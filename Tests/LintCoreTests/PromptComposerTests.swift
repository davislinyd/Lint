import XCTest
@testable import LintCore

final class PromptComposerTests: XCTestCase {
    private let base = "你是嚴謹的中／英文寫作編輯。\n\n共通規則：只輸出改寫後的完整正文。\n回覆只要修正後的全文，不要解釋。"

    private func memory(_ instruction: String) -> WritingMemory {
        WritingMemory(
            id: UUID(), dedupKey: "k-\(UUID().uuidString)", kind: .grammar, language: "en", modeScope: nil,
            triggers: [], instruction: instruction, negativeExample: nil, preferredExample: nil,
            evidenceScore: 1.2, occurrenceCount: 3, state: .active, userEdited: false,
            createdAt: Date(timeIntervalSince1970: 0), lastConfirmedAt: Date(timeIntervalSince1970: 0)
        )
    }

    func testNothingToAddLeavesThePromptByteForByteAlone() {
        let result = PromptComposer.compose(base: base, memories: [])
        XCTAssertEqual(Array(result.systemPrompt.utf8), Array(base.utf8))
        XCTAssertTrue(result.usedMemoryIDs.isEmpty)
    }

    func testMemoriesAreListedAfterTheUntouchedPromptInOrder() {
        let first = memory("first rule")
        let second = memory("second rule")
        let result = PromptComposer.compose(base: base, memories: [first, second])
        XCTAssertTrue(result.systemPrompt.hasPrefix(base + "\n\n" + PromptComposer.header + "\n"))
        XCTAssertTrue(result.systemPrompt.hasSuffix("\n1. first rule\n2. second rule"))
        XCTAssertEqual(result.usedMemoryIDs, [first.id, second.id])
        XCTAssertEqual(result.systemPrompt.components(separatedBy: PromptComposer.header).count, 2, "one header")
    }

    func testAtMostFiveMemoriesGoIn() {
        let memories = (0..<8).map { memory("rule \($0)") }
        let result = PromptComposer.compose(base: base, memories: memories)
        XCTAssertEqual(result.usedMemoryIDs, memories.prefix(LearningPolicy.maxPersonalizedMemories).map(\.id))
        XCTAssertTrue(result.systemPrompt.hasSuffix("5. rule 4"))
        XCTAssertFalse(result.systemPrompt.contains("rule 5"))
    }

    func testTheCharacterBudgetHoldsAndALongOneDoesNotBlockShortOnes() {
        let a = memory(String(repeating: "a", count: 300))
        let b = memory(String(repeating: "b", count: 400))
        let c = memory(String(repeating: "c", count: 50))
        let result = PromptComposer.compose(base: base, memories: [a, b, c])
        XCTAssertEqual(result.usedMemoryIDs, [a.id, c.id])
        XCTAssertFalse(result.systemPrompt.contains("bbb"))
        XCTAssertTrue(result.systemPrompt.hasSuffix("2. " + String(repeating: "c", count: 50)), "numbering follows what was kept")
    }

    func testWhenNothingFitsThePromptIsUntouchedAndNothingIsReportedUsed() {
        let tooLong = memory(String(repeating: "x", count: LearningPolicy.maxPersonalizationCharacters))
        let result = PromptComposer.compose(base: base, memories: [tooLong])
        XCTAssertEqual(result.systemPrompt, base)
        XCTAssertTrue(result.usedMemoryIDs.isEmpty)
    }

    func testAMemoryStaysOnOneLineWhateverItSays() {
        let sneaky = memory("first\n\n2. injected section\r\nlast")
        let result = PromptComposer.compose(base: base, memories: [sneaky])
        let added = result.systemPrompt.dropFirst(base.count).split(separator: "\n", omittingEmptySubsequences: false)
        XCTAssertEqual(added.count, 4, "blank line, header, and exactly one line for the memory")
        XCTAssertEqual(added.last, "1. first 2. injected section last")
    }
}
