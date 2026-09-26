import AVFAudio
import CoreMedia
import ScreenCaptureKit

/// Captures the Mac's playback audio, not the microphone. A display is only
/// used as ScreenCaptureKit's content-filter anchor; no video output is added.
@MainActor
final class SystemAudioCapture: NSObject {
    var onAudioBuffer: ((AVAudioPCMBuffer) -> Void)?
    var onAudioActivity: ((AudioCaptureActivity) -> Void)?
    var onFailure: ((Error) -> Void)?

    private var stream: SCStream?
    private var stopTask: Task<Void, Never>?
    private let sampleQueue = DispatchQueue(label: "dev.touchbarchat.system-audio")
    private var audioPacketCount = 0
    private var lastSignalTime: Date?
    private var lastActivityReport = Date.distantPast
    private var reportPeak: Float?

    var isCapturing: Bool { stream != nil }

    func start() async throws {
        guard stream == nil else { return }

        let available = try await SCShareableContent.excludingDesktopWindows(
            false,
            onScreenWindowsOnly: true
        )
        guard let display = available.displays.first else {
            throw CaptureError.noDisplay
        }

        let filter = SCContentFilter(
            display: display,
            excludingApplications: [],
            exceptingWindows: []
        )
        let configuration = SCStreamConfiguration()
        configuration.capturesAudio = true
        configuration.excludesCurrentProcessAudio = true
        configuration.sampleRate = 48_000
        configuration.channelCount = 1
        configuration.width = 64
        configuration.height = 64
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: 1)
        configuration.queueDepth = 3

        let newStream = SCStream(filter: filter, configuration: configuration, delegate: self)
        try newStream.addStreamOutput(self, type: .audio, sampleHandlerQueue: sampleQueue)
        audioPacketCount = 0
        lastSignalTime = nil
        lastActivityReport = .distantPast
        reportPeak = nil
        stream = newStream
        do {
            try await newStream.startCapture()
        } catch {
            if stream === newStream { stream = nil }
            throw error
        }
        guard stream === newStream else { throw CaptureError.streamStopped }
    }

    func stop() async {
        if let stopTask {
            await stopTask.value
            return
        }
        guard let current = stream else { return }
        let task = Task { [self] in
            try? await current.stopCapture()
            // The sample handler runs on a serial queue and delivers owned buffers
            // to the main queue in that same order. Wait for its queue barrier and
            // the corresponding main-queue barrier before invalidating the stream;
            // otherwise the last packets are silently discarded on pause/end.
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                sampleQueue.async {
                    DispatchQueue.main.async {
                        continuation.resume()
                    }
                }
            }
            if stream === current { stream = nil }
        }
        stopTask = task
        await task.value
        stopTask = nil
    }

    nonisolated static func makeOwnedPCMBuffer(from sampleBuffer: CMSampleBuffer) -> AVAudioPCMBuffer? {
        guard var description = sampleBuffer.formatDescription?.audioStreamBasicDescription,
            let format = AVAudioFormat(streamDescription: &description)
        else { return nil }

        let sampleCount = sampleBuffer.numSamples
        guard sampleCount > 0,
            sampleCount <= Int(UInt32.max),
            let destination = AVAudioPCMBuffer(
                pcmFormat: format,
                frameCapacity: AVAudioFrameCount(sampleCount)
            )
        else { return nil }
        destination.frameLength = AVAudioFrameCount(sampleCount)

        do {
            try sampleBuffer.withAudioBufferList { source, _ in
                let target = UnsafeMutableAudioBufferListPointer(destination.mutableAudioBufferList)
                guard source.count == target.count else { throw CaptureError.unsupportedAudioFormat }
                for index in source.indices {
                    let input = source[index]
                    let output = target[index]
                    guard let inputData = input.mData,
                        let outputData = output.mData,
                        input.mDataByteSize <= output.mDataByteSize
                    else { throw CaptureError.unsupportedAudioFormat }
                    memcpy(outputData, inputData, Int(input.mDataByteSize))
                    target[index].mDataByteSize = input.mDataByteSize
                }
            }
            return destination
        } catch {
            return nil
        }
    }
}

