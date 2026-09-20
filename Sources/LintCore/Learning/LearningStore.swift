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
    func memory(id: UUID) async throws -> WritingMemory?
    func memory(dedupKey: String) async throws -> WritingMemory?
    func memories() async throws -> [WritingMemory]
    func deleteMemory(id: UUID) async throws
    func deleteAllMemories() async throws

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
