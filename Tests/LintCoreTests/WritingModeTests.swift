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
        XCTAssertEqual(WritingTone.allCases, [.preserve, .formal, .concise, .professional, .native, .nativeCasual, .nativeFormal, .nativeGenZ])
    }

    func testTheNativeSpeakerTonesAreTheOnesThatWriteEnglishFromAnyLanguage() {
        XCTAssertEqual(WritingTone.allCases.filter(\.isNative), [.native, .nativeCasual, .nativeFormal, .nativeGenZ])
        for tone in [WritingTone.preserve, .formal, .concise, .professional] {
            XCTAssertFalse(tone.isNative, "\(tone)")
        }
    }

    func testEveryNativeSpeakerStyleHasItsOwnTitleThatNamesTheBase() {
        let titles = WritingTone.allCases.filter(\.isNative).map(\.title)
        XCTAssertEqual(Set(titles).count, 4, "\(titles)")
        for tone in [WritingTone.nativeCasual, .nativeFormal, .nativeGenZ] {
            XCTAssertTrue(tone.title.hasPrefix(WritingTone.native.title + " · "), tone.title)
        }
        XCTAssertNotEqual(WritingTone.nativeFormal.title, WritingTone.formal.title, "the two formal tones are told apart")
        XCTAssertTrue(WritingTone.nativeGenZ.title.hasSuffix("Gen Z"))
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
        for tone in WritingTone.allCases.filter(\.isNative) {
            memory.set(tone, for: .translate)
            XCTAssertEqual(memory.tone(for: .translate), .preserve, "\(tone)")
            XCTAssertEqual(WritingToneMemory(proofread: tone, translate: tone).tone(for: .translate), .preserve, "\(tone)")
            XCTAssertEqual(WritingToneMemory(proofread: tone).tone(for: .proofread), tone, "proofreading keeps \(tone)")
        }
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
        XCTAssertEqual(
            WritingMode.proofread.displayTitle(tone: .nativeGenZ), "\(WritingMode.proofread.title) · \(WritingTone.nativeGenZ.title)"
        )
        XCTAssertEqual(WritingMode.custom.displayTitle(tone: .formal), WritingMode.custom.title, "custom has no tone")
    }
}
