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

    /// The specific memories a generalized or core memory was derived from, oldest first.
    func sources(ofParent parentID: UUID) async throws -> [WritingMemory]
    /// How many memories each generalized or core memory was derived from.
    func sourceCounts() async throws -> [UUID: Int]
    /// Whether the user deleted the memory with this `dedupKey` and it may not be derived again.
    func isVetoed(dedupKey: String) async throws -> Bool
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
