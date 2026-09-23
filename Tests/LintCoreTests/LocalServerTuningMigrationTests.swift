import XCTest

@testable import LintCore

/// Lint's tuning moved out of the one free-text "extra arguments" setting and into each model's
/// runtime profile. What every existing install has stored in that setting therefore has to be
/// sorted into "this was only Lint's default" and "the user typed this".
final class LocalServerTuningMigrationTests: XCTestCase {
    func testAStoredCopyOfAnOldBuiltInDefaultIsCleared() {
        for builtIn in LocalServerArgumentsMigration.builtInDefaults {
            XCTAssertEqual(LocalServerArgumentsMigration.migrate(stored: builtIn), "", builtIn)
            XCTAssertEqual(LocalServerArgumentsMigration.migrate(stored: "  \(builtIn)  "), "", "whitespace only")
        }
        XCTAssertEqual(
            LocalServerArgumentsMigration.builtInDefaults.first,
            "--jinja --no-skip-chat-parsing -ngl 99 -fa on -c 4096 -np 1 -t 6 --reasoning off",
            "the Gemma-era default has to be recognised too"
        )
    }

    func testArgumentsTheUserTypedAreNeverTouched() {
        for custom in [
            "-c 16384",
            "--jinja --no-skip-chat-parsing -ngl 99 -fa on -c 4096 -np 1 -t 6 --reasoning off --verbose",
            "--jinja  --no-skip-chat-parsing -ngl 99 -fa on -c 4096 -np 1 -t 6 --reasoning off",  // extra space inside
            "-ngl 20",
        ] {
            XCTAssertEqual(LocalServerArgumentsMigration.migrate(stored: custom), custom)
        }
    }

    func testAFreshInstallHasNoOverrideAndMigratingTwiceChangesNothing() {
        XCTAssertEqual(LocalServerArgumentsMigration.migrate(stored: nil), "")
        XCTAssertEqual(LocalServerArgumentsMigration.migrate(stored: ""), "")
        XCTAssertEqual(LocalServerArgumentsMigration.migrate(stored: "   "), "")
        for stored in [nil, "", "-c 16384"] + LocalServerArgumentsMigration.builtInDefaults.map(Optional.init) {
            let once = LocalServerArgumentsMigration.migrate(stored: stored)
            XCTAssertEqual(LocalServerArgumentsMigration.migrate(stored: once), once, "stored: \(stored ?? "nil")")
        }
    }

    // MARK: - Idle sleep setting

    func testTheIdleSleepSettingDefaultsToFiveMinutesAndSurvivesNonsense() {
        XCTAssertEqual(IdleSleepOption.default, .fiveMinutes)
        XCTAssertEqual(IdleSleepOption.resolve(nil), .fiveMinutes, "a fresh install releases memory when idle")
        XCTAssertEqual(IdleSleepOption.resolve(300), .fiveMinutes)
        XCTAssertEqual(IdleSleepOption.resolve(0), .never)
        XCTAssertEqual(IdleSleepOption.resolve(1800), .thirtyMinutes)
        XCTAssertEqual(IdleSleepOption.resolve(97), .fiveMinutes, "a value that is not one of the choices")
        XCTAssertEqual(IdleSleepOption.never.seconds, 0, "0 leaves the flag out entirely")
        XCTAssertEqual(IdleSleepOption.allCases.map(\.seconds), [0, 60, 300, 600, 1800])
    }
}
