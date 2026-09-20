import XCTest
@testable import LintCore

final class MemorySanitizerTests: XCTestCase {
    private func token(
        _ text: String,
        sentenceStart: Bool = false,
        glued: Bool = false,
        name: Bool = false
    ) -> WordToken {
        WordToken(text: text, key: text.lowercased(), isSentenceStart: sentenceStart, isGlued: glued, isName: name)
    }

    func testOrdinaryWordsAreSafe() {
        for word in ["discuss", "about", "don't", "café", "軟體", "well-known"] {
            XCTAssertTrue(MemorySanitizer.isSafe(token(word)), word)
        }
    }

    func testWordsWithDigitsOrSymbolsAreNotSafe() {
        for word in ["5pm", "v2", "a.b", "john@acme", "x/y", "100"] {
            XCTAssertFalse(MemorySanitizer.isSafe(token(word)), word)
        }
    }

    func testGluedAndNameTokensAreNotSafe() {
        XCTAssertFalse(MemorySanitizer.isSafe(token("acme", glued: true)))
        XCTAssertFalse(MemorySanitizer.isSafe(token("sarah", name: true)))
    }

    func testAcronymsAreNotSafeButThePronounIIs() {
        XCTAssertFalse(MemorySanitizer.isSafe(token("API")))
        XCTAssertFalse(MemorySanitizer.isSafe(token("DNS", sentenceStart: true)))
        XCTAssertTrue(MemorySanitizer.isSafe(token("I")))
        XCTAssertTrue(MemorySanitizer.isSafe(token("I'm")))
    }

    func testCapitalisedWordsAreOnlySafeAtTheStartOfASentence() {
        XCTAssertTrue(MemorySanitizer.isSafe(token("Kindly", sentenceStart: true)))
        XCTAssertFalse(MemorySanitizer.isSafe(token("Kindly", sentenceStart: false)))
    }

    func testVeryLongTokensAreNotSafe() {
        XCTAssertFalse(MemorySanitizer.isSafe(token(String(repeating: "a", count: MemorySanitizer.maxTokenLength + 1))))
        XCTAssertTrue(MemorySanitizer.isSafe(token(String(repeating: "a", count: MemorySanitizer.maxTokenLength))))
    }

    func testAListIsSafeOnlyWhenEveryTokenIs() {
        XCTAssertTrue(MemorySanitizer.isSafe([token("discuss"), token("about")]))
        XCTAssertFalse(MemorySanitizer.isSafe([token("discuss"), token("2026")]))
        XCTAssertTrue(MemorySanitizer.isSafe([WordToken]()))
    }
}
