import XCTest
@testable import LintCore

final class MemoryExtractorTests: XCTestCase {
    private func feedback(
        _ mode: WritingMode = .proofread,
        tone: WritingTone = .preserve,
        original: String,
        generated: String?,
        final: String? = nil
    ) -> LearningFeedback {
        LearningFeedback(
            gesture: .replaced, mode: mode, tone: tone, originalText: original, generatedText: generated,
            finalText: final ?? generated ?? "", provider: "localLlama", model: "qwen"
        )
    }

    private func extract(_ action: FeedbackAction, _ feedback: LearningFeedback) -> [MemoryCandidate] {
        MemoryExtractor().candidates(from: feedback, action: action)
    }

    private func keys(_ candidates: [MemoryCandidate]) -> [String] {
        candidates.map(\.dedupKey)
    }

    // MARK: golden cases

    func testUnnecessaryPrepositionAfterAVerb() throws {
        let found = extract(.accepted, feedback(
            original: "I think we need discuss about this issue.",
            generated: "I think we need to discuss this issue."
        ))
        XCTAssertEqual(keys(found), ["grammar:en:discuss about"])
        let memory = try XCTUnwrap(found.first)
        XCTAssertEqual(memory.kind, .grammar)
        XCTAssertEqual(memory.triggers, ["discuss about"])
        XCTAssertNil(memory.modeScope)
        let stored = [memory.instruction] + memory.triggers
        XCTAssertFalse(stored.contains { $0.contains("think we need") }, "the sentence must not be kept")
    }

    func testMissingArticle() throws {
        let found = extract(.accepted, feedback(
            original: "I have meeting tomorrow.", generated: "I have a meeting tomorrow."
        ))
        XCTAssertEqual(keys(found), ["grammar:en:articles"])
        XCTAssertTrue(try XCTUnwrap(found.first).triggers.isEmpty, "a habit has no trigger")
    }

    func testTwoMissingArticlesCountAsOnePattern() {
        let found = extract(.accepted, feedback(
            original: "I have meeting and need laptop.", generated: "I have a meeting and need a laptop."
        ))
        XCTAssertEqual(keys(found), ["grammar:en:articles"])
    }

    func testMisspelledWord() throws {
        let found = extract(.accepted, feedback(
            original: "From my prospective I think we should wait.",
            generated: "From my perspective I think we should wait."
        ))
        XCTAssertEqual(keys(found), ["spelling:en:prospective>perspective"])
        let memory = try XCTUnwrap(found.first)
        XCTAssertEqual(memory.kind, .spelling)
        XCTAssertEqual(memory.triggers, ["prospective"])
        XCTAssertTrue(memory.instruction.contains("prospective"))
        XCTAssertTrue(memory.instruction.contains("perspective"))
    }

    func testChineseTermEditedByTheUserIsTerminology() throws {
        let found = extract(.editedAndAccepted, feedback(
            original: "這個軟件需要更新",
            generated: "這個軟件需要更新",
            final: "這個軟體需要更新"
        ))
        XCTAssertEqual(keys(found), ["terminology:zh-Hant:軟件>軟體"])
        let memory = try XCTUnwrap(found.first)
        XCTAssertEqual(memory.kind, .terminology)
        XCTAssertEqual(memory.language, "zh-Hant")
        XCTAssertEqual(memory.triggers, ["軟件"], "the word is in the user's own text")
        XCTAssertNil(memory.modeScope)
    }

    func testAFixTheMemoryAskedForIsNotNewEvidenceButAnEditIs() {
        let asked: Set<String> = ["grammar:en:discuss about"]
        let fixed = feedback(original: "We should discuss about the plan.", generated: "We should discuss the plan.")
        XCTAssertEqual(keys(extract(.accepted, fixed)), ["grammar:en:discuss about"], "without the reminder it counts")
        XCTAssertTrue(MemoryExtractor().candidates(from: fixed, action: .accepted, injected: asked).isEmpty)
        XCTAssertTrue(
            MemoryExtractor().candidates(from: fixed, action: .copied, injected: asked).isEmpty,
            "copying the unchanged suggestion is the same accepted fix"
        )

        let edited = feedback(
            original: "We should discuss about the plan.",
            generated: "We should discuss about the plan.",
            final: "We should discuss the plan."
        )
        XCTAssertEqual(
            keys(MemoryExtractor().candidates(from: edited, action: .editedAndAccepted, injected: asked)),
            ["grammar:en:discuss about"], "the user's own edit still counts"
        )
    }

