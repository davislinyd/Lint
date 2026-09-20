import XCTest
@testable import LintCore

final class LearningCoordinatorTests: XCTestCase {
    private func makeStoreURL() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("LintLearningTests-\(UUID().uuidString)", isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        return dir.appendingPathComponent("Lint", isDirectory: true)
            .appendingPathComponent("LintLearning.sqlite")
    }

    func testDisabledLearningNeverCreatesTheDatabase() async throws {
        let url = try makeStoreURL()
        let coordinator = LearningCoordinator(storeURL: url)
        await coordinator.prepare(config: LearningConfig(enabled: false))
        let stats = await coordinator.stats()
        await coordinator.resetAll()
        XCTAssertEqual(stats, .empty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.deletingLastPathComponent().path))
    }

    func testEnablingLearningCreatesTheDatabase() async throws {
        let url = try makeStoreURL()
        let coordinator = LearningCoordinator(storeURL: url)
        await coordinator.prepare(config: LearningConfig(enabled: true))
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
        let stats = await coordinator.stats()
        XCTAssertEqual(stats, .empty)
    }

    func testExistingDataStaysVisibleAndResettableAfterDisabling() async throws {
        let url = try makeStoreURL()
        let seeded = try SQLiteLearningStore(url: url)
        try await seeded.saveMemory(
            WritingMemory(
                id: UUID(), dedupKey: "grammar:en:articles", kind: .grammar, language: "en",
                modeScope: nil, triggers: [], instruction: "Check articles.",
                negativeExample: nil, preferredExample: nil, evidenceScore: 1.2,
                occurrenceCount: 4, state: .active, userEdited: false,
                createdAt: Date(), lastConfirmedAt: Date()
            )
        )

        let coordinator = LearningCoordinator(storeURL: url)
        await coordinator.prepare(config: LearningConfig(enabled: false))
        let before = await coordinator.stats()
        XCTAssertEqual(before.count(.active), 1)

        await coordinator.resetAll()
        let after = await coordinator.stats()
        XCTAssertEqual(after, .empty)
    }
}
