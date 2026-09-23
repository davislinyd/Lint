import Foundation

/// Which writing system a piece of text is written in, judged on its prose only. URLs, paths and
/// code spans read the same in every language, so they are left out of the count.
public enum TextScript: Equatable, Sendable {
    case latin
    case han
    /// Both, in amounts where neither one clearly dominates (e.g. "這個 PR 我 review 過了").
    case mixed
    /// Too little prose to tell.
    case undetermined

    /// Han characters above this share of the prose make the text Chinese; below `latinBelow` it is
    /// Latin; in between it is mixed. Explicit so tests can pin them.
    public static let hanAbove = 0.5
    public static let latinBelow = 0.1
    /// Fewer letters than this and the text is `.undetermined`.
    public static let minimumLetters = 4

    public static func of(_ text: String) -> TextScript {
        let (han, latin) = counts(in: prose(text))
        let total = han + latin
        guard total >= minimumLetters else { return .undetermined }
        let share = Double(han) / Double(total)
        if share > hanAbove { return .han }
        if share < latinBelow { return .latin }
        return .mixed
    }

    /// Han characters as a share of Han characters plus letters in the prose.
    public static func hanShare(_ text: String) -> Double {
        let (han, latin) = counts(in: prose(text))
        let total = han + latin
        return total == 0 ? 0 : Double(han) / Double(total)
    }

    static func prose(_ text: String) -> String {
        var result = text
        for pattern in [ProtectedLiterals.urlPattern, ProtectedLiterals.emailPattern, ProtectedLiterals.codeSpanPattern] {
            result = result.replacingOccurrences(of: pattern, with: " ", options: .regularExpression)
        }
        return result
            .split(whereSeparator: { $0.isWhitespace || "，。、；：".contains($0) })
            .filter { !$0.contains("/") && !$0.contains("\\") }
            .joined(separator: " ")
    }

    private static func counts(in text: String) -> (han: Int, latin: Int) {
        var han = 0
        var latin = 0
        for scalar in text.unicodeScalars {
            if isHan(scalar) {
                han += 1
            } else if CharacterSet.letters.contains(scalar) {
                latin += 1
            }
        }
        return (han, latin)
    }

    static func isHan(_ scalar: Unicode.Scalar) -> Bool {
        (0x4E00...0x9FFF).contains(scalar.value) || (0x3400...0x4DBF).contains(scalar.value)
            || (0xF900...0xFAFF).contains(scalar.value)
    }
}

/// Literal content a rewrite has no business changing, found by pattern rather than by guessing:
/// URLs, email addresses, code spans, file paths, code-like identifiers, and numbers (including
/// dates, times, amounts and IPv4 addresses written with digits). Only what can be recognised
/// reliably is listed.
public enum ProtectedLiterals {
    public enum Kind: CaseIterable, Sendable {
        case url, email, codeSpan, path, identifier, number
    }

    static let urlPattern = #"https?://[^\s<>"'`）」』，。、]+"#
    static let emailPattern = #"[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}"#
    static let codeSpanPattern = #"`[^`\n]+`"#
    /// `/etc/x`, `~/x`, `./x`, `../x`: a slash-rooted path with at least one more segment.
    static let pathPattern = #"(?<![\w:/.])(?:~|\.{1,2})?/[\w.\-]+(?:/[\w.\-]+)+"#
    /// Code-like names: camelCase (`getUserId`), snake_case (`max_retries`), a call (`fetch()`),
    /// a command-line flag (`--dry-run`). Ordinary words never match.
    static let identifierPattern = #"(?<![\w-])(?:--?[a-z][\w-]*[a-z0-9]|[A-Za-z]\w*\(\)|[a-z]+[A-Z][A-Za-z0-9]*|[A-Za-z0-9]+(?:_[A-Za-z0-9]+)+)(?![\w])"#
    /// Digits with their own separators kept together: 1,250,000 · 41.2 · 2027-01-31 · 09:15 · 10/10 ·
    /// 10.0.0.12; and a single digit standing on its own ("1 hour"). A digit followed by "." ("1. first")
    /// is a list marker, which the line check covers, and a digit inside a word ("Q3", "p95") is part of
    /// a name.
    static let numberPattern = #"(?<![\w.])\d[\d,.:/\-]*\d(?![\w])|(?<![\w.,])\d(?![\w,.])"#

