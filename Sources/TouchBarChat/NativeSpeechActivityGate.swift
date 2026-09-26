import AVFAudio
import CoreMedia
import Foundation
import SoundAnalysis

/// Semantic speech evidence from Apple's on-device sound classifier.
/// Feed it the PCM buffers already delivered by `SystemAudioCapture`. This
/// component never opens a microphone, stores audio, or decides turn endings.
@MainActor
final class NativeSpeechActivityGate {
    struct Evidence: Sendable {
        /// False while warming up, after an error, during analysis backlog, or
        /// when the last result is stale. Callers should then use their fallback.
        let isAvailable: Bool
        /// The most recent classification's speech confidence, if available.
        let speechConfidence: Double?
        /// Highest speech confidence during the recent evidence window.
        let recentSpeechConfidence: Double?
        let hasRecentSpeech: Bool
        /// Latches once speech crosses the threshold in this start/reset cycle.
        /// It remains true through a long silence; check `isAvailable` as well.
        let hasObservedSpeech: Bool
    }

    /// Delivered on the main actor whenever evidence or availability changes.
    var onEvidence: ((Evidence) -> Void)?
    /// A classifier failure affects only this auxiliary gate, not audio capture.
    var onFailure: ((Error) -> Void)?

    private let speechThreshold: Double
    private let recentWindow: TimeInterval
    private let resultFreshnessWindow: TimeInterval
    private let worker = NativeSpeechAnalysisWorker()

    private var generation: UInt64 = 0
    private var isRunning = false
    private var lastFormat: AVAudioFormat?
    private var nextFramePosition: AVAudioFramePosition = 0
    private var droppedUntilSeconds: Double?
    private var latestConfidence: Double?
    private var lastResultUptime: TimeInterval?
    private var recentResults: [(uptime: TimeInterval, confidence: Double)] = []
    private var observedSpeech = false

    init(
        speechThreshold: Double = 0.4,
        recentWindow: TimeInterval = 3,
        resultFreshnessWindow: TimeInterval = 4
    ) {
        self.speechThreshold = min(1, max(0, speechThreshold))
        self.recentWindow = max(0.1, recentWindow)
        self.resultFreshnessWindow = max(0.1, resultFreshnessWindow)
    }

    var evidence: Evidence {
        let now = ProcessInfo.processInfo.systemUptime
        let available =
            isRunning
            && droppedUntilSeconds == nil
            && lastResultUptime.map { now - $0 <= resultFreshnessWindow } == true
        let recentConfidence =
            available
            ? recentResults.lazy
                .filter { now - $0.uptime <= self.recentWindow }
                .map(\.confidence)
                .max()
            : nil
        return Evidence(
            isAvailable: available,
            speechConfidence: available ? latestConfidence : nil,
            recentSpeechConfidence: recentConfidence,
            hasRecentSpeech: recentConfidence.map { $0 >= speechThreshold } ?? false,
            hasObservedSpeech: observedSpeech
        )
    }

    func start() {
        guard !isRunning else { return }
        isRunning = true
        beginGeneration()
    }

    /// Invalidates prior results while keeping the gate ready for new PCM.
    func reset() {
        guard isRunning else {
            clearEvidence()
            onEvidence?(evidence)
            return
        }
        beginGeneration()
    }

    func stop() {
        guard isRunning else { return }
        let oldGeneration = generation
        generation &+= 1
        isRunning = false
        clearEvidence()
        worker.stop(generation: oldGeneration)
        onEvidence?(evidence)
    }

