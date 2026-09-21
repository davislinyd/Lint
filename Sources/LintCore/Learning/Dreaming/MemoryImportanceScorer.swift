import Foundation

/// How important a memory is on a 0...1 scale: worth combining with others and worth keeping.
/// Deterministic, and never read from the memory's text or identity. It is not the reason a pinned
/// or hand-edited memory is left alone: those are excluded before any score is looked at.
enum MemoryImportanceScorer {
    typealias Weights = LearningPolicy.Importance

    static func score(_ memory: WritingMemory, at now: Date) -> Double {
        let value = Weights.confidenceWeight * memory.confidence(at: now)
            + Weights.recurrenceWeight * recurrence(memory)
            + Weights.usefulnessWeight * usefulness(memory)
            + Weights.recencyWeight * recency(memory, at: now)
            + Weights.explicitWeight * explicitSignal(memory)
            - Weights.contradictionWeight * contradictionRate(memory)
        return min(1, max(0, value))
    }

    /// How often the pattern has been seen, up to the point where more no longer says more.
    private static func recurrence(_ memory: WritingMemory) -> Double {
        min(1, Double(max(0, memory.occurrenceCount)) / Weights.recurrenceCap)
    }

    /// How often being in a prompt paid off. With no history it is a neutral 0.5 instead of a
    /// division by nothing, and a memory that was used once does not jump to 1 or fall to 0.
    private static func usefulness(_ memory: WritingMemory) -> Double {
        let retrievals = max(0, memory.retrievalCount)
        let successes = min(max(0, memory.successfulUseCount), retrievals)
        return (Double(successes) + 1) / (Double(retrievals) + 2)
    }

    private static func recency(_ memory: WritingMemory, at now: Date) -> Double {
        let last = max(memory.lastConfirmedAt, memory.lastUsedAt ?? .distantPast)
        let days = max(0, now.timeIntervalSince(last)) / 86_400
        return pow(0.5, days / Weights.recencyHalfLifeDays)
    }

    /// Pinning or rewriting a memory is the user saying it matters.
    private static func explicitSignal(_ memory: WritingMemory) -> Double {
        memory.state == .pinned || memory.userEdited ? 1 : 0
    }

    /// The share of what was observed that went against the memory.
    private static func contradictionRate(_ memory: WritingMemory) -> Double {
        let against = Double(max(0, memory.contradictionCount))
        let total = Double(max(0, memory.occurrenceCount)) + against
        return total > 0 ? against / total : 0
    }
}
