import Foundation
import NaturalLanguage

/// Picks the few memories worth reminding the model about for one text. Built once from the
/// memories that may be used (the coordinator keeps it in memory), so a query never reads the
/// database.
///
/// Two channels: a memory whose trigger appears in the text, and a habit (no trigger) that fits
/// the text's language. Both are ranked, and the result stays within the prompt budget.
///
/// A specific memory that a generalized or core memory stands in for (`supersededBy`, and that
/// memory is in use right now) is left out, since the rule already says it. It is only brought back
/// by its own trigger in the text, which is more precise than the rule, and then it takes the rule's
/// place in the prompt rather than being told alongside it. Once the rule is not in use (faded,
/// disabled, deleted), nothing is left out on its account.
struct MemoryRetriever: Sendable {
    struct Query: Sendable {
        var text: String
        var mode: WritingMode
        var tone: WritingTone = .preserve
        /// The language the result is written in when it is not the text's own (translation).
        var outputLanguage: String?
    }

    private struct Entry: Sendable {
        let memory: WritingMemory
        /// Lower-cased, words separated by single spaces.
        let latinTriggers: [String]
        let cjkTriggers: [String]
        /// The generalized or core memory in use that stands in for this one.
        let coveredBy: UUID?

        var isHabit: Bool { latinTriggers.isEmpty && cjkTriggers.isEmpty }
    }

    private struct Candidate {
        let memory: WritingMemory
        let isLexical: Bool
        let score: Double
        let coveredBy: UUID?
    }

    private let entries: [Entry]
    private let longestLatinTrigger: Int
    private let now: Date

    /// Evidence fades and short-term memories run out, so every memory is judged as it stands at
    /// `now`: short-term, long-term and pinned ones can be retrieved (a memory is used as soon as it
    /// is remembered), and of two that ask for opposite things (`a>b` and `b>a`) only the
    /// better-evidenced one: a prompt must not tell the model both.
    init(memories: [WritingMemory], now: Date = Date()) {
        self.now = now
        let usable = memories
            .map { MemoryLifecycle.settled($0, at: now) }
            .filter(MemoryLifecycle.isUsed)
        let byKey = Dictionary(usable.map { ($0.dedupKey, $0) }, uniquingKeysWith: { first, _ in first })
        let rulesInUse = Set(usable.filter { $0.level != .specific }.map(\.id))
        entries = usable
            .filter { memory in
                guard let key = MemoryExtractor.reversedKey(of: memory.dedupKey),
                      let opposite = byKey[key] else { return true }
                return !Self.loses(memory, to: opposite, at: now)
            }
            .map { memory in
                Entry(
                    memory: memory,
                    latinTriggers: memory.triggers
                        .filter { !$0.isEmpty && !$0.unicodeScalars.contains(where: Script.isCJK) }
                        .map(WordToken.key(of:)),
                    cjkTriggers: memory.triggers.filter { $0.unicodeScalars.contains(where: Script.isCJK) },
                    coveredBy: memory.level == .specific
                        ? memory.supersededBy.flatMap { rulesInUse.contains($0) ? $0 : nil }
                        : nil
                )
            }
        longestLatinTrigger = min(
            4, entries.flatMap(\.latinTriggers).map { $0.split(separator: " ").count }.max() ?? 0
        )
    }

    /// A pinned memory is the user's choice and beats an unpinned one (two pinned ones both stay);
    /// otherwise more evidence wins, then the more recently confirmed, then the id, so exactly one
    /// of the pair goes.
    private static func loses(_ memory: WritingMemory, to opposite: WritingMemory, at now: Date) -> Bool {
        let (pinned, oppositePinned) = (memory.state == .pinned, opposite.state == .pinned)
        if pinned != oppositePinned { return oppositePinned }
        if pinned { return false }
        let (evidence, oppositeEvidence) = (memory.evidence(at: now), opposite.evidence(at: now))
        if evidence != oppositeEvidence { return evidence < oppositeEvidence }
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
            guard memory.toneScope == nil || memory.toneScope == query.tone else { continue }
            // Lint edits English only: a proofread is never reminded of a Chinese term or habit, which
            // would ask for the Chinese of a mixed text to change. A translation, which writes
            // Chinese, still is.
            guard query.mode != .proofread || memory.language == "en" else { continue }
            if entry.isHabit {
                // Covered, and with no trigger of its own to bring it back.
                guard entry.coveredBy == nil else { continue }
                guard languageFits(memory, query: query, profile: profile, habit: true) else { continue }
                candidates.append(Candidate(
                    memory: memory, isLexical: false, score: score(memory, lexical: false, mode: query.mode),
                    coveredBy: nil
                ))
            } else if entry.latinTriggers.contains(where: grams.contains)
                        || entry.cjkTriggers.contains(where: query.text.contains),
                      languageFits(memory, query: query, profile: profile, habit: false) {
                candidates.append(Candidate(
                    memory: memory, isLexical: true, score: score(memory, lexical: true, mode: query.mode),
                    coveredBy: entry.coveredBy
                ))
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

        // A memory picked for its own trigger says more than the rule that covers it, so the rule
        // is left out (unless the user pinned it) and what it made room for goes to the next in line.
        var displaced = Set<UUID>()
        while true {
            let picked = pick(from: candidates.filter { !displaced.contains($0.memory.id) })
            let rules = Set(picked.compactMap(\.coveredBy)).subtracting(displaced)
                .filter { rule in !candidates.contains { $0.memory.id == rule && $0.memory.state == .pinned } }
            if rules.isEmpty { return picked.map(\.memory) }
            displaced.formUnion(rules)
        }
    }

    /// The best of `candidates` (already in order) that fit the prompt budget.
    private func pick(from candidates: [Candidate]) -> [Candidate] {
        var picked: [Candidate] = []
        var habits = 0
        var characters = 0
        for candidate in candidates {
            guard picked.count < MemoryPolicy.maxPersonalizedMemories else { break }
            if !candidate.isLexical, habits >= MemoryPolicy.maxHabitMemories { continue }
            let cost = MemoryPolicy.promptCost(of: candidate.memory)
            guard characters + cost <= MemoryPolicy.maxPersonalizationCharacters else { continue }
            picked.append(candidate)
            characters += cost
            if !candidate.isLexical { habits += 1 }
        }
        return picked
    }

    /// A trigger in the text outweighs everything else, and a memory that sums up several others
    /// outweighs a single one of the same kind, though never a single memory whose trigger is in
    /// the text; after that better-evidenced, more often seen and mode-specific memories come first.
    /// (The tiers are further apart than the rest can add up to.)
    private func score(_ memory: WritingMemory, lexical: Bool, mode: WritingMode) -> Double {
        let tier: Double = switch (memory.level, lexical) {
        case (.specific, true): 2.0
        case (.core, true): 1.4
        case (.generalized, true): 1.3
        case (.core, false): 0.7
        case (.generalized, false): 0.6
        case (.specific, false): 0
        }
        return tier
            + 0.3 * memory.confidence(at: now)
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
            words.append(WordToken.key(of: String(text[range])))
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
