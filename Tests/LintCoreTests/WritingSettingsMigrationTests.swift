import XCTest
@testable import LintCore

final class WritingSettingsMigrationTests: XCTestCase {
    // MARK: legacy names

    func testTheOldNamesResolveToATaskAndATone() {
        let expected: [(String, WritingMode, WritingTone)] = [
            ("proofread", .proofread, .preserve),
            ("toneFormal", .proofread, .formal),
            ("toneConcise", .proofread, .concise),
            ("toneProfessional", .proofread, .professional),
            ("translate", .translate, .preserve),
            ("custom", .custom, .preserve),
        ]
        for (raw, mode, tone) in expected {
            let resolved = LegacyWritingMode.resolve(raw)
            XCTAssertEqual(resolved?.mode, mode, raw)
            XCTAssertEqual(resolved?.tone, tone, raw)
        }
        XCTAssertNil(LegacyWritingMode.resolve("toneCasual"))
    }

    // MARK: last mode

    func testAnOldToneModeBecomesProofreadingInThatTone() {
        for (raw, tone) in [("toneFormal", WritingTone.formal), ("toneConcise", .concise), ("toneProfessional", .professional)] {
            let migrated = WritingSettingsMigration.migrateLastMode(raw)
            XCTAssertEqual(migrated.mode, .proofread, raw)
            XCTAssertEqual(migrated.proofreadTone, tone, raw)
        }
    }

    func testProofreadTranslateAndCustomKeepTheirTaskAndSetNoTone() {
        for mode in WritingMode.allCases {
            let migrated = WritingSettingsMigration.migrateLastMode(mode.rawValue)
            XCTAssertEqual(migrated.mode, mode)
            XCTAssertNil(migrated.proofreadTone, "an existing tone must not be replaced by the default")
        }
    }

    func testNothingOrSomethingUnknownStoredIsProofreading() {
        XCTAssertEqual(WritingSettingsMigration.migrateLastMode(nil).mode, .proofread)
        XCTAssertEqual(WritingSettingsMigration.migrateLastMode("").mode, .proofread)
        XCTAssertEqual(WritingSettingsMigration.migrateLastMode("toneCasual").mode, .proofread)
        XCTAssertNil(WritingSettingsMigration.migrateLastMode("toneCasual").proofreadTone)
    }

    func testMigratingTheLastModeAgainChangesNothing() {
        let first = WritingSettingsMigration.migrateLastMode("toneProfessional")
        let second = WritingSettingsMigration.migrateLastMode(first.mode.rawValue)
        XCTAssertEqual(second.mode, first.mode)
        XCTAssertNil(second.proofreadTone, "the tone was stored the first time; it is not stored again")
    }

    // MARK: prompt overrides

    private let old: [String: String] = [
        "proofread": "my proofreading prompt",
        "toneFormal": "my formal prompt",
        "toneConcise": "my concise prompt",
        "toneProfessional": "my professional prompt",
        "translate": "my translation prompt",
        "custom": "my custom prompt",
    ]

    func testEveryOldOverrideSurvivesUnderItsNewKey() {
        let migrated = WritingSettingsMigration.migrateOverrides(old)
        XCTAssertEqual(migrated["proofread|preserve"], "my proofreading prompt")
        XCTAssertEqual(migrated["proofread|formal"], "my formal prompt")
        XCTAssertEqual(migrated["proofread|concise"], "my concise prompt")
        XCTAssertEqual(migrated["proofread|professional"], "my professional prompt")
        XCTAssertEqual(migrated["translate|preserve"], "my translation prompt")
        XCTAssertEqual(migrated["custom"], "my custom prompt")
    }

    func testAnOldTonePromptStaysAFullPromptForProofreading() {
        // It is not turned into a tone modifier, and it is not offered to translation.
        let migrated = WritingSettingsMigration.migrateOverrides(["toneFormal": "full formal prompt"])
        XCTAssertEqual(migrated["proofread|formal"], "full formal prompt")
        XCTAssertNil(migrated["translate|formal"])
    }

    func testCombinationsThatHadNoOverrideKeepTheBuiltInPrompt() {
        let migrated = WritingSettingsMigration.migrateOverrides(old)
        for key in ["translate|formal", "translate|concise", "translate|professional"] {
            XCTAssertNil(migrated[key], key)
        }
    }

    func testTheOldKeysAreLeftInPlace() {
        let migrated = WritingSettingsMigration.migrateOverrides(old)
        for (key, value) in old {
            XCTAssertEqual(migrated[key], value, "\(key) is not discarded")
        }
    }

    func testMigratingOverridesAgainChangesNothing() {
        let once = WritingSettingsMigration.migrateOverrides(old)
        XCTAssertEqual(WritingSettingsMigration.migrateOverrides(once), once)
    }

    func testAnOverrideAlreadyStoredUnderTheNewKeyIsNotOverwritten() {
        let migrated = WritingSettingsMigration.migrateOverrides([
            "proofread": "older",
            "proofread|preserve": "newer",
        ])
        XCTAssertEqual(migrated["proofread|preserve"], "newer")
    }

    func testOverridesThatAreNotOldModesAreLeftAlone() {
        let migrated = WritingSettingsMigration.migrateOverrides(["something": "else"])
        XCTAssertEqual(migrated, ["something": "else"])
        XCTAssertEqual(WritingSettingsMigration.migrateOverrides([:]), [:])
    }

    // MARK: a tone for each task

    func testProofreadAndTranslateRememberTheirTonesIndependently() {
        var memory = WritingToneMemory()
        memory.set(.professional, for: .proofread)
        XCTAssertEqual(memory.tone(for: .translate), .preserve)

        memory.set(.formal, for: .translate)
        XCTAssertEqual(memory.tone(for: .proofread), .professional)
        XCTAssertEqual(memory.tone(for: .translate), .formal)
    }

    func testGoingFromOneTaskToAnotherAndBackFindsTheToneWhereItWasLeft() {
        var memory = WritingToneMemory()
        memory.set(.professional, for: .proofread)
        var seen: [WritingTone] = []
        for mode in [WritingMode.proofread, .translate, .proofread] {
            seen.append(memory.tone(for: mode))
        }
        XCTAssertEqual(seen, [.professional, .preserve, .professional])
    }

    func testCustomHasNoToneToRemember() {
        var memory = WritingToneMemory(proofread: .concise, translate: .formal)
        memory.set(.professional, for: .custom)
        XCTAssertEqual(memory.tone(for: .custom), .preserve)
        XCTAssertEqual(memory, WritingToneMemory(proofread: .concise, translate: .formal), "nothing else moved")
    }
}
