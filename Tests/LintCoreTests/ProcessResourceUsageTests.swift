import XCTest

@testable import LintCore

final class ProcessResourceUsageTests: XCTestCase {
    func testReadsThisProcess() throws {
        let sample = try XCTUnwrap(ProcessResourceSample.read(pid: getpid()))
        XCTAssertGreaterThan(sample.footprint, 1_000_000)
        XCTAssertGreaterThan(sample.cpuTime, 0)
    }

    /// `getrusage` counts in microseconds; a Mach-tick reading left unconverted is 41 times off on Apple
    /// silicon.
    func testCPUTimeIsInNanoseconds() throws {
        var value = 1.0
        let end = Date().addingTimeInterval(0.2)
        while Date() < end { value = value * 1.000_001 + 1 }
        XCTAssertGreaterThan(value, 1)

        var usage = rusage()
        getrusage(RUSAGE_SELF, &usage)
        let sample = try XCTUnwrap(ProcessResourceSample.read(pid: getpid()))
        let seconds = Double(usage.ru_utime.tv_sec + usage.ru_stime.tv_sec)
        let microseconds = Double(usage.ru_utime.tv_usec + usage.ru_stime.tv_usec)
        let expected = seconds * 1e9 + microseconds * 1e3
        XCTAssertEqual(Double(sample.cpuTime), expected, accuracy: max(expected * 0.1, 20_000_000))
    }

    func testAProcessThatExitedCannotBeRead() throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/true")
        try process.run()
        process.waitUntilExit()
        XCTAssertNil(ProcessResourceSample.read(pid: process.processIdentifier))
    }

    func testCPUPercentCountsOneBusyCoreAsAHundred() {
        let earlier = ProcessResourceSample(cpuTime: 1_000_000_000, footprint: 0, takenAt: 5_000_000_000)
        let half = ProcessResourceSample(cpuTime: 1_500_000_000, footprint: 0, takenAt: 6_000_000_000)
        XCTAssertEqual(try XCTUnwrap(half.cpuPercent(since: earlier)), 50, accuracy: 0.001)
        let twoCores = ProcessResourceSample(cpuTime: 3_000_000_000, footprint: 0, takenAt: 6_000_000_000)
        XCTAssertEqual(try XCTUnwrap(twoCores.cpuPercent(since: earlier)), 200, accuracy: 0.001)
    }

    func testCPUPercentNeedsTimeToPass() {
        let sample = ProcessResourceSample(cpuTime: 1_000_000_000, footprint: 0, takenAt: 5_000_000_000)
        XCTAssertNil(sample.cpuPercent(since: sample))
        let older = ProcessResourceSample(cpuTime: 2_000_000_000, footprint: 0, takenAt: 4_000_000_000)
        XCTAssertNil(sample.cpuPercent(since: older), "a reused pid's CPU time can go backwards")
    }
}
