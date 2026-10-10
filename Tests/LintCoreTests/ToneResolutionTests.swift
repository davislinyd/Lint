import XCTest

@testable import LintCore

/// Which tone a request is written in, from the menu tone, its text and the mixed-text setting.
final class ToneResolutionTests: XCTestCase {
    private let english = "Could you take a look at the PR when you get a chance?"
    private let chinese = "這週我比較忙，下週再約可以嗎？"
    private let mixed = "昨天 deploy 完 API 一直 timeout，我先 rollback 了"

    private func tone(_ menu: WritingTone, _ text: String, _ mixed: MixedTextHandling = .toEnglish, mode: WritingMode = .proofread) -> WritingTone {
        menu.effective(for: text, mode: mode, mixed: mixed)
    }

    func testEnglishTextIsEditedInTheMenuTone() {
        for menu in WritingMode.proofread.tones {
            for handling in MixedTextHandling.allCases {
                XCTAssertEqual(tone(menu, english, handling), menu, "\(menu) \(handling)")
            }
        }
    }

    func testChineseTextIsWrittenInEnglishWhateverTheSetting() {
        let expected: [WritingTone: WritingTone] = [
            .idiomatic: .native, .formal: .nativeFormal, .casual: .nativeCasual, .concise: .nativeConcise,
        ]
        for (menu, written) in expected {
            for handling in MixedTextHandling.allCases {
                XCTAssertEqual(tone(menu, chinese, handling), written, "\(menu) \(handling)")
            }
        }
    }

    func testMixedTextFollowsTheSetting() {
        XCTAssertEqual(tone(.idiomatic, mixed, .toEnglish), .native)
        XCTAssertEqual(tone(.idiomatic, mixed, .keepChinese), .idiomatic)
        XCTAssertEqual(tone(.formal, mixed, .toEnglish), .nativeFormal)
        XCTAssertEqual(tone(.casual, mixed, .keepChinese), .casual)
        XCTAssertEqual(tone(.concise, mixed, .toEnglish), .nativeConcise)
    }

    func testPreserveIsAlwaysAnEditOfTheEnglish() {
        for text in [english, chinese, mixed] {
            for handling in MixedTextHandling.allCases {
                XCTAssertEqual(tone(.preserve, text, handling), .preserve)
            }
        }
    }

    func testATranslationAndACustomPromptTakeTheMenuToneAsItIs() {
        for menu in WritingMode.translate.tones {
            XCTAssertEqual(tone(menu, chinese, mode: .translate), menu, "\(menu)")
        }
        XCTAssertEqual(tone(.idiomatic, chinese, mode: .custom), .idiomatic)
    }

    func testAToneOfAnEarlierVersionIsReadAsItsMenuTone() {
        XCTAssertEqual(tone(.professional, english), .formal)
        XCTAssertEqual(tone(.nativeGenZ, english), .casual)
        XCTAssertEqual(tone(.nativeGenZ, chinese), .nativeCasual)
        XCTAssertEqual(tone(.native, english), .idiomatic)
    }

    func testChineseInAURLIsNotChineseText() {
        XCTAssertEqual(tone(.idiomatic, "See https://zh.wikipedia.org/wiki/台北 for the details."), .idiomatic)
    }
}
