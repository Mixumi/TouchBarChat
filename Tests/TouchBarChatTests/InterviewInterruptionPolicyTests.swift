import XCTest

@testable import TouchBarChat

final class InterviewInterruptionPolicyTests: XCTestCase {
    private let question = "请介绍一下你最近负责的项目"

    func testUnchangedOrPunctuationOnlyRecognitionDoesNotInterrupt() {
        XCTAssertEqual(decision(question + "。"), .unchanged)
        XCTAssertEqual(decision(question), .unchanged)
    }

    func testShortAcknowledgementWaitsForMoreSpeech() {
        XCTAssertEqual(decision(question + "。嗯"), .waitForMoreSpeech)
        XCTAssertEqual(decision(question + "。好的"), .waitForMoreSpeech)
        XCTAssertFalse(InterviewInterruptionPolicy.shouldReplaceAnswerWithTranscript("嗯"))
        XCTAssertFalse(InterviewInterruptionPolicy.shouldReplaceAnswerWithTranscript("好的"))
    }

    func testShortFollowUpAndLongContinuedSpeechInterrupt() {
        XCTAssertEqual(decision(question + "。为什么？"), .newSpeech("为什么？"))
        XCTAssertEqual(
            decision(question + "。你刚才提到的困难"),
            .newSpeech("你刚才提到的困难")
        )
        XCTAssertTrue(InterviewInterruptionPolicy.shouldReplaceAnswerWithTranscript("为什么？"))
        XCTAssertTrue(InterviewInterruptionPolicy.shouldReplaceAnswerWithTranscript("你刚才提到的困难"))
    }

    func testConstraintAfterMidQuestionPauseExtendsSameQuestion() {
        XCTAssertEqual(
            decision(question + "。以及你在其中承担的具体职责"),
            .extendCurrentQuestion
        )
        XCTAssertEqual(
            decision(question + "。还有一点请说说你做的权衡"),
            .newSpeech("还有一点请说说你做的权衡")
        )
    }

    func testQuestionRevisionInterruptsButPreviousTurnRevisionDoesNot() {
        XCTAssertEqual(decision("请介绍一下你最近负责的产品"), .reviseCurrentQuestion)
        let previous = "先介绍一下团队。"
        XCTAssertEqual(
            InterviewInterruptionPolicy.classify(
                submittedQuestion: question,
                currentQuestion: question,
                submittedTranscript: previous + question,
                currentTranscript: "先简单介绍团队。" + question
            ),
            .unchanged
        )
    }

    func testOldQuestionDoesNotMakeNewBackgroundStatementAnswerable() {
        let newSpeech = InterviewInterruptionPolicy.newSpeech(
            submittedTranscript: question + "？",
            currentTranscript: question + "？。我们团队目前有十个人"
        )
        XCTAssertEqual(newSpeech, "我们团队目前有十个人")
        XCTAssertFalse(ChineseQuestionGate.isCandidate(newSpeech))
        XCTAssertTrue(ChineseQuestionGate.isCandidate(question + "？。我们团队目前有十个人"))
    }

    func testLanguageSpecificConnectivesExtendInterruptedQuestion() {
        let cases: [(InterviewLanguage, String, String)] = [
            (.english, "Tell me about your last project", "and your precise contribution"),
            (.korean, "최근 프로젝트를 어떻게 진행하셨나요", "그리고 팀에서 맡은 역할"),
            (.japanese, "最近のプロジェクトをどのように進めましたか", "そして担当した役割も"),
            (.russian, "Расскажите о вашем последнем проекте", "и ваши конкретные обязанности"),
            (.french, "Parlez-moi de votre dernier projet", "et vos responsabilités précises"),
            (.portuguese, "Fale sobre seu projeto mais recente", "e sua contribuição específica"),
        ]
        for (language, submitted, continuation) in cases {
            let current = submitted + ". " + continuation
            XCTAssertEqual(
                InterviewInterruptionPolicy.classify(
                    submittedQuestion: submitted,
                    currentQuestion: current,
                    submittedTranscript: submitted,
                    currentTranscript: current,
                    language: language
                ),
                .extendCurrentQuestion,
                language.rawValue
            )
        }
    }

    func testLanguageSpecificFollowUpReplacesAnswerButBackchannelDoesNot() {
        let cases: [(InterviewLanguage, String, String)] = [
            (.english, "Why?", "Okay"),
            (.korean, "왜요?", "네"),
            (.japanese, "どうして？", "はい"),
            (.russian, "Почему?", "Хорошо"),
            (.french, "Pourquoi ?", "D'accord"),
            (.portuguese, "Por quê?", "Obrigado"),
        ]
        for (language, followUp, backchannel) in cases {
            XCTAssertTrue(InterviewInterruptionPolicy.shouldReplaceAnswerWithTranscript(followUp, language: language))
            XCTAssertFalse(
                InterviewInterruptionPolicy.shouldReplaceAnswerWithTranscript(backchannel, language: language))
        }
    }

    func testLongLatinSpeechRequiresSeveralWordsBeforeReplacingAnswer() {
        XCTAssertFalse(
            InterviewInterruptionPolicy.shouldReplaceAnswerWithTranscript("contribution", language: .english))
        XCTAssertTrue(
            InterviewInterruptionPolicy.shouldReplaceAnswerWithTranscript(
                "the contribution to this project", language: .english))
    }

    private func decision(_ currentTranscript: String) -> InterviewInterruptionPolicy.Decision {
        InterviewInterruptionPolicy.classify(
            submittedQuestion: question,
            currentQuestion: currentTranscript,
            submittedTranscript: question,
            currentTranscript: currentTranscript
        )
    }
}
