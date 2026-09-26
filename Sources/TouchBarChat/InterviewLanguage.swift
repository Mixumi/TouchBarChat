import Foundation

/// A supported language choice for transcription or AI answer output.
///
/// Persist the raw BCP-47 identifier, rather than an array index or a
/// translated display name. This keeps saved settings stable across UI
/// localization. The interview and answer languages may be configured
/// independently; Apple's speech APIs receive the interviewer's locale.
enum InterviewLanguage: String, CaseIterable, Codable, Hashable, Identifiable, Sendable {
    case chinese = "zh-CN"
    case english = "en-US"
    case korean = "ko-KR"
    case japanese = "ja-JP"
    case russian = "ru-RU"
    case french = "fr-FR"
    case portuguese = "pt-BR"

    var id: String { rawValue }
    var locale: Locale { Locale(identifier: rawValue) }
    /// Language-folder name used for app copy and exported status labels.
    var localizationCode: String {
        switch self {
        case .chinese: "zh-Hans"
        case .english: "en"
        case .korean: "ko"
        case .japanese: "ja"
        case .russian: "ru"
        case .french: "fr"
        case .portuguese: "pt-BR"
        }
    }

    /// A stable label for language pickers; the rest of the app can localize
    /// the surrounding UI independently of the selected interview language.
    var nativeName: String {
        switch self {
        case .chinese: "简体中文"
        case .english: "English"
        case .korean: "한국어"
        case .japanese: "日本語"
        case .russian: "Русский"
        case .french: "Français"
        case .portuguese: "Português (Brasil)"
        }
    }

    /// Model instructions use an unambiguous language name, not a localized
    /// UI label that might vary with the Mac's appearance or app language.
    var promptLanguageName: String {
        switch self {
        case .chinese: "Simplified Chinese"
        case .english: "English"
        case .korean: "Korean"
        case .japanese: "Japanese"
        case .russian: "Russian"
        case .french: "French"
        case .portuguese: "Brazilian Portuguese"
        }
    }
}
