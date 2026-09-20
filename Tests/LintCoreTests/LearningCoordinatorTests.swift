import XCTest
@testable import LintCore

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

    private func learner() -> LearningCoordinator {
        LearningCoordinator(storeURL: nil, hmacKey: testKey())
    }

    private func onlyMemory(_ coordinator: LearningCoordinator) async throws -> WritingMemory {
        let all = await coordinator.memories()
        return try XCTUnwrap(all.first)
    }

    func testThreeDifferentEditsTurnACandidateIntoAnActiveMemory() async throws {
        let coordinator = learner()
        for topic in topics.prefix(2) {
            await coordinator.recordFeedback(edit(topic), config: on)
        }
        let candidate = await coordinator.memories()
        XCTAssertEqual(candidate.map(\.dedupKey), ["grammar:en:discuss about"])
        XCTAssertEqual(candidate.first?.state, .candidate)
        XCTAssertEqual(candidate.first?.occurrenceCount, 2)

        await coordinator.recordFeedback(edit(topics[2]), config: on)
        let active = await coordinator.memories()
        XCTAssertEqual(active.count, 1)
        XCTAssertEqual(active.first?.state, .active)
        XCTAssertEqual(active.first?.occurrenceCount, 3)
        XCTAssertEqual(active.first?.triggers, ["discuss about"])
    }

    func testSevenAcceptsAreNeededToPromote() async throws {
        let coordinator = learner()
        for topic in topics.prefix(6) {
            await coordinator.recordFeedback(accept(topic), config: on)
        }
        let beforeSeventh = await coordinator.memories()
        XCTAssertEqual(beforeSeventh.first?.state, .candidate)
        await coordinator.recordFeedback(accept(topics[6]), config: on)
        let afterSeventh = await coordinator.memories()
        XCTAssertEqual(afterSeventh.first?.state, .active)
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

    func testExamplesAreKeptOnlyWhenAskedFor() async throws {
        let without = learner()
        await without.recordFeedback(edit("plan"), config: on)
        let bare = await without.memories()
        XCTAssertNil(bare.first?.negativeExample)

        let with = learner()
        await with.recordFeedback(edit("plan"), config: LearningConfig(enabled: true, storeExamples: true))
        let kept = await with.memories()
        XCTAssertEqual(kept.first?.negativeExample, "should discuss about the plan")
        XCTAssertEqual(kept.first?.preferredExample, "should discuss the plan")
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

    func testPromotionShowsUpInTheNextRetrievalEvenAfterTheCacheWasFilled() async throws {
        let coordinator = learner()
        for topic in topics.prefix(2) {
            await coordinator.recordFeedback(edit(topic), config: on)
        }
        let candidate = await retrieve(coordinator)
        XCTAssertTrue(candidate.isEmpty, "a candidate is not used yet")

        await coordinator.recordFeedback(edit(topics[2]), config: on)
        let active = await retrieve(coordinator)
        XCTAssertEqual(active.count, 1)
    }

    func testEveryChangeShowsUpInTheNextRetrieval() async throws {
        let (coordinator, id) = try await seeded()
        let untouched = await retrieve(coordinator)
        XCTAssertTrue(untouched.isEmpty, "one edit is only a candidate")

        await coordinator.setPinned(true, id: id)
        let pinned = await retrieve(coordinator)
        XCTAssertEqual(pinned.count, 1)

        await coordinator.setEnabled(false, id: id)
        let disabled = await retrieve(coordinator)
        XCTAssertTrue(disabled.isEmpty)

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

    private func learnedDiscussAbout() async throws -> (LearningCoordinator, WritingMemory) {
        let coordinator = learner()
        for topic in topics.prefix(3) {
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

    func testTheTranslationTargetDecidesWhichTerminologyApplies() async throws {
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

        func used(for target: String, mode: WritingMode = .translate) async -> [UUID] {
            await coordinator.personalize(
                prompt: basePrompt, for: "Where can I download the software?", mode: mode,
                translateTarget: target, config: on
            ).usedMemoryIDs
        }
        for target in ["繁體中文", "", "中文"] {
            let ids = await used(for: target)
            XCTAssertEqual(ids, [memory.id], "target \"\(target)\"")
        }
        for target in ["English", "日文", "簡體中文"] {
            let ids = await used(for: target)
            XCTAssertTrue(ids.isEmpty, "target \"\(target)\"")
        }
        let proofreading = await used(for: "繁體中文", mode: .proofread)
        XCTAssertTrue(proofreading.isEmpty, "a translation memory stays out of proofreading")
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

        for feedback in swaps(from: "large", to: "big", ["kitchen"]) {
            await coordinator.recordFeedback(feedback, config: on)
        }
        let weakened = try await memory("vocabulary:en:big>large", in: coordinator)
        XCTAssertEqual(weakened.state, .candidate, "one undo takes 0.7 of its 1.05")
        XCTAssertEqual(weakened.evidenceScore, forward.evidenceScore - 0.7, accuracy: 1e-9)
        XCTAssertEqual(weakened.occurrenceCount, forward.occurrenceCount, "no confirmation")
        XCTAssertEqual(weakened.lastConfirmedAt, forward.lastConfirmedAt)

        let opposite = try await memory("vocabulary:en:large>big", in: coordinator)
        XCTAssertEqual(opposite.state, .candidate)
        XCTAssertEqual(opposite.occurrenceCount, 1)
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
        XCTAssertEqual(after.state, .candidate)
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
        XCTAssertEqual(unpinned, .candidate, "0.7 of evidence is below the threshold")

        await coordinator.setEnabled(false, id: id)
        let disabled = await state()
        XCTAssertEqual(disabled, .disabled)
        await coordinator.recordFeedback(edit("schedule"), config: on)
        let stillDisabled = await state()
        XCTAssertEqual(stillDisabled, .disabled, "more evidence does not re-enable")

        await coordinator.setEnabled(true, id: id)
        let enabled = await state()
        XCTAssertEqual(enabled, .active, "three edits' worth of evidence")
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
        await coordinator.recordFeedback(secretLine, config: LearningConfig(enabled: true, storeExamples: true))

        let file = try Data(contentsOf: url)
        XCTAssertNotNil(file.range(of: Data("discuss about".utf8)), "sanity: the abstracted trigger is stored")
        XCTAssertNotNil(file.range(of: Data("quokka".utf8)), "sanity: an example keeps two words of context")
        XCTAssertNil(file.range(of: Data("schedule".utf8)), "but never the rest of the sentence")
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
                negativeExample: nil, preferredExample: nil, evidenceScore: 1.2,
                occurrenceCount: 4, state: .active, userEdited: false,
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
}
