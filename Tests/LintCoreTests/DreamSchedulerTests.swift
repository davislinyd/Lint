import XCTest
@testable import LintCore

/// Stands in for a pass over the memories, answering from a script.
private final class Passes: @unchecked Sendable {
    private let lock = NSLock()
    private var script: [DreamRunStatus?]
    private var runs = 0
    private var inside = 0
    private var mostInside = 0
    var hold: (@Sendable () async -> Void)?

    init(_ script: [DreamRunStatus?] = []) {
        self.script = script
    }

    var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return runs
    }

    var mostAtOnce: Int {
        lock.lock()
        defer { lock.unlock() }
        return mostInside
    }

    private func enter() -> (result: DreamRunStatus?, hold: (@Sendable () async -> Void)?) {
        lock.withLock {
            runs += 1
            inside += 1
            mostInside = max(mostInside, inside)
            let result: DreamRunStatus? = script.isEmpty ? .completed : script.removeFirst()
            return (result, hold)
        }
    }

    private func leave() {
        lock.withLock { inside -= 1 }
    }

    func run() async -> DreamRunStatus? {
        let entered = enter()
        await entered.hold?()
        leave()
        return entered.result
    }
}

final class DreamSchedulerTests: XCTestCase {
    private struct Setup {
        let scheduler: DreamScheduler
        let gate: InteractiveGate
        let sleeper: ManualSleeper
        let clock: DreamClock
        let passes: Passes
    }

    private let idle = MemoryPolicy.dreamIdleDelay
    private let retry = MemoryPolicy.dreamRetryDelay

    private func make(_ script: [DreamRunStatus?] = []) -> Setup {
        let gate = InteractiveGate()
        let sleeper = ManualSleeper()
        let clock = DreamClock()
        let passes = Passes(script)
        let scheduler = DreamScheduler(
            gate: gate, clock: clock.reader, sleep: sleeper.reader, pass: { await passes.run() }
        )
        return Setup(scheduler: scheduler, gate: gate, sleeper: sleeper, clock: clock, passes: passes)
    }

    private func waiting(_ setup: Setup, _ count: Int = 1) async -> Bool {
        await eventually { setup.sleeper.waitingCount == count }
    }

    private func passed(_ setup: Setup, _ count: Int) async -> Bool {
        await eventually { setup.passes.count == count }
    }

    // MARK: waiting for a quiet moment

    func testABurstOfTriggersEndsInOnePassAfterTheWait() async {
        let setup = make()
        for _ in 0..<3 { await setup.scheduler.markPending() }

        let onlyOne = await waiting(setup)
        XCTAssertTrue(onlyOne, "each trigger restarts the same wait")
        await settle()
        XCTAssertEqual(setup.passes.count, 0, "nothing runs before the wait is over")
        XCTAssertTrue(setup.sleeper.durations.allSatisfy { $0 == idle })

        setup.sleeper.wake()
        let ran = await passed(setup, 1)
        XCTAssertTrue(ran)
        await settle()
        XCTAssertEqual(setup.passes.count, 1)
        XCTAssertEqual(setup.sleeper.waitingCount, 0, "and nothing is waiting for another")
    }

    func testAPassWaitsWhileTheUserIsWaitingOnASuggestionAndForAQuietWindowAfterwards() async {
        let setup = make()
        setup.gate.set(true)
        await setup.scheduler.markPending()
        let first = await waiting(setup)
        XCTAssertTrue(first)

        setup.sleeper.wake()
        let again = await waiting(setup)
        XCTAssertTrue(again, "busy at the end of the wait: another wait")
        XCTAssertEqual(setup.passes.count, 0)

        setup.gate.set(false)
        setup.sleeper.wake()
        let third = await waiting(setup)
        XCTAssertTrue(third, "the suggestion ended during that wait, so it was not quiet")
        XCTAssertEqual(setup.passes.count, 0)

        setup.sleeper.wake()
        let ran = await passed(setup, 1)
        XCTAssertTrue(ran, "a whole quiet window")
    }

