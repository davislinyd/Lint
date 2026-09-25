import Foundation

/// The fixed wordings of the memories Lint writes itself. The Chinese one is what is stored and shown
/// in Settings; the English one is what an English prompt gets, so that it carries no Chinese
/// sentence (a Chinese line once made Apple's model answer English text in Chinese). Text the user
/// wrote is neither, and is used as written.
enum MemoryWording: Equatable, Sendable {
    case articles
    case preferredSpelling(wrong: String, right: String)
    case misspelling(wrong: String, right: String)
    case extraPreposition(verb: String, preposition: String)
    case preferredReplacement(from: String, to: String)
    case acceptedReplacement(from: String, to: String)
    case terminology(from: String, to: String)
    case redundantPrepositions

    var chinese: String {
        switch self {
        case .articles:
            "英文常漏用或誤用冠詞（a／an／the）：請特別檢查單數可數名詞前的冠詞。"
        case .preferredSpelling(let wrong, let right):
            "使用者偏好「\(right)」而非「\(wrong)」。"
        case .misspelling(let wrong, let right):
            "使用者常把「\(right)」誤寫成「\(wrong)」；原文出現「\(wrong)」時請確認是否應為「\(right)」，僅在語意符合時修正。"
        case .extraPreposition(let verb, let preposition):
            "「\(verb) \(preposition)」中的「\(preposition)」有時是多餘的（使用者曾刪掉）；請確認是否應寫成「\(verb)」，僅在語意需要時修正。"
        case .preferredReplacement(let from, let to):
            "使用者偏好用「\(to)」取代「\(from)」。"
        case .acceptedReplacement(let from, let to):
            "使用者接受過把「\(from)」改成「\(to)」；原文出現「\(from)」時可考慮這樣改。"
        case .terminology(let from, let to):
            "用詞：請用「\(to)」，不要用「\(from)」。"
        case .redundantPrepositions:
            "英文常在動詞後多加不必要的介系詞（如 discuss about）：請特別檢查動詞後的介系詞是否多餘，僅在語意不需要時才刪除。"
        }
    }

    var english: String {
        switch self {
        case .articles:
            "This user often leaves out or misuses articles (a, an, the): check the article before every singular countable noun."
        case .preferredSpelling(let wrong, let right):
            "This user prefers \"\(right)\" to \"\(wrong)\"."
        case .misspelling(let wrong, let right):
            "This user often misspells \"\(right)\" as \"\(wrong)\": where the text has \"\(wrong)\", check whether \"\(right)\" is meant, and fix it only then."
        case .extraPreposition(let verb, let preposition):
            "\"\(preposition)\" in \"\(verb) \(preposition)\" is sometimes not needed (this user has removed it): check whether \"\(verb)\" alone is right, and change it only where the meaning allows."
        case .preferredReplacement(let from, let to):
            "This user prefers \"\(to)\" to \"\(from)\"."
        case .acceptedReplacement(let from, let to):
            "This user has accepted \"\(from)\" changed to \"\(to)\"; where the text has \"\(from)\", consider the same change."
        case .terminology(let from, let to):
            "Wording: use \"\(to)\", not \"\(from)\"."
        case .redundantPrepositions:
            "This user often puts an unneeded preposition after a verb (such as \"discuss about\"): check the preposition after each verb, and remove it only where the meaning does not need it."
        }
    }

    /// The wording a stored instruction was written in, nil for anything else (the user's own text).
    init?(chinese instruction: String) {
        for (shape, make) in Self.shapes {
            if let values = Self.values(in: instruction, shapedLike: shape.chinese) {
                self = make(values)
                return
            }
        }
        return nil
    }

    /// Every wording with placeholders for its words, and how to rebuild it from them.
    private static let placeholders: [Character] = ["\u{1}", "\u{2}"]
    private static let shapes: [(MemoryWording, @Sendable ([String]) -> MemoryWording)] = [
        (.articles, { _ in .articles }),
        (.preferredSpelling(wrong: "\u{1}", right: "\u{2}"), { .preferredSpelling(wrong: $0[0], right: $0[1]) }),
        (.misspelling(wrong: "\u{1}", right: "\u{2}"), { .misspelling(wrong: $0[0], right: $0[1]) }),
        (.extraPreposition(verb: "\u{1}", preposition: "\u{2}"), { .extraPreposition(verb: $0[0], preposition: $0[1]) }),
        (.preferredReplacement(from: "\u{1}", to: "\u{2}"), { .preferredReplacement(from: $0[0], to: $0[1]) }),
        (.acceptedReplacement(from: "\u{1}", to: "\u{2}"), { .acceptedReplacement(from: $0[0], to: $0[1]) }),
        (.terminology(from: "\u{1}", to: "\u{2}"), { .terminology(from: $0[0], to: $0[1]) }),
        (.redundantPrepositions, { _ in .redundantPrepositions }),
    ]

    /// The words standing where `template` has its placeholders, if `text` is `template` filled in.
    /// A placeholder that appears twice must stand for the same word both times.
    private static func values(in text: String, shapedLike template: String) -> [String]? {
        var pattern = ""
        var groupOf: [Character: Int] = [:]
        for character in template {
            if placeholders.contains(character) {
                if let group = groupOf[character] {
                    pattern += "\\\(group)"
                } else {
                    groupOf[character] = groupOf.count + 1
                    pattern += "([^「」\"]+?)"
                }
            } else {
                pattern += NSRegularExpression.escapedPattern(for: String(character))
            }
        }
        guard let regex = try? NSRegularExpression(pattern: "^" + pattern + "$"),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text))
        else { return nil }
        return placeholders.compactMap { placeholder in
            groupOf[placeholder].flatMap { Range(match.range(at: $0), in: text) }.map { String(text[$0]) }
        }
    }
}
