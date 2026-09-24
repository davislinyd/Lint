import XCTest

@testable import LintCore

/// The deterministic checks an on-device (Apple Intelligence) answer goes through before it is shown.
final class WritingOutputGuardTests: XCTestCase {
    // MARK: - Protected literals

    func testURLsEmailsCodePathsAndNumbersAreRecognised() {
        let text = "Mail legal-team@example.com, see https://example.com/docs/v2?lang=zh-Hant. Run `make verify` in /etc/lint/config.yaml or config/settings.prod.yaml by 2026-11-03 14:30, total 1,250,000 (41.2%)."
        let found = ProtectedLiterals.extract(from: text)
        for expected in [
            "legal-team@example.com", "https://example.com/docs/v2?lang=zh-Hant", "`make verify`",
            "/etc/lint/config.yaml", "2026-11-03", "14:30", "1,250,000", "41.2",
        ] {
            XCTAssertTrue(found.contains(expected), "\(expected) not found in \(found)")
        }
        XCTAssertFalse(found.contains("https://example.com/docs/v2?lang=zh-Hant."), "sentence punctuation is not part of a URL")
        XCTAssertFalse(found.contains("2"), "a number inside a URL is already protected by the URL")
    }

    func testIPAddressesAndCodeLikeIdentifiersAreProtected() {
        let text = "Restart api-gw on 10.0.12.7, set max_retries in getUserConfig() and pass --dry-run on macOS."
        let found = ProtectedLiterals.extract(from: text)
        for expected in ["10.0.12.7", "max_retries", "getUserConfig()", "--dry-run", "macOS"] {
            XCTAssertTrue(found.contains(expected), "\(expected) not found in \(found)")
        }
        XCTAssertEqual(
            ProtectedLiterals.extract(from: "A well-known e-mail about the follow-up - nothing else.", kinds: [.identifier]), [],
            "ordinary hyphenated words and dashes are not identifiers"
        )
        XCTAssertEqual(
            WritingOutputGuard.assess(
                source: "Please set max_retries to 3 on 10.0.12.7 before the rollout tonight, thanks.",
                output: "Please set max retries to 3 on 10.0.12.7 before the rollout tonight, thanks.",
                mode: .proofread, tone: .preserve
            ),
            [.missing(["max_retries"])]
        )
    }

    func testListMarkersAndNamesAreNotNumbersButASingleDigitIs() {
        XCTAssertEqual(ProtectedLiterals.extract(from: "1. first\n2. second", kinds: [.number]), [], "list markers")
        XCTAssertEqual(ProtectedLiterals.extract(from: "back in 10", kinds: [.number]), ["10"])
        XCTAssertEqual(ProtectedLiterals.extract(from: "the session runs for 1 hour 45 minutes", kinds: [.number]), ["1", "45"])
        XCTAssertEqual(ProtectedLiterals.extract(from: "Q3 revenue and p95 latency", kinds: [.number]), [], "digits inside a name")
    }

    func testSpellingOutADigitIsCaughtInAPreserveProofread() {
        let source = "Please arrive before 09:15 on Monday; the session runs for 1 hour 45 minutes."
        XCTAssertEqual(
            WritingOutputGuard.assess(source: source, output: "Please arrive before 09:15 on Monday; the session runs for one hour 45 minutes.", mode: .proofread, tone: .preserve),
            [.missing(["1"])]
        )
    }

    func testMissingLiteralsAreReported() {
        let source = "Send it to a@b.co by 10/28, details at https://x.test/a."
        XCTAssertEqual(ProtectedLiterals.missing(from: "Send it to a@b.co by 10/28, details at https://x.test/a.", source: source, kinds: Set(ProtectedLiterals.Kind.allCases)), [])
        XCTAssertEqual(
            ProtectedLiterals.missing(from: "Send it to a@b.co by October 28, details at https://x.test.", source: source, kinds: Set(ProtectedLiterals.Kind.allCases)),
            ["https://x.test/a", "10/28"]
        )
    }

    // MARK: - Script and edit size

    func testTheScriptOfATextIgnoresURLsAndCode() {
        XCTAssertEqual(TextScript.of("The migration finished at 03:40."), .latin)
        XCTAssertEqual(TextScript.of("報告已經寄給客戶，對方確認收到了。"), .han)
        XCTAssertEqual(TextScript.of("這個 PR 我 review 過了，有幾個 edge case 還沒 handle"), .mixed)
        XCTAssertEqual(TextScript.of("設定檔在 /etc/lint/config.yaml，請看 https://example.com/ops/backup.sh。"), .han)
        XCTAssertEqual(TextScript.of("ok"), .undetermined)
    }

