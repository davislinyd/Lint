import XCTest

@testable import LintCore

private let quiet: Duration = .seconds(3)
private let budget: Duration = .seconds(120)

final class ModelPriorityGateTests: XCTestCase {
    private func makeGate(maxWaiting: Int = 8) -> (ModelPriorityGate, StepSleeper) {
        let sleeper = StepSleeper()
        let gate = ModelPriorityGate(quietPeriod: quiet, maxWaiting: maxWaiting, sleep: sleeper.sleep)
        return (gate, sleeper)
    }

    private func acquire(_ gate: ModelPriorityGate, front: Bool = false, onPreempt: @escaping @Sendable () -> Void = {}) -> Task<ModelPriorityGate.ExternalLease, Error> {
        Task { try await gate.acquireExternal(front: front, budget: budget, onPreempt: onPreempt) }
    }

    func testAnIdleModelGoesToAnExternalRequestAtOnce() async throws {
        let (gate, _) = makeGate()
        let lease = try await acquire(gate).value
        XCTAssertTrue(gate.isExternalActive)
        lease.release()
        XCTAssertFalse(gate.isExternalActive)
    }

    func testLintNeverWaitsAndInterruptsTheExternalRequestOnce() async throws {
        let (gate, _) = makeGate()
        let preempted = Counter()
        let lease = try await acquire(gate, onPreempt: { preempted.add() }).value
        let first = gate.beginLint()
        let second = gate.beginLint()
        XCTAssertEqual(preempted.value, 1, "one interruption per external request, however many Lint requests overlap")
        XCTAssertTrue(lease.wasPreempted)
        first.end()
        second.end()
        lease.release()
    }

    func testAnExternalRequestWaitsWhileLintRunsAndThroughTheQuietPeriod() async throws {
        let (gate, sleeper) = makeGate()
        let ticket = gate.beginLint()
        let waiting = acquire(gate)
        await settle()
        XCTAssertFalse(gate.isExternalActive)
        ticket.end()
        await settle()
        XCTAssertFalse(gate.isExternalActive, "Lint often sends another request right after one")
        let woke = await sleeper.wakeOldest(quiet)
        XCTAssertTrue(woke)
        let lease = try await waiting.value
        XCTAssertTrue(gate.isExternalActive)
        lease.release()
    }

    func testTypingStartsTheQuietPeriodAgain() async throws {
        let (gate, sleeper) = makeGate()
        gate.beginLint().end()
        let waiting = acquire(gate)
        await settle()
        gate.noteLintActivity()
        let woke = await sleeper.wakeOldest(quiet)
        XCTAssertTrue(woke, "the period that began when Lint's request ended")
        await settle()
        XCTAssertFalse(gate.isExternalActive, "typing since then still holds external requests back")
        let wokeAgain = await sleeper.wakeOldest(quiet)
        XCTAssertTrue(wokeAgain)
        let lease = try await waiting.value
        lease.release()
    }

    func testExternalRequestsGoOneAtATimeInTheOrderTheyCame() async throws {
        let (gate, _) = makeGate()
        let order = Recorder()
        let a = try await acquire(gate).value
        let b = Task { let lease = try await gate.acquireExternal(budget: budget, onPreempt: {}); order.append("b"); return lease }
        await settle()
        let c = Task { let lease = try await gate.acquireExternal(budget: budget, onPreempt: {}); order.append("c"); return lease }
        await settle()
        XCTAssertEqual(order.items, [])
        a.release()
        let leaseB = try await b.value
        await settle()
        XCTAssertEqual(order.items, ["b"], "c waits for b")
        leaseB.release()
        try await c.value.release()
        XCTAssertEqual(order.items, ["b", "c"])
    }

    func testAnInterruptedRequestGoesBackToTheFrontOfTheQueue() async throws {
        let (gate, sleeper) = makeGate()
        let order = Recorder()
        let a = try await acquire(gate).value
        let b = Task { let lease = try await gate.acquireExternal(budget: budget, onPreempt: {}); order.append("b"); return lease }
        await settle()
        let ticket = gate.beginLint()
        a.release()
        let again = Task { let lease = try await gate.acquireExternal(front: true, budget: budget, onPreempt: {}); order.append("a"); return lease }
        await settle()
        ticket.end()
        let woke = await sleeper.wakeOldest(quiet)
        XCTAssertTrue(woke)
        let leaseA = try await again.value
        XCTAssertEqual(order.items, ["a"])
        leaseA.release()
        try await b.value.release()
        XCTAssertEqual(order.items, ["a", "b"])
    }

    func testAFullQueueTurnsNewRequestsAwayButNotOnesComingBack() async throws {
        let (gate, _) = makeGate(maxWaiting: 2)
        let ticket = gate.beginLint()
        let b = acquire(gate)
        let c = acquire(gate)
        await settle()
        do {
            _ = try await acquire(gate).value
            XCTFail("expected queueFull")
        } catch ModelPriorityGate.GateError.queueFull {}
        let back = acquire(gate, front: true)
        await settle()
        XCTAssertEqual(gate.waitingCount, 3)
        gate.cancelAllExternal()
        ticket.end()
        for task in [b, c, back] {
            do { _ = try await task.value; XCTFail("expected closed") } catch ModelPriorityGate.GateError.closed {}
        }
    }

