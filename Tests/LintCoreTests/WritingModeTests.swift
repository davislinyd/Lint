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
        XCTAssertEqual(WritingTone.allCases, [.preserve, .formal, .concise, .professional])
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
        XCTAssertEqual(WritingMode.custom.displayTitle(tone: .formal), WritingMode.custom.title, "custom has no tone")
    }
}