    func testAPatternTheModelAppliedAsRemindedIsReportedAsSuchNotAsEvidence() {
        let fixed = feedback(original: "We should discuss about the plan.", generated: "We should discuss the plan.")
        let reminded = MemoryExtractor().extraction(
            from: fixed, action: .accepted, injected: ["grammar:en:discuss about"]
        )
        XCTAssertTrue(reminded.candidates.isEmpty)
        XCTAssertEqual(reminded.reminded, ["grammar:en:discuss about"])

        let plain = MemoryExtractor().extraction(from: fixed, action: .accepted)
        XCTAssertEqual(plain.candidates.map(\.dedupKey), ["grammar:en:discuss about"])
        XCTAssertTrue(plain.reminded.isEmpty)

        let edited = feedback(
            original: "We should discuss about the plan.",
            generated: "We should discuss about the plan.",
            final: "We should discuss the plan."
        )
        let byTheUser = MemoryExtractor().extraction(
            from: edited, action: .editedAndAccepted, injected: ["grammar:en:discuss about"]
        )
        XCTAssertEqual(byTheUser.candidates.map(\.dedupKey), ["grammar:en:discuss about"])
        XCTAssertTrue(byTheUser.reminded.isEmpty, "the user's own edit is evidence, not a reminder working")
    }

    func testOnlyTheRemindedPatternIsLeftOut() {
        let found = MemoryExtractor().candidates(
            from: feedback(
                original: "We should discuss about the plan and buy laptop.",
                generated: "We should discuss the plan and buy a laptop."
            ),
            action: .accepted,
            injected: ["grammar:en:discuss about"]
        )
        XCTAssertEqual(keys(found), ["grammar:en:articles"])
    }

    // MARK: opposites and contradictions

    func testTheOppositeOfADirectionalMemoryIsItsKeyReversed() {
        XCTAssertEqual(
            MemoryExtractor.reversedKey(of: "spelling:en:prospective>perspective"),
            "spelling:en:perspective>prospective"
        )
        XCTAssertEqual(
            MemoryExtractor.reversedKey(of: "style:en:proofread|formal:need to>should"),
            "style:en:proofread|formal:should>need to"
        )
        XCTAssertEqual(
            MemoryExtractor.reversedKey(of: "terminology:zh-Hant:translate:軟件>軟體"),
            "terminology:zh-Hant:translate:軟體>軟件"
        )
        for key in ["grammar:en:articles", "grammar:en:discuss about", "nocolon", "a:>b", "a:b>", "a:x>y>z"] {
            XCTAssertNil(MemoryExtractor.reversedKey(of: key), key)
        }
    }

    func testTheOppositeEditProducesTheReversedKey() throws {
        let forward = extract(.editedAndAccepted, feedback(
            original: "I need a big house", generated: "I need a big house", final: "I need a large house"
        ))
        let backward = extract(.editedAndAccepted, feedback(
            original: "I need a large house", generated: "I need a large house", final: "I need a big house"
        ))
        let forwardKey = try XCTUnwrap(forward.first).dedupKey
        XCTAssertEqual(MemoryExtractor.reversedKey(of: forwardKey), try XCTUnwrap(backward.first).dedupKey)
        XCTAssertEqual(MemoryExtractor.reversedKey(of: MemoryExtractor.reversedKey(of: forwardKey) ?? ""), forwardKey)
    }

    func testAPrepositionPutBackAfterItsVerbContradictsTheMemoryThatDroppedIt() {
        let putBack = feedback(
            original: "We should discuss about the plan.",
            generated: "We should discuss the plan.",
            final: "We should discuss about the plan."
        )
        let result = MemoryExtractor().extraction(from: putBack, action: .editedAndAccepted)
        XCTAssertEqual(result.contradicted, ["grammar:en:discuss about"])
        XCTAssertTrue(result.candidates.isEmpty)
    }

