import XCTest
@testable import LintCore

final class MemoryLifecycleTests: XCTestCase {
    private let day1 = Date(timeIntervalSince1970: 1_700_000_000)
    private let day2 = Date(timeIntervalSince1970: 1_700_086_400)

    private func candidate(
        triggers: [String] = ["discuss about"],
        instruction: String = "generated wording"
    ) -> MemoryCandidate {
        MemoryCandidate(
            dedupKey: "grammar:en:discuss about", kind: .grammar, language: "en", modeScope: nil,
            triggers: triggers, instruction: instruction
        )
    }

    private func fold(_ weights: [Double], into start: WritingMemory? = nil) -> WritingMemory {
        var memory = start
        for weight in weights {
            memory = MemoryLifecycle.merging(candidate(), weight: weight, at: day1, into: memory)
        }
        return memory!
    }

    func testFirstObservationCreatesACandidate() {
        let memory = MemoryLifecycle.merging(candidate(), weight: 0.35, at: day1, into: nil)
        XCTAssertEqual(memory.state, .candidate)
        XCTAssertEqual(memory.evidenceScore, 0.35, accuracy: 1e-9)
        XCTAssertEqual(memory.occurrenceCount, 1)
        XCTAssertEqual(memory.createdAt, day1)
        XCTAssertEqual(memory.lastConfirmedAt, day1)
        XCTAssertEqual(memory.dedupKey, "grammar:en:discuss about")
        XCTAssertFalse(memory.userEdited)
    }

    func testThreeEditsOrSevenAcceptsPromote() {
        XCTAssertEqual(fold([0.35, 0.35]).state, .candidate)
        XCTAssertEqual(fold([0.35, 0.35, 0.35]).state, .active, "3 × 0.35 must not miss 1.0 by rounding")
        XCTAssertEqual(fold(Array(repeating: 0.15, count: 6)).state, .candidate)
        XCTAssertEqual(fold(Array(repeating: 0.15, count: 7)).state, .active)
        XCTAssertEqual(fold(Array(repeating: 0.05, count: 20)).state, .active)
    }

    func testObservationsAccumulateAndKeepIdentity() {
        let first = fold([0.35])
        let later = MemoryLifecycle.merging(candidate(), weight: 0.15, at: day2, into: first)
        XCTAssertEqual(later.id, first.id)
        XCTAssertEqual(later.createdAt, first.createdAt)
        XCTAssertEqual(later.lastConfirmedAt, day2)
        XCTAssertEqual(later.occurrenceCount, 2)
        XCTAssertEqual(later.evidenceScore, 0.5, accuracy: 1e-9)
    }

    func testPinnedAndDisabledKeepTheirStateWhileEvidenceStillAccumulates() {
        for state in [MemoryState.pinned, .disabled] {
            var memory = fold([0.35])
            memory.state = state
            let after = fold([0.35, 0.35, 0.35], into: memory)
            XCTAssertEqual(after.state, state)
            XCTAssertEqual(after.occurrenceCount, 4)
        }
    }

    func testFreshEvidenceWakesAnArchivedMemory() {
        var archived = fold([0.35])
        archived.state = .archived
        XCTAssertEqual(fold([0.35], into: archived).state, .candidate)
        XCTAssertEqual(fold([0.35, 0.35, 0.35], into: archived).state, .active, "enough of it, and it is in use again")
    }

    func testExistingWordingIsNeverOverwritten() {
        var memory = fold([0.35])
        memory.instruction = "the user's own words"
        memory.userEdited = true
        let after = MemoryLifecycle.merging(
            candidate(instruction: "new generated wording"), weight: 0.35, at: day2, into: memory
        )
        XCTAssertEqual(after.instruction, "the user's own words")
        XCTAssertTrue(after.userEdited)
    }

    func testATriggerSeenLaterIsAdoptedButNeverReplaced() {
        let habit = MemoryLifecycle.merging(candidate(triggers: []), weight: 0.35, at: day1, into: nil)
        XCTAssertTrue(habit.triggers.isEmpty)

        let adopted = MemoryLifecycle.merging(candidate(triggers: ["big"]), weight: 0.15, at: day2, into: habit)
        XCTAssertEqual(adopted.triggers, ["big"])

        let kept = MemoryLifecycle.merging(candidate(triggers: ["other"]), weight: 0.15, at: day2, into: adopted)
        XCTAssertEqual(kept.triggers, ["big"])
    }