    func testOnlyEnglishInTheProseCountsAsEnglish() {
        XCTAssertTrue(TextScript.hasEnglish("Thanks for the update."))
        XCTAssertTrue(TextScript.hasEnglish("這個 bug 很怪"))
        XCTAssertFalse(TextScript.hasEnglish("報告已經寄給客戶，對方確認收到了。"))
        XCTAssertFalse(TextScript.hasEnglish("請看 https://example.com/ops 和 /etc/lint/config.yaml"), "a URL or a path is not English")
        XCTAssertFalse(TextScript.hasEnglish("12:30"))
    }

    func testTheEditRatioCountsWordsHanCharactersAndPunctuation() {
        XCTAssertEqual(EditRatio.tokens("I'm fine, 謝謝!"), ["I'm", "fine", ",", "謝", "謝", "!"])
        XCTAssertEqual(EditRatio.between("same text", "same text"), 0)
        XCTAssertEqual(EditRatio.between("", ""), 0)
        let fix = EditRatio.between(
            "I am agree with your opinion, but we should discuss about the schedule more detail.",
            "I agree with your opinion, but we should discuss the schedule in more detail."
        )
        XCTAssertLessThan(fix, WritingOutputGuard.maximumChangeRatio, "a real correction is well under the limit")
        let paraphrase = EditRatio.between(
            "Could you review my pull request when you have a moment? It only touches the login flow.",
            "When you get a chance, please take a look at my PR — the changes are limited to how users sign in."
        )
        XCTAssertGreaterThan(paraphrase, WritingOutputGuard.maximumChangeRatio, "a paraphrase is over it")
    }

    // MARK: - Assessment per task

    func testProofreadPreserveIsHeldToAMinimalEdit() {
        let source = "Could you review my pull request when you have a moment? It only touches the login flow."
        XCTAssertEqual(WritingOutputGuard.assess(source: source, output: source, mode: .proofread, tone: .preserve), [])
        let rewritten = "When you get a chance, please take a look at my PR — the changes are limited to how users sign in."
        let issues = WritingOutputGuard.assess(source: source, output: rewritten, mode: .proofread, tone: .preserve)
        XCTAssertTrue(
            issues.contains { if case .excessiveChange = $0 { return true } else { return false } },
            "a paraphrase of correct text must not pass as a proofread: \(issues)"
        )
        XCTAssertEqual(
            WritingOutputGuard.assess(source: source, output: rewritten, mode: .proofread, tone: .concise), [],
            "a tone rewrite is meant to change the wording"
        )
    }

    func testTheChangeLimitLeavesVeryShortTextAlone() {
        XCTAssertEqual(
            WritingOutputGuard.assess(source: "thx bro", output: "Thanks, bro.", mode: .proofread, tone: .preserve), [],
            "below the minimum length one fixed word is already a large share"
        )
    }

    func testAProofreadThatTranslatesIsCaught() {
        let english = "The migration finished at 03:40 with no errors."
        XCTAssertEqual(
            WritingOutputGuard.assess(source: english, output: "遷移於 03:40 完成，無錯誤。", mode: .proofread, tone: .preserve).first,
            .languageChanged(from: .latin, to: .han), "reported first; it is also an excessive change"
        )
        XCTAssertEqual(
            WritingOutputGuard.assess(source: "報告已經寄給客戶，對方確認收到了。", output: "The report has been sent and confirmed.", mode: .proofread, tone: .formal)
                .first, .languageChanged(from: .han, to: .latin), "every proofread tone keeps the language"
        )
        XCTAssertTrue(
            WritingOutputGuard.assess(source: "我們的 latency P99 目前是 380ms，跟 SLO 的 300ms 還有一段距離。", output: "Our P99 latency is currently 380ms, still above the 300ms SLO.", mode: .proofread, tone: .preserve)
                .contains { if case .languageChanged = $0 { return true } else { return false } },
            "mixed text that came back in one language"
        )
        XCTAssertEqual(
            WritingOutputGuard.assess(source: english, output: "遷移於 03:40 完成，無錯誤。", mode: .translate, tone: .preserve), [],
            "a translation changes language on purpose"
        )
    }

