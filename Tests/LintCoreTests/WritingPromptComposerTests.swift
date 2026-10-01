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

    /// The tones that correct a text in its own language. Native writes English whatever the text is in.
    private let tonesEditingInPlace = WritingTone.allCases.filter { !$0.isNative }
    private let nativeTones = WritingTone.allCases.filter(\.isNative)

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
        for tone in tonesEditingInPlace {
            let prompt = compose(.proofread, tone)
            for phrase in keepsSourceLanguage {
                XCTAssertTrue(prompt.contains(phrase), "proofread \(tone) lacks \(phrase)")
            }
        }
    }

    func testProofreadEditsTheEnglishOnly() {
        for tone in tonesEditingInPlace {
            let prompt = compose(.proofread, tone)
            XCTAssertTrue(prompt.contains("中英夾雜時只修改英文部分，中文一字不改"), "\(tone)")
            for chinesePolish in ["的／地／得", "精通繁體中文", "中文："] {
                XCTAssertFalse(prompt.contains(chinesePolish), "\(tone): \(chinesePolish)")
            }
            XCTAssertFalse(prompt.hasSuffix("\n"), "\(tone)")
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

    func testProofreadNativeWritesEnglishWhateverLanguageTheTextIsIn() {
        for tone in nativeTones {
            let prompt = compose(.proofread, tone)
            XCTAssertTrue(prompt.contains("語氣：母語人士"), "\(tone)")
            XCTAssertTrue(prompt.contains("一律用英文作答"), "\(tone)")
            XCTAssertTrue(prompt.contains("不要逐字翻譯"), "\(tone)")
            XCTAssertTrue(prompt.contains("整句重寫"), "\(tone)")
            XCTAssertTrue(prompt.contains("忠實度優先"), "\(tone)")
            XCTAssertTrue(prompt.contains("共通規則"), "\(tone)")
            XCTAssertFalse(prompt.hasSuffix("\n"), "\(tone)")
            // Nothing that asks for the text's own language, or for a minimal edit.
            for phrase in keepsSourceLanguage + ["中英夾雜時只修改英文部分", "原樣保留", "只改有問題"] {
                XCTAssertFalse(prompt.contains(phrase), "\(tone): \(phrase)")
            }
            XCTAssertFalse(prompt.contains("保留原語氣"), "\(tone)")
        }
    }

    func testEachNativeStyleSaysHowItShouldSoundAndTheOthersDoNot() {
        let styles: [(WritingTone, String, [String])] = [
            (.nativeCasual, "語氣：母語人士 · 輕鬆", ["口語", "縮寫"]),
            (.nativeFormal, "語氣：母語人士 · 正式", ["書面", "不用縮寫", "俚語"]),
            (.nativeGenZ, "語氣：母語人士 · Gen Z", ["tbh", "不主動加表情符號", "嚴肅", "不改事實"]),
        ]
        for (tone, heading, phrases) in styles {
            let prompt = compose(.proofread, tone)
            XCTAssertTrue(prompt.contains(heading), "\(tone)")
            for phrase in phrases { XCTAssertTrue(prompt.contains(phrase), "\(tone): \(phrase)") }
            for (other, otherHeading, _) in styles where other != tone {
                XCTAssertFalse(prompt.contains(otherHeading), "\(tone) mentions \(other)")
            }
        }
        // The plain native prompt names no style, and the four share everything but that line.
        let plain = compose(.proofread, .native)
        XCTAssertFalse(plain.contains("母語人士 · "))
        for (tone, heading, _) in styles {
            let withoutStyle = compose(.proofread, tone).components(separatedBy: "\n\n").filter { !$0.contains(heading) }
            XCTAssertEqual(withoutStyle, plain.components(separatedBy: "\n\n").filter { !$0.hasPrefix("語氣：母語人士") }, "\(tone)")
        }
    }

    func testAToneOtherThanPreserveDoesNotArgueWithItself() {
        // "Colloquial stays colloquial" and the untouched already-correct example are what
        // preserving the tone means; under another tone they would contradict it.
        for tone in [WritingTone.formal, .concise, .professional] + nativeTones {
            let prompt = compose(.proofread, tone)
            XCTAssertFalse(prompt.contains("口語仍口語"), "\(tone)")
            XCTAssertFalse(prompt.contains("Sounds good"), "\(tone)")
        }
    }

    // MARK: translate

    func testTranslationGoesIntoTraditionalChineseByDefault() {
        for tone in WritingTone.allCases {
            let prompt = compose(.translate, tone)
            XCTAssertTrue(prompt.contains("翻譯成繁體中文"), "\(tone)")
            XCTAssertTrue(prompt.contains("使用台灣用語與標點習慣"), "\(tone)")
            XCTAssertEqual(
                prompt,
                WritingPromptComposer.compose(mode: .translate, tone: tone, customPrompt: "", translationLanguage: .traditionalChinese)
            )
        }
    }

    func testTranslationGoesIntoTheChosenLanguage() {
        let expected: [TranslationLanguage: String] = [
            .indonesian: "印尼文", .japanese: "日文", .korean: "韓文", .portuguese: "巴西葡萄牙文",
            .simplifiedChinese: "簡體中文", .thai: "泰文", .traditionalChinese: "繁體中文", .vietnamese: "越南文",
        ]
        XCTAssertEqual(Set(expected.keys), Set(TranslationLanguage.allCases))
        for (language, name) in expected {
            for tone in WritingTone.allCases {
                let prompt = WritingPromptComposer.compose(
                    mode: .translate, tone: tone, customPrompt: "", translationLanguage: language
                )
                XCTAssertTrue(prompt.contains("把使用者文字翻譯成\(name)。"), "\(language) \(tone)")
            }
        }
    }

    func testTheTranslationLanguageChangesOnlyTheTranslation() {
        for mode in [WritingMode.proofread, .custom] {
            XCTAssertEqual(
                WritingPromptComposer.compose(mode: mode, tone: .formal, customPrompt: "詩", translationLanguage: .japanese),
                compose(mode, .formal, custom: "詩"), "\(mode)"
            )
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

    func testTranslationHasNoNativeTone() {
        for language in TranslationLanguage.allCases {
            for tone in nativeTones {
                XCTAssertEqual(
                    WritingPromptComposer.compose(mode: .translate, tone: tone, customPrompt: "", translationLanguage: language),
                    WritingPromptComposer.compose(mode: .translate, tone: .preserve, customPrompt: "", translationLanguage: language),
                    "\(language) \(tone)"
                )
            }
        }
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
        XCTAssertEqual(WritingPromptComposer.overrideKey(mode: .proofread, tone: .native), "proofread|native")
        XCTAssertEqual(WritingPromptComposer.overrideKey(mode: .proofread, tone: .nativeGenZ), "proofread|nativeGenZ")
        XCTAssertEqual(Set(all).count, 2 * WritingTone.allCases.count + 1, "every task and tone pair, and custom")
    }
}