    func testWeakeningTakesEvidenceAwayButNeverBelowZero() {
        let memory = fold([0.35, 0.35])
        XCTAssertEqual(MemoryLifecycle.weakened(memory, by: 0.3, at: day1).evidenceScore, 0.4, accuracy: 1e-9)
        XCTAssertEqual(MemoryLifecycle.weakened(memory, by: 5, at: day1).evidenceScore, 0)
    }

    func testAnActiveMemoryFallsBackToCandidateOnlyWellBelowTheBar() {
        let active = fold([0.35, 0.35, 0.35])
        XCTAssertEqual(active.state, .active)
        XCTAssertEqual(MemoryLifecycle.weakened(active, by: 0.3, at: day1).state, .active, "0.75 is below the bar to become active, not to stay")
        XCTAssertEqual(MemoryLifecycle.weakened(active, by: 0.7, at: day1).state, .candidate)
    }

    func testAWeakenedMemoryNeedsFreshEvidenceToBecomeActiveAgain() {
        let weakened = MemoryLifecycle.weakened(fold([0.35, 0.35, 0.35]), by: 0.7, at: day1)
        XCTAssertEqual(weakened.state, .candidate)
        let again = fold([0.35], into: weakened)
        XCTAssertEqual(again.state, .candidate, "0.7 is not enough")
        XCTAssertEqual(fold([0.35, 0.35], into: weakened).state, .active)
    }

    func testPinnedDisabledAndArchivedKeepTheirStateWhenWeakened() {
        for state in [MemoryState.pinned, .disabled, .archived] {
            var memory = fold([0.35, 0.35, 0.35])
            memory.state = state
            XCTAssertEqual(MemoryLifecycle.weakened(memory, by: 5, at: day1).state, state)
        }
        XCTAssertEqual(MemoryLifecycle.weakened(fold([0.35]), by: 5, at: day1).state, .candidate)
    }

    func testWeakeningIsNoConfirmation() {
        var memory = fold([0.35, 0.35])
        memory.instruction = "the user's words"
        memory.userEdited = true
        let weakened = MemoryLifecycle.weakened(memory, by: 0.3, at: day1)
        XCTAssertEqual(weakened.id, memory.id)
        XCTAssertEqual(weakened.occurrenceCount, memory.occurrenceCount)
        XCTAssertEqual(weakened.lastConfirmedAt, memory.lastConfirmedAt)
        XCTAssertEqual(weakened.instruction, memory.instruction)
        XCTAssertEqual(weakened.triggers, memory.triggers)
        XCTAssertTrue(weakened.userEdited)
    }

    func testAContradictionWeighsTwiceWhatTheSameObservationWouldHaveAdded() {
        for action in FeedbackAction.allCases {
            XCTAssertEqual(
                LearningPolicy.contradictionWeight(for: action), 2 * LearningPolicy.evidenceWeight(for: action),
                accuracy: 1e-9
            )
        }
        XCTAssertLessThan(LearningPolicy.demoteThreshold, LearningPolicy.activeThreshold)
    }

    // MARK: fading

    private let grace = LearningPolicy.evidenceGraceDays
    private let halfLife = LearningPolicy.evidenceHalfLifeDays

    /// `days` after the memories were last confirmed.
    private func later(_ days: Double) -> Date {
        day1.addingTimeInterval(days * 86_400)
    }

    func testEvidenceHoldsForAWhileThenHalvesEveryNinetyDays() {
        let memory = fold([1.0])
        XCTAssertEqual(memory.evidence(at: day1), 1.0, accuracy: 1e-9)
        XCTAssertEqual(memory.evidence(at: later(grace)), 1.0, accuracy: 1e-9, "a month without the pattern is fine")
        XCTAssertEqual(memory.evidence(at: later(grace + halfLife)), 0.5, accuracy: 1e-9)
        XCTAssertEqual(memory.evidence(at: later(grace + 2 * halfLife)), 0.25, accuracy: 1e-9)
        XCTAssertEqual(memory.evidence(at: later(-1)), 1.0, accuracy: 1e-9, "a clock set back adds nothing")
    }

