import Foundation

/// What a tone that can write English from another language does with a text that mixes that language
/// and English: write all of it in English, or keep the other language and edit only the English. It
/// applies to Chinese and to every language with a script of its own (`TextScript.writesInAnotherScript`);
/// a language in Latin letters mixed with English cannot be told apart word by word, so it is always
/// written in English.
public enum MixedTextHandling: String, CaseIterable, Identifiable, Sendable {
    case toEnglish
    /// Stored as "keepChinese", the name from when it applied to Chinese only.
    case keepOtherLanguage = "keepChinese"

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .toEnglish: String(localized: "整段寫成英文")
        case .keepOtherLanguage: String(localized: "保留其他語言，只改英文")
        }
    }
}

extension WritingTone {
    /// The menu tone a tone belongs to: itself for the five the menus offer, and for the others the
    /// one it is written for (native for Chinese text) or now means (professional, Gen Z).
    public var menuTone: WritingTone {
        switch self {
        case .preserve: .preserve
        case .idiomatic, .native: .idiomatic
        case .formal, .professional, .nativeFormal: .formal
        case .casual, .nativeCasual, .nativeGenZ: .casual
        case .concise, .nativeConcise: .concise
        }
    }

    /// What a menu tone becomes when the answer is to be English written from another language; nil
    /// for preserve, which edits English only.
    var fromOtherLanguage: WritingTone? {
        switch menuTone {
        case .idiomatic: .native
        case .formal: .nativeFormal
        case .casual: .nativeCasual
        case .concise: .nativeConcise
        default: nil
        }
    }

    /// The tone a request is written in, for its text. Proofreading English text, or text that mixes
    /// English with Chinese or another script when that language is to be kept, is an edit in the menu
    /// tone; text in Chinese or another script, such text mixed with English that is to be written in
    /// English, and text in another language in Latin letters (`TextScript.isOtherLanguage`) get the
    /// tone that writes English from it. Preserve is always an edit of the English. A translation and a
    /// custom prompt take the menu tone as it is.
    public func effective(for text: String, mode: WritingMode, mixed: MixedTextHandling) -> WritingTone {
        let tone = menuTone
        guard mode == .proofread, let english = tone.fromOtherLanguage else { return tone }
        if Self.containsChinese(text) || TextScript.writesInAnotherScript(text) {
            return !TextScript.hasEnglish(text) || mixed == .toEnglish ? english : tone
        }
        return TextScript.isOtherLanguage(text) ? english : tone
    }

    /// Han characters in the prose: a Chinese name or word, not a URL that happens to contain one.
    static func containsChinese(_ text: String) -> Bool {
        TextScript.prose(text).unicodeScalars.contains(where: TextScript.isHan)
    }
}
