import Foundation
import XCTest

@testable import LintCore

/// Answers from a table, and records what it was asked.
private final class FakeCorrector: GrammarCorrectionProvider, @unchecked Sendable {
    private let lock = NSLock()
    private var answers: [String: String]
    private(set) var asked: [String] = []

    init(_ answers: [String: String]) { self.answers = answers }

    func correct(_ sentence: String) async throws -> String {
        lock.withLock {
            asked.append(sentence)
            return answers[sentence] ?? sentence
        }
    }
}

final class GrammarCorrectionTests: XCTestCase {
    private let model = URL(fileURLWithPath: "/models/gec.gguf")

    func testTheRequestIsTheGECPrefixWithGreedyDecodingAndNoEscapes() {
        let arguments = LlamaCompletionGECProvider.arguments(model: model, sentence: #"He go to school\n yesterday."#)
        XCTAssertEqual(arguments[0...3], ["-m", "/models/gec.gguf", "-p", #"gec: He go to school\n yesterday."#])
        for flag in ["--temp", "--top-k", "-no-cnv", "--no-display-prompt", "--no-escape"] {
            XCTAssertTrue(arguments.contains(flag), flag)
        }
        XCTAssertEqual(arguments[arguments.firstIndex(of: "--temp")! + 1], "0")
        XCTAssertEqual(arguments[arguments.firstIndex(of: "--top-k")! + 1], "1")
        XCTAssertEqual(LlamaCompletionGECProvider.environment, ["GGML_METAL_DEVICES": "0"])
    }

    func testTheAnswerIsReadUpToTheEndMarker() throws {
        XCTAssertEqual(try LlamaCompletionGECProvider.parse(" He went to school yesterday. [end of text]\n\n"), "He went to school yesterday.")
        XCTAssertThrowsError(try LlamaCompletionGECProvider.parse(" He went to school yester")) {
            XCTAssertEqual($0 as? GrammarCorrectionError, .truncated)
        }
        XCTAssertThrowsError(try LlamaCompletionGECProvider.parse(" [end of text]")) {
            XCTAssertEqual($0 as? GrammarCorrectionError, .emptyOutput)
        }
    }

    func testAFailedProcessIsAnError() async {
        let provider = LlamaCompletionGECProvider(
            executable: URL(fileURLWithPath: "/bin/false"), model: model,
            run: { _, _, _, _ in ProcessResult(status: 1, stdout: "") }
        )
        do {
            _ = try await provider.correct("Hi.")
            XCTFail("expected an error")
        } catch {
            XCTAssertEqual(error as? GrammarCorrectionError, .processFailed(1))
        }
    }

    func testAProcessThatRunsTooLongIsStopped() async {
        let started = Date()
        do {
            _ = try await ProcessRun.run(URL(fileURLWithPath: "/bin/sleep"), ["5"], [:], .milliseconds(200))
            XCTFail("expected a timeout")
        } catch {
            XCTAssertEqual(error as? GrammarCorrectionError, .timedOut)
        }
        XCTAssertLessThan(Date().timeIntervalSince(started), 3)
    }

    func testCancellingStopsTheProcess() async {
        let started = Date()
        let task = Task { try await ProcessRun.run(URL(fileURLWithPath: "/bin/sleep"), ["5"], [:], .seconds(30)) }
        try? await Task.sleep(for: .milliseconds(200))
        task.cancel()
        let result = await task.result
        XCTAssertThrowsError(try result.get()) { XCTAssertTrue($0 is CancellationError) }
        XCTAssertLessThan(Date().timeIntervalSince(started), 3)
    }

    func testStandardOutputIsReturnedWithTheExtraEnvironment() async throws {
        let result = try await ProcessRun.run(URL(fileURLWithPath: "/bin/sh"), ["-c", "echo $LINT_GEC_TEST"], ["LINT_GEC_TEST": "hello"], .seconds(5))
        XCTAssertEqual(result, ProcessResult(status: 0, stdout: "hello\n"))
    }

    func testALineIsCutIntoItsMarkerSentencesAndSpaces() {
        let pieces = GrammarCorrector.pieces(ofLine: "  - He go home. She are late!  Ok")
        XCTAssertEqual(pieces.map(\.text).joined(), "  - He go home. She are late!  Ok")
        XCTAssertEqual(pieces.filter(\.isSentence).map(\.text), ["He go home.", "She are late!", "Ok"])
        XCTAssertEqual(GrammarCorrector.pieces(ofLine: "1. First item  ").map(\.text), ["1. ", "First item", "  "])
        XCTAssertEqual(GrammarCorrector.pieces(ofLine: ""), [])
    }

    func testOnlyTextTheModelCanWriteBackIsSent() {
        XCTAssertTrue(GrammarCorrector.isReadable("He don't like the café’s coffee — at all."))
        XCTAssertFalse(GrammarCorrector.isReadable("這個 PR 我 review 過了"))
        XCTAssertFalse(GrammarCorrector.isReadable("Set `LOG_LEVEL=debug` first."))
        XCTAssertFalse(GrammarCorrector.isReadable("Use {name} here."))
        XCTAssertFalse(GrammarCorrector.isReadable("12:30"), "no English")
    }

    func testLinesListsAndSpacingSurviveAndEachSentenceIsCorrectedAlone() async throws {
        let fake = FakeCorrector(["He go home.": "He goes home.", "She are late.": "She is late."])
        let text = "Hi team,\n\n- He go home. She are late.\n  2. Done\n"
        let result = try await GrammarCorrector(provider: fake).correct(text)
        XCTAssertEqual(result.text, "Hi team,\n\n- He goes home. She is late.\n  2. Done\n")
        XCTAssertEqual(fake.asked, ["Hi team,", "He go home.", "She are late.", "Done"])
        XCTAssertEqual(result.corrected, 4)
        XCTAssertEqual(result.keptSource, 0)
    }

    func testAnAnswerThatLosesALiteralKeepsTheSentence() async throws {
        let fake = FakeCorrector([
            "See https://example.com/a_b for detail.": "See https://example.com/ab for details.",
            "It work.": "It works.",
        ])
        let result = try await GrammarCorrector(provider: fake).correct("See https://example.com/a_b for detail. It work.")
        XCTAssertEqual(result.text, "See https://example.com/a_b for detail. It works.")
        XCTAssertEqual(result.keptSource, 1)
    }

    func testChineseAndCodeAreNeverSent() async throws {
        let fake = FakeCorrector([:])
        let result = try await GrammarCorrector(provider: fake).correct("這個 PR 我 review 過了。\nRun `make` now.")
        XCTAssertEqual(result.text, "這個 PR 我 review 過了。\nRun `make` now.")
        XCTAssertEqual(fake.asked, [])
        XCTAssertEqual(result.skipped, 2)
    }

    func testSpacesTheModelPutsInsideWordsAreTakenOut() {
        XCTAssertEqual(
            GrammarCorrector.keepingSpacing(
                of: "The config file config/settings.prod.yaml have a wrong timeout value.",
                in: "The config file config / settings. prod. yaml has a wrong timeout value."
            ),
            "The config file config/settings.prod.yaml has a wrong timeout value."
        )
        XCTAssertEqual(
            GrammarCorrector.keepingSpacing(of: "The review are at 14:30 (UTC+8).", in: "The review is at 14:30( UTC +8)."),
            "The review is at 14:30 (UTC+8)."
        )
        XCTAssertEqual(GrammarCorrector.keepingSpacing(of: "I've attached the Q3 report.", in: "I've attached the Q 3 report."), "I've attached the Q3 report.")
        XCTAssertEqual(GrammarCorrector.keepingSpacing(of: "He go home.", in: "He goes home."), "He goes home.")
        XCTAssertEqual(GrammarCorrector.keepingSpacing(of: "The datas shows it.", in: "The data shows it."), "The data shows it.")
        XCTAssertEqual(GrammarCorrector.keepingSpacing(of: "It got alot of votes.", in: "It got a lot of votes."), "It got a lot of votes.")
        XCTAssertEqual(
            GrammarCorrector.keepingSpacing(of: "We shipped the fix ,tested it .Everything is fine", in: "We shipped the fix, tested it. Everything is fine."),
            "We shipped the fix, tested it. Everything is fine."
        )
    }

    func testEmptyTextSendsNothing() async throws {
        let fake = FakeCorrector([:])
        let result = try await GrammarCorrector(provider: fake).correct("")
        XCTAssertEqual(result.text, "")
        XCTAssertEqual(fake.asked, [])
    }
}
