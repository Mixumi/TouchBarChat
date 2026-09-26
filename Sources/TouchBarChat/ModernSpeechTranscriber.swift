import AVFoundation
import CoreMedia
import Foundation
import Speech

@available(macOS 26.0, *)
enum ModernSpeechTranscriberError: LocalizedError {
    case alreadyRunning
    case cancelled
    case unsupportedLocale
    case modelUnavailable
    case audioFormatUnavailable
    case audioConversionFailed

    var errorDescription: String? {
        switch self {
        case .alreadyRunning:
            return L10n.text("语音识别已经在运行。")
        case .cancelled:
            return L10n.text("语音识别启动已取消。")
        case .unsupportedLocale:
            return L10n.text("这台 Mac 不支持所选语言的新版本地语音识别。")
        case .modelUnavailable:
            return L10n.text("无法安装所选语言的本地语音模型。请连接网络完成系统模型下载，并确认有足够的存储空间后重试。")
        case .audioFormatUnavailable:
            return L10n.text("无法取得本地语音模型需要的音频格式。")
        case .audioConversionFailed:
            return L10n.text("无法把电脑播放的音频转换为本地语音模型需要的格式。")
        }
    }
}

/// AVAudioConverter may ask for the input more than once during one synchronous
/// conversion. The buffer remains owned by the caller until conversion returns.
@available(macOS 26.0, *)
private final class ModernAudioInput: @unchecked Sendable {
    private let buffer: AVAudioPCMBuffer?
    private let endOfStream: Bool
    private var delivered = false

    init(buffer: AVAudioPCMBuffer?, endOfStream: Bool) {
        self.buffer = buffer
        self.endOfStream = endOfStream
    }

    func next(status: UnsafeMutablePointer<AVAudioConverterInputStatus>) -> AVAudioBuffer? {
        if let buffer, !delivered {
            delivered = true
            status.pointee = .haveData
            return buffer
        }
        status.pointee = endOfStream ? .endOfStream : .noDataNow
        return nil
    }
}

/// SpeechAnalyzer's results are ranges of audio, not whole-session strings.
/// Replace provisional ranges as the model refines them and never concatenate
/// the same provisional phrase twice.
@available(macOS 26.0, *)
private struct ModernSpeechFragment {
    let range: CMTimeRange
    let text: String
    let isFinal: Bool

    func overlaps(_ other: ModernSpeechFragment) -> Bool {
        if CMTimeCompare(range.start, other.range.start) == 0,
            CMTimeCompare(CMTimeRangeGetEnd(range), CMTimeRangeGetEnd(other.range)) == 0
        {
            return true
        }
        let common = CMTimeRangeGetIntersection(range, otherRange: other.range)
        return common.isValid && CMTimeCompare(common.duration, .zero) > 0
    }
}

/// Runs Apple's newer, entirely on-device SpeechTranscriber for a continuous
/// stream of ScreenCaptureKit PCM. No audio is retained after conversion and
/// the session is not split at the legacy recognizer's one-minute boundary.
@available(macOS 26.0, *)
@MainActor
final class ModernSpeechTranscriber {
    var onTranscription: ((String, Bool) -> Void)?
    var onError: ((Error) -> Void)?
    var onStopped: ((Bool) -> Void)?

    private(set) var isRunning = false
    let usesOnDeviceRecognition = true

    private let requestedLocale: Locale
    private var isStarting = false
    private var isFinishing = false
    private var generation: UInt64 = 0
    private var analyzer: SpeechAnalyzer?
    private var transcriber: SpeechTranscriber?
    private var analyzerFormat: AVAudioFormat?
    private var inputBuilder: AsyncStream<AnalyzerInput>.Continuation?
    private var resultsTask: Task<Void, Never>?
    private var finalizationTask: Task<Void, Never>?
    private var stopTimeoutTask: Task<Void, Never>?
    private var converter: AVAudioConverter?
    private var converterSourceFormat: AVAudioFormat?
    private var fragments: [ModernSpeechFragment] = []
    private var lastEmission: (text: String, isFinal: Bool)?
    private var conversionFailedDuringStop = false

