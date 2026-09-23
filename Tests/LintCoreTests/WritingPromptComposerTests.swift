import XCTest
@testable import LintCore

final class WritingPromptComposerTests: XCTestCase {
    private func compose(
        _ mode: WritingMode, _ tone: WritingTone = .preserve, custom: String = ""
    ) -> String {
        WritingPromptComposer.compose(mode: mode, tone: tone, customPrompt: custom)
    }

    /// Wording that only the proofreading task may carry: it says to stay in the source language.
    private let keepsSourceLanguage = ["維持同一語言", "不要擅自翻譯", "自動判斷原文語言"]

    func testEveryTaskAndToneComposesAPrompt() {
        for mode in [WritingMode.proofread, .translate] {
            for tone in WritingTone.allCases {
                XCTAssertFalse(compose(mode, tone).isEmpty, "\(mode) \(tone)")
            }
        }
    }

    func testEveryBuiltInPromptStatesThePriorityAndTheCommonRules() {
        for mode in [WritingMode.proofread, .translate] {
            for tone in WritingTone.allCases {
                let prompt = compose(mode, tone)
                XCTAssertTrue(prompt.contains("忠實度優先"), "\(mode) \(tone)")
                XCTAssertTrue(prompt.contains("共通規則"), "\(mode) \(tone)")
                XCTAssertTrue(prompt.contains("只輸出最終的完整正文"), "\(mode) \(tone)")
            }
        }
    }

    // MARK: proofread

    func testProofreadKeepsTheSourceLanguage() {
        for tone in WritingTone.allCases {
            let prompt = compose(.proofread, tone)
            for phrase in keepsSourceLanguage {
                XCTAssertTrue(prompt.contains(phrase), "proofread \(tone) lacks \(phrase)")
            }
        }
    }

    func testProofreadPreserveKeepsTheOriginalTone() {
        let prompt = compose(.proofread, .preserve)
        XCTAssertTrue(prompt.contains("保留原語氣"))
        XCTAssertTrue(prompt.contains("不要為了換個風格而改寫"))
        XCTAssertTrue(prompt.contains("Sounds good"), "the already-correct example is kept")
    }

    func testProofreadFormalAsksForWrittenLanguage() {
        let prompt = compose(.proofread, .formal)
        XCTAssertTrue(prompt.contains("語氣：正式"))
        XCTAssertTrue(prompt.contains("書面語"))
        XCTAssertTrue(prompt.contains("不等於官腔"))
        XCTAssertFalse(prompt.contains("保留原語氣"))
    }

    func testProofreadConciseIsNotSummarization() {
        let prompt = compose(.proofread, .concise)
        XCTAssertTrue(prompt.contains("不是摘要"))
        XCTAssertTrue(prompt.contains("絕不可刪除事實"))
    }

    func testProofreadProfessionalAsksForBusinessCommunication() {
        let prompt = compose(.proofread, .professional)
        XCTAssertTrue(prompt.contains("語氣：專業"))
        XCTAssertTrue(prompt.contains("同事、主管或客戶"))
        XCTAssertTrue(prompt.contains("不要新增原文沒有的承諾"))
    }

    func testAToneOtherThanPreserveDoesNotArgueWithItself() {
        // "Colloquial stays colloquial" and the untouched already-correct example are what
        // preserving the tone means; under another tone they would contradict it.
        for tone in [WritingTone.formal, .concise, .professional] {
            let prompt = compose(.proofread, tone)
            XCTAssertFalse(prompt.contains("口語仍口語"), "\(tone)")
            XCTAssertFalse(prompt.contains("Sounds good"), "\(tone)")
        }
    }

    // MARK: translate

    func testTranslationAlwaysGoesIntoTraditionalChinese() {
        for tone in WritingTone.allCases {
            let prompt = compose(.translate, tone)
            XCTAssertTrue(prompt.contains("翻譯成繁體中文"), "\(tone)")
            XCTAssertTrue(prompt.contains("使用台灣用語與標點習慣"), "\(tone)")
        }
    }

    func testTranslateNeverTellsTheModelToKeepTheLanguageItIsTranslatingAwayFrom() {
        for tone in WritingTone.allCases {
            let prompt = compose(.translate, tone)
            for phrase in keepsSourceLanguage {
                XCTAssertFalse(prompt.contains(phrase), "translate \(tone) contains \(phrase)")
            }
            XCTAssertFalse(prompt.contains("原樣保留"), "a translation is no proofreading of correct text")
        }
    }

    func testTranslateFormalKeepsTheInformation() {
        let prompt = compose(.translate, .formal)
        XCTAssertTrue(prompt.contains("語氣：正式"))
        XCTAssertTrue(prompt.contains("保留原意與全部資訊"))
    }

    func testTranslateConciseMayNotDropInformation() {
        let prompt = compose(.translate, .concise)
        XCTAssertTrue(prompt.contains("不是摘要"))
        XCTAssertTrue(prompt.contains("不可因求簡而省略原文的任何資訊"))
    }

    func testTranslateProfessionalAsksForNaturalProfessionalLanguage() {
        let prompt = compose(.translate, .professional)
        XCTAssertTrue(prompt.contains("語氣：專業"))
        XCTAssertTrue(prompt.contains("自然的專業語氣"))
    }

    func testTranslatePreserveKeepsTheSpeakingStyle() {
        XCTAssertTrue(compose(.translate, .preserve).contains("說話風格"))
    }

    // MARK: custom

    func testCustomIgnoresTheTone() {
        let plain = compose(.custom, .preserve, custom: "改成詩句")
        for tone in WritingTone.allCases {
            XCTAssertEqual(compose(.custom, tone, custom: "改成詩句"), plain, "\(tone)")
        }
        XCTAssertTrue(plain.contains("改成詩句"))
        XCTAssertFalse(plain.contains("語氣："))
    }

    func testAnEmptyCustomPromptIsProofreadingWithThePreservedTone() {
        let expected = compose(.proofread, .preserve)
        XCTAssertEqual(compose(.custom, custom: ""), expected)
        XCTAssertEqual(compose(.custom, .formal, custom: " \n "), expected)
        XCTAssertEqual(compose(.custom, custom: ""), compose(.custom, custom: ""), "deterministic")
    }

    // MARK: override keys

    func testOverrideKeysArePerTaskAndTone() {
        XCTAssertEqual(WritingPromptComposer.overrideKey(mode: .proofread, tone: .preserve), "proofread|preserve")
        XCTAssertEqual(WritingPromptComposer.overrideKey(mode: .proofread, tone: .professional), "proofread|professional")
        XCTAssertEqual(WritingPromptComposer.overrideKey(mode: .translate, tone: .formal), "translate|formal")
        XCTAssertEqual(WritingPromptComposer.overrideKey(mode: .custom, tone: .concise), "custom")
        let all = WritingMode.allCases.flatMap { mode in
            WritingTone.allCases.map { WritingPromptComposer.overrideKey(mode: mode, tone: $0) }
        }
        XCTAssertEqual(Set(all).count, 9, "eight task and tone pairs, and custom")
    }
}
