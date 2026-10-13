import XCTest
@testable import LintCore

final class StyleTraitsTests: XCTestCase {
    private func seen(
        _ original: String, _ suggestion: String, _ sent: String, startsLine: Bool = true, endsLine: Bool = true
    ) -> [StyleTrait: Bool] {
        StyleTraits.observations(
            original: original, suggestion: suggestion, sent: sent, startsLine: startsLine, endsLine: endsLine
        )
    }

    // MARK: contractions

    func testAContractionTheSuggestionSpelledOutCountsForTheWayItWasSent() {
        let original = "I don't think we need it today."
        let suggestion = "I do not think we need it today."
        XCTAssertEqual(seen(original, suggestion, original), [.keepContractions: true])
        XCTAssertEqual(seen(original, suggestion, suggestion), [.keepContractions: false])
        XCTAssertEqual(seen(original, suggestion, "I really think we need it today."), [:], "neither of the two")
    }

    func testAFullFormTheSuggestionContractedCountsTheSameWay() {
        let original = "We do not have the budget for it."
        let suggestion = "We don't have the budget for it."
        XCTAssertEqual(seen(original, suggestion, original), [.keepFullForms: true])
        XCTAssertEqual(seen(original, suggestion, suggestion), [.keepFullForms: false])
    }

    func testSeveralContractionsCountOnceAndOnlyWhenTheyAgree() {
        let original = "I don't know and we can't go there."
        let suggestion = "I do not know and we cannot go there."
        XCTAssertEqual(seen(original, suggestion, original), [.keepContractions: true])
        XCTAssertEqual(seen(original, suggestion, "I do not know and we can't go there."), [:], "one each way")
    }

    func testAContractionWithTwoReadingsAndOtherChangesAreLeftOut() {
        XCTAssertEqual(seen("It's been a long day for us.", "It has been a long day for us.", "It's been a long day for us."), [:])
        XCTAssertEqual(seen("I'd like more time for it.", "I would like more time for it.", "I'd like more time for it."), [:])
        XCTAssertEqual(seen("We need a big house.", "We need a large house.", "We need a big house."), [:])
    }

    // MARK: the ends of a message

    private let casual = "see you at the office tomorrow"
    private let tidied = "See you at the office tomorrow."

    func testAPeriodAndACapitalTheSuggestionAddedCountForTheWayTheMessageWasSent() {
        XCTAssertEqual(seen(casual, tidied, casual), [.noTerminalPeriod: true, .keepLowercaseStart: true])
        XCTAssertEqual(seen(casual, tidied, tidied), [.noTerminalPeriod: false, .keepLowercaseStart: false])
        XCTAssertEqual(
            seen(casual, tidied, "see you at the office tomorrow."), [.noTerminalPeriod: false, .keepLowercaseStart: true]
        )
        XCTAssertEqual(
            seen(casual, tidied, "See you at the office tomorrow"), [.noTerminalPeriod: true, .keepLowercaseStart: false]
        )
    }

    func testAnEndIsOnlyJudgedWhileItsWordIsStillThere() {
        XCTAssertEqual(seen(casual, tidied, "see you at the office tomorro"), [.keepLowercaseStart: true], "not read to its end")
        XCTAssertEqual(
            seen(casual, tidied, "see you at the office tomorrow and bring the laptop"), [.keepLowercaseStart: true],
            "more was typed after it"
        )
        XCTAssertEqual(seen(casual, tidied, "see you at the office tomorrow!"), [.keepLowercaseStart: true])
        XCTAssertEqual(seen(casual, tidied, "ok see you at the office tomorrow"), [.noTerminalPeriod: true])
    }

    func testNothingCountsWhereTheSuggestionLeftTheTextAlone() {
        XCTAssertEqual(seen("see you tomorrow.", "See you tomorrow.", "see you tomorrow."), [.keepLowercaseStart: true])
        XCTAssertEqual(seen("See you tomorrow", "See you tomorrow.", "See you tomorrow"), [.noTerminalPeriod: true])
        XCTAssertEqual(seen("See you tomorrow.", "See you tomorrow.", "see you tomorrow"), [:], "the model changed nothing")
        XCTAssertEqual(seen("see you tomorrow", "See you tomorrow?", "see you tomorrow"), [.keepLowercaseStart: true])
        XCTAssertEqual(seen("see you tomorrow", "Until the morning.", "see you tomorrow"), [:], "other words at both ends")
        XCTAssertEqual(seen("明天見", "明天見。", "明天見"), [:])
        XCTAssertEqual(seen("", tidied, casual), [:])
    }

