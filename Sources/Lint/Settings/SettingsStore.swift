import Foundation
import LintCore
import Observation

@MainActor
@Observable
final class SettingsStore {
    private enum Keys {
        static let provider = "app.lint.providerKind"
        static let customPrompt = "app.lint.customPrompt"
        static let translateTarget = "app.lint.translateTarget"
        static let lastMode = "app.lint.lastMode"
        static let reasoningEffort = "app.lint.reasoningEffort"
        static let autoSuggestOnSelection = "app.lint.autoSuggestOnSelection"
        static let liveWatchWhileTyping = "app.lint.liveWatchWhileTyping"
        static let showReadyChipNearField = "app.lint.showReadyChipNearField"
        static let fastMode = "app.lint.fastMode"
        static let localServerAutoStart = "app.lint.localServer.autoStart"
        static let localServerBinaryPath = "app.lint.localServer.binaryPath"
        static let localServerHFModel = "app.lint.localServer.hfModel"
        static let localServerPort = "app.lint.localServer.port"
        static let localServerExtraArgs = "app.lint.localServer.extraArgs"
        static let systemPromptOverrides = "app.lint.systemPromptOverrides"
        static func url(_ kind: ProviderKind) -> String { "app.lint.url.\(kind.rawValue)" }
        static func model(_ kind: ProviderKind) -> String { "app.lint.model.\(kind.rawValue)" }
    }

    private let defaults: UserDefaults
    let keychain: KeychainStore

    var providerKind: ProviderKind {
        didSet { defaults.set(providerKind.rawValue, forKey: Keys.provider) }
    }
    var baseURLString: String {
        didSet { defaults.set(baseURLString, forKey: Keys.url(providerKind)) }
    }
    var model: String {
        didSet { defaults.set(model, forKey: Keys.model(providerKind)) }
    }
    var customPrompt: String {
        didSet { defaults.set(customPrompt, forKey: Keys.customPrompt) }
    }
    /// Per-mode full system prompt overrides. Empty / missing → built-in default.
    var systemPromptOverrides: [String: String] {
        didSet { defaults.set(systemPromptOverrides, forKey: Keys.systemPromptOverrides) }
    }
    var translateTarget: String {
        didSet { defaults.set(translateTarget, forKey: Keys.translateTarget) }
    }
    var lastMode: WritingMode {
        didSet { defaults.set(lastMode.rawValue, forKey: Keys.lastMode) }
    }
    var reasoningEffort: ReasoningEffort {
        didSet { defaults.set(reasoningEffort.rawValue, forKey: Keys.reasoningEffort) }
    }
    var autoSuggestOnSelection: Bool {
        didSet { defaults.set(autoSuggestOnSelection, forKey: Keys.autoSuggestOnSelection) }
    }
    var liveWatchWhileTyping: Bool {
        didSet { defaults.set(liveWatchWhileTyping, forKey: Keys.liveWatchWhileTyping) }
    }
    /// When false, live-watch still prefetches but does not float a chip over the editor.
    var showReadyChipNearField: Bool {
        didSet { defaults.set(showReadyChipNearField, forKey: Keys.showReadyChipNearField) }
    }
    var fastMode: Bool {
        didSet { defaults.set(fastMode, forKey: Keys.fastMode) }
    }
    /// When using OpenAI-compatible localhost, launch llama-server if nothing is listening.
    var localServerAutoStart: Bool {
        didSet { defaults.set(localServerAutoStart, forKey: Keys.localServerAutoStart) }
    }
    var localServerBinaryPath: String {
        didSet { defaults.set(localServerBinaryPath, forKey: Keys.localServerBinaryPath) }
    }
    var localServerHFModel: String {
        didSet { defaults.set(localServerHFModel, forKey: Keys.localServerHFModel) }
    }
    var localServerPort: Int {
        didSet { defaults.set(localServerPort, forKey: Keys.localServerPort) }
    }
    var localServerExtraArgs: String {
        didSet { defaults.set(localServerExtraArgs, forKey: Keys.localServerExtraArgs) }
    }

    static let defaultLocalHFModel = "Qwen/Qwen2.5-7B-Instruct-GGUF:q4_k_m"
    static let defaultLocalServerExtraArgs =
        // M1/M2 writing assistant: full GPU offload + flash-attn; 4k ctx is enough for
        // proofreading and keeps KV cache lean (use 8192 if you often edit long docs).
        "--jinja --no-skip-chat-parsing -ngl 99 -fa on -c 4096 -np 1 -t 6"
    static let legacyDefaultLocalServerExtraArgs =
        "--jinja --no-skip-chat-parsing -ngl 99 -fa on -c 8192 -np 1 -t 4"
    static let defaultLocalServerBinary = "/opt/homebrew/bin/llama-server"
    var apiKeyDraft: String = ""
    var hasStoredKey: Bool = false

