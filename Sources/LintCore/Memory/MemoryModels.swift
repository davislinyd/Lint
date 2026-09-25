import Foundation

/// How the user resolved a suggestion.
public enum FeedbackAction: String, Codable, CaseIterable, Sendable {
    case accepted
    case editedAndAccepted
    case copied
    case regenerated
}

public enum MemoryKind: String, Codable, CaseIterable, Sendable {
    case spelling
    case grammar
    case vocabulary
    case terminology
    case style
}

public enum MemoryState: String, Codable, CaseIterable, Sendable {
    case candidate
    case active
    case pinned
    case disabled
    case archived
}

/// How far a memory has been generalized.
public enum MemoryLevel: String, Codable, CaseIterable, Sendable {
    /// A concrete remembered correction or preference.
    case specific
    /// A rule summarized from several compatible specific memories.
    case generalized
    /// A generalized rule that has kept proving itself over a long time.
    case core
}

/// What happened, without the text itself: only keyed hashes, so events can be de-duplicated
/// without keeping what the user wrote.
public struct FeedbackEvent: Codable, Sendable, Equatable, Identifiable {
    public var id: UUID
    public var createdAt: Date
    public var mode: WritingMode
    public var tone: WritingTone = .preserve
    public var action: FeedbackAction
    public var sourceHMAC: String
    public var suggestionHMAC: String?
    public var finalHMAC: String?
    public var provider: String
    public var model: String
    /// Memories that were in the prompt for this suggestion.
    public var usedMemoryIDs: [UUID]
}

/// A reusable writing habit or preference, abstracted away from the text it came from.
public struct WritingMemory: Codable, Sendable, Equatable, Identifiable {
    public var id: UUID
    /// Stable identity of the pattern (e.g. `spelling:en:prospective>perspective`); unique.
    public var dedupKey: String
    public var kind: MemoryKind
    /// Language tag such as `en` or `zh-Hant`.
    public var language: String
    /// nil applies to every writing mode.
    public var modeScope: WritingMode?
    /// nil applies to every tone.
    public var toneScope: WritingTone? = nil
    /// Words or phrases that make this memory relevant; empty means a general habit.
    public var triggers: [String]
    public var instruction: String
    public var evidenceScore: Double
    public var occurrenceCount: Int
    public var state: MemoryState
    /// The user rewrote `instruction` by hand.
    public var userEdited: Bool
    public var createdAt: Date
    public var lastConfirmedAt: Date
    public var level: MemoryLevel = .specific
    /// The generalized or core memory that stands in for this one. Only a pointer: this memory is
    /// left out of a prompt while that one is usable, and comes back on its own when it is not.
    /// That is different from `archived`, which says the pattern itself has faded.
    public var supersededBy: UUID?
    /// Times the memory was in a prompt whose suggestion the user went on to use.
    public var retrievalCount: Int = 0
    /// Times the model applied the memory as reminded and the user accepted it.
    public var successfulUseCount: Int = 0
    /// Times the user undid what the memory asks for.
    public var contradictionCount: Int = 0
    public var lastUsedAt: Date?
    public var lastConsolidatedAt: Date?
}

/// What the user did with a finished suggestion.
public enum UserGesture: Sendable {
    case replaced
    case copied
    case regenerated
}

/// Input to memory. It carries the full texts, which live only in memory: what gets persisted
/// is an event of keyed hashes.
public struct MemoryFeedback: Sendable {
    public var gesture: UserGesture
    public var mode: WritingMode
    /// How the suggestion was asked to sound. Always `preserve` for a mode that takes no tone.
    public var tone: WritingTone
    /// The text the suggestion was generated from.
    public var originalText: String
    /// nil while the suggestion is still streaming or failed; nothing is remembered from that.
    public var generatedText: String?
    /// What the user applied: the suggestion, possibly edited.
    public var finalText: String
    public var provider: String
    public var model: String
    /// Memories that were in the prompt that produced the suggestion.
    public var usedMemoryIDs: [UUID]

    public init(
        gesture: UserGesture,
        mode: WritingMode,
        tone: WritingTone = .preserve,
        originalText: String,
        generatedText: String?,
        finalText: String,
        provider: String,
        model: String,
        usedMemoryIDs: [UUID] = []
    ) {
        self.gesture = gesture
        self.mode = mode
        self.tone = mode.supportsTone ? tone : .preserve
        self.originalText = originalText
        self.generatedText = generatedText
        self.finalText = finalText
        self.provider = provider
        self.model = model
        self.usedMemoryIDs = usedMemoryIDs
    }

