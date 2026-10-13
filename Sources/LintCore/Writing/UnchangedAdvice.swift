import Foundation

/// What to tell the writer when the answer is the text itself, so that "nothing changed" reads as an
/// answer and not as a suggestion that failed to arrive.
public enum UnchangedAdvice: Equatable, Sendable {
    /// The preserve tone found no error. The text may still not be how a native speaker would put it
    /// (measured: a sentence that says its subject twice comes back as it is, every time), which is the
    /// idiomatic tone's work.
    case tryIdiomatic
    /// The tone found nothing to change.
    case nothingToChange

    /// nil unless a proofread answered with the text as it is.
    public static func advice(source: String, answer: String, mode: WritingMode, tone: WritingTone) -> UnchangedAdvice? {
        guard mode == .proofread else { return nil }
        let text = source.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, answer.trimmingCharacters(in: .whitespacesAndNewlines) == text else { return nil }
        return tone == .preserve ? .tryIdiomatic : .nothingToChange
    }

    public var message: String {
        switch self {
        case .tryIdiomatic: String(localized: "沒有發現需要修正的錯誤。想讓說法更自然，可以改用「道地」。")
        case .nothingToChange: String(localized: "這段文字不需要修改。")
        }
    }
}
