import Foundation

/// Organizes memories in the background: many specific memories of one family become one
/// generalized memory, the specific ones stay behind it, and a generalized memory that keeps proving
/// itself becomes core. Nothing here is fine-tuning, and nothing leaves the Mac.
///
/// It is maintenance, so it must never get in the way of writing: it keeps to itself (an actor of
/// its own, so a suggestion never waits for it), reads once, computes in memory, writes a short
/// transaction per cluster, and swallows its own failures (they are logged and recorded, and the
/// memories stay as they were).
///
/// Running it again on memories that have not changed changes nothing.
actor MemoryDreamCoordinator {
    private let store: any LearningStore
    private let clusterer: MemoryClusterer
    private let consolidator: MemoryConsolidator
    private let validator = MemoryConsolidationValidator()
    private let clock: @Sendable () -> Date
    private var isRunning = false

    init(
        store: any LearningStore,
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
    /// pass at the next cluster, and so does the user waiting on a suggestion when a `gate` is given;
    /// what was written by then stays, since each cluster is all or nothing.
    @discardableResult
    func run(yieldingTo gate: InteractiveGate? = nil) async -> DreamRun? {
        guard !isRunning else { return nil }
        isRunning = true
        defer { isRunning = false }

        var record = DreamRun(
            id: UUID(), startedAt: clock(), finishedAt: nil,
            algorithmVersion: LearningPolicy.dreamAlgorithmVersion,
            inputMemoryCount: 0, clusterCount: 0, generatedCount: 0, supersededCount: 0, status: .running
        )
        await save(record)
        do {
            try await organize(&record, gate: gate)
            record.status = .completed
        } catch is CancellationError {
            record.status = .cancelled
        } catch {
            NSLog("Lint learning: organizing memories failed: \(error.localizedDescription)")
            record.status = .failed
        }
        record.finishedAt = clock()
        await save(record)
        return record
    }

    /// The places where a pass may stop: between clusters, never in the middle of one.
    private static func checkpoint(_ gate: InteractiveGate?) throws {
        try Task.checkCancellation()
        if gate?.isBusy == true { throw CancellationError() }
    }

    private func organize(_ record: inout DreamRun, gate: InteractiveGate?) async throws {
        try Self.checkpoint(gate)
        let now = clock()
        let memories = try await store.memories()
        record.inputMemoryCount = memories.count

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

        let minimum = LearningPolicy.dreamMinClusterSize
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
                NSLog("Lint learning: dropped a proposed memory (\(rejection))")
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

    /// A generalized memory with too few sources left is put away (its sources are free again), and
    /// one that has proved itself is promoted. Memories the user holds or has reworded are left as
    /// they are.
    private func maintainParents(at now: Date, gate: InteractiveGate?) async throws {
        let counts = try await store.sourceCounts()
        for parent in try await store.memories() where parent.level != .specific {
            try Self.checkpoint(gate)
            guard parent.state == .active || parent.state == .candidate, !parent.userEdited else { continue }
            let count = counts[parent.id] ?? 0
            if count < LearningPolicy.dreamMinClusterSize {
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
            NSLog("Lint learning: could not record an organizing pass: \(failure.localizedDescription)")
        }
    }
}
