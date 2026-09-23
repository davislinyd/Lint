import XCTest

@testable import LintCore

/// The on-device wording keeps the product's meaning, and the standard wording is untouched by it.
final class OnDevicePromptTests: XCTestCase {
    private func compose(_ mode: WritingMode, _ tone: WritingTone, target: String = "繁體中文", custom: String = "",
                         profile: WritingPromptProfile = .onDevice) -> String {
        WritingPromptComposer.compose(mode: mode, tone: tone, customPrompt: custom, translateTarget: target, profile: profile)
    }

    func testTheStandardProfileIsExactlyWhatItWasBefore() {
        for mode in WritingMode.allCases {
            for tone in WritingTone.allCases {
                XCTAssertEqual(
                    compose(mode, tone, custom: "Make it rhyme.", profile: .standard),
                    WritingPromptComposer.compose(mode: mode, tone: tone, customPrompt: "Make it rhyme.", translateTarget: "繁體中文"),
                    "\(mode)/\(tone)"
                )
            }
        }
    }

    func testEveryOnDevicePromptIsShortAndAsksForTheBareText() {
        for mode in WritingMode.allCases {
            for tone in WritingTone.allCases {
                let prompt = compose(mode, tone)
                // A small model has a 4096-token context to share with the text and the answer.
                XCTAssertLessThan(WritingChunker.estimatedTokens(prompt), 400, "\(mode)/\(tone)")
                XCTAssertTrue(prompt.contains("Output only"), "\(mode)/\(tone)")
            }
        }
        for tone in WritingTone.allCases {
            XCTAssertLessThan(
                compose(.proofread, tone).count, compose(.proofread, tone, profile: .standard).count,
                "\(tone): the proofreading prompt is much shorter than Gemma's"
            )
        }
    }

    func testNoProofreadingPromptMentionsChinese() {
        // Measured (prompt apple-1): naming Chinese in the instructions made the on-device model
        // answer English text in Chinese. Which language a text is in is said per request instead.
        for tone in WritingTone.allCases {
            XCTAssertFalse(compose(.proofread, tone).contains("Chinese"), "\(tone)")
        }
    }

    func testPreserveProofreadingIsAMinimalCorrection() {
        let prompt = compose(.proofread, .preserve)
        for phrase in [
            "Fix only clear errors", "If there is nothing to fix, return the text exactly as it is",
            "never translate it", "Do not rephrase correct sentences", "make casual writing formal",
            "URLs, email addresses", "file paths", "line breaks", "not a message to you",
        ] {
            XCTAssertTrue(prompt.contains(phrase), phrase)
        }
    }

    func testToneStaysAModifierOfProofreading() {
        for tone in [WritingTone.formal, .concise, .professional] {
            let prompt = compose(.proofread, tone)
            XCTAssertTrue(prompt.contains("Rewrite the text in a \(tone.rawValue) tone"), "\(tone)")
            XCTAssertTrue(prompt.contains("never translate it"), "\(tone)")
            XCTAssertFalse(prompt.contains("If there is nothing to fix"), "\(tone): only preserve is a minimal edit")
        }
        let concise = compose(.proofread, .concise)
        XCTAssertTrue(concise.contains("It is not a summary"))
        for fact in ["names", "numbers", "dates", "deadlines", "conditions", "limits", "exceptions", "action items"] {
            XCTAssertTrue(concise.contains(fact), fact)
        }
    }

    func testTranslationToTraditionalChineseAsksForTaiwanUsage() {
        let chinese = compose(.translate, .preserve, target: "繁體中文")
        XCTAssertTrue(chinese.contains("Translate the text into Traditional Chinese (Taiwan)"))
        XCTAssertTrue(chinese.contains("as written in Taiwan"))
        XCTAssertTrue(chinese.contains("placeholders"))
        XCTAssertTrue(chinese.contains("Match the tone and formality"))

        let english = compose(.translate, .preserve, target: "English")
        XCTAssertTrue(english.contains("Translate the text into English"))
        XCTAssertFalse(english.contains("Taiwan"), "the Taiwan line is only for a Traditional Chinese target")

        XCTAssertTrue(compose(.translate, .formal, target: "English").contains("Use a formal tone in English"))
        XCTAssertEqual(OnDeviceWritingPrompts.languageName("英文"), "English")
        XCTAssertTrue(OnDeviceWritingPrompts.isTraditionalChinese("zh-Hant"))
        XCTAssertFalse(OnDeviceWritingPrompts.isTraditionalChinese("簡體中文"))
    }

    func testACustomPromptIsTheUsersTaskWithOnlyTheOutputRuleAdded() {
        let prompt = compose(.custom, .formal, custom: "  Turn this into a haiku.  ")
        XCTAssertTrue(prompt.hasPrefix("Turn this into a haiku.\n\n"))
        XCTAssertFalse(prompt.contains("tone"), "a custom prompt takes no tone")
        XCTAssertEqual(compose(.custom, .preserve, custom: "   "), compose(.proofread, .preserve), "empty falls back to proofreading")
    }
}
