import Foundation
import Testing

@testable import TouchBarChat

struct LocalizationTests {
    @Test func allSupportedLocalizationsAreBundled() throws {
        let languages = ["zh-Hans", "en", "ko", "ja", "ru", "fr", "pt-BR"]
        var expectedKeys: Set<String>?
        for language in languages {
            let url = try #require(localizationURL(language))
            let data = try Data(contentsOf: url)
            let strings = try #require(
                PropertyListSerialization.propertyList(from: data, format: nil) as? [String: String]
            )
            if let expectedKeys {
                #expect(Set(strings.keys) == expectedKeys)
            } else {
                expectedKeys = Set(strings.keys)
            }
            #expect(strings["面试记录"]?.isEmpty == false)
            #expect(strings["开启面试"]?.isEmpty == false)
            #expect(strings["面试官使用的语言"]?.isEmpty == false)
            #expect(strings["AI 回答语言"]?.isEmpty == false)
            #expect(strings["记录保存失败：%@"]?.contains("%@") == true)
            for (key, value) in strings {
                #expect(
                    formatArgumentTypes(key) == formatArgumentTypes(value),
                    "Placeholder mismatch for \(language): \(key)")
            }
        }
    }

    @Test func englishUsesTranslatedCopy() throws {
        let url = try #require(localizationURL("en"))
        let data = try Data(contentsOf: url)
        let strings = try #require(
            PropertyListSerialization.propertyList(from: data, format: nil) as? [String: String]
        )
        #expect(strings["面试记录"] == "Interview records")
    }

    @Test func explicitLanguageLookupChangesWithoutChangingSystemPreferences() {
        #expect(L10n.localizedText("面试记录", localeIdentifier: "en") == "Interview records")
        #expect(L10n.localizedText("未配置 AI 接口", localeIdentifier: "zh-Hans") == "未配置 AI 接口")
        #expect(L10n.localizedText("面试记录", localeIdentifier: "ja") == "面接記録")
        #expect(L10n.localizedText("面试记录", localeIdentifier: "fr") == "Historique des entretiens")
        #expect(L10n.localizedText("面试记录", localeIdentifier: "pt-BR") == "Registros de entrevistas")
    }

    @Test func allLiteralLookupKeysExistInChineseSourceTable() throws {
        let chineseURL = try #require(localizationURL("zh-Hans"))
        let data = try Data(contentsOf: chineseURL)
        let strings = try #require(
            PropertyListSerialization.propertyList(from: data, format: nil) as? [String: String]
        )
        let packageRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let sources = packageRoot.appendingPathComponent("Sources/TouchBarChat")
        let files = try #require(
            FileManager.default.enumerator(
                at: sources, includingPropertiesForKeys: nil
            ))
        let expression = try NSRegularExpression(
            pattern: "L10n\\.(?:text|localizedText)\\(\\s*\"([^\"]+)\""
        )
        for case let file as URL in files where file.pathExtension == "swift" {
            let source = try String(contentsOf: file, encoding: .utf8)
            let range = NSRange(source.startIndex..<source.endIndex, in: source)
            for match in expression.matches(in: source, range: range) {
                let keyRange = try #require(Range(match.range(at: 1), in: source))
                let key = String(source[keyRange])
                #expect(strings[key] != nil, "Missing Localizable.strings key: \(key) in \(file.lastPathComponent)")
            }
        }
    }

    private func formatArgumentTypes(_ text: String) -> [String] {
        let expression = try! NSRegularExpression(
            pattern: "%(?:[0-9]+\\$)?(hh|ll|h|l|z|t|j)?([@diuoxXfFeEgGaAcCsSp])"
        )
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return expression.matches(in: text, range: range).map { match in
            let length = Range(match.range(at: 1), in: text).map { String(text[$0]) } ?? ""
            let conversion = Range(match.range(at: 2), in: text).map { String(text[$0]) } ?? ""
            return length + conversion
        }.sorted()
    }

    private func localizationURL(_ code: String) -> URL? {
        let bundle = L10n.resourceBundle
        return bundle.url(
            forResource: "Localizable", withExtension: "strings", subdirectory: "\(code).lproj"
        )
            ?? bundle.url(
                forResource: "Localizable", withExtension: "strings", subdirectory: "\(code.lowercased()).lproj"
            )
    }
}

@MainActor
struct AppLanguageSettingsTests {
    @Test func selectionPersistsAndRejectsUnknownCodes() throws {
        let suite = "TouchBarChat-AppLanguageTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        let settings = AppLanguageSettings(defaults: defaults)
        #expect(settings.selection == "system")
        settings.select("fr")
        #expect(settings.selection == "fr")
        #expect(AppLanguageSettings(defaults: defaults).selection == "fr")
        settings.select("unsupported")
        #expect(settings.selection == "fr")
    }
}
