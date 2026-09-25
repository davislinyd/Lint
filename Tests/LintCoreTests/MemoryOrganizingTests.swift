import GRDB
import XCTest
@testable import LintCore

/// Organizing memories as the app uses it: through `LearningCoordinator`, on a store in a file.
final class MemoryOrganizingTests: XCTestCase {
    private let on = LearningConfig(enabled: true)
    private let off = LearningConfig(enabled: false)
    private let english = "The roadmap for the next quarter looks quite fine to everyone."

    private struct Setup {
        let coordinator: LearningCoordinator
        let url: URL
        let sleeper: ManualSleeper
        let clock: DreamClock
    }

    private func makeSetup(clock: DreamClock = DreamClock()) throws -> Setup {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("LintOrganizingTests-\(UUID().uuidString)", isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("Lint", isDirectory: true).appendingPathComponent("LintLearning.sqlite")
        let sleeper = ManualSleeper()
        let coordinator = LearningCoordinator(
            storeURL: url, hmacKey: { Data(repeating: 9, count: 32) }, clock: clock.reader,
            organizingSleep: sleeper.reader
        )
        return Setup(coordinator: coordinator, url: url, sleeper: sleeper, clock: clock)
    }

    /// The store behind the coordinator, opened separately to put memories there and to look.
    private func openStore(_ setup: Setup) throws -> SQLiteLearningStore {
        try SQLiteLearningStore(url: setup.url)
    }

    private func rowCount(_ table: String, in url: URL) throws -> Int {
        let queue = try DatabaseQueue(path: url.path)
        return try queue.read { db in try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM \(table)") ?? -1 }
    }

    /// The model left "discuss about" alone and the user fixed it, in a text of its own.
    private func edit(_ index: Int) -> LearningFeedback {
        LearningFeedback(
            gesture: .replaced, mode: .proofread,
            originalText: "we should discuss about the topic\(index).",
            generatedText: "we should discuss about the topic\(index).",
            finalText: "we should discuss the topic\(index).",
            provider: "localLlama", model: "qwen"
        )
    }

    private func seedPrepositions(_ setup: Setup, count: Int = 3) async throws -> SQLiteLearningStore {
        let store = try openStore(setup)
        for memory in DreamFixtures.prepositions(count) { try await store.saveMemory(memory) }
        return store
    }

    // MARK: when it runs

    func testStartingUpWithNoPassYetSchedulesOneWhichThenRuns() async throws {
        let setup = try makeSetup()
        await setup.coordinator.prepare(config: on)

        let waiting = await eventually { setup.sleeper.waitingCount == 1 }
        XCTAssertTrue(waiting)
        XCTAssertEqual(try rowCount("dream_run", in: setup.url), 0, "nothing runs until things are quiet")

        setup.sleeper.wake()
        let ran = await eventually { await setup.coordinator.stats().lastOrganizedAt != nil }
        XCTAssertTrue(ran)
        XCTAssertEqual(try rowCount("dream_run", in: setup.url), 1)
    }

    func testStartingUpSoonAfterAPassSchedulesNothingAndAfterADayItDoes() async throws {
        for (hoursAgo, scheduled) in [(1.0, false), (25.0, true)] {
            let setup = try makeSetup()
            let store = try openStore(setup)
            try await store.recordDreamRun(DreamRun(
                id: UUID(), startedAt: setup.clock.now.addingTimeInterval(-hoursAgo * 3_600),
                finishedAt: setup.clock.now.addingTimeInterval(-hoursAgo * 3_600 + 5), algorithmVersion: 1,
                inputMemoryCount: 0, clusterCount: 0, generatedCount: 0, supersededCount: 0, status: .completed
            ))

            await setup.coordinator.prepare(config: on)

            let waiting = await eventually(timeout: scheduled ? 3 : 0.3) { setup.sleeper.waitingCount == 1 }
            XCTAssertEqual(waiting, scheduled, "\(hoursAgo) hours ago")
        }
    }

    func testAPileOfMemoriesSchedulesAPassButOnlyOnceItIsBigEnough() async throws {
        for (count, scheduled) in [(199, false), (200, true)] {
            let setup = try makeSetup()
            let store = try openStore(setup)
            // Long enough since the last pass to be worth another for the pile, not for a start-up.
            try await store.recordDreamRun(DreamRun(
                id: UUID(), startedAt: setup.clock.now.addingTimeInterval(-7 * 3_600),
                finishedAt: setup.clock.now.addingTimeInterval(-7 * 3_600 + 5), algorithmVersion: 1,
                inputMemoryCount: 0, clusterCount: 0, generatedCount: 0, supersededCount: 0, status: .completed
            ))
            for index in 0..<count {
                try await store.saveMemory(DreamFixtures.plain(
                    "vocabulary:en:a\(index)>b\(index)", kind: .vocabulary, instruction: "rule \(index)", state: .candidate
                ))
            }

            await setup.coordinator.prepare(config: on)

            let waiting = await eventually(timeout: scheduled ? 3 : 0.3) { setup.sleeper.waitingCount == 1 }
            XCTAssertEqual(waiting, scheduled, "\(count) memories")
        }
    }

    func testNothingIsScheduledOrRunWhileLearningIsOffOrOnceItIsSwitchedOff() async throws {
        let setup = try makeSetup()
        await setup.coordinator.prepare(config: off)
        await settle()
        XCTAssertEqual(setup.sleeper.waitingCount, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: setup.url.path), "the database is never created")

        await setup.coordinator.prepare(config: on)
        let waiting = await eventually { setup.sleeper.waitingCount == 1 }
        XCTAssertTrue(waiting)
        await setup.coordinator.prepare(config: off)
        let cancelled = await eventually { setup.sleeper.waitingCount == 0 }
        XCTAssertTrue(cancelled)
        setup.sleeper.wake()
        await settle()
        XCTAssertEqual(try rowCount("dream_run", in: setup.url), 0)
    }

    func testAPassThatComesDueJustAsLearningIsSwitchedOffDoesNotRun() async throws {
        let setup = try makeSetup()
        await setup.coordinator.prepare(config: on)
        let waiting = await eventually { setup.sleeper.waitingCount == 1 }
        XCTAssertTrue(waiting)

        // Switched off through a path that does not reach the scheduler (feedback while off).
        await setup.coordinator.recordFeedback(edit(0), config: off)
        setup.sleeper.wake()
        await settle()
        XCTAssertEqual(try rowCount("dream_run", in: setup.url), 0)
    }

    /// A pass finished `hoursAgo` hours before the setup's clock.
    private func recordPass(_ setup: Setup, hoursAgo: Double) async throws {
        try await openStore(setup).recordDreamRun(DreamRun(
            id: UUID(), startedAt: setup.clock.now.addingTimeInterval(-hoursAgo * 3_600),
            finishedAt: setup.clock.now.addingTimeInterval(-hoursAgo * 3_600 + 5), algorithmVersion: 1,
            inputMemoryCount: 0, clusterCount: 0, generatedCount: 0, supersededCount: 0, status: .completed
        ))
    }

    func testARunOfFeedbackEndsInOnePass() async throws {
        let setup = try makeSetup()
        try await recordPass(setup, hoursAgo: 1)
        await setup.coordinator.prepare(config: on)
        for index in 0..<24 { await setup.coordinator.recordFeedback(edit(index), config: on) }
        await settle()
        XCTAssertEqual(setup.sleeper.waitingCount, 0, "24 changes are not enough, and the last pass was an hour ago")

        for index in 24..<30 { await setup.coordinator.recordFeedback(edit(index), config: on) }
        let waiting = await eventually { setup.sleeper.waitingCount == 1 }
        XCTAssertTrue(waiting, "one wait, however much feedback there was")

        setup.sleeper.wake()
        let ran = await eventually { (try? self.rowCount("dream_run", in: setup.url)) == 2 }
        XCTAssertTrue(ran)
        await settle()
        XCTAssertEqual(try rowCount("dream_run", in: setup.url), 2)
        XCTAssertEqual(setup.sleeper.waitingCount, 0)
    }

    func testTheFirstFeedbackADayAfterTheLastPassSchedulesOne() async throws {
        let setup = try makeSetup()
        try await recordPass(setup, hoursAgo: 1)
        await setup.coordinator.prepare(config: on)
        await setup.coordinator.recordFeedback(edit(0), config: on)
        await settle()
        XCTAssertEqual(setup.sleeper.waitingCount, 0, "an hour after a pass")

        setup.clock.advance(hours: 23)
        await setup.coordinator.recordFeedback(edit(1), config: on)
        await settle()
        XCTAssertEqual(setup.sleeper.waitingCount, 0, "a day to the minute is not more than a day")

        setup.clock.advance(hours: 1)
        await setup.coordinator.recordFeedback(edit(2), config: on)
        let waiting = await eventually { setup.sleeper.waitingCount == 1 }
        XCTAssertTrue(waiting, "Lint is in use and the last pass is over a day old")
    }

    func testAnExplicitRequestReportsWhatWasRememberedForgottenAndErased() async throws {
        let setup = try makeSetup()
        let store = try openStore(setup)
        for index in 0..<3 {
            var cameBack = DreamFixtures.plain("style:en:came-back\(index)", evidence: 0.3, count: 2, state: .candidate)
            cameBack.lastConfirmedAt = setup.clock.now
            try await store.saveMemory(cameBack)
        }
        var ranOut = DreamFixtures.plain("style:en:ran-out", count: 1, state: .candidate)
        ranOut.lastConfirmedAt = setup.clock.now.addingTimeInterval(-8 * 86_400)
        try await store.saveMemory(ranOut)
        for index in 0..<2 {
            try await store.saveMemory(DreamFixtures.plain("style:en:trace\(index)", evidence: 0.05, state: .archived))
        }

        let outcome = await setup.coordinator.organizeMemories(config: on)

        XCTAssertEqual(outcome, .finished(remembered: 3, forgotten: 1, erased: 2, newRules: 0, coveredMemories: 0))
    }

    func testAPassHoldsBackWhileTheUserIsWaitingOnASuggestion() async throws {
        let setup = try makeSetup()
        await setup.coordinator.prepare(config: on)
        let waiting = await eventually { setup.sleeper.waitingCount == 1 }
        XCTAssertTrue(waiting)

        // Called without waiting: it must not queue behind anything the coordinator does.
        setup.coordinator.setInteractiveActivity(true)
        setup.sleeper.wake()
        let again = await eventually { setup.sleeper.waitingCount == 1 }
        XCTAssertTrue(again)
        XCTAssertEqual(try rowCount("dream_run", in: setup.url), 0)

        setup.coordinator.setInteractiveActivity(false)
        for _ in 0..<2 {
            setup.sleeper.wake()
            _ = await eventually(timeout: 0.5) { setup.sleeper.waitingCount == 1 }
        }
        let ran = await eventually { (try? self.rowCount("dream_run", in: setup.url)) == 1 }
        XCTAssertTrue(ran, "after a quiet window")
    }

    // MARK: on request

    func testAnExplicitRequestOrganizesAtOnceAndReportsWhatItDid() async throws {
        let setup = try makeSetup()
        let store = try await seedPrepositions(setup)

        let outcome = await setup.coordinator.organizeMemories(config: on)

        XCTAssertEqual(outcome, .finished(remembered: 0, forgotten: 0, erased: 0, newRules: 1, coveredMemories: 3))
        let stats = await setup.coordinator.stats()
        XCTAssertEqual([stats.count(.specific), stats.count(.generalized), stats.count(.core)], [3, 1, 0])
        XCTAssertEqual(stats.supersededCount, 3)
        XCTAssertNotNil(stats.lastOrganizedAt)
        let parent = try unwrapped(await store.memories().first { $0.level != .specific })
        let counts = await setup.coordinator.sourceCounts()
        XCTAssertEqual(counts, [parent.id: 3])
        let sources = await setup.coordinator.sources(of: parent.id)
        XCTAssertEqual(sources.count, 3)

        let again = await setup.coordinator.organizeMemories(config: on)
        XCTAssertEqual(again, .finished(remembered: 0, forgotten: 0, erased: 0, newRules: 0, coveredMemories: 0), "nothing more to do")
    }

    func testAnExplicitRequestNeedsLearningOnAndSomethingOnDisk() async throws {
        let setup = try makeSetup()
        let nothing = await setup.coordinator.organizeMemories(config: on)
        XCTAssertEqual(nothing, .unavailable)
        XCTAssertFalse(FileManager.default.fileExists(atPath: setup.url.path))

        _ = try await seedPrepositions(setup)
        let disabled = await setup.coordinator.organizeMemories(config: off)
        XCTAssertEqual(disabled, .unavailable)
        XCTAssertEqual(try rowCount("dream_run", in: setup.url), 0)
    }

    func testAnExplicitRequestCountsAsThePassSoNothingIsDueRightAfter() async throws {
        let setup = try makeSetup()
        await setup.coordinator.prepare(config: on)
        let waiting = await eventually { setup.sleeper.waitingCount == 1 }
        XCTAssertTrue(waiting)

        let outcome = await setup.coordinator.organizeMemories(config: on)
        XCTAssertEqual(outcome, .finished(remembered: 0, forgotten: 0, erased: 0, newRules: 0, coveredMemories: 0))
        let none = await eventually { setup.sleeper.waitingCount == 0 }
        XCTAssertTrue(none, "the one that was waiting is no longer needed")
    }

    func testOrganizingShowsUpInTheNextRetrievalEvenAfterTheCacheWasFilled() async throws {
        let setup = try makeSetup()
        _ = try await seedPrepositions(setup)
        let before = await setup.coordinator.relevantMemories(for: english, mode: .proofread, config: on)
        XCTAssertTrue(before.isEmpty, "the cache is filled, and nothing applies to this text")

        await setup.coordinator.organizeMemories(config: on)

        let after = await setup.coordinator.relevantMemories(for: english, mode: .proofread, config: on)
        XCTAssertEqual(after.map(\.dedupKey), ["dream:redundant-preposition:grammar:en"])
    }

    func testASuggestionKeepsWorkingWhateverOrganizingDoes() async throws {
        let setup = try makeSetup()
        let store = try await seedPrepositions(setup)
        // A row the store cannot read makes a pass fail, as any other damage to the file would.
        let queue = try DatabaseQueue(path: setup.url.path)
        try await queue.write { db in
            try db.execute(sql: "UPDATE writing_memory SET state = 'broken' WHERE dedup_key = 'grammar:en:reply about'")
        }
        _ = store

        let outcome = await setup.coordinator.organizeMemories(config: on)
        XCTAssertEqual(outcome, .failed)

        let prompt = await setup.coordinator.personalize(prompt: "BASE", for: english, mode: .proofread, config: on)
        XCTAssertEqual(prompt.systemPrompt, "BASE", "the suggestion goes on without the personalization")
    }
}
