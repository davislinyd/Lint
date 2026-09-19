import XCTest
@testable import LintCore

final class WritingModeTests: XCTestCase {
    func testAllModesHaveTitles() {
        for mode in WritingMode.allCases {
            XCTAssertFalse(mode.title.isEmpty)
            XCTAssertFalse(mode.systemPrompt(customPrompt: "", translateTarget: "日文").isEmpty)
        }
    }

    func testTranslateUsesTargetLanguage() {
        let prompt = WritingMode.translate.systemPrompt(customPrompt: "", translateTarget: "日文")
        XCTAssertTrue(prompt.contains("日文"))
    }

    func testCustomFallsBackToProofreadWhenEmpty() {
        let custom = WritingMode.custom.systemPrompt(customPrompt: "", translateTarget: "")
        let proof = WritingMode.proofread.systemPrompt(customPrompt: "", translateTarget: "")
        XCTAssertEqual(custom, proof)
    }

    func testCustomIncludesUserPrompt() {
        let prompt = WritingMode.custom.systemPrompt(customPrompt: "改成詩句", translateTarget: "")
        XCTAssertTrue(prompt.contains("改成詩句"))
    }
}
