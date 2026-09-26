import Foundation

/// Endpointing uses several independent observations. Apple Speech text may
/// exist even when a local sound classifier or an energy threshold misses a
/// quiet voice, so neither classifier result is an indefinite hard veto.
enum InterviewQuestionEndPolicy {
    /// Invalidate only after a new signal lasts through the PCM onset window.
    /// A one-packet click should not cancel each confirmation timer forever;
    /// canSubmitQuestion separately rejects a still-potential new signal.
    static func shouldInvalidateCandidate(_ observation: SpeechPauseDetector.Observation) -> Bool {
        observation.didDetectSpeechStart
    }

    static func isQuietEnough(
        observation: SpeechPauseDetector.Observation,
        audioAge: TimeInterval,
        stableTextAge: TimeInterval,
        requiredSilence: TimeInterval,
        audioFreshness: TimeInterval,
        noPacketSilenceGrace: TimeInterval,
        captureIsRunning: Bool,
        nativeSpeechRecentlyDetected: Bool?
    ) -> Bool {
        guard observation.isValidPCM else { return false }

        let pcmIsQuiet = !observation.isSpeechActive && !observation.isPotentialSpeech
        let observedPCMQuiet =
            pcmIsQuiet
            && observation.hasObservedSpeech
            && observation.silenceDuration >= requiredSilence
            && audioAge <= audioFreshness

        // When Speech has produced a stable question but the energy threshold
        // never fired, wait longer on a continuously quiet PCM stream. This
        // prevents a low-volume interview from getting stuck forever.
        let recognizedButLowEnergyQuiet =
            pcmIsQuiet
            && !observation.hasObservedSpeech
            && stableTextAge >= max(3.0, requiredSilence)
            && audioAge <= audioFreshness

        // Meeting music/noise may keep raw PCM energy active after the speaker
        // stops. Prefer the on-device speech classifier when it reports quiet;
        // when it is unavailable or disagrees, require a longer ASR-stable
        // interval instead of blocking the question forever.
        let backgroundDelay: TimeInterval
        switch nativeSpeechRecentlyDetected {
        case .some(false): backgroundDelay = 3.0
        case .none: backgroundDelay = 5.0
        case .some(true): backgroundDelay = 6.0
        }
        let recognizedOverBackground =
            captureIsRunning
            && !observation.isPotentialSpeech
            && audioAge <= audioFreshness
            && stableTextAge >= max(requiredSilence, backgroundDelay)

        // ScreenCaptureKit can stop sending packets entirely after playback
        // stops. The last observation may still say "active" in that case.
        let stoppedSendingPackets =
            captureIsRunning
            && audioAge >= max(requiredSilence, noPacketSilenceGrace)
        // A local recognizer may publish its final correction well after the
        // last packet. The capture remains live, so an arbitrary 10-second
        // upper bound would strand that valid question indefinitely.

        return observedPCMQuiet || recognizedButLowEnergyQuiet
            || recognizedOverBackground || stoppedSendingPackets
    }
}
