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

    func testAnotherLanguageIsToldByItsScriptOrByTheRecognizer() {
        for text in [
            "내일 회의를 오후 3시로 옮겨도 될까요?", "내일 PR review 해주세요", "ขอโทษที่ตอบช้านะ", "すみません、あしたでもいいですか。",
            "Xin lỗi vì trả lời muộn, mai mình nói chuyện được không?", "Maaf baru balas, kemarin saya sibuk sekali.",
            "Ich finde den Plan zu riskant.", "감사합니다",
        ] {
            XCTAssertTrue(TextScript.isOtherLanguage(text), text)
        }
        for (text, why) in [
            ("Thanks for the update.", "English"),
            ("The invoice in 청구서_0412.pdf has two different amounts.", "a Korean file name in English text"),
            ("Bob pls ping Carol re: Q3 OKR", "the recognizer is not sure of casual English, and that is not enough"),
            ("Bitte", "too short to tell"),
            ("報告已經寄給客戶。", "Chinese is told by its script, not here"),
            ("See https://ko.example.com/안내 and /srv/데이터/a.txt", "a URL and a path are not prose"),
        ] {
            XCTAssertFalse(TextScript.isOtherLanguage(text), why)
        }
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

    func testIdiomaticHasRoomForARewrittenPhraseButNotForAParaphrase() {
        let source = "May I know when you will be free to have a call with us?"
        let idiomatic = "When would you be available for a call with us?"
        XCTAssertTrue(
            WritingOutputGuard.assess(source: source, output: idiomatic, mode: .proofread, tone: .preserve)
                .contains { if case .excessiveChange = $0 { true } else { false } },
            "more than a correction"
        )
        XCTAssertEqual(WritingOutputGuard.assess(source: source, output: idiomatic, mode: .proofread, tone: .idiomatic), [])
        let paraphrase = "Could you let us know a convenient time for a quick phone discussion sometime soon?"
        XCTAssertTrue(
            WritingOutputGuard.assess(source: source, output: paraphrase, mode: .proofread, tone: .idiomatic)
                .contains { if case .excessiveChange = $0 { true } else { false } }
        )
        let policy = try! XCTUnwrap(WritingGuardPolicy.for(mode: .proofread, tone: .idiomatic))
        XCTAssertTrue(policy.keepsLanguage && policy.limitsChange && policy.fallsBackToSource)
        XCTAssertEqual(policy.protectedKinds, Set(ProtectedLiterals.Kind.allCases), "numbers and acronyms stay, as in preserve")
        XCTAssertEqual(policy.maximumNewWordShare, WritingOutputGuard.idiomaticMaximumNewWordShare)
        XCTAssertNil(WritingGuardPolicy.for(mode: .proofread, tone: .preserve)?.maximumNewWordShare, "preserve stays a minimal edit")
    }

    // MARK: - A tangled sentence (idiomatic)

    /// A subject said twice around a Korean file name and product name; made up, like every fixture.
    private let tangled = "AI said the request item in the quotation file Daehan-20260115_SSD 견적(테스트코리아).xls, the request item \"삼성 SSD 1TB 중고\" is second-hand, is it?"
    private let rebuilt = "AI said the request item \"삼성 SSD 1TB 중고\" in the quotation file Daehan-20260115_SSD 견적(테스트코리아).xls is second-hand, is that correct?"

    func testAnIdiomaticEditMayPutASentenceInAnotherOrder() {
        XCTAssertEqual(WritingOutputGuard.assess(source: tangled, output: rebuilt, mode: .proofread, tone: .idiomatic), [])
        XCTAssertGreaterThan(EditRatio.between(tangled, rebuilt), 0.4, "by edit distance a moved phrase is nearly a rewrite")
        XCTAssertLessThan(WordNovelty.share(of: rebuilt, notIn: tangled), 0.1, "by its words it is the writer's own sentence")
        let paraphrase = "According to the AI, the drive listed in the vendor's spreadsheet appears to be a used unit rather than a new one. Could you confirm?"
        XCTAssertTrue(
            WritingOutputGuard.assess(source: tangled, output: paraphrase, mode: .proofread, tone: .idiomatic)
                .contains { if case .excessiveChange = $0 { true } else { false } }
        )
        XCTAssertEqual(
            WritingOutputGuard.assess(
                source: "Kindly revert back to me at the earliest.", output: "Please get back to me as soon as possible.",
                mode: .proofread, tone: .idiomatic
            ), [], "a short text is mostly its one rewritten phrase"
        )
    }

    func testTheShareOfNewWordsIgnoresOrderCaseAndPunctuation() {
        XCTAssertEqual(WordNovelty.share(of: "The report, please: send it today!", notIn: "please send the report today it"), 0)
        XCTAssertEqual(WordNovelty.share(of: "send send send", notIn: "send it"), 2.0 / 3.0, "a word counts as often as the text has it")
        XCTAssertEqual(WordNovelty.share(of: "Deliver the file", notIn: "send the report"), 2.0 / 3.0)
        XCTAssertEqual(WordNovelty.share(of: "…", notIn: "anything"), 0, "no words, nothing new")
        XCTAssertEqual(WordNovelty.words("It's second-hand, isn't it?"), ["it's", "second", "hand", "isn't", "it"])
    }

    func testWordsInAnotherScriptAreKeptAsWritten() {
        XCTAssertEqual(
            ProtectedLiterals.extract(from: "See 견적(테스트코리아).xls and \"삼성 SSD\", メモ, 發票, Привет, café and naïve.", kinds: [.foreignWord]),
            ["견적", "테스트코리아", "삼성", "メモ", "發票", "Привет"], "accented Latin is Latin"
        )
        let translated = "AI said the request item in the quotation file Daehan-20260115_SSD 견적(테스트코리아).xls, \"Samsung SSD 1TB used,\" is second-hand, is it?"
        for tone in [WritingTone.idiomatic, .preserve] {
            XCTAssertEqual(
                WritingOutputGuard.assess(source: tangled, output: translated, mode: .proofread, tone: tone), [.missing(["삼성", "중고"])], "\(tone)"
            )
        }
        XCTAssertTrue(
            WritingOutputGuard.retryInstruction(for: [.missing(["삼성", "중고"])], source: tangled, tone: .idiomatic).contains("삼성, 중고")
        )
        XCTAssertEqual(
            WritingOutputGuard.assess(source: "Please check the invoice.", output: "Please check the 청구서.", mode: .proofread, tone: .idiomatic),
            [.added(["청구서"])], "and none is brought in"
        )
        XCTAssertEqual(
            WritingOutputGuard.assess(source: "Please check the invoice today.", output: "請今天檢查發票。", mode: .proofread, tone: .idiomatic),
            [.languageChanged(from: .latin, to: .han)], "a change of language is reported once, as that"
        )
        // The tones that write English from Chinese, and a translation, are not held to it.
        for (mode, tone) in [(WritingMode.proofread, WritingTone.native), (.translate, .preserve), (.proofread, .formal)] {
            XCTAssertFalse(WritingGuardPolicy.for(mode: mode, tone: tone)!.protectedKinds.contains(.foreignWord), "\(mode)/\(tone)")
        }
    }

    func testOnlyIdiomaticGuardsLintsOwnModel() {
        for mode in WritingMode.allCases {
            for tone in WritingTone.allCases {
                XCTAssertEqual(
                    WritingGuardPolicy.guardsLocalModel(mode: mode, tone: tone), mode == .proofread && tone == .idiomatic, "\(mode)/\(tone)"
                )
            }
        }
    }

    func testTheRetryForAnIdiomaticEditStillAllowsNativePhrasing() {
        let issues = [WritingIssue.excessiveChange(ratio: 0.8)]
        let idiomatic = WritingOutputGuard.retryInstruction(for: issues, source: "x", tone: .idiomatic)
        XCTAssertTrue(idiomatic.contains("the phrases a native speaker would not use"))
        XCTAssertTrue(idiomatic.contains("the order of a tangled sentence"), "putting a sentence in order is still allowed")
        XCTAssertFalse(idiomatic.contains("the word order"))
        XCTAssertFalse(idiomatic.contains("Fix only definite grammar"))
        XCTAssertTrue(WritingOutputGuard.retryInstruction(for: issues, source: "x").contains("Fix only definite grammar"))
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

    // MARK: native speaker

    func testANativeRewriteOfChineseIsAcceptedAsEnglish() {
        let source = "我已經把報告寄給客戶了，他們說 10/15 前會回覆。詳情在 https://example.com/report"
        let output = "I've sent the report to the client. They said they'd get back to us by October 15. Details are at https://example.com/report"
        XCTAssertEqual(WritingOutputGuard.assess(source: source, output: output, mode: .proofread, tone: .native), [])
        XCTAssertEqual(
            WritingOutputGuard.assess(
                source: "- 修好登入問題\n- 更新 README", output: "Fixed the login bug, and updated the README.",
                mode: .proofread, tone: .native
            ), [], "a native rewrite is free to regroup lines"
        )
    }

    func testANativeRewriteIsNotHeldToAMinimalEditOrToTheTextsLanguage() {
        let source = "Sorry I reply late, I was very busy on the last days, so I not see your message."
        let output = "Sorry for the late reply. I've been swamped the past few days and missed your message."
        XCTAssertEqual(WritingOutputGuard.assess(source: source, output: output, mode: .proofread, tone: .native), [])
        XCTAssertEqual(
            WritingOutputGuard.assess(source: "明天下午三點開會，請準時。", output: "The meeting is at 3 PM tomorrow, so please be on time.", mode: .proofread, tone: .native), [],
            "Han in, Latin out is what it is for"
        )
    }

    func testANativeRewriteThatIsNotEnglishIsCaught() {
        let source = "我已經把報告寄給客戶了。"
        for (output, why) in [
            ("我已經把報告寄給客戶了。", "came back in Chinese"),
            ("I sent 報告 to the client.", "a Chinese word left in"),
            ("Please send it to 王小明.", "a name left in Han"),
            ("I sent the report to the client。", "Chinese punctuation"),
            ("I sent the report to the “client”, 「Amy」.", "corner brackets"),
        ] {
            XCTAssertTrue(
                WritingOutputGuard.assess(source: source, output: output, mode: .proofread, tone: .native).contains(.notEnglish), why
            )
        }
        XCTAssertFalse(
            WritingOutputGuard.assess(source: "Thanks for the update.", output: "Thanks for the update.", mode: .proofread, tone: .native).contains(.notEnglish)
        )
        for source in ["내일 회의를 오후 3시로 옮겨도 될까요?", "Maaf baru balas, kemarin saya sibuk sekali."] {
            XCTAssertTrue(
                WritingOutputGuard.assess(source: source, output: source, mode: .proofread, tone: .native).contains(.notEnglish),
                "came back in its own language: \(source)"
            )
        }
        XCTAssertFalse(
            WritingOutputGuard.assess(
                source: "청구서_0412.pdf 금액이 두 개가 달라요", output: "The amounts in 청구서_0412.pdf don't match.", mode: .proofread, tone: .native
            ).contains(.notEnglish), "a Korean file name kept in English"
        )
    }

    func testEveryNativeStyleIsHeldToTheSamePolicyAsTheNativeTone() {
        let policy = WritingGuardPolicy.for(mode: .proofread, tone: .native)
        XCTAssertEqual(policy?.requiresEnglish, true)
        let source = "我已經把報告寄給客戶了。"
        for tone in WritingTone.allCases.filter(\.isNative) {
            XCTAssertEqual(WritingGuardPolicy.for(mode: .proofread, tone: tone), policy, "\(tone)")
            XCTAssertEqual(
                WritingOutputGuard.assess(source: source, output: "I sent the report to the client already, tbh.", mode: .proofread, tone: tone), [], "\(tone)"
            )
            XCTAssertEqual(
                WritingOutputGuard.assess(source: source, output: "我已經把報告寄給客戶了。", mode: .proofread, tone: tone), [.notEnglish], "\(tone)"
            )
            XCTAssertEqual(WritingGuardPolicy.for(mode: .translate, tone: tone)?.requiresEnglish, false, "a translation is not asked for English")
        }
    }

    func testOnlyANativeRewriteMustBeEnglish() {
        for (mode, tone) in [(WritingMode.proofread, WritingTone.preserve), (.proofread, .formal), (.translate, .preserve), (.custom, .preserve)] {
            XCTAssertFalse(
                WritingOutputGuard.assess(source: "Thanks for the update.", output: "謝謝你的更新。", mode: mode, tone: tone).contains(.notEnglish), "\(mode)/\(tone)"
            )
        }
    }

    func testANativeRewriteStillHasToKeepURLsAndCodeAndInventNothing() {
        let source = "請看 https://status.example.com/incident 然後跑 `make reset`，檔案在 ~/logs/app.log"
        XCTAssertEqual(
            WritingOutputGuard.assess(source: source, output: "Please check the status page and run the reset command.", mode: .proofread, tone: .native),
            [.missing(["https://status.example.com/incident", "`make reset`", "~/logs/app.log"])]
        )
        let invented = WritingOutputGuard.assess(
            source: "請把報告寄給客戶。", output: "Please send the report to bob@example.com.", mode: .proofread, tone: .native
        )
        XCTAssertEqual(invented, [.added(["bob@example.com"])])
    }

    func testANativeRewriteThatTurnsTheTextIntoBulletsIsCaught() {
        let notes = "- The message: A build failed again.\n- The intent: A request for assistance.\n\nCan someone check the build?"
        XCTAssertTrue(
            WritingOutputGuard.assess(source: "ugh, the build broke again 😩 can someone take a look?", output: notes, mode: .proofread, tone: .native)
                .contains(.addedList)
        )
        XCTAssertEqual(
            WritingOutputGuard.assess(source: "Please reply me as soon as possible.", output: "1. Please get back to me ASAP.", mode: .proofread, tone: .nativeCasual),
            [.addedList], "one numbered line is a list too"
        )
        XCTAssertFalse(
            WritingOutputGuard.assess(
                source: "- 確認客戶的付款狀態\n- 把發票寄給財務部", output: "- Check the client's payment status\n- Send the invoice to finance",
                mode: .proofread, tone: .native
            ).contains(.addedList), "the text's own list stays a list"
        )
        XCTAssertFalse(
            WritingOutputGuard.assess(source: "這週我比較忙，下週再約可以嗎？", output: "I'm swamped this week.\nCould we meet next week instead?", mode: .proofread, tone: .native)
                .contains(.addedList), "a native rewrite may split lines"
        )
    }

    func testANativeRewriteWithNotesIsRetriedAsPlainText() async throws {
        let source = "May I know when you will be free to have a call with us?"
        let answered = "- I'll check my calendar and get back to you soon.\n- I'm tied up right now, so let me know a good window for us."
        let rewrite = "When would you be free for a call with us?"
        let script = Script([answered, rewrite])
        let result = try await GuardedWriter.run(source: source, mode: .proofread, tone: .native, systemPrompt: "P") {
            script.next($0, $1)
        }
        XCTAssertEqual(result.text, rewrite)
        XCTAssertEqual(result.outcome, .acceptedAfterRetry(firstIssues: [.addedList]))
        XCTAssertTrue(script.prompts[1].contains("no bullet points, numbering, notes or analysis"))
    }

    func testTheRetryForANativeRewriteSaysToWriteEnglish() {
        let lines = WritingOutputGuard.retryInstruction(for: [.notEnglish], source: "我已經把報告寄給客戶了。")
        XCTAssertTrue(lines.contains("entirely in English"))
        XCTAssertTrue(lines.contains("pinyin"))
        XCTAssertFalse(lines.contains("do not translate"), "that is the opposite of what a native rewrite is asked for")
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

    func testANativeRewriteThatStaysChineseIsRetriedInEnglish() async throws {
        let source = "我已經把報告寄給客戶了。"
        let script = Script(["我已經把報告寄給客戶了。", "I've sent the report to the client."])
        let result = try await GuardedWriter.run(source: source, mode: .proofread, tone: .native, systemPrompt: "P") {
            script.next($0, $1)
        }
        XCTAssertEqual(result.text, "I've sent the report to the client.")
        XCTAssertEqual(result.outcome, .acceptedAfterRetry(firstIssues: [.notEnglish]))
        XCTAssertTrue(script.prompts[1].hasPrefix("P\n\n"))
        XCTAssertTrue(script.prompts[1].contains("entirely in English"))
    }

    func testANativeRewriteThatFailsTwiceIsFlaggedNeverReplacedByItsChineseSource() async throws {
        let source = "我已經把報告寄給客戶了。"
        let script = Script(["我已經把報告寄給客戶了。", "I sent 報告 to the client."])
        let result = try await GuardedWriter.run(source: source, mode: .proofread, tone: .native, systemPrompt: "P") {
            script.next($0, $1)
        }
        XCTAssertEqual(result.text, "I sent 報告 to the client.", "the source is no answer to a request for English")
        XCTAssertEqual(result.outcome, .flagged(issues: [.notEnglish]))
        XCTAssertEqual(script.prompts.count, GuardedWriter.maximumAttempts)
    }

    func testACustomPromptGetsExactlyOneUncheckedRequest() async throws {
        let script = Script([""])
        let result = try await GuardedWriter.run(source: "text", mode: .custom, tone: .preserve, systemPrompt: "P") {
            script.next($0, $1)
        }
        XCTAssertEqual(result.outcome, .accepted)
        XCTAssertEqual(script.prompts.count, 1)
    }

    // MARK: - The writer's voice (idiomatic)

    private let fullForms = "Sorry for letting you wait so long. I will send the report before 5 pm."
    private let contracted = "Sorry to keep you waiting so long. I'll send the report before 5 pm."
    private let keptVoice = "Sorry to keep you waiting so long. I will send the report before 5 pm."

    func testOnlyIdiomaticIsHeldToTheWritersVoice() {
        XCTAssertEqual(
            WritingOutputGuard.assess(source: fullForms, output: contracted, mode: .proofread, tone: .idiomatic),
            [.voiceChanged([.addedContractions])]
        )
        XCTAssertEqual(WritingOutputGuard.assess(source: fullForms, output: keptVoice, mode: .proofread, tone: .idiomatic), [])
        for tone in WritingTone.allCases where tone != .idiomatic {
            XCTAssertFalse(
                WritingOutputGuard.assess(source: fullForms, output: contracted, mode: .proofread, tone: tone).contains { $0.isVoiceOnly },
                "\(tone)"
            )
        }
    }

    func testAVoiceChangeIsRetriedWithWhatChanged() async throws {
        let script = Script([contracted, keptVoice])
        let result = try await GuardedWriter.run(source: fullForms, mode: .proofread, tone: .idiomatic, systemPrompt: "P") {
            script.next($0, $1)
        }
        XCTAssertEqual(result.text, keptVoice)
        XCTAssertEqual(result.outcome, .acceptedAfterRetry(firstIssues: [.voiceChanged([.addedContractions])]))
        XCTAssertTrue(script.prompts[1].contains("The text writes full forms (I will, is not): keep them"), script.prompts[1])
    }

    func testAnEditThatOnlySoundsDifferentKeepsItsFixesFlagged() async throws {
        let moreContracted = "Sorry to keep you waiting so long! I'll send the report before 5 pm."
        let script = Script([moreContracted, contracted])
        let result = try await GuardedWriter.run(source: fullForms, mode: .proofread, tone: .idiomatic, systemPrompt: "P") {
            script.next($0, $1)
        }
        XCTAssertEqual(result.text, contracted, "the attempt that changed the voice least")
        XCTAssertEqual(result.outcome, .flagged(issues: [.voiceChanged([.addedContractions])]))
    }

    func testAVoiceChangeDoesNotRescueAnAnswerThatLostContent() async throws {
        let lostTime = "Sorry to keep you waiting so long. I'll send the report soon."
        let script = Script([lostTime, lostTime])
        let result = try await GuardedWriter.run(source: fullForms, mode: .proofread, tone: .idiomatic, systemPrompt: "P") {
            script.next($0, $1)
        }
        XCTAssertEqual(result.text, fullForms, "a lost time is not a matter of tone")
        guard case .keptSource = result.outcome else { return XCTFail("\(result.outcome)") }

        let rewritten = "Apologies for the delay; you can expect the finished document on your desk before 5 pm, without fail."
        let fallback = Script([contracted, rewritten])
        let better = try await GuardedWriter.run(source: fullForms, mode: .proofread, tone: .idiomatic, systemPrompt: "P") {
            fallback.next($0, $1)
        }
        XCTAssertEqual(better.text, contracted, "the first answer, whose only problem was its voice")
        XCTAssertEqual(better.outcome, .flagged(issues: [.voiceChanged([.addedContractions])]))
    }

    func testEveryVoiceChangeHasARetryInstruction() {
        let changes: [VoiceChange] = [
            .lostQuestion, .addedQuestion, .lostExclamation, .addedExclamation, .lostEmoji, .addedEmoji,
            .lostContractions, .addedContractions, .lostHedge, .addedHedge, .addedStockPhrase("kindly"),
            .lostInformal(["wanna", "lol"]), .longer(ratio: 2), .shorter(ratio: 0.4),
        ]
        let instruction = WritingOutputGuard.retryInstruction(for: [.voiceChanged(changes)], source: fullForms, tone: .idiomatic)
        XCTAssertEqual(instruction.split(separator: "\n").count, changes.count + 1)
        XCTAssertTrue(instruction.contains("Do not add \"kindly\""))
        XCTAssertTrue(instruction.contains("wanna, lol"))
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
