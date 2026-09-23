import Foundation

/// What one guarded writing request came to, over all the pieces of a long text.
public struct WritingPipelineResult: Equatable, Sendable {
    /// What the user is shown.
    public var text: String
    /// The most serious outcome of any piece: kept source, then flagged, then retried, then accepted.
    public var outcome: GuardedWritingResult.Outcome
    /// The model's first answers, before any retry or fallback, joined like `text`.
    public var firstAnswer: String
    /// Requests sent to the model: one per piece, plus retries.
    public var requests: Int
    public var pieces: Int
}

/// The on-device writing path: a text too long for the model's context is split
/// (`WritingChunker`), a proofread piece is told which language it is in, each piece gets
/// `GuardedWriter`'s check and single retry, and a piece the
/// model still says is too long is split once more, at most `maximumSplitDepth` times. A custom
/// prompt is the user's own task: it is sent whole and not checked.
public enum WritingPipeline {
    public static let maximumSplitDepth = 2

    /// - Parameter generate: sends one request (system prompt, text) and returns the full answer.
    public static func run(
        source: String,
        mode: WritingMode,
        tone: WritingTone,
        systemPrompt: String,
        budget: WritingChunkBudget?,
        isolation: isolated (any Actor)? = #isolation,
        generate: (_ systemPrompt: String, _ text: String) async throws -> String
    ) async throws -> WritingPipelineResult {
        guard WritingGuardPolicy.for(mode: mode, tone: tone) != nil else {
            let answer = try await generate(systemPrompt, source)
            return WritingPipelineResult(text: answer, outcome: .accepted, firstAnswer: answer, requests: 1, pieces: 1)
        }
        let pieces = budget.map { WritingChunker.chunks(source, maxTokens: $0.maxInputTokens) } ?? [source]
        var results: [WritingPipelineResult] = []
        for piece in pieces {
            try Task.checkCancellation()
            results.append(try await runPiece(piece, depth: 0, mode: mode, tone: tone, systemPrompt: systemPrompt, generate: generate))
        }
        return combine(results)
    }

    private static func runPiece(
        _ piece: String,
        depth: Int,
        mode: WritingMode,
        tone: WritingTone,
        systemPrompt: String,
        isolation: isolated (any Actor)? = #isolation,
        generate: (_ systemPrompt: String, _ text: String) async throws -> String
    ) async throws -> WritingPipelineResult {
        // Blank space between paragraphs: nothing to write.
        if piece.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return WritingPipelineResult(text: piece, outcome: .accepted, firstAnswer: piece, requests: 0, pieces: 0)
        }
        // A small model drifts into another language unless told which one this text is in.
        let prompt = mode == .proofread
            ? systemPrompt + "\n" + WritingOutputGuard.languageInstruction(for: piece) : systemPrompt
        do {
            var requests = 0
            let result = try await GuardedWriter.run(
                source: piece, mode: mode, tone: tone, systemPrompt: prompt
            ) { prompt, _ in
                requests += 1
                return try await generate(prompt, piece)
            }
            return WritingPipelineResult(
                text: result.text, outcome: result.outcome, firstAnswer: result.attempts.first ?? result.text,
                requests: requests, pieces: 1
            )
        } catch AppleIntelligenceError.contextSizeExceeded where depth < maximumSplitDepth {
            let halves = WritingChunker.chunks(piece, maxTokens: max(WritingChunker.estimatedTokens(piece) / 2, 1))
            guard halves.count > 1 else { throw AppleIntelligenceError.contextSizeExceeded }
            var results: [WritingPipelineResult] = []
            for half in halves {
                try Task.checkCancellation()
                results.append(try await runPiece(half, depth: depth + 1, mode: mode, tone: tone, systemPrompt: systemPrompt, generate: generate))
            }
            return combine(results)
        }
    }

    static func combine(_ results: [WritingPipelineResult]) -> WritingPipelineResult {
        guard results.count != 1 else { return results[0] }
        var kept: [WritingIssue] = []
        var flagged: [WritingIssue] = []
        var retried: [WritingIssue] = []
        for result in results {
            switch result.outcome {
            case .accepted: break
            case .acceptedAfterRetry(let issues): retried += issues
            case .flagged(let issues): flagged += issues
            case .keptSource(let issues): kept += issues
            }
        }
        let outcome: GuardedWritingResult.Outcome =
            !kept.isEmpty ? .keptSource(issues: kept)
            : !flagged.isEmpty ? .flagged(issues: flagged)
            : !retried.isEmpty ? .acceptedAfterRetry(firstIssues: retried)
            : .accepted
        return WritingPipelineResult(
            text: results.map(\.text).joined(),
            outcome: outcome,
            firstAnswer: results.map(\.firstAnswer).joined(),
            requests: results.reduce(0) { $0 + $1.requests },
            pieces: results.reduce(0) { $0 + $1.pieces }
        )
    }
}

/// Tells whether an answer still belongs to the newest request. Each request takes a ticket; an
/// answer is shown only if its ticket is still the latest one, so a slow answer to an older request
/// can never overwrite a newer one.
public struct WritingRequestTickets: Sendable {
    private var latest = 0

    public init() {}

    public mutating func issue() -> Int {
        latest += 1
        return latest
    }

    /// Makes every ticket issued so far stale (the request was cancelled).
    public mutating func invalidate() {
        latest += 1
    }

    public func isCurrent(_ ticket: Int) -> Bool {
        ticket == latest
    }
}
