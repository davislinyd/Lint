import XCTest

@testable import LintCore

final class LlamaServerLaunchPlanTests: XCTestCase {
    private let runtime = URL(fileURLWithPath: "/Applications/Lint.app/Contents/Resources/LlamaRuntime/arm64/llama-server")

    private func plan(
        model: LocalModelReference = .file(URL(fileURLWithPath: "/m.gguf")),
        port: Int = 8000,
        profile: ModelRuntimeProfile = ModelRuntimeProfile(),
        idleSleepSeconds: Int = 0,
        extra: String = ""
    ) -> LlamaServerLaunchPlan {
        LlamaServerLaunchPlan.make(
            runtime: runtime, model: model, port: port, profile: profile,
            idleSleepSeconds: idleSleepSeconds, extraArguments: extra
        )
    }

    private func value(after flag: String, in arguments: [String]) -> String? {
        guard let index = arguments.firstIndex(of: flag), index + 1 < arguments.count else { return nil }
        return arguments[index + 1]
    }

    func testAManagedModelIsLaunchedFromItsLocalFile() {
        let model = URL(fileURLWithPath: "/Users/me/Library/Application Support/Lint/Models/gemma-4-12b-it-qat-q4_0/gemma-4-12b-it-qat-q4_0.gguf")
        let launch = plan(model: .file(model))
        XCTAssertEqual(launch.executableURL, runtime)
        XCTAssertEqual(Array(launch.arguments.prefix(6)), ["-m", model.path, "--host", "127.0.0.1", "--port", "8000"])
        XCTAssertFalse(launch.arguments.contains("-hf"), "a managed model must never make llama-server download anything")
    }

    func testACustomHuggingFaceModelStillUsesHF() {
        let launch = plan(model: .huggingFace("Qwen/Qwen2.5-7B-Instruct-GGUF:q4_k_m"), port: 8123)
        XCTAssertEqual(Array(launch.arguments.prefix(5)), ["-hf", "Qwen/Qwen2.5-7B-Instruct-GGUF:q4_k_m", "--host", "127.0.0.1", "--port"])
        XCTAssertEqual(launch.arguments[5], "8123")
    }

    // MARK: - Lint's own tuning

    private let sharedTuning = [
        "--jinja", "--no-skip-chat-parsing", "-ngl", "99", "-fa", "on", "-c", "3072",
        "-np", "1", "-t", "6", "-ctk", "q8_0", "-ctv", "q8_0", "-b", "512", "-ub", "256",
    ]

    func testTheTuningDefaultsAreWhatLintDecidedForItsOwnWorkload() {
        let arguments = plan().arguments
        XCTAssertEqual(Array(arguments.dropFirst(6)), sharedTuning, "no reasoning switch unless a model needs one")
        XCTAssertFalse(arguments.contains("--mlock"), "Lint wants the OS free to page the model out")
        XCTAssertFalse(arguments.contains("--no-mmap"))
    }

    func testEachModelsOwnProfileIsWhatGetsApplied() {
        let gemma = plan(profile: ModelCatalog.gemma4_12bQATQ4_0.runtimeProfile, idleSleepSeconds: 300).arguments
        XCTAssertEqual(
            Array(gemma.dropFirst(6)), sharedTuning + ["--reasoning", "off", "--sleep-idle-seconds", "300"], "Gemma 4 12B"
        )

        let unknown = plan(profile: .unknownModel).arguments
        XCTAssertEqual(value(after: "--reasoning", in: unknown), "off", "an unknown -hf model is kept from thinking")

        // A profile is data, so a different one really does change the command line.
        let other = plan(profile: ModelRuntimeProfile(
            reasoningArguments: [], contextTokens: 8192, kvCacheType: "f16", batchTokens: 2048, ubatchTokens: 512
        )).arguments
        XCTAssertEqual(value(after: "-c", in: other), "8192")
        XCTAssertEqual(value(after: "-ctk", in: other), "f16")
        XCTAssertEqual(value(after: "-b", in: other), "2048")
        XCTAssertEqual(value(after: "-ub", in: other), "512")
        XCTAssertFalse(other.contains("--reasoning"), "a model with no thinking mode gets no reasoning flag")
    }

