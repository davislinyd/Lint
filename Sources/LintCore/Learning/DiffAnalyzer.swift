import Foundation
import NaturalLanguage

/// A word as written, plus what the extractor needs to judge whether it is safe to remember.
struct WordToken: Equatable, Sendable {
    let text: String
    /// Lower-cased. Diffs compare keys, so a capitalisation change is not an edit.
    let key: String
    let isSentenceStart: Bool
    /// Stuck to symbols such as `@`, `/` or `.com`: part of an address, path or code.
    let isGlued: Bool
    /// Tagged as a person, place or organisation.
    let isName: Bool

    var isCJK: Bool {
        text.unicodeScalars.contains { scalar in
            switch scalar.value {
            case 0x4E00...0x9FFF, 0x3400...0x4DBF, 0xF900...0xFAFF, 0x3040...0x30FF: true
            default: false
            }
        }
    }
}

/// One place where two texts differ, with the unchanged words on either side.
struct EditSpan: Equatable, Sendable {
    let removed: [WordToken]
    let added: [WordToken]
    /// Up to two unchanged words before and after, never reaching into a neighbouring span.
    let before: [WordToken]
    let after: [WordToken]
}

enum DiffAnalyzer {
    /// Past this many differing words on a side, the two texts are treated as unrelated.
    static let maxMiddleTokens = 1_200

    private static let glue: Set<Character> = ["@", "#", "/", "\\", "_", "~", "=", "+", "<", ">", "|", "^", "*"]
    private static let sentenceEnders: Set<Character> = [".", "!", "?", "。", "！", "？", "…"]

    static func tokens(in text: String) -> [WordToken] {
        let tokenizer = NLTokenizer(unit: .word)
        tokenizer.string = text
        var ranges: [Range<String.Index>] = []
        tokenizer.enumerateTokens(in: text.startIndex..<text.endIndex) { range, _ in
            ranges.append(range)
            return true
        }
        let names = nameRanges(in: text)
        return ranges.map { range in
            let word = String(text[range])
            return WordToken(
                text: word,
                key: word.lowercased(),
                isSentenceStart: startsSentence(at: range.lowerBound, in: text),
                isGlued: isGlued(range, in: text),
                isName: names.contains { $0.overlaps(range) }
            )
        }
    }

    /// The differences between two token sequences, in order. Identical sequences, or ones that
    /// differ too much to compare, give none.
    static func spans(from old: [WordToken], to new: [WordToken]) -> [EditSpan] {
        var head = 0
        while head < old.count, head < new.count, old[head].key == new[head].key {
            head += 1
        }
        var tail = 0
        while tail < old.count - head, tail < new.count - head,
              old[old.count - 1 - tail].key == new[new.count - 1 - tail].key {
            tail += 1
        }
        let n = old.count - tail - head
        let m = new.count - tail - head
        guard n > 0 || m > 0, n <= maxMiddleTokens, m <= maxMiddleTokens else { return [] }

        // table[i][j] = length of the longest common subsequence of old[i...] and new[j...].
        let width = m + 1
        var table = [UInt16](repeating: 0, count: (n + 1) * width)
        if n > 0, m > 0 {
            for i in stride(from: n - 1, through: 0, by: -1) {
                for j in stride(from: m - 1, through: 0, by: -1) {
                    table[i * width + j] = old[head + i].key == new[head + j].key
                        ? table[(i + 1) * width + j + 1] + 1
                        : max(table[(i + 1) * width + j], table[i * width + j + 1])
                }
            }
        }

        var ranges: [(old: Range<Int>, new: Range<Int>)] = []
        var i = 0
        var j = 0
        var open: (old: Int, new: Int)?
        while i < n || j < m {
            if i < n, j < m, old[head + i].key == new[head + j].key {
                if let start = open {
                    ranges.append((head + start.old..<head + i, head + start.new..<head + j))
                    open = nil
                }
                i += 1
                j += 1
                continue
            }
            if open == nil { open = (i, j) }
            let dropOld = j >= m || (i < n && table[(i + 1) * width + j] >= table[i * width + j + 1])
            if dropOld { i += 1 } else { j += 1 }
        }
        if let start = open {
            ranges.append((head + start.old..<head + i, head + start.new..<head + j))
        }

        return ranges.enumerated().compactMap { index, range in
            let floor = index > 0 ? ranges[index - 1].old.upperBound : 0
            let ceiling = index + 1 < ranges.count ? ranges[index + 1].old.lowerBound : old.count
            return refined(EditSpan(
                removed: Array(old[range.old]),
                added: Array(new[range.new]),
                before: Array(old[max(floor, range.old.lowerBound - 2)..<range.old.lowerBound]),
                after: Array(old[range.old.upperBound..<min(ceiling, range.old.upperBound + 2)])
            ))
        }
    }

