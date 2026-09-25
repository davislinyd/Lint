import XCTest
@testable import LintCore

/// A clock the test moves by hand, so evidence fades exactly as much as the test says.
private final class TestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var current: Date

    init(_ start: Date = Date(timeIntervalSince1970: 1_800_000_000)) {
        current = start
    }

    var now: Date {
        lock.lock()
        defer { lock.unlock() }
        return current
    }

    func advance(days: Double) {
        lock.lock()
        current = current.addingTimeInterval(days * 86_400)
        lock.unlock()
    }

    var reader: @Sendable () -> Date {
        { [self] in now }
    }
}

final class LearningCoordinatorTests: XCTestCase {
    private func makeStoreURL() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("LintLearningTests-\(UUID().uuidString)", isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        return dir.appendingPathComponent("Lint", isDirectory: true)
            .appendingPathComponent("LintLearning.sqlite")
    }

    private func feedback(
        _ gesture: UserGesture = .replaced,
        original: String = "zq-source-text discuss about",
        generated: String? = "zq-suggestion-text discuss",
        final: String = "zq-suggestion-text discuss"
    ) -> LearningFeedback {
        LearningFeedback(
            gesture: gesture, mode: .proofread, originalText: original, generatedText: generated,
            finalText: final, provider: "localLlama", model: "qwen"
        )
    }

    private func testKey() -> @Sendable () throws -> Data {
        { Data(repeating: 9, count: 32) }
    }

    func testFeedbackIsIgnoredWhileLearningIsOff() async throws {
        let url = try makeStoreURL()
        let coordinator = LearningCoordinator(storeURL: url, hmacKey: testKey())
        await coordinator.recordFeedback(feedback(), config: LearningConfig(enabled: false))
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }

    func testRecordedFeedbackCountsOncePerDay() async throws {
        let coordinator = LearningCoordinator(storeURL: nil, hmacKey: testKey())
        let on = LearningConfig(enabled: true)
        await coordinator.recordFeedback(feedback(), config: on)
        await coordinator.recordFeedback(feedback(), config: on)
        await coordinator.recordFeedback(feedback(final: "zq-edited-text"), config: on)
        let stats = await coordinator.stats()
        XCTAssertEqual(stats.eventCount, 2, "the repeat is dropped, the edited version is a new event")
    }

    func testHalfStreamedSuggestionRecordsNothingAndCreatesNothing() async throws {
        let url = try makeStoreURL()
        let coordinator = LearningCoordinator(storeURL: url, hmacKey: testKey())
        await coordinator.recordFeedback(feedback(generated: nil), config: LearningConfig(enabled: true))
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }

    func testStoredEventsContainNoPlaintext() async throws {
        let url = try makeStoreURL()
        let coordinator = LearningCoordinator(storeURL: url, hmacKey: testKey())
        await coordinator.recordFeedback(feedback(), config: LearningConfig(enabled: true))

        let file = try Data(contentsOf: url)
        XCTAssertNotNil(file.range(of: Data("localLlama".utf8)), "sanity: plaintext columns are visible in the file")
        // Abstracted memories may keep single words (a trigger such as "discuss about"), but the
        // texts themselves never reach the file.
        for secret in ["zq-source-text", "zq-suggestion-text"] {
            XCTAssertNil(file.range(of: Data(secret.utf8)), "\(secret) must not be stored")
        }
    }

    func testMissingHMACKeyRecordsNothing() async throws {
        struct NoKey: Error {}
        let coordinator = LearningCoordinator(storeURL: nil, hmacKey: { throw NoKey() })
        await coordinator.recordFeedback(feedback(), config: LearningConfig(enabled: true))
        let stats = await coordinator.stats()
        XCTAssertEqual(stats.eventCount, 0)
    }

    func testHMACKeyIsFetchedOnlyOnce() async throws {
        final class Counter: @unchecked Sendable {
            private let lock = NSLock()
            private var value = 0
            func increment() { lock.lock(); value += 1; lock.unlock() }
            var count: Int { lock.lock(); defer { lock.unlock() }; return value }
        }
        let calls = Counter()
        let coordinator = LearningCoordinator(storeURL: nil, hmacKey: {
            calls.increment()
            return Data(repeating: 9, count: 32)
        })
        let on = LearningConfig(enabled: true)
        await coordinator.recordFeedback(feedback(), config: on)
        await coordinator.recordFeedback(feedback(.copied), config: on)
        XCTAssertEqual(calls.count, 1)
    }

    // MARK: learning

    private let on = LearningConfig(enabled: true)
    private let topics = ["plan", "budget", "schedule", "firewall", "report", "contract", "design"]

    /// The model left "discuss about" alone and the user fixed it by hand.
    private func edit(_ topic: String, gesture: UserGesture = .replaced) -> LearningFeedback {
        LearningFeedback(
            gesture: gesture, mode: .proofread,
            originalText: "we should discuss about the \(topic).",
            generatedText: "we should discuss about the \(topic).",
            finalText: "we should discuss the \(topic).",
            provider: "localLlama", model: "qwen"
        )
    }

    /// The model fixed "discuss about" and the user took it as is.
    private func accept(_ topic: String, gesture: UserGesture = .replaced) -> LearningFeedback {
        LearningFeedback(
            gesture: gesture, mode: .proofread,
            originalText: "we should discuss about the \(topic).",
            generatedText: "we should discuss the \(topic).",
            finalText: "we should discuss the \(topic).",
            provider: "localLlama", model: "qwen"
        )
    }

    private func learner(clock: TestClock = TestClock()) -> LearningCoordinator {
        LearningCoordinator(storeURL: nil, hmacKey: testKey(), clock: clock.reader)
    }

    private func onlyMemory(_ coordinator: LearningCoordinator) async throws -> WritingMemory {
        let all = await coordinator.memories()
        return try XCTUnwrap(all.first)
    }

    func testOneEditIsUsedAtOnceAndASecondMakesItLongTerm() async throws {
        let coordinator = learner()
        await coordinator.recordFeedback(edit(topics[0]), config: on)
        let first = await coordinator.memories()
        XCTAssertEqual(first.map(\.dedupKey), ["grammar:en:discuss about"])
        XCTAssertEqual(first.first?.state, .candidate, "short-term")
        XCTAssertEqual(first.first?.occurrenceCount, 1)
        let usedAtOnce = await retrieve(coordinator)
        XCTAssertEqual(usedAtOnce.map(\.id), first.map(\.id), "used from the next suggestion on")

        await coordinator.recordFeedback(edit(topics[1]), config: on)
        let proven = await coordinator.memories()
        XCTAssertEqual(proven.count, 1)
        XCTAssertEqual(proven.first?.state, .active, "it came back: long-term")
        XCTAssertEqual(proven.first?.occurrenceCount, 2)
        XCTAssertEqual(proven.first?.triggers, ["discuss about"])
        XCTAssertEqual(proven.first?.evidenceScore ?? 0, LearningPolicy.activeThreshold, accuracy: 1e-9)
    }

    func testAnAcceptedFixIsUsedAtOnceAndComingBackMakesItLongTerm() async throws {
        let coordinator = learner()
        await coordinator.recordFeedback(accept(topics[0]), config: on)
        let first = try await onlyMemory(coordinator)
        XCTAssertEqual(first.state, .candidate)
        XCTAssertEqual(first.evidenceScore, LearningPolicy.evidenceWeight(for: .accepted), accuracy: 1e-9)
        let used = await retrieve(coordinator)
        XCTAssertEqual(used.map(\.id), [first.id])

        await coordinator.recordFeedback(accept(topics[1]), config: on)
        let second = try await onlyMemory(coordinator)
        XCTAssertEqual(second.state, .active)
    }

    func testTheSameFeedbackTwiceIsOneObservation() async throws {
        let coordinator = learner()
        await coordinator.recordFeedback(edit("plan"), config: on)
        await coordinator.recordFeedback(edit("plan"), config: on)
        let memories = await coordinator.memories()
        XCTAssertEqual(memories.first?.occurrenceCount, 1)
    }

    func testCopyingCountsForLessAndRegeneratingForNothing() async throws {
        let coordinator = learner()
        await coordinator.recordFeedback(accept("plan", gesture: .regenerated), config: on)
        let none = await coordinator.memories()
        XCTAssertTrue(none.isEmpty)

        await coordinator.recordFeedback(accept("plan", gesture: .copied), config: on)
        let copied = await coordinator.memories()
        let evidence = try XCTUnwrap(copied.first?.evidenceScore)
        XCTAssertEqual(evidence, LearningPolicy.evidenceWeight(for: .copied), accuracy: 1e-9)
    }

