import Foundation

public enum SSEParser: Sendable {
    public static func payload(fromLine line: String) -> String? {
        var trimmed = line
        if trimmed.hasSuffix("\r") {
            trimmed.removeLast()
        }
        guard trimmed.hasPrefix("data:") else { return nil }
        let value = trimmed.dropFirst(5).trimmingCharacters(in: .whitespaces)
        return value.isEmpty ? nil : value
    }
}

public enum OpenAIStreamDelta: Sendable {
    private struct Chunk: Decodable {
        struct Choice: Decodable {
            struct Delta: Decodable {
                var content: String?
            }
            var delta: Delta?
        }
        struct Usage: Decodable {
            var promptTokens: Int?
            var completionTokens: Int?
            var totalTokens: Int?
            var promptTokensDetails: PromptDetails?
            var completionTokensDetails: CompletionDetails?

            enum CodingKeys: String, CodingKey {
                case promptTokens = "prompt_tokens"
                case completionTokens = "completion_tokens"
                case totalTokens = "total_tokens"
                case promptTokensDetails = "prompt_tokens_details"
                case completionTokensDetails = "completion_tokens_details"
            }

            struct PromptDetails: Decodable {
                var cachedTokens: Int?
                enum CodingKeys: String, CodingKey { case cachedTokens = "cached_tokens" }
            }
            struct CompletionDetails: Decodable {
                var reasoningTokens: Int?
                enum CodingKeys: String, CodingKey { case reasoningTokens = "reasoning_tokens" }
            }
        }

        var choices: [Choice]?
        var usage: Usage?
    }

    /// Only `choices[0].delta.content`. Reasoning fields are ignored by omission.
    public static func content(fromPayload payload: String) -> String? {
        if case .text(let text) = event(fromPayload: payload) { return text }
        return nil
    }

    public static func event(fromPayload payload: String) -> StreamEvent? {
        if payload == "[DONE]" { return nil }
        guard let data = payload.data(using: .utf8) else { return nil }
        guard let chunk = try? JSONDecoder().decode(Chunk.self, from: data) else { return nil }

        if let usage = chunk.usage {
            let prompt = usage.promptTokens ?? 0
            let completion = usage.completionTokens ?? 0
            let total = usage.totalTokens ?? (prompt + completion)
            return .usage(
                TokenUsage(
                    promptTokens: prompt,
                    completionTokens: completion,
                    reasoningTokens: usage.completionTokensDetails?.reasoningTokens ?? 0,
                    cachedPromptTokens: usage.promptTokensDetails?.cachedTokens ?? 0,
                    totalTokens: total
                )
            )
        }

        let text = chunk.choices?.first?.delta?.content
        if let text, !text.isEmpty {
            return .text(text)
        }
        return nil
    }
}

public enum AnthropicStreamDelta: Sendable {
    private struct Event: Decodable {
        var type: String?
        var delta: Delta?
        struct Delta: Decodable {
            var type: String?
            var text: String?
        }
    }

    public static func content(fromPayload payload: String) -> String? {
        guard let data = payload.data(using: .utf8) else { return nil }
        let event = try? JSONDecoder().decode(Event.self, from: data)
        guard event?.type == "content_block_delta" else { return nil }
        let text = event?.delta?.text
        if text == nil || text == "" { return nil }
        return text
    }
}

public enum GeminiStreamDelta: Sendable {
    private struct Event: Decodable {
        var candidates: [Candidate]?
        struct Candidate: Decodable {
            var content: Content?
        }
        struct Content: Decodable {
            var parts: [Part]?
        }
        struct Part: Decodable {
            var text: String?
        }
    }

    public static func content(fromPayload payload: String) -> String? {
        guard let data = payload.data(using: .utf8) else { return nil }
        let event = try? JSONDecoder().decode(Event.self, from: data)
        let text = event?.candidates?.first?.content?.parts?.first?.text
        if text == nil || text == "" { return nil }
        return text
    }
}
