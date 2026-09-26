import XCTest

@testable import TouchBarChat

final class InterviewLanguageTests: XCTestCase {
    func testStableLocaleIdentifiersCanBePersistedAndRestored() throws {
        let identifiers = ["zh-CN", "en-US", "ko-KR", "ja-JP", "ru-RU", "fr-FR", "pt-BR"]
        XCTAssertEqual(InterviewLanguage.allCases.map(\.rawValue), identifiers)
        for language in InterviewLanguage.allCases {
            let restored = try XCTUnwrap(InterviewLanguage(rawValue: language.rawValue))
            XCTAssertEqual(restored, language)
            XCTAssertFalse(language.nativeName.isEmpty)
            XCTAssertFalse(language.promptLanguageName.isEmpty)
        }
    }
}
