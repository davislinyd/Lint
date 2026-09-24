import Foundation

public enum ProviderKind: String, Codable, CaseIterable, Sendable, Identifiable {
    /// Not a provider of its own: Apple Intelligence when it is available, otherwise Lint's local AI
    /// if that is already set up (see `WritingEngineRouter`). Never passed to `LLMService`.
    case automatic
    /// Apple's on-device `SystemLanguageModel` (Foundation Models). Nothing leaves the Mac.
    case appleIntelligence
    case openai
    case localLlama
    case openaiCompatible
    case anthropic
    case gemini
    case chatgptAccount

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .automatic: String(localized: "自動")
        case .appleIntelligence: "Apple Intelligence"
        case .openai: "OpenAI"
        case .localLlama: String(localized: "本機 llama.cpp（由 Lint 管理）")
        case .openaiCompatible: String(localized: "OpenAI 相容端點（Ollama / LM Studio / 自訂）")
        case .anthropic: "Anthropic"
        case .gemini: "Google Gemini"
        case .chatgptAccount: String(localized: "ChatGPT（Plus／Pro 登入）")
        }
    }

    public var keychainAccount: String { rawValue }

    public var defaultBaseURL: URL {
        switch self {
        case .automatic, .appleIntelligence:
            // Only there because every configuration has a URL; nothing is ever sent to it.
            URL(string: "lint-on-device://apple-intelligence")!
        case .openai:
            URL(string: "https://api.openai.com/v1")!
        case .localLlama, .openaiCompatible:
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
        case .automatic, .appleIntelligence: "SystemLanguageModel"
        case .openai: "gpt-4o"
        case .localLlama, .openaiCompatible: ModelCatalog.recommended.huggingFaceSpec
        case .anthropic: "claude-3-5-sonnet-latest"
        case .gemini: "gemini-2.0-flash"
        case .chatgptAccount: "gpt-5.6-luna"
        }
    }

    public var requiresAPIKey: Bool {
        switch self {
        case .automatic, .appleIntelligence, .localLlama, .openaiCompatible, .chatgptAccount:
            return false
        default:
            return true
        }
    }

    /// Uses ChatGPT website session (access token in Keychain) instead of an API key field.
    public var usesChatGPTLogin: Bool {
        self == .chatgptAccount
    }

    /// Unavailable providers stay listed but cannot be selected.
    public var isEnabled: Bool {
        switch self {
        case .chatgptAccount, .openai, .anthropic, .gemini:
            return false
        default:
            return true
        }
    }

    public var pickerLabel: String {
        if isEnabled { return title }
        switch self {
        case .chatgptAccount: return String(localized: "\(title)（暫時關閉）")
        default: return String(localized: "\(title)（尚未測試）")
        }
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
        case .luna: String(localized: "GPT-5.6 Luna（預設）")
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
        case .low: String(localized: "Low（較快）")
        case .medium: "Medium"
        case .high: String(localized: "High（較慢）")
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
    /// Sampling temperature for OpenAI-compatible endpoints. Nil omits the field, so the server's own default applies.
    public var temperature: Double?
    /// Prefer Fast mode / priority tier when the backend supports it.
    public var fastMode: Bool
    /// The request rewrites the user's own text (proofread, translate, tone). A provider with a
    /// safety mode made for transforming content may use it; nothing else reads this.
    public var transformsUserText: Bool

    public init(
        model: String,
        systemPrompt: String,
        userText: String,
        maxTokens: Int = 4096,
        reasoningEffort: ReasoningEffort? = .low,
        temperature: Double? = nil,
        fastMode: Bool = true,
        transformsUserText: Bool = false
    ) {
        self.model = model
        self.systemPrompt = systemPrompt
        self.userText = userText
        self.maxTokens = maxTokens
        self.reasoningEffort = reasoningEffort
        self.temperature = temperature
        self.fastMode = fastMode
        self.transformsUserText = transformsUserText
    }
}

public enum LLMError: Error, LocalizedError, Sendable {
    case invalidURL
    case emptyAPIKey
    case notLoggedInToChatGPT
    case httpStatus(Int, String)
    case decoding
    case unresolvedProvider

    public var errorDescription: String? {
        switch self {
        case .invalidURL:
            String(localized: "API URL 無效")
        case .emptyAPIKey:
            String(localized: "尚未設定 API Key")
        case .notLoggedInToChatGPT:
            String(localized: "請先在設定中登入 ChatGPT（Plus／Pro）")
        case .httpStatus(let code, let body):
            // llama-server's own words for "the prompt does not fit" are raw JSON; the text is
            // never cut short, so say what happened and what to do about it.
            body.contains("exceed_context_size_error")
                ? String(localized: "這段文字對本機 AI 來說太長了。請分段處理，或在「設定 → 模型 → 進階」的額外參數加上較大的 -c（例如 -c 8192）後重新啟動。")
                : String(localized: "HTTP \(code)：\(body)")
        case .decoding:
            String(localized: "無法解析模型回應")
        case .unresolvedProvider:
            String(localized: "尚未決定要用哪個 AI 引擎")
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

