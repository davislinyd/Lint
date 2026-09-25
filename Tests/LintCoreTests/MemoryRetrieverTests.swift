import XCTest
@testable import LintCore

final class MemoryRetrieverTests: XCTestCase {
    private var counter = 0
    /// The fixtures were last confirmed now, so nothing has faded unless a test says so.
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func memory(
        _ key: String,
        kind: MemoryKind = .grammar,
        language: String = "en",
        scope: WritingMode? = nil,
        tone: WritingTone? = nil,
        triggers: [String] = [],
        state: MemoryState = .active,
        evidence: Double = 1.2,
        count: Int = 3,
        instruction: String? = nil,
        level: MemoryLevel = .specific,
        supersededBy: UUID? = nil
    ) -> WritingMemory {
        counter += 1
        return WritingMemory(
            id: UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", counter))!,
            dedupKey: key, kind: kind, language: language,
            modeScope: scope, toneScope: tone, triggers: triggers,
            instruction: instruction ?? "rule for \(key)",
            evidenceScore: evidence, occurrenceCount: count, state: state, userEdited: false,
            createdAt: now, lastConfirmedAt: now, level: level, supersededBy: supersededBy
        )
    }

    private func keys(
        _ memories: [WritingMemory],
        _ text: String,
        mode: WritingMode = .proofread,
        tone: WritingTone = .preserve,
        outputLanguage: String? = nil
    ) -> [String] {
        MemoryRetriever(memories: memories, now: now)
            .select(for: .init(text: text, mode: mode, tone: tone, outputLanguage: outputLanguage))
            .map(\.dedupKey)
    }

    private let english = "From my prospective I think we should wait until tomorrow."

    // MARK: lexical channel

    func testATriggerSelectsItsMemoryOnlyWhenTheTextHasIt() {
        let memories = [
            memory("prospective", kind: .spelling, triggers: ["prospective"]),
            memory("recieve", kind: .spelling, triggers: ["recieve"]),
        ]
        XCTAssertEqual(keys(memories, english), ["prospective"])
        XCTAssertEqual(keys(memories, "We will recieve it soon enough."), ["recieve"])
        XCTAssertEqual(keys(memories, "Nothing to see in this sentence at all."), [])
    }

    func testAPhraseTriggerNeedsItsWordsNextToEachOtherInAnyCase() {
        let memories = [memory("discuss about", triggers: ["discuss about"])]
        XCTAssertEqual(keys(memories, "We should Discuss About the roadmap."), ["discuss about"])
        XCTAssertEqual(keys(memories, "We discuss it about the roadmap."), [])
    }

    func testAChineseTriggerMatchesAsASubstring() {
        // A translation's (a proofread is never reminded of Chinese).
        let memories = [memory("軟件", kind: .terminology, language: "zh-Hant", triggers: ["軟件"])]
        XCTAssertEqual(keys(memories, "這個軟件需要更新", mode: .translate), ["軟件"])
        XCTAssertEqual(keys(memories, "這個軟體需要更新", mode: .translate), [])
    }

    func testAProofreadIsNeverRemindedOfChinese() {
        // Lint edits English only; a Chinese term still serves a translation, which writes Chinese.
        let memories = [
            memory("軟件", kind: .terminology, language: "zh-Hant", triggers: ["軟件"]),
            memory("recieve", kind: .spelling, triggers: ["recieve"]),
        ]
        let mixed = "請先 recieve 這個軟件再說"
        XCTAssertEqual(keys(memories, mixed), ["recieve"])
        XCTAssertEqual(keys(memories, mixed, tone: .formal), ["recieve"])
        XCTAssertEqual(keys(memories, "Install the 軟件 first.", mode: .translate, outputLanguage: "zh-Hant"), ["軟件"])
    }

    func testAnApostropheMatchesWhicheverWayItIsWritten() {
        let plain = [memory("cant", kind: .spelling, triggers: ["can't"])]
        XCTAssertEqual(keys(plain, "We can’t wait until tomorrow."), ["cant"])
        XCTAssertEqual(keys(plain, "We can't wait until tomorrow."), ["cant"])
        // A trigger stored the other way still works.
        let typographic = [memory("cant", kind: .spelling, triggers: ["can’t"])]
        XCTAssertEqual(keys(typographic, "We can't wait until tomorrow."), ["cant"])
    }

