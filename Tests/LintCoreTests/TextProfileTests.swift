import XCTest
@testable import LintCore

final class TextProfileTests: XCTestCase {
    func testCountsLettersAndCJKCharacters() {
        let english = TextProfile("We should discuss this tomorrow.")
        XCTAssertEqual(english.latinLetters, 27)
        XCTAssertEqual(english.cjkCharacters, 0)

        let mixed = TextProfile("請幫我 check 這個 issue")
        XCTAssertEqual(mixed.latinLetters, 10)
        XCTAssertEqual(mixed.cjkCharacters, 5)
    }

    func testChineseVariantIsToldApart() {
        XCTAssertEqual(TextProfile("這個軟體需要更新才能使用新功能").chineseVariant, "zh-Hant")
        XCTAssertEqual(TextProfile("这个软件需要更新才能使用新功能").chineseVariant, "zh-Hans")
        XCTAssertNil(TextProfile("We should wait.").chineseVariant)
    }

    func testMentioningNeedsOnlyASingleCharacterOfTheScript() {
        let mixed = TextProfile("sync with 小明 later")
        XCTAssertTrue(mixed.mentions("en"))
        XCTAssertTrue(mixed.mentions("zh-Hant"))
        XCTAssertFalse(TextProfile("Only English here").mentions("zh-Hant"))
        XCTAssertFalse(TextProfile("只有中文在這裡").mentions("en"))
        XCTAssertFalse(mixed.mentions("fr"))
    }

    func testDominatingNeedsEnoughOfTheLanguage() {
        XCTAssertTrue(TextProfile("I have meeting tomorrow").dominates("en"))
        XCTAssertFalse(TextProfile("hi there").dominates("en"), "too short to say anything about the writer")
        XCTAssertFalse(TextProfile("明天下午三點在會議室討論預算 ok thanks").dominates("en"))
        XCTAssertTrue(TextProfile("明天下午三點在會議室討論預算").dominates("zh-Hant"))
        XCTAssertFalse(TextProfile("这个软件需要更新才能使用新功能").dominates("zh-Hant"), "the variant must match")
        XCTAssertFalse(TextProfile("我覺得 this is a long english sentence with a few words").dominates("zh-Hant"))
    }

    func testATranslationTargetBecomesALanguageTag() {
        XCTAssertEqual(TextProfile.languageTag(forTarget: "繁體中文"), "zh-Hant")
        XCTAssertEqual(TextProfile.languageTag(forTarget: "中文"), "zh-Hant")
        XCTAssertEqual(TextProfile.languageTag(forTarget: "  "), "zh-Hant", "empty is the translation prompt's default")
        XCTAssertEqual(TextProfile.languageTag(forTarget: "Traditional Chinese"), "zh-Hant")
        XCTAssertEqual(TextProfile.languageTag(forTarget: "簡體中文"), "zh-Hans")
        XCTAssertEqual(TextProfile.languageTag(forTarget: "Simplified Chinese"), "zh-Hans")
        XCTAssertEqual(TextProfile.languageTag(forTarget: "English"), "en")
        XCTAssertEqual(TextProfile.languageTag(forTarget: "英文"), "en")
        XCTAssertEqual(TextProfile.languageTag(forTarget: "日文"), "other")
        XCTAssertEqual(TextProfile.languageTag(forTarget: "French"), "other")
    }

    func testJapaneseIsNotTakenForChinese() {
        let japanese = TextProfile("これはテストです。明日また話しましょう")
        XCTAssertFalse(japanese.dominates("zh-Hant"))
        XCTAssertFalse(japanese.dominates("zh-Hans"))
    }
}
