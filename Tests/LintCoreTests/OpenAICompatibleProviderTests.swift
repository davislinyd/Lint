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

    func testOnlyTheLocalServerGetsTheLongTimeout() throws {
        let request = ChatRequest(model: "m", systemPrompt: "s", userText: "u")
        let base = URL(string: "http://127.0.0.1:8000/v1")!
        let local = try OpenAICompatibleProvider.makeURLRequest(
            baseURL: base, apiKey: "", request: request, timeout: OpenAICompatibleProvider.localRequestTimeout
        )
        XCTAssertEqual(local.timeoutInterval, 300, "a model waking from idle sleep is not a dead connection")
        let other = try OpenAICompatibleProvider.makeURLRequest(baseURL: base, apiKey: "", request: request)
        XCTAssertEqual(other.timeoutInterval, URLRequest(url: base).timeoutInterval)
    }

    func testAPromptTooLongForTheContextGetsAMessageAPersonCanActOn() {
        let message = LLMError.httpStatus(400, #"{"error":{"type":"exceed_context_size_error"}}"#).localizedDescription
        XCTAssertFalse(message.contains("exceed_context_size_error"))
        XCTAssertTrue(message.contains("-c"))
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

    // MARK: - A reply that ran out of context

    // The chunks llama-server b11046 sends at the end of a stream: `finish_reason` first, then usage.
    // It says "length" both when the context is full and when `max_tokens` is reached.
    private func ending(_ reason: String, completionTokens: Int) -> [String] {
        [
            #"{"choices":[{"index":0,"delta":{"content":"Section 1. Alice has"}}]}"#,
            #"{"choices":[{"finish_reason":"\#(reason)","index":0,"delta":{}}]}"#,
            #"{"choices":[],"usage":{"completion_tokens":\#(completionTokens),"prompt_tokens":924,"total_tokens":\#(924 + completionTokens)}}"#,
        ]
    }

    private func streamedText(_ kind: ProviderKind, maxTokens: Int, chunks: [String], done: Bool = true) async throws -> String {
        SSEStubProtocol.body = Data((chunks.map { "data: \($0)\n\n" }.joined() + (done ? "data: [DONE]\n\n" : "")).utf8)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [SSEStubProtocol.self]
        let provider = OpenAICompatibleProvider(
            id: kind, baseURL: URL(string: "http://127.0.0.1:8000/v1")!, apiKey: "",
            session: URLSession(configuration: configuration)
        )
        var text = ""
        for try await event in provider.stream(ChatRequest(model: "m", systemPrompt: "s", userText: "u", maxTokens: maxTokens)) {
            if case .text(let token) = event { text += token }
        }
        return text
    }

    func testALocalReplyCutShortByTheContextIsAnErrorNotASuggestion() async {
        do {
            _ = try await streamedText(.localLlama, maxTokens: 3000, chunks: ending("length", completionTokens: 100))
            XCTFail("a reply that stopped at the end of the context must not come back as text")
        } catch {
            guard case LLMError.contextExhausted = error else { return XCTFail("unexpected error: \(error)") }
            XCTAssertEqual(
                error.localizedDescription,
                LLMError.httpStatus(400, "exceed_context_size_error").localizedDescription,
                "the same advice as a text that does not fit at all"
            )
        }
    }

    func testALocalReplyThatReachedItsOwnLimitIsKept() async throws {
        // The warm-up asks for one token and the gloss for at most 512: stopping there is the point.
        let text = try await streamedText(.localLlama, maxTokens: 100, chunks: ending("length", completionTokens: 100))
        XCTAssertEqual(text, "Section 1. Alice has")
    }

    func testALocalReplyThatFinishedIsKept() async throws {
        let text = try await streamedText(.localLlama, maxTokens: 3000, chunks: ending("stop", completionTokens: 100))
        XCTAssertEqual(text, "Section 1. Alice has")
    }

    func testOtherOpenAICompatibleServersAreLeftAlone() async throws {
        let text = try await streamedText(.openaiCompatible, maxTokens: 3000, chunks: ending("length", completionTokens: 100))
        XCTAssertEqual(text, "Section 1. Alice has")
        let cut = try await streamedText(.openaiCompatible, maxTokens: 3000, chunks: [ending("stop", completionTokens: 100)[0]], done: false)
        XCTAssertEqual(cut, "Section 1. Alice has")
    }

    // MARK: - Lint's own key and priority

    func testOnlyLintsLocalModelGetsLintsKeyAndGate() throws {
        let key = LocalAPIKey.generate()
        let gate = ModelPriorityGate()
        let service = LLMService(localModel: LocalModelAccess(key: key, gate: gate))
        let local = try XCTUnwrap(service.provider(for: LLMRuntimeConfig(
            kind: .localLlama, baseURL: URL(string: "http://127.0.0.1:8000/v1")!, model: "m", apiKey: ""
        )) as? OpenAICompatibleProvider)
        XCTAssertEqual(local.apiKey, key.value)
        XCTAssertTrue(local.gate === gate)

        let other = try XCTUnwrap(service.provider(for: LLMRuntimeConfig(
            kind: .openaiCompatible, baseURL: URL(string: "http://127.0.0.1:8000/v1")!, model: "m", apiKey: "theirs"
        )) as? OpenAICompatibleProvider)
        XCTAssertEqual(other.apiKey, "theirs", "Lint's key never goes to another server, even one on the same port")
        XCTAssertNil(other.gate)
    }

    private func provider(_ kind: ProviderKind, gate: ModelPriorityGate) -> OpenAICompatibleProvider {
        SSEStubProtocol.body = Data((ending("stop", completionTokens: 5).map { "data: \($0)\n\n" }.joined() + "data: [DONE]\n\n").utf8)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [SSEStubProtocol.self]
        return OpenAICompatibleProvider(
            id: kind, baseURL: URL(string: "http://127.0.0.1:8000/v1")!, apiKey: "k",
            session: URLSession(configuration: configuration), gate: gate
        )
    }

    func testALocalRequestInterruptsAnExternalOneAndLetsGoWhenItEnds() async throws {
        let gate = ModelPriorityGate(quietPeriod: .milliseconds(10))
        let interrupted = expectation(description: "the external request is interrupted")
        let lease = try await gate.acquireExternal(budget: .seconds(5), onPreempt: { interrupted.fulfill() })
        for try await _ in provider(.localLlama, gate: gate).stream(ChatRequest(model: "m", systemPrompt: "s", userText: "u", maxTokens: 10)) {}
        await fulfillment(of: [interrupted], timeout: 2)
        lease.release()
        let next = try await gate.acquireExternal(budget: .seconds(5), onPreempt: {})
        next.release()
    }

    func testACancelledLocalRequestStillLetsGo() async throws {
        let gate = ModelPriorityGate(quietPeriod: .milliseconds(10))
        let stream = provider(.localLlama, gate: gate).stream(ChatRequest(model: "m", systemPrompt: "s", userText: "u", maxTokens: 10))
        let task = Task { for try await _ in stream {} }
        task.cancel()
        _ = await task.result
        let lease = try await gate.acquireExternal(budget: .seconds(5), onPreempt: {})
        lease.release()
    }

    func testOtherServersDoNotTakeTheLocalModelFromAnyone() async throws {
        let gate = ModelPriorityGate(quietPeriod: .seconds(60))
        let lease = try await gate.acquireExternal(budget: .seconds(5), onPreempt: { XCTFail("not Lint's local model") })
        for try await _ in provider(.openaiCompatible, gate: gate).stream(ChatRequest(model: "m", systemPrompt: "s", userText: "u", maxTokens: 10)) {}
        XCTAssertFalse(lease.wasPreempted)
        lease.release()
    }

    func testALocalReplyWhoseConnectionEndsBeforeItFinishesIsAnError() async {
        // llama-server killed mid-answer: the connection just ends, with no finish_reason and no [DONE].
        do {
            _ = try await streamedText(.localLlama, maxTokens: 3000, chunks: [ending("stop", completionTokens: 100)[0]], done: false)
            XCTFail("an answer that never finished must not come back as text")
        } catch {
            guard case LLMError.replyInterrupted = error else { return XCTFail("unexpected error: \(error)") }
        }
    }
}

/// Answers every request with `body` as a `text/event-stream`.
final class SSEStubProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var body = Data()

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}

    override func startLoading() {
        let response = HTTPURLResponse(
            url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "text/event-stream"]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Self.body)
        client?.urlProtocolDidFinishLoading(self)
    }
}
