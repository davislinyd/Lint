import CryptoKit
import Foundation

/// Turns what the user did into a `FeedbackEvent`. The event holds only keyed hashes of the
/// texts, so it can be de-duplicated without keeping what the user wrote.
struct FeedbackCollector {
    let key: SymmetricKey

    /// nil when there is nothing to learn from.
    func event(for feedback: LearningFeedback, now: Date) -> FeedbackEvent? {
        guard feedback.isLearnable, let generated = feedback.generatedText else { return nil }
        let generatedText = normalized(generated)
        let finalText = normalized(feedback.finalText)

        let action: FeedbackAction
        var finalHMAC: String?
        switch feedback.gesture {
        case .replaced:
            action = finalText == generatedText ? .accepted : .editedAndAccepted
            finalHMAC = hmac(finalText)
        case .copied:
            action = .copied
            finalHMAC = hmac(finalText)
        case .regenerated:
            action = .regenerated
        }
        return FeedbackEvent(
            id: UUID(),
            createdAt: now,
            mode: feedback.mode,
            tone: feedback.tone,
            action: action,
            sourceHMAC: hmac(normalized(feedback.originalText)),
            suggestionHMAC: hmac(generatedText),
            finalHMAC: finalHMAC,
            provider: feedback.provider,
            model: feedback.model,
            usedMemoryIDs: feedback.usedMemoryIDs
        )
    }

    /// Surrounding whitespace is not an edit, and must not defeat de-duplication.
    private func normalized(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func hmac(_ text: String) -> String {
        HMAC<SHA256>.authenticationCode(for: Data(text.utf8), using: key)
            .map { String(format: "%02x", $0) }
            .joined()
    }
}
