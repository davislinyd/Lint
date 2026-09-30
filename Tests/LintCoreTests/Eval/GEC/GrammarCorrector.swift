import Foundation

@testable import LintCore

/// What a correction came to.
struct GrammarCorrectionResult: Equatable, Sendable {
    var text: String
    /// Sentences given to the model.
    var corrected: Int
    /// Sentences the model's answer was not used for: it failed `WritingOutputGuard`'s checks.
    var keptSource: Int
    /// Sentences never sent: no English, or characters the model's vocabulary cannot write back.
    var skipped: Int
}

/// Proofreading with a GEC model: the text is cut into lines and sentences, each sentence the model
/// can read is corrected on its own, and the pieces are put back together with the text's own line
/// breaks, list markers and spacing. The T5 tokenizer turns line breaks into spaces and has no CJK,
/// no `{}<~` and no backtick, so a line is never sent whole and a sentence with those is left as is.
/// Every answer gets `WritingOutputGuard`'s preserve-tone proofreading checks; one that fails them
/// keeps the source sentence (the model is greedy, so asking again gives the same answer).
struct GrammarCorrector: Sendable {
    var provider: any GrammarCorrectionProvider

    init(provider: any GrammarCorrectionProvider) {
        self.provider = provider
    }

    /// The list marker a line may start with, kept out of the sentence the model sees.
    static let listMarker = try! NSRegularExpression(pattern: #"^([-*•]|\d+[.)])[ \t]+"#)
    /// Same as `WritingChunker`'s sentence break for Latin text.
    static let sentenceBreak = try! NSRegularExpression(pattern: #"[.!?]+["'”’)]*\s+"#)
    /// What the T5 vocabulary writes back unchanged, checked character by character with its
    /// SentencePiece model: printable ASCII except < \ ^ ` { } ~, plus these.
    static let readableCharacters = Set(
        (0x20...0x7E).map { Character(Unicode.Scalar(UInt8($0))) }.filter { !"<\\^`{}~".contains($0) }
    ).union("éèêàâçôûüöäÉÜßóáî’‘“”—–€£°•®")

    func correct(_ text: String) async throws -> GrammarCorrectionResult {
        var result = GrammarCorrectionResult(text: "", corrected: 0, keptSource: 0, skipped: 0)
        for (index, line) in text.components(separatedBy: "\n").enumerated() {
            if index > 0 { result.text += "\n" }
            for piece in Self.pieces(ofLine: line) {
                guard piece.isSentence else {
                    result.text += piece.text
                    continue
                }
                guard Self.isReadable(piece.text) else {
                    result.skipped += 1
                    result.text += piece.text
                    continue
                }
                try Task.checkCancellation()
                let answer = Self.keepingSpacing(
                    of: piece.text, in: WritingOutputGuard.tidy(try await provider.correct(piece.text), source: piece.text)
                )
                result.corrected += 1
                if WritingOutputGuard.assess(source: piece.text, output: answer, mode: .proofread, tone: .preserve).isEmpty {
                    result.text += answer
                } else {
                    result.keptSource += 1
                    result.text += piece.text
                }
            }
        }
        return result
    }

    struct Piece: Equatable {
        var text: String
        var isSentence: Bool
    }

    /// A line as leading space, list marker, sentences and the space between and after them, in
    /// order; joined, they are the line.
    static func pieces(ofLine line: String) -> [Piece] {
        var pieces: [Piece] = []
        var rest = Substring(line)
        let leading = rest.prefix { $0 == " " || $0 == "\t" }
        rest = rest.dropFirst(leading.count)
        var prefix = String(leading)
        let restString = String(rest)
        if let marker = listMarker.firstMatch(in: restString, range: NSRange(restString.startIndex..., in: restString)),
           let range = Range(marker.range, in: restString) {
            prefix += restString[range]
            rest = rest.dropFirst(restString.distance(from: restString.startIndex, to: range.upperBound))
        }
        if !prefix.isEmpty { pieces.append(Piece(text: prefix, isSentence: false)) }

        let body = String(rest)
        var start = body.startIndex
        var breaks = sentenceBreak.matches(in: body, range: NSRange(body.startIndex..., in: body))
            .compactMap { Range($0.range, in: body) }
        breaks.append(body.endIndex..<body.endIndex)
        for separator in breaks {
            // The punctuation stays with the sentence, the space after it does not.
            let space = body[separator].reversed().prefix { $0.isWhitespace }.count
            let end = body.index(separator.upperBound, offsetBy: -space)
            let sentence = body[start..<end]
            if !sentence.isEmpty { pieces.append(Piece(text: String(sentence), isSentence: true)) }
            let gap = body[end..<separator.upperBound]
            if !gap.isEmpty { pieces.append(Piece(text: String(gap), isSentence: false)) }
            start = separator.upperBound
        }
        // Trailing space on a sentence without a break after it ("Hi there  ") stays outside.
        if let last = pieces.last, last.isSentence {
            let trailing = String(last.text.reversed().prefix { $0.isWhitespace }.reversed())
            if !trailing.isEmpty {
                pieces[pieces.count - 1].text = String(last.text.dropLast(trailing.count))
                pieces.append(Piece(text: trailing, isSentence: false))
            }
        }
        return pieces
    }

    /// The model's answer with the spaces it put inside words taken out. T5 writes text back from
    /// word pieces and splits what it does not know ("Q4" → "Q 4", "HTTP/2" → "HTTP /2",
    /// "config/settings.prod.yaml" → "config / settings. prod. yaml"). Words are compared, not
    /// characters: where the answer has the same characters as the source split into words
    /// differently, the source's spacing is kept, unless every difference is one a proofread makes:
    /// splitting or joining letters ("alot" → "a lot"), or a space before punctuation moved after it
    /// ("fix ,tested" → "fix, tested").
    static func keepingSpacing(of source: String, in answer: String) -> String {
        let a = words(source), b = words(answer)
        guard a.count * b.count <= 250_000 else { return answer }
        // Longest common subsequence of words, then each run of differing words on its own.
        var table = Array(repeating: Array(repeating: 0, count: b.count + 1), count: a.count + 1)
        for i in stride(from: a.count - 1, through: 0, by: -1) {
            for j in stride(from: b.count - 1, through: 0, by: -1) {
                table[i][j] = a[i].text == b[j].text ? table[i + 1][j + 1] + 1 : max(table[i + 1][j], table[i][j + 1])
            }
        }
        var result = ""
        var removed: [Word] = [], inserted: [Word] = []
        func flush() {
            result += respaced(removed, inserted)
            removed = []
            inserted = []
        }
        var i = 0, j = 0
        while i < a.count || j < b.count {
            if i < a.count, j < b.count, a[i].text == b[j].text {
                flush()
                result += b[j].text + b[j].space
                i += 1
                j += 1
            } else if j < b.count, i == a.count || table[i][j + 1] >= table[i + 1][j] {
                inserted.append(b[j])
                j += 1
            } else {
                removed.append(a[i])
                i += 1
            }
        }
        flush()
        return String(answer.prefix { $0.isWhitespace }) + result
    }

    /// A word and the whitespace after it.
    struct Word {
        var text: String
        var space: String
    }

    static func words(_ text: String) -> [Word] {
        var words: [Word] = []
        for character in text.drop(while: \.isWhitespace) {
            if character.isWhitespace {
                words[words.count - 1].space.append(character)
            } else if let last = words.last, last.space.isEmpty {
                words[words.count - 1].text.append(character)
            } else {
                words.append(Word(text: String(character), space: ""))
            }
        }
        return words
    }

    /// What replaces `removed` source words: the answer's words, with the source's spacing restored
    /// on every leading and trailing group of words whose letters are the same.
    static func respaced(_ removed: [Word], _ inserted: [Word]) -> String {
        func text(_ words: ArraySlice<Word>) -> String { words.map { $0.text + $0.space }.joined() }
        var r = removed[...], i = inserted[...]
        var head = "", tail = ""
        // Leading groups.
        while let (x, y) = firstGroup(r, i) {
            head += isProofreadSpacing(r.prefix(x), i.prefix(y)) ? text(i.prefix(y)) : restoredText(r.prefix(x), i.prefix(y))
            r = r.dropFirst(x)
            i = i.dropFirst(y)
        }
        // Trailing groups.
        while let (x, y) = firstGroup(ArraySlice(r.reversed()), ArraySlice(i.reversed()), reversed: true) {
            tail = (isProofreadSpacing(r.suffix(x), i.suffix(y)) ? text(i.suffix(y)) : restoredText(r.suffix(x), i.suffix(y))) + tail
            r = r.dropLast(x)
            i = i.dropLast(y)
        }
        return head + text(i) + tail
    }

    /// The source words, followed by the whitespace the answer put after the group.
    static func restoredText(_ removed: ArraySlice<Word>, _ inserted: ArraySlice<Word>) -> String {
        guard let last = inserted.last else { return "" }
        return removed.dropLast().map { $0.text + $0.space }.joined() + (removed.last?.text ?? "") + last.space
    }

    /// The fewest words from the start of each list whose characters, spaces aside, are the same.
    static func firstGroup(_ r: ArraySlice<Word>, _ i: ArraySlice<Word>, reversed: Bool = false) -> (Int, Int)? {
        var x = 0, y = 0
        var left = "", right = ""
        while true {
            if !left.isEmpty, left == right { return (x, y) }
            if left.count <= right.count {
                guard x < r.count else { return nil }
                left = reversed ? r[r.startIndex + x].text + left : left + r[r.startIndex + x].text
                x += 1
            } else {
                guard y < i.count else { return nil }
                right = reversed ? i[i.startIndex + y].text + right : right + i[i.startIndex + y].text
                y += 1
            }
            let (shorter, longer) = left.count <= right.count ? (left, right) : (right, left)
            if reversed ? !longer.hasSuffix(shorter) : !longer.hasPrefix(shorter) { return nil }
        }
    }

    /// Whether the answer splits the same characters into words only where a proofread would.
    static func isProofreadSpacing(_ removed: ArraySlice<Word>, _ inserted: ArraySlice<Word>) -> Bool {
        func breaks(_ words: ArraySlice<Word>) -> Set<Int> {
            var offsets = Set<Int>(), offset = 0
            for word in words.dropLast() {
                offset += word.text.count
                offsets.insert(offset)
            }
            return offsets
        }
        let characters = Array(removed.map(\.text).joined())
        let before = breaks(removed), after = breaks(inserted)
        let punctuation = Set(",.;:!?")
        return before.symmetricDifference(after).allSatisfy { offset in
            let previous = characters[offset - 1], next = characters[offset]
            if previous.isLetter, next.isLetter { return true }
            // "fix ,tested" → "fix, tested": the space before the mark goes after it.
            if before.contains(offset), punctuation.contains(next) { return true }
            if after.contains(offset), punctuation.contains(previous), before.contains(offset - 1) { return true }
            return false
        }
    }

    /// English, and nothing the model would have to replace with an unknown token.
    static func isReadable(_ sentence: String) -> Bool {
        TextScript.hasEnglish(sentence) && sentence.allSatisfy(readableCharacters.contains)
    }
}