    func testNothingIsLearnedWhileLearningIsOff() async throws {
        let url = try makeStoreURL()
        let coordinator = LearningCoordinator(storeURL: url, hmacKey: testKey())
        await coordinator.recordFeedback(edit("plan"), config: LearningConfig(enabled: false))
        let memories = await coordinator.memories()
        XCTAssertTrue(memories.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }

    // MARK: retrieval

    private func retrieve(_ coordinator: LearningCoordinator, config: LearningConfig? = nil) async -> [WritingMemory] {
        await coordinator.relevantMemories(
            for: "we should discuss about the roadmap", mode: .proofread, config: config ?? on
        )
    }

    func testLearnedMemoriesAreRetrievedOnlyForRelevantText() async throws {
        let coordinator = learner()
        for topic in topics.prefix(3) {
            await coordinator.recordFeedback(edit(topic), config: on)
        }
        let hit = await retrieve(coordinator)
        XCTAssertEqual(hit.map(\.dedupKey), ["grammar:en:discuss about"])
        let miss = await coordinator.relevantMemories(
            for: "the roadmap looks fine to everyone here", mode: .proofread, config: on
        )
        XCTAssertTrue(miss.isEmpty)
    }

    func testANewMemoryShowsUpInTheNextRetrievalEvenAfterTheCacheWasFilled() async throws {
        let coordinator = learner()
        let empty = await retrieve(coordinator)
        XCTAssertTrue(empty.isEmpty, "nothing learned yet, and the retrieval cache is filled")

        await coordinator.recordFeedback(edit(topics[0]), config: on)
        let learned = await retrieve(coordinator)
        XCTAssertEqual(learned.count, 1)
    }

    func testEveryChangeShowsUpInTheNextRetrieval() async throws {
        let (coordinator, id) = try await seeded()
        let untouched = await retrieve(coordinator)
        XCTAssertEqual(untouched.count, 1, "one edit is used at once")

        await coordinator.setEnabled(false, id: id)
        let disabled = await retrieve(coordinator)
        XCTAssertTrue(disabled.isEmpty)

        await coordinator.setPinned(true, id: id)
        let pinned = await retrieve(coordinator)
        XCTAssertEqual(pinned.count, 1)

        await coordinator.setEnabled(false, id: id)
        let disabledAgain = await retrieve(coordinator)
        XCTAssertTrue(disabledAgain.isEmpty)

        await coordinator.setPinned(true, id: id)
        let repinned = await retrieve(coordinator)
        XCTAssertEqual(repinned.count, 1)

        await coordinator.deleteMemory(id: id)
        let deleted = await retrieve(coordinator)
        XCTAssertTrue(deleted.isEmpty)
    }

    func testResetAndClearingEmptyTheRetrievalToo() async throws {
        let (coordinator, id) = try await seeded()
        await coordinator.setPinned(true, id: id)
        let before = await retrieve(coordinator)
        XCTAssertEqual(before.count, 1)
        await coordinator.deleteAllMemories()
        let cleared = await retrieve(coordinator)
        XCTAssertTrue(cleared.isEmpty)

        await coordinator.recordFeedback(edit("budget"), config: on)
        let relearned = try await onlyMemory(coordinator)
        await coordinator.setPinned(true, id: relearned.id)
        let again = await retrieve(coordinator)
        XCTAssertEqual(again.count, 1)
        await coordinator.resetAll()
        let reset = await retrieve(coordinator)
        XCTAssertTrue(reset.isEmpty)
    }

    func testNothingIsRetrievedWhileLearningIsOffAndRetrievingNeverCreatesTheDatabase() async throws {
        let url = try makeStoreURL()
        let fresh = LearningCoordinator(storeURL: url, hmacKey: testKey())
        let none = await retrieve(fresh)
        XCTAssertTrue(none.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))

        let (coordinator, id) = try await seeded()
        await coordinator.setPinned(true, id: id)
        let off = await retrieve(coordinator, config: LearningConfig(enabled: false))
        XCTAssertTrue(off.isEmpty)
    }

    // MARK: personalizing a prompt

    private let basePrompt = "BASE PROMPT\n回覆只要修正後的全文，不要解釋。"

    /// A memory the user's own edit taught, and which came back once: long-term.
    private func learnedDiscussAbout() async throws -> (LearningCoordinator, WritingMemory) {
        let coordinator = learner()
        for topic in topics.prefix(2) {
            await coordinator.recordFeedback(edit(topic), config: on)
        }
        return (coordinator, try await onlyMemory(coordinator))
    }

    func testPersonalizingAddsTheRelevantMemoriesAndSaysWhichWereUsed() async throws {
        let (coordinator, memory) = try await learnedDiscussAbout()
        let result = await coordinator.personalize(
            prompt: basePrompt, for: "we should discuss about the roadmap", mode: .proofread, config: on
        )
        XCTAssertTrue(result.systemPrompt.hasPrefix(basePrompt + "\n\n" + PromptComposer.header + "\n1. "))
        XCTAssertTrue(result.systemPrompt.hasSuffix(memory.instruction))
        XCTAssertEqual(result.usedMemoryIDs, [memory.id])
    }

    func testAnEnglishPromptGetsWhatWasLearnedInEnglish() async throws {
        let (coordinator, memory) = try await learnedDiscussAbout()
        let result = await coordinator.personalize(
            prompt: basePrompt, for: "we should discuss about the roadmap", mode: .proofread, english: true, config: on
        )
        let english = try XCTUnwrap(MemoryWording(chinese: memory.instruction)).english
        XCTAssertEqual(result.systemPrompt, basePrompt + "\n\n" + PromptComposer.englishHeader + "\n1. " + english)
        XCTAssertEqual(result.usedMemoryIDs, [memory.id])
    }

    func testThePromptIsUntouchedWhileLearningIsOffOrWhenNothingIsRelevant() async throws {
        let (coordinator, _) = try await learnedDiscussAbout()

        let off = await coordinator.personalize(
            prompt: basePrompt, for: "we should discuss about the roadmap", mode: .proofread,
            config: LearningConfig(enabled: false)
        )
        XCTAssertEqual(Array(off.systemPrompt.utf8), Array(basePrompt.utf8), "byte for byte")
        XCTAssertTrue(off.usedMemoryIDs.isEmpty)

        let irrelevant = await coordinator.personalize(
            prompt: basePrompt, for: "the roadmap looks fine to everyone here", mode: .proofread, config: on
        )
        XCTAssertEqual(irrelevant.systemPrompt, basePrompt)
        XCTAssertTrue(irrelevant.usedMemoryIDs.isEmpty)
    }

