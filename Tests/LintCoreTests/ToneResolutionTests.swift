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

    func testAnotherLanguageIsWrittenInEnglishWhateverTheSetting() {
        let texts = [
            "내일 회의를 오후 3시로 옮겨도 될까요?",
            "ขอโทษที่ตอบช้านะ เมื่อวานยุ่งมาก",
            "すみません、あしたでもいいですか。",
            "Xin lỗi vì trả lời muộn, mai mình nói chuyện được không?",
            "Maaf baru balas, kemarin saya sibuk sekali.",
            "Perdón por la demora, ayer estuve muy ocupado.",
            "감사합니다",
            "내일 PR review 해주세요",
        ]
        let expected: [WritingTone: WritingTone] = [
            .idiomatic: .native, .formal: .nativeFormal, .casual: .nativeCasual, .concise: .nativeConcise,
        ]
        for text in texts {
            for (menu, written) in expected {
                for handling in MixedTextHandling.allCases {
                    XCTAssertEqual(tone(menu, text, handling), written, "\(text) \(menu) \(handling)")
                }
            }
            XCTAssertEqual(tone(.preserve, text), .preserve, text)
        }
    }

    func testEnglishWithAWordOfAnotherLanguageStaysEnglish() {
        for text in [
            "The invoice in 청구서_0412.pdf, the invoice has two amounts is different, is it?",
            "Merci for the help, see you tomorrow",
            "Hi Alice, can u send me the file asap",
            "np",
            "Danke",
        ] {
            XCTAssertEqual(tone(.idiomatic, text), .idiomatic, text)
        }
    }
}
