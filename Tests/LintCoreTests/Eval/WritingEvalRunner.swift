import Foundation
import XCTest

@testable import LintCore

/// One engine's answer to one fixture, with how long it took.
struct WritingEvalResult: Codable {
    var id: String
    var category: String
    var mode: String
    var tone: String
    var input: String
    var note: String
    /// What the user would see: after the guard's retry or fallback when the guard is on.
    var output: String
    var seconds: Double
    var failures: [String]
    /// The model's first answer, before any guard. Same as `output` when the guard is off.
    var firstOutput: String?
    /// accepted / retried / keptSource / flagged / unguarded.
    var outcome: String?
    var requests: Int?
    /// Token-level edit ratio from the input to `output`.
    var changeRatio: Double?
    var expectUnchanged: Bool?
    var promptTokens: Int?
    var completionTokens: Int?
}

/// Where a run's answers came from, so that runs are only compared when that makes sense: Apple
/// can change the system model with any OS update.
struct WritingEvalEnvironment: Codable {
    var engine: String
    var model: String
    var osVersion: String
    var appVersion: String
    var promptProfile: String
    var promptVersion: String?
    var appleVariant: String?
    var contextSize: Int?
    var guarded: Bool
    var temperature: Double?
    var hardware: String
}

struct WritingEvalRun: Codable {
    var label: String
    var startedAt: Date
    var environment: WritingEvalEnvironment
    var results: [WritingEvalResult]

    static var directory: URL {
        TestSupport.repoRoot.appendingPathComponent(".build/eval", isDirectory: true)
    }

    /// Share of the already-correct fixtures whose output differs from the input. Lower is better:
    /// every change to text that needed none is an edit the user has to read and reject.
    var cleanSentenceChangeRate: (changed: Int, of: Int)? {
        let clean = results.filter { $0.expectUnchanged == true }
        guard !clean.isEmpty else { return nil }
        let changed = clean.filter {
            $0.output.trimmingCharacters(in: .whitespacesAndNewlines) != $0.input.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return (changed.count, clean.count)
    }

    /// The first request of a run pays for loading the model.
    var coldSeconds: Double? { results.first?.seconds }

    var warmSeconds: [Double] { results.dropFirst().map(\.seconds).sorted() }
}

/// Runs every fixture through one engine, the way the app would, and records what came back.
/// Skipped unless `LINT_EVAL=1`, so `swift test` never needs Apple Intelligence, a model, a download
/// or a network.
///
///     # Apple's on-device model (needs Apple Intelligence on this Mac)
///     LINT_EVAL=1 LINT_EVAL_ENGINE=apple LINT_EVAL_LABEL=apple swift test --filter WritingEvalRunTests
///     # Gemma through a llama-server you started yourself
///     LINT_EVAL=1 LINT_EVAL_ENGINE=llama LINT_EVAL_LABEL=gemma LINT_EVAL_URL=http://127.0.0.1:8099/v1 \
///         swift test --filter WritingEvalRunTests
///     # then put the runs side by side in .build/eval/comparison.md
///     LINT_EVAL_COMPARE=1 swift test --filter WritingEvalReportTests
///
/// The app's paths are reproduced exactly: Apple gets the English prompts, `WritingPipeline`'s
/// check and single retry, one fresh session per request and greedy sampling; llama gets the English
/// prompts with the language line, temperature 0.3 and no guard. `LINT_EVAL_GUARD=0|1` overrides the
/// guard, `LINT_EVAL_TEMPERATURE` the temperature, `LINT_EVAL_PROFILE=standard` the prompts.
/// `LINT_EVAL_REMINDERS=zh|en` adds what a user with two learned habits gets (articles, prepositions
/// after verbs), picked by the app's retriever and worded in Chinese or in English.
final class WritingEvalRunTests: XCTestCase {
    /// Two habits as Lint words them when it learns them: general, so they go with every English text.
    static let learnedHabits: [WritingMemory] = [
        ("grammar:en:articles", MemoryWording.articles),
        ("grammar:en:family:redundant-preposition", MemoryWording.redundantPrepositions),
    ].map { key, wording in
        WritingMemory(
            id: UUID(), dedupKey: key, kind: .grammar, language: "en", modeScope: nil, triggers: [],
            instruction: wording.chinese, evidenceScore: 2, occurrenceCount: 5, state: .active, userEdited: false,
            createdAt: Date(), lastConfirmedAt: Date()
        )
    }

