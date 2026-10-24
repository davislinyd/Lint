import XCTest

@testable import LintCore

final class ForeignServerPolicyTests: XCTestCase {
    func testAnEmptyPortIsLeftToTheNormalLaunch() {
        XCTAssertNil(ForeignServerPolicy.decide(withLintsKey: .unreachable, withoutKey: nil, isLintsOrphan: false))
    }

    func testAServerLeftBehindByLintIsReplacedWhateverKeyItHas() {
        // Lint crashed or was killed: its llama-server kept the old process's key.
        XCTAssertEqual(ForeignServerPolicy.decide(withLintsKey: .rejectedKey, withoutKey: nil, isLintsOrphan: true), .replace)
        // An older Lint started it without a key.
        XCTAssertEqual(ForeignServerPolicy.decide(withLintsKey: .ready, withoutKey: .ready, isLintsOrphan: true), .replace)
    }

    func testSomeoneElsesServerWithoutAKeyIsUsedButMarkedUnprotected() {
        XCTAssertEqual(
            ForeignServerPolicy.decide(withLintsKey: .ready, withoutKey: .ready, isLintsOrphan: false),
            .attach(unprotected: true)
        )
    }

    func testSomeoneElsesServerWithAnotherKeyIsNotTouched() {
        XCTAssertEqual(ForeignServerPolicy.decide(withLintsKey: .rejectedKey, withoutKey: nil, isLintsOrphan: false), .refuse)
    }

    func testAServerThatIsStillLoadingIsNotJudgedYet() {
        // b11046 answers 503 before it looks at the key.
        XCTAssertNil(ForeignServerPolicy.decide(withLintsKey: .unexpected(503), withoutKey: nil, isLintsOrphan: false))
    }
}