    func testAnythingThatHappenedInTheWaitCountsEvenIfItIsOverByTheEnd() async {
        let setup = make()
        await setup.scheduler.markPending()
        let first = await waiting(setup)
        XCTAssertTrue(first)

        setup.gate.set(true)
        setup.gate.set(false)
        setup.sleeper.wake()
        let again = await waiting(setup)
        XCTAssertTrue(again)
        XCTAssertEqual(setup.passes.count, 0)

        setup.sleeper.wake()
        let ran = await passed(setup, 1)
        XCTAssertTrue(ran)
    }

    func testNothingIsDueAnyMoreOnceCancelled() async {
        let setup = make()
        await setup.scheduler.markPending()
        let first = await waiting(setup)
        XCTAssertTrue(first)

        await setup.scheduler.cancelPending()
        let none = await waiting(setup, 0)
        XCTAssertTrue(none)
        setup.sleeper.wake()
        await settle()
        XCTAssertEqual(setup.passes.count, 0)
    }

    // MARK: the triggers

    func testStartingUpSchedulesAPassOnlyWhenItHasBeenLongEnough() async {
        let setup = make()
        let now = setup.clock.now

        await setup.scheduler.noteStartup(lastCompletedPass: now.addingTimeInterval(-3_600))
        await settle()
        XCTAssertEqual(setup.sleeper.waitingCount, 0, "an hour ago")

        await setup.scheduler.noteStartup(lastCompletedPass: now.addingTimeInterval(-24 * 3_600))
        await settle()
        XCTAssertEqual(setup.sleeper.waitingCount, 0, "exactly a day ago is not longer than a day")

        await setup.scheduler.noteStartup(lastCompletedPass: now.addingTimeInterval(-24 * 3_600 - 1))
        let due = await waiting(setup)
        XCTAssertTrue(due)
    }

    func testStartingUpWithNoPassYetSchedulesOne() async {
        let setup = make()
        await setup.scheduler.noteStartup(lastCompletedPass: nil)
        let due = await waiting(setup)
        XCTAssertTrue(due)
    }

    func testUseADayAfterTheLastPassSchedulesOne() async {
        let setup = make()
        await setup.scheduler.noteStartup(lastCompletedPass: setup.clock.now.addingTimeInterval(-3_600))
        await setup.scheduler.noteActivity()
        await settle()
        XCTAssertEqual(setup.sleeper.waitingCount, 0, "an hour after a pass")

        setup.clock.advance(hours: 23)
        await setup.scheduler.noteActivity()
        await settle()
        XCTAssertEqual(setup.sleeper.waitingCount, 0, "exactly a day")

        setup.clock.advance(hours: 1)
        await setup.scheduler.noteActivity()
        let due = await waiting(setup)
        XCTAssertTrue(due)
    }

    func testUseWithNoPassYetSchedulesOne() async {
        let setup = make()
        await setup.scheduler.noteActivity()
        let due = await waiting(setup)
        XCTAssertTrue(due)
    }

    func testEnoughNewMemoriesScheduleAPassAndAPassStartsTheCountOver() async {
        let setup = make()
        await setup.scheduler.noteChanges(24)
        await settle()
        XCTAssertEqual(setup.sleeper.waitingCount, 0, "24 changes")
        await setup.scheduler.noteChanges(1)
        let due = await waiting(setup)
        XCTAssertTrue(due, "25")

        setup.sleeper.wake()
        let ran = await passed(setup, 1)
        XCTAssertTrue(ran)
        await settle()
        await setup.scheduler.noteChanges(24)
        await settle()
        XCTAssertEqual(setup.sleeper.waitingCount, 0, "counted from the pass, not from the start")
    }

