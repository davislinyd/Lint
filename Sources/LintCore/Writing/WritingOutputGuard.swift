import Foundation
import NaturalLanguage

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

    /// Whether the prose has an English letter in it. Lint edits English only, so a proofread of text
    /// without one is not sent to a model; a URL or a path alone does not count.
    public static func hasEnglish(_ text: String) -> Bool {
        prose(text).unicodeScalars.contains { ("a"..."z").contains($0) || ("A"..."Z").contains($0) }
    }

    /// From this share of its letters on, a script other than Latin or Han makes the text another
    /// language: a Korean file or product name in English text leaves it English, a Korean sentence
    /// with an English word or two in it ("내일 PR review 해주세요") is Korean.
    public static let otherScriptMinimumShare = 0.3
    /// Text in Latin letters only is another language when Apple's recognizer is at least this sure of
    /// a language other than English, with at least `otherLanguageMinimumLetters` letters to go on.
    /// Measured: it calls short or casual English Polish or Indonesian ("np", "Hi Alice, can u send me
    /// the file asap"), but not with this confidence, and Lint's English fixtures all come out English;
    /// a Spanish, Indonesian or Vietnamese sentence comes out at 0.99 and up.
    public static let otherLanguageConfidence = 0.9
    public static let otherLanguageMinimumLetters = 6

    /// Letters of a script other than Latin or Han (Hangul, kana, Thai, Cyrillic…) as a share of the
    /// letters in the prose.
    public static func otherScriptShare(_ text: String) -> Double {
        let counts = scriptCounts(in: prose(text))
        let total = counts.latin + counts.han + counts.other
        return total == 0 ? 0 : Double(counts.other) / Double(total)
    }

    /// Enough of the prose is in a script of its own (Korean, Japanese kana, Thai…) for the text to be
    /// in that language, whatever English it mixes in.
    public static func writesInAnotherScript(_ text: String) -> Bool {
        otherScriptShare(text) >= otherScriptMinimumShare
    }

    /// Whether the prose is in a language other than English. Never for text with Chinese in it, which
    /// is told by its script instead: the recognizer calls "請幫我 check 這個 issue" English.
    public static func isOtherLanguage(_ text: String) -> Bool {
        let prose = prose(text)
        let counts = scriptCounts(in: prose)
        if counts.han > 0 { return false }
        if counts.other > 0 { return Double(counts.other) / Double(counts.other + counts.latin) >= otherScriptMinimumShare }
        guard counts.latin >= otherLanguageMinimumLetters else { return false }
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(prose)
        guard let top = recognizer.languageHypotheses(withMaximum: 1).first else { return false }
        return top.key != .english && top.value >= otherLanguageConfidence
    }

    /// The letters of the prose by script: Latin, Han, and every other script together.
    private static func scriptCounts(in prose: String) -> (latin: Int, han: Int, other: Int) {
        var counts = (latin: 0, han: 0, other: 0)
        for scalar in prose.unicodeScalars where CharacterSet.letters.contains(scalar) {
            if isHan(scalar) {
                counts.han += 1
            } else if isLatin(scalar) {
                counts.latin += 1
            } else {
                counts.other += 1
            }
        }
        return counts
    }

    /// Letters of the Latin script, with the accents of Vietnamese, Spanish or German, precomposed or not.
    static func isLatin(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x41...0x5A, 0x61...0x7A, 0xC0...0x24F, 0x300...0x36F, 0x1E00...0x1EFF: true
        default: false
        }
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
        case url, email, codeSpan, path, identifier, placeholder, acronym, number
        /// A word in a script other than Latin: a Korean product name, a Japanese file name, the Chinese
        /// of a mixed text. An edit of the English leaves it alone (measured: a Korean product name
        /// came back translated, in an answer no other check held anything against).
        case foreignWord
    }

    static let urlPattern = #"https?://[^\s<>"'`）」』，。、]+"#
    static let emailPattern = #"[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}"#
    static let codeSpanPattern = #"`[^`\n]+`"#
    /// `/etc/x`, `~/x`, `./x`, `../x`: a slash-rooted path with at least one more segment.
    static let pathPattern = #"(?<![\w:/.])(?:~|\.{1,2})?/[\w.\-]+(?:/[\w.\-]+)+"#
    /// Code-like names: camelCase (`getUserId`), snake_case (`max_retries`), a call (`fetch()`),
    /// a command-line flag (`--dry-run`). Ordinary words never match.
    static let identifierPattern = #"(?<![\w-])(?:--?[a-z][\w-]*[a-z0-9]|[A-Za-z]\w*\(\)|[a-z]+[A-Z][A-Za-z0-9]*|[A-Za-z0-9]+(?:_[A-Za-z0-9]+)+)(?![\w])"#
    /// A template slot: `[Name]`, `[Recipient's Name]`, `{name}`, `{order_id}`, `%s`, `%d`. One that is
    /// not in the text was made up (measured: a formal rewrite that opened with "Dear [Name],", a
    /// professional one that invented a list around "[project name]").
    static let placeholderPattern = #"\[[A-Za-z][A-Za-z' ]{0,30}\]|\{\{?[A-Za-z_][\w.]*\}?\}|%[sd@]"#
    /// Two or more capitals, maybe with digits: PR, CI, SLO, VPN, MFA, UTC, HTTP2. A proofread that
    /// keeps the tone keeps them (measured: "the PR" became "the press release"); a tone rewrite may
    /// spell out ASAP, so only the preserve policy protects them.
    static let acronymPattern = #"(?<![\w-])[A-Z]{2,}[0-9]*(?![\w-])"#
    /// Digits with their own separators kept together: 1,250,000 · 41.2 · 2027-01-31 · 09:15 · 10/10 ·
    /// 10.0.0.12; and a single digit standing on its own ("1 hour"). A digit followed by "." ("1. first")
    /// is a list marker, which the line check covers, and a digit inside a word ("Q3", "p95") is part of
    /// a name.
    /// A run of letters (with their marks) in any script but Latin.
    static let foreignWordPattern = #"[\p{L}&&[^\p{Script=Latin}]][[\p{L}\p{M}]&&[^\p{Script=Latin}]]*"#
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
            (.path, pathPattern), (.placeholder, placeholderPattern), (.identifier, identifierPattern),
            (.acronym, acronymPattern),
            (.number, numberPattern), (.foreignWord, foreignWordPattern),
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

