import AVFAudio
import AppKit
import CoreGraphics

/// The live interview is a single stateful session. All capture, recognition,
/// turn and answer callbacks are serialized on the main actor. Normal pause/end
/// drains pending audio and Speech results; generations discard only callbacks
/// from an interrupted or superseded capture session.
@MainActor
final class TouchBarChatAppDelegate: NSObject, NSApplicationDelegate {
    private enum DrainDisposition {
        case pause
        case end
    }

    private enum Timing {
        static let questionSilence: TimeInterval = 1.6
        static let incompletePhraseSilence: TimeInterval = 3.0
        static let textStability: TimeInterval = 0.7
        static let confirmation: TimeInterval = 0.45
        static let requestCooldown: TimeInterval = 2.0
        static let audioFreshness: TimeInterval = 1.0
        static let noPacketSilenceGrace: TimeInterval = 2.2
        static let deferredAnswerCheck: TimeInterval = 0.5
    }

    private let store = InterviewStore()
    private lazy var ui = AppUIController(store: store)
    private let audioCapture = SystemAudioCapture()
    /// Recreated before each interview so the selected on-device locale is
    /// fixed for the entire session, including pause and resume.
    private var transcriber = LocalSpeechTranscriber()
    private var interviewLanguage: InterviewLanguage = .chinese
    private var answerLanguage: InterviewLanguage = .chinese
    private let answerClient = AIAnswerClient()
    private let touchBar = TouchBarController()
    private let pageHotkeys = GlobalPageHotkeys()
    private let speechActivityGate = NativeSpeechActivityGate()

    private var runState: InterviewRunState = .idle
    private var statusItem: NSStatusItem?
    private var statusTitleItem: NSMenuItem?
    private var recognitionModeItem: NSMenuItem?
    private var pauseItem: NSMenuItem?
    private var resumeItem: NSMenuItem?
    private var forceAnswerItem: NSMenuItem?
    private var captureGeneration: UInt64 = 0
    private var answerGeneration: UInt64 = 0
    private var candidateGeneration: UInt64 = 0
    private var deferredRetryGeneration: UInt64 = 0
    private var startTask: Task<Void, Never>?
    private var shutdownTask: Task<Void, Never>?
    private var answerTask: Task<Void, Never>?
    private var streamingExchangeID: UUID?
    private var streamingAnswerText = ""
    private var candidateTask: Task<Void, Never>?
    private var deferredRetryTask: Task<Void, Never>?
    private var turnTickTask: Task<Void, Never>?
    private var answerConfiguration: AIRequestConfiguration?
    private var drainDisposition: DrainDisposition?
    private var drainFailure: String?
    private var pendingStartTranscript: (text: String, isFinal: Bool)?

    private var recognizerPrefix = ""
    private var sessionTranscript = ""
    private var turnBoundary = TranscriptTurnBoundary()
    private var pauseDetector = SpeechPauseDetector()
    private var lastObservation: SpeechPauseDetector.Observation?
    private var lastAudioUptime: TimeInterval?
    private var lastTextChangeUptime: TimeInterval?
    private var lastAnswerAttemptUptime: TimeInterval?
    private var submittedTranscript = ""
    private var deferredTranscript: String?
    private var deferredRetryExhausted = false
    private var deferredRetryLastSpeechUptime: TimeInterval?
    private var inFlightQuestion: String?
    private var interruptedTurn: (question: String, transcript: String)?
    private var recentlyAnsweredTurn: (turn: InterviewCompletedTurn, exchangeID: UUID?)?
    private var pausedQuestion: (question: String, transcript: String)?
    private var lastShownPersistenceError: String?
    private var presentingPendingTranscript = false

    // MARK: - Application lifecycle and callback wiring

    func applicationDidFinishLaunching(_ notification: Notification) {
        configureApplicationMenu()
        audioCapture.onAudioBuffer = { [weak self] buffer in
            self?.handleAudioBuffer(buffer)
        }
        audioCapture.onAudioActivity = { [weak self] activity in
            self?.handleAudioActivity(activity)
        }
        audioCapture.onFailure = { [weak self] error in
            self?.handleLiveFailure(error)
        }
        configureTranscriberCallbacks()
        speechActivityGate.onFailure = { [weak self] _ in
            guard let self, case .running = self.runState else { return }
            // SoundAnalysis is an auxiliary local gate. Its absence must not
            // interrupt Speech transcription or the saved interview.
            self.ui.updateRunState(.running, message: L10n.text("本机人声分类不可用，继续按转写与停顿判断"))
        }

        ui.onStart = { [weak self] in self?.startInterview() }
        ui.onPause = { [weak self] in self?.pauseInterview() }
        ui.onResume = { [weak self] in self?.resumeInterview() }
        ui.onStop = { [weak self] in self?.endInterview() }
        pageHotkeys.onPrevious = { [weak self] in self?.touchBar.previousPage() }
        pageHotkeys.onNext = { [weak self] in self?.touchBar.nextPage() }

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(settingsDidChange),
            name: .aiSettingsDidChange,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(appLanguageDidChange),
            name: .touchBarChatAppLanguageDidChange,
            object: nil
        )
        ui.showInitialWindow()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationWillTerminate(_ notification: Notification) {
        ui.commitRecordDrafts()
        captureGeneration &+= 1
        cancelCandidate()
        cancelDeferredAnswerRetry()
        stopTurnTicker()
        cancelAnswerRequest(
            preserveForSplit: false,
            status: "应用退出时回答尚未完成",
            recordIfNoPartial: true
        )
        transcriber.cancel()
        speechActivityGate.stop()
        store.finishSession()
        touchBar.dismiss()
        pageHotkeys.stop()
        NotificationCenter.default.removeObserver(self)
    }

    /// A new recognizer is created only while idle. Late callbacks from the
    /// prior session cannot act on the next one because each engine also has
    /// its own generation checks.
    private func configureTranscriberCallbacks() {
        transcriber.onTranscription = { [weak self] text, isFinal in
            self?.handleTranscription(text, isFinal: isFinal)
        }
        transcriber.onError = { [weak self] error in
            self?.handleLiveFailure(error)
        }
        transcriber.onStopped = { [weak self] timedOut in
            self?.finishCaptureDrain(timedOut: timedOut)
        }
    }

    // MARK: - Interview and capture lifecycle

