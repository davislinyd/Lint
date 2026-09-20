import XCTest
@testable import LintCore

final class TimeoutTests: XCTestCase {
    func testAFastOperationReturnsItsOwnResult() async {
        let value = await withTimeout(.seconds(5), fallback: "fallback") { "done" }
        XCTAssertEqual(value, "done")
    }

    func testASlowOperationGivesWayToTheFallback() async {
        let start = ContinuousClock.now
        let value = await withTimeout(.milliseconds(50), fallback: "fallback") {
            try? await Task.sleep(for: .seconds(5))
            return "slow"
        }
        XCTAssertEqual(value, "fallback")
        XCTAssertLessThan(ContinuousClock.now - start, .seconds(1))
    }

    func testAnOperationThatIgnoresCancellationDoesNotHoldTheCallerUp() async {
        let start = ContinuousClock.now
        let value = await withTimeout(.milliseconds(100), fallback: "fallback") {
            // Resumed from a queue after a second, whatever happens to the task waiting for it.
            await withCheckedContinuation { (continuation: CheckedContinuation<String, Never>) in
                DispatchQueue.global().asyncAfter(deadline: .now() + 1) { continuation.resume(returning: "late") }
            }
        }
        XCTAssertEqual(value, "fallback")
        XCTAssertLessThan(ContinuousClock.now - start, .milliseconds(700))
    }

    func testCancellingTheCallerReturnsAtOnce() async {
        let start = ContinuousClock.now
        let task = Task {
            await withTimeout(.seconds(5), fallback: "fallback") {
                try? await Task.sleep(for: .seconds(5))
                return "slow"
            }
        }
        try? await Task.sleep(for: .milliseconds(50))
        task.cancel()
        let value = await task.value
        XCTAssertEqual(value, "fallback")
        XCTAssertLessThan(ContinuousClock.now - start, .seconds(1))
    }

    func testACallerThatIsAlreadyCancelledGetsTheFallbackWithoutWaiting() async {
        let start = ContinuousClock.now
        let task = Task {
            // Wait until this task is cancelled, then ask for the timeout.
            while !Task.isCancelled { await Task.yield() }
            return await withTimeout(.seconds(5), fallback: "fallback") {
                try? await Task.sleep(for: .seconds(5))
                return "slow"
            }
        }
        try? await Task.sleep(for: .milliseconds(20))
        task.cancel()
        let value = await task.value
        XCTAssertEqual(value, "fallback")
        XCTAssertLessThan(ContinuousClock.now - start, .seconds(1))
    }

    func testRacingManyTimesNeverResumesTwice() async {
        for _ in 0..<300 {
            _ = await withTimeout(.milliseconds(1), fallback: 0) { 1 }
        }
    }
}
