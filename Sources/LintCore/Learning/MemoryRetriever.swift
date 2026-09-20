import Foundation
import NaturalLanguage

/// Picks the few memories worth reminding the model about for one text. Built once from the
/// memories that may be used (the coordinator keeps it in memory), so a query never reads the
/// database.
///
/// Two channels: a memory whose trigger appears in the text, and a habit (no trigger) that fits
/// the text's language. Both are ranked, and the result stays within the prompt budget.
struct MemoryRetriever: Sendable {
    struct Query: Sendable {
        var text: String
        var mode: WritingMode
        /// The language the result is written in when it is not the text's own (translation).
        var outputLanguage: String?
    }

    private struct Entry: Sendable {
        let memory: WritingMemory
        /// Lower-cased, words separated by single spaces.
        let latinTriggers: [String]
        let cjkTriggers: [String]

        var isHabit: Bool { latinTriggers.isEmpty && cjkTriggers.isEmpty }
    }

    private struct Candidate {
        let memory: WritingMemory
        let isLexical: Bool
        let score: Double
    }

    private let entries: [Entry]
    private let longestLatinTrigger: Int

    /// Only active and pinned memories can be retrieved, and of two that ask for opposite things
    /// (`a>b` and `b>a`) only the better-evidenced one: a prompt must not tell the model both.
    init(memories: [WritingMemory]) {
        let usable = memories.filter { $0.state == .active || $0.state == .pinned }
        let byKey = Dictionary(usable.map { ($0.dedupKey, $0) }, uniquingKeysWith: { first, _ in first })
        entries = usable
            .filter { memory in
                guard let key = MemoryExtractor.reversedKey(of: memory.dedupKey),
                      let opposite = byKey[key] else { return true }
                return !Self.loses(memory, to: opposite)
            }
            .map { memory in
                Entry(
                    memory: memory,
                    latinTriggers: memory.triggers.filter { !$0.isEmpty && !$0.unicodeScalars.contains(where: Script.isCJK) },
                    cjkTriggers: memory.triggers.filter { $0.unicodeScalars.contains(where: Script.isCJK) }
                )
            }
        longestLatinTrigger = min(
            4, entries.flatMap(\.latinTriggers).map { $0.split(separator: " ").count }.max() ?? 0
        )
    }

    /// A pinned memory is the user's choice and beats an unpinned one (two pinned ones both stay);
    /// otherwise more evidence wins, then the more recently confirmed, then the id, so exactly one
    /// of the pair goes.
    private static func loses(_ memory: WritingMemory, to opposite: WritingMemory) -> Bool {
        let (pinned, oppositePinned) = (memory.state == .pinned, opposite.state == .pinned)
        if pinned != oppositePinned { return oppositePinned }
        if pinned { return false }
        if memory.evidenceScore != opposite.evidenceScore { return memory.evidenceScore < opposite.evidenceScore }
        if memory.lastConfirmedAt != opposite.lastConfirmedAt { return memory.lastConfirmedAt < opposite.lastConfirmedAt }
        return memory.id.uuidString > opposite.id.uuidString
    }

    func select(for query: Query) -> [WritingMemory] {
        let profile = TextProfile(query.text)
        let grams = latinNGrams(in: query.text)

        var candidates: [Candidate] = []
        for entry in entries {
            let memory = entry.memory
            guard memory.modeScope == nil || memory.modeScope == query.mode else { continue }
            if entry.isHabit {
                guard languageFits(memory, query: query, profile: profile, habit: true) else { continue }
                candidates.append(Candidate(memory: memory, isLexical: false, score: score(memory, lexical: false, mode: query.mode)))
            } else if entry.latinTriggers.contains(where: grams.contains)
                        || entry.cjkTriggers.contains(where: query.text.contains),
                      languageFits(memory, query: query, profile: profile, habit: false) {
                candidates.append(Candidate(memory: memory, isLexical: true, score: score(memory, lexical: true, mode: query.mode)))
            }
        }

        // Pinned first, then by score; ties fall to the id so the same memories always come out in
        // the same order (which also keeps the prompt prefix stable between requests).
        candidates.sort { lhs, rhs in
            let (lhsPinned, rhsPinned) = (lhs.memory.state == .pinned, rhs.memory.state == .pinned)
            if lhsPinned != rhsPinned { return lhsPinned }
            if lhs.score != rhs.score { return lhs.score > rhs.score }
            return lhs.memory.id.uuidString < rhs.memory.id.uuidString
        }

        var picked: [WritingMemory] = []
        var habits = 0
        var characters = 0
        for candidate in candidates {
            guard picked.count < LearningPolicy.maxPersonalizedMemories else { break }
            if !candidate.isLexical, habits >= LearningPolicy.maxHabitMemories { continue }
            let cost = LearningPolicy.promptCost(of: candidate.memory)
            guard characters + cost <= LearningPolicy.maxPersonalizationCharacters else { continue }
            picked.append(candidate.memory)
            characters += cost
            if !candidate.isLexical { habits += 1 }
        }
        return picked
    }

    /// A trigger in the text outweighs everything else; otherwise better-evidenced, more often seen
    /// and mode-specific memories come first.
    private func score(_ memory: WritingMemory, lexical: Bool, mode: WritingMode) -> Double {
        (lexical ? 1.0 : 0)
            + 0.3 * memory.confidence
            + 0.1 * min(1, Double(memory.occurrenceCount) / 10)
            + (memory.modeScope == mode ? 0.1 : 0)
    }

    private func languageFits(_ memory: WritingMemory, query: Query, profile: TextProfile, habit: Bool) -> Bool {
        // A translation memory's language is the one being written, not the text's.
        if memory.modeScope == .translate, query.mode == .translate {
            return query.outputLanguage.map { $0 == memory.language } ?? true
        }
        return habit ? profile.dominates(memory.language) : profile.mentions(memory.language)
    }

    /// Every run of up to `longestLatinTrigger` consecutive words, so a trigger is one lookup.
    private func latinNGrams(in text: String) -> Set<String> {
        guard longestLatinTrigger > 0 else { return [] }
        let tokenizer = NLTokenizer(unit: .word)
        tokenizer.string = text
        var words: [String] = []
        tokenizer.enumerateTokens(in: text.startIndex..<text.endIndex) { range, _ in
            words.append(text[range].lowercased())
            return true
        }
        var grams = Set<String>()
        for length in 1...longestLatinTrigger where words.count >= length {
            for start in 0...(words.count - length) {
                grams.insert(words[start..<(start + length)].joined(separator: " "))
            }
        }
        return grams
    }
}
