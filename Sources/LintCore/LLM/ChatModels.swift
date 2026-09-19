import Foundation

public enum ProviderKind: String, Codable, CaseIterable, Sendable, Identifiable {
    case openai
    case openaiCompatible
    case anthropic
    case gemini
    case chatgptAccount

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .openai: "OpenAI"
        case .openaiCompatible: "OpenAI 相容（本機 Qwen / Ollama / LM Studio）"
        case .anthropic: "Anthropic"
        case .gemini: "Google Gemini"
        case .chatgptAccount: "ChatGPT（Plus／Pro 登入）"
        }
    }

    public var keychainAccount: String { rawValue }

    public var defaultBaseURL: URL {
        switch self {
        case .openai:
            URL(string: "https://api.openai.com/v1")!
        case .openaiCompatible:
            URL(string: "http://127.0.0.1:8000/v1")!
        case .anthropic:
            URL(string: "https://api.anthropic.com")!
        case .gemini:
            URL(string: "https://generativelanguage.googleapis.com/v1beta")!
        case .chatgptAccount:
            URL(string: "https://chatgpt.com")!
        }
    }

    public var defaultModel: String {
        switch self {
        case .openai: "gpt-4o"
        case .openaiCompatible: "Qwen/Qwen2.5-7B-Instruct-GGUF:q4_k_m"
        case .anthropic: "claude-3-5-sonnet-latest"
        case .gemini: "gemini-2.0-flash"
        case .chatgptAccount: "gpt-5.6-luna"
        }
    }

    public var requiresAPIKey: Bool {
        switch self {
        case .openaiCompatible, .chatgptAccount:
            return false
        default:
            return true
        }
    }

    /// Uses ChatGPT website session (access token in Keychain) instead of an API key field.
    public var usesChatGPTLogin: Bool {
        self == .chatgptAccount
    }

    /// Temporarily unavailable providers stay listed but cannot be selected.
    public var isEnabled: Bool {
        switch self {
        case .chatgptAccount:
            return false
        default:
            return true
        }
    }

    public var pickerLabel: String {
        if isEnabled { return title }
        return "\(title)（暫時關閉）"
    }
}


public enum ChatGPTModelOption: String, CaseIterable, Sendable, Identifiable {
    case luna = "gpt-5.6-luna"
    case terra = "gpt-5.6-terra"
    case sol = "gpt-5.6-sol"
    case auto = "auto"

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .luna: "GPT-5.6 Luna（預設）"
        case .terra: "GPT-5.6 Terra"
        case .sol: "GPT-5.6 Sol"
        case .auto: "Auto"
        }
    }

    public static func matching(_ raw: String) -> ChatGPTModelOption? {
        allCases.first { $0.rawValue == raw }
    }
}

public enum ReasoningEffort: String, Codable, CaseIterable, Sendable, Identifiable {
    case low
    case medium
    case high

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .low: "Low（較快）"
        case .medium: "Medium"
        case .high: "High（較慢）"
        }
    }
}

public struct ChatRequest: Sendable {
    public var model: String
    public var systemPrompt: String
    public var userText: String
    public var maxTokens: Int
    /// OpenAI-compatible `reasoning_effort`. Nil omits the field.
    public var reasoningEffort: ReasoningEffort?
    /// Prefer Fast mode / priority tier when the backend supports it.
    public var fastMode: Bool

    public init(
        model: String,
        systemPrompt: String,
        userText: String,
        maxTokens: Int = 4096,
        reasoningEffort: ReasoningEffort? = .low,
        fastMode: Bool = true
    ) {
        self.model = model
        self.systemPrompt = systemPrompt
        self.userText = userText
        self.maxTokens = maxTokens
        self.reasoningEffort = reasoningEffort
        self.fastMode = fastMode
    }
}

public enum LLMError: Error, LocalizedError, Sendable {
    case invalidURL
    case emptyAPIKey
    case notLoggedInToChatGPT
    case httpStatus(Int, String)
    case decoding

    public var errorDescription: String? {
        switch self {
        case .invalidURL:
            "API URL 無效"
        case .emptyAPIKey:
            "尚未設定 API Key"
        case .notLoggedInToChatGPT:
            "請先在設定中登入 ChatGPT（Plus／Pro）"
        case .httpStatus(let code, let body):
            "HTTP \(code)：\(body)"
        case .decoding:
            "無法解析模型回應"
        }
    }
}

public func joiningPath(_ base: URL, _ path: String) -> URL? {
    var raw = base.absoluteString
    while raw.hasSuffix("/") {
        raw.removeLast()
    }
    let suffix = path.hasPrefix("/") ? path : "/" + path
    return URL(string: raw + suffix)
}

public struct TokenUsage: Sendable, Equatable {
    public var promptTokens: Int
    public var completionTokens: Int
    public var reasoningTokens: Int
    public var cachedPromptTokens: Int
    public var totalTokens: Int

    public init(
        promptTokens: Int,
        completionTokens: Int,
        reasoningTokens: Int = 0,
        cachedPromptTokens: Int = 0,
        totalTokens: Int
    ) {
        self.promptTokens = promptTokens
        self.completionTokens = completionTokens
        self.reasoningTokens = reasoningTokens
        self.cachedPromptTokens = cachedPromptTokens
        self.totalTokens = totalTokens
    }

    public var summary: String {
        var parts = ["prompt \(promptTokens)"]
        if reasoningTokens > 0 {
            parts.append("reasoning \(reasoningTokens)")
        }
        parts.append("completion \(completionTokens)")
        if cachedPromptTokens > 0 {
            parts.append("cached \(cachedPromptTokens)")
        }
        parts.append("total \(totalTokens)")
        return parts.joined(separator: " · ")
    }
}

public enum StreamEvent: Sendable, Equatable {
    case text(String)
    case usage(TokenUsage)
}

