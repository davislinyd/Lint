import Foundation

/// How an explicit request to organize memories went (`LearningCoordinator.organizeMemories`).
public enum MemoryOrganizationOutcome: Sendable, Equatable {
    /// Learning is off, or there is nothing on disk.
    case unavailable
    /// A pass was already running.
    case alreadyRunning
    case finished(newRules: Int, coveredMemories: Int)
    case failed
}

enum DreamRunStatus: String, Sendable {
    case running
    case completed
    case failed
    case cancelled
}

/// What one organizing pass did, in numbers only: no memory text, and nothing of what the user
/// wrote. Kept for the settings page ("last organized") and for finding out why a pass went wrong.
struct DreamRun: Sendable, Equatable, Identifiable {
    var id: UUID
    var startedAt: Date
    var finishedAt: Date?
    var algorithmVersion: Int
    var inputMemoryCount: Int
    var clusterCount: Int
    var generatedCount: Int
    var supersededCount: Int
    var status: DreamRunStatus
}

extension LearningPolicy {
    /// How much a memory is worth keeping and combining. Each signal is 0...1; the weights add up
    /// to 1, and contradictions take away from the total.
    enum Importance {
        static let confidenceWeight = 0.30
        static let recurrenceWeight = 0.20
        static let usefulnessWeight = 0.20
        static let recencyWeight = 0.15
        static let explicitWeight = 0.15
        static let contradictionWeight = 0.30

        /// This many observations count as fully recurrent.
        static let recurrenceCap = 10.0
        /// Recency halves every this many days since the memory was last confirmed or used.
        static let recencyHalfLifeDays = 30.0
    }
}

extension LearningPolicy {
    /// Bumped when what organizing does changes in a way that old runs cannot be compared with.
    static let dreamAlgorithmVersion = 1

    /// A rule needs this many compatible memories behind it. Fewer is a coincidence.
    static let dreamMinClusterSize = 3
    /// Only memories that have been seen more than once, and for a few days, are combined: a burst
    /// of corrections in one sitting is no habit yet.
    static let dreamMinSourceOccurrences = 2
    static let dreamMinSourceAgeDays = 3.0
    /// Every pair in a cluster must be at least this alike, not just each memory and its neighbour.
    static let dreamSimilarityThreshold = 0.85
    /// What a generalized memory may list as triggers of its own.
    static let dreamMaxTriggers = 12

    /// Organizing waits until nothing has happened for this long, so that a run of feedback ends in
    /// one pass; after a failure it waits this long before it tries again.
    static let dreamIdleDelay = Duration.seconds(60)
    static let dreamRetryDelay = Duration.seconds(3_600)
    /// A pass at start-up if the last one was longer ago than this.
    static let dreamStartupInterval: TimeInterval = 24 * 60 * 60
    /// A pass once this many memories have been learned from or weakened since the last one.
    static let dreamChangeThreshold = 25
    /// A pass when this many memories are candidates or in use, though not more often than the cooldown.
    static let dreamPressureThreshold = 200
    static let dreamPressureCooldown: TimeInterval = 6 * 60 * 60

    /// A generalized memory becomes core only after all of these hold.
    static let coreMinSources = 5
    static let coreMinOccurrences = 12
    static let coreMinConfidence = 0.8
    static let coreMinSuccessfulUses = 3
    static let coreMinAgeDays = 14.0
    static let coreMaxContradictionRate = 0.1
}

/// A shape of memory that the extractor writes from one template, so that its members can be told
/// apart from other memories without reading their words.
enum MemoryFamily: String, Sendable, CaseIterable {
    /// `grammar:en:<verb> <preposition>`: the user deleted a preposition after a verb.
    case redundantPreposition = "redundant-preposition"

    static func of(_ memory: WritingMemory) -> MemoryFamily? {
        guard memory.level == .specific, memory.kind == .grammar, memory.language == "en",
              memory.modeScope == nil, memory.toneScope == nil,
              memory.dedupKey.hasPrefix(redundantPrepositionPrefix)
        else { return nil }
        let words = memory.dedupKey.dropFirst(redundantPrepositionPrefix.count)
            .split(separator: " ", omittingEmptySubsequences: false)
        guard words.count == 2, !words[0].isEmpty,
              MemoryExtractor.prepositions.contains(String(words[1])),
              words[0].unicodeScalars.allSatisfy({ CharacterSet.letters.contains($0) || $0 == "'" || $0 == "-" })
        else { return nil }
        return .redundantPreposition
    }