    /// Enqueues an owned PCM buffer without running inference on the UI thread.
    /// Returns false if stopped, invalid, or backpressured. A dropped buffer
    /// creates a time gap, so evidence stays unavailable until later results
    /// cover audio after that gap.
    @discardableResult
    func process(_ buffer: AVAudioPCMBuffer) -> Bool {
        guard isRunning else { return false }
        let frameCount = AVAudioFramePosition(buffer.frameLength)
        guard frameCount > 0,
            buffer.format.sampleRate.isFinite,
            buffer.format.sampleRate > 0,
            nextFramePosition <= AVAudioFramePosition.max - frameCount
        else {
            fail(NativeSpeechActivityError.invalidPCM)
            return false
        }

        if let lastFormat, !lastFormat.isEqual(buffer.format) {
            // Sound Analysis requires a new analyzer when the stream format changes.
            beginGeneration(preservingObservedSpeech: true)
        }
        lastFormat = buffer.format

        let position = nextFramePosition
        nextFramePosition += frameCount
        let accepted = worker.enqueue(
            ReadOnlyPCMBuffer(value: buffer),
            at: position,
            generation: generation
        )
        if !accepted {
            droppedUntilSeconds = Double(nextFramePosition) / buffer.format.sampleRate
            onEvidence?(evidence)
        }
        return accepted
    }

    private func beginGeneration(preservingObservedSpeech: Bool = false) {
        let priorSpeechEvidence = observedSpeech
        generation &+= 1
        clearEvidence()
        if preservingObservedSpeech { observedSpeech = priorSpeechEvidence }
        let currentGeneration = generation
        worker.start(generation: currentGeneration) { [weak self] event in
            Task { @MainActor [weak self] in
                self?.receive(event, generation: currentGeneration)
            }
        }
        onEvidence?(evidence)
    }

    private func clearEvidence() {
        lastFormat = nil
        nextFramePosition = 0
        droppedUntilSeconds = nil
        latestConfidence = nil
        lastResultUptime = nil
        recentResults.removeAll(keepingCapacity: true)
        observedSpeech = false
    }

    private func receive(_ event: NativeSpeechAnalysisEvent, generation resultGeneration: UInt64) {
        guard isRunning, generation == resultGeneration else { return }
        switch event {
        case .result(let confidence, let endSeconds):
            if let droppedUntilSeconds {
                guard endSeconds.isFinite, endSeconds >= droppedUntilSeconds else { return }
                self.droppedUntilSeconds = nil
                // Results before this point could describe audio before the gap.
                recentResults.removeAll(keepingCapacity: true)
            }
            let now = ProcessInfo.processInfo.systemUptime
            let boundedConfidence = min(1, max(0, confidence))
            latestConfidence = boundedConfidence
            lastResultUptime = now
            recentResults.append((now, boundedConfidence))
            recentResults.removeAll { now - $0.uptime > recentWindow }
            if boundedConfidence >= speechThreshold { observedSpeech = true }
            onEvidence?(evidence)
        case .failed(let message):
            fail(NativeSpeechActivityError.analysisFailed(message))
        }
    }

    private func fail(_ error: NativeSpeechActivityError) {
        let oldGeneration = generation
        generation &+= 1
        isRunning = false
        clearEvidence()
        worker.stop(generation: oldGeneration)
        onEvidence?(evidence)
        onFailure?(error)
    }
}

private enum NativeSpeechActivityError: LocalizedError {
    case invalidPCM
    case missingSpeechClassification
    case analysisFailed(String)

    var errorDescription: String? {
        switch self {
        case .invalidPCM:
            L10n.text("系统音频 PCM 缓冲区无效，语音分类已停用。")
        case .missingSpeechClassification:
            L10n.text("当前系统声音分类器没有 speech 类别，语音分类已停用。")
        case .analysisFailed(let message):
            // The underlying SoundAnalysis text is system-provided; only
            // our framing can be translated by app-owned resources.
            L10n.text("系统声音分类失败：%@", message)
        }
    }
}

private enum NativeSpeechAnalysisEvent: Sendable {
    case result(confidence: Double, endSeconds: Double)
    case failed(String)
}

