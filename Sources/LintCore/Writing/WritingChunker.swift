import Foundation

/// Splits a text too long for a small model's context into pieces that are processed one at a time.
/// Deterministic, and lossless: the pieces joined back together are exactly the text, with every
/// separator (blank lines, line breaks, spaces) left in the piece before it, so formatting survives.
/// It splits between paragraphs first, then lines, then sentences, then words; nothing is truncated.
public enum WritingChunker {
    /// Separators to split after, from the most natural break to the least.
    static let separatorPatterns = [
        #"\n[ \t]*\n\s*"#, // paragraphs
        #"\n"#, // lines
        #"[.!?]+["'”’)]*\s+|[。！？]+[」』）]*\s*"#, // sentences (a Latin one needs a space after it: not "example.com")
        #"\s+"#, // words
    ]

    /// A rough, deliberately high estimate of tokens: one per CJK character, one per three other
    /// characters. It only decides where to split; a piece that still does not fit is split again
    /// when the model says so (`WritingPipeline`).
    public static func estimatedTokens(_ text: String) -> Int {
        var cjk = 0
        var other = 0
        for scalar in text.unicodeScalars {
            if isCJK(scalar) { cjk += 1 } else if !scalar.properties.isWhitespace { other += 1 }
        }
        return cjk + (other + 2) / 3
    }

    /// Pieces of at most `maxTokens` estimated tokens (unless a single character is larger), whose
    /// concatenation is `text`.
    public static func chunks(_ text: String, maxTokens: Int) -> [String] {
        let limit = max(maxTokens, 1)
        guard estimatedTokens(text) > limit else { return [text] }
        return split(Substring(text), level: 0, limit: limit).map(String.init)
    }

    private static func split(_ text: Substring, level: Int, limit: Int) -> [Substring] {
        guard estimatedTokens(String(text)) > limit else { return [text] }
        guard level < separatorPatterns.count else { return splitByCharacters(text, limit: limit) }
        let units = pieces(of: text, after: separatorPatterns[level])
        if units.count == 1 { return split(text, level: level + 1, limit: limit) }
        var result: [Substring] = []
        var current: Substring?
        for unit in units {
            if estimatedTokens(String(unit)) > limit {
                if let pending = current { result.append(pending); current = nil }
                result += split(unit, level: level + 1, limit: limit)
                continue
            }
            if let pending = current {
                let joined = text[pending.startIndex..<unit.endIndex]
                if estimatedTokens(String(joined)) <= limit {
                    current = joined
                } else {
                    result.append(pending)
                    current = unit
                }
            } else {
                current = unit
            }
        }
        if let pending = current { result.append(pending) }
        return result
    }

    /// `text` cut after every match of `pattern`; the matched separator stays with the piece before it.
    private static func pieces(of text: Substring, after pattern: String) -> [Substring] {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [text] }
        let string = String(text)
        var result: [Substring] = []
        var start = text.startIndex
        for match in regex.matches(in: string, range: NSRange(string.startIndex..., in: string)) {
            guard let range = Range(match.range, in: string), !range.isEmpty else { continue }
            let offset = string.distance(from: string.startIndex, to: range.upperBound)
            let end = text.index(text.startIndex, offsetBy: offset)
            if end > start {
                result.append(text[start..<end])
                start = end
            }
        }
        if start < text.endIndex { result.append(text[start..<text.endIndex]) }
        return result.isEmpty ? [text] : result
    }

    private static func splitByCharacters(_ text: Substring, limit: Int) -> [Substring] {
        var result: [Substring] = []
        var start = text.startIndex
        var index = start
        while index < text.endIndex {
            let next = text.index(after: index)
            if estimatedTokens(String(text[start..<next])) > limit, index > start {
                result.append(text[start..<index])
                start = index
            }
            index = next
        }
        result.append(text[start..<text.endIndex])
        return result
    }

    static func isCJK(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x3040...0x30FF, 0x3400...0x4DBF, 0x4E00...0x9FFF, 0xAC00...0xD7AF, 0xF900...0xFAFF, 0xFF00...0xFFEF:
            return true
        default:
            return false
        }
    }
}

/// How much source text one request may carry, from the model's real context size.
public struct WritingChunkBudget: Equatable, Sendable {
    public var contextSize: Int
    public var instructionTokens: Int

    public init(contextSize: Int, instructions: String) {
        self.contextSize = contextSize
        self.instructionTokens = WritingChunker.estimatedTokens(instructions)
    }

    /// The context holds the instructions, the text, and the answer, which for a translation into
    /// Chinese can be longer than the text: so the text gets 40% of what is left after a margin.
    public var maxInputTokens: Int {
        max(64, (contextSize - instructionTokens - 128) * 2 / 5)
    }
}
