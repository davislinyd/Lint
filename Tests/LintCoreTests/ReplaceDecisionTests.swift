import XCTest
@testable import LintCore

final class ReplaceDecisionTests: XCTestCase {
    func testVerifiedAXReplaceRewritesTheSingleOccurrence() {
        let snapshot = snapshot(field: "Hello snippet tail", original: "snippet", newText: "fixed")
        guard case .perform(.setFieldValue(let updated)) = ReplaceDecision.first(snapshot) else {
            return XCTFail("expected a field rewrite, got \(ReplaceDecision.first(snapshot))")
        }
        XCTAssertEqual(updated, "Hello fixed tail")
        XCTAssertEqual(
            ReplaceDecision.afterAXWriteSucceeded(fieldBefore: "Hello snippet tail", fieldAfter: updated, newText: "fixed"),
            .success
        )
    }

    func testSnippetSmallerThanTheFieldNeverSelectsAll() {
        let snapshot = snapshot(field: "prefix snippet suffix", original: "snippet", newText: "fixed")
        var directive = ReplaceDecision.first(snapshot)
        for _ in 0..<6 {
            switch directive {
            case .perform(let attempt):
                if case .selectAllAndPaste = attempt {
                    return XCTFail("select-all on a field larger than the snippet")
                }
                directive = ReplaceDecision.afterAXWriteFailed(attempt, snapshot)
            case .success:
                return XCTFail("nothing was written")
            case .failure(let reason):
                XCTAssertEqual(reason, .notWholeField)
                return
            }
        }
        XCTFail("decision did not stop")
    }

    func testARestoredRangeInALargerFieldNeverSelectsAll() {
        let snapshot = snapshot(
            field: "prefix snippet suffix", original: "snippet", newText: "fixed", rangeRestored: true
        )
        var directive = ReplaceDecision.first(snapshot)
        for _ in 0..<6 {
            switch directive {
            case .perform(let attempt):
                if case .selectAllAndPaste = attempt {
                    return XCTFail("select-all after the range was restored")
                }
                if case .pasteIntoRestoredSelection = attempt {
                    directive = ReplaceDecision.afterPaste(
                        fieldBefore: snapshot.fieldValue, fieldAfter: nil, newText: snapshot.newText
                    )
                } else {
                    directive = ReplaceDecision.afterAXWriteFailed(attempt, snapshot)
                }
            case .success:
                return XCTFail("a field that could be read and then could not was treated as success")
            case .failure(let reason):
                XCTAssertEqual(reason, .unverified)
                return
            }
        }
        XCTFail("restored-range decision did not stop")
    }

    func testUnreadableFieldNeverSelectsAll() {
        let snapshot = snapshot(field: nil, original: "snippet", newText: "fixed", rangeRestored: true)
        var directive = ReplaceDecision.first(snapshot)
        for _ in 0..<6 {
            switch directive {
            case .perform(let attempt):
                if case .selectAllAndPaste = attempt {
                    return XCTFail("select-all without a readable field")
                }
                if case .pasteIntoRestoredSelection = attempt {
                    directive = ReplaceDecision.afterPaste(
                        fieldBefore: snapshot.fieldValue, fieldAfter: nil, newText: snapshot.newText
                    )
                } else {
                    directive = ReplaceDecision.afterAXWriteFailed(attempt, snapshot)
                }
            case .failure(let reason):
                return XCTFail("a paste over the checked selection of an unreadable field failed: \(reason)")
            case .success:
                // Nothing can be read before or after, and the paste went only over the checked selection.
                return
            }
        }
        XCTFail("decision did not stop")
    }

    func testUnverifiedPasteIsAnErrorEvenIfTheOriginalIsGone() {
        let before = "Hello snippet tail"
        XCTAssertEqual(
            ReplaceDecision.afterPaste(fieldBefore: before, fieldAfter: nil, newText: "fixed"),
            .failure(.unverified)
        )
        XCTAssertEqual(
            ReplaceDecision.afterPaste(fieldBefore: before, fieldAfter: "", newText: "fixed"),
            .failure(.unverified)
        )
        XCTAssertEqual(
            ReplaceDecision.afterAXWriteSucceeded(fieldBefore: before, fieldAfter: "Hello tail", newText: "fixed"),
            .failure(.unverified)
        )
        XCTAssertFalse(ReplaceDecision.confirmed(fieldAfter: "other text", newText: "fixed"))
        XCTAssertEqual(ReplaceRefusal.unverified.message, "無法確認已寫入。若不對請還原（⌘Z）。")
    }