    init(keychain: KeychainStore, defaults: UserDefaults = .standard) {
        self.keychain = keychain
        self.defaults = defaults
        var kind = ProviderKind(rawValue: defaults.string(forKey: Keys.provider) ?? "") ?? .openaiCompatible
        if !kind.isEnabled {
            kind = .openaiCompatible
        }
        providerKind = kind
        customPrompt = defaults.string(forKey: Keys.customPrompt) ?? ""
        systemPromptOverrides =
            defaults.dictionary(forKey: Keys.systemPromptOverrides) as? [String: String] ?? [:]
        translateTarget = defaults.string(forKey: Keys.translateTarget) ?? "繁體中文"
        lastMode = WritingMode(rawValue: defaults.string(forKey: Keys.lastMode) ?? "") ?? .proofread
        reasoningEffort = ReasoningEffort(rawValue: defaults.string(forKey: Keys.reasoningEffort) ?? "") ?? .low
        if defaults.object(forKey: Keys.autoSuggestOnSelection) == nil {
            autoSuggestOnSelection = true
        } else {
            autoSuggestOnSelection = defaults.bool(forKey: Keys.autoSuggestOnSelection)
        }
        if defaults.object(forKey: Keys.liveWatchWhileTyping) == nil {
            liveWatchWhileTyping = true
        } else {
            liveWatchWhileTyping = defaults.bool(forKey: Keys.liveWatchWhileTyping)
        }
        if defaults.object(forKey: Keys.showReadyChipNearField) == nil {
            // Default off: floating chip over composers kept covering text on paste.
            showReadyChipNearField = false
        } else {
            showReadyChipNearField = defaults.bool(forKey: Keys.showReadyChipNearField)
        }
        if defaults.object(forKey: Keys.fastMode) == nil {
            fastMode = true
        } else {
            fastMode = defaults.bool(forKey: Keys.fastMode)
        }
        if defaults.object(forKey: Keys.localServerAutoStart) == nil {
            localServerAutoStart = true
        } else {
            localServerAutoStart = defaults.bool(forKey: Keys.localServerAutoStart)
        }
        localServerBinaryPath =
            defaults.string(forKey: Keys.localServerBinaryPath) ?? Self.defaultLocalServerBinary
        localServerHFModel =
            defaults.string(forKey: Keys.localServerHFModel) ?? Self.defaultLocalHFModel
        if defaults.object(forKey: Keys.localServerPort) == nil {
            localServerPort = 8000
        } else {
            localServerPort = defaults.integer(forKey: Keys.localServerPort)
        }
        var loadedExtraArgs =
            defaults.string(forKey: Keys.localServerExtraArgs) ?? Self.defaultLocalServerExtraArgs
        if loadedExtraArgs == Self.legacyDefaultLocalServerExtraArgs {
            loadedExtraArgs = Self.defaultLocalServerExtraArgs
        }
        localServerExtraArgs = loadedExtraArgs
        baseURLString = defaults.string(forKey: Keys.url(kind)) ?? kind.defaultBaseURL.absoluteString
        model = defaults.string(forKey: Keys.model(kind)) ?? kind.defaultModel
        if kind == .chatgptAccount, model == "auto" || model.isEmpty {
            model = ProviderKind.chatgptAccount.defaultModel
        }
        hasStoredKey = false
    }

    func selectProvider(_ kind: ProviderKind) {
        guard kind.isEnabled else { return }
        providerKind = kind
        baseURLString = defaults.string(forKey: Keys.url(kind)) ?? kind.defaultBaseURL.absoluteString
        model = defaults.string(forKey: Keys.model(kind)) ?? kind.defaultModel
        if kind == .chatgptAccount, model == "auto" || model.isEmpty {
            model = ProviderKind.chatgptAccount.defaultModel
        }
        apiKeyDraft = ""
        refreshKeyStatus()
    }

    func refreshKeyStatus() {
        let account = providerKind.keychainAccount
        let store = keychain
        Task.detached {
            let present = ((try? store.get(account: account))?.isEmpty == false)
            await MainActor.run {
                self.hasStoredKey = present
            }
        }
    }

    func saveAPIKeyIfNeeded() throws {
        let trimmed = apiKeyDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        try keychain.set(trimmed, account: providerKind.keychainAccount)
        apiKeyDraft = ""
        hasStoredKey = true
    }


    func defaultSystemPrompt(for mode: WritingMode) -> String {
        mode.systemPrompt(customPrompt: customPrompt, translateTarget: translateTarget)
    }

    func effectiveSystemPrompt(for mode: WritingMode) -> String {
        if let override = systemPromptOverrides[mode.rawValue] {
            let trimmed = override.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { return override }
        }
        return defaultSystemPrompt(for: mode)
    }

    func isSystemPromptOverridden(for mode: WritingMode) -> Bool {
        guard let override = systemPromptOverrides[mode.rawValue] else { return false }
        return !override.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    func setSystemPromptOverride(_ text: String, for mode: WritingMode) {
        var copy = systemPromptOverrides
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let builtIn = defaultSystemPrompt(for: mode)
        if trimmed.isEmpty || text == builtIn {
            copy.removeValue(forKey: mode.rawValue)
        } else {
            copy[mode.rawValue] = text
        }
        systemPromptOverrides = copy
    }

    func resetSystemPromptOverride(for mode: WritingMode) {
        var copy = systemPromptOverrides
        copy.removeValue(forKey: mode.rawValue)
        systemPromptOverrides = copy
    }

    /// OpenAI-compatible pointing at this Mac — eligible for managed llama-server.
    var wantsManagedLocalServer: Bool {
        guard providerKind == .openaiCompatible, localServerAutoStart else { return false }
        let host = baseURLString.lowercased()
        return host.contains("127.0.0.1") || host.contains("localhost")
    }

    func runtimeConfig() throws -> LLMRuntimeConfig {
        try saveAPIKeyIfNeeded()
        guard let url = URL(string: baseURLString.trimmingCharacters(in: .whitespacesAndNewlines)),
              url.scheme != nil
        else {
            throw LLMError.invalidURL
        }
        let key = (try keychain.get(account: providerKind.keychainAccount)) ?? ""
        if providerKind.requiresAPIKey && key.isEmpty {
            throw LLMError.emptyAPIKey
        }
        let modelName = model.trimmingCharacters(in: .whitespacesAndNewlines)
        return LLMRuntimeConfig(
            kind: providerKind,
            baseURL: url,
            model: modelName.isEmpty ? providerKind.defaultModel : modelName,
            apiKey: key
        )
    }
}