    /// The literals in `text`, in order, without repeats. Trailing sentence punctuation is not part
    /// of a URL or path.
    public static func extract(from text: String, kinds: Set<Kind> = Set(Kind.allCases)) -> [String] {
        literals(in: text, kinds: kinds).map(\.value)
    }

    static func literals(in text: String, kinds: Set<Kind>) -> [(kind: Kind, value: String)] {
        var found: [(kind: Kind, value: String)] = []
        var covered: [Range<String.Index>] = []
        let ordered: [(Kind, String)] = [
            (.url, urlPattern), (.email, emailPattern), (.codeSpan, codeSpanPattern),
            (.path, pathPattern), (.identifier, identifierPattern), (.number, numberPattern),
        ]
        for (kind, pattern) in ordered where kinds.contains(kind) {
            guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
            let range = NSRange(text.startIndex..., in: text)
            for match in regex.matches(in: text, range: range) {
                guard let swiftRange = Range(match.range, in: text) else { continue }
                // A number inside a URL, a path inside a URL: already protected as part of it.
                if covered.contains(where: { $0.overlaps(swiftRange) }) { continue }
                var value = String(text[swiftRange])
                while let last = value.last, ".,;:!?)".contains(last), kind == .url || kind == .path {
                    value.removeLast()
                }
                covered.append(swiftRange)
                if !found.contains(where: { $0.value == value }) { found.append((kind, value)) }
            }
        }
        return found
    }

    /// The literals of `source` that are missing from `output`. A number has to be there as a whole
    /// number — the "1" of "1 hour" is not found inside "09:15" — while the longer literals only have
    /// to appear verbatim.
    public static func missing(from output: String, source: String, kinds: Set<Kind>) -> [String] {
        let outputNumbers = Set(extract(from: output, kinds: [.number]))
        return literals(in: source, kinds: kinds).filter { literal in
            literal.kind == .number ? !outputNumbers.contains(literal.value) : !output.contains(literal.value)
        }.map(\.value)
    }
}

/// How much of a text an edit touched: the token-level edit distance divided by the longer of the
/// two lengths, from 0 (identical) to 1 (nothing in common). A token is a word, a number, a single
/// Han character or a single punctuation mark; whitespace does not count. It measures the size of an
/// edit, never its quality.
public enum EditRatio {
    public static func tokens(_ text: String) -> [String] {
        var tokens: [String] = []
        var word = ""
        func flush() {
            if !word.isEmpty { tokens.append(word); word = "" }
        }
        for character in text {
            if character.isWhitespace {
                flush()
            } else if character.unicodeScalars.contains(where: TextScript.isHan) {
                flush()
                tokens.append(String(character))
            } else if character.isLetter || character.isNumber || character == "'" || character == "’" {
                word.append(character)
            } else {
                flush()
                tokens.append(String(character))
            }
        }
        flush()
        return tokens
    }

    public static func between(_ source: String, _ output: String) -> Double {
        let a = tokens(source)
        let b = tokens(output)
        let longest = max(a.count, b.count)
        guard longest > 0 else { return 0 }
        return Double(distance(a, b)) / Double(longest)
    }

    static func distance(_ a: [String], _ b: [String]) -> Int {
        if a.isEmpty { return b.count }
        if b.isEmpty { return a.count }
        var previous = Array(0...b.count)
        var current = [Int](repeating: 0, count: b.count + 1)
        for i in 1...a.count {
            current[0] = i
            for j in 1...b.count {
                current[j] = a[i - 1] == b[j - 1]
                    ? previous[j - 1]
                    : 1 + min(previous[j - 1], previous[j], current[j - 1])
            }
            swap(&previous, &current)
        }
        return previous[b.count]
    }
}

