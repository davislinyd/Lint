import Foundation

/// How a memory grows, and which state it rests in.
enum MemoryLifecycle {
    /// Folds one observation into what is known about the pattern. Pinned, disabled and archived
    /// memories keep their state, and the wording never changes once a memory exists, so the
    /// user's own edits stay.
    static func merging(
        _ candidate: MemoryCandidate,
        weight: Double,
        at now: Date,
        into existing: WritingMemory?
    ) -> WritingMemory {
        var memory = existing ?? WritingMemory(
            id: UUID(),
            dedupKey: candidate.dedupKey,
            kind: candidate.kind,
            language: candidate.language,
            modeScope: candidate.modeScope,
            triggers: [],
            instruction: candidate.instruction,
            negativeExample: nil,
            preferredExample: nil,
            evidenceScore: 0,
            occurrenceCount: 0,
            state: .candidate,
            userEdited: false,
            createdAt: now,
            lastConfirmedAt: now
        )
        memory.evidenceScore += weight
        memory.occurrenceCount += 1
        memory.lastConfirmedAt = now
        // A phrase seen in the user's own text is a trigger, even if it was first seen elsewhere.
        if memory.triggers.isEmpty { memory.triggers = candidate.triggers }
        if memory.negativeExample == nil { memory.negativeExample = candidate.negativeExample }
        if memory.preferredExample == nil { memory.preferredExample = candidate.preferredExample }
        if memory.state == .candidate {
            memory.state = restingState(evidenceScore: memory.evidenceScore)
        }
        return memory
    }

    /// Takes evidence away, because the user undid what the memory asks for. An active memory that
    /// falls well below the bar is a candidate again; pinned, disabled and archived ones keep their
    /// state, and nothing else about the memory changes (this is no confirmation of it).
    static func weakened(_ memory: WritingMemory, by amount: Double) -> WritingMemory {
        var memory = memory
        memory.evidenceScore = max(0, memory.evidenceScore - amount)
        if memory.state == .active, memory.evidenceScore < LearningPolicy.demoteThreshold {
            memory.state = .candidate
        }
        return memory
    }

    /// Where a memory settles when the user has neither pinned nor disabled it.
    static func restingState(evidenceScore: Double) -> MemoryState {
        // The tolerance keeps sums like 3 × 0.35 from missing the threshold by rounding.
        evidenceScore >= LearningPolicy.activeThreshold - 1e-9 ? .active : .candidate
    }
}