    func testRunEveryFixtureThroughOneEngine() async throws {
        let environment = ProcessInfo.processInfo.environment
        try XCTSkipUnless(environment["LINT_EVAL"] == "1", "set LINT_EVAL=1 (see the class comment)")
        let engine = environment["LINT_EVAL_ENGINE"] ?? "apple"
        let label = environment["LINT_EVAL_LABEL"] ?? engine
        let onDevice = engine == "apple"
        let guarded = environment["LINT_EVAL_GUARD"].map { $0 == "1" } ?? onDevice
        let only = environment["LINT_EVAL_ONLY"].map { Set($0.split(separator: ",").map(String.init)) }
        // The app sends llama-server 0.3; LINT_EVAL_TEMPERATURE tries another (0 = greedy).
        let temperature = environment["LINT_EVAL_TEMPERATURE"].flatMap(Double.init) ?? 0.3
        let reminders = environment["LINT_EVAL_REMINDERS"]

        let provider: any LLMProvider
        let model: String
        if onDevice {
            let status = SystemAppleIntelligence().currentStatus()
            try XCTSkipUnless(status.isAvailable, "Apple Intelligence is not available: \(status)")
            provider = AppleFoundationModelProvider()
            model = ProviderKind.appleIntelligence.defaultModel
        } else {
            let endpoint = environment["LINT_EVAL_URL"] ?? "http://127.0.0.1:8000/v1"
            let session = URLSessionConfiguration.ephemeral
            session.timeoutIntervalForRequest = 300
            session.timeoutIntervalForResource = 600
            provider = OpenAICompatibleProvider(
                id: .localLlama, baseURL: try XCTUnwrap(URL(string: endpoint)), apiKey: "",
                session: URLSession(configuration: session)
            )
            model = environment["LINT_EVAL_MODEL"] ?? ProviderKind.localLlama.defaultModel
        }
        let metadata = AppleModelMetadata.current()
        // As the app: the English prompts for Apple and for Lint's local model. LINT_EVAL_PROFILE=standard
        // gives a llama model the original Chinese prompts, to compare.
        let profile: WritingPromptProfile = environment["LINT_EVAL_PROFILE"] == "standard"
            ? .standard : .english(onDevice ? .appleOnDevice : .localModel)

        let fixtures = try WritingEvalFixtures.load()
        var results: [WritingEvalResult] = []
        for testCase in fixtures.cases where only?.contains(testCase.id) ?? true {
            let mode = testCase.writingMode
            let tone = testCase.writingTone
            var usage: TokenUsage?
            func generate(_ systemPrompt: String, _ text: String) async throws -> String {
                let request = ChatRequest(
                    model: model, systemPrompt: systemPrompt, userText: text,
                    // The app caps the on-device answer; llama keeps the app's default.
                    maxTokens: onDevice ? WritingPipeline.responseTokenLimit(for: text) : 4096,
                    reasoningEffort: onDevice ? nil : .low,
                    temperature: onDevice ? nil : temperature,
                    transformsUserText: true
                )
                var output = ""
                for try await event in provider.stream(request) {
                    switch event {
                    case .text(let token): output += token
                    case .usage(let value): usage = value
                    }
                }
                return output
            }

            var systemPrompt = testCase.systemPrompt(profile: profile)
            if let reminders {
                let habits = MemoryRetriever(memories: Self.learnedHabits).select(for: MemoryRetriever.Query(
                    text: testCase.input, mode: mode, tone: tone, outputLanguage: mode == .translate ? "zh-Hant" : nil
                ))
                systemPrompt = PromptComposer.compose(base: systemPrompt, memories: habits, english: reminders == "en").systemPrompt
            }
            let started = Date()
            var output = ""
            var first: String?
            var outcome = "unguarded"
            var requests = 1
            do {
                if guarded {
                    let budget = onDevice
                        ? AppleFoundationModelProvider.contextSize.map { WritingChunkBudget(contextSize: $0, instructions: systemPrompt) }
                        : nil
                    let result = try await WritingPipeline.run(
                        source: testCase.input, mode: mode, tone: tone, systemPrompt: systemPrompt, budget: budget,
                        generate: generate
                    )
                    output = result.text
                    first = result.firstAnswer
                    requests = result.requests
                    switch result.outcome {
                    case .accepted: outcome = "accepted"
                    case .acceptedAfterRetry: outcome = "retried"
                    case .keptSource: outcome = "keptSource"
                    case .flagged: outcome = "flagged"
                    }
                } else {
                    // The unguarded path of the app adds the language line itself (the pipeline does it otherwise).
                    let prompt = profile.isEnglish
                        ? WritingPromptComposer.withLanguageLine(systemPrompt, for: testCase.input, mode: mode) : systemPrompt
                    output = try await generate(prompt, testCase.input)
                    first = output
                }
            } catch {
                output = "<<request failed: \((error as? AppleIntelligenceError)?.diagnostic ?? error.localizedDescription)>>"
            }
            let failures = WritingEvalChecks.run(testCase, output: output)
            results.append(WritingEvalResult(
                id: testCase.id, category: testCase.category, mode: testCase.mode, tone: testCase.tone,
                input: testCase.input, note: testCase.note, output: output,
                seconds: Date().timeIntervalSince(started),
                failures: failures.map { "\($0.check): \($0.detail)" },
                firstOutput: first, outcome: outcome, requests: requests,
                changeRatio: EditRatio.between(testCase.input, output),
                expectUnchanged: testCase.expectUnchanged,
                promptTokens: usage?.promptTokens, completionTokens: usage?.completionTokens
            ))
            print("[eval] \(testCase.id) \(String(format: "%.2f", Date().timeIntervalSince(started)))s \(outcome) \(failures.map(\.check))")
        }

        let promptVersion = [profile.isEnglish ? metadata.promptVersion : nil, reminders.map { "reminders-\($0)" }]
            .compactMap { $0 }.joined(separator: "+")
        let run = WritingEvalRun(
            label: label, startedAt: Date(),
            environment: WritingEvalEnvironment(
                engine: engine, model: model, osVersion: metadata.osVersion, appVersion: Self.appVersion,
                promptProfile: profile.isEnglish ? "english (\(onDevice ? "apple" : "local"))" : "standard",
                promptVersion: promptVersion.isEmpty ? nil : promptVersion,
                appleVariant: onDevice ? metadata.variant : nil,
                contextSize: onDevice ? metadata.contextSize : nil,
                guarded: guarded, temperature: onDevice ? nil : temperature, hardware: Self.hardware
            ),
            results: results
        )
        try FileManager.default.createDirectory(at: WritingEvalRun.directory, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .withoutEscapingSlashes, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let file = WritingEvalRun.directory.appendingPathComponent("\(label).json")
        try encoder.encode(run).write(to: file)

        let failed = results.filter { !$0.failures.isEmpty }
        let cscr = run.cleanSentenceChangeRate.map { "\($0.changed)/\($0.of)" } ?? "n/a"
        print("""
            [eval] \(label): \(results.count) cases, \(failed.count) with a failed check, clean sentences changed \(cscr), \
            cold \(String(format: "%.2f", run.coldSeconds ?? 0))s, warm median \(String(format: "%.2f", WritingEvalReportTests.median(run.warmSeconds)))s
            [eval] written to \(file.path)
            """)
        for result in results where result.output.hasPrefix("<<request failed") {
            print("[eval] request failed: \(result.id): \(result.output)")
        }
    }

    static var appVersion: String {
        let plist = TestSupport.repoRoot.appendingPathComponent("Resources/Info.plist")
        let values = NSDictionary(contentsOf: plist)
        return values?["CFBundleShortVersionString"] as? String ?? "unknown"
    }

    static var hardware: String {
        var size = 0
        sysctlbyname("machdep.cpu.brand_string", nil, &size, nil, 0)
        var brand = [CChar](repeating: 0, count: max(size, 1))
        sysctlbyname("machdep.cpu.brand_string", &brand, &size, nil, 0)
        let memory = ProcessInfo.processInfo.physicalMemory / 1_073_741_824
        return "\(String(decoding: brand.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)), \(memory) GB"
    }
}

/// Puts the runs that are on disk next to each other, in one Markdown file to read.
final class WritingEvalReportTests: XCTestCase {
    static func median(_ values: [Double]) -> Double {
        guard !values.isEmpty else { return 0 }
        let sorted = values.sorted()
        return sorted.count % 2 == 1 ? sorted[sorted.count / 2] : (sorted[sorted.count / 2 - 1] + sorted[sorted.count / 2]) / 2
    }