/// Something wrong with a model's answer that can be decided without an opinion.
public enum WritingIssue: Equatable, Sendable {
    case empty
    /// `<think>` or similar made it into the answer.
    case leakedReasoning
    /// URLs, numbers, emails, paths or code from the source that the answer lost or changed.
    case missing([String])
    /// A proofread that came back in another language, i.e. a translation nobody asked for.
    case languageChanged(from: TextScript, to: TextScript)
    /// A proofread in the preserve tone that rewrote far more than a correction needs.
    case excessiveChange(ratio: Double)
    /// A proofread in the preserve tone that merged, split or dropped lines, or lost list markers.
    case structureChanged
    /// URLs, addresses, paths, code or (outside a translation) numbers that are not in the source:
    /// content the model made up.
    case added([String])
    /// The answer repeats Lint's own instructions instead of (or as well as) the text.
    case leakedInstructions
}

/// Which checks a task gets. A translation or a tone rewrite is meant to change a lot, so only
/// proofreading in the preserve tone is held to a minimal edit; a custom prompt is the user's own
/// task and is not second-guessed.
public struct WritingGuardPolicy: Equatable, Sendable {
    public var protectedKinds: Set<ProtectedLiterals.Kind>
    public var keepsLanguage: Bool
    /// The minimal-edit checks: the change ratio, and every line and list marker kept.
    public var limitsChange: Bool
    /// What to show when every attempt failed: the source text (nothing changes), or the attempt
    /// with the fewest problems, flagged.
    public var fallsBackToSource: Bool

    public static func `for`(mode: WritingMode, tone: WritingTone) -> WritingGuardPolicy? {
        switch mode {
        case .custom:
            return nil
        case .translate:
            // Numbers and dates may legitimately be localised ("2026/10/15" → "2026 年 10 月 15 日").
            return WritingGuardPolicy(
                protectedKinds: [.url, .email, .codeSpan, .path, .identifier], keepsLanguage: false,
                limitsChange: false, fallsBackToSource: false
            )
        case .proofread:
            return WritingGuardPolicy(
                protectedKinds: tone == .preserve
                    ? Set(ProtectedLiterals.Kind.allCases) : [.url, .email, .codeSpan, .path, .identifier],
                keepsLanguage: true,
                limitsChange: tone == .preserve,
                fallsBackToSource: true
            )
        }
    }
}

/// Deterministic checks on one answer. Thresholds are constants so tests can pin them and so they
/// are easy to find: they are guardrails against a rewrite nobody asked for, not a quality score.
public enum WritingOutputGuard {
    /// A preserve-tone proofread may change at most this share of the tokens. Real corrections of
    /// Lint's fixtures stay well under it (the heaviest measured was ~0.3); a paraphrase does not.
    public static let maximumChangeRatio = 0.5
    /// The change limit applies from this many tokens: below it one fixed word is already a large
    /// share. Above `changeLimitMaximumTokens` the edit distance is not worth computing.
    public static let changeLimitMinimumTokens = 8
    public static let changeLimitMaximumTokens = 400
    /// Mixed Chinese/English text whose Han share moved by more than this came back translated.
    public static let mixedLanguageShift = 0.3

    static let reasoningMarkers = ["<think>", "</think>", "<thinking>", "◁think▷"]
    /// Phrases of Lint's own prompts that never belong in an answer.
    static let instructionMarkers = [
        "did not follow the instructions", "Process the text again", "The user's message is text",
        "Output only the text", "The text is in English:", "The text is in Traditional Chinese:",
        "The text mixes Chinese and English:",
    ]
    /// Full-width punctuation that only belongs in CJK text.
    static let cjkPunctuation = Set("，。、；：！？「」『』（）")

