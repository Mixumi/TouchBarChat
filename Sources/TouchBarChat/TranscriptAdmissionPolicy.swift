import Foundation

/// Apple Speech can briefly hypothesize a single character before any real
/// captured signal. Hold only this low-confidence opening fragment; do not
/// blacklist particular words or block later, longer low-volume speech.
enum TranscriptAdmissionPolicy {
    static func shouldDeferInitialFragment(
        _ segmentText: String,
        hasObservedAudioSignal: Bool,
        hasCommittedSegmentText: Bool
    ) -> Bool {
        guard !hasObservedAudioSignal, !hasCommittedSegmentText else { return false }
        let meaningfulCount = segmentText.filter { $0.isLetter || $0.isNumber }.count
        return meaningfulCount == 1
    }
}