    /// The tokenizer segments Chinese differently in an edited text than in the original, so a
    /// span can drag unchanged neighbours along ("這個" vs "這", "個"). Trim it to the characters
    /// that really differ, then widen back to the whole words that contain them. A span whose
    /// text turns out identical is dropped.
    private static func refined(_ span: EditSpan) -> EditSpan? {
        guard (span.removed + span.added).contains(where: \.isCJK) else { return span }
        let old = Array(span.removed.map(\.key).joined())
        let new = Array(span.added.map(\.key).joined())
        var head = 0
        while head < old.count, head < new.count, old[head] == new[head] { head += 1 }
        var tail = 0
        while tail < old.count - head, tail < new.count - head,
              old[old.count - 1 - tail] == new[new.count - 1 - tail] { tail += 1 }
        let oldCore = head..<(old.count - tail)
        let newCore = head..<(new.count - tail)
        if oldCore.isEmpty, newCore.isEmpty { return nil }
        return EditSpan(
            removed: covering(oldCore, in: span.removed),
            added: covering(newCore, in: span.added),
            before: span.before,
            after: span.after
        )
    }

    /// The tokens holding any of the characters in `core` (offsets into the tokens' joined keys).
    private static func covering(_ core: Range<Int>, in tokens: [WordToken]) -> [WordToken] {
        guard !core.isEmpty else { return [] }
        var offset = 0
        return tokens.filter { token in
            defer { offset += token.key.count }
            return offset < core.upperBound && offset + token.key.count > core.lowerBound
        }
    }

    /// Most of the text changed: a rewrite, not a set of small habits worth learning from.
    static func isRewrite(_ spans: [EditSpan], oldCount: Int, newCount: Int) -> Bool {
        let changed = spans.reduce(0) { $0 + $1.removed.count + $1.added.count }
        return changed >= 6 && Double(changed) > 0.4 * Double(oldCount + newCount)
    }

    private static func nameRanges(in text: String) -> [Range<String.Index>] {
        let tagger = NLTagger(tagSchemes: [.nameType])
        tagger.string = text
        var ranges: [Range<String.Index>] = []
        tagger.enumerateTags(
            in: text.startIndex..<text.endIndex,
            unit: .word,
            scheme: .nameType,
            options: [.omitPunctuation, .omitWhitespace, .joinNames]
        ) { tag, range in
            if let tag, tag == .personalName || tag == .placeName || tag == .organizationName {
                ranges.append(range)
            }
            return true
        }
        return ranges
    }

    private static func startsSentence(at index: String.Index, in text: String) -> Bool {
        var position = index
        while position > text.startIndex {
            let previous = text.index(before: position)
            let character = text[previous]
            if character == "\n" { return true }
            if character == " " || character == "\t" || character == "\u{3000}" {
                position = previous
                continue
            }
            return sentenceEnders.contains(character)
        }
        return true
    }

    private static func isGlued(_ range: Range<String.Index>, in text: String) -> Bool {
        if range.lowerBound > text.startIndex {
            let dot = text.index(before: range.lowerBound)
            if glue.contains(text[dot]) { return true }
            // The "com" of "acme.com", the "txt" of "notes.txt".
            if text[dot] == ".", dot > text.startIndex {
                let beforeDot = text[text.index(before: dot)]
                if beforeDot.isLetter || beforeDot.isNumber { return true }
            }
        }
        guard range.upperBound < text.endIndex else { return false }
        let next = text[range.upperBound]
        if glue.contains(next) { return true }
        let afterNext = text.index(after: range.upperBound)
        guard afterNext < text.endIndex else { return false }
        if next == ":" { return text[afterNext] == "/" }
        if next == "." { return text[afterNext].isLetter || text[afterNext].isNumber }
        return false
    }
}
