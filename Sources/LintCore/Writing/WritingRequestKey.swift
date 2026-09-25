import Foundation

/// Everything that decides what a suggestion for a text will be. A suggestion prepared ahead of time
/// may only be used for a request whose key is equal to the one it was prepared for.
///
/// A setting that the mode does not read is left out: neither tone nor the custom prompt matters to
/// anything but the mode that takes it.
public struct WritingRequestKey: Equatable, Sendable {
    public let source: String
    public let mode: WritingMode
    public let tone: WritingTone
    /// Only a custom prompt reads it.
    public let customPrompt: String?
    /// Only a translation reads it.
    public let translationLanguage: TranslationLanguage?

    public init(
        source: String,
        mode: WritingMode,
        tone: WritingTone,
        customPrompt: String,
        translationLanguage: TranslationLanguage = .traditionalChinese
    ) {
        self.source = source
        self.mode = mode
        self.tone = mode.supportsTone ? tone : .preserve
        self.customPrompt = mode == .custom
            ? customPrompt.trimmingCharacters(in: .whitespacesAndNewlines) : nil
        self.translationLanguage = mode == .translate ? translationLanguage : nil
    }
}
