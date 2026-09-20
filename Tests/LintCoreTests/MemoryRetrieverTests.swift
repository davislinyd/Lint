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
        triggers: [String] = [],
        state: MemoryState = .active,
        evidence: Double = 1.2,
        count: Int = 3,
        instruction: String? = nil
    ) -> WritingMemory {
        counter += 1
        return WritingMemory(
            id: UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", counter))!,
            dedupKey: key, kind: kind, language: language, modeScope: scope, triggers: triggers,
            instruction: instruction ?? "rule for \(key)",
            negativeExample: nil, preferredExample: nil,
            evidenceScore: evidence, occurrenceCount: count, state: state, userEdited: false,
            createdAt: now, lastConfirmedAt: now
        )
    }

    private func keys(
        _ memories: [WritingMemory],
        _ text: String,
        mode: WritingMode = .proofread,
        outputLanguage: String? = nil
    ) -> [String] {
        MemoryRetriever(memories: memories, now: now)
            .select(for: .init(text: text, mode: mode, outputLanguage: outputLanguage))
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
        let memories = [memory("軟件", kind: .terminology, language: "zh-Hant", triggers: ["軟件"])]
        XCTAssertEqual(keys(memories, "這個軟件需要更新"), ["軟件"])
        XCTAssertEqual(keys(memories, "這個軟體需要更新"), [])
    }

    func testATriggerNeedsItsLanguageToShowUpInTheText() {
        let memories = [memory("prospective", kind: .spelling, triggers: ["prospective"])]
        XCTAssertEqual(keys(memories, "prospective"), ["prospective"])
        let chinese = [memory("軟件", language: "zh-Hant", triggers: ["軟件"])]
        XCTAssertEqual(keys(chinese, "the word 軟件 in an English sentence"), ["軟件"])
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
        XCTAssertEqual(result.count, LearningPolicy.maxPersonalizedMemories)
        XCTAssertFalse(result.contains("habit"))
        XCTAssertEqual(result, ["lex6", "lex5", "lex4", "lex3", "lex2"])
    }

    // MARK: eligibility

    func testOnlyActiveAndPinnedMemoriesAreRetrieved() {
        let memories = [
            memory("candidate", triggers: ["prospective"], state: .candidate),
            memory("disabled", triggers: ["prospective"], state: .disabled),
            memory("archived", triggers: ["prospective"], state: .archived),
            memory("active", triggers: ["prospective"], state: .active),
            memory("pinned", triggers: ["prospective"], state: .pinned),
        ]
        XCTAssertEqual(Set(keys(memories, english)), ["active", "pinned"])
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
            memory("formal", scope: .toneFormal, triggers: ["prospective"]),
            memory("translate", scope: .translate, triggers: ["prospective"]),
        ]
        XCTAssertEqual(Set(keys(memories, english, mode: .proofread)), ["global"])
        XCTAssertEqual(Set(keys(memories, english, mode: .toneFormal)), ["global", "formal"])
        XCTAssertEqual(Set(keys(memories, english, mode: .translate)), ["global", "translate"])
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
        let used = picked.reduce(0) { $0 + $1.instruction.count + LearningPolicy.personalizationLineOverhead }
        XCTAssertLessThanOrEqual(used, LearningPolicy.maxPersonalizationCharacters)
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
        for state in [MemoryState.candidate, .disabled, .archived] {
            backward.state = state
            XCTAssertEqual(keys([forward, backward], bothWords), ["vocabulary:en:big>large"], "\(state)")
        }
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
            memories.append(memory("tone\(i)", kind: .style, scope: .toneFormal, triggers: [word(10_000 + i)]))
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
        XCTAssertLessThanOrEqual(result.count, LearningPolicy.maxPersonalizedMemories)
        XCTAssertTrue(result.allSatisfy { $0.modeScope == nil }, "no tone or translation memory leaks in")
        XCTAssertTrue(result.allSatisfy { $0.state == .active })

        let clock = ContinuousClock()
        let elapsed = clock.measure { for _ in 0..<10 { _ = retriever.select(for: query) } }
        let perQuery = elapsed / 10
        XCTAssertLessThan(perQuery, .milliseconds(50), "a query over a 500-word text and 2,000 memories took \(perQuery)")
    }
}