extension SystemAudioCapture: SCStreamOutput {
    nonisolated func stream(
        _ stream: SCStream,
        didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
        of outputType: SCStreamOutputType
    ) {
        guard outputType == .audio else { return }
        let sourceStreamID = ObjectIdentifier(stream)
        // Convert before returning from ScreenCaptureKit's callback, while the
        // sample buffer and its backing block are still valid.
        guard sampleBuffer.isValid, sampleBuffer.numSamples > 0 else { return }
        guard let pcmBuffer = Self.makeOwnedPCMBuffer(from: sampleBuffer) else {
            Task { @MainActor [weak self] in
                guard let current = self?.stream,
                    ObjectIdentifier(current) == sourceStreamID
                else { return }
                self?.onFailure?(CaptureError.unsupportedAudioFormat)
            }
            return
        }
        let transferred = OwnedAudioBuffer(value: pcmBuffer)
        let peak = Self.peakAmplitude(of: pcmBuffer)
        // DispatchQueue.main preserves the order established by sampleQueue.
        // Independent unstructured Tasks are not an ordered audio transport.
        DispatchQueue.main.async { [weak self] in
            guard let self, let current = self.stream,
                ObjectIdentifier(current) == sourceStreamID
            else { return }
            self.audioPacketCount += 1
            let now = Date()
            if let peak {
                self.reportPeak = max(self.reportPeak ?? 0, peak)
                if peak >= 0.001 { self.lastSignalTime = now }
            }
            if now.timeIntervalSince(self.lastActivityReport) >= 1 {
                self.lastActivityReport = now
                self.onAudioActivity?(
                    AudioCaptureActivity(
                        packetCount: self.audioPacketCount,
                        hasRecentSignal: self.lastSignalTime.map { now.timeIntervalSince($0) < 2 } ?? false,
                        sampleRate: Int(transferred.value.format.sampleRate),
                        sampleFormat: Self.sampleFormatName(transferred.value.format),
                        peakAmplitude: self.reportPeak
                    )
                )
                self.reportPeak = nil
            }
            self.onAudioBuffer?(transferred.value)
        }
    }
}

extension SystemAudioCapture {
    nonisolated static func peakAmplitude(of buffer: AVAudioPCMBuffer) -> Float? {
        let frameCount = Int(buffer.frameLength)
        let channelCount = Int(buffer.format.channelCount)
        guard frameCount > 0, channelCount > 0 else { return nil }
        let stride = buffer.stride

        if let channels = buffer.floatChannelData {
            var peak: Float = 0
            for channel in 0..<channelCount {
                for frame in 0..<frameCount {
                    peak = max(peak, abs(channels[channel][frame * stride]))
                }
            }
            return peak
        }

        if let channels = buffer.int16ChannelData {
            var peak: Float = 0
            for channel in 0..<channelCount {
                for frame in 0..<frameCount {
                    peak = max(peak, Float(abs(Int(channels[channel][frame * stride]))) / 32768)
                }
            }
            return peak
        }

        if let channels = buffer.int32ChannelData {
            var peak: Float = 0
            for channel in 0..<channelCount {
                for frame in 0..<frameCount {
                    peak = max(peak, Float(abs(Int64(channels[channel][frame * stride]))) / 2_147_483_648)
                }
            }
            return peak
        }

        if buffer.format.commonFormat == .pcmFormatFloat64 {
            let audioBuffers = UnsafeMutableAudioBufferListPointer(buffer.mutableAudioBufferList)
            var peak: Float = 0
            for audioBuffer in audioBuffers {
                guard let data = audioBuffer.mData else { return nil }
                let samples = data.assumingMemoryBound(to: Double.self)
                for index in 0..<(Int(audioBuffer.mDataByteSize) / MemoryLayout<Double>.size) {
                    peak = max(peak, Float(abs(samples[index])))
                }
            }
            return peak
        }

        return nil
    }

    private nonisolated static func sampleFormatName(_ format: AVAudioFormat) -> String {
        switch format.commonFormat {
        case .pcmFormatFloat32: "Float32"
        case .pcmFormatFloat64: "Float64"
        case .pcmFormatInt16: "Int16"
        case .pcmFormatInt32: "Int32"
        default: L10n.text("其他格式")
        }
    }
}

struct AudioCaptureActivity: Sendable {
    let packetCount: Int
    let hasRecentSignal: Bool
    let sampleRate: Int
    let sampleFormat: String
    let peakAmplitude: Float?
}

extension SystemAudioCapture: SCStreamDelegate {
    nonisolated func stream(_ stream: SCStream, didStopWithError error: Error) {
        let stoppedStreamID = ObjectIdentifier(stream)
        Task { @MainActor [weak self] in
            guard let currentStream = self?.stream,
                ObjectIdentifier(currentStream) == stoppedStreamID
            else { return }
            self?.stream = nil
            self?.onFailure?(error)
        }
    }
}

private struct OwnedAudioBuffer: @unchecked Sendable {
    let value: AVAudioPCMBuffer
}

enum CaptureError: LocalizedError {
    case noDisplay
    case streamStopped
    case unsupportedAudioFormat

    var errorDescription: String? {
        switch self {
        case .noDisplay: L10n.text("未找到可用于采集系统声音的显示器。")
        case .streamStopped: L10n.text("系统声音采集意外停止。")
        case .unsupportedAudioFormat: L10n.text("系统声音格式暂不受支持。")
        }
    }
}
