import Foundation

/// How the writing should sound, apart from what is being done to it. `preserve` keeps the text's
/// own formality, politeness, directness and emotional intensity; it is not a "normal" register.
/// `native` is the one tone that is not a modifier of the text's own words: it takes what the text
/// means, in any language, and says it the way a native English speaker would (proofreading only).
public enum WritingTone: String, CaseIterable, Identifiable, Sendable, Codable {
    case preserve
    case formal
    case concise
    case professional
    case native

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .preserve: String(localized: "保留原語氣")
        case .formal: String(localized: "正式")
        case .concise: String(localized: "簡潔")
        case .professional: String(localized: "專業")
        case .native: String(localized: "母語人士")
        }
    }
}

/// The tone each task remembers for itself, so that going from Proofread to Translate and back
/// finds each where it was left. Custom takes no tone: it has none to remember.
public struct WritingToneMemory: Equatable, Sendable {
    private var proofread: WritingTone
    private var translate: WritingTone

    public init(proofread: WritingTone = .preserve, translate: WritingTone = .preserve) {
        self.proofread = WritingMode.proofread.tones.contains(proofread) ? proofread : .preserve
        self.translate = WritingMode.translate.tones.contains(translate) ? translate : .preserve
    }

    public func tone(for mode: WritingMode) -> WritingTone {
        switch mode {
        case .proofread: proofread
        case .translate: translate
        case .custom: .preserve
        }
    }

    /// A tone the task does not offer (native for a translation) is not remembered.
    public mutating func set(_ tone: WritingTone, for mode: WritingMode) {
        guard mode.tones.contains(tone) else { return }
        switch mode {
        case .proofread: proofread = tone
        case .translate: translate = tone
        case .custom: break
        }
    }
}
