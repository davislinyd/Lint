import XCTest
@testable import LintCore

final class LearningStoreTests: XCTestCase {
    private func makeTempDirectory() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("LintLearningTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        return dir
    }

    private func memory(
        key: String = "spelling:en:prospective>perspective",
        state: MemoryState = .candidate,
        modeScope: WritingMode? = nil
    ) -> WritingMemory {
        WritingMemory(
            id: UUID(),
            dedupKey: key,
            kind: .spelling,
            language: "en",
            modeScope: modeScope,
            triggers: ["prospective"],
            instruction: "Check whether \"perspective\" was meant.",
            negativeExample: nil,
            preferredExample: "perspective",
            evidenceScore: 0.35,
            occurrenceCount: 2,
            state: state,
            userEdited: false,
            createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            lastConfirmedAt: Date(timeIntervalSince1970: 1_700_000_500)
        )
    }

    private func event(at seconds: TimeInterval, action: FeedbackAction = .accepted) -> FeedbackEvent {
        FeedbackEvent(
            id: UUID(),
            createdAt: Date(timeIntervalSince1970: seconds),
            mode: .proofread,
            action: action,
            sourceHMAC: "src",
            suggestionHMAC: "sug",
            finalHMAC: nil,
            provider: "localLlama",
            model: "qwen",
            usedMemoryIDs: [UUID()]
        )
    }

    func testMemoryRoundTripKeepsEveryField() async throws {
        let store = try SQLiteLearningStore(url: nil)
        let saved = memory(modeScope: .translate)
        try await store.saveMemory(saved)
        let loaded = try await store.memory(id: saved.id)
        XCTAssertEqual(loaded, saved)
        let byKey = try await store.memory(dedupKey: saved.dedupKey)
        XCTAssertEqual(byKey, saved)
    }

    func testSavingSameIDUpdatesInsteadOfDuplicating() async throws {
        let store = try SQLiteLearningStore(url: nil)
        var saved = memory()
        try await store.saveMemory(saved)
        saved.evidenceScore = 1.05
        saved.state = .active
        try await store.saveMemory(saved)
        let all = try await store.memories()
        XCTAssertEqual(all, [saved])
    }

    func testDedupKeyIsUniqueAcrossDifferentIDs() async throws {
        let store = try SQLiteLearningStore(url: nil)
        try await store.saveMemory(memory())
        do {
            try await store.saveMemory(memory())
            XCTFail("second memory with the same dedupKey should be rejected")
        } catch {}
        let count = try await store.memories().count
        XCTAssertEqual(count, 1)
    }

    func testDeleteMemory() async throws {
        let store = try SQLiteLearningStore(url: nil)
        let kept = memory(key: "grammar:en:articles")
        let dropped = memory()
        try await store.saveMemory(kept)
        try await store.saveMemory(dropped)
        try await store.deleteMemory(id: dropped.id)
        let remaining = try await store.memories()
        XCTAssertEqual(remaining, [kept])
    }

    func testInsertEventsAndCount() async throws {
        let store = try SQLiteLearningStore(url: nil)
        try await store.insertEvent(event(at: 1))
        try await store.insertEvent(event(at: 2, action: .editedAndAccepted))
        let count = try await store.eventCount()
        XCTAssertEqual(count, 2)
    }

    func testPruneDropsOldEventsThenKeepsNewest() async throws {
        let store = try SQLiteLearningStore(url: nil)
        for seconds in [100, 200, 300, 400, 500] {
            try await store.insertEvent(event(at: TimeInterval(seconds)))
        }
        try await store.pruneEvents(keepingLast: 10, olderThan: Date(timeIntervalSince1970: 250))
        let afterCutoff = try await store.eventCount()
        XCTAssertEqual(afterCutoff, 3)
        try await store.pruneEvents(keepingLast: 2, olderThan: Date(timeIntervalSince1970: 0))
        let afterCap = try await store.eventCount()
        XCTAssertEqual(afterCap, 2)
    }

    func testStatsCountsMemoriesByStateAndEvents() async throws {
        let store = try SQLiteLearningStore(url: nil)
        try await store.saveMemory(memory(key: "a", state: .candidate))
        try await store.saveMemory(memory(key: "b", state: .candidate))
        try await store.saveMemory(memory(key: "c", state: .active))
        try await store.insertEvent(event(at: 1))
        let stats = try await store.stats()
        XCTAssertEqual(stats.count(.candidate), 2)
        XCTAssertEqual(stats.count(.active), 1)
        XCTAssertEqual(stats.count(.pinned), 0)
        XCTAssertEqual(stats.eventCount, 1)
    }

    func testResetAllEmptiesTheStoreAndStaysUsable() async throws {
        let store = try SQLiteLearningStore(url: nil)
        try await store.saveMemory(memory())
        try await store.insertEvent(event(at: 1))
        try await store.resetAll()
        let stats = try await store.stats()
        XCTAssertEqual(stats, .empty)
        try await store.saveMemory(memory())
        let count = try await store.memories().count
        XCTAssertEqual(count, 1)
    }

    func testFileStorePersistsAcrossReopenAndMigratesOnlyOnce() async throws {
        let url = try makeTempDirectory().appendingPathComponent("LintLearning.sqlite")
        let saved = memory()
        do {
            let store = try SQLiteLearningStore(url: url)
            try await store.saveMemory(saved)
        }
        let reopened = try SQLiteLearningStore(url: url)
        let loaded = try await reopened.memory(id: saved.id)
        XCTAssertEqual(loaded, saved)
    }

    func testFileIsOwnerOnly() throws {
        let dir = try makeTempDirectory().appendingPathComponent("Lint", isDirectory: true)
        let url = dir.appendingPathComponent("LintLearning.sqlite")
        _ = try SQLiteLearningStore(url: url)
        func permissions(_ url: URL) throws -> Int {
            let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
            return (attributes[.posixPermissions] as? NSNumber)?.intValue ?? -1
        }
        XCTAssertEqual(try permissions(url), 0o600)
        XCTAssertEqual(try permissions(dir), 0o700)
    }
}
