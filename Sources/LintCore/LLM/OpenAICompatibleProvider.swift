import Foundation

public struct OpenAICompatibleProvider: LLMProvider {
    public let id: ProviderKind
    public let baseURL: URL
    public let apiKey: String
    public let session: URLSession

    public init(
        id: ProviderKind = .openaiCompatible,
        baseURL: URL,
        apiKey: String,
        session: URLSession = .shared
    ) {
        self.id = id
        self.baseURL = baseURL
        self.apiKey = apiKey
        self.session = session
    }

    /// A local llama-server may have released the model's memory while idle, and loads it again
    /// before the first token arrives — seconds for a small model, longer for a large one on a busy
    /// Mac. That silence must not be read as a dead connection, so the loopback provider waits.
    public static let localRequestTimeout: TimeInterval = 300

    public static func makeURLRequest(
        baseURL: URL,
        apiKey: String,
        request: ChatRequest,
        timeout: TimeInterval? = nil
    ) throws -> URLRequest {
        guard let url = joiningPath(baseURL, "/chat/completions") else {
            throw LLMError.invalidURL
        }
        var urlRequest = URLRequest(url: url)
        if let timeout { urlRequest.timeoutInterval = timeout }
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if !apiKey.isEmpty {
            urlRequest.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        }
        var body: [String: Any] = [
            "model": request.model,
            "stream": true,
            "stream_options": ["include_usage": true],
            "max_tokens": request.maxTokens,
            "messages": [
                ["role": "system", "content": request.systemPrompt],
                ["role": "user", "content": request.userText]
            ]
        ]
        if let effort = request.reasoningEffort {
            body["reasoning_effort"] = effort.rawValue
        }
        if let temperature = request.temperature {
            body["temperature"] = temperature
        }
        urlRequest.httpBody = try JSONSerialization.data(withJSONObject: body)
        return urlRequest
    }

    public func stream(_ request: ChatRequest) -> AsyncThrowingStream<StreamEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let urlRequest = try Self.makeURLRequest(
                        baseURL: baseURL,
                        apiKey: apiKey,
                        request: request,
                        timeout: id == .localLlama ? Self.localRequestTimeout : nil
                    )
                    var finished = false
                    var stoppedAtLength = false
                    for try await payload in HTTPStream.ssePayloads(session: session, request: urlRequest) {
                        if id == .localLlama, let reason = OpenAIStreamDelta.finishReason(fromPayload: payload) {
                            finished = true
                            stoppedAtLength = reason == "length"
                        }
                        if let event = OpenAIStreamDelta.event(fromPayload: payload) {
                            continuation.yield(event)
                            // llama-server says "length" both when the context is full and when
                            // `max_tokens` is reached; only the usage that follows tells them apart.
                            if stoppedAtLength, case .usage(let usage) = event, usage.completionTokens < request.maxTokens {
                                throw LLMError.contextExhausted
                            }
                        }
                    }
                    // llama-server always ends an answer with a finish_reason. A connection that ends
                    // without one (the server quit mid-answer) leaves a cut-off text, not an answer.
                    if id == .localLlama, !finished, !Task.isCancelled {
                        throw LLMError.replyInterrupted
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}
