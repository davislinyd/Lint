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

    private func feedback(
        _ gesture: UserGesture = .replaced,
        original: String = "zq-source-text discuss about",
        generated: String? = "zq-suggestion-text discuss",
        final: String = "zq-suggestion-text discuss"
    ) -> LearningFeedback {
        LearningFeedback(
            gesture: gesture, mode: .proofread, originalText: original, generatedText: generated,
            finalText: final, provider: "localLlama", model: "qwen"
        )
    }

    private func testKey() -> @Sendable () throws -> Data {
        { Data(repeating: 9, count: 32) }
    }

    func testFeedbackIsIgnoredWhileLearningIsOff() async throws {
        let url = try makeStoreURL()
        let coordinator = LearningCoordinator(storeURL: url, hmacKey: testKey())
        await coordinator.recordFeedback(feedback(), config: LearningConfig(enabled: false))
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }

    func testRecordedFeedbackCountsOncePerDay() async throws {
        let coordinator = LearningCoordinator(storeURL: nil, hmacKey: testKey())
        let on = LearningConfig(enabled: true)
        await coordinator.recordFeedback(feedback(), config: on)
        await coordinator.recordFeedback(feedback(), config: on)
        await coordinator.recordFeedback(feedback(final: "zq-edited-text"), config: on)
        let stats = await coordinator.stats()
        XCTAssertEqual(stats.eventCount, 2, "the repeat is dropped, the edited version is a new event")
    }

    func testHalfStreamedSuggestionRecordsNothingAndCreatesNothing() async throws {
        let url = try makeStoreURL()
        let coordinator = LearningCoordinator(storeURL: url, hmacKey: testKey())
        await coordinator.recordFeedback(feedback(generated: nil), config: LearningConfig(enabled: true))
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }

    func testStoredEventsContainNoPlaintext() async throws {
        let url = try makeStoreURL()
        let coordinator = LearningCoordinator(storeURL: url, hmacKey: testKey())
        await coordinator.recordFeedback(feedback(), config: LearningConfig(enabled: true))

        let file = try Data(contentsOf: url)
        XCTAssertNotNil(file.range(of: Data("localLlama".utf8)), "sanity: plaintext columns are visible in the file")
        for secret in ["zq-source-text", "zq-suggestion-text", "discuss"] {
            XCTAssertNil(file.range(of: Data(secret.utf8)), "\(secret) must not be stored")
        }
    }

    func testMissingHMACKeyRecordsNothing() async throws {
        struct NoKey: Error {}
        let coordinator = LearningCoordinator(storeURL: nil, hmacKey: { throw NoKey() })
        await coordinator.recordFeedback(feedback(), config: LearningConfig(enabled: true))
        let stats = await coordinator.stats()
        XCTAssertEqual(stats.eventCount, 0)
    }

    func testHMACKeyIsFetchedOnlyOnce() async throws {
        final class Counter: @unchecked Sendable {
            private let lock = NSLock()
            private var value = 0
            func increment() { lock.lock(); value += 1; lock.unlock() }
            var count: Int { lock.lock(); defer { lock.unlock() }; return value }
        }
        let calls = Counter()
        let coordinator = LearningCoordinator(storeURL: nil, hmacKey: {
            calls.increment()
            return Data(repeating: 9, count: 32)
        })
        let on = LearningConfig(enabled: true)
        await coordinator.recordFeedback(feedback(), config: on)
        await coordinator.recordFeedback(feedback(.copied), config: on)
        XCTAssertEqual(calls.count, 1)
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
