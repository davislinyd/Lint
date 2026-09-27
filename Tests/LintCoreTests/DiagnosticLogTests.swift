import XCTest

@testable import LintCore

final class DiagnosticLogTests: XCTestCase {
    private func makeDirectory() -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("LintDiagnosticLogTests-\(UUID().uuidString)", isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        return dir.appendingPathComponent("Logs", isDirectory: true)
    }

    private func makeLog(maxFileBytes: Int = 1_000_000) -> (DiagnosticLog, URL) {
        let dir = makeDirectory()
        let log = DiagnosticLog(directory: dir, maxFileBytes: maxFileBytes) { Date(timeIntervalSince1970: 1_800_000_000) }
        return (log, dir)
    }

    private func contents(_ dir: URL, _ name: String) -> String? {
        (try? Data(contentsOf: dir.appendingPathComponent(name))).map { String(decoding: $0, as: UTF8.self) }
    }

    func testEachEventIsOneTimestampedLine() throws {
        let (log, dir) = makeLog()
        log.log("replace", "confirmed")
        log.log("write", "first\nsecond\r\nthird")
        let lines = try XCTUnwrap(contents(dir, "lint.log")).split(separator: "\n")
        XCTAssertEqual(lines.count, 2)
        XCTAssertTrue(lines[0].hasPrefix("2027-01-1"), "local time of the fixed clock: \(lines[0])")
        XCTAssertTrue(lines[0].hasSuffix(" [replace] confirmed"))
        XCTAssertTrue(lines[1].hasSuffix(" [write] first ⏎ second ⏎ third"), "\(lines[1])")
    }

    func testRotatesAtTheSizeLimitAndKeepsOnlyTwoFiles() throws {
        let (log, dir) = makeLog(maxFileBytes: 300)
        for index in 0..<100 { log.log("test", "event \(index)") }
        let names = try FileManager.default.contentsOfDirectory(atPath: dir.path).sorted()
        XCTAssertEqual(names, ["lint.1.log", "lint.log"])
        for name in names {
            let size = try XCTUnwrap(FileManager.default.attributesOfItem(atPath: dir.appendingPathComponent(name).path)[.size] as? NSNumber)
            XCTAssertLessThanOrEqual(size.intValue, 300, name)
        }
        let recent = log.recentLines()
        XCTAssertTrue(recent.hasSuffix("[test] event 99"))
        XCTAssertFalse(recent.contains("event 0\n"))
    }

    func testRecentLinesSpanBothFilesOldestFirst() throws {
        let (log, dir) = makeLog(maxFileBytes: 200)
        for index in 0..<6 { log.log("test", "event \(index)") }
        XCTAssertNotNil(contents(dir, "lint.1.log"), "the first lines were rotated out of lint.log")
        let all = log.recentLines().split(separator: "\n")
        let events = all.map { String($0.split(separator: "]").last ?? "") }
        XCTAssertEqual(events, (6 - all.count..<6).map { " event \($0)" })
        XCTAssertGreaterThan(all.count, 2, "lines from both files")
        XCTAssertEqual(log.recentLines(2).split(separator: "\n").count, 2)
        XCTAssertTrue(log.recentLines(2).hasSuffix("event 5"))
    }

    func testClearRemovesBothFilesAndLoggingStartsAgain() throws {
        let (log, dir) = makeLog(maxFileBytes: 200)
        for index in 0..<10 { log.log("test", "event \(index)") }
        log.clear()
        XCTAssertEqual(log.recentLines(), "")
        XCTAssertNil(contents(dir, "lint.log"))
        XCTAssertNil(contents(dir, "lint.1.log"))
        log.log("test", "after")
        XCTAssertTrue(log.recentLines().hasSuffix("[test] after"))
    }

    func testTheFileIsReadableOnlyByTheUser() throws {
        let (log, dir) = makeLog()
        log.log("test", "event")
        let attributes = try FileManager.default.attributesOfItem(atPath: dir.appendingPathComponent("lint.log").path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        let folder = try FileManager.default.attributesOfItem(atPath: dir.path)
        XCTAssertEqual((folder[.posixPermissions] as? NSNumber)?.intValue, 0o700)
    }

    func testTheHomeFolderIsShortenedAndLongMessagesAreCut() {
        let (log, _) = makeLog()
        log.log("server", "launch \(NSHomeDirectory())/Library/Application Support/Lint/Models/x.gguf")
        XCTAssertTrue(log.recentLines().hasSuffix("launch ~/Library/Application Support/Lint/Models/x.gguf"))
        log.log("test", String(repeating: "x", count: 5000))
        let last = String(log.recentLines(1))
        XCTAssertLessThan(last.count, 1100)
        XCTAssertTrue(last.hasSuffix("x…"))
    }

    func testALogThatWasNotStartedWritesNothing() throws {
        let dir = makeDirectory()
        let log = DiagnosticLog(directory: nil)
        log.log("test", "event")
        XCTAssertEqual(log.recentLines(), "")
        XCTAssertNil(log.currentFileURL)
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.path))
        log.start(in: dir)
        log.log("test", "event")
        XCTAssertEqual(log.currentFileURL, dir.appendingPathComponent("lint.log"))
        XCTAssertTrue(log.recentLines().hasSuffix("[test] event"))
    }

    func testErrorsNeverCarryAServerReplyOrAnUnknownDescription() {
        let reply = DiagnosticLog.describe(LLMError.httpStatus(500, "MARKER the user's text"))
        XCTAssertEqual(reply, "LLMError.httpStatus(500)")
        XCTAssertEqual(
            DiagnosticLog.describe(LLMError.httpStatus(400, "{\"type\":\"exceed_context_size_error\",\"text\":\"MARKER\"}")),
            "LLMError.httpStatus(400) exceed_context_size"
        )
        let unknown = NSError(domain: "Example", code: 7, userInfo: [NSLocalizedDescriptionKey: "MARKER"])
        XCTAssertEqual(DiagnosticLog.describe(unknown), "NSError (Example 7)")
        let apple = AppleIntelligenceError.generationFailed(diagnostic: "GenerationError.decodingFailure(Context(debugDescription: \"MARKER\"))")
        XCTAssertEqual(DiagnosticLog.describe(apple), "AppleIntelligenceError.generationFailed(GenerationError.decodingFailure)")
        XCTAssertEqual(DiagnosticLog.describe(UpdateFailure.hashMismatch), "UpdateFailure.hashMismatch")
        XCTAssertEqual(DiagnosticLog.describe(CancellationError()), "cancelled")
        XCTAssertEqual(DiagnosticLog.describe(URLError(.timedOut)), "URLError(-1001)")
    }

    func testTheSystemSummaryIsInEnglishWhateverTheSystemLanguage() {
        let version = ProcessInfo.processInfo.operatingSystemVersion
        let summary = DiagnosticLog.systemSummary
        XCTAssertTrue(summary.hasPrefix("macOS \(version.majorVersion).\(version.minorVersion)."), summary)
        XCTAssertTrue(summary.hasSuffix(" GB"), summary)
        XCTAssertTrue(summary.unicodeScalars.allSatisfy { $0.isASCII || $0 == "·" }, summary)
    }

    func testOutcomesNameTheIssuesButNotWhatTheyQuote() {
        let outcome = GuardedWritingResult.Outcome.keptSource(issues: [.missing(["MARKER-1"]), .added(["MARKER-2", "x"]), .structureChanged])
        XCTAssertEqual(outcome.diagnosticName, "keptSource(missing×1,added×2,structureChanged)")
        XCTAssertEqual(GuardedWritingResult.Outcome.accepted.diagnosticName, "accepted")
    }
}