    func testOnlyTheUsersOwnEditContradicts() {
        let modelAdded = feedback(original: "We should discuss the plan.", generated: "We should discuss about the plan.")
        XCTAssertTrue(MemoryExtractor().extraction(from: modelAdded, action: .accepted).contradicted.isEmpty)
        XCTAssertTrue(MemoryExtractor().extraction(from: modelAdded, action: .copied).contradicted.isEmpty)
    }

    func testAPronounOrACommonVerbBeforeThePrepositionIsNoContradiction() {
        for (generated, final) in [
            ("Please help me check this.", "Please help me to check this."),
            ("I will go home now.", "I will go to home now."),
        ] {
            let sample = feedback(original: generated, generated: generated, final: final)
            XCTAssertTrue(
                MemoryExtractor().extraction(from: sample, action: .editedAndAccepted).contradicted.isEmpty, final
            )
        }
    }

    func testAPatternEditedBothWaysInOneTextIsNoContradiction() {
        let both = feedback(
            original: "We discuss about the plan and discuss the budget.",
            generated: "We discuss about the plan and discuss the budget.",
            final: "We discuss the plan and discuss about the budget."
        )
        let result = MemoryExtractor().extraction(from: both, action: .editedAndAccepted)
        XCTAssertEqual(result.candidates.map(\.dedupKey), ["grammar:en:discuss about"])
        XCTAssertTrue(result.contradicted.isEmpty)
    }

    func testHeavyRewriteTeachesNothing() {
        XCTAssertTrue(extract(.accepted, feedback(
            original: "Please kindly help me to check this issue.",
            generated: "Could you please check this issue?"
        )).isEmpty)
    }

    func testWholesaleRewriteTeachesNothingEvenIfEachPartLooksLikeAHabit() {
        // Three unrelated three-word swaps: each would be a phrase replacement on its own.
        XCTAssertTrue(extract(.accepted, feedback(
            original: "cat dog bird and fish frog toad and worm ant bee",
            generated: "lion wolf hawk and shark newt slug and moth wasp flea"
        )).isEmpty)
    }

    func testAddressesNumbersAndPathsAreNeverRemembered() {
        XCTAssertTrue(extract(.accepted, feedback(
            original: "Send it to john@acme.com by 5pm.", generated: "Send it to john@acme.com by 6pm."
        )).isEmpty)
        XCTAssertTrue(extract(.accepted, feedback(
            original: "See notes.txt for details.", generated: "See notes.md for details."
        )).isEmpty)
        XCTAssertTrue(extract(.accepted, feedback(
            original: "Ping Sarah about it.", generated: "Ping Sara about it."
        )).isEmpty, "names are not remembered")
    }

    // MARK: which feedback teaches what

    func testRegeneratingAndMissingSuggestionsTeachNothing() {
        let sample = feedback(original: "I have meeting.", generated: "I have a meeting.")
        XCTAssertTrue(extract(.regenerated, sample).isEmpty)
        XCTAssertTrue(extract(.accepted, feedback(original: "I have meeting.", generated: nil)).isEmpty)
    }

    func testTranslationTeachesOnlyThroughTheUsersEdits() throws {
        let translated = feedback(
            .translate, original: "This software needs an update.",
            generated: "這個軟件需要更新", final: "這個軟件需要更新"
        )
        XCTAssertTrue(extract(.accepted, translated).isEmpty, "original and translation are different languages")

        let edited = feedback(
            .translate, original: "This software needs an update.",
            generated: "這個軟件需要更新", final: "這個軟體需要更新"
        )
        let found = extract(.editedAndAccepted, edited)
        XCTAssertEqual(keys(found), ["terminology:zh-Hant:translate:軟件>軟體"])
        let memory = try XCTUnwrap(found.first)
        XCTAssertEqual(memory.modeScope, .translate)
        XCTAssertTrue(memory.triggers.isEmpty, "the model's word is not in the English source, so it is a general habit")
    }