    func testATriggerNeedsItsLanguageToShowUpInTheText() {
        let memories = [memory("prospective", kind: .spelling, triggers: ["prospective"])]
        XCTAssertEqual(keys(memories, "prospective"), ["prospective"])
        let chinese = [memory("軟件", language: "zh-Hant", triggers: ["軟件"])]
        XCTAssertEqual(keys(chinese, "the word 軟件 in an English sentence", mode: .translate), ["軟件"])
        XCTAssertEqual(keys([memory("x", language: "zh-Hant", triggers: ["abc"])], "abc abc abc"), [])
    }

    // MARK: habit channel

    func testAHabitAppliesToTextClearlyInItsLanguage() {
        let habit = [memory("articles")]
        XCTAssertEqual(keys(habit, "I have meeting tomorrow and need laptop"), ["articles"])
        XCTAssertEqual(keys(habit, "明天下午三點在會議室討論預算"), [])
        XCTAssertEqual(keys(habit, "hi there"), [])
    }

    func testHabitSlotsAreCappedAndTheBestOnesTakeThem() {
        let habits = [
            memory("weak", evidence: 1.0, count: 1),
            memory("strong", evidence: 9.0, count: 9),
            memory("middle", evidence: 3.0, count: 4),
            memory("weakest", evidence: 1.0, count: 1),
        ]
        XCTAssertEqual(keys(habits, "I have meeting tomorrow and need laptop"), ["strong", "middle"])
    }

    func testTriggeredMemoriesOutrankHabitsAndTheTotalIsCapped() {
        var memories = (0..<7).map { memory("lex\($0)", kind: .spelling, triggers: ["prospective"], evidence: Double($0 + 1)) }
        memories.append(memory("habit", evidence: 50, count: 50))
        let result = keys(memories, english)
        XCTAssertEqual(result.count, MemoryPolicy.maxPersonalizedMemories)
        XCTAssertFalse(result.contains("habit"))
        XCTAssertEqual(result, ["lex6", "lex5", "lex4", "lex3", "lex2"])
    }

    // MARK: eligibility

    func testShortTermLongTermAndPinnedMemoriesAreRetrieved() {
        let memories = [
            memory("short-term", triggers: ["prospective"], state: .candidate, evidence: 0.15, count: 1),
            memory("disabled", triggers: ["prospective"], state: .disabled),
            memory("forgotten", triggers: ["prospective"], state: .archived),
            memory("long-term", triggers: ["prospective"], state: .active),
            memory("pinned", triggers: ["prospective"], state: .pinned),
        ]
        XCTAssertEqual(Set(keys(memories, english)), ["short-term", "long-term", "pinned"])
    }

    func testALongTermMemoryComesBeforeAShortTermOne() {
        let shortTerm = memory("short-term", triggers: ["prospective"], state: .candidate, evidence: 0.35, count: 1)
        let longTerm = memory("long-term", triggers: ["prospective"], state: .active)
        XCTAssertEqual(keys([shortTerm, longTerm], english), ["long-term", "short-term"])
        XCTAssertEqual(keys([longTerm, shortTerm], english), ["long-term", "short-term"])
    }

    func testAShortTermMemoryThatRanOutOrWaitsForItsPatternIsNotRetrieved() {
        var ranOut = memory("ran-out", triggers: ["prospective"], state: .candidate, evidence: 0.35, count: 1)
        ranOut.lastConfirmedAt = now.addingTimeInterval(-(MemoryPolicy.shortTermDays + 1) * 86_400)
        let waits = memory(
            "vocabulary:en:prospective>perspective", kind: .vocabulary, triggers: ["prospective"],
            state: .candidate, evidence: 0.15, count: 1,
            instruction: MemoryWording.acceptedReplacement(from: "prospective", to: "perspective").chinese
        )
        XCTAssertTrue(keys([ranOut, waits], english).isEmpty)
    }

    func testPinnedMemoriesComeFirst() {
        let memories = [
            memory("strong", triggers: ["prospective"], evidence: 30, count: 30),
            memory("pinned", triggers: ["prospective"], state: .pinned, evidence: 0.1, count: 1),
        ]
        XCTAssertEqual(keys(memories, english), ["pinned", "strong"])
    }

