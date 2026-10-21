import Foundation

/// One changed piece of a replace: the text `old` at `location` (UTF-16, in the field) becomes `new`.
public struct ReplaceSpan: Equatable, Sendable {
    public let location: Int
    public let old: String
    public let new: String

    public init(location: Int, old: String, new: String) {
        self.location = location
        self.old = old
        self.new = new
    }
}

/// The pieces of a captured snippet that a suggestion changes. A rich-text field is written only there,
/// so its mentions, links and formatting outside them are left as they are.
public enum ReplaceSpans {
    /// Past this many pieces the snippet was rewritten rather than corrected: one span from the first
    /// change to the last, so a replace is not dozens of pastes and undo steps.
    static let maxSpans = 8

    /// The spans from the last to the first, so writing one leaves the locations of the others valid.
    /// `base` is where `original` starts in the field. Every span has text to replace, so the selection
    /// over it can be read back before anything is written. Identical texts give none.
    public static func spans(original: String, newText: String, base: Int) -> [ReplaceSpan] {
        let old = tokens(in: original)
        let new = tokens(in: newText)
        var hunks = merged(widened(hunks(from: old, to: new), old: old, new: new), old: old)
        guard hunks.allSatisfy({ !$0.old.isEmpty }) else { return [] }
        if hunks.count > maxSpans, let first = hunks.first, let last = hunks.last {
            hunks = [(first.old.lowerBound..<last.old.upperBound, first.new.lowerBound..<last.new.upperBound)]
        }
        var offsets = [0]
        for token in old { offsets.append(offsets[offsets.count - 1] + token.utf16.count) }
        return hunks.reversed().map { hunk in
            ReplaceSpan(
                location: base + offsets[hunk.old.lowerBound],
                old: old[hunk.old].joined(),
                new: new[hunk.new].joined()
            )
        }
    }

    private typealias Hunk = (old: Range<Int>, new: Range<Int>)
    private enum Run { case space, word }

    /// Runs of spaces, runs of letters and digits in spaced scripts (a word), and every other character
    /// on its own: a CJK character, a punctuation mark, a symbol or an emoji.
    static func tokens(in text: String) -> [String] {
        var tokens: [String] = []
        var current = ""
        var run: Run?
        for character in text {
            let kind: Run? = character.isWhitespace ? .space : (isWordCharacter(character) ? .word : nil)
            if let kind, kind == run {
                current.append(character)
                continue
            }
            if !current.isEmpty { tokens.append(current) }
            current = String(character)
            run = kind
        }
        if !current.isEmpty { tokens.append(current) }
        return tokens
    }

    private static func isWordCharacter(_ character: Character) -> Bool {
        (character.isLetter || character.isNumber) && !character.unicodeScalars.contains(where: Script.isCJK)
    }

    /// Spaces on one line: they hold no mention or link, so a span may reach over them.
    private static func isInlineSpace(_ token: String) -> Bool {
        token.allSatisfy { $0.isWhitespace && !$0.isNewline }
    }

    /// Consecutive changed tokens, in order. Each is preceded and followed by an unchanged token (or an end).
    private static func hunks(from old: [String], to new: [String]) -> [Hunk] {
        var removed = Set<Int>()
        var inserted = Set<Int>()
        for change in new.difference(from: old) {
            switch change {
            case .remove(let offset, _, _): removed.insert(offset)
            case .insert(let offset, _, _): inserted.insert(offset)
            }
        }
        var hunks: [Hunk] = []
        var i = 0
        var j = 0
        while i < old.count || j < new.count {
            if i < old.count, j < new.count, !removed.contains(i), !inserted.contains(j) {
                i += 1
                j += 1
                continue
            }
            let start = (old: i, new: j)
            while i < old.count, removed.contains(i) { i += 1 }
            while j < new.count, inserted.contains(j) { j += 1 }
            hunks.append((start.old..<i, start.new..<j))
        }
        return hunks
    }

    /// An insertion replaces nothing, so there is no selection to read back. Take in the unchanged token
    /// next to it: spaces first, since they carry no formatting.
    private static func widened(_ hunks: [Hunk], old: [String], new: [String]) -> [Hunk] {
        hunks.map { hunk in
            guard hunk.old.isEmpty else { return hunk }
            let before = hunk.old.lowerBound > 0 ? hunk.old.lowerBound - 1 : nil
            let after = hunk.old.upperBound < old.count ? hunk.old.upperBound : nil
            let takeBefore: Bool
            if let before, isInlineSpace(old[before]) {
                takeBefore = true
            } else if let after, isInlineSpace(old[after]) {
                takeBefore = false
            } else {
                takeBefore = before != nil
            }
            if takeBefore, let before {
                return (before..<hunk.old.upperBound, hunk.new.lowerBound - 1..<hunk.new.upperBound)
            }
            if let after {
                return (hunk.old.lowerBound..<after + 1, hunk.new.lowerBound..<hunk.new.upperBound + 1)
            }
            return hunk
        }
    }

    /// Join spans that only spaces on one line (or nothing) keep apart.
    private static func merged(_ hunks: [Hunk], old: [String]) -> [Hunk] {
        var result: [Hunk] = []
        for hunk in hunks {
            if let last = result.last, last.old.upperBound <= hunk.old.lowerBound,
               old[last.old.upperBound..<hunk.old.lowerBound].allSatisfy(isInlineSpace) {
                result[result.count - 1] = (
                    last.old.lowerBound..<hunk.old.upperBound, last.new.lowerBound..<hunk.new.upperBound
                )
            } else {
                result.append(hunk)
            }
        }
        return result
    }
}
