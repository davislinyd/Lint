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

    public static func makeURLRequest(
        baseURL: URL,
        apiKey: String,
        request: ChatRequest
    ) throws -> URLRequest {
        guard let url = joiningPath(baseURL, "/chat/completions") else {
            throw LLMError.invalidURL
        }
        var urlRequest = URLRequest(url: url)
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
                        request: request
                    )
                    for try await payload in HTTPStream.ssePayloads(session: session, request: urlRequest) {
                        if let event = OpenAIStreamDelta.event(fromPayload: payload) {
                            continuation.yield(event)
                        }
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
