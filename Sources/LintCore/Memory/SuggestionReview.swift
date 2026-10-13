import Foundation

/// What became of the changes a suggestion made, judged by the text that was sent in the end
/// (observation mode). Pure, and it keeps nothing.
enum SuggestionReview {
    enum Verdict: Equatable, Sendable {
        /// The sent text has the suggestion's words there.
        case kept
        /// The sent text still has the original's words there, untouched.
        case rejected
        /// Something else stands there now, or the place was edited too closely to tell.
        case unclear
    }

    struct Change: Equatable, Sendable {
        /// The change the suggestion made: the original's words it removed, and its own.
        let span: EditSpan
        let verdict: Verdict
    }

    /// Every change `suggestion` made to `original`, with what `sent` shows of it. Empty when there
    /// is nothing to judge: the suggestion changed nothing or rewrote the text, or `sent` is no
    /// longer the original with a few edits.
    ///
    /// A change is only `rejected` when nothing in `sent` differs from the original at or next to
    /// it. So a change at the very end, where the last words of `sent` may be missing or more may
    /// have been typed, is never taken for a rejection unless the end is as it was.
    static func changes(original: String, suggestion: String, sent: String) -> [Change] {
        let old = DiffAnalyzer.tokens(in: original)
        let suggested = DiffAnalyzer.tokens(in: suggestion)
        let model = DiffAnalyzer.locatedSpans(from: old, to: suggested)
        guard !model.isEmpty,
              !DiffAnalyzer.isRewrite(model.map(\.span), oldCount: old.count, newCount: suggested.count)
        else { return [] }

        let final = DiffAnalyzer.tokens(in: sent)
        let user = DiffAnalyzer.locatedSpans(from: old, to: final)
        // No differences can also mean too many to compare.
        if user.isEmpty, old.map(\.key) != final.map(\.key) { return [] }
        guard !DiffAnalyzer.isRewrite(user.map(\.span), oldCount: old.count, newCount: final.count) else { return [] }

        return model.map { change in
            let near = user.filter { touches($0.oldRange, change.oldRange) }
            let verdict: Verdict
            if near.isEmpty {
                verdict = .rejected
            } else if near.count == 1, near[0].oldRange == change.oldRange,
                      near[0].span.added.map(\.key) == change.span.added.map(\.key) {
                verdict = .kept
            } else {
                verdict = .unclear
            }
            return Change(span: change.span, verdict: verdict)
        }
    }

    /// Overlapping or side by side. A range is empty where words were only added.
    private static func touches(_ lhs: Range<Int>, _ rhs: Range<Int>) -> Bool {
        lhs.lowerBound <= rhs.upperBound && rhs.lowerBound <= lhs.upperBound
    }
}
