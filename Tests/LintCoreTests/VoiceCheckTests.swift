import XCTest

@testable import LintCore

/// What an edit that keeps the writer's voice must leave alone.
final class VoiceCheckTests: XCTestCase {
    func testANaturalFixThatKeepsTheVoicePasses() {
        XCTAssertEqual(VoiceCheck.changes(
            from: "lol sorry, I forgot to open the VPN before the call, that's why I dropped.",
            to: "lol sorry, I forgot to turn on the VPN before the call, that's why I dropped."
        ), [])
        XCTAssertEqual(VoiceCheck.changes(
            from: "This tool is really not convenient! Every time I must fill the same form again. Who designed this?",
            to: "This tool is such a pain! I have to fill out the same form every single time. Who designed this?"
        ), [])
        XCTAssertEqual(VoiceCheck.changes(from: "Same text.", to: "Same text."), [])
    }

    func testSentenceTypesAndEmojiAreKept() {
        XCTAssertEqual(VoiceCheck.changes(from: "Please reply me as soon as possible.", to: "Could you reply as soon as possible?"), [.addedQuestion])
        XCTAssertEqual(VoiceCheck.changes(from: "Who designed this?", to: "Someone designed this badly."), [.lostQuestion])
        XCTAssertEqual(VoiceCheck.changes(from: "Everyone is welcome!", to: "Everyone is welcome."), [.lostExclamation])
        XCTAssertEqual(VoiceCheck.changes(from: "You saved me 🙏", to: "You saved me."), [.lostEmoji])
        XCTAssertEqual(VoiceCheck.changes(from: "Thanks, see you", to: "Thanks, see you 😊"), [.addedEmoji])
        XCTAssertEqual(VoiceCheck.changes(from: "Step 1 is done", to: "Step 1 is done"), [], "a digit is not an emoji")
    }

    func testContractionsFollowTheWriter() {
        XCTAssertEqual(
            VoiceCheck.changes(from: "I'm late, don't wait for me.", to: "I am late, do not wait for me."), [.lostContractions]
        )
        XCTAssertEqual(
            VoiceCheck.changes(from: "I will send it to you before 5 pm.", to: "I'll send it to you before 5 pm."), [.addedContractions]
        )
        XCTAssertEqual(
            VoiceCheck.changes(from: "Send the file by tomorrow.", to: "I'll send the file by tomorrow."), [],
            "a text with neither has no style to keep"
        )
        XCTAssertEqual(VoiceCheck.contractions(in: "It's John's car, and I'd say we're late."), ["It's", "I'd", "we're"])
    }

    func testHedgesAreNeitherDroppedNorAdded() {
        XCTAssertEqual(
            VoiceCheck.changes(from: "I think maybe we can postpone the launch.", to: "We should postpone the launch."), [.lostHedge]
        )
        XCTAssertEqual(
            VoiceCheck.changes(from: "We cannot accept this request.", to: "We might not be able to accept this request."),
            [.addedHedge]
        )
    }

    func testStockPhrasesTheWriterDidNotUseAreCaught() {
        XCTAssertEqual(
            VoiceCheck.changes(from: "Did you get the invoice?", to: "Dear team, did you get the invoice?"), [.addedStockPhrase("dear")]
        )
        XCTAssertEqual(
            VoiceCheck.changes(from: "Kindly revert back to me.", to: "Kindly get back to me."), [], "the writer's own formula stays"
        )
    }

    func testTheWritersInformalWordsAreKept() {
        XCTAssertEqual(
            VoiceCheck.changes(from: "hey, do you have time now? I wanna discuss with you about the release plan", to: "Hey, do you have time now? I want to talk about the release plan."),
            [.lostInformal(["wanna"])], "a capital H keeps the word"
        )
        XCTAssertEqual(VoiceCheck.changes(from: "lol ok", to: "Haha, okay"), [.lostInformal(["lol", "ok"])])
        XCTAssertEqual(VoiceCheck.changes(from: "Okay, the token expired.", to: "OK, the token expired."), [.lostInformal(["okay"])])
        XCTAssertEqual(VoiceCheck.changes(from: "Thank you.", to: "Thanks, haha."), [], "only what the writer had is held to")
    }

    func testLengthIsComparedForEnglishOnly() {
        let source = "The deployment has been finished and the service is running normally now."
        XCTAssertEqual(VoiceCheck.changes(from: source, to: "Deployed."), [.shorter(ratio: 2.0 / 13.0)])
        let longer = VoiceCheck.changes(from: source, to: source + " Everything looks healthy, the dashboards are green and there have been no errors since.")
        XCTAssertTrue(longer.contains { if case .longer = $0 { true } else { false } }, "\(longer)")
        XCTAssertEqual(
            VoiceCheck.changes(from: "抱歉，這個需求我們這季排不進去，下季再評估看看。", to: "Sorry, we can't fit this in this quarter. We'll look at it again next quarter."),
            [], "a Chinese text has no length, contractions or hedges to compare"
        )
        XCTAssertEqual(
            VoiceCheck.changes(from: "這個流程到底是誰設計的？", to: "Who designed this process."), [.lostQuestion],
            "full-width punctuation counts"
        )
    }
}