    func testModeScopeKeepsMemoriesToTheirMode() {
        let memories = [
            memory("global", triggers: ["prospective"]),
            memory("formal", scope: .proofread, tone: .formal, triggers: ["prospective"]),
            memory("translate", scope: .translate, triggers: ["prospective"]),
        ]
        XCTAssertEqual(Set(keys(memories, english, mode: .proofread)), ["global"])
        XCTAssertEqual(Set(keys(memories, english, mode: .proofread, tone: .formal)), ["global", "formal"])
        XCTAssertEqual(Set(keys(memories, english, mode: .translate)), ["global", "translate"])
        XCTAssertEqual(Set(keys(memories, english, mode: .translate, tone: .formal)), ["global", "translate"])
    }

    func testToneScopeKeepsMemoriesToTheirTone() {
        let memories = [
            memory("global", triggers: ["prospective"]),
            memory("professional", scope: .proofread, tone: .professional, triggers: ["prospective"]),
            memory("concise", scope: .proofread, tone: .concise, triggers: ["prospective"]),
            memory("translate-formal", scope: .translate, tone: .formal, triggers: ["prospective"]),
            memory("translate-any", scope: .translate, triggers: ["prospective"]),
        ]
        func found(_ mode: WritingMode, _ tone: WritingTone) -> Set<String> {
            Set(keys(memories, english, mode: mode, tone: tone))
        }
        XCTAssertEqual(found(.proofread, .preserve), ["global"])
        XCTAssertEqual(found(.proofread, .professional), ["global", "professional"])
        XCTAssertEqual(found(.proofread, .concise), ["global", "concise"])
        XCTAssertEqual(found(.proofread, .formal), ["global"])
        XCTAssertEqual(found(.translate, .formal), ["global", "translate-formal", "translate-any"])
        XCTAssertEqual(found(.translate, .professional), ["global", "translate-any"])
        XCTAssertEqual(found(.custom, .preserve), ["global"])
    }

    func testAMemoryScopedToATaskAloneAppliesInEveryToneOfIt() {
        let memories = [memory("proofreading", scope: .proofread, triggers: ["prospective"])]
        for tone in WritingTone.allCases {
            XCTAssertEqual(keys(memories, english, mode: .proofread, tone: tone), ["proofreading"], "\(tone)")
        }
        XCTAssertEqual(keys(memories, english, mode: .translate), [])
    }

    func testATranslationMemoryOfATonePairsTheToneWithTheOutputLanguage() {
        let text = "This software needs an update."
        let term = memory("軟件>軟體", kind: .terminology, language: "zh-Hant", scope: .translate, tone: .professional)
        XCTAssertEqual(
            keys([term], text, mode: .translate, tone: .professional, outputLanguage: "zh-Hant"), ["軟件>軟體"]
        )
        XCTAssertEqual(keys([term], text, mode: .translate, tone: .professional, outputLanguage: "en"), [])
        XCTAssertEqual(keys([term], text, mode: .translate, tone: .preserve, outputLanguage: "zh-Hant"), [])
        let global = memory("軟件>軟體", kind: .terminology, language: "zh-Hant", scope: .translate)
        XCTAssertEqual(
            keys([global], text, mode: .translate, tone: .professional, outputLanguage: "zh-Hant"), ["軟件>軟體"],
            "a translation memory with no tone applies to every tone"
        )
    }

    func testTranslationMemoriesFollowTheOutputLanguage() {
        let term = memory("軟件>軟體", kind: .terminology, language: "zh-Hant", scope: .translate)
        let text = "This software needs an update."
        XCTAssertEqual(keys([term], text, mode: .translate, outputLanguage: "zh-Hant"), ["軟件>軟體"])
        XCTAssertEqual(keys([term], text, mode: .translate, outputLanguage: "en"), [])
        XCTAssertEqual(keys([term], text, mode: .translate), ["軟件>軟體"], "unknown target: no filter")
        XCTAssertEqual(keys([term], text, mode: .proofread), [], "scoped to translation")
    }

    func testTranslationDoesNotBorrowTheUsersEnglishHabits() {
        let articles = memory("articles")
        XCTAssertEqual(keys([articles], "這個軟體需要更新才能使用新功能", mode: .translate, outputLanguage: "en"), [])
    }

    // MARK: budget and order