    /// Starting is the single boundary where settings become an immutable
    /// session snapshot. Pause/resume must not silently switch speech models.
    private func startInterview() {
        guard case .idle = runState else { return }
        guard store.persistenceError == nil else {
            ui.showError(store.persistenceError ?? L10n.text("面试记录暂时无法保存。"))
            return
        }
        guard CGPreflightScreenCaptureAccess() else {
            ui.showError(L10n.text("尚未获得“屏幕与系统音频录制”权限。请在系统设置中允许 TouchBarChat，然后重试。"))
            return
        }
        interviewLanguage = InterviewLanguageSettings.shared.selectedLanguage
        answerLanguage = InterviewLanguageSettings.shared.answerLanguage ?? interviewLanguage
        transcriber = LocalSpeechTranscriber(locale: interviewLanguage.locale)
        configureTranscriberCallbacks()
        do {
            answerConfiguration = try loadOptionalAnswerConfiguration()
        } catch {
            ui.showError(L10n.text("AI 设置需要检查：%@ 可清空接口与模型来只进行转写。", error.localizedDescription))
            return
        }

        sessionTranscript = ""
        recognizerPrefix = ""
        pendingStartTranscript = nil
        turnBoundary.reset()
        submittedTranscript = ""
        cancelDeferredAnswerRetry()
        interruptedTurn = nil
        recentlyAnsweredTurn = nil
        pausedQuestion = nil
        streamingExchangeID = nil
        streamingAnswerText = ""
        presentingPendingTranscript = false
        lastAnswerAttemptUptime = nil
        resetAudioTurnDetection()
        launchCapture(isResume: false)
    }

    private func resumeInterview() {
        guard case .paused = runState else { return }
        do {
            answerConfiguration = try loadOptionalAnswerConfiguration()
        } catch {
            ui.showError(L10n.text("AI 设置需要检查：%@", error.localizedDescription))
            return
        }
        recognizerPrefix = sessionTranscript
        resetAudioTurnDetection()
        launchCapture(isResume: true)
    }

    private func launchCapture(isResume: Bool) {
        captureGeneration &+= 1
        let generation = captureGeneration
        pendingStartTranscript = nil
        runState = .starting
        ui.updateRunState(.starting, message: isResume ? L10n.text("正在继续转写…") : L10n.text("正在启动系统音频转写…"))
        let previousStart = startTask
        let previousShutdown = shutdownTask
        startTask = Task { [weak self] in
            await previousStart?.value
            await previousShutdown?.value
            guard let self, generation == self.captureGeneration else { return }
            await self.beginCapture(generation: generation, isResume: isResume)
        }
    }

    /// Prepare Speech before opening ScreenCaptureKit so the first audible
    /// words are not lost while the model warms up.
    private func beginCapture(generation: UInt64, isResume: Bool) async {
        do {
            try await transcriber.start()
            guard generation == captureGeneration else {
                transcriber.cancel()
                return
            }
            try await audioCapture.start()
            guard generation == captureGeneration else {
                transcriber.cancel()
                await audioCapture.stop()
                return
            }

            if !isResume {
                _ = store.startSession(
                    language: interviewLanguage,
                    answerLanguage: answerLanguage
                )
                if let error = store.persistenceError {
                    transcriber.cancel()
                    await audioCapture.stop()
                    store.finishSession()
                    runState = .idle
                    ui.updateRunState(.idle, message: L10n.text("记录保存不可用"))
                    ui.showError(error)
                    return
                }
            }
            runState = .running
            speechActivityGate.start()
            startTurnTicker()
            let recognitionMode = L10n.text("Apple 本机语音识别")
            if !isResume {
                let touchBarPresentationSupported = touchBar.show()
                touchBar.startLiveDisplay()
                if let pendingStartTranscript {
                    self.pendingStartTranscript = nil
                    handleTranscription(pendingStartTranscript.text, isFinal: pendingStartTranscript.isFinal)
                }
                configureStatusItem()
                refreshTouchBarHotkeys()
                ui.updateRunState(
                    .running,
                    message: answerConfiguration == nil
                        ? L10n.text("已开始，仅转写与保存 · %@", recognitionMode)
                        : (touchBarPresentationSupported
                            ? L10n.text("已开始采集 · %@", recognitionMode)
                            : L10n.text("已开始；Touch Bar 展示接口不可用 · %@", recognitionMode))
                )
            } else {
                touchBar.setCapturePaused(false)
                if let pendingStartTranscript {
                    self.pendingStartTranscript = nil
                    handleTranscription(pendingStartTranscript.text, isFinal: pendingStartTranscript.isFinal)
                }
                touchBar.updateLiveStatus(L10n.text("正在转写…"))
                ui.updateRunState(.running, message: L10n.text("已继续转写 · %@", recognitionMode))
                schedulePausedQuestionAfterResume()
            }
            refreshMenuState()
            ui.minimizeForInterview()
        } catch {
            guard generation == captureGeneration else { return }
            transcriber.cancel()
            await audioCapture.stop()
            guard generation == captureGeneration else { return }
            runState = isResume ? .paused : .idle
            ui.updateRunState(runState, message: isResume ? L10n.text("继续失败，仍处于暂停") : L10n.text("未能开启"))
            refreshMenuState()
            ui.showError(L10n.text("无法开始转写：%@", error.localizedDescription))
        }
    }

    private func pauseInterview() {
        guard case .running = runState else { return }
        beginCaptureDrain(.pause)
    }

    private func beginCaptureDrain(_ disposition: DrainDisposition) {
        captureGeneration &+= 1
        let generation = captureGeneration
        cancelCandidate()
        cancelDeferredAnswerRetry()
        stopTurnTicker()
        speechActivityGate.stop()
        drainDisposition = disposition
        drainFailure = nil
        runState = .finishing
        if case .end = disposition { abandonInFlightAnswerForEnd() }
        touchBar.updateLiveStatus(L10n.text("正在保存最后一句…"))
        ui.updateRunState(
            .finishing,
            message: L10n.text("正在等待最后一句语音识别完成…")
        )
        refreshMenuState()
        shutdownTask = Task { [weak self] in
            guard let self else { return }
            await self.audioCapture.stop()
            guard generation == self.captureGeneration,
                case .finishing = self.runState
            else { return }
            if self.transcriber.isRunning {
                self.transcriber.stop()
            } else {
                self.finishCaptureDrain(timedOut: false)
            }
        }
    }

