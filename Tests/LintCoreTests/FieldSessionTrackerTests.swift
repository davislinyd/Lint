import XCTest
@testable import LintCore

/// The tracker with a clock, fed the way `FieldObserver` feeds it.
private struct Harness {
    var tracker = FieldSessionTracker()
    var now = Date(timeIntervalSince1970: 1_800_000_000)

    mutating func send(_ event: FieldSessionTracker.Event) -> SessionOutcome? {
        tracker.handle(event, at: now)
    }

    /// The field read `times` times, 100 ms apart. Stops at the first outcome.
    mutating func read(_ value: String?, times: Int = 2) -> SessionOutcome? {
        for _ in 0..<times {
            now += 0.1
            if let outcome = tracker.handle(.fieldRead(value), at: now) { return outcome }
        }
        return nil
    }
}

final class FieldSessionTrackerTests: XCTestCase {
    private let chat = ObservedField(app: "com.example.chat", id: 1)
    private let original = "we need discuss about it"
    private let suggested = "we need to discuss it"

    private func suggestion(
        _ original: String? = nil, _ text: String? = nil, prefix: String = "", suffix: String = ""
    ) -> ObservedSuggestion {
        ObservedSuggestion(
            original: original ?? self.original, suggestion: text ?? suggested, tone: .preserve,
            provider: "localLlama", model: "qwen", prefix: prefix, suffix: suffix
        )
    }

    // MARK: how a session went

    func testAReadySuggestionNobodyOpenedIsIgnoredOnceTheFieldIsSent() throws {
        var h = Harness()
        XCTAssertNil(h.send(.suggestionReady(suggestion(), in: chat)))
        XCTAssertTrue(h.tracker.isTracking)
        XCTAssertNil(h.read(original))

        let outcome = try XCTUnwrap(h.read(""))
        XCTAssertEqual(outcome.result, .ignored)
        XCTAssertEqual(outcome.ending, .sent)
        XCTAssertEqual(outcome.app, "com.example.chat")
        XCTAssertEqual(outcome.suggestion, suggestion())
        XCTAssertEqual(outcome.sentText, original)
        XCTAssertFalse(h.tracker.isTracking)
    }

    func testAnOpenedSuggestionThatWasNotUsedIsDismissedAndTheSentTextIsWhatTheFieldHeld() throws {
        var h = Harness()
        _ = h.send(.opened(suggestion(), in: chat))
        XCTAssertNil(h.read("we need discuss about it today"))

        let outcome = try XCTUnwrap(h.read(""))
        XCTAssertEqual(outcome.result, .dismissed)
        XCTAssertEqual(outcome.sentText, "we need discuss about it today")
        XCTAssertNil(outcome.written)
    }

    func testReplaceMakesItAdoptedAndTheSentTextShowsWhatWasEditedAfterwards() throws {
        var h = Harness()
        _ = h.send(.opened(suggestion(), in: chat))
        XCTAssertNil(h.send(.replaced(written: suggested)))
        XCTAssertNil(h.read(suggested))
        XCTAssertNil(h.read("we have to discuss it"))

        let outcome = try XCTUnwrap(h.read(""))
        XCTAssertEqual(outcome.result, .adopted)
        XCTAssertEqual(outcome.written, suggested)
        XCTAssertEqual(outcome.sentText, "we have to discuss it")
    }

    func testASendRightAfterReplaceStillShowsWhatWasWritten() throws {
        var h = Harness()
        _ = h.send(.opened(suggestion(), in: chat))
        _ = h.send(.replaced(written: suggested))

        let outcome = try XCTUnwrap(h.read(""))
        XCTAssertEqual(outcome.sentText, suggested)
    }

    func testCopyingCountsAsAdopted() throws {
        var h = Harness()
        _ = h.send(.opened(suggestion(), in: chat))
        XCTAssertNil(h.send(.copied))

        let outcome = try XCTUnwrap(h.read(""))
        XCTAssertEqual(outcome.result, .adopted)
        XCTAssertNil(outcome.written)
    }

    func testReplaceAndCopyWithoutAnOpenedSuggestionDoNothing() throws {
        var h = Harness()
        XCTAssertNil(h.send(.replaced(written: suggested)), "no field is followed")
        XCTAssertFalse(h.tracker.isTracking)
        _ = h.send(.suggestionReady(suggestion(), in: chat))
        _ = h.send(.replaced(written: suggested))
        _ = h.send(.copied)

        XCTAssertEqual(try XCTUnwrap(h.read("")).result, .ignored)
    }

    func testASessionIsAboutTheSuggestionThatWasUsedThenTheOneLookedAtThenTheOneThatWasReady() throws {
        let second = suggestion(suggested, "we should discuss it")
        var used = Harness()
        _ = used.send(.opened(suggestion(), in: chat))
        _ = used.send(.replaced(written: suggested))
        _ = used.send(.opened(second, in: chat))
        let adopted = try XCTUnwrap(used.read(""))
        XCTAssertEqual(adopted.result, .adopted)
        XCTAssertEqual(adopted.suggestion, suggestion(), "the later one was only looked at")

        var seen = Harness()
        _ = seen.send(.opened(suggestion(), in: chat))
        _ = seen.send(.suggestionReady(second, in: chat))
        let dismissed = try XCTUnwrap(seen.read(""))
        XCTAssertEqual(dismissed.result, .dismissed)
        XCTAssertEqual(dismissed.suggestion, suggestion())

        var waiting = Harness()
        _ = waiting.send(.suggestionReady(suggestion(), in: chat))
        _ = waiting.send(.suggestionReady(second, in: chat))
        let ignored = try XCTUnwrap(waiting.read(""))
        XCTAssertEqual(ignored.result, .ignored)
        XCTAssertEqual(ignored.suggestion, second, "the newest one that was ready")
    }

