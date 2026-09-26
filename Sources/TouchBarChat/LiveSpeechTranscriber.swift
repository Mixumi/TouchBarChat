import AVFoundation
import Foundation
import Speech

enum LiveSpeechTranscriberError: LocalizedError {
    case alreadyRunning
    case cancelled
    case missingUsageDescription
    case permissionDenied
    case permissionRestricted
    case unavailable
    case onDeviceUnavailable
    case audioConversionFailed
    case finalizationTimedOut

    var errorDescription: String? {
        switch self {
        case .alreadyRunning:
            return L10n.text("语音识别已经在运行。")
        case .cancelled:
            return L10n.text("语音识别启动已取消。")
        case .missingUsageDescription:
            return L10n.text("应用缺少 NSSpeechRecognitionUsageDescription 配置。")
        case .permissionDenied:
            return L10n.text("没有语音识别权限，请在系统设置中允许此应用使用语音识别。")
        case .permissionRestricted:
            return L10n.text("这台 Mac 限制了语音识别。")
        case .unavailable:
            return L10n.text("当前无法使用所选语言的语音识别。")
        case .onDeviceUnavailable:
            return L10n.text("这台 Mac 尚不支持所选语言的本地语音识别。")
        case .audioConversionFailed:
            return L10n.text("无法将会议音频转换为语音识别所需的格式。")
        case .finalizationTimedOut:
            return L10n.text("等待语音识别最终结果超时。")
        }
    }
}

/// AVAudioConverter may call its @Sendable input block more than once. Its
/// synchronous conversion owns this immutable buffer until the call returns.
private final class SingleBufferInput: @unchecked Sendable {
    private let lock = NSLock()
    private let buffer: AVAudioPCMBuffer
    private var delivered = false

    init(_ buffer: AVAudioPCMBuffer) {
        self.buffer = buffer
    }

    func next(status: UnsafeMutablePointer<AVAudioConverterInputStatus>) -> AVAudioBuffer? {
        lock.lock()
        defer { lock.unlock() }
        guard !delivered else {
            status.pointee = .noDataNow
            return nil
        }
        delivered = true
        status.pointee = .haveData
        return buffer
    }
}

/// Receives uncompressed system audio and emits the best local transcription
/// for the selected locale.
/// A partial result replaces the previous partial result for its recognition task;
/// completed tasks are prepended once so callbacks contain the full session text.
/// A final result is stable for its task, not an end-of-turn signal. All methods
/// and callbacks run on the main actor.
@MainActor
final class LiveSpeechTranscriber {
    var onTranscription: ((String, Bool) -> Void)?
    var onError: ((Error) -> Void)?
    /// Called after endAudio has produced a final result, or after a bounded
    /// wait that preserves the latest partial result. True means timeout.
    var onStopped: ((Bool) -> Void)?

    private(set) var isRunning = false
    private(set) var usesOnDeviceRecognition = false

    private let locale: Locale
    private var isStarting = false
    private var generation: UInt64 = 0
    private var recognizer: SFSpeechRecognizer?
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private struct RecognitionTaskSession {
        let request: SFSpeechAudioBufferRecognitionRequest
        let task: SFSpeechRecognitionTask
    }
    private var recognitionTasks: [UInt64: RecognitionTaskSession] = [:]
    private var activeTaskID: UInt64 = 0
    private var activeTaskStartedAt: TimeInterval?
    private var nextEmissionTaskID: UInt64 = 1
    private var rolloverTask: Task<Void, Never>?
    private var stopTimeoutTask: Task<Void, Never>?
    private var converter: AVAudioConverter?
    private var converterSourceFormat: AVAudioFormat?
    private struct LastResult: Equatable {
        let text: String
        let isFinal: Bool
    }
    private var lastResults: [UInt64: LastResult] = [:]
    private var emittedResults: [UInt64: LastResult] = [:]
    private var completedTaskIDs: Set<UInt64> = []
    private var completedTranscriptPrefix = ""

