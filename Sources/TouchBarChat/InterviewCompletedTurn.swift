import Foundation

/// Keeps enough context to recognize a late addition to a question even if
/// its first AI answer finished before the extra words arrived.
struct InterviewCompletedTurn {
    let question: String
    let submittedTranscript: String
    let boundaryBeforeSubmission: TranscriptTurnBoundary
    let language: InterviewLanguage

    init(
        question: String,
        submittedTranscript: String,
        boundaryBeforeSubmission: TranscriptTurnBoundary,
        language: InterviewLanguage = .chinese
    ) {
        self.question = question
        self.submittedTranscript = submittedTranscript
        self.boundaryBeforeSubmission = boundaryBeforeSubmission
        self.language = language
    }

    func boundaryIncludingContinuation(currentTranscript: String) -> TranscriptTurnBoundary? {
        var expanded = boundaryBeforeSubmission
        expanded.update(currentTranscript)
        let decision = InterviewInterruptionPolicy.classify(
            submittedQuestion: question,
            currentQuestion: expanded.pendingText,
            submittedTranscript: submittedTranscript,
            currentTranscript: currentTranscript,
            language: language
        )
        guard decision == .extendCurrentQuestion else { return nil }
        return expanded
    }
}