    func testOnlyPinnedAndDisabledMemoriesDoNotFade() {
        for state in [MemoryState.pinned, .disabled] {
            var memory = fold([1.0])
            memory.state = state
            XCTAssertEqual(memory.evidence(at: later(1_000)), 1.0, accuracy: 1e-9, "\(state)")
        }
        for state in [MemoryState.candidate, .active, .archived] {
            var memory = fold([1.0])
            memory.state = state
            XCTAssertLessThan(memory.evidence(at: later(1_000)), 0.001, "\(state)")
        }
    }

    func testConfidenceFollowsTheFadedEvidence() {
        let memory = fold([1.0])
        XCTAssertEqual(memory.confidence(at: day1), 0.5, accuracy: 1e-9)
        XCTAssertEqual(memory.confidence(at: later(grace + halfLife)), 0.5 / 1.5, accuracy: 1e-9)
    }

    func testMergingAddsToWhatIsLeftAndRestartsTheClock() {
        let old = fold([1.0])
        let at = later(grace + halfLife)
        let merged = MemoryLifecycle.merging(candidate(), weight: 0.35, at: at, into: old)
        XCTAssertEqual(merged.evidenceScore, 0.5 + 0.35, accuracy: 1e-9)
        XCTAssertEqual(merged.lastConfirmedAt, at)
        XCTAssertEqual(merged.evidence(at: at.addingTimeInterval(10 * 86_400)), 0.85, accuracy: 1e-9)
    }

    func testWeakeningWorksOnWhatIsLeftAndKeepsTheClock() {
        let old = fold([0.35, 0.35, 0.35])
        let at = later(grace + halfLife)
        let left = old.evidence(at: at)
        let weakened = MemoryLifecycle.weakened(old, by: 0.2, at: at)
        XCTAssertEqual(weakened.evidence(at: at), left - 0.2, accuracy: 1e-9)
        XCTAssertEqual(weakened.lastConfirmedAt, old.lastConfirmedAt)
        // From the same last confirmation it goes on fading: a half-life later, half of what is left.
        XCTAssertEqual(weakened.evidence(at: later(grace + 2 * halfLife)), (left - 0.2) / 2, accuracy: 1e-9)
    }

    func testWeakeningAMemoryFadedToNothingDoesNotBreak() {
        let ancient = MemoryLifecycle.weakened(fold([1.0]), by: 0.5, at: later(3_650_000))
        XCTAssertEqual(ancient.evidenceScore, 0)
        XCTAssertFalse(ancient.evidenceScore.isNaN)
    }

    func testSettlingArchivesAFadedCandidateAndDemotesAFadedActiveMemory() {
        let candidate = fold([0.35])
        XCTAssertEqual(MemoryLifecycle.settled(candidate, at: later(grace + 150)).state, .candidate)
        XCTAssertEqual(MemoryLifecycle.settled(candidate, at: later(grace + 170)).state, .archived)

        let active = fold([0.35, 0.35, 0.35])
        XCTAssertEqual(MemoryLifecycle.settled(active, at: later(grace + 90)).state, .active)
        XCTAssertEqual(MemoryLifecycle.settled(active, at: later(grace + 100)).state, .candidate)
        XCTAssertEqual(MemoryLifecycle.settled(active, at: later(grace + 320)).state, .archived)
    }

    func testSettlingNeverMovesAMemoryTheUserHoldsOrOneAlreadyArchived() {
        for state in [MemoryState.pinned, .disabled, .archived] {
            var memory = fold([0.35])
            memory.state = state
            XCTAssertEqual(MemoryLifecycle.settled(memory, at: later(5_000)), memory, "\(state)")
        }
    }

    func testRefreshingRestartsTheClockWithoutAddingEvidence() {
        let active = fold([0.35, 0.35, 0.35])
        let at = later(grace + halfLife)
        let refreshed = MemoryLifecycle.refreshed(active, at: at)
        XCTAssertEqual(refreshed.evidenceScore, active.evidence(at: at), accuracy: 1e-9, "no more than what was left")
        XCTAssertEqual(refreshed.lastConfirmedAt, at)
        XCTAssertEqual(refreshed.occurrenceCount, active.occurrenceCount)
        let aMonthLater = at.addingTimeInterval(grace * 86_400)
        XCTAssertEqual(refreshed.evidence(at: aMonthLater), refreshed.evidenceScore, accuracy: 1e-9)
    }