    /// The legacy fallback is local-only. If the language asset is missing,
    /// fail visibly instead of silently sending interview audio to a service.
    init(locale: Locale = Locale(identifier: "zh-CN")) {
        self.locale = locale
    }

    func start() async throws {
        guard !isStarting, request == nil else {
            throw LiveSpeechTranscriberError.alreadyRunning
        }

        isStarting = true
        let startGeneration = generation
        defer { isStarting = false }

        // Speech.framework terminates an app that requests authorization
        // without this purpose string, so fail with an actionable error.
        guard Bundle.main.object(forInfoDictionaryKey: "NSSpeechRecognitionUsageDescription") != nil else {
            throw LiveSpeechTranscriberError.missingUsageDescription
        }

        let authorization = await Self.authorizationStatus()
        guard startGeneration == generation else {
            throw LiveSpeechTranscriberError.cancelled
        }
        switch authorization {
        case .authorized:
            break
        case .denied:
            throw LiveSpeechTranscriberError.permissionDenied
        case .restricted:
            throw LiveSpeechTranscriberError.permissionRestricted
        case .notDetermined:
            throw LiveSpeechTranscriberError.permissionDenied
        @unknown default:
            throw LiveSpeechTranscriberError.permissionDenied
        }

        guard SFSpeechRecognizer.supportedLocales().contains(where: { $0.identifier == locale.identifier }),
            let recognizer = SFSpeechRecognizer(locale: locale),
            recognizer.isAvailable
        else {
            throw LiveSpeechTranscriberError.unavailable
        }
        guard recognizer.supportsOnDeviceRecognition else {
            throw LiveSpeechTranscriberError.onDeviceUnavailable
        }

        recognizer.queue = .main

        generation &+= 1
        self.recognizer = recognizer
        usesOnDeviceRecognition = true
        isRunning = true
        beginRecognitionTask()
    }

    /// Call on MainActor with successive AVAudioPCMBuffer chunks from the
    /// system-audio capture. ScreenCaptureKit's usual 48 kHz stereo buffers
    /// are converted to the format preferred by Speech.framework.
    func append(_ buffer: AVAudioPCMBuffer) {
        guard isRunning, let request, buffer.frameLength > 0 else { return }

        let preferredFormat = request.nativeAudioFormat
        if buffer.format == preferredFormat {
            request.append(buffer)
            return
        }

        if converter == nil || converterSourceFormat != buffer.format {
            converter = AVAudioConverter(from: buffer.format, to: preferredFormat)
            converterSourceFormat = buffer.format
        }
        guard let converter else {
            fail(LiveSpeechTranscriberError.audioConversionFailed)
            return
        }

        let inputRate = buffer.format.sampleRate
        let outputRate = preferredFormat.sampleRate
        guard inputRate.isFinite, outputRate.isFinite, inputRate > 0, outputRate > 0 else {
            fail(LiveSpeechTranscriberError.audioConversionFailed)
            return
        }
        let frameEstimate = ceil(Double(buffer.frameLength) * outputRate / inputRate)
        guard frameEstimate.isFinite, frameEstimate >= 0,
            frameEstimate <= Double(UInt32.max) - 1024
        else {
            fail(LiveSpeechTranscriberError.audioConversionFailed)
            return
        }
        let capacity = AVAudioFrameCount(frameEstimate + 1024)
        guard let converted = AVAudioPCMBuffer(pcmFormat: preferredFormat, frameCapacity: capacity) else {
            fail(LiveSpeechTranscriberError.audioConversionFailed)
            return
        }

        let input = SingleBufferInput(buffer)
        var conversionError: NSError?
        let status = converter.convert(to: converted, error: &conversionError) { _, inputStatus in
            input.next(status: inputStatus)
        }
        guard status != .error, conversionError == nil else {
            fail(conversionError ?? LiveSpeechTranscriberError.audioConversionFailed)
            return
        }
        if converted.frameLength > 0 {
            request.append(converted)
        }
    }