    private static let redundantPrepositionPrefix = "grammar:en:"
}

/// Which memories may be combined into a higher one. Pinned, disabled and hand-edited memories are
/// the user's and never are; neither is anything that is still new or thinly supported.
enum ConsolidationEligibility {
    static func canBeSource(_ memory: WritingMemory, at now: Date) -> Bool {
        memory.level == .specific
            && memory.state == .active
            && !memory.userEdited
            && memory.occurrenceCount >= LearningPolicy.dreamMinSourceOccurrences
            && now.timeIntervalSince(memory.createdAt) >= LearningPolicy.dreamMinSourceAgeDays * 86_400
    }
}

extension ConsolidationEligibility {
    /// A generalized memory becomes core only once it has kept proving itself: many sources, seen
    /// often, strongly supported, used successfully, old enough, and rarely undone. One the user
    /// holds or has reworded is not moved by itself.
    static func canBePromoted(_ memory: WritingMemory, sourceCount: Int, at now: Date) -> Bool {
        let against = Double(max(0, memory.contradictionCount))
        let observed = Double(max(0, memory.occurrenceCount)) + against
        let contradictionRate = observed > 0 ? against / observed : 0
        return memory.level == .generalized
            && memory.state == .active
            && !memory.userEdited
            && sourceCount >= LearningPolicy.coreMinSources
            && memory.occurrenceCount >= LearningPolicy.coreMinOccurrences
            && memory.confidence(at: now) >= LearningPolicy.coreMinConfidence
            && memory.successfulUseCount >= LearningPolicy.coreMinSuccessfulUses
            && now.timeIntervalSince(memory.createdAt) >= LearningPolicy.coreMinAgeDays * 86_400
            && contradictionRate <= LearningPolicy.coreMaxContradictionRate
    }
}

/// Memories that are alike enough, all of them, and compatible in what they apply to.
struct MemoryCluster: Sendable, Equatable {
    var language: String
    var kind: MemoryKind
    var modeScope: WritingMode?
    var toneScope: WritingTone?
    /// Most important first.
    var members: [WritingMemory]
}

/// What organizing wants to store, before anything is checked or written.
struct ConsolidationProposal: Sendable, Equatable {
    enum Origin: Sendable, Equatable {
        /// Worded by a fixed template for a family, from nothing but the family itself.
        case rule(MemoryFamily)
        /// Worded by a synthesis provider, and so only as safe as the validator makes it.
        case synthesized
    }

    /// Stable identity of the derived memory, so that running again finds it instead of making another.
    var parentDedupKey: String
    var sourceIDs: [UUID]
    var kind: MemoryKind
    var language: String
    var modeScope: WritingMode?
    var toneScope: WritingTone?
    var targetLevel: MemoryLevel
    var instruction: String
    var triggers: [String]
    var origin: Origin
    /// Words the instruction may use that the sources do not contain (a template's own examples).
    var allowedExtraWords: Set<String> = []
}

/// What a synthesis provider gets to see: the learned memories as they are stored, which are already
/// abstracted away from any text, and nothing of what the user wrote.
struct SynthesisSource: Sendable, Equatable {
    var id: UUID
    var kind: MemoryKind
    var language: String
    var mode: WritingMode?
    var tone: WritingTone?
    var instruction: String
    var triggers: [String]
    var confidence: Double
    var occurrenceCount: Int
}

enum SynthesisResult: Sendable, Equatable {
    /// The memories have no safe rule in common.
    case noConsolidation
    case rule(instruction: String, triggers: [String])
}

/// Words a higher-level rule from several compatible memories, in place of the fixed templates.
///
/// Nothing implements this yet. An implementation must run on this Mac, must never start a server,
/// install or download a model to do so, must give up when asked to (interactive work comes first),
/// and must answer with structured data rather than prose. Whatever it returns still has to pass
/// `MemoryConsolidationValidator` before anything is stored.
protocol MemorySynthesisProvider: Sendable {
    func synthesize(_ sources: [SynthesisSource]) async throws -> SynthesisResult
}
