import Foundation

/// How the writing should sound, apart from what is being done to it. `preserve` keeps the text's
/// own formality, politeness, directness and emotional intensity; it is not a "normal" register.
public enum WritingTone: String, CaseIterable, Identifiable, Sendable, Codable {
    case preserve
    case formal
    case concise
    case professional

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .preserve: String(localized: "保留原語氣")
        case .formal: String(localized: "正式")
        case .concise: String(localized: "簡潔")
        case .professional: String(localized: "專業")
        }
    }
}

/// The tone each task remembers for itself, so that going from Proofread to Translate and back
/// finds each where it was left. Custom takes no tone: it has none to remember.
public struct WritingToneMemory: Equatable, Sendable {
    private var proofread: WritingTone
    private var translate: WritingTone

    public init(proofread: WritingTone = .preserve, translate: WritingTone = .preserve) {
        self.proofread = proofread
        self.translate = translate
    }

    public func tone(for mode: WritingMode) -> WritingTone {
        switch mode {
        case .proofread: proofread
        case .translate: translate
        case .custom: .preserve
        }
    }

    public mutating func set(_ tone: WritingTone, for mode: WritingMode) {
        switch mode {
        case .proofread: proofread = tone
        case .translate: translate = tone
        case .custom: break
        }
    }
}
