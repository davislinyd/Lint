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

    /// The tones the menus offer for the task, in order. A translation goes into the reading language,
    /// so there is no idiomatic English to make of it.
    public var tones: [WritingTone] {
        switch self {
        case .proofread: [.preserve, .idiomatic, .formal, .casual, .concise]
        case .translate: [.preserve, .formal, .casual, .concise]
        case .custom: []
        }
    }

    /// The tones whose prompts can be edited: every tone a request of the task can be written in
    /// (`WritingTone.effective`), each menu tone followed by what it becomes for Chinese text.
    public var promptTones: [WritingTone] {
        switch self {
        case .proofread: [.preserve, .idiomatic, .native, .formal, .nativeFormal, .casual, .nativeCasual, .concise, .nativeConcise]
        case .translate: tones
        case .custom: []
        }
    }

    /// Whether the task has a prompt for the tone at all. A translation has none for the tones that
    /// write English; any other tone of the task, offered or not, is written as asked.
    public func accepts(_ tone: WritingTone) -> Bool {
        switch self {
        case .proofread: true
        case .translate: !tone.isNative && tone != .idiomatic
        case .custom: false
        }
    }

    /// The title with the tone after it, unless it is the default one or does not apply.
    public func displayTitle(tone: WritingTone) -> String {
        guard supportsTone, tone != .preserve else { return title }
        return "\(title) · \(tone.title)"
    }
}