/// How much of an answer is not the text's own words: the share of its words (case aside, each
/// counted as often as it occurs) that the text does not have. Unlike `EditRatio` it does not mind
/// the order, so a sentence put in a better order costs nothing while a paraphrase costs nearly all
/// of it. Measured on a sentence that said its subject twice: the rebuilt sentence is 0.59 by
/// `EditRatio` and 0.05 here, a paraphrase of it 0.90 and 0.72.
public enum WordNovelty {
    /// The words of `text`, lowercased: punctuation is not a word.
    public static func words(_ text: String) -> [String] {
        EditRatio.tokens(text).filter { $0.first.map { $0.isLetter || $0.isNumber } ?? false }.map { $0.lowercased() }
    }

    public static func share(of output: String, notIn source: String) -> Double {
        let answer = words(output)
        guard !answer.isEmpty else { return 0 }
        var available: [String: Int] = [:]
        for word in words(source) { available[word, default: 0] += 1 }
        var new = 0
        for word in answer {
            if let left = available[word], left > 0 { available[word] = left - 1 } else { new += 1 }
        }
        return Double(new) / Double(answer.count)
    }
}

/// Something wrong with a model's answer that can be decided without an opinion.
public enum WritingIssue: Equatable, Sendable {
    case empty
    /// `<think>` or similar made it into the answer.
    case leakedReasoning
    /// URLs, numbers, emails, paths, code or other-language words from the source that the answer lost
    /// or changed.
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
    /// A native rewrite that still has Chinese in it (a word, a name, or its punctuation): it was
    /// asked for English.
    case notEnglish
    /// The answer repeats Lint's own instructions instead of (or as well as) the text.
    case leakedInstructions
    /// Bullets or numbering the text did not have: notes about the text ("- The intent: …") or a list
    /// of options instead of the rewrite (measured: Apple's model on the native tone).
    case addedList
    /// An edit that was to keep the writer's voice did not (`VoiceCheck`): a softer, more formal or
    /// otherwise different-sounding text, which still says the same thing.
    case voiceChanged([VoiceChange])

    /// What is left of the voice when the text itself is intact: worth showing, with a note, rather
    /// than throwing the fixes away.
    public var isVoiceOnly: Bool {
        if case .voiceChanged = self { return true }
        return false
    }
}

