import XCTest
@testable import LintCore

final class WritingRequestKeyTests: XCTestCase {
    private func key(
        _ source: String = "some text",
        _ mode: WritingMode = .proofread,
        _ tone: WritingTone = .preserve,
        custom: String = ""
    ) -> WritingRequestKey {
        WritingRequestKey(source: source, mode: mode, tone: tone, customPrompt: custom)
    }

    func testTheSameRequestHasTheSameKey() {
        XCTAssertEqual(key(), key())
        XCTAssertEqual(key("t", .translate, .formal), key("t", .translate, .formal))
    }

    func testAPrefetchMadeForPreserveIsNotTheOneForProfessional() {
        XCTAssertNotEqual(key("t", .proofread, .preserve), key("t", .proofread, .professional))
        for tone in WritingTone.allCases {
            for other in WritingTone.allCases where other != tone {
                XCTAssertNotEqual(key("t", .proofread, tone), key("t", .proofread, other), "\(tone) \(other)")
                XCTAssertNotEqual(key("t", .translate, tone), key("t", .translate, other), "\(tone) \(other)")
            }
        }
    }

    func testAnotherModeIsAnotherRequest() {
        XCTAssertNotEqual(key("t", .proofread), key("t", .translate))
        XCTAssertNotEqual(key("t", .proofread), key("t", .custom))
        XCTAssertNotEqual(key("t", .translate), key("t", .custom))
    }

    func testAnotherTextIsAnotherRequest() {
        XCTAssertNotEqual(key("one"), key("two"))
    }

    func testACustomPromptHasNoTone() {
        XCTAssertEqual(key("t", .custom, .preserve, custom: "詩"), key("t", .custom, .formal, custom: "詩"))
    }

    func testTheCustomPromptOnlyMattersToACustomPrompt() {
        XCTAssertNotEqual(key("t", .custom, custom: "詩"), key("t", .custom, custom: "散文"))
        XCTAssertEqual(key("t", .proofread, custom: "詩"), key("t", .proofread, custom: "散文"))
        XCTAssertEqual(key("t", .translate, custom: "詩"), key("t", .translate, custom: "散文"))
    }

    func testTheTranslationLanguageOnlyMattersToATranslation() {
        func key(_ mode: WritingMode, _ language: TranslationLanguage) -> WritingRequestKey {
            WritingRequestKey(source: "t", mode: mode, tone: .preserve, customPrompt: "", translationLanguage: language)
        }
        XCTAssertNotEqual(key(.translate, .japanese), key(.translate, .traditionalChinese))
        XCTAssertEqual(key(.translate, .traditionalChinese), self.key("t", .translate), "Traditional Chinese is the default")
        XCTAssertEqual(key(.proofread, .japanese), key(.proofread, .thai))
        XCTAssertEqual(key(.custom, .japanese), key(.custom, .thai))
    }
}
