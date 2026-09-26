import XCTest

@testable import TouchBarChat

final class InterviewQuestionEndPolicyTests: XCTestCase {
    func testNormalSpeechWaitsForPCMQuiet() {
        XCTAssertFalse(ready(observedSpeech: true, active: true, silence: 0, audioAge: 0.1))
        XCTAssertFalse(ready(observedSpeech: true, active: false, silence: 1.0, audioAge: 0.1))
        XCTAssertTrue(ready(observedSpeech: true, active: false, silence: 1.7, audioAge: 0.1))
    }

    func testRecognizedLowEnergyQuestionEventuallyProceeds() {
        XCTAssertFalse(
            ready(
                observedSpeech: false, active: false, silence: 0,
                audioAge: 0.1, stableTextAge: 2.9))
        XCTAssertTrue(
            ready(
                observedSpeech: false, active: false, silence: 0,
                audioAge: 0.1, stableTextAge: 3.1))
    }

    func testPlaybackPacketGapAlsoHandlesDelayedFinalRecognition() {
        XCTAssertFalse(ready(observedSpeech: true, active: true, silence: 0, audioAge: 2.0))
        XCTAssertTrue(ready(observedSpeech: true, active: true, silence: 0, audioAge: 2.3))
        XCTAssertTrue(ready(observedSpeech: true, active: true, silence: 0, audioAge: 10.1))
        XCTAssertTrue(ready(observedSpeech: true, active: true, silence: 0, audioAge: 60.0))
    }

    func testSustainedBackgroundSoundDoesNotCancelEveryConfirmation() {
        let background = SpeechPauseDetector.Observation(
            isValidPCM: true,
            didDetectSoundStart: false,
            didDetectSpeechStart: false,
            didDetectSpeechEnd: false,
            isSpeechActive: true,
            isPotentialSpeech: false,
            silenceDuration: 0,
            hasObservedSpeech: true
        )
        XCTAssertFalse(InterviewQuestionEndPolicy.shouldInvalidateCandidate(background))

        let briefSound = SpeechPauseDetector.Observation(
            isValidPCM: true,
            didDetectSoundStart: true,
            didDetectSpeechStart: false,
            didDetectSpeechEnd: false,
            isSpeechActive: false,
            isPotentialSpeech: true,
            silenceDuration: 0,
            hasObservedSpeech: true
        )
        XCTAssertFalse(InterviewQuestionEndPolicy.shouldInvalidateCandidate(briefSound))

        let sustainedOnset = SpeechPauseDetector.Observation(
            isValidPCM: true,
            didDetectSoundStart: false,
            didDetectSpeechStart: true,
            didDetectSpeechEnd: false,
            isSpeechActive: true,
            isPotentialSpeech: false,
            silenceDuration: 0,
            hasObservedSpeech: true
        )
        XCTAssertTrue(InterviewQuestionEndPolicy.shouldInvalidateCandidate(sustainedOnset))
    }

    func testBackgroundAudioDoesNotBlockStableRecognitionForever() {
        XCTAssertFalse(
            ready(
                observedSpeech: true, active: true, silence: 0,
                audioAge: 0.1, stableTextAge: 2.9, nativeSpeech: false))
        XCTAssertTrue(
            ready(
                observedSpeech: true, active: true, silence: 0,
                audioAge: 0.1, stableTextAge: 3.1, nativeSpeech: false))
        XCTAssertFalse(
            ready(
                observedSpeech: true, active: true, silence: 0,
                audioAge: 0.1, stableTextAge: 4.9, nativeSpeech: nil))
        XCTAssertTrue(
            ready(
                observedSpeech: true, active: true, silence: 0,
                audioAge: 0.1, stableTextAge: 5.1, nativeSpeech: nil))
    }

    func testPotentialNewSignalBlocksBackgroundFallbackDuringOnset() {
        let observation = SpeechPauseDetector.Observation(
            isValidPCM: true,
            didDetectSoundStart: true,
            didDetectSpeechStart: false,
            didDetectSpeechEnd: false,
            isSpeechActive: false,
            isPotentialSpeech: true,
            silenceDuration: 0,
            hasObservedSpeech: true
        )
        XCTAssertFalse(
            InterviewQuestionEndPolicy.isQuietEnough(
                observation: observation,
                audioAge: 0.1,
                stableTextAge: 8,
                requiredSilence: 1.6,
                audioFreshness: 1.0,
                noPacketSilenceGrace: 2.2,
                captureIsRunning: true,
                nativeSpeechRecentlyDetected: false
            ))
    }

    private func ready(
        observedSpeech: Bool,
        active: Bool,
        silence: TimeInterval,
        audioAge: TimeInterval,
        stableTextAge: TimeInterval = 3.1,
        nativeSpeech: Bool? = true,
        captureIsRunning: Bool = true
    ) -> Bool {
        let observation = SpeechPauseDetector.Observation(
            isValidPCM: true,
            didDetectSoundStart: false,
            didDetectSpeechStart: false,
            didDetectSpeechEnd: false,
            isSpeechActive: active,
            isPotentialSpeech: false,
            silenceDuration: silence,
            hasObservedSpeech: observedSpeech
        )
        return InterviewQuestionEndPolicy.isQuietEnough(
            observation: observation,
            audioAge: audioAge,
            stableTextAge: stableTextAge,
            requiredSilence: 1.6,
            audioFreshness: 1.0,
            noPacketSilenceGrace: 2.2,
            captureIsRunning: captureIsRunning,
            nativeSpeechRecentlyDetected: nativeSpeech
        )
    }
}