    func testAToneLearnsOnlyFromTheUsersEdits() throws {
        let sample = feedback(
            .proofread, tone: .formal, original: "I need a big house",
            generated: "I need a large house", final: "I need a huge house"
        )
        XCTAssertTrue(extract(.accepted, sample).isEmpty)
        let found = extract(.editedAndAccepted, sample)
        XCTAssertEqual(keys(found), ["vocabulary:en:proofread|formal:large>huge"])
        let memory = try XCTUnwrap(found.first)
        XCTAssertEqual(memory.modeScope, .proofread)
        XCTAssertEqual(memory.toneScope, .formal)
    }

    func testTheUsersEditUnderProfessionalIsScopedToProfessionalProofreading() throws {
        let sample = feedback(
            .proofread, tone: .professional, original: "I need a big house",
            generated: "I need a large house", final: "I need a huge house"
        )
        let memory = try XCTUnwrap(extract(.editedAndAccepted, sample).first)
        XCTAssertEqual(memory.dedupKey, "vocabulary:en:proofread|professional:large>huge")
        XCTAssertEqual([memory.modeScope, memory.toneScope] as [AnyHashable?], [WritingMode.proofread, WritingTone.professional])
    }

    func testEditsInDifferentTonesAreDifferentMemories() {
        var seen = Set<String>()
        for tone in WritingTone.allCases {
            let sample = feedback(
                .proofread, tone: tone, original: "I need a big house",
                generated: "I need a large house", final: "I need a huge house"
            )
            seen.formUnion(keys(extract(.editedAndAccepted, sample)))
        }
        XCTAssertEqual(seen.count, 4, "plain proofreading and each tone keep their own")
        XCTAssertTrue(seen.contains("vocabulary:en:large>huge"), "plain proofreading stays global")
    }

    func testTranslationStaysScopedToTranslationAndAToneOnlyWhenOneWasAsked() throws {
        func learned(_ tone: WritingTone) throws -> MemoryCandidate {
            try XCTUnwrap(extract(.editedAndAccepted, feedback(
                .translate, tone: tone, original: "This software needs an update.",
                generated: "這個軟件需要更新", final: "這個軟體需要更新"
            )).first)
        }
        let preserved = try learned(.preserve)
        XCTAssertEqual(preserved.dedupKey, "terminology:zh-Hant:translate:軟件>軟體", "as it always was")
        XCTAssertEqual(preserved.modeScope, .translate)
        XCTAssertNil(preserved.toneScope)

        let formal = try learned(.formal)
        XCTAssertEqual(formal.dedupKey, "terminology:zh-Hant:translate|formal:軟件>軟體")
        XCTAssertEqual(formal.toneScope, .formal)
    }

    func testProofreadingInAToneIsNotProofreadingTheModelsRewriteIsNotAHabit() {
        // The same correction that plain proofreading learns from is the tone's own rewrite here.
        for tone in [WritingTone.formal, .concise, .professional] {
            let sample = feedback(
                .proofread, tone: tone,
                original: "I have meeting tomorrow.", generated: "I have a meeting tomorrow."
            )
            for action in [FeedbackAction.accepted, .copied] {
                XCTAssertTrue(extract(action, sample).isEmpty, "\(tone) \(action)")
            }
        }
        let plain = feedback(original: "I have meeting tomorrow.", generated: "I have a meeting tomorrow.")
        XCTAssertEqual(keys(extract(.accepted, plain)), ["grammar:en:articles"])
    }

    func testTranslatingInAnyToneLearnsNothingFromTheModelsRewrite() {
        for tone in WritingTone.allCases {
            let sample = feedback(
                .translate, tone: tone,
                original: "This software needs an update.", generated: "這個軟件需要更新"
            )
            XCTAssertTrue(extract(.accepted, sample).isEmpty, "\(tone)")
        }
    }

    func testAToneOnACustomPromptIsNoTone() {
        let sample = feedback(
            .custom, tone: .formal, original: "I have meeting tomorrow.", generated: "I have a meeting tomorrow."
        )
        XCTAssertEqual(sample.tone, .preserve)
        XCTAssertTrue(extract(.accepted, sample).isEmpty, "a custom rewrite is not proofreading")
    }