    func testAPileOfMemoriesSchedulesAPassButNotOftenerThanTheCooldown() async {
        let setup = make()
        await setup.scheduler.notePressure(memories: 199)
        await settle()
        XCTAssertEqual(setup.sleeper.waitingCount, 0)

        await setup.scheduler.notePressure(memories: 200)
        let due = await waiting(setup)
        XCTAssertTrue(due)
        setup.sleeper.wake()
        let ran = await passed(setup, 1)
        XCTAssertTrue(ran)
        await settle()

        // A pass has just been, and it could not thin them out any further than it did.
        await setup.scheduler.notePressure(memories: 500)
        await settle()
        XCTAssertEqual(setup.sleeper.waitingCount, 0)

        setup.clock.advance(hours: 5)
        await setup.scheduler.notePressure(memories: 500)
        await settle()
        XCTAssertEqual(setup.sleeper.waitingCount, 0, "five hours is not six")

        setup.clock.advance(hours: 1)
        await setup.scheduler.notePressure(memories: 500)
        let again = await waiting(setup)
        XCTAssertTrue(again)
    }

    func testAPassThatWasAskedForCountsAsThePassSoNothingIsDueRightAfter() async {
        let setup = make()
        await setup.scheduler.noteChanges(25)
        let due = await waiting(setup)
        XCTAssertTrue(due)

        await setup.scheduler.didRun()
        let none = await waiting(setup, 0)
        XCTAssertTrue(none)
        await setup.scheduler.noteChanges(24)
        await setup.scheduler.notePressure(memories: 900)
        await settle()
        XCTAssertEqual(setup.sleeper.waitingCount, 0, "changes counted anew, and the cooldown is running")
    }

    // MARK: how a pass ends

    func testAPassThatFailsIsTriedAgainMuchLaterAndNeverReachesAnyone() async {
        let setup = make([.failed, .completed])
        await setup.scheduler.markPending()
        let first = await waiting(setup)
        XCTAssertTrue(first)
        setup.sleeper.wake()
        let failed = await passed(setup, 1)
        XCTAssertTrue(failed)

        let later = await waiting(setup)
        XCTAssertTrue(later)
        XCTAssertEqual(setup.sleeper.durations.last, retry)

        setup.sleeper.wake()
        let done = await passed(setup, 2)
        XCTAssertTrue(done)
        await settle()
        XCTAssertEqual(setup.sleeper.waitingCount, 0)
    }

    func testAPassThatGaveWayToTheUserIsTriedAgainAfterTheNextQuietWindow() async {
        let setup = make([.cancelled, .completed])
        await setup.scheduler.markPending()
        let first = await waiting(setup)
        XCTAssertTrue(first)
        setup.sleeper.wake()
        let cancelled = await passed(setup, 1)
        XCTAssertTrue(cancelled)

        let again = await waiting(setup)
        XCTAssertTrue(again)
        XCTAssertEqual(setup.sleeper.durations.last, idle)
        setup.sleeper.wake()
        let done = await passed(setup, 2)
        XCTAssertTrue(done)
    }

    func testAPassThatHadNothingToRunIsNotTriedAgain() async {
        let setup = make([nil])
        await setup.scheduler.markPending()
        let first = await waiting(setup)
        XCTAssertTrue(first)
        setup.sleeper.wake()
        let ran = await passed(setup, 1)
        XCTAssertTrue(ran)
        await settle()
        XCTAssertEqual(setup.sleeper.waitingCount, 0)
    }

    func testOnlyOnePassRunsAtATimeAndWhatCameInMeanwhileGetsAnother() async {
        let setup = make()
        let release = ManualSleeper()
        setup.passes.hold = { try? await release.sleep(.seconds(1)) }

        await setup.scheduler.markPending()
        let first = await waiting(setup)
        XCTAssertTrue(first)
        setup.sleeper.wake()
        let running = await eventually { release.waitingCount == 1 }
        XCTAssertTrue(running)

        await setup.scheduler.markPending()
        await setup.scheduler.markPending()
        await settle()
        XCTAssertEqual(setup.sleeper.waitingCount, 0, "not while one is running")

        setup.passes.hold = nil
        release.wake()
        let next = await waiting(setup)
        XCTAssertTrue(next, "and another one after it")
        setup.sleeper.wake()
        let second = await passed(setup, 2)
        XCTAssertTrue(second)
        await settle()
        XCTAssertEqual(setup.passes.count, 2)
        XCTAssertEqual(setup.passes.mostAtOnce, 1)
    }
}