/// Which checks a task gets. A translation or a tone rewrite is meant to change a lot, so only
/// proofreading in the preserve tone is held to a minimal edit; a custom prompt is the user's own
/// task and is not second-guessed.
public struct WritingGuardPolicy: Equatable, Sendable {
    public var protectedKinds: Set<ProtectedLiterals.Kind>
    public var keepsLanguage: Bool
    /// The answer has to be English, with no Chinese left in it (the native tone).
    public var requiresEnglish: Bool = false
    /// No more list lines than the text has. A rewrite that need not keep the lines (`limitsChange`
    /// off) still has no reason to turn a message into bullets.
    public var forbidsAddedLists: Bool = false
    /// Numbers and dates may be written another way ("10/15" → "October 15", "十" → "10"), so none
    /// are demanded of the answer and none are held against it.
    public var numbersMayChange: Bool = false
    /// The minimal-edit checks: the change ratio, and every line and list marker kept.
    public var limitsChange: Bool
    /// When set, `limitsChange` measures the change as the share of the answer's words that are new
    /// (`WordNovelty`) instead of by edit distance: for an edit that may put a sentence in another order.
    public var maximumNewWordShare: Double? = nil
    /// The answer has to sound like the writer (`VoiceCheck`).
    public var keepsVoice: Bool = false
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
                protectedKinds: [.url, .email, .codeSpan, .path, .placeholder, .identifier], keepsLanguage: false,
                numbersMayChange: true, limitsChange: false, fallsBackToSource: false
            )
        case .proofread where tone.isNative:
            // The text may be in another language, so keeping it is no safe answer to a request for English: two
            // failed attempts show the better one, flagged, as a translation does.
            return WritingGuardPolicy(
                protectedKinds: [.url, .email, .codeSpan, .path, .placeholder, .identifier], keepsLanguage: false,
                requiresEnglish: true, forbidsAddedLists: true, numbersMayChange: true, limitsChange: false,
                fallsBackToSource: false
            )
        case .proofread where tone == .idiomatic:
            // The preserve checks, except that the edit may rebuild a tangled sentence: what is limited
            // is how many of the answer's words are not the writer's, not how far they moved.
            return WritingGuardPolicy(
                protectedKinds: Set(ProtectedLiterals.Kind.allCases), keepsLanguage: true, limitsChange: true,
                maximumNewWordShare: WritingOutputGuard.idiomaticMaximumNewWordShare, keepsVoice: true, fallsBackToSource: true
            )
        case .proofread:
            return WritingGuardPolicy(
                protectedKinds: tone == .preserve
                    ? Set(ProtectedLiterals.Kind.allCases) : [.url, .email, .codeSpan, .path, .placeholder, .identifier],
                keepsLanguage: true,
                limitsChange: tone == .preserve,
                fallsBackToSource: true
            )
        }
    }

    /// Whether Lint's own model (the English prompts, no guard otherwise) goes through the guard for
    /// this task: only the idiomatic tone, whose promise to keep the writer's voice is worth a retry.
    /// Apple's model is always guarded; other providers never are.
    public static func guardsLocalModel(mode: WritingMode, tone: WritingTone) -> Bool {
        mode == .proofread && tone == .idiomatic
    }
}

