import XCTest
@testable import LintCore

final class ChangedWordsTests: XCTestCase {
    func testASmartApostropheTypedInThePanelIsNotAChange() {
        XCTAssertEqual(ChangedWords.inserted(original: "that’s what i thought.", result: "that's what I thought."), [2])
        XCTAssertEqual(ChangedWords.inserted(original: "that's what i thought.", result: "that’s what I thought."), [2])
    }

    func testSmartDoubleQuotesAreNotAChange() {
        XCTAssertEqual(ChangedWords.inserted(original: "she said “hi”", result: "she said \"hi\""), [])
    }

    func testCapitalisationAndNewWordsAreChanges() {
        XCTAssertEqual(ChangedWords.inserted(original: "i think so", result: "I think so"), [0])
        XCTAssertEqual(ChangedWords.inserted(original: "this is pen", result: "this is a pen"), [2])
    }

    func testTheSameTextHasNoChanges() {
        XCTAssertEqual(ChangedWords.inserted(original: "this is a pen.", result: "this is a pen."), [])
    }
}
