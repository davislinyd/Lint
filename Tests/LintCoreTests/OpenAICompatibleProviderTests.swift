import XCTest
@testable import LintCore

final class OpenAICompatibleProviderTests: XCTestCase {
    func testChatCompletionsRequestShape() throws {
        let request = ChatRequest(
            model: "grok-4.6",
            systemPrompt: "sys",
            userText: "hello"
        )
        let urlRequest = try OpenAICompatibleProvider.makeURLRequest(
            baseURL: URL(string: "http://127.0.0.1:8001/v1")!,
            apiKey: "secret",
            request: request
        )
        XCTAssertEqual(urlRequest.url?.absoluteString, "http://127.0.0.1:8001/v1/chat/completions")
        XCTAssertEqual(urlRequest.value(forHTTPHeaderField: "Authorization"), "Bearer secret")
        let body = try XCTUnwrap(urlRequest.httpBody)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        XCTAssertEqual(json["model"] as? String, "grok-4.6")
        XCTAssertEqual(json["stream"] as? Bool, true)
        let messages = try XCTUnwrap(json["messages"] as? [[String: Any]])
        XCTAssertEqual(messages[0]["role"] as? String, "system")
        XCTAssertEqual(messages[1]["content"] as? String, "hello")
    }

    func testOmitsAuthorizationWhenKeyEmpty() throws {
        let request = ChatRequest(model: "m", systemPrompt: "s", userText: "u")
        let urlRequest = try OpenAICompatibleProvider.makeURLRequest(
            baseURL: URL(string: "http://127.0.0.1:11434/v1/")!,
            apiKey: "",
            request: request
        )
        XCTAssertNil(urlRequest.value(forHTTPHeaderField: "Authorization"))
        XCTAssertEqual(urlRequest.url?.absoluteString, "http://127.0.0.1:11434/v1/chat/completions")
    }

    func testAnthropicRequestShape() throws {
        let request = ChatRequest(model: "claude-3-5-sonnet-latest", systemPrompt: "sys", userText: "hi")
        let urlRequest = try AnthropicProvider.makeURLRequest(
            baseURL: URL(string: "https://api.anthropic.com")!,
            apiKey: "sk-ant",
            request: request
        )
        XCTAssertEqual(urlRequest.url?.absoluteString, "https://api.anthropic.com/v1/messages")
        XCTAssertEqual(urlRequest.value(forHTTPHeaderField: "x-api-key"), "sk-ant")
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: try XCTUnwrap(urlRequest.httpBody)) as? [String: Any])
        XCTAssertEqual(body["stream"] as? Bool, true)
        XCTAssertEqual(body["system"] as? String, "sys")
    }

    func testAnthropicRejectsEmptyKey() {
        XCTAssertThrowsError(
            try AnthropicProvider.makeURLRequest(
                baseURL: URL(string: "https://api.anthropic.com")!,
                apiKey: "",
                request: ChatRequest(model: "m", systemPrompt: "s", userText: "u")
            )
        )
    }

    func testGeminiRequestUsesSSEQuery() throws {
        let request = ChatRequest(model: "gemini-2.0-flash", systemPrompt: "sys", userText: "hi")
        let urlRequest = try GeminiProvider.makeURLRequest(
            baseURL: URL(string: "https://generativelanguage.googleapis.com/v1beta")!,
            apiKey: "gkey",
            request: request
        )
        let url = try XCTUnwrap(urlRequest.url?.absoluteString)
        XCTAssertTrue(url.contains("/models/gemini-2.0-flash:streamGenerateContent"))
        XCTAssertTrue(url.contains("alt=sse"))
        XCTAssertTrue(url.contains("key=gkey"))
    }
}
