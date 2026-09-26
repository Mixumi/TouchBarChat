import AVFAudio
import Darwin
import Foundation
import Speech

/// A developer-only, repeatable test of the selected recognition path. It
/// synthesizes a fixed phrase in memory; it never reads the microphone or
/// system audio, and never creates an interview or writes an audio file.
@MainActor
enum SpeechSelfTest {
    private static let expected = "请介绍你最近负责的项目，以及遇到的最大挑战。你如何解决这个问题？"

    static func run() async -> Int32 {
        print("speech-self-test: authorization-before=\(authorizationName(SFSpeechRecognizer.authorizationStatus()))")
        print("speech-self-test: expected=\(expected)")
        if #available(macOS 26.0, *) {
            let locale = Locale(identifier: "zh-CN")
            let supported = await SpeechTranscriber.supportedLocale(equivalentTo: locale)
            let installed = await SpeechTranscriber.installedLocales
            print("speech-self-test: speech-analyzer-available=\(SpeechTranscriber.isAvailable)")
            print("speech-self-test: speech-analyzer-zh-locale=\(supported?.identifier ?? "unsupported")")
            print(
                "speech-self-test: speech-analyzer-installed-locales=\(installed.map(\.identifier).joined(separator: ","))"
            )
        }

        guard let voice = AVSpeechSynthesisVoice(language: "zh-CN") else {
            print("speech-self-test: error=No Mandarin synthesis voice is installed")
            return EXIT_FAILURE
        }

        let collector = SynthesizedAudioCollector()
        let synthesizer = AVSpeechSynthesizer()
        synthesizer.delegate = collector
        let utterance = AVSpeechUtterance(string: expected)
        utterance.voice = voice
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate
        synthesizer.write(utterance) { [collector] buffer in
            collector.receive(buffer)
        }

        // The buffer callback may arrive asynchronously. The delegate and the
        // zero-frame completion buffer both signal the end of synthesis.
        var synthesized: SynthesizedAudioCollector.Result?
        for _ in 0..<600 {
            if let result = collector.resultIfComplete() {
                synthesized = result
                break
            }
            try? await Task.sleep(for: .milliseconds(50))
        }
        guard let synthesized else {
            synthesizer.stopSpeaking(at: .immediate)
            print("speech-self-test: error=Synthesis did not finish within 30 seconds")
            return EXIT_FAILURE
        }
        if let error = synthesized.error {
            print("speech-self-test: error=\(error)")
            return EXIT_FAILURE
        }
        guard !synthesized.buffers.isEmpty else {
            print("speech-self-test: error=Synthesis produced no PCM audio")
            return EXIT_FAILURE
        }
        let sourceFrames = synthesized.buffers.reduce(UInt64(0)) { $0 + UInt64($1.frameLength) }
        let sourceRates = Set(synthesized.buffers.map { $0.format.sampleRate }).sorted()
        print("speech-self-test: source-rates=\(sourceRates.map { String($0) }.joined(separator: ","))")
        print("speech-self-test: source-frames=\(sourceFrames)")

        let captureLikeBuffers: [AVAudioPCMBuffer]
        do {
            captureLikeBuffers = try CaptureLikeTestAudio.convert(synthesized.buffers)
        } catch {
            print("speech-self-test: error=Unable to create 48 kHz mono test audio: \(error.localizedDescription)")
            return EXIT_FAILURE
        }
        let fedFrames = captureLikeBuffers.reduce(UInt64(0)) { $0 + UInt64($1.frameLength) }
        print("speech-self-test: fed-rate=48000 channels=1 fed-frames=\(fedFrames) packets=\(captureLikeBuffers.count)")

        let transcriber = LocalSpeechTranscriber(locale: Locale(identifier: "zh-CN"))
        var recognized = ""
        var lastIsFinal = false
        var stopped = false
        var timedOut = false
        var recognitionError: Error?
        transcriber.onTranscription = { text, isFinal in
            recognized = text
            lastIsFinal = isFinal
        }
        transcriber.onStopped = { didTimeOut in
            timedOut = didTimeOut
            stopped = true
        }
        transcriber.onError = { error in
            recognitionError = error
        }

