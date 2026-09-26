import Combine
import Foundation

/// Persists the language heard during an interview. The UI language follows
/// macOS independently; changing this value never changes an active session.
@MainActor
final class InterviewLanguageSettings: ObservableObject {
    static let shared = InterviewLanguageSettings()
    static let defaultsKey = "interview.language"
    static let answerDefaultsKey = "interview.answerLanguage"

    @Published private(set) var selectedLanguage: InterviewLanguage
    /// nil keeps AI responses in the same language as transcription.
    @Published private(set) var answerLanguage: InterviewLanguage?

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        selectedLanguage =
            InterviewLanguage(
                rawValue: defaults.string(forKey: Self.defaultsKey) ?? ""
            ) ?? .chinese
        answerLanguage = defaults.string(forKey: Self.answerDefaultsKey)
            .flatMap(InterviewLanguage.init(rawValue:))
    }

    func select(_ language: InterviewLanguage) {
        guard selectedLanguage != language else { return }
        defaults.set(language.rawValue, forKey: Self.defaultsKey)
        selectedLanguage = language
    }

    func selectAnswerLanguage(_ language: InterviewLanguage?) {
        guard answerLanguage != language else { return }
        if let language {
            defaults.set(language.rawValue, forKey: Self.answerDefaultsKey)
        } else {
            defaults.removeObject(forKey: Self.answerDefaultsKey)
        }
        answerLanguage = language
    }
}
