import Foundation

/// A live-turn WAIT response is not proof that the interviewer will continue.
/// Permit one answer after additional, independent evidence of silence, but
/// never keep retrying the model's deterministic WAIT response indefinitely.
enum DeferredAnswerRetryPolicy {
    enum Decision: Equatable {
        case pending
        case forceAnswer
        case manualFallback
        case cancel
    }

    private static let minimumQuietAfterWait: TimeInterval = 5.0
    private static let classifierQuietAfterWait: TimeInterval = 7.0
    private static let maximumQuietWait: TimeInterval = 16.0
    private static let absoluteMaximumWait: TimeInterval = 30.0
    private static let audioFreshness: TimeInterval = 1.0

    static func decide(
        snapshotMatches: Bool,
        captureIsRunning: Bool,
        questionReady: Bool,
        observation: SpeechPauseDetector.Observation?,
        audioAge: TimeInterval?,
        elapsedSinceWait: TimeInterval,
        elapsedSinceLastSpeechOnset: TimeInterval,
        nativeSpeechRecentlyDetected: Bool?
    ) -> Decision {
        guard snapshotMatches, captureIsRunning else { return .cancel }

        if questionReady,
            let observation,
            let audioAge,
            observation.isValidPCM,
            elapsedSinceLastSpeechOnset >= minimumQuietAfterWait
        {
            let quietPCM =
                !observation.isSpeechActive
                && !observation.isPotentialSpeech
                && audioAge <= audioFreshness
                && (!observation.hasObservedSpeech
                    || observation.silenceDuration >= minimumQuietAfterWait)

            // ScreenCaptureKit may stop delivering packets when playback stops;
            // the last PCM observation can still be marked active.
            let stoppedPackets = audioAge >= minimumQuietAfterWait

            // Constant music or meeting noise can keep PCM energy high after
            // speech ends. Prefer the independent local speech classifier in
            // that case, after a longer stable interval.
            let classifierQuiet =
                nativeSpeechRecentlyDetected == false
                && !observation.isPotentialSpeech
                && elapsedSinceLastSpeechOnset >= classifierQuietAfterWait
                && audioAge <= audioFreshness

            if quietPCM || stoppedPackets || classifierQuiet {
                return .forceAnswer
            }
        }

        // One unrelated sound restarts the quiet interval; it must not make
        // the old question wait forever. The absolute cap also bounds a noisy
        // or continually speaking stream with no usable new ASR text.
        return elapsedSinceLastSpeechOnset >= maximumQuietWait
            || elapsedSinceWait >= absoluteMaximumWait
            ? .manualFallback : .pending
    }
}