/// `SystemAudioCapture` creates an owned buffer before calling its consumers.
/// We only read it on the serial analysis queue; other consumers must not
/// mutate its bytes after passing it here.
private struct ReadOnlyPCMBuffer: @unchecked Sendable {
    let value: AVAudioPCMBuffer
}

/// All mutable fields below are confined to `queue`. The semaphore's immediate
/// try-wait bounds queued PCM without blocking the main actor.
private final class NativeSpeechAnalysisWorker: @unchecked Sendable {
    private let queue = DispatchQueue(label: "dev.touchbarchat.native-speech-analysis", qos: .userInitiated)
    private let pendingBuffers = DispatchSemaphore(value: 3)
    private var generation: UInt64 = 0
    private var emit: (@Sendable (NativeSpeechAnalysisEvent) -> Void)?
    private var analyzer: SNAudioStreamAnalyzer?
    private var request: SNClassifySoundRequest?
    private var observer: NativeSpeechResultsObserver?
    private var format: AVAudioFormat?
    private var failed = false

    func start(
        generation: UInt64,
        emit: @escaping @Sendable (NativeSpeechAnalysisEvent) -> Void
    ) {
        queue.async {
            self.tearDown()
            self.generation = generation
            self.emit = emit
            self.failed = false
        }
    }

    func stop(generation: UInt64) {
        queue.async {
            guard self.generation == generation else { return }
            self.tearDown()
            self.emit = nil
            self.failed = true
        }
    }

    func enqueue(
        _ buffer: ReadOnlyPCMBuffer,
        at position: AVAudioFramePosition,
        generation: UInt64
    ) -> Bool {
        guard pendingBuffers.wait(timeout: .now()) == .success else { return false }
        queue.async {
            defer { self.pendingBuffers.signal() }
            guard self.generation == generation, !self.failed else { return }
            do {
                try self.configureIfNeeded(for: buffer.value.format)
                self.analyzer?.analyze(buffer.value, atAudioFramePosition: position)
            } catch {
                self.failed = true
                self.emit?(.failed(error.localizedDescription))
                self.tearDown()
            }
        }
        return true
    }

    private func configureIfNeeded(for inputFormat: AVAudioFormat) throws {
        if let format, format.isEqual(inputFormat), analyzer != nil { return }
        tearDown()
        let request = try SNClassifySoundRequest(classifierIdentifier: .version1)
        guard request.knownClassifications.contains("speech") else {
            throw NativeSpeechActivityError.missingSpeechClassification
        }
        guard let emit else {
            throw NativeSpeechActivityError.analysisFailed(L10n.text("分析器未启动"))
        }
        let observer = NativeSpeechResultsObserver(emit: emit)
        let analyzer = SNAudioStreamAnalyzer(format: inputFormat)
        try analyzer.add(request, withObserver: observer)
        self.format = inputFormat
        self.request = request
        self.observer = observer  // The analyzer retains its observer weakly.
        self.analyzer = analyzer
    }

    private func tearDown() {
        analyzer?.removeAllRequests()
        analyzer = nil
        request = nil
        observer = nil
        format = nil
    }
}

private final class NativeSpeechResultsObserver: NSObject, SNResultsObserving {
    private let emit: @Sendable (NativeSpeechAnalysisEvent) -> Void

    init(emit: @escaping @Sendable (NativeSpeechAnalysisEvent) -> Void) {
        self.emit = emit
    }

    func request(_ request: any SNRequest, didProduce result: any SNResult) {
        guard let result = result as? SNClassificationResult else { return }
        // The built-in model exposes the exact technical label "speech".
        // A missing candidate means no speech evidence in this result.
        let confidence = result.classification(forIdentifier: "speech")?.confidence ?? 0
        let endSeconds = CMTimeGetSeconds(CMTimeRangeGetEnd(result.timeRange))
        emit(.result(confidence: confidence, endSeconds: endSeconds))
    }

    func request(_ request: any SNRequest, didFailWithError error: any Error) {
        emit(.failed(error.localizedDescription))
    }
}
