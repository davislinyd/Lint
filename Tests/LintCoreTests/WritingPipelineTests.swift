import XCTest

@testable import LintCore

/// Splitting long text, one retry at most, and never showing a stale answer. A scripted fake stands
/// in for the model, so none of this needs Apple Intelligence.
final class WritingPipelineTests: XCTestCase {
    // MARK: - Chunking

    func testShortTextIsOnePiece() {
        XCTAssertEqual(WritingChunker.chunks("Hello there.", maxTokens: 100), ["Hello there."])
    }

    func testPiecesJoinBackToExactlyTheText() {
        let paragraph = "The rollout starts at 09:00. Please check https://status.example.com before you begin. "
        let text = "  Intro line.\n\n" + String(repeating: paragraph, count: 12) + "\n\n- item one\n- item two\n\n\n結尾段落。第二句。\n"
        for limit in [8, 20, 50, 120] {
            let pieces = WritingChunker.chunks(text, maxTokens: limit)
            XCTAssertEqual(pieces.joined(), text, "limit \(limit)")
            XCTAssertGreaterThan(pieces.count, 1, "limit \(limit)")
            for piece in pieces where piece.count > 1 {
                XCTAssertLessThanOrEqual(WritingChunker.estimatedTokens(piece), limit, "limit \(limit): \(piece.debugDescription)")
            }
        }
    }

    func testParagraphsAreKeptWholeWhenTheyFit() {
        let text = "First paragraph here.\n\nSecond paragraph here.\n\nThird paragraph here."
        let pieces = WritingChunker.chunks(text, maxTokens: 8)
        XCTAssertEqual(pieces, ["First paragraph here.\n\n", "Second paragraph here.\n\n", "Third paragraph here."])
    }

    func testAURLIsNotSplitAtItsDots() {
        let text = "See https://docs.example.com/a/b.html for details and more words to make it long enough to split"
        let pieces = WritingChunker.chunks(text, maxTokens: 12)
        XCTAssertEqual(pieces.joined(), text)
        XCTAssertTrue(pieces.contains { $0.contains("https://docs.example.com/a/b.html") })
    }

    func testTheEstimateIsConservativeForChinese() {
        XCTAssertEqual(WritingChunker.estimatedTokens("你好世界"), 4)
        XCTAssertEqual(WritingChunker.estimatedTokens("abcdef"), 2)
    }

    func testTheBudgetComesFromTheRealContextSize() {
        let small = WritingChunkBudget(contextSize: 4096, instructions: String(repeating: "word ", count: 150))
        let large = WritingChunkBudget(contextSize: 8192, instructions: String(repeating: "word ", count: 150))
        XCTAssertGreaterThan(large.maxInputTokens, small.maxInputTokens)
        XCTAssertLessThan(small.maxInputTokens, 4096 / 2, "room is left for the instructions and the answer")
        XCTAssertEqual(WritingChunkBudget(contextSize: 100, instructions: String(repeating: "x", count: 900)).maxInputTokens, 64)
    }

    // MARK: - Pipeline

    /// About 45 estimated tokens: one paragraph fits the smallest budget (64), two do not.
    private static func paragraph(_ first: String) -> String {
        first + " paragraph " + String(repeating: "lorem ipsum dolor ", count: 7) + "end."
    }

    private static let smallBudget = WritingChunkBudget(contextSize: 128, instructions: "")

    private final class FakeModel: @unchecked Sendable {
        var answer: (String, String) throws -> String
        var calls: [(prompt: String, text: String)] = []
        init(_ answer: @escaping (String, String) throws -> String) { self.answer = answer }
        func generate(_ prompt: String, _ text: String) throws -> String {
            calls.append((prompt, text))
            return try answer(prompt, text)
        }
    }

    func testEachPieceIsWrittenOnItsOwnAndTheLayoutSurvives() async throws {
        let text = ["first", "second", "third"].map(Self.paragraph).joined(separator: "\n\n")
        let model = FakeModel { _, piece in piece.prefix(1).uppercased() + piece.dropFirst() }
        let result = try await WritingPipeline.run(
            source: text, mode: .proofread, tone: .preserve, systemPrompt: "P", budget: Self.smallBudget
        ) { try model.generate($0, $1) }
        XCTAssertEqual(result.text, ["First", "Second", "Third"].map(Self.paragraph).joined(separator: "\n\n"))
        XCTAssertEqual(result.pieces, 3)
        XCTAssertEqual(result.requests, 3)
        XCTAssertEqual(result.outcome, .accepted)
        XCTAssertTrue(model.calls.allSatisfy { $0.prompt == "P\nThe text is in English: answer in English, do not translate it." })
    }

    func testAnExcessiveRewriteIsRetriedOnceThenTheSourceIsKept() async throws {
        let source = "Could you review my pull request when you have a moment? It only touches the login flow."
        let paraphrase = "When you get a chance, please take a look at my PR — the changes are limited to how users sign in."
        let model = FakeModel { _, _ in paraphrase }
        let result = try await WritingPipeline.run(
            source: source, mode: .proofread, tone: .preserve, systemPrompt: "P", budget: nil
        ) { try model.generate($0, $1) }
        XCTAssertEqual(result.text, source)
        guard case .keptSource = result.outcome else { return XCTFail("\(result.outcome)") }
        XCTAssertEqual(model.calls.count, 2, "one retry, never a loop")
        XCTAssertTrue(model.calls[1].prompt.contains("You changed far too much"), "the retry is the stricter minimal-edit prompt")
        XCTAssertEqual(result.firstAnswer, paraphrase)
    }