    private func endInterview() {
        switch runState {
        case .idle: return
        case .running:
            beginCaptureDrain(.end)
            return
        case .finishing:
            drainDisposition = .end
            abandonInFlightAnswerForEnd()
            ui.updateRunState(.finishing, message: L10n.text("正在保存最后一句并结束面试…"))
            return
        case .starting, .paused: break
        }
        captureGeneration &+= 1
        let previousStart = startTask
        startTask?.cancel()
        startTask = nil
        cancelCandidate()
        cancelDeferredAnswerRetry()
        stopTurnTicker()
        abandonInFlightAnswerForEnd()
        transcriber.cancel()
        speechActivityGate.stop()
        finalizeEndedInterview(timedOut: false)
        shutdownTask = Task { [weak self] in
            await previousStart?.value
            await self?.audioCapture.stop()
        }
    }

    private func abandonInFlightAnswerForEnd() {
        cancelAnswerRequest(
            preserveForSplit: false,
            status: "面试结束时回答尚未完成",
            recordIfNoPartial: true
        )
    }

    private func finishCaptureDrain(timedOut: Bool) {
        guard case .finishing = runState, let disposition = drainDisposition else { return }
        drainDisposition = nil
        switch disposition {
        case .pause:
            let pendingQuestion = currentCandidateQuestion
            if !timedOut,
                answerTask == nil,
                deferredTranscript != turnBoundary.transcript,
                InterviewQuestionGate.isCandidate(pendingQuestion, language: interviewLanguage)
            {
                pausedQuestion = (pendingQuestion, turnBoundary.transcript)
            } else {
                pausedQuestion = nil
            }
            runState = .paused
            recognizerPrefix = sessionTranscript
            resetAudioTurnDetection()
            store.flush()
            touchBar.setCapturePaused(true)
            pageHotkeys.stop()
            ui.updateRunState(
                .paused,
                message: timedOut
                    ? L10n.text("已暂停；最终识别未返回，已保存目前文字")
                    : (store.persistenceError == nil
                        ? (pausedQuestion == nil
                            ? L10n.text("采集已暂停；当前文字已保存")
                            : L10n.text("采集已暂停；当前文字已保存，继续后将确认待处理提问"))
                        : L10n.text("采集已暂停；记录保存失败"))
            )
            checkPersistenceHealth()
            refreshMenuState()
        case .end:
            finalizeEndedInterview(timedOut: timedOut)
        }
        if let drainFailure {
            ui.showError(L10n.text("音频采集提前中断：%@ 已保存收到的文字。", drainFailure))
        }
        self.drainFailure = nil
    }

    private func finalizeEndedInterview(timedOut: Bool) {
        cancelDeferredAnswerRetry()
        runState = .idle
        recentlyAnsweredTurn = nil
        pausedQuestion = nil
        store.finishSession()
        store.flush()
        checkPersistenceHealth()
        answerConfiguration = nil
        touchBar.stopLiveDisplay()
        touchBar.dismiss()
        pageHotkeys.stop()
        removeStatusItem()
        ui.updateRunState(
            .idle,
            message: store.persistenceError == nil
                ? (timedOut
                    ? L10n.text("面试已结束；最终识别未返回，已保存目前文字")
                    : L10n.text("面试已结束，记录可复盘编辑"))
                : L10n.text("面试已结束，但记录保存失败")
        )
        ui.showMainWindow()
    }

    // MARK: - Audio and transcription events

    private func handleLiveFailure(_ error: Error) {
        switch runState {
        case .idle, .paused: return
        case .finishing:
            drainFailure = error.localizedDescription
            return
        case .starting, .running: break
        }
        endInterview()
        ui.showError(L10n.text("转写已停止：%@ 已收到的文字已保存；请检查权限和音频来源后重试。", error.localizedDescription))
    }

    private func handleAudioActivity(_ activity: AudioCaptureActivity) {
        guard case .running = runState else { return }
        guard !touchBar.isShowingGeneratedAnswer else { return }
        if activity.hasRecentSignal {
            touchBar.updateLiveStatus(L10n.text("正在识别电脑播放的声音…"))
        } else if activity.packetCount > 0 {
            touchBar.updateLiveStatus(L10n.text("等待电脑播放的声音…"))
        }
    }

    private func handleAudioBuffer(_ buffer: AVAudioPCMBuffer) {
        switch runState {
        case .starting, .finishing:
            // The capture can deliver audio before startCapture returns, and
            // queued packets must still reach Speech while we drain on stop.
            transcriber.append(buffer)
            return
        case .running: break
        case .idle, .paused: return
        }
        transcriber.append(buffer)
        speechActivityGate.process(buffer)
        let observation = pauseDetector.process(buffer)
        guard observation.isValidPCM else {
            resetAudioTurnDetection()
            cancelCandidate()
            cancelAnswerRequest(
                preserveForSplit: false,
                status: "音频异常时回答尚未完成"
            )
            touchBar.showGenerationStatus(L10n.text("音频格式异常，已暂停自动判断"))
            ui.updateRunState(.running, message: L10n.text("音频格式异常，已暂停自动判断"))
            return
        }
        let now = ProcessInfo.processInfo.systemUptime
        lastAudioUptime = now
        lastObservation = observation

        if observation.didDetectSoundStart || observation.didDetectSpeechStart,
            deferredRetryTask != nil
        {
            // A brief notification can occur without changing ASR text. It
            // resets the extra quiet interval, but does not permanently
            // strand the question. Changed text still cancels this snapshot.
            deferredRetryLastSpeechUptime = now
            ui.updateRunState(.running, message: L10n.text("听到新的声音，重新等待提问结束…"))
        }

        if InterviewQuestionEndPolicy.shouldInvalidateCandidate(observation) {
            // New sound invalidates a not-yet-submitted candidate, but a
            // steady background signal must not reset it every audio packet.
            cancelCandidate()
        }
        // This energy detector confirms only 80 ms of sound, not a new
        // interviewer turn. Do not discard a streaming answer here; wait for
        // changed Speech text so a notification or brief acknowledgement
        // cannot erase a useful answer.
        if !observation.isSpeechActive && !observation.isPotentialSpeech {
            transcriber.rolloverIfQuiet(silenceDuration: observation.silenceDuration)
            considerQuestionEnd()
        }
    }

