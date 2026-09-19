import Foundation

public struct ChatGPTCompletionRequest: Sendable {
    public var accessToken: String
    public var model: String
    public var systemPrompt: String
    public var userText: String
    public var reasoningEffort: ReasoningEffort?
    public var fastMode: Bool

    public init(
        accessToken: String,
        model: String,
        systemPrompt: String,
        userText: String,
        reasoningEffort: ReasoningEffort?,
        fastMode: Bool
    ) {
        self.accessToken = accessToken
        self.model = model
        self.systemPrompt = systemPrompt
        self.userText = userText
        self.reasoningEffort = reasoningEffort
        self.fastMode = fastMode
    }
}

/// App-side WKWebView backend (same cookie jar / TLS fingerprint as login).
public protocol ChatGPTBrowserBackend: AnyObject {
    func complete(_ request: ChatGPTCompletionRequest) async throws -> String
}

/// Registered by the app at launch. Provider prefers this over raw URLSession.
public final class ChatGPTBrowserBackendRegistry: @unchecked Sendable {
    public static let shared = ChatGPTBrowserBackendRegistry()
    public weak var backend: ChatGPTBrowserBackend?
    private init() {}
}
