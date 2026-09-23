import Foundation

public struct LLMRuntimeConfig: Sendable {
    public var kind: ProviderKind
    public var baseURL: URL
    public var model: String
    public var apiKey: String

    public init(kind: ProviderKind, baseURL: URL, model: String, apiKey: String) {
        self.kind = kind
        self.baseURL = baseURL
        self.model = model
        self.apiKey = apiKey
    }
}

public struct LLMService: Sendable {
    public init() {}

    public func provider(for config: LLMRuntimeConfig) throws -> any LLMProvider {
        if config.kind.requiresAPIKey && config.apiKey.isEmpty {
            throw LLMError.emptyAPIKey
        }
        switch config.kind {
        case .automatic:
            // A choice to be resolved (`WritingEngineRouter`), not something to send a request to.
            throw LLMError.unresolvedProvider
        case .appleIntelligence:
            return AppleFoundationModelProvider()
        case .openai, .openaiCompatible, .localLlama:
            return OpenAICompatibleProvider(
                id: config.kind,
                baseURL: config.baseURL,
                apiKey: config.apiKey
            )
        case .anthropic:
            return AnthropicProvider(baseURL: config.baseURL, apiKey: config.apiKey)
        case .gemini:
            return GeminiProvider(baseURL: config.baseURL, apiKey: config.apiKey)
        case .chatgptAccount:
            if config.apiKey.isEmpty {
                throw LLMError.notLoggedInToChatGPT
            }
            return ChatGPTAccountProvider(accessToken: config.apiKey, model: config.model)
        }
    }

    public func stream(config: LLMRuntimeConfig, request: ChatRequest) throws -> AsyncThrowingStream<StreamEvent, Error> {
        try provider(for: config).stream(request)
    }
}
