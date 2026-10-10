import Foundation

/// What a tone that can write English from Chinese does with a text that mixes the two: write all of
/// it in English, or keep the Chinese and edit only the English.
public enum MixedTextHandling: String, CaseIterable, Identifiable, Sendable {
    case toEnglish
    case keepChinese

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .toEnglish: String(localized: "整段寫成英文")
        case .keepChinese: String(localized: "保留中文，只改英文")
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

    /// What a menu tone becomes when the answer is to be English written from Chinese; nil for
    /// preserve, which edits English only.
    var fromChinese: WritingTone? {
        switch menuTone {
        case .idiomatic: .native
        case .formal: .nativeFormal
        case .casual: .nativeCasual
        case .concise: .nativeConcise
        default: nil
        }
    }

    /// The tone a request is written in, for its text. Proofreading English text, or text that mixes
    /// Chinese and English when the Chinese is to be kept, is an edit in the menu tone; text that is
    /// Chinese, or mixed text that is to be written in English, gets the tone that writes English from
    /// Chinese. Preserve is always an edit of the English. A translation and a custom prompt take the
    /// menu tone as it is.
    public func effective(for text: String, mode: WritingMode, mixed: MixedTextHandling) -> WritingTone {
        let tone = menuTone
        guard mode == .proofread, let english = tone.fromChinese, Self.containsChinese(text) else { return tone }
        return !TextScript.hasEnglish(text) || mixed == .toEnglish ? english : tone
    }

    /// Han characters in the prose: a Chinese name or word, not a URL that happens to contain one.
    static func containsChinese(_ text: String) -> Bool {
        TextScript.prose(text).unicodeScalars.contains(where: TextScript.isHan)
    }
}
