import XCTest
@testable import LintCore

final class LiveLLMTests: XCTestCase {
    func testLiveGrokRouterStreamsContentNotReasoning() async throws {
        try XCTSkipUnless(
            ProcessInfo.processInfo.environment["LINT_LIVE"] == "1",
            "set LINT_LIVE=1 to hit the local router"
        )
        let key = ProcessInfo.processInfo.environment["LINT_API_KEY"] ?? ""
        try XCTSkipIf(key.isEmpty, "LINT_API_KEY missing")

        let sessionConfig = URLSessionConfiguration.ephemeral
        sessionConfig.timeoutIntervalForRequest = 45
        sessionConfig.timeoutIntervalForResource = 45
        let provider = OpenAICompatibleProvider(
            baseURL: ProviderKind.openaiCompatible.defaultBaseURL,
            apiKey: key,
            session: URLSession(configuration: sessionConfig)
        )
        let request = ChatRequest(
            model: ProviderKind.openaiCompatible.defaultModel,
            systemPrompt: "Reply with the single word pong. No other text.",
            userText: "ping",
            maxTokens: 64
        )
        var collected = ""
        for try await event in provider.stream(request) {
            if case .text(let token) = event {
                collected += token
            }
            if collected.count > 80 { break }
        }
        XCTAssertFalse(collected.isEmpty, "expected visible content tokens")
        XCTAssertFalse(
            collected.lowercased().contains("the user"),
            "reasoning leaked into content"
        )
        XCTAssertTrue(
            collected.lowercased().contains("pong"),
            "unexpected content"
        )
    }
}
