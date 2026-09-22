import XCTest
@testable import LintCore

final class WritingRequestKeyTests: XCTestCase {
    private func key(
        _ source: String = "some text",
        _ mode: WritingMode = .proofread,
        _ tone: WritingTone = .preserve,
        target: String = "繁體中文",
        custom: String = ""
    ) -> WritingRequestKey {
        WritingRequestKey(source: source, mode: mode, tone: tone, translateTarget: target, customPrompt: custom)
    }

    func testTheSameRequestHasTheSameKey() {
        XCTAssertEqual(key(), key())
        XCTAssertEqual(key("t", .translate, .formal, target: "日文"), key("t", .translate, .formal, target: "日文"))
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

    func testAnotherTranslationTargetIsAnotherTranslation() {
        XCTAssertNotEqual(key("t", .translate, target: "日文"), key("t", .translate, target: "English"))
        XCTAssertEqual(
            key("t", .translate, target: "日文"), key("t", .translate, target: "  日文\n"),
            "surrounding whitespace is not another language"
        )
    }

    func testTheTranslationTargetOnlyMattersToTranslation() {
        XCTAssertEqual(key("t", .proofread, target: "日文"), key("t", .proofread, target: "English"))
        XCTAssertEqual(key("t", .custom, target: "日文"), key("t", .custom, target: "English"))
    }

    func testACustomPromptHasNoTone() {
        XCTAssertEqual(key("t", .custom, .preserve, custom: "詩"), key("t", .custom, .formal, custom: "詩"))
    }

    func testTheCustomPromptOnlyMattersToACustomPrompt() {
        XCTAssertNotEqual(key("t", .custom, custom: "詩"), key("t", .custom, custom: "散文"))
        XCTAssertEqual(key("t", .proofread, custom: "詩"), key("t", .proofread, custom: "散文"))
        XCTAssertEqual(key("t", .translate, custom: "詩"), key("t", .translate, custom: "散文"))
    }
}