    func testTheCharacterBudgetIsRespectedAndALongOneDoesNotBlockShortOnes() {
        let long = String(repeating: "a", count: 300)
        let longer = String(repeating: "b", count: 400)
        let short = String(repeating: "c", count: 50)
        let memories = [
            memory("A", triggers: ["prospective"], evidence: 9, instruction: long),
            memory("B", triggers: ["prospective"], evidence: 5, instruction: longer),
            memory("C", triggers: ["prospective"], evidence: 1, instruction: short),
        ]
        let picked = MemoryRetriever(memories: memories, now: now).select(for: .init(text: english, mode: .proofread))
        XCTAssertEqual(picked.map(\.dedupKey), ["A", "C"])
        let used = picked.reduce(0) { $0 + $1.instruction.count + MemoryPolicy.personalizationLineOverhead }
        XCTAssertLessThanOrEqual(used, MemoryPolicy.maxPersonalizationCharacters)
    }

    func testTheOrderDoesNotDependOnTheInputOrder() {
        let memories = (0..<6).map { memory("m\($0)", triggers: ["prospective"], evidence: 2, count: 2) }
        let forward = keys(memories, english)
        XCTAssertEqual(forward, keys(memories.reversed(), english))
        XCTAssertEqual(forward, keys(memories.shuffled(), english))
        XCTAssertEqual(forward, ["m0", "m1", "m2", "m3", "m4"], "equal scores fall back to the id")
    }

    // MARK: opposites

    private let bothWords = "We need a big house and a large office."

    private func opposites(forward: Double, backward: Double) -> (WritingMemory, WritingMemory) {
        (
            memory("vocabulary:en:big>large", kind: .vocabulary, triggers: ["big"], evidence: forward),
            memory("vocabulary:en:large>big", kind: .vocabulary, triggers: ["large"], evidence: backward)
        )
    }

    func testOfTwoMemoriesAskingForOppositeThingsOnlyTheBetterEvidencedIsUsed() {
        let (forward, backward) = opposites(forward: 3, backward: 1.2)
        XCTAssertEqual(keys([forward, backward], bothWords), ["vocabulary:en:big>large"])
        XCTAssertEqual(keys([backward, forward], bothWords), ["vocabulary:en:big>large"], "input order is irrelevant")
        let (weakForward, strongBackward) = opposites(forward: 1.2, backward: 3)
        XCTAssertEqual(keys([weakForward, strongBackward], bothWords), ["vocabulary:en:large>big"])
    }

    func testAPinnedMemoryBeatsItsOppositeAndTwoPinnedOnesBothStay() {
        var (forward, backward) = opposites(forward: 0.2, backward: 9)
        forward.state = .pinned
        XCTAssertEqual(keys([forward, backward], bothWords), ["vocabulary:en:big>large"])
        backward.state = .pinned
        XCTAssertEqual(Set(keys([forward, backward], bothWords)), ["vocabulary:en:big>large", "vocabulary:en:large>big"])
    }

    func testATieGoesToTheMoreRecentlyConfirmedThenToTheId() {
        var (forward, backward) = opposites(forward: 2, backward: 2)
        backward.lastConfirmedAt = now.addingTimeInterval(100)
        XCTAssertEqual(keys([forward, backward], bothWords), ["vocabulary:en:large>big"])
        backward.lastConfirmedAt = forward.lastConfirmedAt
        let first = keys([forward, backward], bothWords)
        XCTAssertEqual(first.count, 1, "exactly one of a tied pair stays")
        XCTAssertEqual(first, keys([backward, forward], bothWords))
    }

    func testAnOppositeThatCannotBeUsedDoesNotSuppressAnything() {
        var (forward, backward) = opposites(forward: 1.2, backward: 50)
        for state in [MemoryState.disabled, .archived] {
            backward.state = state
            XCTAssertEqual(keys([forward, backward], bothWords), ["vocabulary:en:big>large"], "\(state)")
        }
    }

    func testAShortTermOppositeIsInUseAndLosesToTheBetterEvidencedOne() {
        var (forward, backward) = opposites(forward: 1.2, backward: 0.35)
        backward.state = .candidate
        backward.occurrenceCount = 1
        XCTAssertEqual(keys([forward, backward], bothWords), ["vocabulary:en:big>large"])
        forward.state = .archived
        XCTAssertEqual(keys([forward, backward], bothWords), ["vocabulary:en:large>big"], "alone, it is used")
    }

    func testMemoriesWithoutADirectionNeverSuppressEachOther() {
        let memories = [
            memory("grammar:en:discuss about", triggers: ["discuss about"]),
            memory("grammar:en:articles"),
        ]
        XCTAssertEqual(Set(keys(memories, "We should discuss about the plan and buy laptop today."))
            , ["grammar:en:discuss about", "grammar:en:articles"])
    }