    func testRefreshingLeavesHeldAndDormantMemoriesAlone() {
        for state in [MemoryState.pinned, .disabled, .archived] {
            var memory = fold([0.35])
            memory.state = state
            XCTAssertEqual(MemoryLifecycle.refreshed(memory, at: later(200)), memory, "\(state)")
        }
    }

    func testHoldingFreezesWhatHasFadedSoFar() {
        let active = fold([0.35, 0.35, 0.35])
        let at = later(grace + halfLife)
        for state in [MemoryState.pinned, .disabled] {
            let held = MemoryLifecycle.held(active, as: state, at: at)
            XCTAssertEqual(held.state, state)
            XCTAssertEqual(held.evidenceScore, active.evidence(at: at), accuracy: 1e-9)
            XCTAssertEqual(held.evidence(at: later(5_000)), held.evidenceScore, accuracy: 1e-9)
        }
    }

    func testResumingRestartsTheClockAndRestoresAnArchivedMemory() {
        let at = later(grace + halfLife)
        let held = MemoryLifecycle.held(fold([0.35, 0.35, 0.35]), as: .pinned, at: at)
        let resumed = MemoryLifecycle.resumed(held, at: later(1_000))
        XCTAssertEqual(resumed.lastConfirmedAt, later(1_000), "the time it was held does not count against it")
        XCTAssertEqual(resumed.evidenceScore, held.evidenceScore, accuracy: 1e-9)
        XCTAssertEqual(resumed.state, .candidate, "0.525 is under the bar to be active")

        var archived = fold([0.35])
        archived.state = .archived
        let restored = MemoryLifecycle.resumed(archived, at: later(1_000))
        XCTAssertEqual(restored.state, .active)
        XCTAssertGreaterThanOrEqual(restored.evidenceScore, LearningPolicy.activeThreshold - 1e-9)
        XCTAssertEqual(restored.lastConfirmedAt, later(1_000))
    }

    func testConfidenceRisesWithEvidenceWithoutReachingOne() {
        let none = fold([0.0])
        let some = fold([1.0])
        let lots = fold(Array(repeating: 1.0, count: 20))
        XCTAssertEqual(none.confidence(at: day1), 0, accuracy: 1e-9)
        XCTAssertEqual(some.confidence(at: day1), 0.5, accuracy: 1e-9)
        XCTAssertGreaterThan(lots.confidence(at: day1), some.confidence(at: day1))
        XCTAssertLessThan(lots.confidence(at: day1), 1)
    }

    func testRestingState() {
        XCTAssertEqual(MemoryLifecycle.restingState(evidenceScore: 0.99), .candidate)
        XCTAssertEqual(MemoryLifecycle.restingState(evidenceScore: 1.0), .active)
        XCTAssertEqual(MemoryLifecycle.restingState(evidenceScore: 5), .active)
    }

    func testEvidenceWeights() {
        XCTAssertGreaterThan(
            LearningPolicy.evidenceWeight(for: .editedAndAccepted), LearningPolicy.evidenceWeight(for: .accepted)
        )
        XCTAssertGreaterThan(
            LearningPolicy.evidenceWeight(for: .accepted), LearningPolicy.evidenceWeight(for: .copied)
        )
        XCTAssertEqual(LearningPolicy.evidenceWeight(for: .regenerated), 0)
    }

    // MARK: organizing memories

    private func proposal() -> ConsolidationProposal {
        ConsolidationProposal(
            parentDedupKey: "dream:redundant-preposition:grammar:en", sourceIDs: [],
            kind: .grammar, language: "en", modeScope: nil, targetLevel: .generalized,
            instruction: MemoryConsolidator.redundantPrepositionInstruction, triggers: [],
            origin: .rule(.redundantPreposition)
        )
    }

    private func application(
        sources: [WritingMemory], existing: WritingMemory? = nil, linked: [WritingMemory] = []
    ) -> ConsolidationApplication {
        ConsolidationApplication(
            existingParent: existing, sources: sources, linkedSourceIDs: Set(linked.map(\.id))
        )
    }

