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

/// What happened, without the text itself: only keyed hashes, so events can be de-duplicated
/// without keeping what the user wrote.
public struct FeedbackEvent: Codable, Sendable, Equatable, Identifiable {
    public var id: UUID
    public var createdAt: Date
    public var mode: WritingMode
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
    /// Words or phrases that make this memory relevant; empty means a general habit.
    public var triggers: [String]
    public var instruction: String
    public var negativeExample: String?
    public var preferredExample: String?
    public var evidenceScore: Double
    public var occurrenceCount: Int
    public var state: MemoryState
    /// The user rewrote `instruction` by hand.
    public var userEdited: Bool
    public var createdAt: Date
    public var lastConfirmedAt: Date
}

/// Snapshot of the user's learning settings. `SettingsStore` is bound to the main actor, so this
/// is what crosses into `LearningCoordinator`.
public struct LearningConfig: Sendable, Equatable {
    public var enabled: Bool

    public init(enabled: Bool) {
        self.enabled = enabled
    }
}

public struct LearningStats: Sendable, Equatable {
    public var memoriesByState: [MemoryState: Int]
    public var eventCount: Int

    public static let empty = LearningStats(memoriesByState: [:], eventCount: 0)

    public func count(_ state: MemoryState) -> Int {
        memoriesByState[state] ?? 0
    }
}

/// Tunables in one place so tests can pin them down.
enum LearningPolicy {
    static let eventRetentionCount = 5_000
    static let eventRetentionDays = 180
}
