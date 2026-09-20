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
        // Abstracted memories may keep single words (a trigger such as "discuss about"), but the
        // texts themselves never reach the file.
        for secret in ["zq-source-text", "zq-suggestion-text"] {
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

    // MARK: learning

    private let on = LearningConfig(enabled: true)
    private let topics = ["plan", "budget", "schedule", "firewall", "report", "contract", "design"]

    /// The model left "discuss about" alone and the user fixed it by hand.
    private func edit(_ topic: String, gesture: UserGesture = .replaced) -> LearningFeedback {
        LearningFeedback(
            gesture: gesture, mode: .proofread,
            originalText: "we should discuss about the \(topic).",
            generatedText: "we should discuss about the \(topic).",
            finalText: "we should discuss the \(topic).",
            provider: "localLlama", model: "qwen"
        )
    }

    /// The model fixed "discuss about" and the user took it as is.
    private func accept(_ topic: String, gesture: UserGesture = .replaced) -> LearningFeedback {
        LearningFeedback(
            gesture: gesture, mode: .proofread,
            originalText: "we should discuss about the \(topic).",
            generatedText: "we should discuss the \(topic).",
            finalText: "we should discuss the \(topic).",
            provider: "localLlama", model: "qwen"
        )
    }

    private func learner() -> LearningCoordinator {
        LearningCoordinator(storeURL: nil, hmacKey: testKey())
    }

    private func onlyMemory(_ coordinator: LearningCoordinator) async throws -> WritingMemory {
        let all = await coordinator.memories()
        return try XCTUnwrap(all.first)
    }

    func testThreeDifferentEditsTurnACandidateIntoAnActiveMemory() async throws {
        let coordinator = learner()
        for topic in topics.prefix(2) {
            await coordinator.recordFeedback(edit(topic), config: on)
        }
        let candidate = await coordinator.memories()
        XCTAssertEqual(candidate.map(\.dedupKey), ["grammar:en:discuss about"])
        XCTAssertEqual(candidate.first?.state, .candidate)
        XCTAssertEqual(candidate.first?.occurrenceCount, 2)

        await coordinator.recordFeedback(edit(topics[2]), config: on)
        let active = await coordinator.memories()
        XCTAssertEqual(active.count, 1)
        XCTAssertEqual(active.first?.state, .active)
        XCTAssertEqual(active.first?.occurrenceCount, 3)
        XCTAssertEqual(active.first?.triggers, ["discuss about"])
    }

    func testSevenAcceptsAreNeededToPromote() async throws {
        let coordinator = learner()
        for topic in topics.prefix(6) {
            await coordinator.recordFeedback(accept(topic), config: on)
        }
        let beforeSeventh = await coordinator.memories()
        XCTAssertEqual(beforeSeventh.first?.state, .candidate)
        await coordinator.recordFeedback(accept(topics[6]), config: on)
        let afterSeventh = await coordinator.memories()
        XCTAssertEqual(afterSeventh.first?.state, .active)
    }

    func testTheSameFeedbackTwiceIsOneObservation() async throws {
        let coordinator = learner()
        await coordinator.recordFeedback(edit("plan"), config: on)
        await coordinator.recordFeedback(edit("plan"), config: on)
        let memories = await coordinator.memories()
        XCTAssertEqual(memories.first?.occurrenceCount, 1)
    }

    func testCopyingCountsForLessAndRegeneratingForNothing() async throws {
        let coordinator = learner()
        await coordinator.recordFeedback(accept("plan", gesture: .regenerated), config: on)
        let none = await coordinator.memories()
        XCTAssertTrue(none.isEmpty)

        await coordinator.recordFeedback(accept("plan", gesture: .copied), config: on)
        let copied = await coordinator.memories()
        let evidence = try XCTUnwrap(copied.first?.evidenceScore)
        XCTAssertEqual(evidence, LearningPolicy.evidenceWeight(for: .copied), accuracy: 1e-9)
    }

    func testNothingIsLearnedWhileLearningIsOff() async throws {
        let url = try makeStoreURL()
        let coordinator = LearningCoordinator(storeURL: url, hmacKey: testKey())
        await coordinator.recordFeedback(edit("plan"), config: LearningConfig(enabled: false))
        let memories = await coordinator.memories()
        XCTAssertTrue(memories.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }

    func testExamplesAreKeptOnlyWhenAskedFor() async throws {
        let without = learner()
        await without.recordFeedback(edit("plan"), config: on)
        let bare = await without.memories()
        XCTAssertNil(bare.first?.negativeExample)

        let with = learner()
        await with.recordFeedback(edit("plan"), config: LearningConfig(enabled: true, storeExamples: true))
        let kept = await with.memories()
        XCTAssertEqual(kept.first?.negativeExample, "should discuss about the plan")
        XCTAssertEqual(kept.first?.preferredExample, "should discuss the plan")
    }

    // MARK: retrieval

    private func retrieve(_ coordinator: LearningCoordinator, config: LearningConfig? = nil) async -> [WritingMemory] {
        await coordinator.relevantMemories(
            for: "we should discuss about the roadmap", mode: .proofread, config: config ?? on
        )
    }

    func testLearnedMemoriesAreRetrievedOnlyForRelevantText() async throws {
        let coordinator = learner()
        for topic in topics.prefix(3) {
            await coordinator.recordFeedback(edit(topic), config: on)
        }
        let hit = await retrieve(coordinator)
        XCTAssertEqual(hit.map(\.dedupKey), ["grammar:en:discuss about"])
        let miss = await coordinator.relevantMemories(
            for: "the roadmap looks fine to everyone here", mode: .proofread, config: on
        )
        XCTAssertTrue(miss.isEmpty)
    }

    func testPromotionShowsUpInTheNextRetrievalEvenAfterTheCacheWasFilled() async throws {
        let coordinator = learner()
        for topic in topics.prefix(2) {
            await coordinator.recordFeedback(edit(topic), config: on)
        }
        let candidate = await retrieve(coordinator)
        XCTAssertTrue(candidate.isEmpty, "a candidate is not used yet")

        await coordinator.recordFeedback(edit(topics[2]), config: on)
        let active = await retrieve(coordinator)
        XCTAssertEqual(active.count, 1)
    }

    func testEveryChangeShowsUpInTheNextRetrieval() async throws {
        let (coordinator, id) = try await seeded()
        let untouched = await retrieve(coordinator)
        XCTAssertTrue(untouched.isEmpty, "one edit is only a candidate")

        await coordinator.setPinned(true, id: id)
        let pinned = await retrieve(coordinator)
        XCTAssertEqual(pinned.count, 1)

        await coordinator.setEnabled(false, id: id)
        let disabled = await retrieve(coordinator)
        XCTAssertTrue(disabled.isEmpty)

        await coordinator.setPinned(true, id: id)
        let repinned = await retrieve(coordinator)
        XCTAssertEqual(repinned.count, 1)

        await coordinator.deleteMemory(id: id)
        let deleted = await retrieve(coordinator)
        XCTAssertTrue(deleted.isEmpty)
    }

    func testResetAndClearingEmptyTheRetrievalToo() async throws {
        let (coordinator, id) = try await seeded()
        await coordinator.setPinned(true, id: id)
        let before = await retrieve(coordinator)
        XCTAssertEqual(before.count, 1)
        await coordinator.deleteAllMemories()
        let cleared = await retrieve(coordinator)
        XCTAssertTrue(cleared.isEmpty)

        await coordinator.recordFeedback(edit("budget"), config: on)
        let relearned = try await onlyMemory(coordinator)
        await coordinator.setPinned(true, id: relearned.id)
        let again = await retrieve(coordinator)
        XCTAssertEqual(again.count, 1)
        await coordinator.resetAll()
        let reset = await retrieve(coordinator)
        XCTAssertTrue(reset.isEmpty)
    }

    func testNothingIsRetrievedWhileLearningIsOffAndRetrievingNeverCreatesTheDatabase() async throws {
        let url = try makeStoreURL()
        let fresh = LearningCoordinator(storeURL: url, hmacKey: testKey())
        let none = await retrieve(fresh)
        XCTAssertTrue(none.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))

        let (coordinator, id) = try await seeded()
        await coordinator.setPinned(true, id: id)
        let off = await retrieve(coordinator, config: LearningConfig(enabled: false))
        XCTAssertTrue(off.isEmpty)
    }

    // MARK: managing memories

    private func seeded() async throws -> (LearningCoordinator, UUID) {
        let coordinator = learner()
        await coordinator.recordFeedback(edit("plan"), config: on)
        let id = try await onlyMemory(coordinator).id
        return (coordinator, id)
    }

    func testPinningDisablingAndTheirUndoFollowTheEvidence() async throws {
        let (coordinator, id) = try await seeded()
        func state() async -> MemoryState? { await coordinator.memories().first { $0.id == id }?.state }

        await coordinator.setPinned(true, id: id)
        let pinned = await state()
        XCTAssertEqual(pinned, .pinned)
        await coordinator.recordFeedback(edit("budget"), config: on)
        let stillPinned = await state()
        XCTAssertEqual(stillPinned, .pinned, "more evidence does not unpin")

        await coordinator.setPinned(false, id: id)
        let unpinned = await state()
        XCTAssertEqual(unpinned, .candidate, "0.7 of evidence is below the threshold")

        await coordinator.setEnabled(false, id: id)
        let disabled = await state()
        XCTAssertEqual(disabled, .disabled)
        await coordinator.recordFeedback(edit("schedule"), config: on)
        let stillDisabled = await state()
        XCTAssertEqual(stillDisabled, .disabled, "more evidence does not re-enable")

        await coordinator.setEnabled(true, id: id)
        let enabled = await state()
        XCTAssertEqual(enabled, .active, "three edits' worth of evidence")
    }

    func testEditedInstructionIsCleanedLimitedAndKept() async throws {
        let (coordinator, id) = try await seeded()
        await coordinator.setInstruction("  my   own\nwording  ", id: id)
        var memory = try await onlyMemory(coordinator)
        XCTAssertEqual(memory.instruction, "my own wording")
        XCTAssertTrue(memory.userEdited)

        await coordinator.setInstruction("   \n ", id: id)
        memory = try await onlyMemory(coordinator)
        XCTAssertEqual(memory.instruction, "my own wording", "an empty text is ignored")

        await coordinator.recordFeedback(edit("budget"), config: on)
        memory = try await onlyMemory(coordinator)
        XCTAssertEqual(memory.instruction, "my own wording", "new evidence does not overwrite it")

        await coordinator.setInstruction(String(repeating: "x", count: 500), id: id)
        memory = try await onlyMemory(coordinator)
        XCTAssertEqual(memory.instruction.count, LearningPolicy.maxInstructionLength)
    }

    func testDeletingOneOrAllMemories() async throws {
        let (coordinator, id) = try await seeded()
        await coordinator.recordFeedback(
            LearningFeedback(
                gesture: .replaced, mode: .proofread, originalText: "i have meeting.",
                generatedText: "i have a meeting.", finalText: "i have a meeting.",
                provider: "localLlama", model: "qwen"
            ),
            config: on
        )
        let two = await coordinator.memories()
        XCTAssertEqual(two.count, 2)

        await coordinator.deleteMemory(id: id)
        let one = await coordinator.memories()
        XCTAssertEqual(one.map(\.dedupKey), ["grammar:en:articles"])

        await coordinator.deleteAllMemories()
        let none = await coordinator.memories()
        XCTAssertTrue(none.isEmpty)
        let stats = await coordinator.stats()
        XCTAssertGreaterThan(stats.eventCount, 0, "clearing memories keeps the feedback log")
    }

    func testManagementNeverCreatesTheDatabase() async throws {
        let url = try makeStoreURL()
        let coordinator = LearningCoordinator(storeURL: url, hmacKey: testKey())
        let id = UUID()
        await coordinator.setPinned(true, id: id)
        await coordinator.setEnabled(false, id: id)
        await coordinator.setInstruction("text", id: id)
        await coordinator.deleteMemory(id: id)
        await coordinator.deleteAllMemories()
        let memories = await coordinator.memories()
        XCTAssertTrue(memories.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }

    func testMemoriesOnDiskHoldNoSentences() async throws {
        let url = try makeStoreURL()
        let coordinator = LearningCoordinator(storeURL: url, hmacKey: testKey())
        let secretLine = LearningFeedback(
            gesture: .replaced, mode: .proofread,
            originalText: "we should discuss about the quokka schedule.",
            generatedText: "we should discuss about the quokka schedule.",
            finalText: "we should discuss the quokka schedule.",
            provider: "localLlama", model: "qwen"
        )
        await coordinator.recordFeedback(secretLine, config: LearningConfig(enabled: true, storeExamples: true))

        let file = try Data(contentsOf: url)
        XCTAssertNotNil(file.range(of: Data("discuss about".utf8)), "sanity: the abstracted trigger is stored")
        XCTAssertNotNil(file.range(of: Data("quokka".utf8)), "sanity: an example keeps two words of context")
        XCTAssertNil(file.range(of: Data("schedule".utf8)), "but never the rest of the sentence")
        XCTAssertNil(file.range(of: Data("we should".utf8)))
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