    /// Prefer a quiet boundary for Speech's short-dictation task renewal.
    /// A hard timeout still protects against the framework's ~one-minute limit
    /// when the other party speaks without pausing.
    func rolloverIfQuiet(silenceDuration: TimeInterval) {
        guard isRunning,
            silenceDuration >= 0.8,
            let activeTaskStartedAt,
            ProcessInfo.processInfo.systemUptime - activeTaskStartedAt >= 35
        else { return }
        rolloverRecognitionTask(expectedTaskID: activeTaskID)
    }

    /// Finishes the current audio stream. A final transcription may arrive
    /// asynchronously after this method returns.
    func stop() {
        guard isRunning else { return }
        isRunning = false
        rolloverTask?.cancel()
        rolloverTask = nil
        request?.endAudio()
        if recognitionTasks.isEmpty {
            finishIfStopped()
            return
        }
        stopTimeoutTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(5))
            guard !Task.isCancelled, let self, !self.isRunning,
                !self.recognitionTasks.isEmpty
            else { return }
            // Speech does not always send isFinal after endAudio(). Keep every
            // task's latest partial instead of losing the whole trailing turn.
            for taskID in self.recognitionTasks.keys {
                self.completedTaskIDs.insert(taskID)
            }
            self.flushReadyResults()
            self.completeStop(timedOut: true)
        }
    }

    /// Immediately discards the recognition task and any later callbacks.
    func cancel() {
        generation &+= 1
        let tasks = recognitionTasks.values.map(\.task)
        clearSession()
        for task in tasks { task.cancel() }
    }

    private static func authorizationStatus() async -> SFSpeechRecognizerAuthorizationStatus {
        let current = SFSpeechRecognizer.authorizationStatus()
        guard current == .notDetermined else { return current }
        return await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { @Sendable status in
                continuation.resume(returning: status)
            }
        }
    }

    private func beginRecognitionTask() {
        guard let recognizer else { return }
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        request.addsPunctuation = true
        request.taskHint = .dictation
        request.requiresOnDeviceRecognition = usesOnDeviceRecognition

        activeTaskID &+= 1
        let taskID = activeTaskID
        activeTaskStartedAt = ProcessInfo.processInfo.systemUptime
        let taskGeneration = generation
        self.request = request
        converter = nil
        converterSourceFormat = nil
        let task = recognizer.recognitionTask(with: request) { [weak self] result, error in
            // SFSpeechRecognizer.queue is the main operation queue above.
            MainActor.assumeIsolated {
                self?.handle(result: result, error: error, generation: taskGeneration, taskID: taskID)
            }
        }
        recognitionTasks[taskID] = RecognitionTaskSession(request: request, task: task)

        rolloverTask?.cancel()
        rolloverTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(52))
            guard !Task.isCancelled, let self else { return }
            self.rolloverRecognitionTask(expectedTaskID: taskID)
        }
    }

    private func rolloverRecognitionTask(expectedTaskID taskID: UInt64) {
        guard isRunning, activeTaskID == taskID else { return }
        request?.endAudio()
        guard isRunning, activeTaskID == taskID else { return }
        beginRecognitionTask()
        // Some Speech tasks never deliver isFinal after endAudio(). Do not
        // let one old task indefinitely block every newer partial result.
        // Keep its latest partial, then advance the ordered transcript.
        let rolloverGeneration = generation
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(4))
            guard !Task.isCancelled, let self,
                self.generation == rolloverGeneration,
                let stale = self.recognitionTasks.removeValue(forKey: taskID),
                taskID < self.activeTaskID
            else { return }
            self.completedTaskIDs.insert(taskID)
            self.flushReadyResults()
            stale.task.cancel()
        }
    }

    private func handle(
        result: SFSpeechRecognitionResult?, error: Error?,
        generation taskGeneration: UInt64, taskID: UInt64
    ) {
        guard taskGeneration == generation, recognitionTasks[taskID] != nil else { return }

        if let result {
            let text = result.bestTranscription.formattedString.trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty {
                lastResults[taskID] = LastResult(text: text, isFinal: result.isFinal)
            }
            if result.isFinal {
                recognitionTasks.removeValue(forKey: taskID)
                completedTaskIDs.insert(taskID)
            }
            flushReadyResults()
            guard taskGeneration == generation else { return }
            if result.isFinal {
                if taskID == activeTaskID, isRunning {
                    beginRecognitionTask()
                } else {
                    finishIfStopped()
                }
                return
            }
        }

        if let error {
            recognitionTasks.removeValue(forKey: taskID)
            completedTaskIDs.insert(taskID)
            flushReadyResults()
            guard taskGeneration == generation else { return }
            if taskID == activeTaskID && isRunning {
                fail(error)
            } else {
                finishIfStopped()
            }
        }
    }

    private func flushReadyResults() {
        let currentGeneration = generation
        while true {
            let taskID = nextEmissionTaskID
            if let result = lastResults[taskID], result != emittedResults[taskID] {
                emittedResults[taskID] = result
                onTranscription?(
                    Self.joinTranscript(completedTranscriptPrefix, result.text),
                    result.isFinal
                )
                guard currentGeneration == generation else { return }
            }
            guard completedTaskIDs.remove(taskID) != nil else { return }
            if let completedText = lastResults[taskID]?.text {
                // Advance only when this task completes. A final result is used
                // in the normal rollover path; if the task ended with an error,
                // preserve its last partial rather than dropping spoken words.
                completedTranscriptPrefix = Self.joinTranscript(
                    completedTranscriptPrefix,
                    completedText
                )
            }
            lastResults.removeValue(forKey: taskID)
            emittedResults.removeValue(forKey: taskID)
            nextEmissionTaskID &+= 1
        }
    }

    private static func joinTranscript(_ prefix: String, _ segment: String) -> String {
        guard !prefix.isEmpty else { return segment }
        guard !segment.isEmpty else { return prefix }

        // Chinese characters can join directly across the rollover boundary.
        // Preserve a word boundary when two ASCII words meet there.
        let needsSpace =
            prefix.unicodeScalars.last.map(Self.isASCIIAlphanumeric) == true
            && segment.unicodeScalars.first.map(Self.isASCIIAlphanumeric) == true
        return prefix + (needsSpace ? " " : "") + segment
    }

    private static func isASCIIAlphanumeric(_ scalar: UnicodeScalar) -> Bool {
        (scalar.value >= 48 && scalar.value <= 57)
            || (scalar.value >= 65 && scalar.value <= 90)
            || (scalar.value >= 97 && scalar.value <= 122)
    }

    private func finishIfStopped() {
        if !isRunning && recognitionTasks.isEmpty && request != nil {
            completeStop(timedOut: false)
        }
    }

    private func completeStop(timedOut: Bool) {
        let tasks = recognitionTasks.values.map(\.task)
        generation &+= 1
        clearSession()
        for task in tasks { task.cancel() }
        onStopped?(timedOut)
    }

    private func fail(_ error: Error) {
        let tasks = recognitionTasks.values.map(\.task)
        generation &+= 1
        clearSession()
        for task in tasks { task.cancel() }
        onError?(error)
    }

    private func clearSession() {
        isRunning = false
        usesOnDeviceRecognition = false
        rolloverTask?.cancel()
        rolloverTask = nil
        stopTimeoutTask?.cancel()
        stopTimeoutTask = nil
        recognitionTasks.removeAll()
        lastResults.removeAll()
        emittedResults.removeAll()
        completedTaskIDs.removeAll()
        activeTaskID = 0
        activeTaskStartedAt = nil
        nextEmissionTaskID = 1
        completedTranscriptPrefix = ""
        request = nil
        recognizer = nil
        converter = nil
        converterSourceFormat = nil
    }
}