    static func percentile(_ values: [Double], _ p: Double) -> Double {
        guard !values.isEmpty else { return 0 }
        let sorted = values.sorted()
        return sorted[min(sorted.count - 1, Int((Double(sorted.count) * p).rounded(.up)) - 1)]
    }

    func testWriteTheComparison() throws {
        try XCTSkipUnless(
            ProcessInfo.processInfo.environment["LINT_EVAL_COMPARE"] == "1",
            "set LINT_EVAL_COMPARE=1 after at least one LINT_EVAL=1 run"
        )
        let directory = WritingEvalRun.directory
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil))?
            .filter { $0.pathExtension == "json" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent } ?? []
        try XCTSkipIf(files.isEmpty, "no runs in \(directory.path)")

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let fixtures = try WritingEvalFixtures.load()
        // The checks are re-applied to the stored answers rather than trusted as recorded: a run
        // costs minutes of model time, and the checks get sharper as the fixtures are read.
        // Runs written by an older version of this harness (no `environment`) are left out.
        let runs: [WritingEvalRun] = files.compactMap { file in
            guard var run = try? decoder.decode(WritingEvalRun.self, from: Data(contentsOf: file)) else {
                print("[eval] skipped \(file.lastPathComponent): not a run of this harness")
                return nil
            }
            // Only the cases still in the fixtures count: a run is re-scored on the current set.
            run.results = run.results.filter { result in fixtures.cases.contains { $0.id == result.id } }
            run.results = run.results.map { result in
                guard let testCase = fixtures.cases.first(where: { $0.id == result.id }) else { return result }
                var updated = result
                updated.failures = WritingEvalChecks.run(testCase, output: result.output).map { "\($0.check): \($0.detail)" }
                updated.expectUnchanged = testCase.expectUnchanged
                updated.changeRatio = EditRatio.between(testCase.input, result.output)
                return updated
            }
            return run
        }

