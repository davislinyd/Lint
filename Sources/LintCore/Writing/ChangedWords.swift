import Foundation

/// The words of a result that the panel marks as changed.
public enum ChangedWords {
    /// Indexes of the words of `result` (split at spaces) that are not in `original`. A straight and
    /// a typographic quote are the same word ("that’s", "that's"): macOS's smart quotes turn what is
    /// typed in the panel into ’ and “ ”, and models write either (as `WordToken.key` has it).
    /// Capitalisation still counts.
    public static func inserted(original: String, result: String) -> Set<Int> {
        let old = original.split(separator: " ", omittingEmptySubsequences: false).map(key)
        let new = result.split(separator: " ", omittingEmptySubsequences: false).map(key)
        var inserted = Set<Int>()
        for case .insert(let offset, _, _) in new.difference(from: old) {
            inserted.insert(offset)
        }
        return inserted
    }

    private static func key(_ word: Substring) -> String {
        String(word.map { character in
            if WordToken.typographicApostrophes.contains(character) { return "'" }
            if character == "\u{201C}" || character == "\u{201D}" { return "\"" }
            return character
        })
    }
}
