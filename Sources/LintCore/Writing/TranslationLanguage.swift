import Foundation

/// The language a translation, and the reading aid under a suggestion, is written in. Lint only
/// translates English into one of these to help read it; it never translates into English.
///
/// Declared in the order of the English names, which is the order the menus show.
public enum TranslationLanguage: String, CaseIterable, Identifiable, Sendable, Codable {
    case indonesian = "id"
    case japanese = "ja"
    case korean = "ko"
    case portuguese = "pt-BR"
    case simplifiedChinese = "zh-Hans"
    case thai = "th"
    case traditionalChinese = "zh-Hant"
    case vietnamese = "vi"

    public var id: String { rawValue }

    /// What the menus call it, in English whatever the interface language.
    public var englishName: String {
        switch self {
        case .indonesian: "Indonesian"
        case .japanese: "Japanese"
        case .korean: "Korean"
        case .portuguese: "Portuguese (Brazil)"
        case .simplifiedChinese: "Simplified Chinese"
        case .thai: "Thai"
        case .traditionalChinese: "Traditional Chinese"
        case .vietnamese: "Vietnamese"
        }
    }

    /// Its name in the English prompts.
    var promptName: String {
        switch self {
        case .traditionalChinese: "Traditional Chinese (Taiwan)"
        case .portuguese: "Brazilian Portuguese"
        default: englishName
        }
    }

    /// Its name in the Chinese prompts.
    public var chineseName: String {
        switch self {
        case .indonesian: "印尼文"
        case .japanese: "日文"
        case .korean: "韓文"
        case .portuguese: "巴西葡萄牙文"
        case .simplifiedChinese: "簡體中文"
        case .thai: "泰文"
        case .traditionalChinese: "繁體中文"
        case .vietnamese: "越南文"
        }
    }
}
