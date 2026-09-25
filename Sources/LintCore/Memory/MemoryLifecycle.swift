import Foundation

/// How a memory grows and fades, and which state it rests in.
///
/// A memory is used as soon as it is remembered: it is short-term (`candidate`). Once it has proved
/// itself it is long-term (`active`); if it has not within `MemoryPolicy.shortTermDays`, it is
/// forgotten (`archived`). A forgotten memory is only a trace, kept so that its pattern is recognised
/// if it comes back, and it is erased once the trace has faded (see `MemoryDreamCoordinator`).
///
/// Evidence is kept as it stood at `lastConfirmedAt` and fades from there (see
/// `WritingMemory.evidence(at:)`). Whatever changes a memory first settles that fading into the
/// stored value and restarts the clock, so the two never count the same time twice.
enum MemoryLifecycle {
    /// Whether a memory has shown that it is worth keeping: its pattern came back, either seen again
    /// or seen again while the model was reminded of it and the user took the fix (which is the
    /// user's text repeating the habit, not the reminder confirming itself), and the user has never
    /// undone it. A memory the user rewrote by hand has been judged by the user.
    static func isProven(_ memory: WritingMemory) -> Bool {
        if memory.userEdited { return true }
        guard memory.contradictionCount == 0 else { return false }
        return memory.occurrenceCount >= 2 || memory.successfulUseCount >= 1
    }

    /// A change the model made and the user only accepted, which depends on its sentence: another
    /// word ("used" for "able"), or the same word in another form ("tickets" for "ticket"). One such
    /// fix says little about a habit, so the memory is used only once its pattern has come back.
    /// Told apart by the wording it was stored with, so memories remembered before this rule follow it.
    static func waitsForRecurrence(_ memory: WritingMemory) -> Bool {
        guard memory.level == .specific, !isProven(memory) else { return false }
        switch MemoryWording(chinese: memory.instruction) {
        case .acceptedReplacement?: return true
        case .misspelling(let wrong, let right)?: return MemoryExtractor.isInflection(wrong, right)
        default: return false
        }
    }

    /// Short-term, long-term or pinned: the memories a prompt may be reminded of.
    static func isUsed(_ memory: WritingMemory) -> Bool {
        memory.state == .candidate || memory.state == .active || memory.state == .pinned
    }

