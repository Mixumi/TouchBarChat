import AVFAudio
import Foundation

/// Energy-based pause detection for the already captured system-audio PCM.
/// This is deliberately not speaker identification or a speech/music classifier.
/// Its durations come from audio frames, so UI or recognizer callback delays do
/// not make a quiet interval appear longer than it really was.
struct SpeechPauseDetector {
    struct Observation {
        /// False when PCM cannot be inspected; callers must fail closed.
        let isValidPCM: Bool
        /// Any new above-threshold sound, before the sustained-signal check.
        /// This immediately invalidates a pending end-of-turn decision.
        let didDetectSoundStart: Bool
        /// A sustained signal began after the short onset confirmation window.
        let didDetectSpeechStart: Bool
        /// A sustained signal has been quiet for the release confirmation window.
        let didDetectSpeechEnd: Bool
        /// True through brief gaps within a sustained signal.
        let isSpeechActive: Bool
        /// True while a new sound is awaiting onset confirmation.
        let isPotentialSpeech: Bool
        /// Seconds of PCM silence since the last above-threshold sound.
        /// Remains zero until the first signal is confirmed.
        let silenceDuration: TimeInterval
        let hasObservedSpeech: Bool
    }

    private static let windowDuration: TimeInterval = 0.02
    private static let onsetDuration: TimeInterval = 0.08
    private static let releaseDuration: TimeInterval = 0.16
    private static let minimumSignalRMS = 0.0008
    private static let noiseMultiplier = 3.0

    private var noiseFloorRMS = 0.0002
    private var onsetTime: TimeInterval = 0
    private var quietTime: TimeInterval = 0
    private var elapsedSilence: TimeInterval = 0
    private var speechActive = false
    private var hasObservedSpeech = false

    mutating func reset() {
        self = Self()
    }

    mutating func process(_ buffer: AVAudioPCMBuffer) -> Observation {
        let sampleRate = buffer.format.sampleRate
        let frameCount = Int(buffer.frameLength)
        guard sampleRate > 0, frameCount > 0 else { return observation(isValidPCM: false) }

        let framesPerWindow = max(1, Int(sampleRate * Self.windowDuration))
        var didSoundStart = false
        var didStart = false
        var didEnd = false
        var startFrame = 0

        while startFrame < frameCount {
            let count = min(framesPerWindow, frameCount - startFrame)
            guard let rms = Self.windowRMS(buffer, startFrame: startFrame, frameCount: count) else {
                // Unknown PCM is not interpreted as silence: doing so could
                // spuriously finish a question after a format change.
                return observation(isValidPCM: false)
            }

            let duration = Double(count) / sampleRate
            let threshold = max(Self.minimumSignalRMS, noiseFloorRMS * Self.noiseMultiplier)
            if rms >= threshold {
                if !speechActive && onsetTime == 0 {
                    didSoundStart = true
                }
                onsetTime += duration
                quietTime = 0
                elapsedSilence = 0
                if !speechActive && onsetTime >= Self.onsetDuration {
                    speechActive = true
                    hasObservedSpeech = true
                    didStart = true
                }
            } else {
                onsetTime = 0
                if speechActive {
                    quietTime += duration
                    elapsedSilence += duration
                    if quietTime >= Self.releaseDuration {
                        speechActive = false
                        didEnd = true
                    }
                } else if hasObservedSpeech {
                    elapsedSilence += duration
                }

                // Learn the floor only from quiet windows, never from a voice
                // burst or loud playback. Falling is faster than rising so a
                // newly quiet room quickly regains sensitivity.
                let weight = rms < noiseFloorRMS ? 0.10 : 0.01
                noiseFloorRMS += weight * (rms - noiseFloorRMS)
            }
            startFrame += count
        }

        return observation(didSoundStart: didSoundStart, didStart: didStart, didEnd: didEnd)
    }

    private func observation(
        isValidPCM: Bool = true,
        didSoundStart: Bool = false,
        didStart: Bool = false,
        didEnd: Bool = false
    ) -> Observation {
        Observation(
            isValidPCM: isValidPCM,
            didDetectSoundStart: didSoundStart,
            didDetectSpeechStart: didStart,
            didDetectSpeechEnd: didEnd,
            isSpeechActive: speechActive,
            isPotentialSpeech: !speechActive && onsetTime > 0,
            silenceDuration: hasObservedSpeech ? elapsedSilence : 0,
            hasObservedSpeech: hasObservedSpeech
        )
    }

    private static func windowRMS(
        _ buffer: AVAudioPCMBuffer,
        startFrame: Int,
        frameCount: Int
    ) -> Double? {
        switch buffer.format.commonFormat {
        case .pcmFormatFloat32:
            return windowRMS(buffer, startFrame: startFrame, frameCount: frameCount, sampleSize: 4) {
                data, index in
                let value = data.assumingMemoryBound(to: Float.self)[index]
                return value.isFinite ? Double(value) : 0
            }
        case .pcmFormatInt16:
            return windowRMS(buffer, startFrame: startFrame, frameCount: frameCount, sampleSize: 2) {
                data, index in
                Double(data.assumingMemoryBound(to: Int16.self)[index]) / 32_768
            }
        case .pcmFormatInt32:
            return windowRMS(buffer, startFrame: startFrame, frameCount: frameCount, sampleSize: 4) {
                data, index in
                Double(data.assumingMemoryBound(to: Int32.self)[index]) / 2_147_483_648
            }
        case .pcmFormatFloat64:
            return windowRMS(buffer, startFrame: startFrame, frameCount: frameCount, sampleSize: 8) {
                data, index in
                let value = data.assumingMemoryBound(to: Double.self)[index]
                return value.isFinite ? value : 0
            }
        default:
            return nil
        }
    }

    private static func windowRMS(
        _ buffer: AVAudioPCMBuffer,
        startFrame: Int,
        frameCount: Int,
        sampleSize: Int,
        valueAt: (UnsafeRawPointer, Int) -> Double
    ) -> Double? {
        let channelCount = Int(buffer.format.channelCount)
        guard channelCount > 0 else { return nil }
        let interleaved = buffer.format.isInterleaved
        let audioBuffers = UnsafeMutableAudioBufferListPointer(buffer.mutableAudioBufferList)
        guard audioBuffers.count >= (interleaved ? 1 : channelCount) else { return nil }

        var sumOfSquares = 0.0
        for channel in 0..<channelCount {
            let audioBuffer = audioBuffers[interleaved ? 0 : channel]
            guard let data = audioBuffer.mData else { return nil }
            let channelsInBuffer = interleaved ? channelCount : 1
            let lastSampleIndex = (startFrame + frameCount) * channelsInBuffer
            guard Int(audioBuffer.mDataByteSize) >= lastSampleIndex * sampleSize else { return nil }

            for frame in startFrame..<(startFrame + frameCount) {
                let index = interleaved ? frame * channelCount + channel : frame
                let sample = valueAt(UnsafeRawPointer(data), index)
                sumOfSquares += sample * sample
            }
        }

        return sqrt(sumOfSquares / Double(frameCount * channelCount))
    }
}
