import Foundation

public struct AnthropicProvider: LLMProvider {
    public let id: ProviderKind = .anthropic
    public let baseURL: URL
    public let apiKey: String
    public let session: URLSession

    public init(baseURL: URL, apiKey: String, session: URLSession = .shared) {
        self.baseURL = baseURL
        self.apiKey = apiKey
        self.session = session
    }

    public static func makeURLRequest(
        baseURL: URL,
        apiKey: String,
        request: ChatRequest
    ) throws -> URLRequest {
        if apiKey.isEmpty { throw LLMError.emptyAPIKey }
        guard let url = joiningPath(baseURL, "/v1/messages") else {
            throw LLMError.invalidURL
        }
        var urlRequest = URLRequest(url: url)
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        urlRequest.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        let body: [String: Any] = [
            "model": request.model,
            "max_tokens": request.maxTokens,
            "stream": true,
            "system": request.systemPrompt,
            "messages": [
                ["role": "user", "content": request.userText]
            ]
        ]
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
                        if let content = AnthropicStreamDelta.content(fromPayload: payload) {
                            continuation.yield(.text(content))
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
