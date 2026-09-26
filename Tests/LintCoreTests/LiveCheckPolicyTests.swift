import XCTest
@testable import LintCore

final class LiveCheckPolicyTests: XCTestCase {
    func testAMissingSettingIsOffAndAStoredChoiceIsKept() {
        XCTAssertFalse(LiveCheckPolicy.enabledValue(stored: nil))
        XCTAssertTrue(LiveCheckPolicy.enabledValue(stored: true))
        XCTAssertFalse(LiveCheckPolicy.enabledValue(stored: false))
        XCTAssertEqual(
            LiveCheckPolicy.decide(featureEnabled: false, bundleID: "com.apple.TextEdit", isSecure: false, characterCount: 40),
            .skipDisabled
        )
    }

    func testDenylistedBundlesAreSkippedAndUnknownBundlesAreAllowedWhenOn() {
        for bundle in LiveCheckPolicy.denylistedBundleIDs {
            XCTAssertEqual(
                LiveCheckPolicy.decide(featureEnabled: true, bundleID: bundle, isSecure: false, characterCount: 40),
                .skipDenylisted,
                bundle
            )
        }
        XCTAssertEqual(
            LiveCheckPolicy.decide(featureEnabled: true, bundleID: "com.apple.TextEdit", isSecure: false, characterCount: 40),
            .allow
        )
        XCTAssertEqual(
            LiveCheckPolicy.decide(featureEnabled: true, bundleID: nil, isSecure: false, characterCount: 40),
            .allow
        )
    }

    func testShortTextAndSecureFieldsAreSkipped() {
        XCTAssertEqual(
            LiveCheckPolicy.decide(featureEnabled: true, bundleID: "com.apple.TextEdit", isSecure: false, characterCount: 7),
            .skipTooShort
        )
        XCTAssertEqual(
            LiveCheckPolicy.decide(
                featureEnabled: true, bundleID: "com.apple.TextEdit", isSecure: true, characterCount: 40
            ),
            .skipSecure
        )
    }

    func testPollingStopsOnlyWhenBothWatchesAreOff() {
        XCTAssertFalse(LiveCheckPolicy.shouldPoll(watchSelection: false, watchTyping: false))
        XCTAssertTrue(LiveCheckPolicy.shouldPoll(watchSelection: true, watchTyping: false))
        XCTAssertTrue(LiveCheckPolicy.shouldPoll(watchSelection: false, watchTyping: true))
    }
}
