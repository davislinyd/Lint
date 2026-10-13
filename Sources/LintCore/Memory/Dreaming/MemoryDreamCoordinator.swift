import Foundation

/// Dreams in the background, the way sleep sorts what was remembered during the day. What
/// has proved itself is written down as long-term and what has not as forgotten (the rules are in
/// `MemoryLifecycle.settled`), forgotten memories whose trace has faded are erased, many specific
/// memories of one family become one generalized memory (the specific ones stay behind it), and a
/// generalized memory that keeps proving itself becomes core. Nothing here is fine-tuning, and
/// nothing leaves the Mac.
///
/// It is maintenance, so it must never get in the way of writing: it keeps to itself (an actor of
/// its own, so a suggestion never waits for it), reads once, computes in memory, writes a short
/// transaction per cluster, and swallows its own failures (they are logged and recorded, and the
/// memories stay as they were).
///
/// Running it again on memories that have not changed changes nothing.
actor MemoryDreamCoordinator {
    private let store: any MemoryStore
    private let clusterer: MemoryClusterer
    private let consolidator: MemoryConsolidator
    private let validator = MemoryConsolidationValidator()
    private let clock: @Sendable () -> Date
    private var isRunning = false

    init(
        store: any MemoryStore,
        similarity: any MemorySimilarityService = StructuralMemorySimilarity(),
        synthesis: (any MemorySynthesisProvider)? = nil,
        clock: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.store = store
        // Small clusters are kept here: one may still join a memory that exists already.
        self.clusterer = MemoryClusterer(similarity: similarity, minClusterSize: 1)
        self.consolidator = MemoryConsolidator(synthesis: synthesis)
        self.clock = clock
    }

    /// One pass over the memories. Nil if another pass is still running. Cancelling the task ends the
    /// pass at the next memory or cluster, and so does the user waiting on a suggestion when a `gate`
    /// is given; what was written by then stays, since each step is all or nothing.
    @discardableResult
    func run(yieldingTo gate: InteractiveGate? = nil) async -> DreamRun? {
        guard !isRunning else { return nil }
        isRunning = true
        defer { isRunning = false }

        var record = DreamRun(
            id: UUID(), startedAt: clock(), finishedAt: nil,
            algorithmVersion: MemoryPolicy.dreamAlgorithmVersion,
            inputMemoryCount: 0, clusterCount: 0, generatedCount: 0, supersededCount: 0, status: .running
        )
        await save(record)
        do {
            try await organize(&record, gate: gate)
            record.status = .completed
        } catch is CancellationError {
            record.status = .cancelled
        } catch {
            DiagnosticLog.shared.log("memory", "dreaming failed: \(DiagnosticLog.describe(error))")
            record.status = .failed
        }
        record.finishedAt = clock()
        await save(record)
        return record
    }

    /// The places where a pass may stop: between memories and between clusters, never in the middle
    /// of one.
    private static func checkpoint(_ gate: InteractiveGate?) throws {
        try Task.checkCancellation()
        if gate?.isBusy == true { throw CancellationError() }
    }

    private func organize(_ record: inout DreamRun, gate: InteractiveGate?) async throws {
        try Self.checkpoint(gate)
        let now = clock()
        record.inputMemoryCount = try await store.memories().count
        try await settle(&record, at: now, gate: gate)
        try await erase(&record, at: now, gate: gate)
        try await adjust(&record, at: now, gate: gate)
        try await adjustApps(at: now, gate: gate)
        let memories = try await store.memories()

        // Judged as they stand today, whether or not they have been settled in the store yet.
        let settled = memories.map { MemoryLifecycle.settled($0, at: now) }
        let usableParents = Set(
            settled.filter { $0.level != .specific && ($0.state == .active || $0.state == .pinned) }.map(\.id)
        )
        let parents = Dictionary(
            settled.filter { $0.level != .specific }.map { ($0.dedupKey, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        // Behind a parent that is in use they are covered already; behind one that is not, they are free.
        let candidates = settled.filter { memory in
            ConsolidationEligibility.canBeSource(memory, at: now)
                && !(memory.supersededBy.map(usableParents.contains) ?? false)
        }

        let minimum = MemoryPolicy.dreamMinClusterSize
        for cluster in await clusterer.clusters(from: candidates, at: now) {
            try Self.checkpoint(gate)
            if cluster.members.count < minimum {
                // Too few for a rule of its own, but enough to join one that exists.
                guard let key = consolidator.ruleParentKey(for: cluster),
                      let existing = parents[key], existing.state != .disabled
                else { continue }
            }
            record.clusterCount += 1
            guard let proposal = await consolidator.proposal(for: cluster, at: now) else { continue }
            let joining = parents[proposal.parentDedupKey].map { $0.state != .disabled } ?? false
            if let rejection = validator.validate(
                proposal, cluster: cluster, minimumSources: joining ? 1 : minimum, at: now
            ) {
                DiagnosticLog.shared.log("memory", "dropped a proposed memory (\(rejection))")
                continue
            }
            let outcome = try await store.applyConsolidation(
                parentDedupKey: proposal.parentDedupKey, sourceIDs: proposal.sourceIDs, at: now
            ) { application in
                MemoryLifecycle.consolidated(proposal, from: application, at: now)
            }
            if case .applied(_, let created, let covered) = outcome {
                if created { record.generatedCount += 1 }
                record.supersededCount += covered
            }
        }
        try await maintainParents(at: now, gate: gate)
    }

    /// Writes down what the rules say about each memory now: proved short-term memories become
    /// long-term, and the ones that did not prove themselves, or faded, are forgotten. Each memory is
    /// written in a transaction of its own and judged again inside it, in case it changed meanwhile.
    private func settle(_ record: inout DreamRun, at now: Date, gate: InteractiveGate?) async throws {
        for memory in try await store.memories() {
            let settled = MemoryLifecycle.settled(memory, at: now)
            guard settled != memory else { continue }
            try Self.checkpoint(gate)
            try await store.updateMemory(id: memory.id) { current in
                current = MemoryLifecycle.settled(current, at: now)
            }
            if settled.state != memory.state {
                if settled.state == .active { record.rememberedCount += 1 }
                if settled.state == .archived { record.forgottenCount += 1 }
            }
        }
    }

    /// Erases the forgotten memories whose trace has faded away: their pattern did not come back
    /// while it could still be recognised. Which of them may go at all (specific ones the user did
    /// not rewrite; never a pinned, disabled, generalized or core one) the store decides, inside the
    /// transaction that erases them.
    private func erase(_ record: inout DreamRun, at now: Date, gate: InteractiveGate?) async throws {
        try Self.checkpoint(gate)
        let faded = try await store.memories().filter { memory in
            memory.state == .archived && memory.evidence(at: now) < MemoryPolicy.archiveThreshold
        }
        record.erasedCount = try await store.eraseMemories(ids: faded.map(\.id))
    }

    /// Brings the style profile, the one memory that says how the user writes, in line with what
    /// observation mode counted: a trait is taken up or dropped by `ObservationAdjuster`, and with
    /// none left the memory is put away. A profile the user pinned, disabled, reworded or deleted is
    /// theirs and is left alone. While it holds it is confirmed again by every pass, so it does not
    /// fade for want of new evidence: a trait the model respects is one it no longer touches.
    private func adjust(_ record: inout DreamRun, at now: Date, gate: InteractiveGate?) async throws {
        try Self.checkpoint(gate)
        let existing = try await store.memory(dedupKey: StyleProfile.dedupKey)
        if let existing {
            guard !existing.userEdited, existing.state != .pinned, existing.state != .disabled else { return }
        } else if try await store.isVetoed(dedupKey: StyleProfile.dedupKey) {
            return
        }
        let inUse = existing.map(MemoryLifecycle.isUsed) ?? false
        var held: Set<StyleTrait> = []
        if inUse, case .profile(let traits)? = existing.flatMap({ MemoryWording(chinese: $0.instruction) }) {
            held = Set(traits)
        }
        let counters = try await store.observationStats(prefix: StyleTrait.statPrefix)
        let traits = Set(StyleTrait.allCases.filter { trait in
            counters[trait.statKey].map {
                ObservationAdjuster.holds($0.faded(to: now), held: held.contains(trait))
            } ?? false
        })

        guard let instruction = MemoryWording.profile(of: traits)?.chinese else {
            guard inUse, let existing else { return }
            try await store.updateMemory(id: existing.id) { memory in
                guard !memory.userEdited, memory.state == .active || memory.state == .candidate else { return }
                memory.state = .archived
            }
            record.adjustedCount += 1
            return
        }
        if !inUse || traits != held { record.adjustedCount += 1 }
        try await store.mergeMemory(dedupKey: StyleProfile.dedupKey) { current in
            // Seen once and not from the user's words: never a source of a generalized memory.
            var memory = current ?? WritingMemory(
                id: UUID(), dedupKey: StyleProfile.dedupKey, kind: .style, language: "en", modeScope: nil,
                triggers: [], instruction: instruction, evidenceScore: 0, occurrenceCount: 1,
                state: .active, userEdited: false, createdAt: now, lastConfirmedAt: now
            )
            // Judged again here, in case the user got to it meanwhile.
            guard !memory.userEdited, memory.state != .pinned, memory.state != .disabled else { return memory }
            memory.instruction = instruction
            memory.state = .active
            memory.evidenceScore = max(memory.evidence(at: now), MemoryPolicy.activeThreshold)
            memory.lastConfirmedAt = now
            return memory
        }
    }

    /// Brings what Lint does differently per app in line with what observation mode counted there.
    /// An app goes quiet when its suggestions were never used, and stays so until one is (asking
    /// for a suggestion there also ends it, see `MemoryCoordinator.forget`); the tone used there
    /// most of the time is its own for as long as the counts say so.
    private func adjustApps(at now: Date, gate: InteractiveGate?) async throws {
        try Self.checkpoint(gate)
        let sessions = try await store.observationStats(prefix: ObservationKey.app)
        var adoptions: [String: [WritingTone: Double]] = [:]
        for (key, counter) in try await store.observationStats(prefix: ObservationKey.appTone) {
            let parts = key.dropFirst(ObservationKey.appTone.count).split(separator: ":", omittingEmptySubsequences: false)
            guard parts.count == 2, let tone = WritingTone(rawValue: String(parts[1])) else { continue }
            adoptions[String(parts[0]), default: [:]][tone] = counter.faded(to: now).positive
        }
        let existing = Dictionary(
            try await store.appAdjustments().map { ($0.app, $0) }, uniquingKeysWith: { first, _ in first }
        )
        let apps = Set(sessions.keys.map { String($0.dropFirst(ObservationKey.app.count)) })
            .union(adoptions.keys).union(existing.keys)
        for app in apps.sorted() {
            try Self.checkpoint(gate)
            var adjustment = existing[app] ?? AppAdjustment(app: app)
            if let counter = sessions[ObservationKey.app(app)]?.faded(to: now) {
                if ObservationAdjuster.isQuiet(counter) {
                    adjustment.quiet = true
                } else if counter.positive.rounded() >= 1 {
                    adjustment.quiet = false
                }
            }
            adjustment.tone = ObservationAdjuster.tone(from: adoptions[app] ?? [:])
            if adjustment != existing[app], !(existing[app] == nil && adjustment.isEmpty) {
                try await store.saveAppAdjustment(adjustment, at: now)
            }
        }
    }

    /// A generalized memory with too few sources left is put away (its sources are free again), and
    /// one that has proved itself is promoted. Memories the user holds or has reworded are left as
    /// they are.
    private func maintainParents(at now: Date, gate: InteractiveGate?) async throws {
        let counts = try await store.sourceCounts()
        for parent in try await store.memories() where parent.level != .specific {
            try Self.checkpoint(gate)
            guard parent.state == .active || parent.state == .candidate, !parent.userEdited else { continue }
            let count = counts[parent.id] ?? 0
            if count < MemoryPolicy.dreamMinClusterSize {
                try await store.updateMemory(id: parent.id) { memory in
                    guard memory.state == .active || memory.state == .candidate, !memory.userEdited else { return }
                    memory.state = .archived
                }
            } else if ConsolidationEligibility.canBePromoted(
                MemoryLifecycle.settled(parent, at: now), sourceCount: count, at: now
            ) {
                try await store.updateMemory(id: parent.id) { memory in
                    guard ConsolidationEligibility.canBePromoted(
                        MemoryLifecycle.settled(memory, at: now), sourceCount: count, at: now
                    ) else { return }
                    memory = MemoryLifecycle.promoted(memory, to: .core, at: now)
                }
            }
        }
    }

    /// Unstructured, so that a pass that was cancelled can still record that it was.
    private func save(_ record: DreamRun) async {
        let store = store
        let failure = await Task { () -> (any Error)? in
            do {
                try await store.recordDreamRun(record)
                return nil
            } catch {
                return error
            }
        }.value
        if let failure {
            DiagnosticLog.shared.log("memory", "could not record a dream: \(DiagnosticLog.describe(failure))")
        }
    }
}