    func testASuggestionThatChangesNothingIsNotFollowed() throws {
        var h = Harness()
        XCTAssertNil(h.send(.suggestionReady(suggestion(original, " \(original)\n"), in: chat)))
        XCTAssertNil(h.send(.opened(suggestion(original, original), in: chat)))
        XCTAssertFalse(h.tracker.isTracking)

        // What Replace wrote is checked again and left alone: the session stays about the suggestion.
        _ = h.send(.opened(suggestion(), in: chat))
        _ = h.send(.replaced(written: suggested))
        _ = h.send(.opened(suggestion(suggested, suggested), in: chat))
        XCTAssertEqual(try XCTUnwrap(h.read("")).suggestion, suggestion())
    }

    // MARK: reading the field

    func testOneEmptyReadIsNotASend() {
        var h = Harness()
        _ = h.send(.suggestionReady(suggestion(), in: chat))
        XCTAssertNil(h.read(original))
        XCTAssertNil(h.read("", times: 1))
        XCTAssertNil(h.read(original))
        XCTAssertTrue(h.tracker.isTracking)
    }

    func testTheSentTextIsTheLastOneThatWasReadTwice() throws {
        var h = Harness()
        _ = h.send(.opened(suggestion(), in: chat))
        XCTAssertNil(h.read("we need discuss about it now"))
        XCTAssertNil(h.read("we need discuss about it now and th", times: 1))

        XCTAssertEqual(try XCTUnwrap(h.read("")).sentText, "we need discuss about it now")
    }

    func testTheSentTextIsOnlyTheStretchTheSuggestionWasFor() throws {
        let inParagraph = suggestion(prefix: "Hi team,\n", suffix: "\nThanks")
        var h = Harness()
        _ = h.send(.opened(inParagraph, in: chat))
        XCTAssertNil(h.read("Hi team,\nwe need discuss about it now\nThanks"))
        XCTAssertEqual(try XCTUnwrap(h.read("")).sentText, "we need discuss about it now")

        var changed = Harness()
        _ = changed.send(.opened(inParagraph, in: chat))
        XCTAssertNil(changed.read("Hello team,\nwe need discuss about it now\nThanks"))
        let outcome = try XCTUnwrap(changed.read(""))
        XCTAssertEqual(outcome.ending, .sent)
        XCTAssertNil(outcome.sentText, "the text before the stretch changed, so the stretch cannot be told")
    }

    // MARK: how a session ends

    func testASuggestionInAnotherFieldEndsTheSessionAndStartsItsOwn() throws {
        var h = Harness()
        _ = h.send(.suggestionReady(suggestion(), in: chat))
        XCTAssertNil(h.read(original))
        let mail = ObservedField(app: "com.example.mail", id: 2)

        let ended = try XCTUnwrap(h.send(.opened(suggestion(), in: mail)))
        XCTAssertEqual(ended.app, "com.example.chat")
        XCTAssertEqual(ended.result, .ignored)
        XCTAssertEqual(ended.ending, .movedOn)
        XCTAssertNil(ended.sentText)

        let next = try XCTUnwrap(h.read(""))
        XCTAssertEqual(next.app, "com.example.mail")
        XCTAssertEqual(next.result, .dismissed)
    }

    func testAnotherSuggestionInTheSameFieldKeepsTheSession() {
        var h = Harness()
        _ = h.send(.suggestionReady(suggestion(), in: chat))
        XCTAssertNil(h.send(.suggestionReady(suggestion("we need discuss about it today", "we need to discuss it today"), in: chat)))
        XCTAssertTrue(h.tracker.isTracking)
    }

    func testAFieldThatCannotBeReadForTwoSecondsIsGone() throws {
        var h = Harness()
        _ = h.send(.opened(suggestion(), in: chat))
        XCTAssertNil(h.read(original))
        XCTAssertNil(h.read(nil, times: 10), "a second without an answer")
        XCTAssertNil(h.read(original), "it answers again")
        XCTAssertNil(h.read(nil, times: 15))

        let outcome = try XCTUnwrap(h.read(nil, times: 10))
        XCTAssertEqual(outcome.ending, .gone)
        XCTAssertEqual(outcome.result, .dismissed)
        XCTAssertNil(outcome.sentText)
    }

    func testASessionWithNothingNewForTenMinutesEnds() throws {
        var h = Harness()
        _ = h.send(.suggestionReady(suggestion(), in: chat))
        XCTAssertNil(h.read(original))
        h.now += 9 * 60
        XCTAssertNil(h.read("we need discuss about it, and"), "still being written")
        h.now += 9 * 60
        XCTAssertNil(h.read("we need discuss about it, and more"))
        h.now += 10 * 60

        let outcome = try XCTUnwrap(h.read("we need discuss about it, and more", times: 1))
        XCTAssertEqual(outcome.ending, .timedOut)
        XCTAssertEqual(outcome.result, .ignored)
        XCTAssertNil(outcome.sentText)
    }

    func testGivingUpEndsTheSessionAsGone() throws {
        var h = Harness()
        XCTAssertNil(h.tracker.giveUp())
        _ = h.send(.opened(suggestion(), in: chat))
        _ = h.send(.copied)

        let outcome = try XCTUnwrap(h.tracker.giveUp())
        XCTAssertEqual(outcome.ending, .gone)
        XCTAssertEqual(outcome.result, .adopted)
        XCTAssertFalse(h.tracker.isTracking)
    }
}