        do {
            try await transcriber.start()
        } catch {
            print(
                "speech-self-test: authorization-after=\(authorizationName(SFSpeechRecognizer.authorizationStatus()))")
            print("speech-self-test: error=\(error.localizedDescription)")
            return EXIT_FAILURE
        }
        let recognitionMode =
            transcriber.usesModernRecognition
            ? "SpeechAnalyzer on-device" : "SFSpeechRecognizer on-device"
        print("speech-self-test: authorization-after=\(authorizationName(SFSpeechRecognizer.authorizationStatus()))")
        print("speech-self-test: recognition-mode=\(recognitionMode)")

        var suppliedFrames: UInt64 = 0
        for buffer in captureLikeBuffers {
            guard buffer.format.sampleRate.isFinite, buffer.format.sampleRate > 0 else {
                transcriber.cancel()
                print("speech-self-test: error=Synthesized PCM has an invalid sample rate")
                return EXIT_FAILURE
            }
            transcriber.append(buffer)
            suppliedFrames += UInt64(buffer.frameLength)
            // Offline synthesis may emit faster than playback. Feed its chunks
            // at their actual audio duration so the live recognizer sees the
            // same cadence as ScreenCaptureKit, with no artificial truncation.
            let duration = Double(buffer.frameLength) / buffer.format.sampleRate
            let nanoseconds = UInt64(min(duration * 1_000_000_000, Double(UInt64.max)))
            if nanoseconds > 0 {
                try? await Task.sleep(nanoseconds: nanoseconds)
            }
            if recognitionError != nil { break }
        }

        if recognitionError == nil {
            transcriber.stop()  // Drains the selected local engine's final result.
            for _ in 0..<700 where !stopped && recognitionError == nil {
                try? await Task.sleep(for: .milliseconds(50))
            }
        }
        if !stopped { transcriber.cancel() }

        print("speech-self-test: supplied-frames=\(suppliedFrames)")
        print("speech-self-test: recognized=\(recognized)")
        print("speech-self-test: is-final=\(lastIsFinal) timed-out=\(timedOut || !stopped)")
        if let recognitionError {
            print("speech-self-test: error=\(recognitionError.localizedDescription)")
            return EXIT_FAILURE
        }
        return stopped && !recognized.isEmpty ? EXIT_SUCCESS : EXIT_FAILURE
    }

    private static func authorizationName(_ value: SFSpeechRecognizerAuthorizationStatus) -> String {
        switch value {
        case .authorized: "authorized"
        case .denied: "denied"
        case .restricted: "restricted"
        case .notDetermined: "not-determined"
        @unknown default: "unknown"
        }
    }
}

private final class SynthesizedAudioCollector: NSObject, AVSpeechSynthesizerDelegate, @unchecked Sendable {
    struct Result {
        let buffers: [AVAudioPCMBuffer]
        let error: String?
    }

    private let lock = NSLock()
    private var buffers: [AVAudioPCMBuffer] = []
    private var complete = false
    private var error: String?

    func receive(_ audioBuffer: AVAudioBuffer) {
        lock.lock()
        defer { lock.unlock() }
        guard !complete else { return }
        guard let source = audioBuffer as? AVAudioPCMBuffer else {
            error = "Synthesis returned a non-PCM buffer"
            complete = true
            return
        }
        if source.frameLength == 0 {
            complete = true
            return
        }
        guard let owned = Self.makeOwnedCopy(of: source) else {
            error = "Unable to copy synthesized PCM"
            complete = true
            return
        }
        buffers.append(owned)
    }

    func resultIfComplete() -> Result? {
        lock.lock()
        defer { lock.unlock() }
        guard complete else { return nil }
        return Result(buffers: buffers, error: error)
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        lock.lock()
        complete = true
        lock.unlock()
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        lock.lock()
        error = "Synthesis was cancelled"
        complete = true
        lock.unlock()
    }

    private static func makeOwnedCopy(of source: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        guard
            let destination = AVAudioPCMBuffer(
                pcmFormat: source.format,
                frameCapacity: source.frameLength
            )
        else { return nil }
        destination.frameLength = source.frameLength
        let input = UnsafeMutableAudioBufferListPointer(source.mutableAudioBufferList)
        let output = UnsafeMutableAudioBufferListPointer(destination.mutableAudioBufferList)
        guard input.count == output.count else { return nil }
        for index in input.indices {
            guard let inputData = input[index].mData,
                let outputData = output[index].mData,
                input[index].mDataByteSize <= output[index].mDataByteSize
            else { return nil }
            memcpy(outputData, inputData, Int(input[index].mDataByteSize))
            output[index].mDataByteSize = input[index].mDataByteSize
        }
        return destination
    }
}

