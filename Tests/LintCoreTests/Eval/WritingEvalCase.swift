import Foundation

@testable import LintCore

/// One fixture: a piece of text, the task to run on it, and the properties a good answer must have
/// whichever engine produced it. Fixtures live in `WritingEvalFixtures.json` and were written for
/// this repository — no benchmark corpus is involved.
struct WritingEvalCase: Decodable {
    enum Language: String, Decodable {
        case en, zhHant = "zh-Hant", mixed, any
    }

    var id: String
    var category: String
    /// `proofread` or `translate`; the raw value of `WritingMode`.
    var mode: String
    /// The raw value of `WritingTone`.
    var tone: String
    var translateTarget: String?
    var input: String
    var outputLanguage: Language
    /// Substrings that have to come out the other side untouched: numbers, URLs, names, commands.
    var mustPreserve: [String]?
    /// The text is already right, so the answer should be the same text.
    var expectUnchanged: Bool?
    /// A list or an email: the lines have to survive.
    var preserveLineStructure: Bool?
    /// For the human reading the report; nothing checks it.
    var note: String

    var writingMode: WritingMode { WritingMode(rawValue: mode) ?? .proofread }
    var writingTone: WritingTone { WritingTone(rawValue: tone) ?? .preserve }

    /// Exactly the system prompt the app sends for this case with the given engine. The standard
    /// one has the bubble's "bare text only" line, as a selection suggestion does.
    func systemPrompt(profile: WritingPromptProfile) -> String {
        let prompt = WritingPromptComposer.compose(
            mode: writingMode, tone: writingTone, customPrompt: "",
            translateTarget: translateTarget ?? "繁體中文", profile: profile
        )
        return profile == .standard ? prompt + "\n回覆只要修正後的全文，不要解釋。" : prompt
    }
}

struct WritingEvalFixtures: Decodable {
    var version: Int
    var about: String
    var cases: [WritingEvalCase]

    static func load() throws -> WritingEvalFixtures {
        let url = TestSupport.repoRoot
            .appendingPathComponent("Tests/LintCoreTests/Eval/WritingEvalFixtures.json")
        return try JSONDecoder().decode(WritingEvalFixtures.self, from: Data(contentsOf: url))
    }
}

/// What can be decided without an opinion. Anything about whether the rewrite is *good* (a grammar
/// error left in, a meaning changed) is left to a person reading the report: a made-up score would
/// only look like evidence.
enum WritingEvalChecks {
    struct Failure: Equatable {
        var check: String
        var detail: String
    }

    /// Openings that mean the model started talking to the user instead of returning the text.
    static let preambles = [
        "here is", "here's", "sure,", "sure!", "certainly", "of course", "i've ", "i have ",
        "the corrected", "corrected version", "revised version", "translation:",
        "以下是", "這是修正", "修改如下", "修正後", "翻譯如下", "好的，", "當然",
    ]

    /// Characters that exist only in Simplified Chinese, common in Lint's kind of text. Finding one
    /// in Traditional Chinese output is a hard error.
    static let simplifiedOnly = Set("这们说为时会发过对还没应该个来务员统网络设计软数库实现问题请让项际从关进与页开边写档给认确间简体见线运维险证码类专业单击载览众阶层报导师亲导习惯")

    /// Mainland terms where Taiwan uses another word (Traditional characters, wrong vocabulary).
    static let mainlandTerms = ["軟件", "信息", "網絡", "服務器", "默認", "視頻", "數據庫", "硬盤", "內存", "鏈接", "屏幕", "質量", "設置", "訪問", "網關"]

    static func run(_ testCase: WritingEvalCase, output raw: String) -> [Failure] {
        var failures: [Failure] = []
        let output = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let input = testCase.input.trimmingCharacters(in: .whitespacesAndNewlines)

        if output.isEmpty {
            return [Failure(check: "non-empty", detail: "the model returned nothing")]
        }
        for tag in ["<think>", "</think>", "<thinking>", "◁think▷"] where raw.contains(tag) {
            failures.append(Failure(check: "no-thinking", detail: "output contains \(tag)"))
        }
        let opening = output.prefix(40).lowercased()
        let inputOpening = input.prefix(40).lowercased()
        // "I've attached…" is only a preamble when the text did not start that way itself.
        if let hit = preambles.first(where: { opening.hasPrefix($0) && !inputOpening.hasPrefix($0) }) {
            failures.append(Failure(check: "no-preamble", detail: "starts with \"\(hit)\""))
        }
        if !input.contains("```"), output.contains("```") {
            failures.append(Failure(check: "no-added-code-fence", detail: "the model wrapped the answer in a fence"))
        }
        for token in testCase.mustPreserve ?? [] where !output.contains(token) {
            failures.append(Failure(check: "preserves", detail: "\(token) is missing"))
        }
        if let detail = languageFailure(testCase.outputLanguage, in: output) {
            failures.append(Failure(check: "language", detail: detail))
        }
        if testCase.outputLanguage == .zhHant || testCase.outputLanguage == .mixed {
            let simplified = output.filter { simplifiedOnly.contains($0) }
            if !simplified.isEmpty {
                failures.append(Failure(check: "simplified-chinese", detail: String(Set(simplified)).sorted().map(String.init).joined()))
            }
            let mainland = mainlandTerms.filter { output.contains($0) && !testCase.input.contains($0) }
            if !mainland.isEmpty {
                failures.append(Failure(check: "taiwan-wording", detail: mainland.joined(separator: ", ")))
            }
        }
        if testCase.expectUnchanged == true, output != input {
            failures.append(Failure(check: "unchanged", detail: "text that was already correct was rewritten"))
        }
        if testCase.preserveLineStructure == true {
            let inputLines = lines(of: input)
            let outputLines = lines(of: output)
            if inputLines.count != outputLines.count {
                failures.append(Failure(
                    check: "line-structure",
                    detail: "\(inputLines.count) lines in, \(outputLines.count) out"
                ))
            } else {
                for (before, after) in zip(inputLines, outputLines) where marker(of: before) != marker(of: after) {
                    failures.append(Failure(
                        check: "line-structure",
                        detail: "list marker \"\(marker(of: before))\" became \"\(marker(of: after))\""
                    ))
                    break
                }
            }
        }
        return failures
    }

    // MARK: - Helpers

    static func lines(of text: String) -> [String] {
        text.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    /// The `- ` or `1. ` a list line starts with, "" for anything else.
    static func marker(of line: String) -> String {
        if line.hasPrefix("- ") || line.hasPrefix("* ") { return String(line.prefix(2)) }
        let digits = line.prefix { $0.isNumber }
        if !digits.isEmpty, line.dropFirst(digits.count).hasPrefix(". ") { return "\(digits). " }
        return ""
    }

    /// Han characters as a share of the prose (URLs, paths and code left out); the app's own
    /// measure, so the eval and the guard agree on what "the wrong language" is.
    static func hanRatio(of text: String) -> Double {
        TextScript.hanShare(text)
    }

    static func languageFailure(_ expected: WritingEvalCase.Language, in output: String) -> String? {
        let ratio = hanRatio(of: output)
        switch expected {
        case .any: return nil
        case .en:
            return ratio > 0.15 ? "expected English, Han characters are \(percent(ratio)) of it" : nil
        case .zhHant:
            return ratio < 0.4 ? "expected Traditional Chinese, Han characters are only \(percent(ratio))" : nil
        case .mixed:
            return (0.05...0.95).contains(ratio)
                ? nil : "expected both languages, Han characters are \(percent(ratio))"
        }
    }

    private static func percent(_ value: Double) -> String {
        "\(Int((value * 100).rounded()))%"
    }
}
