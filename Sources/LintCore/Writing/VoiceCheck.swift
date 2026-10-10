import Foundation

/// One way an answer sounds different from the text it came from, decided by pattern rather than by
/// opinion: an edit that keeps the writer's voice keeps a question a question, keeps contractions
/// where the writer used them, and adds no hedges or stock phrases the writer did not write.
public enum VoiceChange: Equatable, Sendable, CustomStringConvertible {
    case lostQuestion, addedQuestion
    case lostExclamation, addedExclamation
    case lostEmoji, addedEmoji
    /// The writer used contractions ("I'm", "don't") and the answer spells them out, or the reverse.
    case lostContractions, addedContractions
    /// The writer hedged ("maybe", "I think") and the answer does not, or the reverse.
    case lostHedge, addedHedge
    /// A formula the writer did not use ("Dear", "I hope this finds you well", "kindly").
    case addedStockPhrase(String)
    /// Informal words of the writer's ("wanna", "lol") that the answer does not have.
    case lostInformal([String])
    /// The answer is far longer or shorter than the text (English text only).
    case longer(ratio: Double), shorter(ratio: Double)

    public var description: String {
        switch self {
        case .lostQuestion: "question lost"
        case .addedQuestion: "question added"
        case .lostExclamation: "exclamation lost"
        case .addedExclamation: "exclamation added"
        case .lostEmoji: "emoji lost"
        case .addedEmoji: "emoji added"
        case .lostContractions: "contractions spelled out"
        case .addedContractions: "contractions added"
        case .lostHedge: "hedge lost"
        case .addedHedge: "hedge added"
        case .addedStockPhrase(let phrase): "stock phrase added: \(phrase)"
        case .lostInformal(let words): "informal words lost: \(words.joined(separator: ", "))"
        case .longer(let ratio): String(format: "%.1f× longer", ratio)
        case .shorter(let ratio): String(format: "%.1f× shorter", 1 / ratio)
        }
    }
}

/// Compares how a text and an answer to it sound. Punctuation, emoji and stock phrases are compared
/// whatever the text's language; contractions, hedges and length only when both are English, since
/// a Chinese text has none of them to compare.
public enum VoiceCheck {
    /// An answer this many times the text's length, or this share of it, was not an edit of it.
    public static let maximumLengthRatio = 1.5
    public static let minimumLengthRatio = 0.6
    /// Below this many tokens one added word is already a large share.
    public static let lengthMinimumTokens = 8

    /// Lowercased; found anywhere in the answer, but only held against it when the text lacks it.
    static let stockPhrases = [
        "dear ", "i hope this", "i hope you", "hope you're doing well", "hope you are doing well",
        "best regards", "kind regards", "warm regards", "sincerely", "please don't hesitate",
        "please do not hesitate", "feel free to", "kindly", "at your earliest convenience",
        "i am writing to", "i'm writing to", "i would like to", "i'd like to",
        "thank you for your patience", "thanks for your patience", "thank you in advance",
        "apologize for any inconvenience", "sorry for any inconvenience", "let me know if you have any questions",
    ]

    /// Chat words a writer chooses on purpose; a native polish keeps them. Compared as whole words,
    /// case aside ("hey" → "Hey" keeps it).
    static let informalWords: Set<String> = [
        "wanna", "gonna", "gotta", "lemme", "gimme", "kinda", "sorta", "dunno", "ya", "yeah", "yep", "yup",
        "nope", "nah", "lol", "lmao", "omg", "btw", "idk", "imo", "tbh", "ngl", "fyi", "thx", "pls", "plz",
        "tmrw", "tmr", "hey", "ugh", "haha", "ok", "okay", "cuz",
    ]

    /// Words that soften a claim. "just" is left out: as often as not it means "a moment ago".
    static let hedgePattern = try! NSRegularExpression(
        pattern: #"\b(?:maybe|perhaps|probably|possibly|might|i think|i guess|i feel|kind of|kinda|sort of|a bit)\b"#,
        options: [.caseInsensitive]
    )

