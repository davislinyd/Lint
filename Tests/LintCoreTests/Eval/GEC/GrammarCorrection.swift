import Foundation

@testable import LintCore

/// A grammatical-error-correction model: one English sentence in, the same sentence corrected out.
/// Not a chat model: there is no system prompt, no instruction and no conversation, so it can only
/// proofread; tone rewrites, translation and custom prompts stay with `LLMProvider`.
///
/// Only the evaluation uses this (`LINT_EVAL_ENGINE=gec`). A T5 GEC model was measured against
/// Gemma 4 E4B and not adopted: see docs/GEC-T5-EVALUATION.md.
protocol GrammarCorrectionProvider: Sendable {
    func correct(_ sentence: String) async throws -> String
}

enum GrammarCorrectionError: Error, Equatable, Sendable {
    case processFailed(Int32)
    case timedOut
    /// The model stopped at the token limit instead of finishing the sentence.
    case truncated
    case emptyOutput
}

struct ProcessResult: Equatable, Sendable {
    var status: Int32
    var stdout: String

    init(status: Int32, stdout: String) {
        self.status = status
        self.stdout = stdout
    }
}

/// Runs one short-lived process to completion and returns its standard output.
typealias ProcessRunner = @Sendable (
    _ executable: URL, _ arguments: [String], _ environment: [String: String], _ timeout: Duration
) async throws -> ProcessResult

/// A T5 GEC model (`gec: <sentence>`) run by llama.cpp's `llama-completion`, one process per
/// sentence. `llama-server` cannot run it: its request path never calls `llama_encode`, which an
/// encoder-decoder model needs (ggml-org/llama.cpp#26565); `llama-completion` does.
struct LlamaCompletionGECProvider: GrammarCorrectionProvider {
    static let prefix = "gec: "
    /// Far more than any sentence needs: an answer that reaches it was not a correction.
    static let maximumTokens = 256
    static let endMarker = "[end of text]"

    var executable: URL
    var model: URL
    var timeout: Duration
    var run: ProcessRunner

    init(executable: URL, model: URL, timeout: Duration = .seconds(20), run: @escaping ProcessRunner = ProcessRun.run) {
        self.executable = executable
        self.model = model
        self.timeout = timeout
        self.run = run
    }

    /// No Metal device at all: a model this small runs faster on the CPU (measured), and every
    /// process that opens a Metal device has the system compile ggml's shaders first, which took up
    /// to 30 s when the shader cache was cold.
    static let environment = ["GGML_METAL_DEVICES": "0"]

    /// Greedy decoding on the CPU, no chat template, no escape processing of the user's
    /// backslashes, no echo of the prompt.
    static func arguments(model: URL, sentence: String) -> [String] {
        [
            "-m", model.path, "-p", prefix + sentence,
            "-n", String(maximumTokens), "--temp", "0", "--top-k", "1",
            "-no-cnv", "--no-display-prompt", "--no-escape", "--no-warmup",
            "-c", "512", "-ngl", "0", "-t", "4",
        ]
    }

    /// `llama-completion` writes the answer, then ` [end of text]` when the model stopped by itself.
    static func parse(_ stdout: String) throws -> String {
        guard let end = stdout.range(of: endMarker, options: .backwards) else { throw GrammarCorrectionError.truncated }
        let answer = stdout[..<end.lowerBound].trimmingCharacters(in: .whitespacesAndNewlines)
        guard !answer.isEmpty else { throw GrammarCorrectionError.emptyOutput }
        return answer
    }

    func correct(_ sentence: String) async throws -> String {
        let result = try await run(executable, Self.arguments(model: model, sentence: sentence), Self.environment, timeout)
        guard result.status == 0 else { throw GrammarCorrectionError.processFailed(result.status) }
        return try Self.parse(result.stdout)
    }
}

enum ProcessRun {
    /// Standard error (llama.cpp's log) is discarded. Cancelling the calling task or running past
    /// `timeout` terminates the process.
    static func run(
        _ executable: URL, _ arguments: [String], _ environment: [String: String], _ timeout: Duration
    ) async throws -> ProcessResult {
        try Task.checkCancellation()
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.environment = ProcessInfo.processInfo.environment.merging(environment) { $1 }
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        let state = ProcessState()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<ProcessResult, Error>) in
                // Both the end of the output and the exit, in either order. (`waitUntilExit()` on a
                // dispatch thread can wait forever: it needs a run loop.)
                let done = DispatchGroup()
                done.enter()
                process.terminationHandler = { _ in done.leave() }
                do {
                    try process.run()
                } catch {
                    continuation.resume(throwing: error)
                    return
                }
                state.started(process)
                DispatchQueue.global().asyncAfter(deadline: .now() + timeout.seconds) {
                    if state.stop(timedOut: true) { process.terminate() }
                }
                done.enter()
                DispatchQueue.global().async {
                    state.output = output.fileHandleForReading.readDataToEndOfFile()
                    done.leave()
                }
                done.notify(queue: .global()) {
                    state.finish()
                    if state.wasCancelled {
                        continuation.resume(throwing: CancellationError())
                    } else if state.didTimeOut {
                        continuation.resume(throwing: GrammarCorrectionError.timedOut)
                    } else {
                        continuation.resume(returning: ProcessResult(
                            status: process.terminationStatus, stdout: String(decoding: state.output, as: UTF8.self)
                        ))
                    }
                }
            }
        } onCancel: {
            if let running = state.cancel() { running.terminate() }
        }
    }
}

/// Who stopped the process first, and whether there is still one to stop.
private final class ProcessState: @unchecked Sendable {
    private let lock = NSLock()
    private var process: Process?
    private var finished = false
    private(set) var wasCancelled = false
    private(set) var didTimeOut = false
    /// Written once by the reader, read after it is done.
    var output = Data()

    func started(_ process: Process) {
        lock.lock()
        defer { lock.unlock() }
        self.process = process
        // Cancelled between `run()` and here.
        if wasCancelled { process.terminate() }
    }

    /// True if the caller should terminate the process now.
    func stop(timedOut: Bool) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !finished, process != nil, !wasCancelled, !didTimeOut else { return false }
        didTimeOut = timedOut
        return true
    }

    func cancel() -> Process? {
        lock.lock()
        defer { lock.unlock() }
        guard !finished, !wasCancelled else { return nil }
        wasCancelled = true
        return process
    }

    func finish() {
        lock.lock()
        defer { lock.unlock() }
        finished = true
    }
}

private extension Duration {
    var seconds: Double {
        let (whole, fraction) = components
        return Double(whole) + Double(fraction) / 1e18
    }
}