    // MARK: fading

    private func daysLater(_ days: Double) -> Date {
        now.addingTimeInterval(days * 86_400)
    }

    private func keys(_ memories: [WritingMemory], _ text: String, at date: Date) -> [String] {
        MemoryRetriever(memories: memories, now: date)
            .select(for: .init(text: text, mode: .proofread, outputLanguage: nil))
            .map(\.dedupKey)
    }

    func testAMemoryThatHasFadedBelowTheBarIsNoLongerUsed() {
        let memory = memory("faded", triggers: ["prospective"], evidence: 1.05)
        XCTAssertEqual(keys([memory], english, at: daysLater(100)), ["faded"], "0.61 is still enough")
        XCTAssertEqual(keys([memory], english, at: daysLater(130)), [], "0.49 is not")
    }

    func testPinnedMemoriesNeverFade() {
        let pinned = memory("pinned", triggers: ["prospective"], state: .pinned, evidence: 0.2)
        XCTAssertEqual(keys([pinned], english, at: daysLater(3_000)), ["pinned"])
    }

    func testFadedEvidenceLowersTheRank() {
        let old = memory("old", triggers: ["prospective"], evidence: 3, count: 3)
        var recent = memory("recent", triggers: ["prospective"], evidence: 1.2, count: 3)
        recent.lastConfirmedAt = daysLater(190)
        // Stored, the old one is stronger (3 against 1.2) and leads while nothing has faded...
        XCTAssertEqual(keys([old, recent], english, at: now), ["old", "recent"])
        // ...but by day 200 it has faded to 0.81, and the one confirmed ten days ago leads.
        XCTAssertEqual(keys([old, recent], english, at: daysLater(200)), ["recent", "old"])
    }

    func testOppositesAreJudgedOnWhatHasFaded() {
        var forward = memory("vocabulary:en:big>large", kind: .vocabulary, triggers: ["big"], evidence: 3)
        var backward = memory("vocabulary:en:large>big", kind: .vocabulary, triggers: ["large"], evidence: 1.2)
        forward.lastConfirmedAt = now
        backward.lastConfirmedAt = daysLater(190)
        XCTAssertEqual(keys([forward, backward], bothWords, at: now), ["vocabulary:en:big>large"])
        XCTAssertEqual(keys([forward, backward], bothWords, at: daysLater(200)), ["vocabulary:en:large>big"])
    }

    // MARK: scale

    func testTheRightMemoryWinsAmongThousandsAndItIsFast() {
        func word(_ n: Int) -> String {
            var value = n
            var letters = ""
            repeat {
                letters.append(Character(UnicodeScalar(UInt8(97 + value % 26))))
                value /= 26
            } while value > 0
            return "zq" + letters.reversed().map(String.init).joined() + "xx"
        }
        var memories: [WritingMemory] = []
        for i in 0..<700 { memories.append(memory("spell\(i)", kind: .spelling, triggers: [word(i)])) }
        for i in 0..<500 {
            memories.append(memory("tone\(i)", kind: .style, scope: .proofread, tone: .formal, triggers: [word(10_000 + i)]))
        }
        for i in 0..<500 {
            memories.append(memory("term\(i)", kind: .terminology, language: "zh-Hant", scope: .translate, triggers: [word(20_000 + i)]))
        }
        for i in 0..<300 {
            memories.append(memory("dead\(i)", triggers: [word(30_000 + i)], state: i % 2 == 0 ? .candidate : .disabled))
        }
        let target = memory("prospective>perspective", kind: .spelling, triggers: ["prospective"], evidence: 2, count: 2)
        memories.append(target)
        memories.append(memory("articles", evidence: 3, count: 5))
        XCTAssertGreaterThanOrEqual(memories.count, 2_000)

        let retriever = MemoryRetriever(memories: memories, now: now)
        let text = String(repeating: english + " ", count: 45) // about 500 words
        let query = MemoryRetriever.Query(text: text, mode: .proofread, outputLanguage: nil)

        let result = retriever.select(for: query)
        XCTAssertEqual(result.first?.dedupKey, "prospective>perspective")
        XCTAssertLessThanOrEqual(result.count, MemoryPolicy.maxPersonalizedMemories)
        XCTAssertTrue(result.allSatisfy { $0.modeScope == nil && $0.toneScope == nil }, "no tone or translation memory leaks in")
        XCTAssertTrue(result.allSatisfy { $0.state == .active })

        let clock = ContinuousClock()
        let elapsed = clock.measure { for _ in 0..<10 { _ = retriever.select(for: query) } }
        let perQuery = elapsed / 10
        XCTAssertLessThan(perQuery, .milliseconds(50), "a query over a 500-word text and 2,000 memories took \(perQuery)")
    }