    func testSpellingAndGrammarStayGlobalInEveryMode() throws {
        for (mode, tone) in [(WritingMode.proofread, WritingTone.concise), (.translate, .formal), (.custom, .preserve)] {
            let sample = feedback(
                mode, tone: tone, original: "From my perspective we wait",
                generated: "From my perspective we wait", final: "From my prospective we wait"
            )
            let found = extract(.editedAndAccepted, sample)
            XCTAssertEqual(keys(found), ["spelling:en:perspective>prospective"], "\(mode) \(tone)")
            let memory = try XCTUnwrap(found.first)
            XCTAssertNil(memory.modeScope)
            XCTAssertNil(memory.toneScope)
        }
    }

    func testCopyingLearnsFromTheDifferenceItActuallyShows() {
        let unchanged = feedback(original: "I have meeting.", generated: "I have a meeting.")
        XCTAssertEqual(keys(extract(.copied, unchanged)), ["grammar:en:articles"])

        let edited = feedback(original: "I need a big house", generated: "I need a big house", final: "I need a huge house")
        XCTAssertEqual(keys(extract(.copied, edited)), ["vocabulary:en:big>huge"])
    }

    // MARK: triggers

    func testAUserEditOfAModelWordIsATriggerOnlyWhenTheWordIsInTheSource() throws {
        let inSource = feedback(
            original: "I need a large house", generated: "I need a large house", final: "I need a huge house"
        )
        XCTAssertEqual(try XCTUnwrap(extract(.editedAndAccepted, inSource).first).triggers, ["large"])

        let notInSource = feedback(
            original: "I need a big house", generated: "I need a large house", final: "I need a huge house"
        )
        XCTAssertTrue(try XCTUnwrap(extract(.editedAndAccepted, notInSource).first).triggers.isEmpty)
    }

    func testAcceptedReplacementIsRemembered() throws {
        let found = extract(.accepted, feedback(
            original: "This is very big news.", generated: "This is very large news."
        ))
        let memory = try XCTUnwrap(found.first)
        XCTAssertEqual(memory.dedupKey, "vocabulary:en:big>large")
        XCTAssertEqual(memory.triggers, ["big"])
    }

    func testPhraseReplacementIsStyle() throws {
        let found = extract(.editedAndAccepted, feedback(
            original: "We must act now to fix it.",
            generated: "We must act now to fix it.",
            final: "We should act now to fix it."
        ))
        XCTAssertEqual(keys(found), ["vocabulary:en:must>should"])
        let phrase = extract(.editedAndAccepted, feedback(
            original: "I will send it. Kindly request your help.",
            generated: "I will send it. Kindly request your help.",
            final: "I will send it. Could you help."
        ))
        XCTAssertEqual(try XCTUnwrap(phrase.first).kind, .style)
    }

    func testSwapsOfFunctionWordsAreGrammarInContextNotAPreference() {
        XCTAssertTrue(extract(.accepted, feedback(
            original: "The server is down since yesterday.", generated: "The server has been down since yesterday."
        )).isEmpty)
    }

    func testTenseAndAgreementFixesAreNotSpellingSlips() {
        XCTAssertTrue(extract(.accepted, feedback(
            original: "We has a meeting yesterday.", generated: "We had a meeting yesterday."
        )).isEmpty)
    }

    func testAVeryCommonWordIsNeverATrigger() throws {
        let found = extract(.accepted, feedback(original: "Thanks for you reply.", generated: "Thanks for your reply."))
        XCTAssertEqual(keys(found), ["spelling:en:you>your"])
        XCTAssertTrue(try XCTUnwrap(found.first).triggers.isEmpty, "\"you\" would match nearly every text")
    }

    func testAPrepositionAfterAPronounOrACommonVerbIsLeftAlone() {
        XCTAssertTrue(extract(.accepted, feedback(
            original: "Could you help me to check this?", generated: "Could you help me check this?"
        )).isEmpty)
        XCTAssertTrue(extract(.accepted, feedback(
            original: "I will go to home now.", generated: "I will go home now."
        )).isEmpty)
    }