    func testThePromptIsUntouchedWhenThereIsNothingLearnedAtAll() async throws {
        let url = try makeStoreURL()
        let coordinator = LearningCoordinator(storeURL: url, hmacKey: testKey())
        let result = await coordinator.personalize(prompt: basePrompt, for: "any text at all", mode: .proofread, config: on)
        XCTAssertEqual(result.systemPrompt, basePrompt)
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path), "personalizing never creates the database")
    }

    func testATranslationMemoryAppliesToTranslationOnly() async throws {
        let coordinator = learner()
        let pairs = [
            ("This software needs an update.", "這個軟件需要更新才能使用新功能", "這個軟體需要更新才能使用新功能"),
            ("Please install the software first.", "請先安裝這個軟件再重新啟動電腦", "請先安裝這個軟體再重新啟動電腦"),
            ("The software version is too old.", "軟件的版本太舊所以無法連線成功", "軟體的版本太舊所以無法連線成功"),
        ]
        for (source, generated, final) in pairs {
            await coordinator.recordFeedback(
                LearningFeedback(
                    gesture: .replaced, mode: .translate, originalText: source, generatedText: generated,
                    finalText: final, provider: "localLlama", model: "qwen"
                ),
                config: on
            )
        }
        let memory = try await onlyMemory(coordinator)
        XCTAssertEqual(memory.state, .active)
        XCTAssertEqual(memory.modeScope, .translate)

        func used(mode: WritingMode = .translate, into language: TranslationLanguage = .traditionalChinese) async -> [UUID] {
            await coordinator.personalize(
                prompt: basePrompt, for: "Where can I download the software?", mode: mode,
                translationLanguage: language, config: on
            ).usedMemoryIDs
        }
        let translating = await used()
        XCTAssertEqual(translating, [memory.id], "translation writes Traditional Chinese, where the memory applies")
        let proofreading = await used(mode: .proofread)
        XCTAssertTrue(proofreading.isEmpty, "a translation memory stays out of proofreading")
        let intoJapanese = await used(into: .japanese)
        XCTAssertTrue(intoJapanese.isEmpty, "a Traditional Chinese memory stays out of a translation into Japanese")
    }

    // MARK: tone

    /// The model added the article, and the user took it as it is.
    private func acceptedArticle(_ mode: WritingMode, _ tone: WritingTone, _ topic: String) -> LearningFeedback {
        LearningFeedback(
            gesture: .replaced, mode: mode, tone: tone,
            originalText: "I have meeting about the \(topic).", generatedText: "I have a meeting about the \(topic).",
            finalText: "I have a meeting about the \(topic).", provider: "localLlama", model: "qwen"
        )
    }

    func testProofreadingInAToneIsTheModelsRewriteAndNotTheUsersHabit() async throws {
        for tone in [WritingTone.formal, .concise, .professional] {
            let coordinator = learner()
            for topic in topics.prefix(3) {
                await coordinator.recordFeedback(acceptedArticle(.proofread, tone, topic), config: on)
            }
            let memories = await coordinator.memories()
            XCTAssertTrue(memories.isEmpty, "\(tone): nothing is learned from what the model wrote")
            let stats = await coordinator.stats()
            XCTAssertEqual(stats.eventCount, 3, "\(tone): what happened is still recorded, without the text")
        }
        let control = learner()
        for topic in topics.prefix(3) {
            await control.recordFeedback(acceptedArticle(.proofread, .preserve, topic), config: on)
        }
        let learned = await control.memories()
        XCTAssertEqual(learned.map(\.dedupKey), ["grammar:en:articles"], "plain proofreading still learns")
    }

    func testTranslatingInAnyToneLearnsNothingFromTheModelsRewrite() async throws {
        for tone in WritingTone.allCases {
            let coordinator = learner()
            for topic in topics.prefix(3) {
                await coordinator.recordFeedback(acceptedArticle(.translate, tone, topic), config: on)
            }
            let memories = await coordinator.memories()
            XCTAssertTrue(memories.isEmpty, "\(tone)")
        }
    }

    func testTheUsersEditUnderAToneIsLearnedForThatToneOnly() async throws {
        let coordinator = learner()
        for noun in ["house", "office", "car"] {
            await coordinator.recordFeedback(
                LearningFeedback(
                    gesture: .replaced, mode: .proofread, tone: .professional,
                    originalText: "I need a big \(noun)", generatedText: "I need a large \(noun)",
                    finalText: "I need a huge \(noun)", provider: "localLlama", model: "qwen"
                ),
                config: on
            )
        }
        let memory = try await onlyMemory(coordinator)
        XCTAssertEqual(memory.dedupKey, "vocabulary:en:proofread|professional:large>huge")
        XCTAssertEqual(memory.modeScope, .proofread)
        XCTAssertEqual(memory.toneScope, .professional)
        XCTAssertEqual(memory.state, .active)

        func ids(_ mode: WritingMode, _ tone: WritingTone) async -> [UUID] {
            await coordinator.relevantMemories(
                for: "We need something large today please", mode: mode, tone: tone, config: on
            ).map(\.id)
        }
        let professional = await ids(.proofread, .professional)
        XCTAssertEqual(professional, [memory.id])
        for tone in [WritingTone.preserve, .formal, .concise] {
            let other = await ids(.proofread, tone)
            XCTAssertTrue(other.isEmpty, "\(tone)")
        }
        let translating = await ids(.translate, .professional)
        XCTAssertTrue(translating.isEmpty, "it was learned while proofreading")

        // The prompt is personalized with the tone that was asked for.
        func used(_ tone: WritingTone) async -> [UUID] {
            await coordinator.personalize(
                prompt: basePrompt, for: "We need something large today please", mode: .proofread, tone: tone,
                config: on
            ).usedMemoryIDs
        }
        let usedProfessional = await used(.professional)
        XCTAssertEqual(usedProfessional, [memory.id])
        let usedPreserve = await used(.preserve)
        XCTAssertTrue(usedPreserve.isEmpty)
    }

    func testAHabitLearnedUnderAToneStaysAvailableInEveryTone() async throws {
        let coordinator = learner()
        for topic in topics.prefix(3) {
            // The user put the article in themselves: a habit of theirs, whatever the tone.
            await coordinator.recordFeedback(
                LearningFeedback(
                    gesture: .replaced, mode: .proofread, tone: .concise,
                    originalText: "I have meeting about the \(topic).",
                    generatedText: "I have meeting about the \(topic).",
                    finalText: "I have a meeting about the \(topic).", provider: "localLlama", model: "qwen"
                ),
                config: on
            )
        }
        let memory = try await onlyMemory(coordinator)
        XCTAssertEqual(memory.dedupKey, "grammar:en:articles")
        XCTAssertNil(memory.modeScope)
        XCTAssertNil(memory.toneScope)
        for tone in WritingTone.allCases {
            let found = await coordinator.relevantMemories(
                for: "we should discuss about the roadmap", mode: .proofread, tone: tone, config: on
            )
            XCTAssertEqual(found.map(\.id), [memory.id], "\(tone)")
        }
    }

    func testAnEditWhileTranslatingInAToneIsScopedToThatTaskAndTone() async throws {
        let coordinator = learner()
        for noun in ["house", "office", "car"] {
            await coordinator.recordFeedback(
                LearningFeedback(
                    gesture: .replaced, mode: .translate, tone: .formal,
                    originalText: "This \(noun) is very big and old", generatedText: "這個\(noun)非常大而且很舊",
                    finalText: "這個\(noun)極為龐大而且老舊", provider: "localLlama", model: "qwen"
                ),
                config: on
            )
        }
        let memories = await coordinator.memories()
        XCTAssertFalse(memories.isEmpty)
        XCTAssertTrue(memories.allSatisfy { $0.modeScope == .translate && $0.toneScope == .formal })
    }

    func testAToneChangesNothingWhileLearningIsOff() async throws {
        let url = try makeStoreURL()
        let coordinator = LearningCoordinator(storeURL: url, hmacKey: testKey())
        await coordinator.recordFeedback(acceptedArticle(.proofread, .professional, "plan"), config: LearningConfig(enabled: false))
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
        let off = await coordinator.personalize(
            prompt: basePrompt, for: "we should discuss about the roadmap", mode: .proofread, tone: .professional,
            config: LearningConfig(enabled: false)
        )
        XCTAssertEqual(Array(off.systemPrompt.utf8), Array(basePrompt.utf8), "byte for byte")
    }

    // MARK: not learning from its own reminders

    func testAMemoryIsNotCountedAgainWhenTheModelJustObeyedIt() async throws {
        let (coordinator, memory) = try await learnedDiscussAbout()

        // The model was reminded, fixed the text, and the user took it as is.
        var reminded = accept("firewall")
        reminded.usedMemoryIDs = [memory.id]
        await coordinator.recordFeedback(reminded, config: on)
        let afterReminded = try await onlyMemory(coordinator)
        XCTAssertEqual(afterReminded.occurrenceCount, memory.occurrenceCount)
        XCTAssertEqual(afterReminded.evidenceScore, memory.evidenceScore, accuracy: 1e-9)

        // The same fix without the reminder is a fresh observation.
        await coordinator.recordFeedback(accept("report"), config: on)
        let afterPlain = try await onlyMemory(coordinator)
        XCTAssertEqual(afterPlain.occurrenceCount, memory.occurrenceCount + 1)

        // The user's own edit counts even though the memory was in the prompt.
        var edited = edit("contract")
        edited.usedMemoryIDs = [memory.id]
        await coordinator.recordFeedback(edited, config: on)
        let afterEdit = try await onlyMemory(coordinator)
        XCTAssertEqual(afterEdit.occurrenceCount, memory.occurrenceCount + 2)
    }

    func testOtherPatternsInTheSameFeedbackStillCount() async throws {
        let (coordinator, memory) = try await learnedDiscussAbout()
        await coordinator.recordFeedback(
            LearningFeedback(
                gesture: .replaced, mode: .proofread,
                originalText: "we should discuss about the plan and buy laptop.",
                generatedText: "we should discuss the plan and buy a laptop.",
                finalText: "we should discuss the plan and buy a laptop.",
                provider: "localLlama", model: "qwen", usedMemoryIDs: [memory.id]
            ),
            config: on
        )
        let all = await coordinator.memories()
        XCTAssertEqual(Set(all.map(\.dedupKey)), ["grammar:en:discuss about", "grammar:en:articles"])
        let old = try XCTUnwrap(all.first { $0.id == memory.id })
        XCTAssertEqual(old.occurrenceCount, memory.occurrenceCount, "the reminded pattern is left alone")
    }

    func testAMemoryThatIsGoneIsSimplyNotExcluded() async throws {
        let coordinator = learner()
        var feedback = accept("plan")
        feedback.usedMemoryIDs = [UUID()]
        await coordinator.recordFeedback(feedback, config: on)
        let memories = await coordinator.memories()
        XCTAssertEqual(memories.map(\.dedupKey), ["grammar:en:discuss about"])
    }

    func testTheMemoriesUsedAreKeptWithTheEvent() async throws {
        let url = try makeStoreURL()
        let coordinator = LearningCoordinator(storeURL: url, hmacKey: testKey())
        let usedNowhereElse = UUID()
        var feedback = edit("plan")
        feedback.usedMemoryIDs = [usedNowhereElse]
        await coordinator.recordFeedback(feedback, config: on)
        let file = try Data(contentsOf: url)
        XCTAssertNotNil(file.range(of: Data(usedNowhereElse.uuidString.utf8)))
    }

    // MARK: opposites and contradictions

    /// The user keeps replacing `from` with `to` in what the model left alone, one object at a time.
    private func swaps(from: String, to: String, _ objects: [String]) -> [LearningFeedback] {
        objects.map { object in
            LearningFeedback(
                gesture: .replaced, mode: .proofread,
                originalText: "I need a \(from) \(object).",
                generatedText: "I need a \(from) \(object).",
                finalText: "I need a \(to) \(object).",
                provider: "localLlama", model: "qwen"
            )
        }
    }

    private func memory(_ key: String, in coordinator: LearningCoordinator) async throws -> WritingMemory {
        let all = await coordinator.memories()
        return try XCTUnwrap(all.first { $0.dedupKey == key }, key)
    }

    func testDoingTheOppositeWeakensTheEstablishedMemory() async throws {
        let coordinator = learner()
        for feedback in swaps(from: "big", to: "large", ["house", "office", "garage"]) {
            await coordinator.recordFeedback(feedback, config: on)
        }
        let forward = try await memory("vocabulary:en:big>large", in: coordinator)
        XCTAssertEqual(forward.state, .active)
        XCTAssertEqual(forward.evidenceScore, 1.35, accuracy: 1e-9, "long-term from the second edit on (1.0), then one more")

        for feedback in swaps(from: "large", to: "big", ["kitchen"]) {
            await coordinator.recordFeedback(feedback, config: on)
        }
        let weakened = try await memory("vocabulary:en:big>large", in: coordinator)
        XCTAssertEqual(weakened.state, .active, "one undo takes 0.7, and 0.65 is enough to stay")
        XCTAssertEqual(weakened.evidenceScore, forward.evidenceScore - 0.7, accuracy: 1e-9)
        XCTAssertEqual(weakened.occurrenceCount, forward.occurrenceCount, "no confirmation")
        XCTAssertEqual(weakened.lastConfirmedAt, forward.lastConfirmedAt)
        XCTAssertEqual(weakened.contradictionCount, 1)

        let opposite = try await memory("vocabulary:en:large>big", in: coordinator)
        XCTAssertEqual(opposite.state, .candidate)
        XCTAssertEqual(opposite.occurrenceCount, 1)

        for feedback in swaps(from: "large", to: "big", ["attic"]) {
            await coordinator.recordFeedback(feedback, config: on)
        }
        let forgotten = try await memory("vocabulary:en:big>large", in: coordinator)
        XCTAssertEqual(forgotten.state, .archived, "a second undo leaves nothing: forgotten")
        let kept = try await memory("vocabulary:en:large>big", in: coordinator)
        XCTAssertEqual(kept.state, .active, "and the direction the user keeps came back: long-term")
    }

    func testTheDirectionTheUserKeepsWinsAndTheOtherLeavesThePrompt() async throws {
        let coordinator = learner()
        let text = "We need a big house and a large office."
        for feedback in swaps(from: "big", to: "large", ["house", "office", "garage"]) {
            await coordinator.recordFeedback(feedback, config: on)
        }
        let before = await coordinator.relevantMemories(for: text, mode: .proofread, config: on)
        XCTAssertEqual(before.map(\.dedupKey), ["vocabulary:en:big>large"])

        for feedback in swaps(from: "large", to: "big", ["kitchen", "attic", "cellar"]) {
            await coordinator.recordFeedback(feedback, config: on)
        }
        let flipped = await coordinator.relevantMemories(for: text, mode: .proofread, config: on)
        XCTAssertEqual(flipped.map(\.dedupKey), ["vocabulary:en:large>big"])
        let old = try await memory("vocabulary:en:big>large", in: coordinator)
        XCTAssertEqual(old.evidenceScore, 0, accuracy: 1e-9, "never below zero")
    }

    func testPuttingAPrepositionBackWeakensTheMemoryThatDroppedIt() async throws {
        let (coordinator, memory) = try await learnedDiscussAbout()
        let primed = await retrieve(coordinator)
        XCTAssertEqual(primed.count, 1, "the memory is in use, and the retrieval cache is filled")

        // The model, reminded, dropped "about"; the user put it back.
        await coordinator.recordFeedback(
            LearningFeedback(
                gesture: .replaced, mode: .proofread,
                originalText: "we should discuss about the plan.",
                generatedText: "we should discuss the plan.",
                finalText: "we should discuss about the plan.",
                provider: "localLlama", model: "qwen", usedMemoryIDs: [memory.id]
            ),
            config: on
        )
        let after = try await onlyMemory(coordinator)
        XCTAssertEqual(after.state, .archived, "0.3 is left: forgotten")
        XCTAssertEqual(after.evidenceScore, memory.evidenceScore - 0.7, accuracy: 1e-9)
        XCTAssertEqual(after.occurrenceCount, memory.occurrenceCount)
        let used = await retrieve(coordinator)
        XCTAssertTrue(used.isEmpty, "it left the prompt at once")
    }

    /// The exact situation of copying from the full panel: a pinned memory with a single copy's worth of
    /// evidence, a reminded model that dropped "about", and a copy of the text with it put back.
    private func remindedCopy(_ memory: WritingMemory, edited: Bool) -> LearningFeedback {
        LearningFeedback(
            gesture: .copied, mode: .proofread,
            originalText: "we must discuss about the schedule tomorrow.",
            generatedText: "we must discuss the schedule tomorrow.",
            finalText: edited ? "we must discuss about the schedule tomorrow." : "we must discuss the schedule tomorrow.",
            provider: "localLlama", model: "qwen", usedMemoryIDs: [memory.id]
        )
    }

    func testCopyingAnEditThatPutsThePrepositionBackWeakensAPinnedMemoryToo() async throws {
        let coordinator = learner()
        await coordinator.recordFeedback(accept("plan", gesture: .copied), config: on)
        let first = try await onlyMemory(coordinator)
        XCTAssertEqual(first.evidenceScore, 0.05, accuracy: 1e-9)
        await coordinator.setPinned(true, id: first.id)

        await coordinator.recordFeedback(remindedCopy(first, edited: true), config: on)
        let after = try await onlyMemory(coordinator)
        XCTAssertEqual(after.evidenceScore, 0, accuracy: 1e-9, "0.05 minus 0.1, floored")
        XCTAssertEqual(after.state, .pinned)
        XCTAssertEqual(after.occurrenceCount, first.occurrenceCount)
    }

    func testCopyingTheRemindedSuggestionUneditedLeavesTheMemoryAlone() async throws {
        let coordinator = learner()
        await coordinator.recordFeedback(accept("plan", gesture: .copied), config: on)
        let first = try await onlyMemory(coordinator)
        await coordinator.setPinned(true, id: first.id)

        await coordinator.recordFeedback(remindedCopy(first, edited: false), config: on)
        let after = try await onlyMemory(coordinator)
        XCTAssertEqual(after.evidenceScore, first.evidenceScore, accuracy: 1e-9, "a reminder that worked is no evidence")
        XCTAssertEqual(after.occurrenceCount, first.occurrenceCount)
    }

    func testAContradictionOfAMemoryThatDoesNotExistCreatesNothing() async throws {
        let coordinator = learner()
        await coordinator.recordFeedback(
            LearningFeedback(
                gesture: .replaced, mode: .proofread,
                originalText: "we should discuss about the plan.",
                generatedText: "we should discuss the plan.",
                finalText: "we should discuss about the plan.",
                provider: "localLlama", model: "qwen"
            ),
            config: on
        )
        let memories = await coordinator.memories()
        XCTAssertTrue(memories.isEmpty)
    }

    func testAReminderThatWorkedIsNeitherSupportNorOpposition() async throws {
        let coordinator = learner()
        for feedback in swaps(from: "big", to: "large", ["house", "office", "garage"]) {
            await coordinator.recordFeedback(feedback, config: on)
        }
        let forward = try await memory("vocabulary:en:big>large", in: coordinator)
        // One flip back: the opposite now exists, and the forward memory drops to a candidate.
        for feedback in swaps(from: "large", to: "big", ["kitchen"]) {
            await coordinator.recordFeedback(feedback, config: on)
        }
        let backward = try await memory("vocabulary:en:large>big", in: coordinator)
        let weakenedForward = try await memory("vocabulary:en:big>large", in: coordinator)

        // The model, reminded of big>large, made that change and the user took it as is.
        func modelSwap(_ object: String, reminded: Bool) -> LearningFeedback {
            LearningFeedback(
                gesture: .replaced, mode: .proofread,
                originalText: "I need a big \(object).", generatedText: "I need a large \(object).",
                finalText: "I need a large \(object).", provider: "localLlama", model: "qwen",
                usedMemoryIDs: reminded ? [forward.id] : []
            )
        }
        await coordinator.recordFeedback(modelSwap("garage", reminded: true), config: on)
        let afterReminded = try await memory("vocabulary:en:large>big", in: coordinator)
        XCTAssertEqual(afterReminded.evidenceScore, backward.evidenceScore, accuracy: 1e-9)
        let forwardAfterReminded = try await memory("vocabulary:en:big>large", in: coordinator)
        XCTAssertEqual(forwardAfterReminded.evidenceScore, weakenedForward.evidenceScore, accuracy: 1e-9)

        // Without the reminder it is an ordinary observation: it supports one and opposes the other.
        await coordinator.recordFeedback(modelSwap("attic", reminded: false), config: on)
        let afterPlain = try await memory("vocabulary:en:large>big", in: coordinator)
        XCTAssertEqual(afterPlain.evidenceScore, backward.evidenceScore - 0.3, accuracy: 1e-9)
        let forwardAfterPlain = try await memory("vocabulary:en:big>large", in: coordinator)
        XCTAssertEqual(forwardAfterPlain.evidenceScore, weakenedForward.evidenceScore + 0.15, accuracy: 1e-9)
    }

    // MARK: fading

    private let key = "grammar:en:discuss about"

    private func learnedDiscussAbout(clock: TestClock) async throws -> (LearningCoordinator, WritingMemory) {
        let coordinator = learner(clock: clock)
        for topic in topics.prefix(2) {
            await coordinator.recordFeedback(edit(topic), config: on)
        }
        return (coordinator, try await onlyMemory(coordinator))
    }

    func testAMemoryFadesOutOfThePromptIsForgottenAndComesBackWhenItsPatternDoes() async throws {
        let clock = TestClock()
        let (coordinator, first) = try await learnedDiscussAbout(clock: clock)
        XCTAssertEqual(first.state, .active)
        let usedAtFirst = await retrieve(coordinator)
        XCTAssertEqual(usedAtFirst.count, 1)

        clock.advance(days: 100)
        let usedAt100 = await retrieve(coordinator)
        XCTAssertEqual(usedAt100.count, 1, "0.58 of evidence left")

        clock.advance(days: 30)
        let usedAt130 = await retrieve(coordinator)
        XCTAssertTrue(usedAt130.isEmpty, "below the bar, so out of the prompt")
        let forgotten = try await onlyMemory(coordinator)
        XCTAssertEqual(forgotten.state, .archived, "forgotten, not demoted")

        clock.advance(days: 150)
        let trace = try await onlyMemory(coordinator)
        XCTAssertEqual(trace.state, .archived)

        // The habit comes back: the trace is recognised, and the memory is long-term again at once.
        await coordinator.recordFeedback(edit("design"), config: on)
        let woken = try await onlyMemory(coordinator)
        XCTAssertEqual(woken.id, first.id)
        XCTAssertEqual(woken.state, .active)
        XCTAssertEqual(woken.occurrenceCount, first.occurrenceCount + 1)
        XCTAssertEqual(woken.evidenceScore, LearningPolicy.activeThreshold, accuracy: 1e-9, "what was left and the edit are below the start")
        let used = await retrieve(coordinator)
        XCTAssertEqual(used.count, 1)
    }

    func testPinnedAndDisabledMemoriesHoldStillAndGiveTheirTimeBackWhenReleased() async throws {
        let clock = TestClock()
        let (coordinator, memory) = try await learnedDiscussAbout(clock: clock)

        await coordinator.setPinned(true, id: memory.id)
        clock.advance(days: 400)
        let pinned = try await onlyMemory(coordinator)
        XCTAssertEqual(pinned.state, .pinned)
        XCTAssertEqual(pinned.evidence(at: clock.now), memory.evidenceScore, accuracy: 1e-9)

        await coordinator.setPinned(false, id: memory.id)
        let unpinned = try await onlyMemory(coordinator)
        XCTAssertEqual(unpinned.state, .active, "400 pinned days did not count against it")
        clock.advance(days: 60)
        let fading = try await onlyMemory(coordinator)
        XCTAssertEqual(fading.state, .active)
        XCTAssertEqual(fading.evidence(at: clock.now), memory.evidenceScore * pow(0.5, 30.0 / 90.0), accuracy: 1e-9)

        await coordinator.setEnabled(false, id: memory.id)
        clock.advance(days: 400)
        let disabled = try await onlyMemory(coordinator)
        XCTAssertEqual(disabled.state, .disabled)
        await coordinator.setEnabled(true, id: memory.id)
        let enabled = try await onlyMemory(coordinator)
        XCTAssertEqual(enabled.state, .active, "it had proved itself, so it is long-term again")
        XCTAssertEqual(enabled.lastConfirmedAt, clock.now, "the 400 disabled days do not count against it")
        XCTAssertEqual(enabled.evidence(at: clock.now), LearningPolicy.activeThreshold, accuracy: 1e-9)
    }

    func testRestoringAnArchivedMemoryMakesItActiveAgain() async throws {
        let clock = TestClock()
        let (coordinator, memory) = try await learnedDiscussAbout(clock: clock)
        clock.advance(days: 400)
        let archived = try await onlyMemory(coordinator)
        XCTAssertEqual(archived.state, .archived)

        await coordinator.setEnabled(true, id: memory.id)
        let restored = try await onlyMemory(coordinator)
        XCTAssertEqual(restored.state, .active)
        XCTAssertEqual(restored.lastConfirmedAt, clock.now)
        let used = await retrieve(coordinator)
        XCTAssertEqual(used.count, 1)
    }

    func testAHabitThatKeepsRecurringDoesNotFadeButOneThatStopsDoes() async throws {
        let clock = TestClock()
        let (coordinator, memory) = try await learnedDiscussAbout(clock: clock)
        let objects = ["alpha", "bravo", "charlie", "delta", "echo", "foxtrot", "golf", "hotel"]

        // Every 25 days the reminded model fixes it and the user takes that as is: 200 days.
        for object in objects {
            clock.advance(days: 25)
            var reminded = accept(object)
            reminded.usedMemoryIDs = [memory.id]
            await coordinator.recordFeedback(reminded, config: on)
        }
        let alive = try await onlyMemory(coordinator)
        XCTAssertEqual(alive.state, .active)
        XCTAssertEqual(alive.evidence(at: clock.now), memory.evidenceScore, accuracy: 1e-9, "not a bit weaker")
        XCTAssertEqual(alive.occurrenceCount, memory.occurrenceCount, "and not counted as more evidence either")
        let used = await retrieve(coordinator)
        XCTAssertEqual(used.count, 1)

        // Then it stops showing up.
        clock.advance(days: 130)
        let gone = await retrieve(coordinator)
        XCTAssertTrue(gone.isEmpty)
    }

    func testAContradictionCutsIntoWhatHasFadedAndTheFadingGoesOnFromThere() async throws {
        let clock = TestClock()
        let (coordinator, memory) = try await learnedDiscussAbout(clock: clock)
        clock.advance(days: 60)
        await coordinator.recordFeedback(
            LearningFeedback(
                gesture: .replaced, mode: .proofread,
                originalText: "we should discuss about the plan.",
                generatedText: "we should discuss the plan.",
                finalText: "we should discuss about the plan.",
                provider: "localLlama", model: "qwen", usedMemoryIDs: [memory.id]
            ),
            config: on
        )
        let after = try await onlyMemory(coordinator)
        let left = memory.evidenceScore * pow(0.5, 30.0 / 90.0)
        XCTAssertEqual(after.evidence(at: clock.now), left - 0.7, accuracy: 1e-9)
        XCTAssertEqual(after.state, .archived, "what the undo leaves is below the bar: forgotten")
        XCTAssertEqual(after.lastConfirmedAt, memory.lastConfirmedAt, "no confirmation")
    }

    // MARK: managing memories

    private func seeded() async throws -> (LearningCoordinator, UUID) {
        let coordinator = learner()
        await coordinator.recordFeedback(edit("plan"), config: on)
        let id = try await onlyMemory(coordinator).id
        return (coordinator, id)
    }

    func testPinningDisablingAndTheirUndoFollowTheEvidence() async throws {
        let (coordinator, id) = try await seeded()
        func state() async -> MemoryState? { await coordinator.memories().first { $0.id == id }?.state }

        await coordinator.setPinned(true, id: id)
        let pinned = await state()
        XCTAssertEqual(pinned, .pinned)
        await coordinator.recordFeedback(edit("budget"), config: on)
        let stillPinned = await state()
        XCTAssertEqual(stillPinned, .pinned, "more evidence does not unpin")

        await coordinator.setPinned(false, id: id)
        let unpinned = await state()
        XCTAssertEqual(unpinned, .active, "its pattern came back while it was pinned: long-term")

        await coordinator.setEnabled(false, id: id)
        let disabled = await state()
        XCTAssertEqual(disabled, .disabled)
        await coordinator.recordFeedback(edit("schedule"), config: on)
        let stillDisabled = await state()
        XCTAssertEqual(stillDisabled, .disabled, "more evidence does not re-enable")

        await coordinator.setEnabled(true, id: id)
        let enabled = await state()
        XCTAssertEqual(enabled, .active, "proved, and well above the bar")
    }

    func testEditedInstructionIsCleanedLimitedAndKept() async throws {
        let (coordinator, id) = try await seeded()
        await coordinator.setInstruction("  my   own\nwording  ", id: id)
        var memory = try await onlyMemory(coordinator)
        XCTAssertEqual(memory.instruction, "my own wording")
        XCTAssertTrue(memory.userEdited)

        await coordinator.setInstruction("   \n ", id: id)
        memory = try await onlyMemory(coordinator)
        XCTAssertEqual(memory.instruction, "my own wording", "an empty text is ignored")

        await coordinator.recordFeedback(edit("budget"), config: on)
        memory = try await onlyMemory(coordinator)
        XCTAssertEqual(memory.instruction, "my own wording", "new evidence does not overwrite it")

        await coordinator.setInstruction(String(repeating: "x", count: 500), id: id)
        memory = try await onlyMemory(coordinator)
        XCTAssertEqual(memory.instruction.count, LearningPolicy.maxInstructionLength)
    }

    func testDeletingOneOrAllMemories() async throws {
        let (coordinator, id) = try await seeded()
        await coordinator.recordFeedback(
            LearningFeedback(
                gesture: .replaced, mode: .proofread, originalText: "i have meeting.",
                generatedText: "i have a meeting.", finalText: "i have a meeting.",
                provider: "localLlama", model: "qwen"
            ),
            config: on
        )
        let two = await coordinator.memories()
        XCTAssertEqual(two.count, 2)

        await coordinator.deleteMemory(id: id)
        let one = await coordinator.memories()
        XCTAssertEqual(one.map(\.dedupKey), ["grammar:en:articles"])

        await coordinator.deleteAllMemories()
        let none = await coordinator.memories()
        XCTAssertTrue(none.isEmpty)
        let stats = await coordinator.stats()
        XCTAssertGreaterThan(stats.eventCount, 0, "clearing memories keeps the feedback log")
    }

    func testManagementNeverCreatesTheDatabase() async throws {
        let url = try makeStoreURL()
        let coordinator = LearningCoordinator(storeURL: url, hmacKey: testKey())
        let id = UUID()
        await coordinator.setPinned(true, id: id)
        await coordinator.setEnabled(false, id: id)
        await coordinator.setInstruction("text", id: id)
        await coordinator.deleteMemory(id: id)
        await coordinator.deleteAllMemories()
        let memories = await coordinator.memories()
        XCTAssertTrue(memories.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }

    func testMemoriesOnDiskHoldNoSentences() async throws {
        let url = try makeStoreURL()
        let coordinator = LearningCoordinator(storeURL: url, hmacKey: testKey())
        let secretLine = LearningFeedback(
            gesture: .replaced, mode: .proofread,
            originalText: "we should discuss about the quokka schedule.",
            generatedText: "we should discuss about the quokka schedule.",
            finalText: "we should discuss the quokka schedule.",
            provider: "localLlama", model: "qwen"
        )
        await coordinator.recordFeedback(secretLine, config: on)

        let file = try Data(contentsOf: url)
        XCTAssertNotNil(file.range(of: Data("discuss about".utf8)), "sanity: the abstracted trigger is stored")
        XCTAssertNil(file.range(of: Data("quokka".utf8)), "not even the words around the edit")
        XCTAssertNil(file.range(of: Data("schedule".utf8)))
        XCTAssertNil(file.range(of: Data("we should".utf8)))
    }

    func testDisabledLearningNeverCreatesTheDatabase() async throws {
        let url = try makeStoreURL()
        let coordinator = LearningCoordinator(storeURL: url)
        await coordinator.prepare(config: LearningConfig(enabled: false))
        let stats = await coordinator.stats()
        await coordinator.resetAll()
        XCTAssertEqual(stats, .empty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.deletingLastPathComponent().path))
    }

    func testEnablingLearningCreatesTheDatabase() async throws {
        let url = try makeStoreURL()
        let coordinator = LearningCoordinator(storeURL: url)
        await coordinator.prepare(config: LearningConfig(enabled: true))
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
        let stats = await coordinator.stats()
        XCTAssertEqual(stats, .empty)
    }

    func testExistingDataStaysVisibleAndResettableAfterDisabling() async throws {
        let url = try makeStoreURL()
        let seeded = try SQLiteLearningStore(url: url)
        try await seeded.saveMemory(
            WritingMemory(
                id: UUID(), dedupKey: "grammar:en:articles", kind: .grammar, language: "en",
                modeScope: nil, triggers: [], instruction: "Check articles.",
                evidenceScore: 1.2, occurrenceCount: 4, state: .active, userEdited: false,
                createdAt: Date(), lastConfirmedAt: Date()
            )
        )

        let coordinator = LearningCoordinator(storeURL: url)
        await coordinator.prepare(config: LearningConfig(enabled: false))
        let before = await coordinator.stats()
        XCTAssertEqual(before.count(.active), 1)

        await coordinator.resetAll()
        let after = await coordinator.stats()
        XCTAssertEqual(after, .empty)
    }

    // MARK: use of memories, and the ones that were organized

    /// A suggestion that left the text as it was: nothing to learn, but the memories were in the prompt.
    private func unchanged(
        _ subject: String = "roadmap", used: [UUID], gesture: UserGesture = .replaced
    ) -> LearningFeedback {
        let text = "the \(subject) looks fine to everyone here."
        return LearningFeedback(
            gesture: gesture, mode: .proofread, originalText: text, generatedText: text,
            finalText: text, provider: "localLlama", model: "qwen", usedMemoryIDs: used
        )
    }

    private struct Organized {
        let coordinator: LearningCoordinator
        let store: SQLiteLearningStore
        let url: URL
        let parent: WritingMemory
        let children: [WritingMemory]
    }

    /// A store holding a rule and the three memories it stands in for, made by a real organizing pass.
    private func organized(clock: TestClock = TestClock(), sources: Int = 3) async throws -> Organized {
        let url = try makeStoreURL()
        let store = try SQLiteLearningStore(url: url)
        let children = ["discuss", "mention", "emphasize", "reply", "describe", "explain"]
            .prefix(sources).map { DreamFixtures.preposition($0) }
        for child in children { try await store.saveMemory(child) }
        await MemoryDreamCoordinator(store: store, clock: clock.reader).run()
        let parent = try unwrapped(await store.memories().first { $0.level != .specific })
        let coordinator = LearningCoordinator(storeURL: url, hmacKey: testKey(), clock: clock.reader)
        return Organized(coordinator: coordinator, store: store, url: url, parent: parent, children: children)
    }

    private func stored(_ id: UUID, in store: SQLiteLearningStore) async throws -> WritingMemory {
        try unwrapped(await store.memory(id: id))
    }

    func testTheUseOfAMemoryIsCountedOncePerUsedSuggestion() async throws {
        let clock = TestClock()
        let (coordinator, memory) = try await learnedDiscussAbout(clock: clock)
        XCTAssertEqual([memory.retrievalCount, memory.successfulUseCount, memory.contradictionCount], [0, 0, 0])
        XCTAssertNil(memory.lastUsedAt)

        clock.advance(days: 1)
        await coordinator.recordFeedback(unchanged("roadmap", used: [memory.id, memory.id]), config: on)
        let once = try await onlyMemory(coordinator)
        XCTAssertEqual(once.retrievalCount, 1, "in the prompt once, however often it is listed")
        XCTAssertEqual(once.lastUsedAt, clock.now)
        XCTAssertEqual(once.successfulUseCount, 0, "it was in the prompt, and nothing shows it did anything")
        XCTAssertEqual(once.lastConfirmedAt, memory.lastConfirmedAt, "using a memory is not confirming it")
        XCTAssertEqual(once.evidenceScore, memory.evidenceScore)

        clock.advance(days: 1)
        await coordinator.recordFeedback(unchanged("schedule", used: [memory.id]), config: on)
        let twice = try await onlyMemory(coordinator)
        XCTAssertEqual(twice.retrievalCount, 2)
        XCTAssertEqual(twice.lastUsedAt, clock.now)
    }

    func testNothingIsCountedForRegeneratingAnUnfinishedSuggestionOrARepeat() async throws {
        let (coordinator, memory) = try await learnedDiscussAbout()

        await coordinator.recordFeedback(unchanged("roadmap", used: [memory.id], gesture: .regenerated), config: on)
        var unfinished = unchanged("roadmap", used: [memory.id])
        unfinished.generatedText = nil
        await coordinator.recordFeedback(unfinished, config: on)
        let none = try await onlyMemory(coordinator)
        XCTAssertEqual([none.retrievalCount, none.successfulUseCount, none.contradictionCount], [0, 0, 0])
        XCTAssertNil(none.lastUsedAt)

        let feedback = unchanged("budget", used: [memory.id])
        await coordinator.recordFeedback(feedback, config: on)
        await coordinator.recordFeedback(feedback, config: on)
        let once = try await onlyMemory(coordinator)
        XCTAssertEqual(once.retrievalCount, 1, "the same feedback again is not another use")
    }

    func testPersonalizingCountsNothingBecauseNothingWasShownYet() async throws {
        let (coordinator, memory) = try await learnedDiscussAbout()
        for _ in 0..<3 {
            let result = await coordinator.personalize(
                prompt: basePrompt, for: "we should discuss about the roadmap", mode: .proofread, config: on
            )
            XCTAssertEqual(result.usedMemoryIDs, [memory.id])
        }
        let after = try await onlyMemory(coordinator)
        XCTAssertEqual([after.retrievalCount, after.successfulUseCount], [0, 0])
        XCTAssertNil(after.lastUsedAt)
    }

    func testAReminderThatWorkedIsASuccessfulUseButTheUsersOwnEditIsNot() async throws {
        let (coordinator, memory) = try await learnedDiscussAbout()

        var reminded = accept("firewall")
        reminded.usedMemoryIDs = [memory.id]
        await coordinator.recordFeedback(reminded, config: on)
        let worked = try await onlyMemory(coordinator)
        XCTAssertEqual(worked.successfulUseCount, 1)
        XCTAssertEqual(worked.retrievalCount, 1)
        XCTAssertEqual(worked.evidenceScore, memory.evidenceScore, accuracy: 1e-9, "and still no new evidence")

        var edited = edit("contract")
        edited.usedMemoryIDs = [memory.id]
        await coordinator.recordFeedback(edited, config: on)
        var plain = accept("report")
        plain.usedMemoryIDs = []
        await coordinator.recordFeedback(plain, config: on)
        let after = try await onlyMemory(coordinator)
        XCTAssertEqual(after.successfulUseCount, 1, "not for an edit, and not for a fix nobody reminded of")
        XCTAssertEqual(after.retrievalCount, 2)
    }

    func testTheRuleThatGaveTheReminderGetsTheCreditForTheMemoryItStandsInFor() async throws {
        let clock = TestClock()
        let setup = try await organized(clock: clock)
        clock.advance(days: 2)

        var reminded = accept("firewall")
        reminded.usedMemoryIDs = [setup.parent.id]
        await setup.coordinator.recordFeedback(reminded, config: on)

        let parent = try await stored(setup.parent.id, in: setup.store)
        XCTAssertEqual(parent.successfulUseCount, 1)
        XCTAssertEqual(parent.retrievalCount, 1)
        XCTAssertEqual(parent.lastConfirmedAt, clock.now, "the habit is still there, so the rule is kept alive")
        XCTAssertEqual(parent.evidenceScore, setup.parent.evidenceScore, accuracy: 1e-9, "the reminder is no new evidence")
        XCTAssertEqual(parent.occurrenceCount, setup.parent.occurrenceCount)

        let child = try await stored(setup.children[0].id, in: setup.store)
        XCTAssertEqual([child.successfulUseCount, child.retrievalCount], [0, 0], "it was not in the prompt itself")
        XCTAssertEqual(child.occurrenceCount, setup.children[0].occurrenceCount, "and it was not counted again")
        XCTAssertEqual(child.evidenceScore, setup.children[0].evidenceScore, accuracy: 1e-9)
    }

    func testASourceSeenAgainCountsForItsRule() async throws {
        let clock = TestClock()
        let setup = try await organized(clock: clock)
        clock.advance(days: 2)

        await setup.coordinator.recordFeedback(edit("firewall"), config: on)

        let child = try await stored(setup.children[0].id, in: setup.store)
        XCTAssertEqual(child.occurrenceCount, setup.children[0].occurrenceCount + 1)
        let parent = try await stored(setup.parent.id, in: setup.store)
        XCTAssertEqual(parent.occurrenceCount, setup.parent.occurrenceCount + 1)
        XCTAssertEqual(parent.evidenceScore, setup.parent.evidenceScore + 0.35, accuracy: 1e-9)
        XCTAssertEqual(parent.lastConfirmedAt, clock.now)
        XCTAssertEqual(parent.instruction, setup.parent.instruction)
    }

    func testARulePutAwayOrSwitchedOffIsNotWokenBySeeingASourceAgain() async throws {
        for state in [MemoryState.archived, .disabled] {
            let setup = try await organized()
            try await setup.store.updateMemory(id: setup.parent.id) { $0.state = state }
            let before = try await stored(setup.parent.id, in: setup.store)

            await setup.coordinator.recordFeedback(edit("firewall"), config: on)

            let child = try await stored(setup.children[0].id, in: setup.store)
            XCTAssertEqual(child.occurrenceCount, setup.children[0].occurrenceCount + 1, "\(state)")
            let after = try await stored(setup.parent.id, in: setup.store)
            XCTAssertEqual(after, before, "\(state)")
        }
    }

    func testUndoingAMemoryCountsAgainstItAndAgainstItsRule() async throws {
        let setup = try await organized()
        let putBack = LearningFeedback(
            gesture: .replaced, mode: .proofread,
            originalText: "we should discuss about the plan.",
            generatedText: "we should discuss the plan.",
            finalText: "we should discuss about the plan.",
            provider: "localLlama", model: "qwen", usedMemoryIDs: [setup.parent.id]
        )

        await setup.coordinator.recordFeedback(putBack, config: on)

        let child = try await stored(setup.children[0].id, in: setup.store)
        XCTAssertEqual(child.contradictionCount, 1)
        XCTAssertEqual(child.evidenceScore, setup.children[0].evidenceScore - 0.7, accuracy: 1e-9)
        let parent = try await stored(setup.parent.id, in: setup.store)
        XCTAssertEqual(parent.contradictionCount, 1)
        XCTAssertEqual(parent.evidenceScore, setup.parent.evidenceScore - 0.7, accuracy: 1e-9)
        let other = try await stored(setup.children[1].id, in: setup.store)
        XCTAssertEqual(other.contradictionCount, 0, "only the pattern that was undone")
    }

    func testOnlyTheUserUndoingSomethingIsAContradiction() async throws {
        let (coordinator, memory) = try await learnedDiscussAbout()
        await coordinator.recordFeedback(unchanged("roadmap", used: [memory.id], gesture: .regenerated), config: on)
        await coordinator.recordFeedback(unchanged("budget", used: [memory.id]), config: on)
        let quiet = try await onlyMemory(coordinator)
        XCTAssertEqual(quiet.contradictionCount, 0, "regenerating, or using a suggestion as it was, says nothing against it")

        await coordinator.recordFeedback(
            LearningFeedback(
                gesture: .replaced, mode: .proofread,
                originalText: "we should discuss about the plan.", generatedText: "we should discuss the plan.",
                finalText: "we should discuss about the plan.", provider: "localLlama", model: "qwen",
                usedMemoryIDs: [memory.id]
            ),
            config: on
        )
        let undone = try await onlyMemory(coordinator)
        XCTAssertEqual(undone.contradictionCount, 1)
    }

    func testLearningOffLeavesOrganizedMemoriesAndTheirCountsAlone() async throws {
        let setup = try await organized()
        let off = LearningConfig(enabled: false)
        let before = try await setup.store.memories()

        var feedback = accept("firewall")
        feedback.usedMemoryIDs = [setup.parent.id]
        await setup.coordinator.recordFeedback(feedback, config: off)
        let result = await setup.coordinator.personalize(
            prompt: basePrompt, for: "we should discuss about the roadmap", mode: .proofread, config: off
        )

        XCTAssertEqual(Array(result.systemPrompt.utf8), Array(basePrompt.utf8), "byte for byte")
        XCTAssertTrue(result.usedMemoryIDs.isEmpty)
        let after = try await setup.store.memories()
        XCTAssertEqual(after, before)
    }

    func testAnOrganizedStoreGivesThePreciseMemoryOrTheRuleWithinTheBudget() async throws {
        let setup = try await organized()

        let general = await setup.coordinator.personalize(
            prompt: basePrompt, for: "The roadmap for the next quarter looks quite fine to everyone.",
            mode: .proofread, config: on
        )
        XCTAssertEqual(general.usedMemoryIDs, [setup.parent.id], "the rule speaks for the memories behind it")
        XCTAssertTrue(general.systemPrompt.hasSuffix(setup.parent.instruction))

        let precise = await setup.coordinator.personalize(
            prompt: basePrompt, for: "we should discuss about the roadmap", mode: .proofread, config: on
        )
        XCTAssertEqual(precise.usedMemoryIDs, [setup.children[0].id], "and the precise memory takes its place when it applies")
        XCTAssertTrue(precise.systemPrompt.hasSuffix(setup.children[0].instruction))
        XCTAssertFalse(precise.systemPrompt.contains(setup.parent.instruction))
        let added = precise.systemPrompt.dropFirst(basePrompt.count)
        XCTAssertLessThanOrEqual(added.count, PromptComposer.header.count + LearningPolicy.maxPersonalizationCharacters + 10)
    }

    func testARuleThatKeepsWorkingBecomesCoreOnceItIsOldEnough() async throws {
        let clock = TestClock()
        let setup = try await organized(clock: clock, sources: 5)
        let dreamer = MemoryDreamCoordinator(store: setup.store, clock: clock.reader)
        let counts = try await setup.store.sourceCounts()
        XCTAssertEqual(counts, [setup.parent.id: 5])

        // The reminder keeps working: the model applies it and the user accepts the result.
        for topic in ["firewall", "report", "contract"] {
            clock.advance(days: 1)
            var reminded = accept(topic)
            reminded.usedMemoryIDs = [setup.parent.id]
            await setup.coordinator.recordFeedback(reminded, config: on)
        }
        let used = try await stored(setup.parent.id, in: setup.store)
        XCTAssertEqual(used.successfulUseCount, 3, "without this a rule could never earn its way to core")

        await dreamer.run()
        let tooYoung = try await stored(setup.parent.id, in: setup.store)
        XCTAssertEqual(tooYoung.level, .generalized, "three days old")

        clock.advance(days: 11)
        await dreamer.run()
        let core = try await stored(setup.parent.id, in: setup.store)
        XCTAssertEqual(core.level, .core)
        XCTAssertEqual(core.state, .active)
        // Both the rule's own counters and its sources are intact.
        XCTAssertEqual(core.successfulUseCount, 3)
        let children = try await setup.store.sources(ofParent: core.id)
        XCTAssertEqual(children.count, 5)
    }

    func testOrganizingAddsNoTextToTheFile() async throws {
        let setup = try await organized()
        var feedback = self.feedback()
        feedback.usedMemoryIDs = [setup.parent.id]
        await setup.coordinator.recordFeedback(feedback, config: on)

        let file = try Data(contentsOf: setup.url)
        for secret in ["zq-source-text", "zq-suggestion-text"] {
            XCTAssertNil(file.range(of: Data(secret.utf8)), "\(secret) must not be stored")
        }
    }

    // MARK: learning at once, forgetting what does not prove itself

    /// The model fixed a number the user got wrong ("tickets" for "ticket") and the user took it.
    private func numberFix(_ noun: String) -> LearningFeedback {
        LearningFeedback(
            gesture: .replaced, mode: .proofread,
            originalText: "I need a tickets for the \(noun) tonight.",
            generatedText: "I need a ticket for the \(noun) tonight.",
            finalText: "I need a ticket for the \(noun) tonight.",
            provider: "localLlama", model: "qwen"
        )
    }

    private let ticketsText = "Please bring the tickets for the concert tonight."

    func testAFixOfTheSameWordInAnotherFormIsUsedOnlyOnceItComesBack() async throws {
        let coordinator = learner()
        await coordinator.recordFeedback(numberFix("show"), config: on)
        let first = try await onlyMemory(coordinator)
        XCTAssertEqual(first.dedupKey, "spelling:en:tickets>ticket")
        XCTAssertEqual(first.state, .archived, "only a trace")
        let unused = await coordinator.relevantMemories(for: ticketsText, mode: .proofread, config: on)
        XCTAssertTrue(unused.isEmpty)

        await coordinator.recordFeedback(numberFix("game"), config: on)
        let second = try await onlyMemory(coordinator)
        XCTAssertEqual(second.state, .active, "it came back: long-term at once")
        let used = await coordinator.relevantMemories(for: ticketsText, mode: .proofread, config: on)
        XCTAssertEqual(used.map(\.id), [first.id])
    }

    func testAReminderThatWorkedMakesAShortTermMemoryLongTerm() async throws {
        let coordinator = learner()
        await coordinator.recordFeedback(accept("plan"), config: on)
        let first = try await onlyMemory(coordinator)
        XCTAssertEqual(first.state, .candidate)

        // Reminded of it, the model fixed the same habit in a new text, and the user took that.
        var reminded = accept("budget")
        reminded.usedMemoryIDs = [first.id]
        await coordinator.recordFeedback(reminded, config: on)
        let after = try await onlyMemory(coordinator)
        XCTAssertEqual(after.state, .active)
        XCTAssertEqual(after.successfulUseCount, 1)
        XCTAssertEqual(after.occurrenceCount, 1, "no new evidence, as before")
    }

    func testAShortTermMemoryThatDoesNotProveItselfIsForgottenAfterSevenDays() async throws {
        let clock = TestClock()
        let coordinator = learner(clock: clock)
        await coordinator.recordFeedback(edit("plan"), config: on)

        clock.advance(days: LearningPolicy.shortTermDays - 1.0 / 24)
        let stillUsed = await retrieve(coordinator)
        XCTAssertEqual(stillUsed.count, 1, "an hour to go, and the retrieval cache is filled")

        clock.advance(days: 2.0 / 24)
        let gone = await retrieve(coordinator)
        XCTAssertTrue(gone.isEmpty, "a cache two hours old is judged again")
        let forgotten = try await onlyMemory(coordinator)
        XCTAssertEqual(forgotten.state, .archived)
        let stats = await coordinator.stats()
        XCTAssertEqual(stats.count(.candidate), 0)
        XCTAssertEqual(stats.count(.archived), 1)
    }

    func testEnablingAForgottenMemoryBringsItBackLongTerm() async throws {
        let clock = TestClock()
        let coordinator = learner(clock: clock)
        await coordinator.recordFeedback(edit("plan"), config: on)
        clock.advance(days: 10)
        let forgotten = try await onlyMemory(coordinator)
        XCTAssertEqual(forgotten.state, .archived)

        await coordinator.setEnabled(true, id: forgotten.id)
        let enabled = try await onlyMemory(coordinator)
        XCTAssertEqual(enabled.state, .active, "what Settings showed is what is enabled")
        let used = await retrieve(coordinator)
        XCTAssertEqual(used.count, 1)
    }

    func testStatsCountTheMemoriesAsTheyStandNow() async throws {
        let clock = TestClock()
        let coordinator = learner(clock: clock)
        await coordinator.recordFeedback(edit("plan"), config: on)
        await coordinator.recordFeedback(numberFix("show"), config: on)
        let fresh = await coordinator.stats()
        XCTAssertEqual([fresh.count(.candidate), fresh.count(.active), fresh.count(.archived)], [1, 0, 1])

        await coordinator.recordFeedback(edit("budget"), config: on)
        let proven = await coordinator.stats()
        XCTAssertEqual([proven.count(.candidate), proven.count(.active), proven.count(.archived)], [0, 1, 1])
        XCTAssertEqual(proven.count(.specific), 2)
    }
}
