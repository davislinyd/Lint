import XCTest
@testable import LintCore

final class DiffAnalyzerTests: XCTestCase {
    private func spans(_ old: String, _ new: String) -> [EditSpan] {
        DiffAnalyzer.spans(from: DiffAnalyzer.tokens(in: old), to: DiffAnalyzer.tokens(in: new))
    }

    private func keys(_ tokens: [WordToken]) -> [String] {
        tokens.map(\.key)
    }

    // MARK: tokens

    func testTokensAreLowercasedAndMarkSentenceStarts() {
        let tokens = DiffAnalyzer.tokens(in: "We met. Then we left\nNow")
        XCTAssertEqual(keys(tokens), ["we", "met", "then", "we", "left", "now"])
        XCTAssertEqual(tokens.map(\.isSentenceStart), [true, false, true, false, false, true])
        XCTAssertEqual(tokens[0].text, "We")
    }

    func testKeysWriteTheTypographicApostrophesAsThePlainOne() {
        for apostrophe in ["\u{2019}", "\u{2018}", "\u{02BC}", "\u{FF07}", "'"] {
            XCTAssertEqual(WordToken.key(of: "Don\(apostrophe)t"), "don't")
        }
        XCTAssertEqual(keys(DiffAnalyzer.tokens(in: "It’s here")), ["it's", "here"])
        XCTAssertEqual(DiffAnalyzer.tokens(in: "It’s here")[0].text, "It’s", "the text stays as written")
    }

    func testAddressesPathsAndTagsAreGlued() {
        let text = "mail john@acme.com or see https://acme.com/a and notes.txt or #tag now."
        let glued = Set(DiffAnalyzer.tokens(in: text).filter(\.isGlued).map(\.key))
        for word in ["john", "acme", "com", "https", "a", "notes", "txt", "tag"] {
            XCTAssertTrue(glued.contains(word), "\(word) should be glued")
        }
        for word in ["mail", "or", "see", "and", "now"] {
            XCTAssertFalse(glued.contains(word), "\(word) is an ordinary word")
        }
    }

    func testSentencePunctuationDoesNotGlueAWord() {
        let tokens = DiffAnalyzer.tokens(in: "We fixed the issue. Next, we test.")
        XCTAssertTrue(tokens.allSatisfy { !$0.isGlued })
    }

    func testNamesAreTagged() {
        let tokens = DiffAnalyzer.tokens(in: "John said we should meet.")
        XCTAssertTrue(tokens[0].isName)
        XCTAssertFalse(tokens[1].isName)
    }

    func testChineseWordsAreSegmented() {
        XCTAssertTrue(keys(DiffAnalyzer.tokens(in: "這個軟件需要更新")).contains("軟件"))
    }

    // MARK: spans

    func testReplacementIsOneSpanWithContext() throws {
        let found = spans("From my prospective I think we should wait", "From my perspective I think we should wait")
        let span = try XCTUnwrap(found.first)
        XCTAssertEqual(found.count, 1)
        XCTAssertEqual(keys(span.removed), ["prospective"])
        XCTAssertEqual(keys(span.added), ["perspective"])
        XCTAssertEqual(keys(span.before), ["from", "my"])
    }

    func testInsertionAndDeletion() throws {
        let inserted = try XCTUnwrap(spans("I have meeting tomorrow", "I have a meeting tomorrow").first)
        XCTAssertEqual(keys(inserted.added), ["a"])
        XCTAssertTrue(inserted.removed.isEmpty)

        let deleted = try XCTUnwrap(spans("We discuss about the plan", "We discuss the plan").first)
        XCTAssertEqual(keys(deleted.removed), ["about"])
        XCTAssertTrue(deleted.added.isEmpty)
        XCTAssertEqual(keys(deleted.before), ["we", "discuss"])
    }

    func testSeveralSpansKeepTheirContextApart() {
        let found = spans(
            "I think we need discuss about this issue.",
            "I think we need to discuss this issue."
        )
        XCTAssertEqual(found.count, 2)
        XCTAssertEqual(keys(found[0].added), ["to"])
        XCTAssertEqual(keys(found[1].removed), ["about"])
        // The word between the two spans is the second one's `before`, which does not reach back
        // into the first span.
        XCTAssertEqual(keys(found[1].before), ["discuss"])
    }

    func testIdenticalOrCaseOnlyDifferencesGiveNoSpans() {
        XCTAssertTrue(spans("we should wait", "we should wait").isEmpty)
        XCTAssertTrue(spans("i think so", "I think so").isEmpty)
        XCTAssertTrue(spans("", "").isEmpty)
    }

    func testSwitchingApostropheStyleIsNoEditButARealEditBesideItIs() throws {
        XCTAssertTrue(spans("We don’t know why it can’t work.", "We don't know why it can't work.").isEmpty)
        XCTAssertTrue(spans("We don't know why it can't work.", "We don’t know why it can’t work.").isEmpty)

        let found = spans("We don’t recieve it.", "We don't receive it.")
        XCTAssertEqual(found.count, 1)
        XCTAssertEqual(keys(try XCTUnwrap(found.first).removed), ["recieve"])
    }

    func testChineseWordReplacement() throws {
        let span = try XCTUnwrap(spans("這個軟件需要更新", "這個軟體需要更新").first)
        XCTAssertEqual(keys(span.removed), ["軟件"])
        XCTAssertEqual(keys(span.added), ["軟體"])
    }

    func testTextsTooDifferentToCompareGiveNoSpans() {
        let old = (0..<(DiffAnalyzer.maxMiddleTokens + 1)).map { "old\($0)" }.joined(separator: " ")
        let new = (0..<10).map { "new\($0)" }.joined(separator: " ")
        XCTAssertTrue(spans(old, new).isEmpty)
    }

    // MARK: rewrite guard

    func testHeavyRewriteIsRecognised() {
        let old = DiffAnalyzer.tokens(in: "Please kindly help me to check this issue.")
        let new = DiffAnalyzer.tokens(in: "Could you please check this issue?")
        let found = DiffAnalyzer.spans(from: old, to: new)
        XCTAssertTrue(DiffAnalyzer.isRewrite(found, oldCount: old.count, newCount: new.count))
    }

    func testSmallEditsAndTinyTextsAreNotRewrites() {
        let old = DiffAnalyzer.tokens(in: "I think we need discuss about this issue.")
        let new = DiffAnalyzer.tokens(in: "I think we need to discuss this issue.")
        let found = DiffAnalyzer.spans(from: old, to: new)
        XCTAssertFalse(DiffAnalyzer.isRewrite(found, oldCount: old.count, newCount: new.count))

        let tinyOld = DiffAnalyzer.tokens(in: "teh cat")
        let tinyNew = DiffAnalyzer.tokens(in: "the cat")
        let tiny = DiffAnalyzer.spans(from: tinyOld, to: tinyNew)
        XCTAssertFalse(DiffAnalyzer.isRewrite(tiny, oldCount: tinyOld.count, newCount: tinyNew.count))
    }
}
