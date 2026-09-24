import Foundation
import XCTest

@testable import LintCore

/// The fixtures themselves, and the checks the evaluation applies. These run in every `swift test`;
/// the evaluation itself (`WritingEvalRunTests`) only runs when asked.
final class WritingEvalFixtureTests: XCTestCase {
    func testTheFixturesCoverLintsWorkloadAndAreWellFormed() throws {
        let fixtures = try WritingEvalFixtures.load()
        XCTAssertEqual(fixtures.version, 6)
        XCTAssertGreaterThanOrEqual(fixtures.cases.count, 60, "the set is meant to be about 60-140 cases")
        XCTAssertLessThanOrEqual(fixtures.cases.count, 140)
        XCTAssertEqual(Set(fixtures.cases.map(\.id)).count, fixtures.cases.count, "ids are unique")

        let categories = Set(fixtures.cases.map(\.category))
        for wanted in [
            "english-grammar", "english-minimal-edit",
            "en-to-zh-hant", "tone-formal", "tone-concise", "tone-professional",
            "numbers-dates", "urls", "names", "punctuation", "bullet-list",
            "short-email", "business-writing", "already-correct", "preservation",
            "fragment", "clean-technical", "clean-business", "clean-casual", "casual-preserve",
            "ip-address", "shell-command", "code-identifier", "currency", "file-path", "product-names",
            "english-natural", "english-holdout", "mixed-english",
        ] {
            XCTAssertTrue(categories.contains(wanted), "no fixture for \(wanted)")
        }

        for testCase in fixtures.cases {
            XCTAssertFalse(testCase.input.isEmpty, testCase.id)
            XCTAssertFalse(testCase.note.isEmpty, "\(testCase.id) has nothing for the reviewer to go on")
            XCTAssertNotNil(WritingMode(rawValue: testCase.mode), "\(testCase.id): mode \(testCase.mode)")
            XCTAssertNotNil(WritingTone(rawValue: testCase.tone), "\(testCase.id): tone \(testCase.tone)")
            for token in testCase.mustPreserve ?? [] {
                XCTAssertTrue(testCase.input.contains(token), "\(testCase.id): \(token) is not in the input")
            }
            for token in testCase.mustFix ?? [] {
                XCTAssertTrue(testCase.input.contains(token), "\(testCase.id): \(token) is not in the input")
                XCTAssertNotEqual(testCase.expectUnchanged, true, "\(testCase.id): correct text has nothing to fix")
            }
            XCTAssertFalse(testCase.systemPrompt(profile: .standard).isEmpty)
            XCTAssertFalse(testCase.systemPrompt(profile: .english(.appleOnDevice)).isEmpty)
            XCTAssertFalse(testCase.systemPrompt(profile: .english(.localModel)).isEmpty)
        }
        // English edits, and English-to-Chinese translation only for reference: no Chinese
        // proofreading and no Chinese-to-English translation. Mixed text has its English edited only.
        for testCase in fixtures.cases {
            if testCase.writingMode == .translate {
                XCTAssertEqual(testCase.outputLanguage, .zhHant, "\(testCase.id): translation only goes into Chinese")
            } else {
                let expected: WritingEvalCase.Language = testCase.category == "mixed-english" ? .mixed : .en
                XCTAssertEqual(testCase.outputLanguage, expected, "\(testCase.id): only English is proofread")
            }
        }
        XCTAssertGreaterThanOrEqual(
            fixtures.cases.filter { $0.expectUnchanged == true }.count, 15,
            "enough already-correct text for the clean sentence change rate to mean something"
        )
    }

    // MARK: - The checks themselves

