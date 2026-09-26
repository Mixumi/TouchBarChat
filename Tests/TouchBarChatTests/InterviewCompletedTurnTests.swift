import XCTest

@testable import TouchBarChat

final class InterviewCompletedTurnTests: XCTestCase {
    private let question = "请介绍一下你负责的项目"

    func testLateAddedConstraintReopensQuestionAfterFirstAnswerCompleted() throws {
        var boundary = TranscriptTurnBoundary()
        boundary.update(question)
        let completed = InterviewCompletedTurn(
            question: question,
            submittedTranscript: question,
            boundaryBeforeSubmission: boundary
        )
        let expanded = try XCTUnwrap(
            completed.boundaryIncludingContinuation(
                currentTranscript: question + "。以及你在其中承担的具体职责"
            ))
        XCTAssertEqual(expanded.pendingText, question + "。以及你在其中承担的具体职责")
    }

    func testNewQuestionAndShortAcknowledgementDoNotReopenOldQuestion() {
        var boundary = TranscriptTurnBoundary()
        boundary.update(question)
        let completed = InterviewCompletedTurn(
            question: question,
            submittedTranscript: question,
            boundaryBeforeSubmission: boundary
        )
        XCTAssertNil(
            completed.boundaryIncludingContinuation(
                currentTranscript: question + "。为什么？"
            ))
        XCTAssertNil(
            completed.boundaryIncludingContinuation(
                currentTranscript: question + "。嗯"
            ))
    }

    func testEnglishContinuationUsesRecordedInterviewLanguage() throws {
        let englishQuestion = "Tell me about your most recent project"
        var boundary = TranscriptTurnBoundary()
        boundary.update(englishQuestion)
        let completed = InterviewCompletedTurn(
            question: englishQuestion,
            submittedTranscript: englishQuestion,
            boundaryBeforeSubmission: boundary,
            language: .english
        )
        let continued = englishQuestion + ". and your personal contribution"
        let expanded = try XCTUnwrap(completed.boundaryIncludingContinuation(currentTranscript: continued))
        XCTAssertEqual(expanded.pendingText, continued)
    }
}