    /// n't, 'm, 're, 've, 'll, 'd, and the 's of it's, that's, let's and the like. A possessive is not one.
    static let contractionPattern = try! NSRegularExpression(
        pattern: #"\b(?:\w+n['’]t|i['’]m|\w+['’](?:re|ve|ll|d)|(?:it|that|let|there|here|what|he|she|who|how|where|when)['’]s)\b"#,
        options: [.caseInsensitive]
    )

    /// Forms a writer who contracts would have contracted. "I have" is left out: "I have a car" is
    /// rarely "I've a car".
    static let expandedPattern = try! NSRegularExpression(
        pattern: #"\b(?:i am|you are|we are|they are|it is|that is|there is|do not|does not|did not|is not|are not|was not|were not|will not|would not|should not|could not|cannot|have not|has not|had not|i will|we will|you will|they will|it will|i would|we would|let us)\b"#,
        options: [.caseInsensitive]
    )

    public static func contractions(in text: String) -> [String] {
        matches(of: contractionPattern, in: text)
    }

    public static func changes(from source: String, to output: String) -> [VoiceChange] {
        var changes: [VoiceChange] = []
        func compare(_ has: (String) -> Bool, lost: VoiceChange, added: VoiceChange) {
            switch (has(source), has(output)) {
            case (true, false): changes.append(lost)
            case (false, true): changes.append(added)
            default: break
            }
        }
        compare({ $0.contains("?") || $0.contains("？") }, lost: .lostQuestion, added: .addedQuestion)
        compare({ $0.contains("!") || $0.contains("！") }, lost: .lostExclamation, added: .addedExclamation)
        compare(containsEmoji, lost: .lostEmoji, added: .addedEmoji)

        let lowercasedSource = source.lowercased()
        let lowercasedOutput = output.lowercased()
        for phrase in stockPhrases where lowercasedOutput.contains(phrase) && !lowercasedSource.contains(phrase) {
            changes.append(.addedStockPhrase(phrase.trimmingCharacters(in: .whitespaces)))
        }
        let outputWords = words(in: lowercasedOutput)
        let lostInformal = words(in: lowercasedSource).filter { informalWords.contains($0) && !outputWords.contains($0) }
        if !lostInformal.isEmpty { changes.append(.lostInformal(lostInformal)) }

        guard TextScript.of(source) == .latin, TextScript.of(output) == .latin else { return changes }
        switch (contractionStyle(source), contractionStyle(output)) {
        case (.contracted, .expanded): changes.append(.lostContractions)
        case (.expanded, .contracted): changes.append(.addedContractions)
        default: break
        }
        compare({ !matches(of: hedgePattern, in: $0).isEmpty }, lost: .lostHedge, added: .addedHedge)
        let sourceTokens = EditRatio.tokens(source).count
        if sourceTokens >= lengthMinimumTokens {
            let ratio = Double(EditRatio.tokens(output).count) / Double(sourceTokens)
            if ratio > maximumLengthRatio { changes.append(.longer(ratio: ratio)) }
            if ratio < minimumLengthRatio { changes.append(.shorter(ratio: ratio)) }
        }
        return changes
    }

    enum ContractionStyle { case contracted, expanded, neutral }

    /// Contracted if the text contracts anything; expanded if it spells out something it could have
    /// contracted and contracts nothing; neutral if it has neither, so there is nothing to keep.
    static func contractionStyle(_ text: String) -> ContractionStyle {
        if !contractions(in: text).isEmpty { return .contracted }
        return matches(of: expandedPattern, in: text).isEmpty ? .neutral : .expanded
    }

    /// The words of `text` in order, without repeats.
    static func words(in text: String) -> [String] {
        var seen: [String] = []
        for word in text.split(whereSeparator: { !$0.isLetter }).map(String.init) where !seen.contains(word) {
            seen.append(word)
        }
        return seen
    }

    static func containsEmoji(_ text: String) -> Bool {
        // Digits, # and * are emoji too when followed by a keycap mark; on their own they are not.
        text.unicodeScalars.contains { $0.properties.isEmojiPresentation || ($0.properties.isEmoji && $0.value >= 0x2300) }
    }

    private static func matches(of regex: NSRegularExpression, in text: String) -> [String] {
        let range = NSRange(text.startIndex..., in: text)
        return regex.matches(in: text, range: range).compactMap { Range($0.range, in: text).map { String(text[$0]) } }
    }
}