    func testARequestThatWaitedTooLongGivesUp() async throws {
        let (gate, sleeper) = makeGate()
        let ticket = gate.beginLint()
        let waiting = acquire(gate)
        await settle()
        let woke = await sleeper.wakeOldest(budget)
        XCTAssertTrue(woke)
        do {
            _ = try await waiting.value
            XCTFail("expected timedOut")
        } catch ModelPriorityGate.GateError.timedOut {}
        XCTAssertEqual(gate.waitingCount, 0)
        ticket.end()
    }

    func testACancelledRequestLeavesTheQueue() async throws {
        let (gate, _) = makeGate()
        let ticket = gate.beginLint()
        let waiting = acquire(gate)
        await settle()
        waiting.cancel()
        do {
            _ = try await waiting.value
            XCTFail("expected cancellation")
        } catch is CancellationError {}
        XCTAssertEqual(gate.waitingCount, 0)
        ticket.end()
    }

    func testEndingTwiceIsHarmlessAndOverlappingLintRequestsAreCounted() async throws {
        let (gate, sleeper) = makeGate()
        let first = gate.beginLint()
        let second = gate.beginLint()
        let waiting = acquire(gate)
        first.end()
        first.end()
        await settle()
        XCTAssertFalse(sleeper.isSleeping(quiet), "Lint is still using the model, so no quiet period has begun")
        XCTAssertFalse(gate.isExternalActive)
        second.end()
        await settle()
        let woke = await sleeper.wakeOldest(quiet)
        XCTAssertTrue(woke)
        try await waiting.value.release()
    }

    func testStoppingTheAPIInterruptsTheActiveRequestAndFailsTheWaitingOnes() async throws {
        let (gate, _) = makeGate()
        let preempted = Counter()
        let lease = try await acquire(gate, onPreempt: { preempted.add() }).value
        let waiting = acquire(gate)
        await settle()
        gate.cancelAllExternal()
        XCTAssertEqual(preempted.value, 1)
        do { _ = try await waiting.value; XCTFail("expected closed") } catch ModelPriorityGate.GateError.closed {}
        lease.release()
        let later = try await acquire(gate).value
        later.release()
    }

    func testTheGateRemembersWhetherAnExternalRequestRanSinceLintsLast() async throws {
        let (gate, _) = makeGate()
        XCTAssertFalse(gate.externalRanSinceLastLint)
        try await acquire(gate).value.release()
        XCTAssertTrue(gate.externalRanSinceLastLint, "Lint's prompt may no longer be in the model's cache")
        gate.beginLint().end()
        XCTAssertFalse(gate.externalRanSinceLastLint)
    }
}

/// A sleep that ends only when the test says so, oldest first per duration.
private final class StepSleeper: @unchecked Sendable {
    private let lock = NSLock()
    private var waiters: [(id: Int, duration: Duration, continuation: CheckedContinuation<Void, any Error>)] = []
    private var next = 0

    var sleep: @Sendable (Duration) async throws -> Void {
        { [self] duration in try await wait(duration) }
    }

    private func wait(_ duration: Duration) async throws {
        let id = lock.withLock { next += 1; return next }
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                lock.lock()
                if Task.isCancelled {
                    lock.unlock()
                    continuation.resume(throwing: CancellationError())
                } else {
                    waiters.append((id, duration, continuation))
                    lock.unlock()
                }
            }
        } onCancel: {
            lock.lock()
            let index = waiters.firstIndex { $0.id == id }
            let continuation = index.map { waiters.remove(at: $0).continuation }
            lock.unlock()
            continuation?.resume(throwing: CancellationError())
        }
    }

    /// Whether something is sleeping for `duration` now.
    func isSleeping(_ duration: Duration) -> Bool {
        lock.withLock { waiters.contains { $0.duration == duration } }
    }

    /// Ends the oldest sleep of `duration`, waiting a moment for one to begin (timers start on their
    /// own tasks); false if none did.
    @discardableResult
    func wakeOldest(_ duration: Duration) async -> Bool {
        for _ in 0..<200 {
            let continuation: CheckedContinuation<Void, any Error>? = lock.withLock {
                guard let index = waiters.firstIndex(where: { $0.duration == duration }) else { return nil }
                return waiters.remove(at: index).continuation
            }
            if let continuation {
                continuation.resume()
                return true
            }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return false
    }
}

private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    var value: Int { lock.withLock { count } }
    func add() { lock.withLock { count += 1 } }
}

private final class Recorder: @unchecked Sendable {
    private let lock = NSLock()
    private var list: [String] = []
    var items: [String] { lock.withLock { list } }
    func append(_ item: String) { lock.withLock { list.append(item) } }
}