    // MARK: organized memories

    private let discussText = "We should discuss about the plan tomorrow."

    /// A generalized memory with no triggers: a rule for English text as a whole.
    private func rule(
        _ key: String = "dream:rule", state: MemoryState = .active, level: MemoryLevel = .generalized,
        triggers: [String] = [], evidence: Double = 3.6, count: Int = 9
    ) -> WritingMemory {
        memory(key, triggers: triggers, state: state, evidence: evidence, count: count, level: level)
    }

    private func covered(
        _ key: String, by rule: WritingMemory, triggers: [String] = [], evidence: Double = 1.2
    ) -> WritingMemory {
        memory(key, triggers: triggers, evidence: evidence, supersededBy: rule.id)
    }

    func testAMemoryThatARuleStandsInForIsLeftOutOfTheRedundantPrompt() {
        let rule = rule()
        let habit = covered("grammar:en:habit", by: rule)
        let bound = covered("grammar:en:discuss about", by: rule, triggers: ["discuss about"])

        XCTAssertEqual(keys([rule, habit, bound], english), [rule.dedupKey])

        // The same memories with nothing standing in for them: each is as useful as before.
        let free = [habit, memory("grammar:en:discuss about", triggers: ["discuss about"])]
        XCTAssertEqual(keys(free, english), ["grammar:en:habit"])
        XCTAssertEqual(keys(free + [self.rule()], english).count, 2)
    }

    func testAnExactTriggerBringsTheMemoryBackInPlaceOfItsRule() {
        let rule = rule()
        let bound = covered("grammar:en:discuss about", by: rule, triggers: ["discuss about"])
        let other = covered("grammar:en:mention about", by: rule, triggers: ["mention about"])

        XCTAssertEqual(keys([rule, bound, other], discussText), ["grammar:en:discuss about"],
                       "the precise memory, not the rule as well")
        XCTAssertEqual(keys([rule, bound, other], english), [rule.dedupKey], "no trigger, so the rule speaks")
    }

    func testARuleIsOnlyLeftOutWhenTheMemoryItStandsInForIsReallyPicked() {
        let ruleA = rule("dream:a")
        let ruleB = rule("dream:b")
        let inA = covered("grammar:en:discuss about", by: ruleA, triggers: ["discuss about"])
        let inB = covered("grammar:en:mention about", by: ruleB, triggers: ["mention about"])

        // Only A's memory is in the text: A gives way to it, and B still speaks (it is a habit, so two fit).
        XCTAssertEqual(
            Set(keys([ruleA, ruleB, inA, inB], discussText)), ["grammar:en:discuss about", "dream:b"]
        )
    }

    func testAPinnedRuleIsNotDisplaced() {
        let rule = rule(state: .pinned)
        let bound = covered("grammar:en:discuss about", by: rule, triggers: ["discuss about"])
        XCTAssertEqual(keys([bound, rule], discussText), [rule.dedupKey, "grammar:en:discuss about"])
    }

    func testARuleThatIsNotInUseHidesNothing() {
        for state in [MemoryState.archived, .disabled] {
            let rule = rule(state: state)
            let habit = covered("grammar:en:habit", by: rule)
            let bound = covered("grammar:en:discuss about", by: rule, triggers: ["discuss about"])
            XCTAssertEqual(
                Set(keys([rule, habit, bound], discussText)), ["grammar:en:habit", "grammar:en:discuss about"],
                "\(state)"
            )
        }
    }

    func testAMemoryWhoseRuleIsGoneOrHasFadedIsNotHidden() {
        let gone = memory("grammar:en:habit", supersededBy: UUID())
        XCTAssertEqual(keys([gone], english), ["grammar:en:habit"], "the rule was deleted")

        // The rule has not been confirmed for so long that it has faded away by now.
        var faded = rule()
        faded.evidenceScore = 0.2
        faded.lastConfirmedAt = now.addingTimeInterval(-2_000 * 86_400)
        let habit = covered("grammar:en:habit", by: faded)
        XCTAssertEqual(keys([faded, habit], english), ["grammar:en:habit"])
    }