    func testAConsolidatedMemorySumsTheEvidenceAsOfTheNewestSource() throws {
        let now = DreamFixtures.now
        // Two weeks apart, and 60 days after the older one the clock has not started to run down yet
        // (30 days of grace), but at 75 days it has.
        let newest = DreamFixtures.preposition("mention", evidence: 1.2, count: 3, confirmedDaysAgo: 1)
        let older = DreamFixtures.preposition("reply", evidence: 1.0, count: 2, confirmedDaysAgo: 90)
        let expectedOlder = older.evidence(at: newest.lastConfirmedAt)
        XCTAssertLessThan(expectedOlder, 1.0)

        let parent = try XCTUnwrap(MemoryLifecycle.consolidated(
            proposal(), from: application(sources: [newest, older]), at: now
        ))

        XCTAssertEqual(parent.evidenceScore, 1.2 + expectedOlder, accuracy: 1e-9)
        XCTAssertEqual(parent.lastConfirmedAt, newest.lastConfirmedAt)
        XCTAssertEqual(parent.occurrenceCount, 5)
        XCTAssertEqual(parent.createdAt, now)
        XCTAssertEqual(parent.lastConsolidatedAt, now)
        XCTAssertEqual(parent.level, .generalized)
        XCTAssertEqual(parent.dedupKey, "dream:redundant-preposition:grammar:en")
        XCTAssertEqual(parent.instruction, MemoryConsolidator.redundantPrepositionInstruction)
        XCTAssertEqual(parent.state, .active)
        XCTAssertFalse(parent.userEdited)
        XCTAssertEqual([parent.retrievalCount, parent.successfulUseCount], [0, 0])
    }

    func testAConsolidatedMemoryStartsAsACandidateIfTheSourcesAreWeakTogether() throws {
        let weak = (0..<2).map { DreamFixtures.preposition("v\($0)", evidence: 0.3) }
        let parent = try XCTUnwrap(MemoryLifecycle.consolidated(
            proposal(), from: application(sources: weak), at: DreamFixtures.now
        ))
        XCTAssertEqual(parent.state, .candidate)
        XCTAssertEqual(parent.evidenceScore, 0.6, accuracy: 1e-9)
    }

    func testTheContradictionsAgainstTheSourcesCarryOver() throws {
        var contradicted = DreamFixtures.preposition("reply")
        contradicted.contradictionCount = 2
        let parent = try XCTUnwrap(MemoryLifecycle.consolidated(
            proposal(), from: application(sources: [contradicted, DreamFixtures.preposition("mention")]),
            at: DreamFixtures.now
        ))
        XCTAssertEqual(parent.contradictionCount, 2)
    }

    func testAnExistingMemoryOnlyCountsTheSourcesItHasNotCounted() throws {
        let now = DreamFixtures.now
        let old = DreamFixtures.prepositions(3)
        let first = try XCTUnwrap(MemoryLifecycle.consolidated(proposal(), from: application(sources: old), at: now))

        let late = DreamFixtures.preposition("describe", evidence: 2, count: 5, confirmedDaysAgo: 0)
        let joined = try XCTUnwrap(MemoryLifecycle.consolidated(
            proposal(), from: application(sources: old + [late], existing: first, linked: old), at: now
        ))

        XCTAssertEqual(joined.id, first.id)
        XCTAssertEqual(joined.createdAt, first.createdAt)
        XCTAssertEqual(joined.evidenceScore, first.evidenceScore + 2, accuracy: 1e-9)
        XCTAssertEqual(joined.occurrenceCount, first.occurrenceCount + 5)
        XCTAssertEqual(joined.lastConfirmedAt, late.lastConfirmedAt)

        XCTAssertNil(MemoryLifecycle.consolidated(
            proposal(), from: application(sources: old, existing: first, linked: old), at: now
        ), "nothing new, nothing to write")
    }

    func testAnExistingMemoryKeepsItsWordingAndTheStateTheUserGaveIt() throws {
        let now = DreamFixtures.now
        let sources = DreamFixtures.prepositions(3)
        var existing = try XCTUnwrap(MemoryLifecycle.consolidated(proposal(), from: application(sources: sources), at: now))
        existing.instruction = "my own wording"
        existing.userEdited = true
        existing.state = .pinned
        let late = DreamFixtures.preposition("describe")

        let pinned = try XCTUnwrap(MemoryLifecycle.consolidated(
            proposal(), from: application(sources: sources + [late], existing: existing, linked: sources), at: now
        ))
        XCTAssertEqual(pinned.instruction, "my own wording")
        XCTAssertTrue(pinned.userEdited)
        XCTAssertEqual(pinned.state, .pinned)

        existing.state = .disabled
        XCTAssertNil(MemoryLifecycle.consolidated(
            proposal(), from: application(sources: sources + [late], existing: existing, linked: sources), at: now
        ), "a disabled memory stays off")
    }

