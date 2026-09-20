import XCTest
@testable import LintCore

final class MemoryLifecycleTests: XCTestCase {
    private let day1 = Date(timeIntervalSince1970: 1_700_000_000)
    private let day2 = Date(timeIntervalSince1970: 1_700_086_400)

    private func candidate(
        triggers: [String] = ["discuss about"],
        instruction: String = "generated wording",
        negative: String? = nil,
        preferred: String? = nil
    ) -> MemoryCandidate {
        MemoryCandidate(
            dedupKey: "grammar:en:discuss about", kind: .grammar, language: "en", modeScope: nil,
            triggers: triggers, instruction: instruction,
            negativeExample: negative, preferredExample: preferred
        )
    }

    private func fold(_ weights: [Double], into start: WritingMemory? = nil) -> WritingMemory {
        var memory = start
        for (offset, weight) in weights.enumerated() {
            memory = MemoryLifecycle.merging(
                candidate(), weight: weight, at: day1.addingTimeInterval(Double(offset)), into: memory
            )
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

    func testPinnedDisabledAndArchivedKeepTheirState() {
        for state in [MemoryState.pinned, .disabled, .archived] {
            var memory = fold([0.35])
            memory.state = state
            let after = fold([0.35, 0.35, 0.35], into: memory)
            XCTAssertEqual(after.state, state)
            XCTAssertEqual(after.occurrenceCount, 4, "evidence still accumulates")
        }
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

    func testExamplesAreFilledOnlyWhenMissing() {
        let first = MemoryLifecycle.merging(candidate(negative: "a", preferred: "b"), weight: 0.35, at: day1, into: nil)
        let second = MemoryLifecycle.merging(candidate(negative: "c", preferred: "d"), weight: 0.35, at: day2, into: first)
        XCTAssertEqual(second.negativeExample, "a")
        XCTAssertEqual(second.preferredExample, "b")

        let bare = MemoryLifecycle.merging(candidate(), weight: 0.35, at: day1, into: nil)
        let filled = MemoryLifecycle.merging(candidate(negative: "c", preferred: "d"), weight: 0.35, at: day2, into: bare)
        XCTAssertEqual(filled.negativeExample, "c")
    }

    func testConfidenceRisesWithEvidenceWithoutReachingOne() {
        let none = fold([0.0])
        let some = fold([1.0])
        let lots = fold(Array(repeating: 1.0, count: 20))
        XCTAssertEqual(none.confidence, 0, accuracy: 1e-9)
        XCTAssertEqual(some.confidence, 0.5, accuracy: 1e-9)
        XCTAssertGreaterThan(lots.confidence, some.confidence)
        XCTAssertLessThan(lots.confidence, 1)
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
}
