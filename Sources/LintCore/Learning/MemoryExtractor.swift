import Foundation

/// A pattern spotted in one piece of feedback, before it is folded into what is already known.
struct MemoryCandidate: Equatable, Sendable {
    var dedupKey: String
    var kind: MemoryKind
    var language: String
    var modeScope: WritingMode?
    var triggers: [String]
    var instruction: String
}

/// Finds habits in the difference between two versions of a text. Deterministic: the instruction
/// of every memory is a template filled with words that passed the sanitizer, never model output,
/// so a memory cannot carry instructions of its own.
struct MemoryExtractor: Sendable {
    private static let articles: Set<String> = ["a", "an", "the"]
    static let prepositions: Set<String> = [
        "about", "to", "of", "for", "in", "on", "at", "with", "by", "from", "into", "onto", "over",
    ]
    /// Forms of "be", "have" and "do": changing one is tense or agreement in context, not a habit.
    private static let auxiliaries: Set<String> = [
        "is", "are", "am", "was", "were", "be", "been", "being", "has", "have", "had", "do", "does", "did",
    ]
    /// So frequent that a memory triggered by one would fire on almost every text, and whose swaps
    /// ("is" for "has been") are grammar in context rather than a reusable preference.
    private static let functionWords: Set<String> = articles.union(prepositions).union(auxiliaries).union([
        "i", "you", "he", "she", "it", "we", "they", "me", "him", "her", "us", "them",
        "my", "your", "his", "its", "our", "their", "this", "that", "these", "those",
        "and", "or", "but", "so", "if", "as", "than", "not", "no",
    ])
    /// Verbs that take a preposition in many correct sentences ("go to", "need to", "help to").
    private static let commonVerbs: Set<String> = [
        "go", "goes", "went", "come", "get", "got", "make", "take", "give", "let", "want", "need",
        "like", "try", "use", "used", "say", "see", "know", "think", "help", "going", "able",
    ]

    private enum Pattern {
        case articles
        case spelling(old: WordToken, new: WordToken)
        case extraPreposition(verb: WordToken, preposition: WordToken)
        case replacement(old: [WordToken], new: [WordToken])
        case terminology(old: [WordToken], new: [WordToken])
    }

    private struct Context {
        let mode: WritingMode
        /// The difference is the user's own choice (an edit of the suggestion), not a change the
        /// model made to the user's text.
        let userChoice: Bool
        let sourceText: String
        let sourceTokens: [WordToken]
        let newText: String
    }

    /// What one piece of feedback says about the memories.
    struct Extraction: Equatable, Sendable {
        /// Patterns it shows, each once however often it occurs in the text.
        var candidates: [MemoryCandidate]
        /// Memories (by `dedupKey`) the user's own edit argues against: a preposition a memory says
        /// to drop, put back. Never one that the same feedback also supports.
        var contradicted: [String]
        /// Patterns the prompt reminded the model of, which it then applied and the user accepted.
        /// The habit is still there, but the fix is no evidence that it is wanted.
        var reminded: [String] = []
    }

    /// The patterns in a piece of feedback.
    func candidates(
        from feedback: LearningFeedback,
        action: FeedbackAction,
        injected: Set<String> = []
    ) -> [MemoryCandidate] {
        extraction(from: feedback, action: action, injected: injected).candidates
    }

    /// `injected` holds the patterns (by `dedupKey`) the prompt already reminded the model of. If
    /// the model then fixed the text and the user accepted it, that is the reminder working, not
    /// new evidence: counting it would let a memory keep confirming itself. An edit by the user is
    /// still their own choice, so it counts either way.
    func extraction(
        from feedback: LearningFeedback,
        action: FeedbackAction,
        injected: Set<String> = []
    ) -> Extraction {
        let none = Extraction(candidates: [], contradicted: [])
        guard let comparison = comparison(for: feedback, action: action) else { return none }
        let oldTokens = DiffAnalyzer.tokens(in: comparison.old)
        let newTokens = DiffAnalyzer.tokens(in: comparison.new)
        let spans = DiffAnalyzer.spans(from: oldTokens, to: newTokens)
        guard !DiffAnalyzer.isRewrite(spans, oldCount: oldTokens.count, newCount: newTokens.count) else {
            return none
        }

        let source = trimmed(feedback.originalText)
        let context = Context(
            mode: feedback.mode,
            userChoice: comparison.userChoice,
            sourceText: source,
            sourceTokens: comparison.userChoice ? DiffAnalyzer.tokens(in: source) : oldTokens,
            newText: comparison.new
        )
        var seen = Set<String>()
        var found: [MemoryCandidate] = []
        var against: [String] = []
        var reminded: [String] = []
        for span in spans {
            if comparison.userChoice, let key = contradictedKey(by: span), !against.contains(key) {
                against.append(key)
            }
            guard let pattern = pattern(of: span),
                  let candidate = candidate(for: pattern, context: context)
            else { continue }
            if !comparison.userChoice, injected.contains(candidate.dedupKey) {
                if !reminded.contains(candidate.dedupKey) { reminded.append(candidate.dedupKey) }
                continue
            }
            guard seen.insert(candidate.dedupKey).inserted else { continue }
            found.append(candidate)
        }
        // Editing a pattern both ways in one text is no reversal; it is left out.
        return Extraction(
            candidates: found, contradicted: against.filter { !seen.contains($0) }, reminded: reminded
        )
    }

