import Foundation

/// Persistence boundary of the learning subsystem; SQLite in the app, swappable in tests.
protocol LearningStore: Sendable {
    /// Inserts, or updates the row with the same `id`. A different `id` with an existing
    /// `dedupKey` is an error: merging evidence is the caller's job.
    func saveMemory(_ memory: WritingMemory) async throws
    /// Read-modify-write in one transaction: `transform` gets the memory with this `dedupKey`
    /// (nil if there is none) and returns what to keep.
    func mergeMemory(dedupKey: String, _ transform: @escaping @Sendable (WritingMemory?) -> WritingMemory) async throws
    /// Changes one memory in one transaction; does nothing if it is gone.
    func updateMemory(id: UUID, _ transform: @escaping @Sendable (inout WritingMemory) -> Void) async throws
    /// Like `updateMemory(id:_:)`, for the memory with this `dedupKey`.
    func updateMemory(dedupKey: String, _ transform: @escaping @Sendable (inout WritingMemory) -> Void) async throws
    func memory(id: UUID) async throws -> WritingMemory?
    func memory(dedupKey: String) async throws -> WritingMemory?
    func memories() async throws -> [WritingMemory]
    /// Deleting a generalized or core memory is remembered (`isVetoed`), so it is not derived again;
    /// the memories it was derived from stay, and are no longer pointed at as superseded.
    func deleteMemory(id: UUID) async throws
    func deleteAllMemories() async throws
    /// Removes, in one transaction, those of `ids` that are forgotten specific memories the user has
    /// not rewritten, and nothing else: no veto is written, since no user asked for it, and the
    /// relations they are in go with them. Returns how many were removed.
    func eraseMemories(ids: [UUID]) async throws -> Int

    /// The specific memories a generalized or core memory was derived from, oldest first.
    func sources(ofParent parentID: UUID) async throws -> [WritingMemory]
    /// How many memories each generalized or core memory was derived from.
    func sourceCounts() async throws -> [UUID: Int]
    /// Whether the user deleted the memory with this `dedupKey` and it may not be derived again.
    func isVetoed(dedupKey: String) async throws -> Bool
    /// Stores a generalized or core memory, relates it to the memories it is derived from and marks
    /// them as superseded by it, all in one transaction: either all of it happens or none of it.
    ///
    /// Inside the transaction the sources are read again and must all still qualify (see
    /// `ConsolidationEligibility`) and not stand behind another usable memory, and the derived
    /// memory must not have been deleted by the user; otherwise nothing is written. `build` gets what
    /// the transaction found and returns the memory to keep, or nil to write nothing.
    func applyConsolidation(
        parentDedupKey: String,
        sourceIDs: [UUID],
        at now: Date,
        build: @escaping @Sendable (ConsolidationApplication) -> WritingMemory?
    ) async throws -> ConsolidationOutcome
    /// Inserts, or updates the run with the same `id`.
    func recordDreamRun(_ run: DreamRun) async throws
    /// The most recent run that ran to the end, or nil.
    func lastCompletedDreamRun() async throws -> DreamRun?

    /// With a window, the event is skipped when one with the same source, action and final text was
    /// recorded that long (or less) before it. Returns whether it was inserted.
    @discardableResult
    func insertEvent(_ event: FeedbackEvent, unlessDuplicateWithin window: TimeInterval?) async throws -> Bool
    func eventCount() async throws -> Int
    /// Drops events older than `cutoff`, then everything but the newest `maxCount`.
    func pruneEvents(keepingLast maxCount: Int, olderThan cutoff: Date) async throws

    func stats() async throws -> LearningStats
    /// Removes every memory and event, and scrubs the freed pages from the file.
    func resetAll() async throws
}

/// What `applyConsolidation` found inside its transaction.
struct ConsolidationApplication: Sendable {
    /// The derived memory that already exists under this key, if any.
    var existingParent: WritingMemory?
    /// The sources as they are now, in the order asked for.
    var sources: [WritingMemory]
    /// Those of the sources that `existingParent` was already derived from.
    var linkedSourceIDs: Set<UUID>
}

enum ConsolidationOutcome: Sendable, Equatable {
    enum Reason: Sendable, Equatable {
        /// The user deleted this derived memory, so it is not derived again.
        case vetoed
        /// A source is gone, changed or is covered by something else since it was chosen.
        case sourceChanged
        /// `build` had nothing to write.
        case declined
    }

    case applied(parentID: UUID, created: Bool, newlyCovered: Int)
    case skipped(Reason)
}
