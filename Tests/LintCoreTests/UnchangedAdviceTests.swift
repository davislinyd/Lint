import XCTest

@testable import LintCore

/// What the writer is told when the answer is the text itself.
final class UnchangedAdviceTests: XCTestCase {
    private let text = "The meeting room on the fifth floor, the meeting room is already booked."

    func testAnUnchangedPreserveAnswerPointsToTheIdiomaticTone() {
        XCTAssertEqual(UnchangedAdvice.advice(source: text, answer: text, mode: .proofread, tone: .preserve), .tryIdiomatic)
        XCTAssertEqual(
            UnchangedAdvice.advice(source: "  \(text)\n", answer: text, mode: .proofread, tone: .preserve), .tryIdiomatic,
            "the selection's own white space aside"
        )
    }

    func testAnyOtherToneJustSaysNothingNeededChanging() {
        for tone in [WritingTone.idiomatic, .formal, .casual, .concise] {
            XCTAssertEqual(UnchangedAdvice.advice(source: text, answer: text, mode: .proofread, tone: tone), .nothingToChange, "\(tone)")
        }
    }

    func testAChangedAnswerATranslationAndAnEmptyTextGetNoAdvice() {
        XCTAssertNil(UnchangedAdvice.advice(source: text, answer: "The meeting room on the fifth floor is already booked.", mode: .proofread, tone: .preserve))
        XCTAssertNil(UnchangedAdvice.advice(source: text, answer: text, mode: .translate, tone: .preserve))
        XCTAssertNil(UnchangedAdvice.advice(source: text, answer: text, mode: .custom, tone: .preserve))
        XCTAssertNil(UnchangedAdvice.advice(source: "  ", answer: "", mode: .proofread, tone: .preserve))
    }

    func testEachAdviceHasItsOwnMessage() {
        XCTAssertFalse(UnchangedAdvice.tryIdiomatic.message.isEmpty)
        XCTAssertNotEqual(UnchangedAdvice.tryIdiomatic.message, UnchangedAdvice.nothingToChange.message)
    }
}