    func testAMemoryThatWasPutAwayComesBackWhenItGainsSources() throws {
        let now = DreamFixtures.now
        let sources = DreamFixtures.prepositions(3)
        var existing = try XCTUnwrap(MemoryLifecycle.consolidated(proposal(), from: application(sources: sources), at: now))
        existing.state = .archived
        existing.evidenceScore = 0.05

        let woken = try XCTUnwrap(MemoryLifecycle.consolidated(
            proposal(),
            from: application(sources: [DreamFixtures.preposition("describe")], existing: existing),
            at: now
        ))
        XCTAssertEqual(woken.state, .active)
        XCTAssertEqual(woken.evidenceScore, 0.05 + 1.2, accuracy: 1e-9)
    }

    func testPromotionKeepsTheEvidenceAndRestartsTheClock() {
        let now = DreamFixtures.now
        var memory = DreamFixtures.preposition("mention", evidence: 4, confirmedDaysAgo: 120)
        memory.level = .generalized
        let worth = memory.evidence(at: now)
        XCTAssertLessThan(worth, 4, "sanity: it has faded")

        let core = MemoryLifecycle.promoted(memory, to: .core, at: now)

        XCTAssertEqual(core.level, .core)
        XCTAssertEqual(core.evidenceScore, worth, accuracy: 1e-12)
        XCTAssertEqual(core.evidence(at: now), worth, accuracy: 1e-12, "worth the same as a moment ago")
        XCTAssertEqual(core.lastConfirmedAt, now)
        XCTAssertEqual(core.lastConsolidatedAt, now)
        XCTAssertEqual(core.state, memory.state)
        XCTAssertEqual(core.id, memory.id)
    }

    // MARK: levels fade at their own pace

    private func aged(_ level: MemoryLevel, state: MemoryState = .active, evidence: Double = 1, days: Double) -> WritingMemory {
        var memory = DreamFixtures.preposition("mention", evidence: evidence, state: state, confirmedDaysAgo: days)
        memory.level = level
        return memory
    }

    func testEveryLevelHoldsOnForThirtyDaysThenHalvesOnceEveryHalfLife() {
        let now = DreamFixtures.now
        let halfLives: [(MemoryLevel, Double)] = [(.specific, 90), (.generalized, 180), (.core, 365)]
        for (level, halfLife) in halfLives {
            XCTAssertEqual(LearningPolicy.halfLifeDays(for: level), halfLife)
            XCTAssertEqual(aged(level, days: 0).evidence(at: now), 1, accuracy: 1e-12, "\(level)")
            XCTAssertEqual(aged(level, days: 30).evidence(at: now), 1, accuracy: 1e-12, "\(level): grace")
            XCTAssertLessThan(aged(level, days: 31).evidence(at: now), 1, "\(level): it starts to fade after the grace")
            XCTAssertEqual(aged(level, days: 30 + halfLife).evidence(at: now), 0.5, accuracy: 1e-9, "\(level)")
            XCTAssertEqual(aged(level, days: 30 + 2 * halfLife).evidence(at: now), 0.25, accuracy: 1e-9, "\(level)")
        }
    }

    func testTheSameAgeFadesLessTheMoreGeneralTheMemory() {
        let now = DreamFixtures.now
        let specific = aged(.specific, days: 200).evidence(at: now)
        let generalized = aged(.generalized, days: 200).evidence(at: now)
        let core = aged(.core, days: 200).evidence(at: now)
        XCTAssertLessThan(specific, generalized)
        XCTAssertLessThan(generalized, core)
    }

    func testPinnedAndDisabledMemoriesOfAnyLevelDoNotFade() {
        let now = DreamFixtures.now
        for level in MemoryLevel.allCases {
            for state in [MemoryState.pinned, .disabled] {
                XCTAssertEqual(aged(level, state: state, days: 5_000).evidence(at: now), 1, "\(level) \(state)")
            }
        }
    }