    init(locale: Locale = Locale(identifier: "zh-CN")) {
        requestedLocale = locale
    }

    static func supports(_ locale: Locale) async -> Bool {
        guard SpeechTranscriber.isAvailable else { return false }
        return await SpeechTranscriber.supportedLocale(equivalentTo: locale) != nil
    }

    func start() async throws {
        guard !isStarting, analyzer == nil else {
            throw ModernSpeechTranscriberError.alreadyRunning
        }
        isStarting = true
        let startGeneration = generation
        defer { isStarting = false }

        guard SpeechTranscriber.isAvailable,
            let locale = await SpeechTranscriber.supportedLocale(equivalentTo: requestedLocale)
        else {
            throw ModernSpeechTranscriberError.unsupportedLocale
        }
        try checkStartupGeneration(startGeneration)

        // The progressive preset also enables .fastResults. Apple documents
        // that option as trading accuracy for speed, so request only volatile
        // (replaceable) interim results and the normal accurate final result.
        let module = SpeechTranscriber(
            locale: locale,
            transcriptionOptions: [],
            reportingOptions: [.volatileResults],
            attributeOptions: []
        )
        let status = await AssetInventory.status(forModules: [module])
        try checkStartupGeneration(startGeneration)
        guard status != .unsupported else {
            // A locale can be supported by the API but still lack a usable
            // installable on-device model on this specific Mac.
            throw ModernSpeechTranscriberError.modelUnavailable
        }
        if status != .installed {
            do {
                if let installation = try await AssetInventory.assetInstallationRequest(supporting: [module]) {
                    try await installation.downloadAndInstall()
                }
            } catch {
                try checkStartupGeneration(startGeneration)
                throw ModernSpeechTranscriberError.modelUnavailable
            }
        }
        try checkStartupGeneration(startGeneration)
        guard await AssetInventory.status(forModules: [module]) == .installed else {
            throw ModernSpeechTranscriberError.modelUnavailable
        }

        // Keep ASR independent. SpeechDetector in this analyzer would gate
        // transcription, while its current results stream supplies no VAD
        // events; a detector-only analyzer crashes on macOS 26.7.
        let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [module])
        guard let format else {
            throw ModernSpeechTranscriberError.audioFormatUnavailable
        }
        try checkStartupGeneration(startGeneration)