    func testLostLiteralsAreCaughtWhereTheTaskMustKeepThem() {
        let source = "Docs moved to https://example.com/docs, ping legal@example.com by 10/28."
        let lost = "Docs moved to our site, ping legal by October 28."
        let preserve = WritingOutputGuard.assess(source: source, output: lost, mode: .proofread, tone: .preserve)
        XCTAssertEqual(preserve.first, .missing(["https://example.com/docs", "legal@example.com", "10/28"]))
        // A tone rewrite or a translation may restate a date, but never lose a URL or an address.
        XCTAssertEqual(
            WritingOutputGuard.assess(source: source, output: lost, mode: .proofread, tone: .formal).first,
            .missing(["https://example.com/docs", "legal@example.com"])
        )
        XCTAssertEqual(
            WritingOutputGuard.assess(source: source, output: "文件搬到 https://example.com/docs，10 月 28 日前請聯絡 legal@example.com。", mode: .translate, tone: .preserve),
            []
        )
    }

    func testListsAndLinesSurviveAPreserveProofread() {
        let source = "- fix the login redirect\n- update the readme"
        XCTAssertEqual(WritingOutputGuard.assess(source: source, output: "- Fix the login redirect\n- Update the README", mode: .proofread, tone: .preserve), [])
        XCTAssertTrue(
            WritingOutputGuard.assess(source: source, output: "Fix the login redirect\nUpdate the README", mode: .proofread, tone: .preserve)
                .contains(.structureChanged)
        )
        XCTAssertEqual(
            WritingOutputGuard.assess(source: "a line here\nand another\nand a third one", output: "a line here and another\nand a third one", mode: .proofread, tone: .preserve),
            [.structureChanged], "two lines merged into one"
        )
        XCTAssertEqual(
            WritingOutputGuard.assess(source: source, output: "Fix the login redirect and update the README.", mode: .proofread, tone: .concise), [],
            "only the minimal edit holds the lines"
        )
    }

    // The next three are answers Apple's on-device model actually gave during the evaluation.

    func testMadeUpContentIsCaughtEvenInAToneRewrite() {
        let source = "This is totally broken and whoever shipped it clearly didn't test anything."
        let invented = "The shipment dated 2024/08/15 was delivered to alice.smith@example.com. The file /uploads/project-report-20240910.pdf contains the details."
        let issues = WritingOutputGuard.assess(source: source, output: invented, mode: .proofread, tone: .professional)
        guard case .added(let values) = issues.first(where: { if case .added = $0 { return true } else { return false } }) else {
            return XCTFail("\(issues)")
        }
        XCTAssertTrue(values.contains("alice.smith@example.com"))
        XCTAssertTrue(values.contains("2024/08/15"))
        XCTAssertEqual(
            WritingOutputGuard.assess(source: "We rolled back after ten minutes.", output: "我們在 10 分鐘後回復了版本。", mode: .translate, tone: .preserve), [],
            "a translation may write a spelled-out number as digits"
        )
    }

    func testAPreserveProofreadKeepsAcronymsButAToneRewriteMaySpellThemOut() {
        let source = "Thanks! I'll take a look at the PR this afternoon, the CI is green."
        let expanded = "Thanks! I'll take a look at the press release this afternoon, the CI is green."
        XCTAssertEqual(WritingOutputGuard.assess(source: source, output: expanded, mode: .proofread, tone: .preserve), [.missing(["PR"])])
        XCTAssertEqual(
            WritingOutputGuard.assess(source: "Please reply ASAP.", output: "Please reply as soon as possible.", mode: .proofread, tone: .formal), []
        )
        XCTAssertEqual(ProtectedLiterals.extract(from: "Meet at 3 PM (UTC+8) about MFA and HTTP2, OK?", kinds: [.acronym]), ["PM", "UTC", "MFA", "HTTP2", "OK"])
        XCTAssertEqual(ProtectedLiterals.extract(from: "I think a Q3 plan is fine.", kinds: [.acronym]), [], "one capital is not an acronym")
    }