/// Turns the synthesizer's native format into small, independent 48 kHz mono
/// Float32 PCM packets. This is only used by the developer self-test and keeps
/// the audio entirely in memory; 960 frames correspond to 20 ms of playback.
private enum CaptureLikeTestAudio {
    private enum ConversionError: LocalizedError {
        case invalidSource
        case converterUnavailable
        case conversionFailed

        var errorDescription: String? {
            switch self {
            case .invalidSource: "The synthesized audio format is invalid."
            case .converterUnavailable: "AVAudioConverter could not be created."
            case .conversionFailed: "AVAudioConverter could not produce PCM."
            }
        }
    }

    private final class Input: @unchecked Sendable {
        private let source: AVAudioPCMBuffer?
        private let finishing: Bool
        private var delivered = false

        init(source: AVAudioPCMBuffer?, finishing: Bool) {
            self.source = source
            self.finishing = finishing
        }

        func next(status: UnsafeMutablePointer<AVAudioConverterInputStatus>) -> AVAudioBuffer? {
            if let source, !delivered {
                delivered = true
                status.pointee = .haveData
                return source
            }
            status.pointee = finishing ? .endOfStream : .noDataNow
            return nil
        }
    }

    static func convert(_ sources: [AVAudioPCMBuffer]) throws -> [AVAudioPCMBuffer] {
        guard let target = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1) else {
            throw ConversionError.converterUnavailable
        }
        var allSamples: [Float] = []
        var converter: AVAudioConverter?
        var sourceFormat: AVAudioFormat?

        func pump(_ active: AVAudioConverter, source: AVAudioPCMBuffer?, finishing: Bool) throws {
            let capacity: AVAudioFrameCount
            if let source {
                let sourceRate = source.format.sampleRate
                guard sourceRate.isFinite, sourceRate > 0 else {
                    throw ConversionError.invalidSource
                }
                let estimate = ceil(Double(source.frameLength) * 48_000 / sourceRate) + 4096
                guard estimate.isFinite, estimate < Double(UInt32.max) else {
                    throw ConversionError.invalidSource
                }
                capacity = AVAudioFrameCount(max(4096, estimate))
            } else {
                capacity = 4096
            }
            let input = Input(source: source, finishing: finishing)
            for _ in 0..<64 {
                guard let output = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity) else {
                    throw ConversionError.conversionFailed
                }
                var conversionError: NSError?
                let status = active.convert(to: output, error: &conversionError) { _, inputStatus in
                    input.next(status: inputStatus)
                }
                guard status != .error, conversionError == nil,
                    let channel = output.floatChannelData?[0]
                else {
                    throw conversionError ?? ConversionError.conversionFailed
                }
                if output.frameLength > 0 {
                    allSamples.append(
                        contentsOf: UnsafeBufferPointer(
                            start: channel,
                            count: Int(output.frameLength)
                        ))
                }
                if status == .endOfStream || output.frameLength == 0
                    || (status == .inputRanDry && !finishing)
                {
                    return
                }
            }
            throw ConversionError.conversionFailed
        }

        for source in sources where source.frameLength > 0 {
            if converter == nil || sourceFormat != source.format {
                if let converter { try pump(converter, source: nil, finishing: true) }
                converter = AVAudioConverter(from: source.format, to: target)
                sourceFormat = source.format
            }
            guard let converter else { throw ConversionError.converterUnavailable }
            try pump(converter, source: source, finishing: false)
        }
        if let converter { try pump(converter, source: nil, finishing: true) }
        guard !allSamples.isEmpty else { throw ConversionError.conversionFailed }

        let packetFrames = 960
        var packets: [AVAudioPCMBuffer] = []
        var offset = 0
        while offset < allSamples.count {
            let count = min(packetFrames, allSamples.count - offset)
            guard
                let packet = AVAudioPCMBuffer(
                    pcmFormat: target,
                    frameCapacity: AVAudioFrameCount(count)
                ), let channel = packet.floatChannelData?[0]
            else {
                throw ConversionError.conversionFailed
            }
            packet.frameLength = AVAudioFrameCount(count)
            allSamples.withUnsafeBufferPointer { source in
                channel.update(from: source.baseAddress!.advanced(by: offset), count: count)
            }
            packets.append(packet)
            offset += count
        }
        return packets
    }
}
