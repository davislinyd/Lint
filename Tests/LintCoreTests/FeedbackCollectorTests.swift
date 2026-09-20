import CryptoKit
import XCTest
@testable import LintCore

final class FeedbackCollectorTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_700_000_000)
    private let suggestion = "I think we need to discuss this issue."

    private func collector(keyByte: UInt8 = 1) -> FeedbackCollector {
        FeedbackCollector(key: SymmetricKey(data: Data(repeating: keyByte, count: 32)))
    }

    private func feedback(
        _ gesture: UserGesture = .replaced,
        original: String = "I think we need discuss about this issue.",
        generated: String? = "I think we need to discuss this issue.",
        final: String = "I think we need to discuss this issue.",
        mode: WritingMode = .proofread
    ) -> LearningFeedback {
        LearningFeedback(
            gesture: gesture, mode: mode, originalText: original, generatedText: generated,
            finalText: final, provider: "localLlama", model: "qwen"
        )
    }

    func testReplacingTheSuggestionUnchangedIsAccepted() throws {
        let event = try XCTUnwrap(collector().event(for: feedback(), now: now))
        XCTAssertEqual(event.action, .accepted)
        XCTAssertEqual(event.suggestionHMAC, event.finalHMAC)
    }

    func testReplacingAnEditedSuggestionIsEditedAndAccepted() throws {
        let edited = feedback(final: "Could we discuss this issue?")
        let event = try XCTUnwrap(collector().event(for: edited, now: now))
        XCTAssertEqual(event.action, .editedAndAccepted)
        XCTAssertNotNil(event.finalHMAC)
        XCTAssertNotEqual(event.suggestionHMAC, event.finalHMAC)
    }

    func testSurroundingWhitespaceIsNotAnEdit() throws {
        let padded = feedback(final: "\n  \(suggestion)  \n")
        let event = try XCTUnwrap(collector().event(for: padded, now: now))
        XCTAssertEqual(event.action, .accepted)
        XCTAssertEqual(event.suggestionHMAC, event.finalHMAC)
    }

    func testCopyingIsRecordedAsCopied() throws {
        let event = try XCTUnwrap(collector().event(for: feedback(.copied), now: now))
        XCTAssertEqual(event.action, .copied)
        XCTAssertNotNil(event.finalHMAC)
    }

    func testRegeneratingHasNoFinalText() throws {
        let event = try XCTUnwrap(collector().event(for: feedback(.regenerated), now: now))
        XCTAssertEqual(event.action, .regenerated)
        XCTAssertNil(event.finalHMAC)
    }

    func testNothingIsLearnedWithoutAFinishedSuggestion() {
        XCTAssertNil(collector().event(for: feedback(generated: nil), now: now))
        XCTAssertNil(collector().event(for: feedback(generated: "  \n"), now: now))
    }

    func testNothingIsLearnedWithoutSourceText() {
        XCTAssertNil(collector().event(for: feedback(original: " "), now: now))
    }

    func testEventCarriesModeProviderModelAndTime() throws {
        let event = try XCTUnwrap(collector().event(for: feedback(mode: .toneFormal), now: now))
        XCTAssertEqual(event.mode, .toneFormal)
        XCTAssertEqual(event.provider, "localLlama")
        XCTAssertEqual(event.model, "qwen")
        XCTAssertEqual(event.createdAt, now)
        XCTAssertTrue(event.usedMemoryIDs.isEmpty)
    }

    func testHashesAreKeyedStableAndHideTheText() throws {
        let one = try XCTUnwrap(collector().event(for: feedback(), now: now))
        let again = try XCTUnwrap(collector().event(for: feedback(), now: now))
        let otherKey = try XCTUnwrap(collector(keyByte: 2).event(for: feedback(), now: now))

        XCTAssertEqual(one.sourceHMAC, again.sourceHMAC)
        XCTAssertNotEqual(one.sourceHMAC, otherKey.sourceHMAC)
        XCTAssertEqual(one.sourceHMAC.count, 64)
        XCTAssertTrue(one.sourceHMAC.allSatisfy(\.isHexDigit))
        XCTAssertNotEqual(one.sourceHMAC, one.suggestionHMAC, "different texts hash differently")
    }
}
