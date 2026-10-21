import XCTest
@testable import LintCore

final class ReplaceSpansTests: XCTestCase {
    func testAMentionBeforeTheTypoIsLeftOut() {
        let original = "@Davis Lin this is aa pen."
        let newText = "@Davis Lin this is a pen."
        let spans = ReplaceSpans.spans(original: original, newText: newText, base: 3)
        XCTAssertEqual(spans, [ReplaceSpan(location: 22, old: "aa", new: "a")])
        assertSpans(spans, turn: original, into: newText, base: 3)
    }

    func testUnchangedTextBetweenTwoEditsStaysOutsideBothSpans() {
        let original = "Plese see https://x.y/doc and reply soon"
        let newText = "Please see https://x.y/doc and reply soon."
        let spans = ReplaceSpans.spans(original: original, newText: newText, base: 0)
        XCTAssertEqual(spans, [
            ReplaceSpan(location: 36, old: "soon", new: "soon."),
            ReplaceSpan(location: 0, old: "Plese", new: "Please"),
        ])
        assertSpans(spans, turn: original, into: newText, base: 0)
    }

    func testEditsSeparatedOnlyBySpacesAreOneSpan() {
        let spans = ReplaceSpans.spans(original: "a teh brwon fox", newText: "a the brown fox", base: 0)
        XCTAssertEqual(spans, [ReplaceSpan(location: 2, old: "teh brwon", new: "the brown")])
    }

    func testEditsOnDifferentLinesStayApart() {
        let original = "teh\nbrwon"
        let newText = "the\nbrown"
        let spans = ReplaceSpans.spans(original: original, newText: newText, base: 0)
        XCTAssertEqual(spans.count, 2)
        XCTAssertFalse(spans.contains { $0.old.contains("\n") || $0.new.contains("\n") })
        assertSpans(spans, turn: original, into: newText, base: 0)
    }

    func testAnInsertionTakesInTheSpaceNextToIt() {
        let original = "this is pen."
        let newText = "this is a pen."
        let spans = ReplaceSpans.spans(original: original, newText: newText, base: 0)
        XCTAssertEqual(spans, [ReplaceSpan(location: 7, old: " ", new: " a ")])
        assertSpans(spans, turn: original, into: newText, base: 0)
    }

    func testAnInsertionWithoutSpacesTakesInTheNextToken() {
        let original = "pen."
        let newText = "A pen."
        let spans = ReplaceSpans.spans(original: original, newText: newText, base: 0)
        XCTAssertEqual(spans, [ReplaceSpan(location: 0, old: "pen", new: "A pen")])
        assertSpans(spans, turn: original, into: newText, base: 0)
    }

    func testADeletionHasNothingToWrite() {
        let original = "this is is a pen"
        let newText = "this is a pen"
        let spans = ReplaceSpans.spans(original: original, newText: newText, base: 0)
        XCTAssertEqual(spans.count, 1)
        XCTAssertEqual(spans.first?.new, "")
        assertSpans(spans, turn: original, into: newText, base: 0)
    }

    func testAChineseTypoIsOneCharacter() {
        let spans = ReplaceSpans.spans(original: "請幫我看這個問提", newText: "請幫我看這個問題", base: 0)
        XCTAssertEqual(spans, [ReplaceSpan(location: 7, old: "提", new: "題")])
    }

    func testLocationsCountUTF16() {
        let spans = ReplaceSpans.spans(original: "👍 teh end", newText: "👍 the end", base: 10)
        XCTAssertEqual(spans, [ReplaceSpan(location: 13, old: "teh", new: "the")])
    }

    func testARewriteBecomesOneSpan() {
        let original = "x a x b x c x d x e x f x g x h x i x"
        let newText = "x A x B x C x D x E x F x G x H x I x"
        let spans = ReplaceSpans.spans(original: original, newText: newText, base: 0)
        XCTAssertEqual(spans, [ReplaceSpan(location: 2, old: "a x b x c x d x e x f x g x h x i", new: "A x B x C x D x E x F x G x H x I")])
        assertSpans(spans, turn: original, into: newText, base: 0)
    }

    func testIdenticalTextsHaveNoSpans() {
        XCTAssertEqual(ReplaceSpans.spans(original: "same text", newText: "same text", base: 0), [])
    }

    /// Writing the spans in order over the field must give the new text, and each must replace what is there.
    private func assertSpans(
        _ spans: [ReplaceSpan], turn original: String, into newText: String, base: Int,
        file: StaticString = #filePath, line: UInt = #line
    ) {
        let field = NSMutableString(string: String(repeating: "_", count: base) + original)
        for span in spans {
            let range = NSRange(location: span.location, length: (span.old as NSString).length)
            XCTAssertEqual(field.substring(with: range), span.old, file: file, line: line)
            XCTAssertFalse(span.old.isEmpty, file: file, line: line)
            field.replaceCharacters(in: range, with: span.new)
        }
        XCTAssertEqual(field as String, String(repeating: "_", count: base) + newText, file: file, line: line)
    }
}