    func testATemplateSlotTheTextDidNotHaveIsMadeUp() {
        // Measured: Apple's model, asked for a formal tone, opened a one-line text with a greeting slot.
        let source = "hey, just wanted to check if you got my last email about the contract. lmk asap thanks"
        let framed = "Dear [Name],\n\nI am writing to ask whether you received my last email about the contract."
        XCTAssertTrue(
            WritingOutputGuard.assess(source: source, output: framed, mode: .proofread, tone: .formal).contains(.added(["[Name]"]))
        )
        XCTAssertEqual(
            ProtectedLiterals.extract(from: "Hi {name}, order #{order_id} arrives in %d days, [Your Name]", kinds: [.placeholder]),
            ["{name}", "{order_id}", "%d", "[Your Name]"]
        )
        XCTAssertEqual(
            WritingOutputGuard.assess(source: "Hi {name}, your order ships in %d days.", output: "嗨 {name}，您的訂單將在 %d 天內出貨。", mode: .translate, tone: .preserve), [],
            "a translation keeps the slots it was given"
        )
    }

    func testFixingCapitalsIsNotAddingContent() {
        XCTAssertEqual(
            WritingOutputGuard.assess(
                source: "i talked to sarah from apple about the ios release on monday.",
                output: "I talked to Sarah from Apple about the iOS release on Monday.", mode: .proofread, tone: .preserve
            ), []
        )
    }

    func testAnAnswerThatRepeatsTheInstructionsIsCaught() {
        let source = "Hi team,\n\nheads up that the office will be close on 10/10. plan accordingly.\n\nThanks"
        let leaked = "IMPORTANT: your previous answer did not follow the instructions. Process the text again.\n\nHi team,\n\nThe office will be closed on 10/10."
        XCTAssertTrue(WritingOutputGuard.assess(source: source, output: leaked, mode: .proofread, tone: .formal).contains(.leakedInstructions))
    }

    func testChineseCreepingIntoEnglishIsCaught() {
        XCTAssertEqual(
            WritingOutputGuard.assess(source: "Noted. Will circle back after lunch.", output: "Noted。Will circle back after lunch。", mode: .proofread, tone: .preserve),
            [.languageChanged(from: .latin, to: .mixed)], "Chinese punctuation in English"
        )
        XCTAssertTrue(
            WritingOutputGuard.assess(
                source: "Please arrive before 09:15 on Monday; the session runs for 1 hour 45 minutes.",
                output: "Please arrive before 09:15 on Monday; the session runs for 1 小時 45 分鐘.", mode: .proofread, tone: .preserve
            ).contains(.languageChanged(from: .latin, to: .mixed)), "two words translated"
        )
        XCTAssertEqual(
            WritingOutputGuard.assess(source: "報告已經寄給客戶，對方確認收到了。", output: "報告已經寄給客戶，對方確認收到了。", mode: .proofread, tone: .preserve), [],
            "Chinese text keeps its own punctuation"
        )
    }

    func testEmptyAnswersAndLeakedReasoningAreCaught() {
        XCTAssertEqual(WritingOutputGuard.assess(source: "Hello there, friend.", output: "  \n", mode: .translate, tone: .preserve), [.empty])
        XCTAssertTrue(
            WritingOutputGuard.assess(source: "Hello there, friend.", output: "<think>hmm</think>Hello there, friend.", mode: .proofread, tone: .preserve)
                .contains(.leakedReasoning)
        )
    }

    func testACustomPromptIsNeverSecondGuessed() {
        XCTAssertNil(WritingGuardPolicy.for(mode: .custom, tone: .preserve))
        XCTAssertEqual(WritingOutputGuard.assess(source: "a b c d e f g h i j", output: "", mode: .custom, tone: .preserve), [])
    }

    // MARK: - Tidying

    func testTidyRemovesMarkdownLineBreaksAndKeepsTheSelectionsOwnWhitespace() {
        XCTAssertEqual(
            WritingOutputGuard.tidy("Hi Tom,  \n\nThanks.  \nAmy\n", source: "Hi Tom,\n\nThanks.\nAmy"),
            "Hi Tom,\n\nThanks.\nAmy"
        )
        XCTAssertEqual(WritingOutputGuard.tidy("\nFixed text.\n\n", source: "  broken text\n"), "  Fixed text.\n")
        XCTAssertEqual(
            WritingOutputGuard.tidy("line  \nnext", source: "line  \nnext"), "line  \nnext",
            "a source that uses trailing spaces itself keeps them"
        )
        XCTAssertEqual(
            WritingOutputGuard.tidy("I’ve attached “the” report.", source: "I've attached the report."),
            "I've attached \"the\" report.", "the text's straight quotes are kept"
        )
        XCTAssertEqual(
            WritingOutputGuard.tidy("It’s “done”.", source: "It’s done."), "It’s “done”.",
            "a text that already uses typographic quotes keeps them"
        )
    }

