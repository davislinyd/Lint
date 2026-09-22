import Foundation

/// What is done to the text. How it should sound is `WritingTone`, and the prompt for a pair of
/// the two is composed by `WritingPromptComposer`.
public enum WritingMode: String, CaseIterable, Identifiable, Sendable, Codable {
    case proofread
    case translate
    case custom

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .proofread: String(localized: "文法校對與潤飾")
        case .translate: String(localized: "翻譯")
        case .custom: String(localized: "自訂 Prompt")
        }
    }

    /// Proofreading and translation take a tone; a custom prompt says everything itself.
    public var supportsTone: Bool {
        self != .custom
    }

    /// The title with the tone after it, unless it is the default one or does not apply.
    public func displayTitle(tone: WritingTone) -> String {
        guard supportsTone, tone != .preserve else { return title }
        return "\(title) · \(tone.title)"
    }
}
