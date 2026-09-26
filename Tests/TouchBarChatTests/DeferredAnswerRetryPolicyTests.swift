import XCTest

@testable import TouchBarChat

final class DeferredAnswerRetryPolicyTests: XCTestCase {
    func testWaitsForAdditionalQuietBeforeSingleForcedAnswer() {
        XCTAssertEqual(decision(elapsed: 4.9, active: false, silence: 8), .pending)
        XCTAssertEqual(decision(elapsed: 5.1, active: false, silence: 4.9), .pending)
        XCTAssertEqual(decision(elapsed: 5.1, active: false, silence: 5.1), .forceAnswer)
    }

    func testPacketlessPlaybackCanCompleteAfterWait() {
        XCTAssertEqual(decision(elapsed: 5.1, active: true, silence: 0, audioAge: 5.1), .forceAnswer)
    }

    func testOngoingSpeechNeverForcesAnswerAndWaitIsBounded() {
        XCTAssertEqual(decision(elapsed: 7.1, active: true, silence: 0, nativeSpeech: true), .pending)
        XCTAssertEqual(decision(elapsed: 16.1, active: true, silence: 0, nativeSpeech: true), .manualFallback)
    }

    func testNewSoundResetsQuietClockWithoutPermanentlyCancelingRetry() {
        XCTAssertEqual(decision(elapsed: 10, quietElapsed: 3, active: false, silence: 5), .pending)
        XCTAssertEqual(decision(elapsed: 19, quietElapsed: 5, active: false, silence: 5), .forceAnswer)
        XCTAssertEqual(decision(elapsed: 30.1, quietElapsed: 2, active: true, silence: 0), .manualFallback)
    }

    func testClassifierCanIdentifyQuietOverContinuousBackground() {
        XCTAssertEqual(decision(elapsed: 6.9, active: true, silence: 0, nativeSpeech: false), .pending)
        XCTAssertEqual(decision(elapsed: 7.1, active: true, silence: 0, nativeSpeech: false), .forceAnswer)
    }

    func testChangedTranscriptOrStoppedCaptureCancelsStaleRetry() {
        XCTAssertEqual(decision(elapsed: 6, active: false, silence: 6, snapshotMatches: false), .cancel)
        XCTAssertEqual(decision(elapsed: 6, active: false, silence: 6, captureIsRunning: false), .cancel)
    }

    func testQuestionStillRequiresTheNormalEndGate() {
        XCTAssertEqual(decision(elapsed: 6, active: false, silence: 6, questionReady: false), .pending)
        XCTAssertEqual(decision(elapsed: 16, active: false, silence: 6, questionReady: false), .manualFallback)
    }

    private func decision(
        elapsed: TimeInterval,
        quietElapsed: TimeInterval? = nil,
        active: Bool,
        silence: TimeInterval,
        audioAge: TimeInterval = 0.1,
        nativeSpeech: Bool? = nil,
        snapshotMatches: Bool = true,
        captureIsRunning: Bool = true,
        questionReady: Bool = true
    ) -> DeferredAnswerRetryPolicy.Decision {
        DeferredAnswerRetryPolicy.decide(
            snapshotMatches: snapshotMatches,
            captureIsRunning: captureIsRunning,
            questionReady: questionReady,
            observation: SpeechPauseDetector.Observation(
                isValidPCM: true,
                didDetectSoundStart: false,
                didDetectSpeechStart: false,
                didDetectSpeechEnd: false,
                isSpeechActive: active,
                isPotentialSpeech: false,
                silenceDuration: silence,
                hasObservedSpeech: true
            ),
            audioAge: audioAge,
            elapsedSinceWait: elapsed,
            elapsedSinceLastSpeechOnset: quietElapsed ?? elapsed,
            nativeSpeechRecentlyDetected: nativeSpeech
        )
    }
}
