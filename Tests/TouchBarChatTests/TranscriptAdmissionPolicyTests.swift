import XCTest

@testable import TouchBarChat

final class TranscriptAdmissionPolicyTests: XCTestCase {
    func testOpeningSingleCharacterWithoutAudioEvidenceIsDeferred() {
        XCTAssertTrue(
            TranscriptAdmissionPolicy.shouldDeferInitialFragment(
                "我", hasObservedAudioSignal: false, hasCommittedSegmentText: false
            ))
        XCTAssertFalse(
            TranscriptAdmissionPolicy.shouldDeferInitialFragment(
                "我", hasObservedAudioSignal: true, hasCommittedSegmentText: false
            ))
    }

    func testLongerLowVolumeSpeechAndCorrectionsRemainAvailable() {
        XCTAssertFalse(
            TranscriptAdmissionPolicy.shouldDeferInitialFragment(
                "我觉得", hasObservedAudioSignal: false, hasCommittedSegmentText: false
            ))
        XCTAssertFalse(
            TranscriptAdmissionPolicy.shouldDeferInitialFragment(
                "我", hasObservedAudioSignal: false, hasCommittedSegmentText: true
            ))
        XCTAssertFalse(
            TranscriptAdmissionPolicy.shouldDeferInitialFragment(
                "", hasObservedAudioSignal: false, hasCommittedSegmentText: false
            ))
    }
}