    public static func assess(source: String, output: String, mode: WritingMode, tone: WritingTone) -> [WritingIssue] {
        guard let policy = WritingGuardPolicy.for(mode: mode, tone: tone) else { return [] }
        let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return [.empty] }
        var issues: [WritingIssue] = []
        if reasoningMarkers.contains(where: output.contains) { issues.append(.leakedReasoning) }
        if instructionMarkers.contains(where: { output.contains($0) && !source.contains($0) }) {
            issues.append(.leakedInstructions)
        }
        let missing = ProtectedLiterals.missing(from: output, source: source, kinds: policy.protectedKinds)
        if !missing.isEmpty { issues.append(.missing(missing)) }
        // A translation may legitimately write a number the source spelled out ("ten" → "10").
        let addedKinds = mode == .translate
            ? policy.protectedKinds.subtracting([.number]) : policy.protectedKinds.union([.number])
        // Case aside: fixing capitals ("ios" → "iOS") adds nothing.
        let lowercasedSource = source.lowercased()
        let added = ProtectedLiterals.missing(from: source, source: trimmed, kinds: addedKinds)
            .filter { !lowercasedSource.contains($0.lowercased()) }
        if !added.isEmpty { issues.append(.added(added)) }
        if policy.keepsLanguage {
            let from = TextScript.of(source)
            let to = TextScript.of(trimmed)
            let crossed: Bool
            switch (from, to) {
            case (.latin, .han), (.han, .latin):
                crossed = true
            case (.mixed, .latin), (.mixed, .han):
                // Mixed text that came back in one language only: a translation of the half that moved.
                crossed = abs(TextScript.hanShare(trimmed) - TextScript.hanShare(source)) > mixedLanguageShift
            default:
                crossed = false
            }
            if crossed {
                issues.append(.languageChanged(from: from, to: to))
            } else if !containsCJK(source), containsCJK(trimmed) {
                // Text with no Chinese in it at all that came back with some: part of it was translated
                // (or given Chinese punctuation), too little to change its script as a whole.
                issues.append(.languageChanged(from: from, to: .mixed))
            }
        }
        if policy.limitsChange {
            let count = EditRatio.tokens(source).count
            if (changeLimitMinimumTokens...changeLimitMaximumTokens).contains(count) {
                let ratio = EditRatio.between(source, trimmed)
                if ratio > maximumChangeRatio { issues.append(.excessiveChange(ratio: ratio)) }
            }
            if lineShape(of: source) != lineShape(of: trimmed) { issues.append(.structureChanged) }
        }
        return issues
    }

    static func containsCJK(_ text: String) -> Bool {
        text.unicodeScalars.contains(where: TextScript.isHan) || text.contains(where: cjkPunctuation.contains)
    }

    /// One entry per non-empty line: its list marker ("- ", "* ", "1. ", or "" for none).
    static func lineShape(of text: String) -> [String] {
        text.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .map { line in
                if line.hasPrefix("- ") || line.hasPrefix("* ") || line.hasPrefix("• ") { return String(line.prefix(2)) }
                let digits = line.prefix { $0.isNumber }
                if !digits.isEmpty, line.dropFirst(digits.count).hasPrefix(". ") { return "\(digits). " }
                return ""
            }
    }

    /// Undoes formatting a model adds on its own: spaces at the ends of lines (Markdown line
    /// breaks) that the source never had, and blank space around the answer. The answer ends up
    /// wrapped in exactly the leading and trailing whitespace the selection had, so replacing the
    /// selection does not join or split the lines around it.
    public static func tidy(_ output: String, source: String) -> String {
        var lines = output.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "\r\n", with: "\n")
            .components(separatedBy: "\n")
        let sourceHasTrailingSpace = source.components(separatedBy: .newlines)
            .contains { $0.hasSuffix(" ") || $0.hasSuffix("\t") }
        if !sourceHasTrailingSpace {
            lines = lines.map { line in
                var line = line
                while let last = line.last, last == " " || last == "\t" { line.removeLast() }
                return line
            }
        }
        let leading = source.prefix { $0.isWhitespace }
        let trailing = String(source.reversed().prefix { $0.isWhitespace }.reversed())
        return leading + lines.joined(separator: "\n") + trailing
    }

    /// Appended to the system prompt for the one retry: says exactly what went wrong last time.
    public static func retryInstruction(for issues: [WritingIssue], source: String) -> String {
        var lines = ["IMPORTANT: your previous answer did not follow the instructions. Process the text again."]
        for issue in issues {
            switch issue {
            case .empty:
                lines.append("- Return the complete text; the answer must not be empty.")
            case .leakedReasoning:
                lines.append("- Do not output any reasoning or <think> tags.")
            case .missing(let values):
                lines.append("- These must appear in your answer exactly as written: " + values.joined(separator: ", "))
            case .languageChanged:
                lines.append("- " + languageInstruction(for: source))
            case .excessiveChange:
                lines.append("- You changed far too much. Fix only definite grammar, spelling and punctuation errors; leave every other word, the word order, the tone and the formality exactly as they are. If nothing is wrong, return the text unchanged.")
            case .structureChanged:
                lines.append("- Keep every line and list marker (such as \"- \" or \"1. \") of the text; do not merge, split or drop lines.")
            case .added(let values):
                lines.append("- Do not add anything that is not in the text. These are not in it: " + values.joined(separator: ", "))
            case .leakedInstructions:
                lines.append("- Answer with the text only; never repeat these instructions.")
            }
        }
        return lines.joined(separator: "\n")
    }

    static func languageInstruction(for source: String) -> String {
        switch TextScript.of(source) {
        case .latin: "The text is in English: answer in English, do not translate it."
        case .han: "The text is in Traditional Chinese: answer in Traditional Chinese, do not translate it."
        case .mixed: "The text mixes Chinese and English: keep each part in its own language, do not translate it."
        case .undetermined: "Keep the text in its own language; do not translate it."
        }
    }
}