        func count(_ run: WritingEvalRun, _ check: String, mode: String? = nil) -> Int {
            run.results.filter { result in
                (mode == nil || result.mode == mode) && result.failures.contains { $0.hasPrefix(check + ":") }
            }.count
        }

        var markdown = "# Lint writing evaluation\n\n"
        markdown += "Fixtures: `Tests/LintCoreTests/Eval/WritingEvalFixtures.json` (version \(fixtures.version), \(fixtures.cases.count) cases). "
        markdown += "Only objective checks are counted here; grammar errors left in, meaning changes and added facts are judged by reading the answers below.\n\n"
        markdown += "## Runs\n\n| Run | Engine | Model | OS | Prompt | Guard, temperature | Hardware |\n|---|---|---|---|---|---|---|\n"
        for run in runs {
            let env = run.environment
            let model = [env.model, env.appleVariant, env.contextSize.map { "ctx \($0)" }].compactMap { $0 }.joined(separator: ", ")
            let guardNote = (env.guarded ? "on" : "off") + (env.temperature.map { ", t=\($0)" } ?? "")
            markdown += "| \(run.label) | \(env.engine) | \(model) | \(env.osVersion) | \(env.promptProfile) \(env.promptVersion ?? "") | \(guardNote) | \(env.hardware) |\n"
        }
        markdown += "\n## Objective checks\n\n"
        markdown += "| Run | Cases | Any check failed | Errors left (cases / pieces) | Clean sentences changed | Literal lost | Language | Simplified chars | Mainland terms | Lines/lists | Preamble | Retried | Kept source | Flagged | Request failed |\n"
        markdown += "|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|\n"
        for run in runs {
            let cscr = run.cleanSentenceChangeRate.map { "\($0.changed)/\($0.of) (\(Int((Double($0.changed) / Double($0.of) * 100).rounded()))%)" } ?? "n/a"
            let unfixedPieces = run.results.reduce(0) { total, result in
                guard let testCase = fixtures.cases.first(where: { $0.id == result.id }) else { return total }
                return total + (testCase.mustFix ?? []).filter(result.output.contains).count
            }
            let fixable = fixtures.cases.reduce(0) { $0 + ($1.mustFix?.count ?? 0) }
            markdown += "| \(run.label) | \(run.results.count) | \(run.results.filter { !$0.failures.isEmpty }.count) "
            markdown += "| \(count(run, "fixes")) / \(unfixedPieces) of \(fixable) | \(cscr) "
            markdown += "| \(count(run, "preserves")) | \(count(run, "language")) | \(count(run, "simplified-chinese")) | \(count(run, "taiwan-wording")) "
            markdown += "| \(count(run, "line-structure")) | \(count(run, "no-preamble")) "
            markdown += "| \(run.results.filter { $0.outcome == "retried" }.count) | \(run.results.filter { $0.outcome == "keptSource" }.count) "
            markdown += "| \(run.results.filter { $0.outcome == "flagged" }.count) | \(run.results.filter { $0.output.hasPrefix("<<request failed") }.count) |\n"
        }
        markdown += "\n## Latency (seconds, whole request as the app makes it, including any retry)\n\n"
        markdown += "| Run | Cold (first case) | Warm median | Warm p90 | Warm max | Total |\n|---|---|---|---|---|---|\n"
        for run in runs {
            let warm = run.warmSeconds
            markdown += "| \(run.label) | \(String(format: "%.2f", run.coldSeconds ?? 0)) | \(String(format: "%.2f", Self.median(warm))) "
            markdown += "| \(String(format: "%.2f", Self.percentile(warm, 0.9))) | \(String(format: "%.2f", warm.last ?? 0)) "
            markdown += "| \(String(format: "%.1f", run.results.reduce(0) { $0 + $1.seconds })) |\n"
        }

