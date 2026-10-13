import XCTest
@testable import LintCore

final class SuggestionReviewTests: XCTestCase {
    private let original = "From my prospective we need a big house near the office"
    private let suggestion = "From my perspective we need a large house near the office"

    /// The words each change removed and added, with its verdict.
    private func review(
        _ sent: String, original: String? = nil, suggestion: String? = nil
    ) -> [String: SuggestionReview.Verdict] {
        let changes = SuggestionReview.changes(
            original: original ?? self.original, suggestion: suggestion ?? self.suggestion, sent: sent
        )
        return Dictionary(uniqueKeysWithValues: changes.map { change in
            ("\(change.span.removed.map(\.key).joined(separator: " "))>\(change.span.added.map(\.key).joined(separator: " "))", change.verdict)
        })
    }

    func testEveryChangeIsRejectedWhenTheOriginalWasSent() {
        XCTAssertEqual(review(original), ["prospective>perspective": .rejected, "big>large": .rejected])
        XCTAssertEqual(review("  \(original)\n"), ["prospective>perspective": .rejected, "big>large": .rejected])
    }

    func testEveryChangeIsKeptWhenTheSuggestionWasSent() {
        XCTAssertEqual(review(suggestion), ["prospective>perspective": .kept, "big>large": .kept])
    }

    func testEachChangeIsJudgedByItsOwnPlace() {
        XCTAssertEqual(
            review("From my perspective we need a big house near the office"),
            ["prospective>perspective": .kept, "big>large": .rejected]
        )
        XCTAssertEqual(
            review("From my prospective we need a huge house near the office"),
            ["prospective>perspective": .rejected, "big>large": .unclear],
            "another word stands there now"
        )
    }

    func testAnEditRightNextToAChangeLeavesItUnclear() {
        XCTAssertEqual(
            review("From my prospective we need a big home near the office"),
            ["prospective>perspective": .rejected, "big>large": .unclear]
        )
        XCTAssertEqual(
            review("From my prospective we need a big house next to the office"),
            ["prospective>perspective": .rejected, "big>large": .rejected],
            "two words away is another place"
        )
    }

    func testAChangeAtTheEndIsOnlyRejectedWhenTheEndIsAsItWas() {
        let source = "we will discuss the plan in the big offce"
        let fixed = "we will discuss the plan in the big office"
        XCTAssertEqual(review(source, original: source, suggestion: fixed), ["offce>office": .rejected])
        XCTAssertEqual(
            review("we will discuss the plan in the big off", original: source, suggestion: fixed),
            ["offce>office": .unclear], "the last word was not read to its end"
        )
        XCTAssertEqual(
            review("we will discuss the plan in the big offce tomorrow morning", original: source, suggestion: fixed),
            ["offce>office": .unclear], "more was typed after it"
        )
    }

    func testAnAddedWordIsJudgedToo() {
        let source = "we need discuss the plan today"
        let fixed = "we need to discuss the plan today"
        XCTAssertEqual(review(source, original: source, suggestion: fixed), [">to": .rejected])
        XCTAssertEqual(review(fixed, original: source, suggestion: fixed), [">to": .kept])
        XCTAssertEqual(review("we need really discuss the plan today", original: source, suggestion: fixed), [">to": .unclear])
    }

    func testThereIsNothingToJudgeWithoutAChangeOrWithoutTheOriginal() {
        XCTAssertTrue(review(original, suggestion: original).isEmpty, "the suggestion changed nothing")
        XCTAssertTrue(
            review(original, suggestion: "In my view, a larger home close to work would suit us better").isEmpty,
            "the suggestion rewrote the text"
        )
        XCTAssertTrue(
            review("Never mind, I will call you about the whole thing later tonight").isEmpty,
            "something else was sent"
        )
        XCTAssertTrue(review("").isEmpty)
    }

    func testATextTooDifferentToCompareIsNotTakenForTheOriginal() {
        // Past `DiffAnalyzer.maxMiddleTokens` differing words the diff gives up and reports none.
        let words = (0..<1_300).map { "word\($0)" }
        let long = words.joined(separator: " ")
        let fixed = (words.prefix(650) + ["changed"] + words.dropFirst(651)).joined(separator: " ")
        XCTAssertEqual(review(long, original: long, suggestion: fixed), ["word650>changed": .rejected])
        let other = (0..<1_300).map { "other\($0)" }.joined(separator: " ")
        XCTAssertTrue(review(other, original: long, suggestion: fixed).isEmpty)
    }
}