    /// Folds one observation into what is known about the pattern. Pinned and disabled memories
    /// keep their state; the wording never changes once a memory exists, so the user's own edits
    /// stay. New evidence wakes a forgotten memory: it is short-term again, and has come back.
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
            toneScope: candidate.toneScope,
            triggers: [],
            instruction: candidate.instruction,
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
        if memory.state == .archived { memory.state = .candidate }
        if memory.state == .candidate {
            memory.state = restingState(evidenceScore: memory.evidenceScore)
        }
        return memory
    }

    /// Another observation of a pattern that a generalized memory stands for: it counts for that
    /// memory too, as if it had been seen there. The wording, and the state the user gave it, stay.
    static func supported(_ memory: WritingMemory, weight: Double, at now: Date) -> WritingMemory {
        var memory = memory
        memory.evidenceScore = memory.evidence(at: now) + weight
        memory.occurrenceCount += 1
        memory.lastConfirmedAt = now
        if memory.state == .archived { memory.state = .candidate }
        if memory.state == .candidate {
            memory.state = restingState(evidenceScore: memory.evidenceScore)
        }
        return memory
    }

    /// Takes evidence away, because the user undid what the memory asks for. A short-term or
    /// long-term memory left well below the bar is forgotten at once; pinned, disabled and forgotten
    /// ones keep their state. This is no confirmation, so the clock is not restarted: the stored
    /// value is set so that, counted from the same last confirmation, it reads what is left today.
    static func weakened(_ memory: WritingMemory, by amount: Double, at now: Date) -> WritingMemory {
        var memory = memory
        let factor = memory.decayFactor(at: now)
        let remaining = max(0, memory.evidence(at: now) - amount)
        memory.evidenceScore = factor > 0 ? remaining / factor : 0
        memory.contradictionCount += 1
        if memory.state == .active || memory.state == .candidate, remaining < MemoryPolicy.demoteThreshold {
            memory.state = .archived
        }
        return memory
    }

    /// Where a memory stands at `now`: the one place where remembering and forgetting are decided,
    /// so that what a prompt is reminded of, what Settings shows and what a dream writes all agree.
    /// Applying it again changes nothing. Pinned and disabled memories are the user's and never move;
    /// a forgotten one stays forgotten until its pattern comes back (see `merging`).
    ///
    /// A short-term memory that has proved itself (`isProven`) is long-term, with at least the
    /// evidence a long-term memory starts from. One that has not within `shortTermDays` of last
    /// showing up is forgotten, and so is one that waits for its pattern to come back. A long-term
    /// memory whose evidence has faded below `demoteThreshold` is forgotten too.
    static func settled(_ memory: WritingMemory, at now: Date) -> WritingMemory {
        var memory = memory
        switch memory.state {
        case .pinned, .disabled, .archived:
            return memory
        case .candidate:
            guard isProven(memory) else {
                let idle = now.timeIntervalSince(memory.lastConfirmedAt)
                if idle > MemoryPolicy.shortTermDays * 86_400 || waitsForRecurrence(memory) {
                    memory.state = .archived
                }
                return memory
            }
            memory.state = .active
            memory.evidenceScore = max(memory.evidenceScore, MemoryPolicy.activeThreshold)
        case .active:
            break
        }
        if memory.evidence(at: now) < MemoryPolicy.demoteThreshold {
            memory.state = .archived
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
    /// or dormant does not count against it: it fades from now on. A forgotten one comes back as
    /// long-term, since the user asked for it.
    static func resumed(_ memory: WritingMemory, at now: Date) -> WritingMemory {
        var memory = memory
        var evidence = memory.evidence(at: now)
        if memory.state == .archived { evidence = max(evidence, MemoryPolicy.activeThreshold) }
        memory.evidenceScore = evidence
        memory.lastConfirmedAt = now
        memory.state = restingState(evidenceScore: evidence)
        return memory
    }

    /// The generalized memory that `proposal` describes, with the evidence of the sources it has not
    /// counted yet added to it. Nil when there is nothing to write: the memory is disabled (it stays
    /// off), or all of these sources were counted before.
    ///
    /// The evidence is summed as it stood when the newest of the sources was last confirmed, which is
    /// also when the memory counts as confirmed: it is not fresher than the habit it summarizes, and
    /// it fades from there. An existing memory keeps its wording, whoever wrote it, and its state if
    /// the user holds it.
    static func consolidated(
        _ proposal: ConsolidationProposal,
        from application: ConsolidationApplication,
        at now: Date
    ) -> WritingMemory? {
        let existing = application.existingParent
        if existing?.state == .disabled { return nil }
        let added = application.sources.filter { !application.linkedSourceIDs.contains($0.id) }
        guard let newest = added.map(\.lastConfirmedAt).max() else { return nil }
        let confirmed = max(existing?.lastConfirmedAt ?? .distantPast, newest)

        var memory = existing ?? WritingMemory(
            id: UUID(),
            dedupKey: proposal.parentDedupKey,
            kind: proposal.kind,
            language: proposal.language,
            modeScope: proposal.modeScope,
            toneScope: proposal.toneScope,
            triggers: proposal.triggers,
            instruction: proposal.instruction,
            evidenceScore: 0,
            occurrenceCount: 0,
            state: .candidate,
            userEdited: false,
            createdAt: now,
            lastConfirmedAt: confirmed,
            level: proposal.targetLevel
        )
        memory.evidenceScore = memory.evidence(at: confirmed) + added.reduce(0) { $0 + $1.evidence(at: confirmed) }
        memory.occurrenceCount += added.reduce(0) { $0 + $1.occurrenceCount }
        memory.contradictionCount += added.reduce(0) { $0 + $1.contradictionCount }
        memory.lastConfirmedAt = confirmed
        memory.lastConsolidatedAt = now
        if memory.state == .archived { memory.state = .candidate }
        if memory.state == .candidate {
            memory.state = restingState(evidenceScore: memory.evidenceScore)
        }
        return memory
    }

    /// The memory earns a higher level. What it has faded to so far is settled into the stored value
    /// and the clock restarts, so that the longer half-life of the new level applies from now on and
    /// does not change what the memory is worth today.
    static func promoted(_ memory: WritingMemory, to level: MemoryLevel, at now: Date) -> WritingMemory {
        var memory = memory
        memory.evidenceScore = memory.evidence(at: now)
        memory.lastConfirmedAt = now
        memory.lastConsolidatedAt = now
        memory.level = level
        return memory
    }

    /// Where a memory settles when the user has neither pinned nor disabled it.
    static func restingState(evidenceScore: Double) -> MemoryState {
        // The tolerance keeps sums like 3 × 0.35 from missing the threshold by rounding.
        evidenceScore >= MemoryPolicy.activeThreshold - 1e-9 ? .active : .candidate
    }
}