    // MARK: - Retry and fallback

    private final class Script: @unchecked Sendable {
        var answers: [String]
        var prompts: [String] = []
        var retries: [Bool] = []
        init(_ answers: [String]) { self.answers = answers }
        func next(_ prompt: String, _ isRetry: Bool) -> String {
            prompts.append(prompt)
            retries.append(isRetry)
            return answers.removeFirst()
        }
    }

    func testAGoodAnswerIsAcceptedWithOneRequest() async throws {
        let script = Script(["I agree with your opinion."])
        let result = try await GuardedWriter.run(source: "I am agree with your opinion.", mode: .proofread, tone: .preserve, systemPrompt: "P") {
            script.next($0, $1)
        }
        XCTAssertEqual(result.outcome, .accepted)
        XCTAssertEqual(result.text, "I agree with your opinion.")
        XCTAssertEqual(script.prompts, ["P"])
    }

    func testABadAnswerIsRetriedOnceWithTheProblemSpelledOut() async throws {
        let source = "The migration finished at 03:40 with no errors."
        let script = Script(["遷移於 03:40 完成。", source])
        let result = try await GuardedWriter.run(source: source, mode: .proofread, tone: .preserve, systemPrompt: "P") {
            script.next($0, $1)
        }
        XCTAssertEqual(result.text, source)
        guard case .acceptedAfterRetry(let firstIssues) = result.outcome else { return XCTFail("\(result.outcome)") }
        XCTAssertEqual(firstIssues.first, .languageChanged(from: .latin, to: .han))
        XCTAssertEqual(script.retries, [false, true])
        XCTAssertTrue(script.prompts[1].hasPrefix("P\n\n"), "the retry keeps the original prompt")
        XCTAssertTrue(script.prompts[1].contains("The text is in English"), "and says which language")
    }

    func testAProofreadThatFailsTwiceKeepsTheSourceAndNeverTriesAThirdTime() async throws {
        let source = "Could you review my pull request when you have a moment? It only touches the login flow."
        let paraphrase = "When you get a chance, please take a look at my PR — the changes are limited to how users sign in."
        let script = Script([paraphrase, paraphrase, paraphrase])
        let result = try await GuardedWriter.run(source: source, mode: .proofread, tone: .preserve, systemPrompt: "P") {
            script.next($0, $1)
        }
        XCTAssertEqual(result.text, source, "for a proofread, no change is the safe answer")
        guard case .keptSource = result.outcome else { return XCTFail("\(result.outcome)") }
        XCTAssertEqual(script.prompts.count, GuardedWriter.maximumAttempts)
        XCTAssertEqual(result.attempts.count, 2)
    }

    func testATranslationThatFailsTwiceShowsTheBetterAttemptFlagged() async throws {
        let source = "See https://example.com/a and https://example.com/b."
        let script = Script(["請見網站。", "請見 https://example.com/a 網站。"])
        let result = try await GuardedWriter.run(source: source, mode: .translate, tone: .preserve, systemPrompt: "P") {
            script.next($0, $1)
        }
        XCTAssertEqual(result.text, "請見 https://example.com/a 網站。", "the attempt that lost less")
        XCTAssertEqual(result.outcome, .flagged(issues: [.missing(["https://example.com/b"])]))
    }

    func testACustomPromptGetsExactlyOneUncheckedRequest() async throws {
        let script = Script([""])
        let result = try await GuardedWriter.run(source: "text", mode: .custom, tone: .preserve, systemPrompt: "P") {
            script.next($0, $1)
        }
        XCTAssertEqual(result.outcome, .accepted)
        XCTAssertEqual(script.prompts.count, 1)
    }

    func testEveryAttemptIsTidiedBeforeItIsJudged() async throws {
        let source = "Hi Tom,\n\nThe numbers look right to me.\n\nBest,\nAmy"
        let script = Script(["Hi Tom,  \n\nThe numbers look right to me.  \n\nBest,  \nAmy  "])
        let result = try await GuardedWriter.run(source: source, mode: .proofread, tone: .preserve, systemPrompt: "P") {
            script.next($0, $1)
        }
        XCTAssertEqual(result.text, source)
        XCTAssertEqual(result.outcome, .accepted)
    }
}
