import XCTest
@testable import LintCore

final class MemoryImportanceScorerTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func memory(
        evidence: Double = 1,
        count: Int = 1,
        state: MemoryState = .active,
        userEdited: Bool = false,
        confirmedDaysAgo: Double = 0,
        retrievals: Int = 0,
        successes: Int = 0,
        contradictions: Int = 0,
        usedDaysAgo: Double? = nil,
        key: String = "grammar:en:discuss about",
        instruction: String = "rule"
    ) -> WritingMemory {
        WritingMemory(
            id: UUID(), dedupKey: key, kind: .grammar, language: "en", modeScope: nil, triggers: [],
            instruction: instruction, evidenceScore: evidence, occurrenceCount: count, state: state,
            userEdited: userEdited, createdAt: now.addingTimeInterval(-400 * 86_400),
            lastConfirmedAt: now.addingTimeInterval(-confirmedDaysAgo * 86_400),
            retrievalCount: retrievals, successfulUseCount: successes, contradictionCount: contradictions,
            lastUsedAt: usedDaysAgo.map { now.addingTimeInterval(-$0 * 86_400) }
        )
    }

    private func score(_ memory: WritingMemory) -> Double {
        MemoryImportanceScorer.score(memory, at: now)
    }

    func testAFreshMemoryScoresFromItsSignals() {
        // confidence 0.5, recurrence 0.1, no history 0.5, recency 1, no explicit signal, no contradictions
        let expected = 0.30 * 0.5 + 0.20 * 0.1 + 0.20 * 0.5 + 0.15 * 1
        XCTAssertEqual(score(memory()), expected, accuracy: 1e-9)
    }

    func testNoRetrievalHistoryIsNeutralAndFinite() {
        let value = score(memory(retrievals: 0, successes: 0))
        XCTAssertTrue(value.isFinite)
        // A success count with nothing retrieved cannot be real and counts as none.
        XCTAssertEqual(score(memory(retrievals: 0, successes: 5)), value, accuracy: 1e-12)
    }

    func testUsefulnessRisesWithSuccessesAndFallsWithWastedRetrievals() {
        let untried = score(memory())
        let proven = score(memory(retrievals: 10, successes: 10))
        let ignored = score(memory(retrievals: 10, successes: 0))
        XCTAssertGreaterThan(proven, untried)
        XCTAssertGreaterThan(untried, ignored)
        // 11/12 against 1/12 of the 0.20 weight
        XCTAssertEqual(proven - ignored, 0.20 * (11.0 / 12 - 1.0 / 12), accuracy: 1e-9)
    }

    func testRecurrenceStopsCountingAtTheCap() {
        XCTAssertLessThan(score(memory(count: 5)), score(memory(count: 10)))
        XCTAssertEqual(score(memory(count: 10)), score(memory(count: 50)), accuracy: 1e-12)
        XCTAssertEqual(score(memory(count: 10)) - score(memory(count: 0)), 0.20, accuracy: 1e-9)
    }

    func testRecencyHalvesEveryThirtyDays() {
        // Pinned, so that the confidence does not fade along with it.
        let fresh = score(memory(state: .pinned))
        XCTAssertEqual(score(memory(state: .pinned, confirmedDaysAgo: 30)), fresh - 0.15 * 0.5, accuracy: 1e-9)
        XCTAssertEqual(score(memory(state: .pinned, confirmedDaysAgo: 60)), fresh - 0.15 * 0.75, accuracy: 1e-9)
    }

    func testUseKeepsAMemoryRecentEvenWhenItWasNotConfirmed() {
        let neglected = score(memory(state: .pinned, confirmedDaysAgo: 90))
        let used = score(memory(state: .pinned, confirmedDaysAgo: 90, usedDaysAgo: 0))
        XCTAssertEqual(used - neglected, 0.15 * (1 - 0.125), accuracy: 1e-9)
    }

    func testFadedEvidenceLowersTheScore() {
        // 120 days: 30 days of grace, then one 90-day half-life.
        let faded = memory(confirmedDaysAgo: 120)
        XCTAssertLessThan(score(faded), score(memory()))
        let confidence = 0.5 / 1.5
        let recency = pow(0.5, 120.0 / 30)
        XCTAssertEqual(
            score(faded), 0.30 * confidence + 0.20 * 0.1 + 0.20 * 0.5 + 0.15 * recency, accuracy: 1e-9
        )
    }

    func testPinningOrRewritingIsAnExplicitSignal() {
        let plain = score(memory())
        XCTAssertEqual(score(memory(state: .pinned)) - plain, 0.15, accuracy: 1e-9)
        XCTAssertEqual(score(memory(userEdited: true)) - plain, 0.15, accuracy: 1e-9)
    }

    func testContradictionsTakeAwayInProportionToWhatWasObserved() {
        let plain = score(memory(count: 3))
        XCTAssertEqual(plain - score(memory(count: 3, contradictions: 1)), 0.30 * 0.25, accuracy: 1e-9)
        XCTAssertEqual(plain - score(memory(count: 3, contradictions: 3)), 0.30 * 0.5, accuracy: 1e-9)
    }

    func testTheScoreStaysWithinZeroAndOne() {
        let doomed = memory(evidence: 0, count: 1, contradictions: 1_000)
        XCTAssertEqual(score(doomed), 0)
        let best = memory(evidence: 1_000, count: 100, state: .pinned, retrievals: 1_000, successes: 1_000)
        XCTAssertLessThanOrEqual(score(best), 1)
        XCTAssertGreaterThan(score(best), 0.9)
    }

    func testTheScoreIgnoresTheMemorysIdentityAndText() {
        let a = memory(key: "grammar:en:discuss about", instruction: "one")
        let b = memory(key: "grammar:en:mention about", instruction: "something else entirely")
        XCTAssertEqual(score(a), score(b))
        XCTAssertEqual(score(a), score(a))
    }

    func testNegativeCountersCountAsNone() {
        let broken = memory(count: -5, retrievals: -3, successes: -1, contradictions: -2)
        XCTAssertEqual(score(broken), score(memory(count: 0)), accuracy: 1e-12)
    }
}
