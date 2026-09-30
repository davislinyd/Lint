import XCTest
@testable import LintCore

final class WritingModeTests: XCTestCase {
    func testOnlyTheTasksCanBeChosen() {
        XCTAssertEqual(WritingMode.allCases, [.proofread, .translate, .custom])
    }

    func testEveryTaskAndToneHasATitle() {
        for mode in WritingMode.allCases {
            XCTAssertFalse(mode.title.isEmpty)
        }
        for tone in WritingTone.allCases {
            XCTAssertFalse(tone.title.isEmpty)
        }
    }

    func testPreserveIsTheFirstTone() {
        XCTAssertEqual(WritingTone.allCases, [.preserve, .formal, .concise, .professional, .native])
    }

    func testOnlyProofreadingCanWriteLikeANativeSpeaker() {
        XCTAssertEqual(WritingMode.proofread.tones, WritingTone.allCases)
        XCTAssertEqual(WritingMode.translate.tones, [.preserve, .formal, .concise, .professional])
        XCTAssertEqual(WritingMode.custom.tones, [])
    }

    func testATranslationRemembersNoNativeTone() {
        var memory = WritingToneMemory(proofread: .native, translate: .native)
        XCTAssertEqual(memory.tone(for: .proofread), .native)
        XCTAssertEqual(memory.tone(for: .translate), .preserve, "a translation has no native tone to restore")
        memory.set(.native, for: .translate)
        XCTAssertEqual(memory.tone(for: .translate), .preserve)
        memory.set(.formal, for: .translate)
        XCTAssertEqual(memory.tone(for: .translate), .formal)
        XCTAssertEqual(memory.tone(for: .proofread), .native, "each task keeps its own")
    }

    func testProofreadingAndTranslationTakeATone() {
        XCTAssertTrue(WritingMode.proofread.supportsTone)
        XCTAssertTrue(WritingMode.translate.supportsTone)
        XCTAssertFalse(WritingMode.custom.supportsTone)
    }

    func testTheDisplayTitleShowsOnlyATonePeopleChose() {
        XCTAssertEqual(WritingMode.proofread.displayTitle(tone: .preserve), WritingMode.proofread.title)
        XCTAssertEqual(
            WritingMode.proofread.displayTitle(tone: .formal), "\(WritingMode.proofread.title) · \(WritingTone.formal.title)"
        )
        XCTAssertEqual(
            WritingMode.translate.displayTitle(tone: .professional),
            "\(WritingMode.translate.title) · \(WritingTone.professional.title)"
        )
        XCTAssertEqual(
            WritingMode.proofread.displayTitle(tone: .native), "\(WritingMode.proofread.title) · \(WritingTone.native.title)"
        )
        XCTAssertEqual(WritingMode.custom.displayTitle(tone: .formal), WritingMode.custom.title, "custom has no tone")
    }
}