    func testFunctionWordsAloneAreNoTrigger() {
        XCTAssertTrue(extract(.accepted, feedback(original: "It is in the box.", generated: "It is on the box.")).isEmpty)
        XCTAssertEqual(
            keys(extract(.accepted, feedback(original: "It is a box.", generated: "It is the box."))),
            ["grammar:en:articles"]
        )
    }

    // MARK: typography

    func testSwitchingApostropheStyleIsNoHabit() {
        let found = extract(.accepted, feedback(
            original: "We don’t know why it can’t work.", generated: "We don't know why it can't work."
        ))
        XCTAssertTrue(found.isEmpty, "a model straightening quotes is not the user's spelling")
    }

    func testAKeyWritesTheApostropheTheSameWhicheverWayItWasTyped() throws {
        let found = extract(.editedAndAccepted, feedback(
            original: "I think we dont know.", generated: "I think we dont know.", final: "I think we don’t know."
        ))
        XCTAssertEqual(keys(found), ["spelling:en:dont>don't"])
        XCTAssertTrue(try XCTUnwrap(found.first).instruction.contains("don't"))
    }

    // MARK: safety of what is stored

    func testWordsAroundAnEditAreNeverStored() throws {
        let found = try XCTUnwrap(extract(.accepted, feedback(
            original: "From my prospective on 2026 we should wait.",
            generated: "From my perspective on 2026 we should wait."
        )).first)
        XCTAssertEqual(found.dedupKey, "spelling:en:prospective>perspective")
        let stored = ([found.dedupKey, found.instruction] + found.triggers).joined(separator: " ")
        for word in ["2026", "should", "wait", "From my"] {
            XCTAssertFalse(stored.contains(word), "\(word) is not part of the pattern")
        }
    }

    func testStoredTextOnlyHasSafeCharactersAndIsShort() {
        let samples = [
            feedback(original: "I think we need discuss about this issue.", generated: "I think we need to discuss this issue."),
            feedback(original: "From my prospective we wait.", generated: "From my perspective we wait."),
            feedback(original: "I have meeting.", generated: "I have a meeting."),
        ]
        for sample in samples {
            for memory in extract(.accepted, sample) {
                XCTAssertLessThanOrEqual(memory.instruction.count, 200)
                for trigger in memory.triggers {
                    XCTAssertLessThanOrEqual(trigger.count, MemorySanitizer.maxPhraseLength)
                    XCTAssertTrue(trigger.allSatisfy { $0.isLetter || $0 == " " || $0 == "'" || $0 == "-" }, trigger)
                }
                XCTAssertFalse(memory.instruction.contains("\n"))
            }
        }
    }

    // MARK: the same word in another form

    func testTheSameWordInAnotherFormIsAnInflection() {
        let inflections = [
            ("tickets", "ticket"), ("agent", "agents"), ("use", "used"), ("work", "worked"),
            ("box", "boxes"), ("consider", "considering"), ("company", "companies"), ("study", "studied"),
            ("manage", "managing"), ("large", "largest"), ("control", "controlled"), ("big", "bigger"),
            ("quick", "quickly"), ("easy", "easily"), ("user", "user's"), ("informations", "information"),
        ]
        for (a, b) in inflections {
            XCTAssertTrue(MemoryExtractor.isInflection(a, b), "\(a) / \(b)")
            XCTAssertTrue(MemoryExtractor.isInflection(b, a), "\(b) / \(a)")
        }
    }

    func testWordsThatAreOftenConfusedAreNoInflection() {
        let confusions = [
            ("recieve", "receive"), ("form", "from"), ("then", "than"), ("their", "there"), ("its", "it's"),
            ("lose", "loose"), ("advice", "advise"), ("affect", "effect"), ("quite", "quiet"), ("fine", "find"),
            ("here", "hers"), ("definately", "definitely"), ("led", "lead"), ("ticket", "ticket"),
        ]
        for (a, b) in confusions {
            XCTAssertFalse(MemoryExtractor.isInflection(a, b), "\(a) / \(b)")
            XCTAssertFalse(MemoryExtractor.isInflection(b, a), "\(b) / \(a)")
        }
    }
}