    func testATextPickedOutOfALineHasNoStartOrEndToJudge() {
        XCTAssertEqual(seen(casual, tidied, casual, startsLine: false), [.noTerminalPeriod: true])
        XCTAssertEqual(seen(casual, tidied, casual, endsLine: false), [.keepLowercaseStart: true])
    }

    func testOnlyTheTonesThatKeepTheWritersVoiceAreObserved() {
        for tone in WritingTone.allCases {
            XCTAssertEqual(StyleTraits.isObserved(tone), tone == .preserve || tone == .idiomatic, "\(tone)")
            XCTAssertEqual(StyleTraits.isObserved(tone), tone.correctsOnly, "\(tone): the tones memory learns corrections from")
        }
    }

    // MARK: when a trait holds

    private func counter(_ positive: Double, _ negative: Double) -> DecayedCounter {
        DecayedCounter(positive: positive, negative: negative, updatedAt: Date(timeIntervalSince1970: 1_800_000_000))
    }

    func testATraitIsTakenUpOnceItWasSeenOftenEnoughAndKeptMostOfTheTime() {
        XCTAssertTrue(ObservationAdjuster.holds(counter(8, 0), held: false))
        XCTAssertTrue(ObservationAdjuster.holds(counter(8, 2), held: false))
        XCTAssertTrue(ObservationAdjuster.holds(counter(7.999, 0), held: false), "eight today, faded by a few hours")
        XCTAssertFalse(ObservationAdjuster.holds(counter(7.4, 0), held: false), "not seen often enough")
        XCTAssertFalse(ObservationAdjuster.holds(counter(7.9, 2.1), held: false), "kept too little of the time")
        XCTAssertFalse(ObservationAdjuster.holds(counter(0, 0), held: false))
    }

    func testAnAppGoesQuietWhenManySuggestionsThereWereNeverUsed() {
        XCTAssertTrue(ObservationAdjuster.isQuiet(counter(0, 30)))
        XCTAssertTrue(ObservationAdjuster.isQuiet(counter(0.9, 29.6)), "thirty today, a few hours ago; one used long ago")
        XCTAssertFalse(ObservationAdjuster.isQuiet(counter(0, 29.4)), "not often enough")
        XCTAssertFalse(ObservationAdjuster.isQuiet(counter(1, 80)), "one was used")
        XCTAssertFalse(ObservationAdjuster.isQuiet(counter(0, 0)))
    }

    func testTheToneUsedInAnAppMostOfTheTimeIsItsOwn() {
        XCTAssertEqual(ObservationAdjuster.tone(from: [.formal: 3]), .formal)
        XCTAssertEqual(ObservationAdjuster.tone(from: [.formal: 2.6]), .formal, "three, faded a little")
        XCTAssertEqual(ObservationAdjuster.tone(from: [.formal: 8, .casual: 2]), .formal)
        XCTAssertNil(ObservationAdjuster.tone(from: [.formal: 2.4]), "not used often enough")
        XCTAssertNil(ObservationAdjuster.tone(from: [.formal: 7, .casual: 3]), "not most of the time")
        XCTAssertNil(ObservationAdjuster.tone(from: [.formal: 4, .casual: 4]))
        XCTAssertNil(ObservationAdjuster.tone(from: [:]))
        XCTAssertNil(ObservationAdjuster.tone(from: [.formal: 0]))
    }

    func testATraitThatHoldsIsOnlyDroppedWellBelowTheBar() {
        XCTAssertTrue(ObservationAdjuster.holds(counter(7, 3), held: true), "between the two bars it stays")
        XCTAssertTrue(ObservationAdjuster.holds(counter(6, 4), held: true))
        XCTAssertFalse(ObservationAdjuster.holds(counter(5.9, 4.1), held: true))
        XCTAssertTrue(ObservationAdjuster.holds(counter(0.4, 0.1), held: true), "what has faded still stands until it is contradicted")
        XCTAssertFalse(ObservationAdjuster.holds(counter(0, 0), held: true))
    }
}