    func testALongerHalfLifeKeepsAGeneralizedMemoryInUseWhereASpecificOneFadesToACandidate() {
        let now = DreamFixtures.now
        // 200 days: a specific memory is down to a third, a generalized one still above the bar.
        XCTAssertEqual(MemoryLifecycle.settled(aged(.specific, evidence: 1.2, days: 200), at: now).state, .candidate)
        XCTAssertEqual(MemoryLifecycle.settled(aged(.generalized, evidence: 1.2, days: 200), at: now).state, .active)
        XCTAssertEqual(MemoryLifecycle.settled(aged(.core, evidence: 1.2, days: 200), at: now).state, .active)
        // 300 days: the specific one has faded away altogether, the generalized one has not.
        XCTAssertEqual(MemoryLifecycle.settled(aged(.specific, evidence: 0.3, days: 300), at: now).state, .archived)
        XCTAssertEqual(MemoryLifecycle.settled(aged(.generalized, evidence: 0.3, days: 300), at: now).state, .candidate)
    }

    func testWeakeningKeepsTheAccountOfWhatWasLeftUnderTheLongerHalfLife() {
        let now = DreamFixtures.now
        let memory = aged(.generalized, evidence: 3, days: 210)      // one half-life of fading: 1.5 left
        let weakened = MemoryLifecycle.weakened(memory, by: 0.5, at: now)
        XCTAssertEqual(weakened.evidence(at: now), 1.0, accuracy: 1e-9)
        XCTAssertEqual(weakened.lastConfirmedAt, memory.lastConfirmedAt, "no confirmation, so the clock keeps running")
    }

    // MARK: contradictions and support

    func testEveryWeakeningCountsAsAContradiction() {
        let now = DreamFixtures.now
        var memory = DreamFixtures.preposition("mention")
        XCTAssertEqual(memory.contradictionCount, 0)
        memory = MemoryLifecycle.weakened(memory, by: 0.1, at: now)
        memory = MemoryLifecycle.weakened(memory, by: 5, at: now)    // and one that takes everything
        XCTAssertEqual(memory.contradictionCount, 2)
        XCTAssertEqual(memory.evidenceScore, 0, accuracy: 1e-12)
        XCTAssertEqual(memory.state, .candidate)

        var pinned = DreamFixtures.preposition("reply", state: .pinned)
        pinned = MemoryLifecycle.weakened(pinned, by: 0.1, at: now)
        XCTAssertEqual(pinned.contradictionCount, 1)
        XCTAssertEqual(pinned.state, .pinned)
    }

    func testSupportCountsAsAnotherObservationOfTheRule() {
        let now = DreamFixtures.now
        var rule = DreamFixtures.preposition("mention", evidence: 3.6, count: 9, confirmedDaysAgo: 5)
        rule.level = .generalized
        let supported = MemoryLifecycle.supported(rule, weight: 0.35, at: now)

        XCTAssertEqual(supported.evidenceScore, 3.95, accuracy: 1e-9)
        XCTAssertEqual(supported.occurrenceCount, 10)
        XCTAssertEqual(supported.lastConfirmedAt, now)
        XCTAssertEqual(supported.instruction, rule.instruction)
        XCTAssertEqual(supported.contradictionCount, rule.contradictionCount)
        XCTAssertEqual(supported.level, .generalized)
        XCTAssertEqual(supported.state, .active)
    }

    func testSupportWakesAMemoryThatHadFadedAndKeepsWhatTheUserGave() {
        let now = DreamFixtures.now
        var archived = DreamFixtures.preposition("mention", evidence: 0.05, state: .archived)
        archived.level = .generalized
        XCTAssertEqual(MemoryLifecycle.supported(archived, weight: 0.35, at: now).state, .candidate)

        var pinned = DreamFixtures.preposition("mention", evidence: 0.05, state: .pinned)
        pinned.level = .generalized
        pinned.userEdited = true
        pinned.instruction = "my own wording"
        let supported = MemoryLifecycle.supported(pinned, weight: 0.35, at: now)
        XCTAssertEqual(supported.state, .pinned)
        XCTAssertEqual(supported.instruction, "my own wording")
        XCTAssertTrue(supported.userEdited)
    }
}