    func testTheChecksCatchWhatLintActuallyCaresAbout() throws {
        let fixtures = try WritingEvalFixtures.load()
        let url = try XCTUnwrap(fixtures.cases.first { $0.category == "urls" })

        XCTAssertEqual(WritingEvalChecks.run(url, output: "   ").map(\.check), ["non-empty"])
        XCTAssertTrue(
            WritingEvalChecks.run(url, output: "<think>hmm</think> The docs moved to \(url.mustPreserve![0]) — please update your bookmarks.")
                .contains { $0.check == "no-thinking" }
        )
        XCTAssertTrue(
            WritingEvalChecks.run(url, output: "Here is the corrected text: \(url.mustPreserve![0])")
                .contains { $0.check == "no-preamble" }
        )
        XCTAssertTrue(
            WritingEvalChecks.run(url, output: "The docs moved to https://example.com/docs — please update your bookmarks.")
                .contains { $0.check == "preserves" },
            "a URL that was quietly shortened is a failure"
        )

        let unchanged = try XCTUnwrap(fixtures.cases.first { $0.expectUnchanged == true })
        XCTAssertTrue(WritingEvalChecks.run(unchanged, output: unchanged.input).isEmpty, "the same text passes")
        XCTAssertTrue(
            WritingEvalChecks.run(unchanged, output: unchanged.input + " Thanks!")
                .contains { $0.check == "unchanged" }
        )

        let bullets = try XCTUnwrap(fixtures.cases.first { $0.id == "bullet-01" })
        XCTAssertTrue(WritingEvalChecks.run(bullets, output: bullets.input).isEmpty)
        XCTAssertTrue(
            WritingEvalChecks.run(bullets, output: "Fix the login redirect, update the readme and ask design about the empty state.")
                .contains { $0.check == "line-structure" },
            "a list that was flattened into a sentence is a failure"
        )
    }

    func testAnErrorLeftInIsCaught() throws {
        let fixtures = try WritingEvalFixtures.load()
        let grammar = try XCTUnwrap(fixtures.cases.first { $0.id == "en-grammar-01" })
        XCTAssertTrue(WritingEvalChecks.run(grammar, output: grammar.input).contains { $0.check == "fixes" })
        XCTAssertFalse(
            WritingEvalChecks.run(grammar, output: "I agree with your opinion, but we should discuss the schedule in more detail.")
                .contains { $0.check == "fixes" }
        )
        XCTAssertGreaterThanOrEqual(fixtures.cases.filter { $0.category == "english-natural" }.count, 10)
    }

    func testTraditionalChineseOutputIsCheckedForSimplifiedCharactersAndMainlandTerms() throws {
        let fixtures = try WritingEvalFixtures.load()
        let translation = try XCTUnwrap(fixtures.cases.first { $0.id == "en2zh-tw-01" })
        XCTAssertTrue(WritingEvalChecks.run(translation, output: "請把影片存到共用雲端硬碟，並更新軟體的預設設定。").isEmpty)
        let checks = WritingEvalChecks.run(translation, output: "请把视频存到共享盘，并更新軟件的默認设置。").map(\.check)
        XCTAssertTrue(checks.contains("simplified-chinese"))
        XCTAssertTrue(checks.contains("taiwan-wording"))
    }

    func testTheLanguageCheckOnlyCatchesTheWrongLanguage() {
        XCTAssertEqual(WritingEvalChecks.hanRatio(of: "Hello there"), 0)
        XCTAssertEqual(WritingEvalChecks.hanRatio(of: "已經完成"), 1)
        XCTAssertNil(WritingEvalChecks.languageFailure(.en, in: "The migration finished at 03:40."))
        XCTAssertNotNil(WritingEvalChecks.languageFailure(.en, in: "遷移已於 03:40 完成。"))
        XCTAssertNil(WritingEvalChecks.languageFailure(.zhHant, in: "遷移已於 03:40 完成。"))
        XCTAssertNotNil(WritingEvalChecks.languageFailure(.zhHant, in: "The migration finished."))
        XCTAssertNil(WritingEvalChecks.languageFailure(.mixed, in: "這個 PR 我 review 過了"))
        XCTAssertNotNil(WritingEvalChecks.languageFailure(.mixed, in: "I reviewed the PR already"))
        XCTAssertNil(WritingEvalChecks.languageFailure(.any, in: "anything at all"))
    }
}