    /// The key of the memory that asks for the opposite: `a>b` becomes `b>a`. Nil for a memory
    /// with no direction ("articles", "discuss about").
    static func reversedKey(of key: String) -> String? {
        guard let colon = key.lastIndex(of: ":") else { return nil }
        let sides = key[key.index(after: colon)...].split(separator: ">", omittingEmptySubsequences: false)
        guard sides.count == 2, !sides[0].isEmpty, !sides[1].isEmpty else { return nil }
        return "\(key[...colon])\(sides[1])>\(sides[0])"
    }

    /// The memory an edit of the user's undoes: a preposition the memory says to drop, put back
    /// after its verb. (The opposite direction of `a>b` memories shows up as a candidate of its own.)
    private func contradictedKey(by span: EditSpan) -> String? {
        guard span.removed.isEmpty, span.added.count == 1,
              Self.prepositions.contains(span.added[0].key),
              MemorySanitizer.isSafe(span.added),
              let verb = span.before.last, MemorySanitizer.isSafe(verb),
              !Self.functionWords.contains(verb.key), !Self.commonVerbs.contains(verb.key)
        else { return nil }
        return "grammar:en:\(verb.key) \(span.added[0].key)"
    }

    // MARK: choosing what to compare

    private func comparison(
        for feedback: LearningFeedback, action: FeedbackAction
    ) -> (old: String, new: String, userChoice: Bool)? {
        guard let generated = feedback.generatedText else { return nil }
        let original = trimmed(feedback.originalText)
        let suggestion = trimmed(generated)
        let final = trimmed(feedback.finalText)

        let result: (old: String, new: String, userChoice: Bool)
        switch action {
        case .regenerated:
            return nil
        case .accepted:
            result = (original, suggestion, false)
        case .editedAndAccepted:
            result = (suggestion, final, true)
        case .copied:
            result = final == suggestion ? (original, suggestion, false) : (suggestion, final, true)
        }
        // A tone change or a translation rewrites the text by design, so only the user's own
        // edits say anything about them.
        if !result.userChoice, feedback.mode != .proofread { return nil }
        return result
    }