    func testARuleIsNotAnythingElsesPointer() {
        // A rule that itself names another is still a rule, and is not left out for that.
        let outer = rule("dream:outer")
        var inner = rule("dream:inner")
        inner.supersededBy = outer.id
        XCTAssertEqual(Set(keys([outer, inner], english)), ["dream:outer", "dream:inner"])
    }

    func testTheOrderIsExactSpecificThenRuleThenHabit() {
        let exact = memory("grammar:en:discuss about", triggers: ["discuss about"])
        let coreLexical = rule("dream:core-lexical", level: .core, triggers: ["discuss about"])
        let generalizedLexical = rule("dream:gen-lexical", triggers: ["discuss about"])
        let coreHabit = rule("dream:core-habit", level: .core)
        let generalizedHabit = rule("dream:gen-habit")
        let specificHabit = memory("grammar:en:habit")

        let all = [specificHabit, generalizedHabit, coreHabit, generalizedLexical, coreLexical, exact]
        XCTAssertEqual(
            keys(all, discussText),
            [exact.dedupKey, coreLexical.dedupKey, generalizedLexical.dedupKey, coreHabit.dedupKey, generalizedHabit.dedupKey],
            "two habits fit, and the plain one is not among them"
        )
    }

    func testEvidenceCannotLiftARuleOverAnExactMemoryOrAHabitOverARule() {
        let strongRule = rule("dream:strong", triggers: ["discuss about"], evidence: 500, count: 50)
        let weakExact = memory("grammar:en:discuss about", triggers: ["discuss about"], evidence: 0.6, count: 1)
        XCTAssertEqual(keys([strongRule, weakExact], discussText), [weakExact.dedupKey, strongRule.dedupKey])

        let strongHabit = memory("grammar:en:strong-habit", evidence: 500, count: 50)
        let weakRule = rule("dream:weak", evidence: 0.6, count: 1)
        XCTAssertEqual(keys([strongHabit, weakRule], english), [weakRule.dedupKey, strongHabit.dedupKey])
    }

    func testARuleTakesOneOfTheHabitSlots() {
        let habits = (0..<3).map { memory("grammar:en:habit\($0)") }
        let picked = keys(habits + [rule()], english)
        XCTAssertEqual(picked.count, MemoryPolicy.maxHabitMemories)
        XCTAssertEqual(picked.first, "dream:rule")
    }

    func testThePromptBudgetHoldsWhenRulesAreInvolved() {
        let rule = rule()
        let long = String(repeating: "字", count: 150)
        let bound = (0..<8).map { index in
            memory(
                "grammar:en:word\(index) about", triggers: ["word\(index) about"], instruction: long,
                supersededBy: rule.id
            )
        }
        let text = "Please word0 about word1 about word2 about word3 about word4 about word5 about word6 about word7 about it."
        let picked = MemoryRetriever(memories: bound + [rule], now: now)
            .select(for: .init(text: text, mode: .proofread, outputLanguage: nil))

        XCTAssertLessThanOrEqual(picked.count, MemoryPolicy.maxPersonalizedMemories)
        XCTAssertLessThanOrEqual(picked.map(MemoryPolicy.promptCost).reduce(0, +), MemoryPolicy.maxPersonalizationCharacters)
        XCTAssertEqual(picked.count, 3, "150 characters and the numbering: three fit in 600")
        XCTAssertFalse(picked.contains { $0.id == rule.id })

        let composed = PromptComposer.compose(base: "BASE", memories: picked)
        XCTAssertEqual(composed.usedMemoryIDs, picked.map(\.id))
    }

    func testAllOfItStaysInTheSameOrderWhateverOrderTheMemoriesComeIn() {
        let rule = rule()
        var memories = [
            rule, covered("grammar:en:discuss about", by: rule, triggers: ["discuss about"]),
            covered("grammar:en:habit", by: rule), self.rule("dream:other", level: .core),
            memory("grammar:en:exact", triggers: ["plan"]), memory("grammar:en:h2"),
        ]
        let expected = keys(memories, discussText)
        XCTAssertFalse(expected.isEmpty)
        for shift in 1..<memories.count {
            memories.append(memories.removeFirst())
            XCTAssertEqual(keys(memories, discussText), expected, "rotated by \(shift)")
        }
        XCTAssertEqual(keys(memories.reversed(), discussText), expected)
    }
}
