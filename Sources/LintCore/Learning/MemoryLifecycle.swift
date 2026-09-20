import Foundation

/// How a memory grows and fades, and which state it rests in.
///
/// Evidence is kept as it stood at `lastConfirmedAt` and fades from there (see
/// `WritingMemory.evidence(at:)`). Whatever changes a memory first settles that fading into the
/// stored value and restarts the clock, so the two never count the same time twice.
enum MemoryLifecycle {
    /// Folds one observation into what is known about the pattern. Pinned and disabled memories
    /// keep their state; the wording never changes once a memory exists, so the user's own edits
    /// stay. New evidence wakes a memory that had faded away and been archived.
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
        memory.evidenceScore = memory.evidence(at: now) + weight
        memory.occurrenceCount += 1
        memory.lastConfirmedAt = now
        // A phrase seen in the user's own text is a trigger, even if it was first seen elsewhere.
        if memory.triggers.isEmpty { memory.triggers = candidate.triggers }
        if memory.negativeExample == nil { memory.negativeExample = candidate.negativeExample }
        if memory.preferredExample == nil { memory.preferredExample = candidate.preferredExample }
        if memory.state == .archived { memory.state = .candidate }
        if memory.state == .candidate {
            memory.state = restingState(evidenceScore: memory.evidenceScore)
        }
        return memory
    }

    /// Takes evidence away, because the user undid what the memory asks for. An active memory that
    /// falls well below the bar is a candidate again; pinned, disabled and archived ones keep their
    /// state. This is no confirmation, so the clock is not restarted: the stored value is set so
    /// that, counted from the same last confirmation, it reads what is left today.
    static func weakened(_ memory: WritingMemory, by amount: Double, at now: Date) -> WritingMemory {
        var memory = memory
        let factor = memory.decayFactor(at: now)
        let remaining = max(0, memory.evidence(at: now) - amount)
        memory.evidenceScore = factor > 0 ? remaining / factor : 0
        if memory.state == .active, remaining < LearningPolicy.demoteThreshold {
            memory.state = .candidate
        }
        return memory
    }

    /// Where a memory stands once its evidence has faded. Pinned and disabled memories are the
    /// user's and never move. A candidate that has faded away is archived; an active one that has
    /// faded below the bar to stay active is a candidate again.
    static func settled(_ memory: WritingMemory, at now: Date) -> WritingMemory {
        guard memory.state == .candidate || memory.state == .active else { return memory }
        let evidence = memory.evidence(at: now)
        var memory = memory
        if evidence < LearningPolicy.archiveThreshold {
            memory.state = .archived
        } else if memory.state == .active, evidence < LearningPolicy.demoteThreshold {
            memory.state = .candidate
        }
        return memory
    }

    /// The pattern showed up again in the user's text and the model handled it as reminded. That
    /// says the habit persists, but it is no new evidence that the fix is wanted (the reminder
    /// explains it), so only the clock is restarted and the evidence is not added to.
    static func refreshed(_ memory: WritingMemory, at now: Date) -> WritingMemory {
        guard memory.state == .candidate || memory.state == .active else { return memory }
        var memory = memory
        memory.evidenceScore = memory.evidence(at: now)
        memory.lastConfirmedAt = now
        return memory
    }

    /// The user holds the memory (pins or disables it): what it has faded to so far is fixed, and
    /// it no longer fades.
    static func held(_ memory: WritingMemory, as state: MemoryState, at now: Date) -> WritingMemory {
        var memory = memory
        memory.evidenceScore = memory.evidence(at: now)
        memory.state = state
        return memory
    }

    /// The user gives a memory back to the lifecycle (unpins or enables it). The time it was held
    /// or dormant does not count against it: it fades from now on. One that had faded away and
    /// been archived starts again as active, since the user asked for it.
    static func resumed(_ memory: WritingMemory, at now: Date) -> WritingMemory {
        var memory = memory
        var evidence = memory.evidence(at: now)
        if memory.state == .archived { evidence = max(evidence, LearningPolicy.activeThreshold) }
        memory.evidenceScore = evidence
        memory.lastConfirmedAt = now
        memory.state = restingState(evidenceScore: evidence)
        return memory
    }

    /// Where a memory settles when the user has neither pinned nor disabled it.
    static func restingState(evidenceScore: Double) -> MemoryState {
        // The tolerance keeps sums like 3 × 0.35 from missing the threshold by rounding.
        evidenceScore >= LearningPolicy.activeThreshold - 1e-9 ? .active : .candidate
    }
}