/// Deterministic checks on one answer. Thresholds are constants so tests can pin them and so they
/// are easy to find: they are guardrails against a rewrite nobody asked for, not a quality score.
public enum WritingOutputGuard {
    /// A preserve-tone proofread may change at most this share of the tokens. Real corrections of
    /// Lint's fixtures stay well under it (the heaviest measured was ~0.3); a paraphrase does not.
    public static let maximumChangeRatio = 0.5
    /// An idiomatic edit may bring at most this share of new words. Measured on Lint's fixtures: good
    /// answers stay at or under 0.38, answers that reply to the text or describe it are 0.77 and up.
    public static let idiomaticMaximumNewWordShare = 0.5
    /// The new-word limit applies from this many words: in a shorter text a rewritten phrase is most
    /// of it ("Kindly revert back to me at the earliest." → "Please get back to me as soon as possible.").
    public static let newWordMinimumWords = 12
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
        "Output only the text", "The text is in English:", "The text mixes Chinese and English:",
        "Reminders about this user's",
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
        // A change of language says it all: the other-language words it dropped or brought in are the
        // same finding, and are not reported a second time.
        let languageIssue = policy.keepsLanguage ? languageChange(from: source, to: trimmed) : nil
        var literalKinds = languageIssue == nil ? policy.protectedKinds : policy.protectedKinds.subtracting([.foreignWord])
        // A text in another script that is to keep it (Korean, Thai…) keeps its words in every tone, and
        // an answer that translated them is retried with those words listed. Measured on Gemma 4 E4B: its
        // first answer translated the Korean of such a text every time, and that retry kept it and fixed
        // the English; telling the model up front, or on the retry, that the text "mixes another language
        // and English" left the English of a Thai text uncorrected in most runs.
        if policy.keepsLanguage, languageIssue == nil, TextScript.writesInAnotherScript(source) {
            literalKinds.insert(.foreignWord)
        }
        let missing = ProtectedLiterals.missing(from: output, source: source, kinds: literalKinds)
        if !missing.isEmpty { issues.append(.missing(missing)) }
        // A translation may legitimately write a number the source spelled out ("ten" → "10").
        let addedKinds = policy.numbersMayChange ? literalKinds.subtracting([.number]) : literalKinds.union([.number])
        // Case aside: fixing capitals ("ios" → "iOS") adds nothing.
        let lowercasedSource = source.lowercased()
        let added = ProtectedLiterals.missing(from: source, source: trimmed, kinds: addedKinds)
            .filter { !lowercasedSource.contains($0.lowercased()) }
        if !added.isEmpty { issues.append(.added(added)) }
        if let languageIssue { issues.append(languageIssue) }
        if policy.requiresEnglish, containsCJK(trimmed) || TextScript.isOtherLanguage(trimmed) { issues.append(.notEnglish) }
        if policy.forbidsAddedLists, listLines(in: trimmed) > listLines(in: source) { issues.append(.addedList) }
        if policy.limitsChange {
            if let limit = policy.maximumNewWordShare {
                if WordNovelty.words(source).count >= newWordMinimumWords {
                    let share = WordNovelty.share(of: trimmed, notIn: source)
                    if share > limit { issues.append(.excessiveChange(ratio: share)) }
                }
            } else {
                let count = EditRatio.tokens(source).count
                if (changeLimitMinimumTokens...changeLimitMaximumTokens).contains(count) {
                    let ratio = EditRatio.between(source, trimmed)
                    if ratio > maximumChangeRatio { issues.append(.excessiveChange(ratio: ratio)) }
                }
            }
            if lineShape(of: source) != lineShape(of: trimmed) { issues.append(.structureChanged) }
        }
        if policy.keepsVoice {
            let changes = VoiceCheck.changes(from: source, to: trimmed)
            if !changes.isEmpty { issues.append(.voiceChanged(changes)) }
        }
        return issues
    }

    /// The answer is in another language than the text, as a whole or in part; nil when it kept it.
    static func languageChange(from source: String, to output: String) -> WritingIssue? {
        let from = TextScript.of(source)
        let to = TextScript.of(output)
        let crossed: Bool
        switch (from, to) {
        case (.latin, .han), (.han, .latin):
            crossed = true
        case (.mixed, .latin), (.mixed, .han):
            // Mixed text that came back in one language only: a translation of the half that moved.
            crossed = abs(TextScript.hanShare(output) - TextScript.hanShare(source)) > mixedLanguageShift
        default:
            crossed = false
        }
        if crossed { return .languageChanged(from: from, to: to) }
        // Text with no Chinese in it at all that came back with some: part of it was translated
        // (or given Chinese punctuation), too little to change its script as a whole.
        if !containsCJK(source), containsCJK(output) { return .languageChanged(from: from, to: .mixed) }
        return nil
    }

    static func containsCJK(_ text: String) -> Bool {
        text.unicodeScalars.contains(where: TextScript.isHan) || text.contains(where: cjkPunctuation.contains)
    }

    static func listLines(in text: String) -> Int {
        lineShape(of: text).filter { !$0.isEmpty }.count
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
        // A model that writes typographic quotes ("I’ve") where the text has straight ones changes
        // every contraction; the text's own style wins.
        if !source.contains(where: { "‘’“”".contains($0) }) {
            lines = lines.map { line in
                line.replacingOccurrences(of: "’", with: "'").replacingOccurrences(of: "‘", with: "'")
                    .replacingOccurrences(of: "“", with: "\"").replacingOccurrences(of: "”", with: "\"")
            }
        }
        let leading = source.prefix { $0.isWhitespace }
        let trailing = String(source.reversed().prefix { $0.isWhitespace }.reversed())
        return leading + lines.joined(separator: "\n") + trailing
    }

    /// Appended to the system prompt for the one retry: says exactly what went wrong last time.
    public static func retryInstruction(for issues: [WritingIssue], source: String, tone: WritingTone = .preserve) -> String {
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
            case .excessiveChange where tone == .idiomatic:
                lines.append("- You rewrote too much in your own words. Keep the writer's words: change only errors, the phrases a native speaker would not use, and the order of a tangled sentence; leave the tone and the formality exactly as they are. If nothing needs changing, return the text unchanged.")
            case .excessiveChange:
                lines.append("- You changed far too much. Fix only definite grammar, spelling and punctuation errors; leave every other word, the word order, the tone and the formality exactly as they are. If nothing is wrong, return the text unchanged.")
            case .structureChanged:
                lines.append("- Keep every line and list marker (such as \"- \" or \"1. \") of the text; do not merge, split or drop lines.")
            case .added(let values):
                lines.append("- Do not add anything that is not in the text. These are not in it: " + values.joined(separator: ", "))
            case .leakedInstructions:
                lines.append("- Answer with the text only; never repeat these instructions.")
            case .notEnglish:
                lines.append("- Write the answer entirely in English: put every word of another language into English, write names from another script in Latin letters (Chinese names in pinyin), and use English punctuation.")
            case .addedList:
                lines.append("- Answer with the rewritten text only, as the text is laid out: no bullet points, numbering, notes or analysis.")
            case .voiceChanged(let changes):
                lines += changes.map { "- " + voiceInstruction(for: $0) }
            }
        }
        return lines.joined(separator: "\n")
    }

    /// Says what the last answer changed about how the writer sounds.
    static func voiceInstruction(for change: VoiceChange) -> String {
        switch change {
        case .lostQuestion: "The text asks a question: keep it a question."
        case .addedQuestion: "The text does not ask a question: do not turn it into one."
        case .lostExclamation: "Keep the exclamation marks of the text."
        case .addedExclamation: "Do not add exclamation marks."
        case .lostEmoji: "Keep every emoji of the text."
        case .addedEmoji: "Do not add emoji."
        case .lostContractions: "The text uses contractions (I'm, don't): keep them."
        case .addedContractions: "The text writes full forms (I will, is not): keep them; do not contract them."
        case .lostHedge: "Keep the writer's hedges (maybe, I think, probably)."
        case .addedHedge: "Do not soften the text with words such as maybe, might or a bit."
        case .addedStockPhrase(let phrase): "Do not add \"\(phrase)\"; the writer did not write it."
        case .lostInformal(let words): "Keep the writer's informal words exactly as written: " + words.joined(separator: ", ") + "."
        case .longer: "Your answer was much longer than the text: add nothing."
        case .shorter: "Your answer was much shorter than the text: leave nothing out."
        }
    }

    static func languageInstruction(for source: String) -> String {
        switch TextScript.of(source) {
        case .latin: "The text is in English: answer in English, do not translate it."
        // Lint edits English only; text with no English at all is never sent (`TextScript.hasEnglish`).
        case .han, .mixed: "The text mixes Chinese and English: change only the English; leave the Chinese exactly as written, and do not translate either part."
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
        /// Both failed and the task has no safe "no change" (a translation), or what is still wrong
        /// is only how the edit sounds (`WritingIssue.voiceChanged`): the better attempt is shown, with
        /// what is still wrong so the UI can say so.
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
        let stricter = systemPrompt + "\n\n" + WritingOutputGuard.retryInstruction(for: firstIssues, source: source, tone: tone)
        let second = WritingOutputGuard.tidy(try await generate(stricter, true), source: source)
        let secondIssues = WritingOutputGuard.assess(source: source, output: second, mode: mode, tone: tone)
        if secondIssues.isEmpty {
            return GuardedWritingResult(text: second, outcome: .acceptedAfterRetry(firstIssues: firstIssues), attempts: [first, second])
        }
        if policy.fallsBackToSource {
            // An attempt whose text is intact and only sounds a little different keeps its fixes; it is
            // shown flagged. The one that changed the voice least wins.
            let voiceOnly = [(first, firstIssues), (second, secondIssues)].filter { $0.1.allSatisfy(\.isVoiceOnly) }
            if let best = voiceOnly.min(by: { severity($0.1) < severity($1.1) }) {
                return GuardedWritingResult(text: best.0, outcome: .flagged(issues: best.1), attempts: [first, second])
            }
            return GuardedWritingResult(text: source, outcome: .keptSource(issues: secondIssues), attempts: [first, second])
        }
        let (text, issues) = severity(secondIssues) <= severity(firstIssues) ? (second, secondIssues) : (first, firstIssues)
        return GuardedWritingResult(text: text, outcome: .flagged(issues: issues), attempts: [first, second])
    }

    /// Fewer and smaller problems first; used only to pick between two failed attempts.
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
            case .notEnglish: total + 40
            case .addedList: total + 50
            case .voiceChanged(let changes): total + 5 * changes.count
            }
        }
    }
}