    /// Provisional Speech results replace prior text snapshots. They are not
    /// appended blindly: the recognizer may revise or retract an earlier word.
    private func handleTranscription(_ text: String, isFinal: Bool) {
        switch runState {
        case .starting:
            pendingStartTranscript = (text, isFinal)
            return
        case .running, .finishing: break
        case .idle, .paused: return
        }
        let normalized = text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        guard
            !TranscriptAdmissionPolicy.shouldDeferInitialFragment(
                normalized,
                hasObservedAudioSignal: lastObservation?.hasObservedSpeech == true,
                hasCommittedSegmentText: sessionTranscript != recognizerPrefix
            )
        else { return }
        touchBar.updateRecognitionActivity(
            hasText: !normalized.isEmpty,
            isFinal: isFinal
        )
        let fullTranscript: String
        if recognizerPrefix.isEmpty {
            fullTranscript = normalized
        } else if normalized.isEmpty {
            fullTranscript = recognizerPrefix
        } else {
            fullTranscript = recognizerPrefix + "\n" + normalized
        }
        guard fullTranscript != sessionTranscript else {
            if case .running = runState { considerQuestionEnd() }
            return
        }

        sessionTranscript = fullTranscript
        store.updateTranscript(fullTranscript)
        turnBoundary.update(fullTranscript)
        if answerTask == nil { reopenCompletedQuestionIfExtended() }
        cancelDeferredAnswerRetry()
        lastTextChangeUptime = ProcessInfo.processInfo.systemUptime
        cancelCandidate()
        var confirmedNewSpeech: String?
        var correctedQuestion = false
        if answerTask != nil, let inFlightQuestion {
            switch InterviewInterruptionPolicy.classify(
                submittedQuestion: inFlightQuestion,
                currentQuestion: turnBoundary.pendingText,
                submittedTranscript: submittedTranscript,
                currentTranscript: fullTranscript,
                language: interviewLanguage
            ) {
            case .unchanged, .waitForMoreSpeech:
                break
            case .reviseCurrentQuestion:
                // Reconsider the same prompt; do not misfile it as a second
                // question in the persistent interview record.
                cancelAnswerRequest(
                    preserveForSplit: false,
                    status: "转写修正前的部分回答"
                )
                correctedQuestion = true
            case .extendCurrentQuestion:
                cancelAnswerRequest(
                    preserveForSplit: false,
                    status: "问题补充前的部分回答"
                )
                correctedQuestion = true
            case .newSpeech(let text):
                cancelAnswerRequest(
                    status: "后续提问开始前回答未完成",
                    recordIfNoPartial: true
                )
                confirmedNewSpeech = text
            }
        }

        let pendingDisplayText =
            confirmedNewSpeech
            ?? (correctedQuestion ? turnBoundary.pendingText : displayablePendingTranscript())
        let shouldShowPendingText =
            answerTask == nil
            && (!touchBar.isShowingGeneratedAnswer
                || presentingPendingTranscript
                || confirmedNewSpeech != nil
                || correctedQuestion
                || InterviewInterruptionPolicy.shouldReplaceAnswerWithTranscript(
                    pendingDisplayText,
                    language: interviewLanguage
                ))
        if shouldShowPendingText && !pendingDisplayText.isEmpty {
            if !presentingPendingTranscript {
                touchBar.beginTranscriptTurn()
                presentingPendingTranscript = true
            }
            touchBar.updateTranscript(pendingDisplayText)
        } else if presentingPendingTranscript && pendingDisplayText.isEmpty {
            // Speech may retract an early volatile guess altogether. Replace
            // its Touch Bar text as well as the persisted transcript.
            touchBar.updateTranscript("")
            presentingPendingTranscript = false
        }
        if case .running = runState { considerQuestionEnd() }
        refreshMenuState()
    }

    /// After an in-flight question is interrupted, show only the newly heard
    /// words on Touch Bar, rather than replaying the already submitted prompt.
    private func displayablePendingTranscript() -> String {
        guard let interruptedTurn,
            interruptedTurn.transcript != turnBoundary.transcript
        else {
            return turnBoundary.pendingText
        }
        return InterviewInterruptionPolicy.newSpeech(
            submittedTranscript: interruptedTurn.transcript,
            currentTranscript: turnBoundary.transcript
        )
    }

    private var currentCandidateQuestion: String {
        interruptedTurn == nil ? turnBoundary.pendingText : displayablePendingTranscript()
    }

    private func reopenCompletedQuestionIfExtended() {
        guard let recentlyAnsweredTurn,
            let expanded = recentlyAnsweredTurn.turn.boundaryIncludingContinuation(
                currentTranscript: turnBoundary.transcript
            )
        else { return }
        self.recentlyAnsweredTurn = nil
        turnBoundary = expanded
        if let exchangeID = recentlyAnsweredTurn.exchangeID {
            store.updateLiveExchange(
                id: exchangeID,
                answer: nil,
                status: "已生成；问题随后补充，以上为旧草稿",
                final: true
            )
        }
        touchBar.beginTranscriptTurn()
        touchBar.updateTranscript(expanded.pendingText)
        presentingPendingTranscript = true
        refreshTouchBarHotkeys()
    }

    // MARK: - Question boundary and answer generation

