import Foundation

/// How the writing should sound, apart from what is being done to it. `preserve` keeps the text's
/// own formality, politeness, directness and emotional intensity; it is not a "normal" register.
/// `idiomatic` keeps all of that too, and also rewrites what is correct but not how a native speaker
/// would put it ("revert back", word-for-word translations), proofreading only.
///
/// The menus offer five tones (`WritingMode.tones`); each request is written in the tone one of them
/// becomes for its text (`effective(for:mode:mixed:)`). The `native…` tones take what the text means,
/// in any language, and say it the way a native English speaker would: they are what idiomatic,
/// formal, casual and concise become for Chinese text. `professional` and `nativeGenZ` are no longer
/// offered (they mean formal and casual now) but stay readable, because settings, prompt overrides
/// and the memory database written by earlier versions name them.
public enum WritingTone: String, CaseIterable, Identifiable, Sendable, Codable {
    case preserve
    case idiomatic
    case formal
    case casual
    case concise
    case professional
    case native
    case nativeCasual
    case nativeFormal
    case nativeGenZ
    case nativeConcise

    public var id: String { rawValue }

    /// Writes English from a text in any language, instead of editing the text as it is.
    public var isNative: Bool {
        switch self {
        case .native, .nativeCasual, .nativeFormal, .nativeGenZ, .nativeConcise: true
        case .preserve, .idiomatic, .formal, .casual, .concise, .professional: false
        }
    }

    /// Corrects the text without giving it another register. What the writer accepts in these tones is
    /// a correction they needed, so Lint learns from it and what it learns applies in every tone.
    public var correctsOnly: Bool {
        self == .preserve || self == .idiomatic
    }

    public var title: String {
        switch self {
        case .preserve: String(localized: "保留原語氣")
        case .idiomatic: String(localized: "道地")
        case .formal: String(localized: "正式")
        case .casual: String(localized: "輕鬆")
        case .concise: String(localized: "簡潔")
        case .professional: String(localized: "專業")
        // What a menu tone becomes for Chinese text; seen only where prompts are edited.
        case .native, .nativeFormal, .nativeCasual, .nativeConcise:
            menuTone.title + " · " + String(localized: "中文 → 英文")
        case .nativeGenZ: String(localized: "母語人士") + " · " + String(localized: "Gen Z")
        }
    }
}

/// The tone each task remembers for itself, so that going from Proofread to Translate and back
/// finds each where it was left. Custom takes no tone: it has none to remember.
public struct WritingToneMemory: Equatable, Sendable {
    private var proofread: WritingTone
    private var translate: WritingTone

    /// A tone that is not in the task's menu is remembered as the menu tone it belongs to
    /// (`WritingTone.menuTone`), so a tone saved by an earlier version still means what it did.
    public init(
        proofread: WritingTone = WritingMode.proofread.defaultTone, translate: WritingTone = WritingMode.translate.defaultTone
    ) {
        self.proofread = Self.offered(proofread.menuTone, for: .proofread)
        self.translate = Self.offered(translate.menuTone, for: .translate)
    }

    private static func offered(_ tone: WritingTone, for mode: WritingMode) -> WritingTone {
        mode.tones.contains(tone) ? tone : .preserve
    }

    public func tone(for mode: WritingMode) -> WritingTone {
        switch mode {
        case .proofread: proofread
        case .translate: translate
        case .custom: .preserve
        }
    }

    /// A tone the task does not offer (idiomatic for a translation) is not remembered.
    public mutating func set(_ tone: WritingTone, for mode: WritingMode) {
        let tone = tone.menuTone
        guard mode.tones.contains(tone) else { return }
        switch mode {
        case .proofread: proofread = tone
        case .translate: translate = tone
        case .custom: break
        }
    }
}