    func testAFieldThatCannotBeReadCountsATargetedWriteAsDone() {
        for before in [nil, ""] as [String?] {
            for after in [nil, ""] as [String?] {
                XCTAssertEqual(
                    ReplaceDecision.afterPaste(fieldBefore: before, fieldAfter: after, newText: "fixed"),
                    .success
                )
                XCTAssertEqual(
                    ReplaceDecision.afterAXWriteSucceeded(fieldBefore: before, fieldAfter: after, newText: "fixed"),
                    .success
                )
            }
        }
        // Once the field can be read, it has to show the new text.
        XCTAssertEqual(
            ReplaceDecision.afterPaste(fieldBefore: nil, fieldAfter: "Hello snippet tail", newText: "fixed"),
            .failure(.unverified)
        )
        XCTAssertEqual(
            ReplaceDecision.afterPaste(fieldBefore: nil, fieldAfter: "Hello fixed tail", newText: "fixed"),
            .success
        )
        // A paste that is reported as failed is never done.
        XCTAssertEqual(
            ReplaceDecision.afterAXWriteFailed(
                .pasteIntoRestoredSelection,
                snapshot(field: nil, original: "snippet", newText: "fixed", rangeRestored: true)
            ),
            .failure(.unverified)
        )
    }

    func testOnlyTheCheckedTextMayBeWrittenOver() {
        XCTAssertTrue(ReplaceDecision.liveMatches("snippet", original: "snippet"))
        XCTAssertTrue(ReplaceDecision.liveMatches(" snippet\n", original: "snippet"))
        XCTAssertFalse(ReplaceDecision.liveMatches("prefix snippet suffix", original: "snippet"))
        XCTAssertFalse(ReplaceDecision.liveMatches("snip", original: "snippet"))
        XCTAssertFalse(ReplaceDecision.liveMatches(nil, original: "snippet"))
        XCTAssertFalse(ReplaceDecision.liveMatches("", original: ""))
    }

    func testNoCaptureUsesTheExistingMessage() {
        let snapshot = snapshot(field: "snippet", original: "snippet", newText: "fixed", hasCapture: false)
        XCTAssertEqual(ReplaceDecision.first(snapshot), .failure(.noCapture))
        XCTAssertEqual(ReplaceRefusal.noCapture.message, "沒有可覆蓋的選取")
    }

    func testSourceNotFrontmostRefusesBeforeAnyWrite() {
        let snapshot = snapshot(
            field: "snippet", original: "snippet", newText: "fixed", sourceFrontmost: false
        )
        XCTAssertEqual(ReplaceDecision.first(snapshot), .failure(.sourceNotFrontmost))
        XCTAssertEqual(ReplaceRefusal.sourceNotFrontmost.message, "沒有寫入。")
        XCTAssertFalse(ReplaceDecision.allowsSelectAll(field: "prefix snippet", original: "snippet"))
    }

    func testWholeFieldMaySelectAllOnlyAfterTheValueWriteFails() {
        let snapshot = snapshot(field: "  snippet\n", original: "snippet", newText: "fixed")
        guard case .perform(.setFieldValue) = ReplaceDecision.first(snapshot) else {
            return XCTFail("a field equal to the snippet is still a value write first")
        }
        XCTAssertTrue(ReplaceDecision.allowsSelectAll(field: "  snippet\n", original: "snippet"))
        XCTAssertEqual(
            ReplaceDecision.afterAXWriteFailed(.setFieldValue("fixed"), snapshot),
            .perform(.selectAllAndPaste)
        )
    }

    func testRepeatedSnippetIsNotRewrittenAtTheFirstMatch() {
        let snapshot = snapshot(field: "snippet and snippet", original: "snippet", newText: "fixed")
        XCTAssertEqual(ReplaceDecision.first(snapshot), .failure(.ambiguous))
        var restored = snapshot
        restored.rangeRestored = true
        XCTAssertEqual(ReplaceDecision.first(restored), .perform(.setSelectedText))
    }

    private func snapshot(
        field: String?,
        original: String,
        newText: String,
        hasCapture: Bool = true,
        sourceFrontmost: Bool = true,
        rangeRestored: Bool = false
    ) -> ReplaceSnapshot {
        ReplaceSnapshot(
            hasCapture: hasCapture,
            sourceFrontmost: sourceFrontmost,
            hasElement: true,
            fieldValue: field,
            original: original,
            newText: newText,
            rangeRestored: rangeRestored,
            liveSelectedText: nil
        )
    }
}