    /// A timer is only scheduled after text and audio both suggest a pause;
    /// it rechecks the same transcript before a network request is submitted.
    private func considerQuestionEnd() {
        let now = ProcessInfo.processInfo.systemUptime
        guard canSubmitQuestion(now: now), candidateTask == nil else { return }
        let transcriptSnapshot = turnBoundary.transcript
        let questionSnapshot = currentCandidateQuestion
        let generation = candidateGeneration
        candidateTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(Timing.confirmation))
            guard let self, generation == self.candidateGeneration else { return }
            self.candidateTask = nil
            guard !Task.isCancelled,
                self.turnBoundary.transcript == transcriptSnapshot,
                self.currentCandidateQuestion == questionSnapshot,
                self.canSubmitQuestion(now: ProcessInfo.processInfo.systemUptime)
            else { return }
            self.submitQuestion(questionSnapshot, transcriptSnapshot: transcriptSnapshot)
        }
    }

    /// Pause is an explicit capture boundary. If its final Speech result
    /// arrived only during drain, resume gives new audio a short chance to
    /// continue before submitting the preserved question without requiring
    /// another recognition callback or PCM packet.
    private func schedulePausedQuestionAfterResume() {
        guard let pausedQuestion, candidateTask == nil else { return }
        self.pausedQuestion = nil
        let generation = candidateGeneration
        candidateTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(Timing.questionSilence))
            guard let self, generation == self.candidateGeneration else { return }
            self.candidateTask = nil
            guard !Task.isCancelled,
                case .running = self.runState,
                self.audioCapture.isCapturing,
                self.answerTask == nil,
                self.turnBoundary.transcript == pausedQuestion.transcript,
                self.currentCandidateQuestion == pausedQuestion.question
            else { return }
            self.submitQuestion(
                pausedQuestion.question,
                transcriptSnapshot: pausedQuestion.transcript
            )
        }
    }

    private func canSubmitQuestion(now: TimeInterval, ignoringDeferral: Bool = false) -> Bool {
        guard case .running = runState else { return false }
        let question = currentCandidateQuestion
        guard ignoringDeferral || deferredTranscript != turnBoundary.transcript else { return false }
        let nativeSpeechEvidence = speechActivityGate.evidence
        // SoundAnalysis may miss quiet but successfully transcribed speech.
        // Treat that mismatch as a bounded extra wait, never a permanent veto.
        let classificationGrace: TimeInterval =
            nativeSpeechEvidence.isAvailable
                && !nativeSpeechEvidence.hasObservedSpeech ? 0.8 : 0
        let requiredSilence =
            (Self.needsLongerPause(question, language: interviewLanguage)
                ? Timing.incompletePhraseSilence : Timing.questionSilence) + classificationGrace
        guard InterviewQuestionGate.isCandidate(question, language: interviewLanguage),
            answerTask == nil,
            let observation = lastObservation,
            observation.isValidPCM,
            let lastAudioUptime,
            let lastTextChangeUptime, now - lastTextChangeUptime >= Timing.textStability,
            let activeSessionID = store.activeSessionID,
            store.sessions.contains(where: { $0.id == activeSessionID })
        else { return false }
        let audioAge = now - lastAudioUptime
        guard
            InterviewQuestionEndPolicy.isQuietEnough(
                observation: observation,
                audioAge: audioAge,
                stableTextAge: now - lastTextChangeUptime,
                requiredSilence: requiredSilence,
                audioFreshness: Timing.audioFreshness,
                noPacketSilenceGrace: Timing.noPacketSilenceGrace,
                captureIsRunning: audioCapture.isCapturing,
                nativeSpeechRecentlyDetected: nativeSpeechEvidence.isAvailable
                    ? nativeSpeechEvidence.hasRecentSpeech : nil
            )
        else { return false }
        if let lastAnswerAttemptUptime,
            now - lastAnswerAttemptUptime < Timing.requestCooldown
        {
            return false
        }
        return true
    }

    private static func needsLongerPause(
        _ question: String,
        language: InterviewLanguage
    ) -> Bool {
        let trimmed = question.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let unfinishedEndings: [String]
        switch language {
        case .chinese:
            unfinishedEndings = ["但是", "然后", "比如", "例如", "因为", "如果", "还有", "以及", "或者", "我想", "就是说"]
        case .english:
            unfinishedEndings = ["and", "but", "because", "if", "for example", "such as", "or"]
        case .korean:
            unfinishedEndings = ["그리고", "하지만", "예를 들어", "왜냐하면", "만약"]
        case .japanese:
            unfinishedEndings = ["そして", "しかし", "例えば", "なぜなら", "もし"]
        case .russian:
            unfinishedEndings = ["и", "но", "потому что", "если", "например", "или"]
        case .french:
            unfinishedEndings = ["et", "mais", "parce que", "si", "par exemple", "ou"]
        case .portuguese:
            unfinishedEndings = ["e", "mas", "porque", "se", "por exemplo", "ou"]
        }
        return unfinishedEndings.contains { ending in
            guard trimmed.hasSuffix(ending) else { return false }
            // Avoid treating the last letters of a longer word as a connective.
            switch language {
            case .chinese, .korean, .japanese:
                return true
            case .english, .russian, .french, .portuguese:
                let preceding = trimmed.dropLast(ending.count).last
                return preceding == nil
                    || preceding?.isWhitespace == true
                    || preceding?.isPunctuation == true
            }
        }
    }

    /// Persist and stream one candidate answer. Generation/session checks in
    /// every callback prevent a late response from replacing a newer turn.
    private func submitQuestion(
        _ question: String,
        transcriptSnapshot: String,
        forceAnswer: Bool = false
    ) {
        cancelDeferredAnswerRetry()
        var question = question
        if let interruptedTurn, interruptedTurn.transcript != transcriptSnapshot {
            let independentQuestion = InterviewInterruptionPolicy.newSpeech(
                submittedTranscript: interruptedTurn.transcript,
                currentTranscript: transcriptSnapshot
            )
            if forceAnswer
                || InterviewQuestionGate.isCandidate(
                    independentQuestion,
                    language: interviewLanguage
                )
            {
                // The interrupted question (including any partial AI text)
                // was already persisted when its request was cancelled.
                var nextTurn = TranscriptTurnBoundary()
                nextTurn.reset(committedPrefix: interruptedTurn.transcript)
                nextTurn.update(transcriptSnapshot)
                turnBoundary = nextTurn
                question = independentQuestion
            }
        }
        interruptedTurn = nil
        recentlyAnsweredTurn = nil
        lastAnswerAttemptUptime = ProcessInfo.processInfo.systemUptime
        submittedTranscript = transcriptSnapshot
        guard let configuration = answerConfiguration else {
            _ = store.appendExchange(question: question, answer: nil, status: "未配置 AI 接口")
            turnBoundary.commitCurrentText()
            presentingPendingTranscript = false
            speechActivityGate.reset()
            return
        }
        guard let sessionID = store.activeSessionID else { return }
        let boundaryBeforeSubmission = turnBoundary
        answerGeneration &+= 1
        let generation = answerGeneration
        inFlightQuestion = question
        streamingExchangeID = nil
        streamingAnswerText = ""
        presentingPendingTranscript = false
        touchBar.beginAnswerGeneration()
        answerTask = Task { [weak self] in
            guard let self else { return }
            do {
                let onPartialAnswer: @MainActor (String) -> Void = { [weak self] partialAnswer in
                    guard let self,
                        !Task.isCancelled,
                        generation == self.answerGeneration,
                        sessionID == self.store.activeSessionID,
                        self.hasActiveInterview
                    else { return }
                    self.streamingAnswerText = partialAnswer
                    if let exchangeID = self.streamingExchangeID {
                        self.store.updateLiveExchange(
                            id: exchangeID,
                            answer: partialAnswer,
                            status: "生成中（部分回答）",
                            final: false
                        )
                    } else {
                        self.streamingExchangeID = self.store.appendExchange(
                            question: question,
                            answer: partialAnswer,
                            status: "生成中（部分回答）"
                        )
                    }
                    self.touchBar.updateStreamingAnswer(partialAnswer, isFinal: false)
                    self.refreshTouchBarHotkeys()
                }
                let outcome: AIAnswerOutcome
                if forceAnswer {
                    outcome = .answer(
                        try await self.answerClient.streamAnswer(
                            endpoint: configuration.endpoint,
                            model: configuration.model,
                            apiKey: configuration.apiKey ?? "",
                            userProfile: configuration.profile,
                            question: question,
                            language: self.answerLanguage,
                            onPartialAnswer: onPartialAnswer
                        ))
                } else {
                    outcome = try await self.answerClient.streamAnswerForLiveTurn(
                        endpoint: configuration.endpoint,
                        model: configuration.model,
                        apiKey: configuration.apiKey ?? "",
                        userProfile: configuration.profile,
                        question: question,
                        recentContext: self.recentQuestionContext(),
                        language: self.answerLanguage,
                        onPartialAnswer: onPartialAnswer
                    )
                }
                guard !Task.isCancelled,
                    generation == self.answerGeneration,
                    sessionID == self.store.activeSessionID,
                    self.hasActiveInterview
                else { return }
                self.inFlightQuestion = nil
                self.answerTask = nil
                switch outcome {
                case .answer(let answer):
                    let completedExchangeID: UUID?
                    if let exchangeID = self.streamingExchangeID {
                        self.store.updateLiveExchange(
                            id: exchangeID,
                            answer: answer,
                            status: "已生成",
                            final: true
                        )
                        completedExchangeID = exchangeID
                    } else {
                        completedExchangeID = self.store.appendExchange(
                            question: question, answer: answer, status: "已生成"
                        )
                    }
                    self.streamingExchangeID = nil
                    self.streamingAnswerText = ""
                    self.turnBoundary.commitThrough(transcriptSnapshot)
                    self.recentlyAnsweredTurn = (
                        InterviewCompletedTurn(
                            question: question,
                            submittedTranscript: transcriptSnapshot,
                            boundaryBeforeSubmission: boundaryBeforeSubmission,
                            language: self.interviewLanguage
                        ),
                        completedExchangeID
                    )
                    self.presentingPendingTranscript = false
                    self.speechActivityGate.reset()
                    self.touchBar.updateStreamingAnswer(answer, isFinal: true)
                    self.refreshTouchBarHotkeys()
                    self.reopenCompletedQuestionIfExtended()
                    self.considerQuestionEnd()
                case .needsMoreSpeech:
                    self.streamingExchangeID = nil
                    self.streamingAnswerText = ""
                    if self.turnBoundary.transcript == transcriptSnapshot,
                        self.currentCandidateQuestion == question
                    {
                        // A WAIT sentinel can be a false positive. Keep the
                        // transcript visible and permit one bounded automatic
                        // answer only after a further, confirmed quiet spell.
                        self.deferredTranscript = transcriptSnapshot
                        self.deferredRetryExhausted = false
                        self.presentingPendingTranscript = true
                        self.touchBar.beginTranscriptTurn()
                        self.touchBar.updateTranscript(question)
                        self.refreshTouchBarHotkeys()
                        self.scheduleDeferredAnswerRetry(
                            question: question,
                            transcript: transcriptSnapshot,
                            sessionID: sessionID,
                            answerGeneration: generation
                        )
                        self.ui.updateRunState(.running, message: L10n.text("AI 判断提问可能未说完，等待语音结束…"))
                    } else {
                        // Speech revised the text while the model was
                        // deciding. Let the normal turn detector use it.
                        self.considerQuestionEnd()
                    }
                }
                self.refreshMenuState()
            } catch is CancellationError {
                // A later generation owns the display and session state.
            } catch {
                guard generation == self.answerGeneration,
                    sessionID == self.store.activeSessionID,
                    self.hasActiveInterview
                else { return }
                let failureStatus = "生成失败：\(error.localizedDescription)"
                if let exchangeID = self.streamingExchangeID {
                    self.store.updateLiveExchange(
                        id: exchangeID,
                        answer: self.streamingAnswerText,
                        status: failureStatus,
                        final: true
                    )
                } else {
                    _ = self.store.appendExchange(
                        question: question,
                        answer: nil,
                        status: failureStatus
                    )
                }
                self.streamingExchangeID = nil
                self.streamingAnswerText = ""
                self.turnBoundary.commitThrough(transcriptSnapshot)
                self.presentingPendingTranscript = false
                self.speechActivityGate.reset()
                self.inFlightQuestion = nil
                self.answerTask = nil
                self.touchBar.showGenerationStatus(L10n.text("AI 回答失败；记录已保存"))
                self.refreshMenuState()
            }
        }
    }

    // MARK: - Retry, diagnostics, and persistence

    private func resetAudioTurnDetection() {
        pauseDetector.reset()
        lastObservation = nil
        lastAudioUptime = nil
        lastTextChangeUptime = nil
    }

    private static func meaningfulText(_ text: String) -> String {
        String(text.filter { $0.isLetter || $0.isNumber }).lowercased()
    }

    private var hasActiveInterview: Bool {
        switch runState {
        case .idle: false
        case .starting, .running, .finishing, .paused: store.activeSessionID != nil
        }
    }

    private func cancelCandidate() {
        candidateGeneration &+= 1
        candidateTask?.cancel()
        candidateTask = nil
    }

    private func cancelDeferredAnswerRetry(clearDeferral: Bool = true) {
        deferredRetryGeneration &+= 1
        deferredRetryTask?.cancel()
        deferredRetryTask = nil
        if clearDeferral {
            deferredTranscript = nil
            deferredRetryExhausted = false
            deferredRetryLastSpeechUptime = nil
        }
    }

    /// A model WAIT response is advisory, not a terminal state. A late final
    /// transcript or session change invalidates this snapshot; a fresh audio
    /// onset restarts its quiet clock. Only one delayed no-WAIT answer is sent.
    private func scheduleDeferredAnswerRetry(
        question: String,
        transcript: String,
        sessionID: UUID,
        answerGeneration: UInt64
    ) {
        cancelDeferredAnswerRetry(clearDeferral: false)
        let retryGeneration = deferredRetryGeneration
        let captureGeneration = captureGeneration
        let deferredAt = ProcessInfo.processInfo.systemUptime
        deferredRetryLastSpeechUptime = nil
        deferredRetryTask = Task { [weak self] in
            while !Task.isCancelled {
                do {
                    try await Task.sleep(for: .seconds(Timing.deferredAnswerCheck))
                } catch {
                    return
                }
                guard let self,
                    retryGeneration == self.deferredRetryGeneration,
                    captureGeneration == self.captureGeneration,
                    answerGeneration == self.answerGeneration,
                    case .running = self.runState,
                    self.audioCapture.isCapturing,
                    sessionID == self.store.activeSessionID,
                    self.answerTask == nil,
                    self.deferredTranscript == transcript
                else { return }

                let now = ProcessInfo.processInfo.systemUptime
                let elapsed = now - deferredAt
                let quietElapsed = now - max(deferredAt, self.deferredRetryLastSpeechUptime ?? deferredAt)
                let nativeEvidence = self.speechActivityGate.evidence
                let decision = DeferredAnswerRetryPolicy.decide(
                    snapshotMatches: self.turnBoundary.transcript == transcript
                        && self.currentCandidateQuestion == question,
                    captureIsRunning: self.audioCapture.isCapturing,
                    questionReady: self.canSubmitQuestion(now: now, ignoringDeferral: true),
                    observation: self.lastObservation,
                    audioAge: self.lastAudioUptime.map { now - $0 },
                    elapsedSinceWait: elapsed,
                    elapsedSinceLastSpeechOnset: quietElapsed,
                    nativeSpeechRecentlyDetected: nativeEvidence.isAvailable
                        ? nativeEvidence.hasRecentSpeech : nil
                )
                switch decision {
                case .forceAnswer:
                    self.submitQuestion(question, transcriptSnapshot: transcript, forceAnswer: true)
                    self.refreshMenuState()
                    return
                case .manualFallback:
                    self.deferredRetryTask = nil
                    self.deferredRetryExhausted = true
                    self.ui.updateRunState(
                        .running,
                        message: L10n.text("尚未确认提问结束；可从菜单栏手动生成当前回答")
                    )
                    self.refreshMenuState()
                    return
                case .cancel:
                    self.cancelDeferredAnswerRetry()
                    return
                case .pending:
                    break
                }
            }
        }
    }

    private func startTurnTicker() {
        stopTurnTicker()
        turnTickTask = Task { [weak self] in
            while !Task.isCancelled {
                do {
                    try await Task.sleep(for: .milliseconds(250))
                } catch {
                    return
                }
                guard let self, case .running = self.runState else { return }
                self.checkPersistenceHealth()
                self.refreshTouchBarHotkeys()
                self.considerQuestionEnd()
            }
        }
    }

    private func stopTurnTicker() {
        turnTickTask?.cancel()
        turnTickTask = nil
    }

    private func refreshTouchBarHotkeys() {
        // The available width changes with the Control Strip and frontmost
        // app. If AppKit kept the role icon but hid the content item, switch
        // once to the compact width before deciding which controls are live.
        _ = touchBar.recoverContentVisibilityIfNeeded()
        guard case .running = runState,
            touchBar.isShowingGeneratedAnswer,
            touchBar.hasVisibleAnswerItem
        else {
            pageHotkeys.stop()
            return
        }
        pageHotkeys.start()
    }

    private func checkPersistenceHealth() {
        guard let error = store.persistenceError else {
            lastShownPersistenceError = nil
            return
        }
        guard error != lastShownPersistenceError else { return }
        lastShownPersistenceError = error
        touchBar.showGenerationStatus(L10n.text("记录保存失败，请检查磁盘"))
        refreshMenuState()
        ui.showError(L10n.text("%@ 当前文字仍在内存中；请检查磁盘并重试保存，暂勿退出应用。", error))
    }

    private func cancelAnswerRequest(
        preserveForSplit: Bool = true,
        status: String = "回答中断",
        recordIfNoPartial: Bool = false
    ) {
        guard answerTask != nil else { return }
        if let exchangeID = streamingExchangeID {
            store.updateLiveExchange(
                id: exchangeID,
                answer: streamingAnswerText,
                status: status,
                final: true
            )
        } else if recordIfNoPartial, let inFlightQuestion {
            _ = store.appendExchange(question: inFlightQuestion, answer: nil, status: status)
        }
        if preserveForSplit, let inFlightQuestion {
            interruptedTurn = (inFlightQuestion, submittedTranscript)
        } else {
            interruptedTurn = nil
        }
        answerGeneration &+= 1
        answerTask?.cancel()
        answerTask = nil
        inFlightQuestion = nil
        streamingExchangeID = nil
        streamingAnswerText = ""
        submittedTranscript = ""
        // Keep the last visible text until new recognized words arrive. A
        // transient sound should not erase a useful answer by itself.
    }

    private func loadOptionalAnswerConfiguration() throws -> AIRequestConfiguration? {
        let draft = try AISettingsStore.shared.currentDraft()
        if draft.endpointText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
            draft.model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        {
            return nil
        }
        return try AISettingsStore.shared.loadValidatedConfiguration()
    }

    private func recentQuestionContext() -> String {
        guard let activeSessionID = store.activeSessionID,
            let session = store.sessions.first(where: { $0.id == activeSessionID })
        else {
            return ""
        }
        // Interrupted or superseded drafts are retained for review, but they
        // must not be fed back as if the candidate actually said them.
        return session.exchanges.filter {
            $0.status == "已生成" || $0.status == "answered"
        }.suffix(3).enumerated().map { index, exchange in
            let answer = exchange.displayAnswer ?? "(no AI answer)"
            return "\(index + 1). Interviewer: \(exchange.displayQuestion)\nAI draft: \(answer)"
        }.joined(separator: "\n")
    }

    private func forceCurrentAnswer() {
        guard case .running = runState,
            answerConfiguration != nil,
            answerTask == nil
        else { return }
        let question = currentCandidateQuestion
        guard !question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            touchBar.showGenerationStatus(L10n.text("尚未识别到当前提问"))
            return
        }
        cancelCandidate()
        cancelDeferredAnswerRetry()
        touchBar.beginTranscriptTurn()
        touchBar.updateTranscript(question)
        presentingPendingTranscript = true
        submitQuestion(question, transcriptSnapshot: turnBoundary.transcript, forceAnswer: true)
        refreshMenuState()
    }

    // MARK: - Menu bar and app menu

    private func configureStatusItem() {
        guard statusItem == nil else { return }
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.image = NSImage(
            systemSymbolName: "waveform",
            accessibilityDescription: "TouchBarChat"
        )
        item.button?.toolTip = L10n.text("TouchBarChat · 面试进行中")
        let menu = NSMenu()
        let title = NSMenuItem(title: L10n.text("TouchBarChat · 面试进行中"), action: nil, keyEquivalent: "")
        title.isEnabled = false
        menu.addItem(title)
        statusTitleItem = title
        menu.addItem(.separator())
        let pause = menu.addItem(withTitle: L10n.text("暂停面试"), action: #selector(pauseFromMenu), keyEquivalent: "")
        pause.target = self
        pauseItem = pause
        let resume = menu.addItem(withTitle: L10n.text("继续面试"), action: #selector(resumeFromMenu), keyEquivalent: "")
        resume.target = self
        resumeItem = resume
        menu.addItem(withTitle: L10n.text("结束面试"), action: #selector(endFromMenu), keyEquivalent: "").target = self
        let force = menu.addItem(
            withTitle: L10n.text("手动生成当前回答"),
            action: #selector(forceAnswerFromMenu),
            keyEquivalent: ""
        )
        force.target = self
        forceAnswerItem = force
        menu.addItem(.separator())
        menu.addItem(withTitle: L10n.text("打开主窗口"), action: #selector(openMainWindow), keyEquivalent: "").target = self
        menu.addItem(.separator())
        let source = NSMenuItem(title: L10n.text("输入：电脑播放声音（不含麦克风）"), action: nil, keyEquivalent: "")
        source.isEnabled = false
        menu.addItem(source)
        let recognition = NSMenuItem(title: L10n.text("识别：检查中"), action: nil, keyEquivalent: "")
        recognition.isEnabled = false
        menu.addItem(recognition)
        recognitionModeItem = recognition
        menu.addItem(.separator())
        menu.addItem(withTitle: L10n.text("退出 TouchBarChat"), action: #selector(quit), keyEquivalent: "q").target = self
        item.menu = menu
        statusItem = item
        refreshMenuState()
    }

    private func configureApplicationMenu() {
        let mainMenu = NSMenu()
        let applicationItem = NSMenuItem()
        let applicationMenu = NSMenu(title: "TouchBarChat")
        applicationMenu.addItem(
            withTitle: L10n.text("关于 TouchBarChat"),
            action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)),
            keyEquivalent: ""
        ).target = NSApp
        applicationMenu.addItem(.separator())
        applicationMenu.addItem(
            withTitle: L10n.text("退出 TouchBarChat"),
            action: #selector(NSApplication.terminate(_:)),
            keyEquivalent: "q"
        ).target = NSApp
        applicationItem.submenu = applicationMenu
        mainMenu.addItem(applicationItem)

        let editItem = NSMenuItem()
        let editMenu = NSMenu(title: L10n.text("编辑"))
        // Leave targets unset so the focused text field handles each command.
        editMenu.addItem(
            withTitle: L10n.text("撤销"),
            action: Selector(("undo:")),
            keyEquivalent: "z"
        )
        editMenu.addItem(.separator())
        editMenu.addItem(
            withTitle: L10n.text("剪切"),
            action: #selector(NSTextView.cut(_:)),
            keyEquivalent: "x"
        )
        editMenu.addItem(
            withTitle: L10n.text("复制"),
            action: #selector(NSTextView.copy(_:)),
            keyEquivalent: "c"
        )
        editMenu.addItem(
            withTitle: L10n.text("粘贴"),
            action: #selector(NSTextView.paste(_:)),
            keyEquivalent: "v"
        )
        editMenu.addItem(.separator())
        editMenu.addItem(
            withTitle: L10n.text("全选"),
            action: #selector(NSTextView.selectAll(_:)),
            keyEquivalent: "a"
        )
        editItem.submenu = editMenu
        mainMenu.addItem(editItem)

        let windowItem = NSMenuItem()
        let windowMenu = NSMenu(title: L10n.text("窗口"))
        windowMenu.addItem(
            withTitle: L10n.text("打开主窗口"),
            action: #selector(openMainWindow),
            keyEquivalent: "0"
        ).target = self
        windowItem.submenu = windowMenu
        mainMenu.addItem(windowItem)
        NSApp.mainMenu = mainMenu
    }

    private func removeStatusItem() {
        if let statusItem { NSStatusBar.system.removeStatusItem(statusItem) }
        statusItem = nil
        statusTitleItem = nil
        recognitionModeItem = nil
        pauseItem = nil
        resumeItem = nil
        forceAnswerItem = nil
    }

    private func refreshMenuState() {
        if store.persistenceError != nil {
            statusTitleItem?.title = L10n.text("TouchBarChat · 记录保存失败")
        }
        recognitionModeItem?.title = L10n.text("识别：Apple 本机处理")
        if case .running = runState {
            forceAnswerItem?.isEnabled =
                answerConfiguration != nil
                && answerTask == nil
                && !currentCandidateQuestion.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        } else {
            forceAnswerItem?.isEnabled = false
        }
        switch runState {
        case .running:
            if store.persistenceError == nil {
                statusTitleItem?.title =
                    deferredRetryExhausted
                    ? L10n.text("TouchBarChat · 可手动生成回答")
                    : (deferredTranscript == nil
                        ? L10n.text("TouchBarChat · 面试进行中")
                        : L10n.text("TouchBarChat · 等待提问结束"))
            }
            pauseItem?.isEnabled = true
            resumeItem?.isEnabled = false
        case .paused:
            if store.persistenceError == nil {
                statusTitleItem?.title = L10n.text("TouchBarChat · 已暂停")
            }
            pauseItem?.isEnabled = false
            resumeItem?.isEnabled = true
        case .finishing:
            if store.persistenceError == nil {
                statusTitleItem?.title = L10n.text("TouchBarChat · 正在保存转写")
            }
            pauseItem?.isEnabled = false
            resumeItem?.isEnabled = false
        case .idle, .starting:
            pauseItem?.isEnabled = false
            resumeItem?.isEnabled = false
        }
    }

    @objc private func settingsDidChange() {
        // The UI disables API editing during a live session. If an external
        // defaults writer changes it anyway, the next session will load it.
    }

    @objc private func appLanguageDidChange() {
        configureApplicationMenu()
        if statusItem != nil {
            removeStatusItem()
            configureStatusItem()
        }
    }

    @objc private func pauseFromMenu() { pauseInterview() }
    @objc private func resumeFromMenu() { resumeInterview() }
    @objc private func endFromMenu() { endInterview() }
    @objc private func forceAnswerFromMenu() { forceCurrentAnswer() }
    @objc private func openMainWindow() { ui.showMainWindow() }
    @objc private func quit() { NSApp.terminate(nil) }
}