        var category = ""
        for testCase in fixtures.cases {
            if testCase.category != category {
                category = testCase.category
                markdown += "\n## \(category)\n"
            }
            markdown += "\n### \(testCase.id) — \(testCase.mode)/\(testCase.tone)\(testCase.expectUnchanged == true ? " (already correct)" : "")\n\n"
            markdown += "**Input**\n\n```\n\(testCase.input)\n```\n\n"
            markdown += "**What a good answer does:** \(testCase.note)\n"
            for run in runs {
                guard let result = run.results.first(where: { $0.id == testCase.id }) else { continue }
                let ratio = result.changeRatio.map { String(format: "%.2f", $0) } ?? "–"
                markdown += "\n**\(run.label)** (\(String(format: "%.1f", result.seconds))s, change \(ratio)"
                if let outcome = result.outcome, outcome != "accepted", outcome != "unguarded" { markdown += ", \(outcome)" }
                markdown += ")"
                markdown += result.failures.isEmpty ? "\n" : " — failed: \(result.failures.joined(separator: "; "))\n"
                markdown += "\n```\n\(result.output)\n```\n"
                if let first = result.firstOutput, first != result.output {
                    markdown += "\nfirst answer, rejected by the guard:\n\n```\n\(first)\n```\n"
                }
            }
        }

        let file = directory.appendingPathComponent("comparison.md")
        try markdown.write(to: file, atomically: true, encoding: .utf8)
        print("[eval] written to \(file.path)")
    }
}
