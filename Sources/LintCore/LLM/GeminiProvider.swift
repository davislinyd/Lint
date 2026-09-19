import Foundation

public struct GeminiProvider: LLMProvider {
    public let id: ProviderKind = .gemini
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
        let path = "/models/\(request.model):streamGenerateContent"
        guard var url = joiningPath(baseURL, path) else {
            throw LLMError.invalidURL
        }
        var items = URLComponents(url: url, resolvingAgainstBaseURL: false)
        items?.queryItems = [
            URLQueryItem(name: "alt", value: "sse"),
            URLQueryItem(name: "key", value: apiKey)
        ]
        guard let finalURL = items?.url else { throw LLMError.invalidURL }
        url = finalURL
        var urlRequest = URLRequest(url: url)
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let body: [String: Any] = [
            "system_instruction": [
                "parts": [["text": request.systemPrompt]]
            ],
            "contents": [
                [
                    "role": "user",
                    "parts": [["text": request.userText]]
                ]
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
                        if let content = GeminiStreamDelta.content(fromPayload: payload) {
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
