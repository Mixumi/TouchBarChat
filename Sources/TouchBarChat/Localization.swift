import Combine
import Foundation

extension Notification.Name {
    static let touchBarChatAppLanguageDidChange = Notification.Name("TouchBarChatAppLanguageDidChange")
}

/// Interface language is independent of speech recognition and AI output.
/// A missing or invalid saved value returns to the macOS language preference.
@MainActor
final class AppLanguageSettings: ObservableObject {
    static let shared = AppLanguageSettings()
    nonisolated static let defaultsKey = "touchbarchat.appLanguage"
    nonisolated static let systemCode = "system"
    nonisolated static let supportedCodes = ["zh-Hans", "en", "ko", "ja", "ru", "fr", "pt-BR"]

    @Published private(set) var selection: String
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let saved = defaults.string(forKey: Self.defaultsKey) ?? Self.systemCode
        selection = Self.supportedCodes.contains(saved) ? saved : Self.systemCode
    }

    func select(_ code: String) {
        guard code == Self.systemCode || Self.supportedCodes.contains(code),
            code != selection
        else { return }
        defaults.set(code, forKey: Self.defaultsKey)
        selection = code
        NotificationCenter.default.post(name: .touchBarChatAppLanguageDidChange, object: nil)
    }
}

/// Resolves app-owned copy using the selected UI language or macOS preference.
/// The Chinese source string is the key and fallback, so a missing translation
/// remains understandable when a new screen is added.
enum L10n {
    static var resourceBundle: Bundle {
        // SwiftPM's generated Bundle.module accessor looks next to the
        // executable. A conventional macOS .app stores resources under
        // Contents/Resources, so resolve that location first when packaged.
        if let resourceURL = Bundle.main.resourceURL {
            // The packaging script also copies each localization directly
            // into the app, preserving BCP-47 spelling such as pt-BR.
            let directChineseTable = resourceURL.appendingPathComponent(
                "zh-Hans.lproj/Localizable.strings"
            )
            if FileManager.default.fileExists(atPath: directChineseTable.path) {
                return .main
            }
            if let bundle = Bundle(
                url: resourceURL.appendingPathComponent(
                    "TouchBarChat_TouchBarChat.bundle", isDirectory: true
                ))
            {
                return bundle
            }
        }
        return .module
    }

    static var localeIdentifier: String {
        let override = UserDefaults.standard.string(forKey: AppLanguageSettings.defaultsKey)
        if let override, AppLanguageSettings.supportedCodes.contains(override) {
            return override
        }
        let preferred =
            Bundle.preferredLocalizations(
                from: AppLanguageSettings.supportedCodes,
                forPreferences: Locale.preferredLanguages
            ).first ?? "zh-Hans"
        return preferred
    }

    static var locale: Locale {
        Locale(identifier: localeIdentifier)
    }

    /// Reading a particular `.lproj` file directly is intentional. Calling
    /// `Bundle(path: folder).localizedString` still applies the process's
    /// preferred language on some macOS versions, which can relabel a saved
    /// Chinese interview in English when the app UI is set to English.
    private static let translations: [String: [String: String]] = {
        var tables: [String: [String: String]] = [:]
        for code in AppLanguageSettings.supportedCodes {
            let bundle = resourceBundle
            let url =
                bundle.url(
                    forResource: "Localizable",
                    withExtension: "strings",
                    subdirectory: "\(code).lproj"
                )
                ?? bundle.url(
                    forResource: "Localizable",
                    withExtension: "strings",
                    subdirectory: "\(code.lowercased()).lproj"
                )
            guard
                let url,
                let data = try? Data(contentsOf: url),
                let propertyList = try? PropertyListSerialization.propertyList(from: data, format: nil),
                let table = propertyList as? [String: String]
            else { continue }
            tables[code] = table
        }
        return tables
    }()

    static func text(_ key: String, _ arguments: CVarArg...) -> String {
        localizedText(key, localeIdentifier: localeIdentifier, arguments: arguments)
    }

    /// Exposed internally for deterministic localization tests without
    /// changing the process-wide AppleLanguages preference.
    static func localizedText(
        _ key: String,
        localeIdentifier: String,
        arguments: [CVarArg] = []
    ) -> String {
        let format = translations[localeIdentifier]?[key] ?? key
        guard !arguments.isEmpty else { return format }
        return String(format: format, locale: Locale(identifier: localeIdentifier), arguments: arguments)
    }
}
