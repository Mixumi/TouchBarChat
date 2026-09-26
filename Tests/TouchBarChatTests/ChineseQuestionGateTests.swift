import XCTest

@testable import TouchBarChat

final class ChineseQuestionGateTests: XCTestCase {
    func testCommonChineseInterviewPrompts() {
        XCTAssertTrue(ChineseQuestionGate.isCandidate("请介绍一下你最近负责的项目"))
        XCTAssertTrue(ChineseQuestionGate.isCandidate("你怎么看待跨团队协作"))
        XCTAssertTrue(ChineseQuestionGate.isCandidate("能举个例子吗"))
    }

    func testInterviewerSelfIntroductionIsNotAQuestion() {
        XCTAssertFalse(ChineseQuestionGate.isCandidate("我先介绍一下我们的团队"))
        XCTAssertFalse(ChineseQuestionGate.isCandidate("接下来我介绍一下岗位背景"))
    }

    func testShortAcknowledgementsAreNotQuestions() {
        XCTAssertFalse(ChineseQuestionGate.isCandidate("好的"))
        XCTAssertFalse(ChineseQuestionGate.isCandidate("嗯嗯"))
        XCTAssertTrue(ChineseQuestionGate.isCandidate("为什么？"))
    }

    func testQuestionAndDirectiveCandidatesInEverySupportedLanguage() {
        let examples: [(InterviewLanguage, String, String)] = [
            (.chinese, "请介绍一下你最近负责的项目", "好的"),
            (.english, "Tell me about your most recent project", "Okay"),
            (.korean, "최근 프로젝트를 어떻게 진행하셨나요", "네"),
            (.japanese, "最近のプロジェクトをどのように進めましたか", "はい"),
            (.russian, "Расскажите о вашем последнем проекте", "Хорошо"),
            (.french, "Parlez-moi de votre dernier projet", "D'accord"),
            (.portuguese, "Fale sobre seu projeto mais recente", "Obrigado"),
        ]
        for (language, question, acknowledgement) in examples {
            XCTAssertTrue(InterviewQuestionGate.isCandidate(question, language: language), language.rawValue)
            XCTAssertFalse(InterviewQuestionGate.isCandidate(acknowledgement, language: language), language.rawValue)
        }
    }

    func testInterviewerIntroductionsDoNotTriggerAcrossLanguages() {
        let introductions: [(InterviewLanguage, String)] = [
            (.english, "We will tell you about the role"),
            (.korean, "저희 팀과 업무를 소개해 드리겠습니다"),
            (.japanese, "これからチームを紹介します"),
            (.russian, "Мы расскажем о нашей команде"),
            (.french, "Nous allons parler de notre équipe"),
            (.portuguese, "Vamos falar sobre nossa equipe"),
        ]
        for (language, introduction) in introductions {
            XCTAssertFalse(InterviewQuestionGate.isCandidate(introduction, language: language), language.rawValue)
        }
    }

    func testShortFollowUpCanBeACompleteQuestionInEachLanguage() {
        let followUps: [(InterviewLanguage, String)] = [
            (.chinese, "为什么？"),
            (.english, "Why?"),
            (.korean, "왜요?"),
            (.japanese, "どうして？"),
            (.russian, "Почему?"),
            (.french, "Pourquoi ?"),
            (.portuguese, "Por quê?"),
        ]
        for (language, followUp) in followUps {
            XCTAssertTrue(InterviewQuestionGate.isCandidate(followUp, language: language), language.rawValue)
        }
    }

    func testSelfIntroductionDirectivesWithoutQuestionMark() {
        let directives: [(InterviewLanguage, String)] = [
            (.english, "Introduce yourself briefly"),
            (.korean, "자기소개 부탁드립니다"),
            (.japanese, "自己紹介してください"),
            (.russian, "Представьтесь, пожалуйста, кратко"),
            (.french, "Présentez-vous brièvement"),
            (.portuguese, "Apresente-se brevemente"),
        ]
        for (language, directive) in directives {
            XCTAssertTrue(InterviewQuestionGate.isCandidate(directive, language: language), language.rawValue)
        }
    }

    func testVeryShortButCompleteIntroductionDirectives() {
        XCTAssertTrue(InterviewQuestionGate.isCandidate("Introduce yourself", language: .english))
        XCTAssertTrue(InterviewQuestionGate.isCandidate("Представьтесь", language: .russian))
        XCTAssertTrue(InterviewQuestionGate.isCandidate("Présentez-vous", language: .french))
        XCTAssertTrue(InterviewQuestionGate.isCandidate("Apresente-se", language: .portuguese))
    }

    func testSingleWordPunctuationIsNotAutomaticallyAQuestionInLatinScripts() {
        XCTAssertFalse(InterviewQuestionGate.isCandidate("Really?", language: .english))
        XCTAssertFalse(InterviewQuestionGate.isCandidate("Vraiment ?", language: .french))
        XCTAssertFalse(InterviewQuestionGate.isCandidate("Серьёзно?", language: .russian))
    }
}
