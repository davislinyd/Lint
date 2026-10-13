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

    func testEveryToneStaysReadable() {
        // Settings, prompt overrides and the memory database of earlier versions name every one of them.
        XCTAssertEqual(WritingTone.allCases, [
            .preserve, .idiomatic, .formal, .casual, .concise, .professional,
            .native, .nativeCasual, .nativeFormal, .nativeGenZ, .nativeConcise,
        ])
    }

    func testProofreadingStartsIdiomaticUntilTheUserPicksATone() {
        XCTAssertEqual(WritingMode.proofread.defaultTone, .idiomatic)
        XCTAssertEqual(WritingMode.translate.defaultTone, .preserve)
        XCTAssertEqual(WritingMode.custom.defaultTone, .preserve)
        let untouched = WritingToneMemory()
        XCTAssertEqual(untouched.tone(for: .proofread), .idiomatic)
        XCTAssertEqual(untouched.tone(for: .translate), .preserve)
        XCTAssertEqual(WritingToneMemory(proofread: .preserve).tone(for: .proofread), .preserve, "a tone the user picked stays, preserve included")
        for mode in [WritingMode.proofread, .translate] {
            XCTAssertTrue(mode.tones.contains(mode.defaultTone), "\(mode)")
        }
    }

    func testTheMenusOfferFiveTones() {
        XCTAssertEqual(WritingMode.proofread.tones, [.preserve, .idiomatic, .formal, .casual, .concise])
        XCTAssertEqual(WritingMode.translate.tones, [.preserve, .formal, .casual, .concise], "no idiomatic English to make of a translation")
        XCTAssertEqual(WritingMode.custom.tones, [])
        for tone in WritingMode.proofread.tones { XCTAssertEqual(tone.menuTone, tone, "\(tone)") }
    }

    func testEveryOtherToneBelongsToTheMenuToneItIsWrittenForOrNowMeans() {
        let expected: [WritingTone: WritingTone] = [
            .native: .idiomatic, .nativeFormal: .formal, .professional: .formal,
            .nativeCasual: .casual, .nativeGenZ: .casual, .nativeConcise: .concise,
        ]
        for (tone, menu) in expected { XCTAssertEqual(tone.menuTone, menu, "\(tone)") }
    }

    func testTheTonesThatWriteEnglishFromChineseAreTheNativeOnes() {
        XCTAssertEqual(WritingTone.allCases.filter(\.isNative), [.native, .nativeCasual, .nativeFormal, .nativeGenZ, .nativeConcise])
        for tone in WritingMode.proofread.tones { XCTAssertFalse(tone.isNative, "\(tone)") }
    }

    func testThePromptsThatCanBeEditedAreEveryToneARequestCanBeWrittenIn() {
        XCTAssertEqual(
            WritingMode.proofread.promptTones,
            [.preserve, .idiomatic, .native, .formal, .nativeFormal, .casual, .nativeCasual, .concise, .nativeConcise]
        )
        XCTAssertEqual(WritingMode.translate.promptTones, WritingMode.translate.tones)
        // Each English-from-Chinese tone is named after its menu tone, so the list reads in pairs.
        for tone in [WritingTone.native, .nativeFormal, .nativeCasual, .nativeConcise] {
            XCTAssertTrue(tone.title.hasPrefix(tone.menuTone.title + " · "), tone.title)
        }
        XCTAssertEqual(Set(WritingMode.proofread.promptTones.map(\.title)).count, 9)
    }

    func testIdiomaticIsAProofreadingToneOnly() {
        XCTAssertTrue(WritingMode.proofread.tones.contains(.idiomatic))
        XCTAssertFalse(WritingMode.translate.tones.contains(.idiomatic), "a translation is not English to make idiomatic")
        var memory = WritingToneMemory(proofread: .idiomatic, translate: .idiomatic)
        XCTAssertEqual(memory.tone(for: .proofread), .idiomatic)
        XCTAssertEqual(memory.tone(for: .translate), .preserve)
        memory.set(.idiomatic, for: .translate)
        XCTAssertEqual(memory.tone(for: .translate), .preserve)
        XCTAssertEqual(WritingPromptComposer.overrideKey(mode: .proofread, tone: .idiomatic), "proofread|idiomatic")
    }

    func testAToneSavedByAnEarlierVersionIsRememberedAsItsMenuTone() {
        for tone in WritingTone.allCases {
            XCTAssertEqual(WritingToneMemory(proofread: tone).tone(for: .proofread), tone.menuTone, "\(tone)")
            let translated = WritingToneMemory(translate: tone).tone(for: .translate)
            XCTAssertEqual(translated, WritingMode.translate.tones.contains(tone.menuTone) ? tone.menuTone : .preserve, "\(tone)")
        }
        var memory = WritingToneMemory()
        memory.set(.nativeGenZ, for: .proofread)
        XCTAssertEqual(memory.tone(for: .proofread), .casual)
        memory.set(.native, for: .translate)
        XCTAssertEqual(memory.tone(for: .translate), .preserve, "a translation has no idiomatic tone")
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
