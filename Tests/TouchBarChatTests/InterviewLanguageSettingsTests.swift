import XCTest

@testable import TouchBarChat

@MainActor
final class InterviewLanguageSettingsTests: XCTestCase {
    func testPersistsSelectionAndDefaultsToChinese() {
        let suite = "TouchBarChat.LanguageSettingsTests.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suite) else {
            XCTFail("Could not create isolated user defaults")
            return
        }
        defer { defaults.removePersistentDomain(forName: suite) }

        let settings = InterviewLanguageSettings(defaults: defaults)
        XCTAssertEqual(settings.selectedLanguage, .chinese)
        settings.select(.japanese)
        XCTAssertEqual(defaults.string(forKey: InterviewLanguageSettings.defaultsKey), "ja-JP")
        XCTAssertEqual(
            InterviewLanguageSettings(defaults: defaults).selectedLanguage,
            .japanese
        )
        XCTAssertNil(settings.answerLanguage)
        settings.selectAnswerLanguage(.french)
        XCTAssertEqual(defaults.string(forKey: InterviewLanguageSettings.answerDefaultsKey), "fr-FR")
        XCTAssertEqual(InterviewLanguageSettings(defaults: defaults).answerLanguage, .french)
        settings.selectAnswerLanguage(nil)
        XCTAssertNil(defaults.string(forKey: InterviewLanguageSettings.answerDefaultsKey))
    }
}
