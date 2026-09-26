import XCTest

@testable import TouchBarChat

final class TranscriptTurnBoundaryTests: XCTestCase {
    func testNewQuestionAfterCommittedQuestion() {
        var cursor = TranscriptTurnBoundary()
        cursor.update("请介绍一下自己")
        cursor.commitCurrentText()
        cursor.update("请介绍一下自己 你做过什么项目")
        XCTAssertEqual(cursor.pendingText, "你做过什么项目")
    }

    func testRecognitionInsertionBeforeBoundaryDoesNotLoseNextQuestion() {
        var cursor = TranscriptTurnBoundary()
        cursor.update("介绍一下自己")
        cursor.commitCurrentText()
        cursor.update("介绍一下自己 你做过什么项目")
        cursor.update("请介绍一下自己 你做过什么项目")
        XCTAssertEqual(cursor.pendingText, "你做过什么项目")
    }

    func testRecognitionRevisionAcrossBoundaryFailsClosed() {
        var cursor = TranscriptTurnBoundary()
        cursor.update("介绍自己")
        cursor.commitCurrentText()
        cursor.update("介绍自己 你做过什么项目")
        cursor.update("请介绍一下自己的项目经历")
        XCTAssertEqual(cursor.pendingText, "")
    }

    func testSingleRevisionCanChangeOldQuestionAndAppendNewOne() {
        var cursor = TranscriptTurnBoundary()
        cursor.update("介绍自己")
        cursor.commitCurrentText()
        cursor.update("请介绍一下自己 你做过什么项目")
        XCTAssertEqual(cursor.pendingText, "你做过什么项目")
    }

    func testSingleRevisionCanAppendChineseQuestionWithoutWhitespace() {
        var cursor = TranscriptTurnBoundary()
        cursor.update("介绍自己")
        cursor.commitCurrentText()
        cursor.update("请介绍一下自己你做过什么项目")
        XCTAssertEqual(cursor.pendingText, "你做过什么项目")
    }

    func testPauseResumeStartsAfterPreviousTranscript() {
        var cursor = TranscriptTurnBoundary()
        cursor.reset(committedPrefix: "第一题\n")
        cursor.update("第一题\n第二题是什么")
        XCTAssertEqual(cursor.pendingText, "第二题是什么")
    }

    func testCompletingAnswerKeepsWordsThatArrivedDuringGeneration() {
        var cursor = TranscriptTurnBoundary()
        let submitted = "请介绍一下你负责的项目？"
        cursor.update(submitted)
        cursor.update(submitted + "。你刚才")
        cursor.commitThrough(submitted)
        XCTAssertEqual(cursor.pendingText, "。你刚才")
        cursor.update(submitted + "。你刚才说的困难是什么？")
        XCTAssertEqual(cursor.pendingText, "。你刚才说的困难是什么？")
    }

    func testCompletionKeepsNewSpeechAfterEarlierRecognitionCorrection() {
        var cursor = TranscriptTurnBoundary()
        let submitted = "介绍一下项目？"
        cursor.update(submitted)
        cursor.update("请介绍一下项目？。为什么？")
        cursor.commitThrough(submitted)
        XCTAssertEqual(cursor.pendingText, "。为什么？")
    }
}