    /// False when there is no finished suggestion or no source text to compare it with.
    var canFormMemory: Bool {
        guard let generatedText else { return false }
        return !generatedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !originalText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

extension WritingMemory {
    /// Evidence as it stands at `date`. It fades once the pattern has not shown up for a while, and
    /// not at all while the user holds the memory (pinned or disabled).
    public func evidence(at date: Date) -> Double {
        evidenceScore * decayFactor(at: date)
    }

    /// 0...1 and rising with evidence; what the settings page shows and retrieval ranks by.
    public func confidence(at date: Date) -> Double {
        let evidence = evidence(at: date)
        return evidence / (evidence + 1)
    }

    func decayFactor(at date: Date) -> Double {
        guard state != .pinned, state != .disabled else { return 1 }
        let days = max(0, date.timeIntervalSince(lastConfirmedAt)) / 86_400
        let fading = max(0, days - MemoryPolicy.evidenceGraceDays)
        return pow(0.5, fading / MemoryPolicy.halfLifeDays(for: level))
    }
}

/// A system prompt with the user's remembered habits added.
public struct PersonalizedPrompt: Sendable, Equatable {
    public var systemPrompt: String
    /// The memories whose wording went into it, so feedback can tell what the model was reminded of.
    public var usedMemoryIDs: [UUID]

    public init(systemPrompt: String, usedMemoryIDs: [UUID]) {
        self.systemPrompt = systemPrompt
        self.usedMemoryIDs = usedMemoryIDs
    }
}

/// Snapshot of the user's memory settings. `SettingsStore` is bound to the main actor, so this
/// is what crosses into `MemoryCoordinator`.
public struct MemoryConfig: Sendable, Equatable {
    public var enabled: Bool

    public init(enabled: Bool) {
        self.enabled = enabled
    }
}

public struct MemoryStats: Sendable, Equatable {
    public var memoriesByState: [MemoryState: Int]
    public var eventCount: Int
    public var memoriesByLevel: [MemoryLevel: Int] = [:]
    /// Specific memories that a usable generalized or core memory currently stands in for.
    public var supersededCount = 0
    /// When memories were last dreamed; nil if that never finished.
    public var lastDreamAt: Date?

    public static let empty = MemoryStats(memoriesByState: [:], eventCount: 0)

    public func count(_ state: MemoryState) -> Int {
        memoriesByState[state] ?? 0
    }

    public func count(_ level: MemoryLevel) -> Int {
        memoriesByLevel[level] ?? 0
    }
}

/// Tunables in one place so tests can pin them down.
enum MemoryPolicy {
    static let eventRetentionCount = 5_000
    static let eventRetentionDays = 180
    /// The same source, action and final text within this window counts once.
    static let eventDedupeWindow: TimeInterval = 24 * 60 * 60
    /// A memory is used as soon as it is remembered (short-term, `candidate`). One that has not proved
    /// itself (see `MemoryLifecycle.isProven`) within this many days of last showing up is forgotten.
    static let shortTermDays = 7.0
    /// The evidence a memory has at least once it has proved itself and is long-term (`active`); one
    /// that gathers this much by evidence alone is long-term at once.
    static let activeThreshold = 1.0
    /// A long-term memory whose evidence has faded below this is forgotten, and so is any memory the
    /// user's undoing takes below it. Lower than the evidence a long-term memory starts from, so that
    /// it lasts a while without its pattern.
    static let demoteThreshold = 0.5

    /// Evidence starts to fade once a memory has gone this many days without its pattern showing up
    /// again, and then halves every `evidenceHalfLifeDays`. A habit that keeps recurring never fades.
    static let evidenceGraceDays = 30.0
    static let evidenceHalfLifeDays = 90.0
    /// A rule that sums up several habits, and one that has kept proving itself, fade more slowly
    /// than a single correction does.
    static let generalizedEvidenceHalfLifeDays = 180.0
    static let coreEvidenceHalfLifeDays = 365.0

    static func halfLifeDays(for level: MemoryLevel) -> Double {
        switch level {
        case .specific: evidenceHalfLifeDays
        case .generalized: generalizedEvidenceHalfLifeDays
        case .core: coreEvidenceHalfLifeDays
        }
    }
    /// A forgotten memory is kept as a trace, so that its pattern is recognised if it comes back;
    /// once the trace has faded below this, it is erased the next time a dream runs.
    static let archiveThreshold = 0.1
    /// Memories keep fading, and short-term ones run out, so a retriever this old is built again
    /// even if nothing has changed.
    static let retrieverMaxAge: TimeInterval = 60 * 60
    static let maxInstructionLength = 200

    /// What a prompt may carry: a few short reminders, so a small local context window stays free
    /// for the text itself.
    static let maxPersonalizedMemories = 5
    /// Of those, how many may be habits, which are not tied to anything in the text.
    static let maxHabitMemories = 2
    static let maxPersonalizationCharacters = 600
    /// The numbering and line break a memory costs once listed in a prompt.
    static let personalizationLineOverhead = 4

    /// What one memory takes of the prompt budget once listed.
    static func promptCost(of memory: WritingMemory) -> Int {
        memory.instruction.count + personalizationLineOverhead
    }
    /// A habit only applies to a text that is clearly in its language.
    static let minHabitLatinLetters = 8
    static let minHabitCJKCharacters = 4

    /// What one observation is worth. An edit is the user's own choice; accepting is a weaker
    /// yes, copying weaker still, and asking again says nothing about what to learn.
    static func evidenceWeight(for action: FeedbackAction) -> Double {
        switch action {
        case .accepted: 0.15
        case .editedAndAccepted: 0.35
        case .copied: 0.05
        case .regenerated: 0
        }
    }

    /// What one observation *against* a memory takes away: twice what the same observation would
    /// have added, because undoing what a memory asks for is a clear sign that it is wrong.
    static func contradictionWeight(for action: FeedbackAction) -> Double {
        2 * evidenceWeight(for: action)
    }
}
