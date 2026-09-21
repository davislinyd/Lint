import Foundation

/// How alike two memories are, 0...1. Behind a protocol so that clustering does not depend on how
/// it is measured (and tests can fix the answers).
protocol MemorySimilarityService: Sendable {
    func similarity(_ lhs: WritingMemory, _ rhs: WritingMemory) async -> Double
}

/// Works offline and gives the same answer for the same memories on any Mac. Memories of one family
/// (see `MemoryFamily`) are the same shape by construction, however different their words; for
/// everything else it compares wording (`LexicalMemorySimilarity`).
///
/// Sentence embeddings are not used: the instructions are fixed templates, so they would rate any
/// two memories of a kind alike, and Apple has no Traditional Chinese model for them anyway.
struct StructuralMemorySimilarity: MemorySimilarityService {
    func similarity(_ lhs: WritingMemory, _ rhs: WritingMemory) async -> Double {
        if let family = MemoryFamily.of(lhs), family == MemoryFamily.of(rhs) { return 1 }
        return LexicalMemorySimilarity.score(lhs, rhs)
    }
}

enum LexicalMemorySimilarity {
    /// Overlap of the instructions' words and the memories' triggers. Habits have no triggers, and
    /// two of them are then compared by their instructions alone.
    static func score(_ lhs: WritingMemory, _ rhs: WritingMemory) -> Double {
        let instruction = jaccard(shingles(of: lhs.instruction), shingles(of: rhs.instruction))
        let (lhsTriggers, rhsTriggers) = (triggerSet(lhs), triggerSet(rhs))
        if lhsTriggers.isEmpty, rhsTriggers.isEmpty { return instruction }
        return 0.6 * instruction + 0.4 * jaccard(lhsTriggers, rhsTriggers)
    }

    /// Latin words, and pairs of neighbouring CJK characters (Chinese has no spaces to split on).
    static func shingles(of text: String) -> Set<String> {
        var result = Set<String>()
        var word = ""
        var previousCJK: Unicode.Scalar?
        func endWord() {
            if !word.isEmpty { result.insert(word) }
            word = ""
        }
        for scalar in text.lowercased().unicodeScalars {
            if Script.isCJK(scalar) {
                endWord()
                if let previousCJK { result.insert("\(previousCJK)\(scalar)") }
                previousCJK = scalar
            } else if CharacterSet.letters.contains(scalar) || scalar == "'" || scalar == "-" {
                previousCJK = nil
                word.unicodeScalars.append(scalar)
            } else {
                endWord()
                previousCJK = nil
            }
        }
        endWord()
        return result
    }

    private static func triggerSet(_ memory: WritingMemory) -> Set<String> {
        Set(memory.triggers.map { $0.lowercased().trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty })
    }

    private static func jaccard(_ lhs: Set<String>, _ rhs: Set<String>) -> Double {
        let union = lhs.union(rhs).count
        return union == 0 ? 0 : Double(lhs.intersection(rhs).count) / Double(union)
    }
}
