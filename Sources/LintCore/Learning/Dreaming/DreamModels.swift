import Foundation

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