    private func trimmed(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: classifying a span

    private func pattern(of span: EditSpan) -> Pattern? {
        let removed = span.removed
        let added = span.added
        let all = removed + added
        guard !all.isEmpty, MemorySanitizer.isSafe(all) else { return nil }

        if all.contains(where: \.isCJK) {
            guard (1...2).contains(removed.count), (1...2).contains(added.count) else { return nil }
            return .terminology(old: removed, new: added)
        }
        if all.allSatisfy({ Self.articles.contains($0.key) }) {
            return .articles
        }
        if removed.count == 1, added.count == 1, Self.isMisspelling(removed[0].key, of: added[0].key) {
            // "has" for "had" is tense, not a slip of the fingers.
            if Self.auxiliaries.contains(removed[0].key), Self.auxiliaries.contains(added[0].key) { return nil }
            return .spelling(old: removed[0], new: added[0])
        }
        if removed.count == 1, added.isEmpty, Self.prepositions.contains(removed[0].key),
           let verb = span.before.last, MemorySanitizer.isSafe(verb),
           !Self.functionWords.contains(verb.key), !Self.commonVerbs.contains(verb.key) {
            return .extraPreposition(verb: verb, preposition: removed[0])
        }
        if (1...3).contains(removed.count), (1...3).contains(added.count),
           !Self.onlyFunctionWords(removed), !Self.onlyFunctionWords(added) {
            return .replacement(old: removed, new: added)
        }
        return nil
    }

    private static func onlyFunctionWords(_ tokens: [WordToken]) -> Bool {
        tokens.allSatisfy { functionWords.contains($0.key) }
    }

    /// Close enough to be a slip of the fingers rather than another word.
    private static func isMisspelling(_ wrong: String, of right: String) -> Bool {
        let a = Array(wrong)
        let b = Array(right)
        guard a.count >= 3, b.count >= 3, a != b else { return false }
        let longest = max(a.count, b.count)
        let limit = longest <= 4 ? 1 : (longest <= 7 ? 2 : 3)
        return editDistance(a, b) <= limit
    }

    /// Levenshtein distance where swapping two neighbouring letters counts as one edit.
    private static func editDistance(_ a: [Character], _ b: [Character]) -> Int {
        var d = Array(repeating: Array(repeating: 0, count: b.count + 1), count: a.count + 1)
        for i in 0...a.count { d[i][0] = i }
        for j in 0...b.count { d[0][j] = j }
        for i in 1...a.count {
            for j in 1...b.count {
                let cost = a[i - 1] == b[j - 1] ? 0 : 1
                d[i][j] = min(d[i - 1][j] + 1, d[i][j - 1] + 1, d[i - 1][j - 1] + cost)
                if i > 1, j > 1, a[i - 1] == b[j - 2], a[i - 2] == b[j - 1] {
                    d[i][j] = min(d[i][j], d[i - 2][j - 2] + 1)
                }
            }
        }
        return d[a.count][b.count]
    }

    // MARK: building a candidate

    private func candidate(for pattern: Pattern, context: Context) -> MemoryCandidate? {
        let scope = context.mode == .proofread ? nil : context.mode

        switch pattern {
        case .articles:
            return MemoryCandidate(
                dedupKey: "grammar:en:articles",
                kind: .grammar, language: "en", modeScope: nil, triggers: [],
                instruction: "英文常漏用或誤用冠詞（a／an／the）：請特別檢查單數可數名詞前的冠詞。"
            )

        case .spelling(let old, let new):
            let (wrong, right) = (old.key, new.key)
            return MemoryCandidate(
                dedupKey: "spelling:en:\(wrong)>\(right)",
                kind: .spelling, language: "en", modeScope: nil,
                triggers: triggers(for: [old], context: context),
                instruction: context.userChoice
                    ? "使用者偏好「\(right)」而非「\(wrong)」。"
                    : "使用者常把「\(right)」誤寫成「\(wrong)」；原文出現「\(wrong)」時請確認是否應為「\(right)」，僅在語意符合時修正。"
            )

        case .extraPreposition(let verb, let preposition):
            let phrase = "\(verb.key) \(preposition.key)"
            return MemoryCandidate(
                dedupKey: "grammar:en:\(phrase)",
                kind: .grammar, language: "en", modeScope: nil,
                triggers: triggers(for: [verb, preposition], context: context),
                instruction: "「\(phrase)」中的「\(preposition.key)」有時是多餘的（使用者曾刪掉）；請確認是否應寫成「\(verb.key)」，僅在語意需要時修正。"
            )

        case .replacement(let old, let new):
            let (from, to) = (Self.phrase(old), Self.phrase(new))
            guard from.count <= MemorySanitizer.maxPhraseLength, to.count <= MemorySanitizer.maxPhraseLength
            else { return nil }
            let kind: MemoryKind = old.count == 1 && new.count == 1 ? .vocabulary : .style
            return MemoryCandidate(
                dedupKey: Self.key(kind, "en", scope, "\(from)>\(to)"),
                kind: kind, language: "en", modeScope: scope,
                triggers: triggers(for: old, context: context),
                instruction: context.userChoice
                    ? "使用者偏好用「\(to)」取代「\(from)」。"
                    : "使用者接受過把「\(from)」改成「\(to)」；原文出現「\(from)」時可考慮這樣改。"
            )

        case .terminology(let old, let new):
            let (from, to) = (Self.phrase(old), Self.phrase(new))
            guard from.count <= MemorySanitizer.maxPhraseLength, to.count <= MemorySanitizer.maxPhraseLength
            else { return nil }
            let language = TextProfile.chineseVariant(of: context.newText) ?? "zh-Hant"
            return MemoryCandidate(
                dedupKey: Self.key(.terminology, language, scope, "\(from)>\(to)"),
                kind: .terminology, language: language, modeScope: scope,
                triggers: triggers(for: old, context: context),
                instruction: "用詞：請用「\(to)」，不要用「\(from)」。"
            )
        }
    }

    /// What makes a memory relevant to a text. A word the model wrote and the user replaced is only
    /// a trigger if it is also in the user's own text; otherwise the memory is a general habit.
    private func triggers(for phrase: [WordToken], context: Context) -> [String] {
        // A lone function word would match nearly every text: the memory is a general habit instead.
        if phrase.count == 1, Self.functionWords.contains(phrase[0].key) { return [] }
        let text = Self.phrase(phrase)
        guard context.userChoice else { return [text] }
        return Self.appears(phrase, in: context) ? [text] : []
    }

    private static func appears(_ phrase: [WordToken], in context: Context) -> Bool {
        if phrase.contains(where: \.isCJK) {
            return context.sourceText.contains(phrase.map(\.text).joined())
        }
        let keys = phrase.map(\.key)
        let source = context.sourceTokens.map(\.key)
        guard !keys.isEmpty, source.count >= keys.count else { return false }
        return (0...(source.count - keys.count)).contains { Array(source[$0..<($0 + keys.count)]) == keys }
    }

    private static func phrase(_ tokens: [WordToken]) -> String {
        tokens.contains(where: \.isCJK) ? tokens.map(\.text).joined() : tokens.map(\.key).joined(separator: " ")
    }

    private static func key(_ kind: MemoryKind, _ language: String, _ scope: WritingMode?, _ pattern: String) -> String {
        [kind.rawValue, language, scope?.rawValue, pattern].compactMap { $0 }.joined(separator: ":")
    }
}
