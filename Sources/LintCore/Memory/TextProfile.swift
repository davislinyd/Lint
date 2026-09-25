import Foundation
import NaturalLanguage

enum Script {
    static func isCJK(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x4E00...0x9FFF, 0x3400...0x4DBF, 0xF900...0xFAFF, 0x3040...0x30FF: true
        default: false
        }
    }
}

/// Which scripts a text is written in, to tell which memories can apply to it. The tokenizer's own
/// language recognizer is not used for this: it calls "請幫我 check 這個 issue" English.
struct TextProfile: Sendable {
    let latinLetters: Int
    let cjkCharacters: Int
    /// `zh-Hant` or `zh-Hans`; nil when the text has no CJK or the variant is unclear.
    let chineseVariant: String?

    init(_ text: String) {
        var latin = 0
        var cjk = ""
        var cjkCount = 0
        for scalar in text.unicodeScalars {
            if (0x41...0x5A).contains(scalar.value) || (0x61...0x7A).contains(scalar.value) {
                latin += 1
            } else if Script.isCJK(scalar) {
                cjk.unicodeScalars.append(scalar)
                cjkCount += 1
            }
        }
        latinLetters = latin
        cjkCharacters = cjkCount
        chineseVariant = cjkCount > 0 ? Self.chineseVariant(of: cjk) : nil
    }

    /// The language shows up in the text at all. Enough for a memory whose trigger was found in it.
    func mentions(_ language: String) -> Bool {
        switch language {
        case "en": latinLetters > 0
        case "zh-Hant", "zh-Hans": cjkCharacters > 0
        default: false
        }
    }

    /// The text is mostly in the language. Needed for a habit, which has no trigger to show that
    /// it is relevant.
    func dominates(_ language: String) -> Bool {
        switch language {
        case "en":
            latinLetters >= MemoryPolicy.minHabitLatinLetters && latinLetters >= cjkCharacters
        case "zh-Hant", "zh-Hans":
            cjkCharacters >= MemoryPolicy.minHabitCJKCharacters
                && cjkCharacters * 2 >= latinLetters && chineseVariant == language
        default:
            false
        }
    }

    static func chineseVariant(of text: String) -> String? {
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(text)
        switch recognizer.dominantLanguage {
        case .simplifiedChinese: return "zh-Hans"
        case .traditionalChinese: return "zh-Hant"
        default: return nil
        }
    }
}