    func testEverySizedOptionAppearsExactlyOnce() {
        for extra in ["", "-c 8192", "--ctx-size=8192 -ctk f16", "--verbose", "-ngl 40 -t 2 --reasoning auto"] {
            let arguments = plan(profile: ModelCatalog.gemma4_12bQATQ4_0.runtimeProfile, idleSleepSeconds: 300, extra: extra).arguments
            for flag in ["-c", "-ctk", "-ctv", "-b", "-ub", "-ngl", "-fa", "-np", "-t", "--reasoning", "--sleep-idle-seconds", "--jinja", "--host", "--port"] {
                XCTAssertLessThanOrEqual(
                    arguments.filter { $0 == flag }.count, 1,
                    "\(flag) appears more than once for extra: '\(extra)'"
                )
            }
        }
    }

    func testTheUsersOwnArgumentsWinOverLintsTuningAndNeverDuplicateIt() {
        let arguments = plan(
            profile: ModelCatalog.gemma4_12bQATQ4_0.runtimeProfile,
            extra: "-c 8192 -ctk f16 -ctv f16 -b 2048 -ub 512 --reasoning auto"
        ).arguments
        XCTAssertEqual(value(after: "-c", in: arguments), "8192")
        XCTAssertEqual(value(after: "-ctk", in: arguments), "f16")
        XCTAssertEqual(value(after: "-ctv", in: arguments), "f16")
        XCTAssertEqual(value(after: "-b", in: arguments), "2048")
        XCTAssertEqual(value(after: "-ub", in: arguments), "512")
        XCTAssertEqual(value(after: "--reasoning", in: arguments), "auto")
        XCTAssertFalse(arguments.contains("3072"))
        XCTAssertFalse(arguments.contains("q8_0"))
        // The long spellings and `--flag=value` are the same option.
        let long = plan(extra: "--ctx-size=8192 --cache-type-k q4_0 --n-gpu-layers 20 --no-jinja").arguments
        XCTAssertFalse(long.contains("3072"))
        XCTAssertFalse(long.contains("-ctk"), "--cache-type-k already set it")
        XCTAssertFalse(long.contains("-ngl"))
        XCTAssertFalse(long.contains("--jinja"))
        XCTAssertTrue(long.contains("-ctv"), "the V cache was not overridden, so Lint still sets it")
    }

    // MARK: - Idle sleep

    func testIdleSleepIsPassedOnlyWhenItIsSwitchedOn() {
        XCTAssertFalse(plan(idleSleepSeconds: 0).arguments.contains("--sleep-idle-seconds"))
        let arguments = plan(idleSleepSeconds: 300).arguments
        XCTAssertEqual(value(after: "--sleep-idle-seconds", in: arguments), "300")
        XCTAssertEqual(arguments.filter { $0 == "--sleep-idle-seconds" }.count, 1)
        XCTAssertEqual(
            value(after: "--sleep-idle-seconds", in: plan(idleSleepSeconds: 300, extra: "--sleep-idle-seconds 60").arguments),
            "60", "the advanced field still wins"
        )
    }

    func testTheServerStaysBoundToLoopbackWhateverTheExtraArgumentsSay() {
        for extra in ["--host 0.0.0.0", "--host=0.0.0.0 -ngl 99", "-ngl 99 --host ::", "--host\t0.0.0.0\n--jinja"] {
            let plan = self.plan(extra: extra)
            let hostIndices = plan.arguments.indices.filter { plan.arguments[$0] == "--host" }
            XCTAssertEqual(hostIndices.count, 1, "extra: \(extra)")
            XCTAssertEqual(plan.arguments[hostIndices[0] + 1], "127.0.0.1", "extra: \(extra)")
            XCTAssertFalse(plan.arguments.contains { $0.hasPrefix("--host=") || $0 == "0.0.0.0" || $0 == "::" }, "extra: \(extra)")
        }
        XCTAssertEqual(LlamaServerLaunchPlan.host, "127.0.0.1")
    }

    func testOrdinaryExtraArgumentsAreKeptInOrderAtTheEnd() {
        let arguments = plan(extra: "  --verbose   --metrics -t 2  ").arguments
        XCTAssertEqual(Array(arguments.suffix(4)), ["--verbose", "--metrics", "-t", "2"])
    }
}