        let analyzer = SpeechAnalyzer(modules: [module])
        let (input, builder) = AsyncStream.makeStream(of: AnalyzerInput.self)
        self.analyzer = analyzer
        self.transcriber = module
        analyzerFormat = format
        inputBuilder = builder
        do {
            // Warm the local model before ScreenCaptureKit starts delivering
            // packets, so the interviewer's first words are not raced by
            // model startup.
            try await analyzer.prepareToAnalyze(in: format)
            try checkStartupGeneration(startGeneration)
            try await analyzer.start(inputSequence: input)
            try checkStartupGeneration(startGeneration)
            isRunning = true
            resultsTask = Task { [weak self] in
                do {
                    for try await result in module.results {
                        self?.receive(result, generation: startGeneration)
                    }
                } catch {
                    self?.handleResultFailure(error, generation: startGeneration)
                }
            }
        } catch {
            if generation == startGeneration {
                discardSession()
            }
            await analyzer.cancelAndFinishNow()
            throw error
        }
    }

    /// Called serially on the main actor. A converted buffer is never mutated
    /// after being yielded to SpeechAnalyzer, preserving PCM order.
    func append(_ buffer: AVAudioPCMBuffer) {
        guard isRunning, buffer.frameLength > 0 else { return }
        do {
            try convertAndYield(buffer)
        } catch {
            fail(error)
        }
    }

    func rolloverIfQuiet(silenceDuration: TimeInterval) {
        // SpeechAnalyzer supports a continuous session; splitting here would
        // discard language context and can clip words at the join.
    }

    func stop() {
        guard isRunning, !isFinishing, let analyzer else { return }
        isRunning = false
        isFinishing = true
        let stopGeneration = generation
        do {
            try flushConverter()
        } catch {
            conversionFailedDuringStop = true
            onError?(error)
        }
        inputBuilder?.finish()
        inputBuilder = nil

        finalizationTask = Task { [weak self] in
            do {
                try await analyzer.finalizeAndFinishThroughEndOfInput()
                // finalize publishes results; wait for our consumer to read
                // them before notifying the store that the drain is complete.
                await self?.resultsTask?.value
                self?.completeStop(generation: stopGeneration, timedOut: false)
            } catch {
                self?.handleFinalizationFailure(error, generation: stopGeneration)
            }
        }
        stopTimeoutTask = Task { [weak self] in
            // Long meetings can leave a short processing backlog. Give the
            // local model time to emit the final tail before abandoning it.
            try? await Task.sleep(for: .seconds(30))
            guard !Task.isCancelled else { return }
            self?.completeStop(generation: stopGeneration, timedOut: true)
        }
    }

    func cancel() {
        let oldAnalyzer = analyzer
        generation &+= 1
        discardSession()
        if let oldAnalyzer {
            Task { await oldAnalyzer.cancelAndFinishNow() }
        }
    }

    private func checkStartupGeneration(_ expected: UInt64) throws {
        guard generation == expected, !Task.isCancelled else {
            throw ModernSpeechTranscriberError.cancelled
        }
    }

    private func convertAndYield(_ source: AVAudioPCMBuffer) throws {
        guard let format = analyzerFormat else {
            throw ModernSpeechTranscriberError.audioFormatUnavailable
        }
        if source.format == format {
            inputBuilder?.yield(AnalyzerInput(buffer: source))
            return
        }
        if converter == nil || converterSourceFormat != source.format {
            try flushConverter()
            converter = AVAudioConverter(from: source.format, to: format)
            converterSourceFormat = source.format
        }
        guard let converter else {
            throw ModernSpeechTranscriberError.audioConversionFailed
        }
        let sourceRate = source.format.sampleRate
        let destinationRate = format.sampleRate
        guard sourceRate.isFinite, destinationRate.isFinite,
            sourceRate > 0, destinationRate > 0
        else {
            throw ModernSpeechTranscriberError.audioConversionFailed
        }
        let estimated = ceil(Double(source.frameLength) * destinationRate / sourceRate) + 4096
        guard estimated.isFinite, estimated < Double(UInt32.max) else {
            throw ModernSpeechTranscriberError.audioConversionFailed
        }
        try pump(
            converter, source: source, endOfStream: false,
            frameCapacity: AVAudioFrameCount(max(4096, estimated)))
    }

    private func flushConverter() throws {
        guard let converter else { return }
        try pump(converter, source: nil, endOfStream: true, frameCapacity: 4096)
        self.converter = nil
        converterSourceFormat = nil
    }

    private func pump(
        _ converter: AVAudioConverter, source: AVAudioPCMBuffer?,
        endOfStream: Bool, frameCapacity: AVAudioFrameCount
    ) throws {
        guard let format = analyzerFormat else {
            throw ModernSpeechTranscriberError.audioFormatUnavailable
        }
        let provider = ModernAudioInput(buffer: source, endOfStream: endOfStream)
        // Normal packets fit in one conversion. Extra rounds drain a converter
        // that emitted only part of a packet or retained resampling tail data.
        for _ in 0..<32 {
            guard let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCapacity) else {
                throw ModernSpeechTranscriberError.audioConversionFailed
            }
            var conversionError: NSError?
            let status = converter.convert(to: output, error: &conversionError) { _, inputStatus in
                provider.next(status: inputStatus)
            }
            guard status != .error, conversionError == nil else {
                throw conversionError ?? ModernSpeechTranscriberError.audioConversionFailed
            }
            if output.frameLength > 0 {
                inputBuilder?.yield(AnalyzerInput(buffer: output))
            }
            if status == .endOfStream || output.frameLength == 0
                || (status == .inputRanDry && !endOfStream)
            {
                return
            }
        }
        throw ModernSpeechTranscriberError.audioConversionFailed
    }

    private func receive(_ result: SpeechTranscriber.Result, generation expected: UInt64) {
        guard expected == generation, isRunning || isFinishing else { return }
        let text = String(result.text.characters).trimmingCharacters(in: .whitespacesAndNewlines)
        let incoming = ModernSpeechFragment(range: result.range, text: text, isFinal: result.isFinal)

        // The model can make an earlier volatile result final without sending
        // it again. Finalization time is authoritative for all older ranges.
        fragments = fragments.map { fragment in
            let hasFinalized =
                result.resultsFinalizationTime.isValid
                && CMTimeCompare(
                    CMTimeRangeGetEnd(fragment.range), result.resultsFinalizationTime
                ) <= 0
            return ModernSpeechFragment(
                range: fragment.range,
                text: fragment.text,
                isFinal: fragment.isFinal || hasFinalized
            )
        }

        if incoming.isFinal {
            // A finalized phrase replaces every provisional interpretation of
            // that audio. Exact duplicate final callbacks are also replaced.
            fragments.removeAll { $0.overlaps(incoming) }
        } else {
            // Never let a late volatile guess replace already-finalized text.
            guard !fragments.contains(where: { $0.isFinal && $0.overlaps(incoming) }) else {
                emitFragments()
                return
            }
            fragments.removeAll { !$0.isFinal && $0.overlaps(incoming) }
        }
        // An empty result revokes the previous volatile interpretation of its
        // audio range; it is not a phrase to append to the transcript.
        if !text.isEmpty {
            fragments.append(incoming)
        }
        fragments.sort { CMTimeCompare($0.range.start, $1.range.start) < 0 }

        emitFragments()
    }

    private func emitFragments() {
        let assembled = fragments.reduce(into: "") { result, fragment in
            result = Self.join(result, fragment.text)
        }
        let isFullyFinal = fragments.allSatisfy(\.isFinal)
        if lastEmission?.text != assembled || lastEmission?.isFinal != isFullyFinal {
            lastEmission = (assembled, isFullyFinal)
            onTranscription?(assembled, isFullyFinal)
        }
    }

    private static func join(_ prefix: String, _ part: String) -> String {
        guard !prefix.isEmpty else { return part }
        let first = part.unicodeScalars.first
        let last = prefix.unicodeScalars.last
        let asciiWordBoundary = first.map(Self.isASCIIWord) == true && last.map(Self.isASCIIWord) == true
        return prefix + (asciiWordBoundary ? " " : "") + part
    }

    private static func isASCIIWord(_ scalar: UnicodeScalar) -> Bool {
        (48...57).contains(scalar.value) || (65...90).contains(scalar.value)
            || (97...122).contains(scalar.value)
    }

    private func handleResultFailure(_ error: Error, generation expected: UInt64) {
        guard expected == generation else { return }
        if isFinishing {
            onError?(error)
            completeStop(generation: expected, timedOut: true)
        } else if isRunning {
            fail(error)
        }
    }

    private func handleFinalizationFailure(_ error: Error, generation expected: UInt64) {
        guard expected == generation, isFinishing else { return }
        onError?(error)
        completeStop(generation: expected, timedOut: true)
    }

    private func completeStop(generation expected: UInt64, timedOut: Bool) {
        guard expected == generation, isFinishing else { return }
        let oldAnalyzer = analyzer
        let wasIncomplete = timedOut || conversionFailedDuringStop
        generation &+= 1
        discardSession()
        if timedOut, let oldAnalyzer {
            Task { await oldAnalyzer.cancelAndFinishNow() }
        }
        onStopped?(wasIncomplete)
    }

    private func fail(_ error: Error) {
        let oldAnalyzer = analyzer
        generation &+= 1
        discardSession()
        if let oldAnalyzer {
            Task { await oldAnalyzer.cancelAndFinishNow() }
        }
        onError?(error)
    }

    private func discardSession() {
        isRunning = false
        isFinishing = false
        inputBuilder?.finish()
        inputBuilder = nil
        resultsTask?.cancel()
        resultsTask = nil
        finalizationTask?.cancel()
        finalizationTask = nil
        stopTimeoutTask?.cancel()
        stopTimeoutTask = nil
        analyzer = nil
        transcriber = nil
        analyzerFormat = nil
        converter = nil
        converterSourceFormat = nil
        fragments.removeAll()
        lastEmission = nil
        conversionFailedDuringStop = false
    }
}