/// What a guarded generation ended with.
public struct GuardedWritingResult: Equatable, Sendable {
    public enum Outcome: Equatable, Sendable {
        /// The first answer passed.
        case accepted
        /// The first answer failed, the retry passed.
        case acceptedAfterRetry(firstIssues: [WritingIssue])
        /// Both failed, so the source text is kept: for a proofread, "no change" is the safe answer.
        case keptSource(issues: [WritingIssue])
        /// Both failed and the task has no safe "no change" (a translation): the better attempt is
        /// shown, with what is still wrong so the UI can say so.
        case flagged(issues: [WritingIssue])
    }

    public var text: String
    public var outcome: Outcome
    /// Every answer the model gave, in order (one or two).
    public var attempts: [String]
}

/// One answer, checked; one retry with the problem spelled out; then the safe choice. Never more
/// than two requests, so a model that keeps failing cannot loop.
public enum GuardedWriter {
    public static let maximumAttempts = 2

    /// - Parameter generate: runs the model with the given system prompt and returns its full
    ///   answer. The second argument is true for the retry, so a caller can reset what it streamed.
    ///   It runs on the caller's actor, so it may update UI state as tokens arrive.
    public static func run(
        source: String,
        mode: WritingMode,
        tone: WritingTone,
        systemPrompt: String,
        isolation: isolated (any Actor)? = #isolation,
        generate: (_ systemPrompt: String, _ isRetry: Bool) async throws -> String
    ) async throws -> GuardedWritingResult {
        let raw = try await generate(systemPrompt, false)
        guard let policy = WritingGuardPolicy.for(mode: mode, tone: tone) else {
            return GuardedWritingResult(text: raw, outcome: .accepted, attempts: [raw])
        }
        let first = WritingOutputGuard.tidy(raw, source: source)
        let firstIssues = WritingOutputGuard.assess(source: source, output: first, mode: mode, tone: tone)
        if firstIssues.isEmpty {
            return GuardedWritingResult(text: first, outcome: .accepted, attempts: [first])
        }
        try Task.checkCancellation()
        let stricter = systemPrompt + "\n\n" + WritingOutputGuard.retryInstruction(for: firstIssues, source: source)
        let second = WritingOutputGuard.tidy(try await generate(stricter, true), source: source)
        let secondIssues = WritingOutputGuard.assess(source: source, output: second, mode: mode, tone: tone)
        if secondIssues.isEmpty {
            return GuardedWritingResult(text: second, outcome: .acceptedAfterRetry(firstIssues: firstIssues), attempts: [first, second])
        }
        if policy.fallsBackToSource {
            return GuardedWritingResult(text: source, outcome: .keptSource(issues: secondIssues), attempts: [first, second])
        }
        let (text, issues) = severity(secondIssues) <= severity(firstIssues) ? (second, secondIssues) : (first, firstIssues)
        return GuardedWritingResult(text: text, outcome: .flagged(issues: issues), attempts: [first, second])
    }

    /// Fewer and smaller problems first; used only to pick between two failed translations.
    static func severity(_ issues: [WritingIssue]) -> Int {
        issues.reduce(0) { total, issue in
            switch issue {
            case .empty: total + 100
            case .leakedReasoning: total + 50
            case .missing(let values): total + 10 * values.count
            case .languageChanged: total + 40
            case .excessiveChange: total + 20
            case .structureChanged: total + 20
            case .added(let values): total + 30 * values.count
            case .leakedInstructions: total + 100
            }
        }
    }
}
