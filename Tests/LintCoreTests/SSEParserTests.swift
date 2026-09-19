import XCTest
@testable import LintCore

final class SSEParserTests: XCTestCase {
    func testPayloadFromDataLine() {
        XCTAssertEqual(SSEParser.payload(fromLine: "data: hello"), "hello")
        XCTAssertEqual(SSEParser.payload(fromLine: "data:  {\"a\":1}\r"), "{\"a\":1}")
        XCTAssertNil(SSEParser.payload(fromLine: "event: delta"))
        XCTAssertNil(SSEParser.payload(fromLine: "data:"))
        XCTAssertNil(SSEParser.payload(fromLine: ""))
    }

    func testOpenAIContentIgnoresReasoning() {
        let reasoning = """
        {"choices":[{"delta":{"reasoning_content":"The user query is"},"finish_reason":null,"index":0}],"object":"chat.completion.chunk"}
        """
        let role = """
        {"choices":[{"delta":{"role":"assistant"},"finish_reason":null,"index":0}]}
        """
        let content = """
        {"choices":[{"delta":{"content":"pong"},"finish_reason":null,"index":0}]}
        """
        XCTAssertNil(OpenAIStreamDelta.content(fromPayload: reasoning))
        XCTAssertNil(OpenAIStreamDelta.content(fromPayload: role))
        XCTAssertEqual(OpenAIStreamDelta.content(fromPayload: content), "pong")
        XCTAssertNil(OpenAIStreamDelta.content(fromPayload: "[DONE]"))
    }

    func testAnthropicTextDelta() {
        let payload = """
        {"type":"content_block_delta","delta":{"type":"text_delta","text":"Hello"}}
        """
        XCTAssertEqual(AnthropicStreamDelta.content(fromPayload: payload), "Hello")
        XCTAssertNil(AnthropicStreamDelta.content(fromPayload: #"{"type":"message_start"}"#))
    }

    func testGeminiTextDelta() {
        let payload = """
        {"candidates":[{"content":{"parts":[{"text":"嗨"}]}}]}
        """
        XCTAssertEqual(GeminiStreamDelta.content(fromPayload: payload), "嗨")
    }

    func testOpenAIUsageChunk() {
        let payload = """
        {"choices":[{"delta":{},"finish_reason":"stop","index":0}],"usage":{"completion_tokens":137,"completion_tokens_details":{"reasoning_tokens":132},"prompt_tokens":2156,"prompt_tokens_details":{"cached_tokens":2048},"total_tokens":2293}}
        """
        let event = OpenAIStreamDelta.event(fromPayload: payload)
        guard case .usage(let usage) = event else {
            return XCTFail("expected usage event")
        }
        XCTAssertEqual(usage.promptTokens, 2156)
        XCTAssertEqual(usage.completionTokens, 137)
        XCTAssertEqual(usage.reasoningTokens, 132)
        XCTAssertEqual(usage.cachedPromptTokens, 2048)
        XCTAssertEqual(usage.totalTokens, 2293)
    }
}
