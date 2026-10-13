import XCTest
@testable import LintCore

final class ObservationModelsTests: XCTestCase {
    private func suggestion(_ original: String, prefix: String = "", suffix: String = "") -> ObservedSuggestion {
        ObservedSuggestion(
            original: original, suggestion: "changed", tone: .preserve, provider: "localLlama", model: "qwen",
            prefix: prefix, suffix: suffix
        )
    }

    // MARK: where the text sits in the field

    func testTheTextIsFoundAtTheRangeItWasCapturedAt() throws {
        let value = "see you soon\nsee you soon"
        let located = try XCTUnwrap(suggestion("see you soon").located(in: value, utf16Range: 13..<25))
        XCTAssertEqual(located.prefix, "see you soon\n")
        XCTAssertEqual(located.suffix, "")
    }

    func testTheRangeCountsUTF16LikeAccessibilityDoes() throws {
        let value = "👍 ok\nsee you soon\nbye"
        let located = try XCTUnwrap(suggestion("see you soon").located(in: value, utf16Range: 6..<18))
        XCTAssertEqual(located.prefix, "👍 ok\n")
        XCTAssertEqual(located.suffix, "\nbye")
    }

    func testWithoutAUsableRangeTheOnlyOccurrenceIsTaken() throws {
        let value = "Hi,\nsee you soon\nbye"
        for range in [nil, 0..<5, 4..<400, -3..<2] as [Range<Int>?] {
            let located = try XCTUnwrap(suggestion("see you soon").located(in: value, utf16Range: range))
            XCTAssertEqual(located.prefix, "Hi,\n")
            XCTAssertEqual(located.suffix, "\nbye")
        }
    }

    func testATextThatIsThereTwiceOrNotAtAllIsNotLocated() {
        XCTAssertNil(suggestion("see you soon").located(in: "see you soon\nsee you soon", utf16Range: nil))
        XCTAssertNil(suggestion("see you soon").located(in: "see you later", utf16Range: 0..<12))
        XCTAssertNil(suggestion("see you soon").located(in: "", utf16Range: nil))
    }

    func testTheStretchIsWhatSitsBetweenTheSurroundingsAndWhitespaceAroundTheFieldDoesNotCount() {
        let inside = suggestion("old", prefix: "  Hi,\n", suffix: "\nbye \n")
        XCTAssertEqual(inside.stretch(of: "Hi,\n new text \nbye"), "new text")
        XCTAssertEqual(inside.stretch(of: "  Hi,\n\nbye \n"), "")
        XCTAssertNil(inside.stretch(of: "Hey,\nnew text\nbye"))
        XCTAssertNil(inside.stretch(of: "Hi,\nnew text\nbye now"))
        XCTAssertNil(inside.stretch(of: "Hi,"), "shorter than what was around it")

        let whole = suggestion("old", prefix: " ", suffix: "\n")
        XCTAssertEqual(whole.stretch(of: "new text"), "new text")
    }

    func testASuggestionChangesNothingWhenOnlyTheWhitespaceAroundItDiffers() {
        var same = suggestion("see you soon")
        same.suggestion = "\nsee you soon "
        XCTAssertTrue(same.changesNothing)
        same.suggestion = "See you soon"
        XCTAssertFalse(same.changesNothing)
    }

    func testASuggestionKnowsWhetherItsTextBeginsAndEndsWithALine() {
        for (prefix, starts) in [("", true), ("Hi,\n", true), ("Hi,\n \t", true), ("Hi, ", false), ("Hi", false)] {
            XCTAssertEqual(suggestion("see you soon", prefix: prefix).startsLine, starts, prefix.debugDescription)
        }
        for (suffix, ends) in [("", true), ("\nbye", true), (" \nbye", true), (" bye", false), ("!", false)] {
            XCTAssertEqual(suggestion("see you soon", suffix: suffix).endsLine, ends, suffix.debugDescription)
        }
    }

    // MARK: fading counts

    func testACounterHalvesEveryThirtyDays() {
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let counter = DecayedCounter(positive: 8, negative: 2, updatedAt: start)

        let later = counter.faded(to: start.addingTimeInterval(60 * 86_400))
        XCTAssertEqual(later.positive, 2, accuracy: 1e-9)
        XCTAssertEqual(later.negative, 0.5, accuracy: 1e-9)
        XCTAssertEqual(later.total, 2.5, accuracy: 1e-9)
        XCTAssertEqual(later.updatedAt, start.addingTimeInterval(60 * 86_400))
    }

    func testACounterDoesNotGrowWhenTheClockGoesBack() {
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let counter = DecayedCounter(positive: 8, negative: 2, updatedAt: start)
        XCTAssertEqual(counter.faded(to: start.addingTimeInterval(-86_400)), counter)
    }
}
