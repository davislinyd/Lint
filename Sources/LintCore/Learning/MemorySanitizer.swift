import Foundation

/// Decides which words may end up in a memory. Memories outlive the text they came from, so
/// anything that could identify someone or something (names, numbers, addresses, paths,
/// acronyms) is kept out.
enum MemorySanitizer {
    static let maxTokenLength = 24
    static let maxPhraseLength = 40

    private static let allowedScalars: CharacterSet = {
        var set = CharacterSet.letters
        set.insert(charactersIn: "'’-")
        return set
    }()

    static func isSafe(_ token: WordToken) -> Bool {
        let text = token.text
        guard !token.isGlued, !token.isName, text.count <= maxTokenLength else { return false }
        guard text.unicodeScalars.allSatisfy({ allowedScalars.contains($0) }) else { return false }
        if text.count >= 2, text.allSatisfy(\.isUppercase) { return false }
        // A capital in the middle of a sentence is most likely a name (the pronoun "I" aside).
        if text.first?.isUppercase == true, !token.isSentenceStart, !isPronounI(text) { return false }
        return true
    }

    static func isSafe(_ tokens: [WordToken]) -> Bool {
        tokens.allSatisfy(isSafe)
    }

    private static func isPronounI(_ text: String) -> Bool {
        text == "I" || text.hasPrefix("I'") || text.hasPrefix("I’")
    }
}