    func testARetryThatFixesItIsAccepted() async throws {
        let source = "Could you review my pull request when you have a moment? It only touches the login flow."
        var answers = ["When you get a chance, please take a look at my PR — the changes are limited to how users sign in.", source]
        let model = FakeModel { _, _ in answers.removeFirst() }
        let result = try await WritingPipeline.run(
            source: source, mode: .proofread, tone: .preserve, systemPrompt: "P", budget: nil
        ) { try model.generate($0, $1) }
        XCTAssertEqual(result.text, source)
        guard case .acceptedAfterRetry = result.outcome else { return XCTFail("\(result.outcome)") }
    }

    func testTheMinimalEditLimitDoesNotApplyToTranslationsTonesOrCustomPrompts() async throws {
        let source = "Could you review my pull request when you have a moment? It only touches the login flow."
        let rewrite = "When you get a chance, please take a look at my PR — the changes are limited to how users sign in."
        for (mode, tone) in [(WritingMode.proofread, WritingTone.formal), (.proofread, .concise), (.proofread, .professional), (.custom, .preserve)] {
            let model = FakeModel { _, _ in rewrite }
            let result = try await WritingPipeline.run(
                source: source, mode: mode, tone: tone, systemPrompt: "P", budget: nil
            ) { try model.generate($0, $1) }
            XCTAssertEqual(result.text, rewrite, "\(mode)/\(tone)")
            XCTAssertEqual(model.calls.count, 1, "\(mode)/\(tone): no retry")
        }
        let translation = FakeModel { _, _ in "可以在你有空的時候幫我看一下 PR 嗎？只動到登入流程。" }
        let translated = try await WritingPipeline.run(
            source: source, mode: .translate, tone: .preserve, systemPrompt: "P", budget: nil
        ) { try translation.generate($0, $1) }
        XCTAssertEqual(translated.outcome, .accepted)
        XCTAssertEqual(translation.calls.count, 1)
    }

    func testAPieceTheModelSaysIsTooLongIsSplitAgainAtMostTwice() async throws {
        let text = "one two three four five six seven eight nine ten eleven twelve thirteen fourteen fifteen sixteen"
        let limit = 8
        let model = FakeModel { _, piece in
            if WritingChunker.estimatedTokens(piece) > limit { throw AppleIntelligenceError.contextSizeExceeded }
            return piece
        }
        let result = try await WritingPipeline.run(
            source: text, mode: .proofread, tone: .concise, systemPrompt: "P", budget: nil
        ) { try model.generate($0, $1) }
        XCTAssertEqual(result.text, text)
        XCTAssertGreaterThan(result.pieces, 1)

        let hopeless = FakeModel { _, _ in throw AppleIntelligenceError.contextSizeExceeded }
        do {
            _ = try await WritingPipeline.run(
                source: text, mode: .proofread, tone: .concise, systemPrompt: "P", budget: nil
            ) { try hopeless.generate($0, $1) }
            XCTFail("expected contextSizeExceeded")
        } catch AppleIntelligenceError.contextSizeExceeded {
            // 1 + 2 + 4 requests: the whole text, its halves, their halves; then it gives up.
            XCTAssertLessThanOrEqual(hopeless.calls.count, 7)
        }
    }

    func testOnlyAProofreadIsToldWhichLanguageTheTextIsIn() async throws {
        for (mode, expected) in [(WritingMode.proofread, "P\nThe text is in Traditional Chinese: answer in Traditional Chinese, do not translate it."), (.translate, "P")] {
            let model = FakeModel { _, piece in piece }
            _ = try await WritingPipeline.run(
                source: "報告已經寄給客戶，對方確認收到了。", mode: mode, tone: .preserve, systemPrompt: "P", budget: nil
            ) { try model.generate($0, $1) }
            XCTAssertEqual(model.calls.first?.prompt, expected, "\(mode)")
        }
    }

    func testACustomPromptIsSentWholeAndUnchecked() async throws {
        let model = FakeModel { _, _ in "" }
        let result = try await WritingPipeline.run(
            source: String(repeating: "word ", count: 500), mode: .custom, tone: .preserve, systemPrompt: "P",
            budget: WritingChunkBudget(contextSize: 200, instructions: "P")
        ) { try model.generate($0, $1) }
        XCTAssertEqual(model.calls.count, 1)
        XCTAssertEqual(result.text, "")
    }

    func testCancellationStopsBeforeTheNextPiece() async throws {
        let text = ["first", "second", "third"].map(Self.paragraph).joined(separator: "\n\n")
        let model = FakeModel { _, piece in piece }
        let task = Task {
            try await WritingPipeline.run(
                source: text, mode: .proofread, tone: .preserve, systemPrompt: "P", budget: Self.smallBudget
            ) { prompt, piece in
                withUnsafeCurrentTask { $0?.cancel() }
                return try model.generate(prompt, piece)
            }
        }
        do {
            _ = try await task.value
            XCTFail("expected cancellation")
        } catch is CancellationError {
            XCTAssertEqual(model.calls.count, 1)
        }
    }

    // MARK: - Stale answers

    func testOnlyTheNewestRequestMayShowItsAnswer() {
        var tickets = WritingRequestTickets()
        let first = tickets.issue()
        XCTAssertTrue(tickets.isCurrent(first))
        let second = tickets.issue()
        XCTAssertFalse(tickets.isCurrent(first), "an older answer arriving late is dropped")
        XCTAssertTrue(tickets.isCurrent(second))
        tickets.invalidate()
        XCTAssertFalse(tickets.isCurrent(second), "a cancelled request shows nothing")
    }
}
