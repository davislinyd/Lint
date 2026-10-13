import Foundation

/// A way of writing that is the user's own and that a model tends to "correct". A closed list: each
/// one can be told from the texts alone, and has a fixed wording (`MemoryWording.profile`).
enum StyleTrait: String, CaseIterable, Sendable {
    /// Writes "don't" and wants it left that way.
    case keepContractions
    /// Writes "do not" and wants it left that way.
    case keepFullForms
    /// Ends a message without a period.
    case noTerminalPeriod
    /// Starts a message in lowercase.
    case keepLowercaseStart

    /// Key of the counter of how often the trait was kept (`positive`) or given up (`negative`).
    var statKey: String { Self.statPrefix + rawValue }

    static let statPrefix = "trait:"
}

/// The one memory that says how the user writes: the traits that hold, in a fixed wording
/// (`MemoryWording.profile`). Dreaming keeps it in line with the counts (`MemoryDreamCoordinator`).
enum StyleProfile {
    static let keyPrefix = "profile:"
    static let dedupKey = keyPrefix + "en"
}

/// Tells, from a suggestion and the text that was sent in the end (observation mode), which of the
/// user's own ways of writing the suggestion would have changed and whether the user kept them.
///
/// A trait only counts where the suggestion touched it. That is what keeps the model's own style
/// from confirming itself: a text the model left alone says nothing.
enum StyleTraits {
    /// The tones that keep the writer's own voice. Any other changes the register on purpose, so what
    /// becomes of a contraction there says nothing about the user.
    static func isObserved(_ tone: WritingTone) -> Bool {
        tone == .preserve || tone == .idiomatic
    }

    /// For each trait the suggestion touched: true when `sent` has the user's own way, false when it
    /// has the suggestion's. A trait the sent text does not settle is left out.
    ///
    /// `startsLine` and `endsLine` say whether the text the suggestion was made for begins and ends
    /// where a line of the field does. A stretch picked out of the middle of a sentence has no
    /// start or end of its own to judge.
    static func observations(
        original: String, suggestion: String, sent: String, startsLine: Bool, endsLine: Bool
    ) -> [StyleTrait: Bool] {
        let old = original.trimmingCharacters(in: .whitespacesAndNewlines)
        let new = suggestion.trimmingCharacters(in: .whitespacesAndNewlines)
        let final = sent.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !old.isEmpty, !new.isEmpty, !final.isEmpty else { return [:] }

        var seen: [StyleTrait: Bool] = [:]
        // Contractions are words, so each change is judged at its own place in the sent text.
        var verdicts: [StyleTrait: Set<SuggestionReview.Verdict>] = [:]
        for change in SuggestionReview.changes(original: old, suggestion: new, sent: final) {
            guard let trait = contractionTrait(of: change.span) else { continue }
            verdicts[trait, default: []].insert(change.verdict)
        }
        for (trait, found) in verdicts {
            if found == [.rejected] { seen[trait] = true }
            if found == [.kept] { seen[trait] = false }
        }

        // A period and a capital are not words: they are read off the ends of the texts, and only
        // while the word next to them is still the one the suggestion was made for.
        let oldWords = DiffAnalyzer.tokens(in: old).map(\.key)
        let newWords = DiffAnalyzer.tokens(in: new).map(\.key)
        let finalWords = DiffAnalyzer.tokens(in: final).map(\.key)
        if endsLine, let last = old.last, last.isLetter || last.isNumber, new.last == ".",
           oldWords.last == newWords.last, finalWords.last == oldWords.last, let end = final.last {
            if end == "." { seen[.noTerminalPeriod] = false }
            if end.isLetter || end.isNumber { seen[.noTerminalPeriod] = true }
        }
        if startsLine, let first = old.first, first.isLowercase, let capital = new.first,
           String(first).uppercased() == String(capital),
           oldWords.first == newWords.first, finalWords.first == oldWords.first, let start = final.first {
            if start.isLowercase { seen[.keepLowercaseStart] = true }
            if start.isUppercase { seen[.keepLowercaseStart] = false }
        }
        return seen
    }

    /// The suggestion spelled a contraction out, or contracted what was spelled out.
    private static func contractionTrait(of span: EditSpan) -> StyleTrait? {
        let removed = span.removed.map(\.key)
        let added = span.added.map(\.key)
        if removed.count == 1, contractions[removed[0]]?.contains(added) == true { return .keepContractions }
        if added.count == 1, contractions[added[0]]?.contains(removed) == true { return .keepFullForms }
        return nil
    }

    /// A contraction and what it stands for, one reading each: "it's" only counts as "it is", and
    /// "I'd", which is "I would" as often as "I had", not at all.
    private static let contractions: [String: [[String]]] = {
        var table: [String: [[String]]] = [
            "won't": [["will", "not"]], "can't": [["cannot"], ["can", "not"]],
            "i'm": [["i", "am"]], "let's": [["let", "us"]],
        ]
        for verb in ["do", "does", "did", "is", "are", "was", "were", "have", "has", "had", "would", "should", "could"] {
            table["\(verb)n't"] = [[verb, "not"]]
        }
        for pronoun in ["i", "you", "we", "they"] {
            table["\(pronoun)'ve"] = [[pronoun, "have"]]
            table["\(pronoun)'ll"] = [[pronoun, "will"]]
        }
        for pronoun in ["you", "we", "they"] {
            table["\(pronoun)'re"] = [[pronoun, "are"]]
        }
        for word in ["it", "that", "there"] {
            table["\(word)'s"] = [[word, "is"]]
        }
        return table
    }()
}
