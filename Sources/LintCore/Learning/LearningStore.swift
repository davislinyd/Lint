import Foundation

/// Persistence boundary of the learning subsystem; SQLite in the app, swappable in tests.
protocol LearningStore: Sendable {
    /// Inserts, or updates the row with the same `id`. A different `id` with an existing
    /// `dedupKey` is an error: merging evidence is the caller's job.
    func saveMemory(_ memory: WritingMemory) async throws
    func memory(id: UUID) async throws -> WritingMemory?
    func memory(dedupKey: String) async throws -> WritingMemory?
    func memories() async throws -> [WritingMemory]
    func deleteMemory(id: UUID) async throws

    func insertEvent(_ event: FeedbackEvent) async throws
    func eventCount() async throws -> Int
    /// Drops events older than `cutoff`, then everything but the newest `maxCount`.
    func pruneEvents(keepingLast maxCount: Int, olderThan cutoff: Date) async throws

    func stats() async throws -> LearningStats
    /// Removes every memory and event, and scrubs the freed pages from the file.
    func resetAll() async throws
}
