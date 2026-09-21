import XCTest

@testable import LintCore

final class LlamaServerLaunchPlanTests: XCTestCase {
    private let runtime = URL(fileURLWithPath: "/Applications/Lint.app/Contents/Resources/LlamaRuntime/arm64/llama-server")

    func testAManagedModelIsLaunchedFromItsLocalFile() {
        let model = URL(fileURLWithPath: "/Users/me/Library/Application Support/Lint/Models/qwen/qwen-00001-of-00002.gguf")
        let plan = LlamaServerLaunchPlan.make(runtime: runtime, model: .file(model), port: 8000, extraArguments: "-ngl 99 -c 4096")
        XCTAssertEqual(plan.executableURL, runtime)
        XCTAssertEqual(
            plan.arguments,
            ["-m", model.path, "--host", "127.0.0.1", "--port", "8000", "-ngl", "99", "-c", "4096"]
        )
        XCTAssertFalse(plan.arguments.contains("-hf"), "a managed model must never make llama-server download anything")
    }

    func testACustomHuggingFaceModelStillUsesHF() {
        let plan = LlamaServerLaunchPlan.make(runtime: runtime, model: .huggingFace("Qwen/Qwen2.5-7B-Instruct-GGUF:q4_k_m"), port: 8123, extraArguments: "")
        XCTAssertEqual(plan.arguments, ["-hf", "Qwen/Qwen2.5-7B-Instruct-GGUF:q4_k_m", "--host", "127.0.0.1", "--port", "8123"])
    }

    func testTheServerStaysBoundToLoopbackWhateverTheExtraArgumentsSay() {
        for extra in ["--host 0.0.0.0", "--host=0.0.0.0 -ngl 99", "-ngl 99 --host ::", "--host\t0.0.0.0\n--jinja"] {
            let plan = LlamaServerLaunchPlan.make(runtime: runtime, model: .file(URL(fileURLWithPath: "/m.gguf")), port: 8000, extraArguments: extra)
            let hostIndices = plan.arguments.indices.filter { plan.arguments[$0] == "--host" }
            XCTAssertEqual(hostIndices.count, 1, "extra: \(extra)")
            XCTAssertEqual(plan.arguments[hostIndices[0] + 1], "127.0.0.1", "extra: \(extra)")
            XCTAssertFalse(plan.arguments.contains { $0.hasPrefix("--host=") || $0 == "0.0.0.0" || $0 == "::" }, "extra: \(extra)")
        }
        XCTAssertEqual(LlamaServerLaunchPlan.host, "127.0.0.1")
    }

    func testOrdinaryExtraArgumentsAreKeptInOrder() {
        let plan = LlamaServerLaunchPlan.make(
            runtime: runtime, model: .file(URL(fileURLWithPath: "/m.gguf")), port: 1,
            extraArguments: "  --jinja --no-skip-chat-parsing   -ngl 99 -fa on  "
        )
        XCTAssertEqual(Array(plan.arguments.suffix(6)), ["--jinja", "--no-skip-chat-parsing", "-ngl", "99", "-fa", "on"])
    }
}
