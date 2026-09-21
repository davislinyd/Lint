import Foundation
import LintCore
import Observation

/// UI language. Bundles resolve their language from `AppleLanguages` once at launch,
/// so a change only takes effect after a restart.
enum AppLanguage: String, CaseIterable, Identifiable {
    case system
    case zhHant = "zh-Hant"
    case en

    var id: String { rawValue }

    /// nil → follow the system language.
    var languageCode: String? {
        self == .system ? nil : rawValue
    }
}

@MainActor
@Observable
final class SettingsStore {
    private enum Keys {
        static let provider = "app.lint.providerKind"
        static let appLanguage = "app.lint.appLanguage"
        static let customPrompt = "app.lint.customPrompt"
        static let translateTarget = "app.lint.translateTarget"
        static let lastMode = "app.lint.lastMode"
        static let reasoningEffort = "app.lint.reasoningEffort"
        static let autoSuggestOnSelection = "app.lint.autoSuggestOnSelection"
        static let liveWatchWhileTyping = "app.lint.liveWatchWhileTyping"
        static let showReadyChipNearField = "app.lint.showReadyChipNearField"
        static let fastMode = "app.lint.fastMode"
        static let learningEnabled = "app.lint.learning.enabled"
        static let localServerAutoStart = "app.lint.localServer.autoStart"
        static let localServerBinaryPath = "app.lint.localServer.binaryPath"
        static let localRuntimeSource = "app.lint.localServer.runtimeSource"
        static let migratedBundledRuntime = "app.lint.localServer.migratedBundledRuntime"
        static let localModelSource = "app.lint.localServer.modelSource"
        static let localManagedModelID = "app.lint.localServer.managedModelID"
        static let migratedManagedModel = "app.lint.localServer.migratedManagedModel"
        static let localAISetupDeferred = "app.lint.localAI.setupDeferred"
        /// Legacy: the `-hf` spec now lives in `model(.localLlama)`; only read by the migration.
        static let localServerHFModel = "app.lint.localServer.hfModel"
        static let migratedLocalLlama = "app.lint.migratedLocalLlama"
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
    var appLanguage: AppLanguage {
        didSet {
            defaults.set(appLanguage.rawValue, forKey: Keys.appLanguage)
            // `array(forKey: "AppleLanguages")` falls through to the system value, so the choice
            // is kept under our own key and only mirrored into the app domain here.
            if let code = appLanguage.languageCode {
                defaults.set([code], forKey: "AppleLanguages")
            } else {
                defaults.removeObject(forKey: "AppleLanguages")
            }
        }
    }
    /// The choice in effect for this run; differs from `appLanguage` once a restart is pending.
    let launchAppLanguage: AppLanguage
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
    /// Personalized learning is opt-in; while off, nothing is recorded and prompts are untouched.
    var learningEnabled: Bool {
        didSet { defaults.set(learningEnabled, forKey: Keys.learningEnabled) }
    }
    /// With the local llama.cpp provider, launch llama-server if nothing is listening.
    var localServerAutoStart: Bool {
        didSet { defaults.set(localServerAutoStart, forKey: Keys.localServerAutoStart) }
    }
    /// Automatic (Lint's bundled runtime) or a custom `llama-server` path.
    var localRuntimeSource: LocalRuntimeSource {
        didSet { defaults.set(localRuntimeSource.rawValue, forKey: Keys.localRuntimeSource) }
    }
    /// A model Lint downloads and verifies itself, or (advanced) a Hugging Face `-hf` spec.
    var localModelSource: LocalModelSource {
        didSet { defaults.set(localModelSource.rawValue, forKey: Keys.localModelSource) }
    }
    var localManagedModelID: String {
        didSet { defaults.set(localManagedModelID, forKey: Keys.localManagedModelID) }
    }
    /// The user chose "Later" on the first-run setup screen: do not open it by itself again.
    var localAISetupDeferred: Bool {
        didSet { defaults.set(localAISetupDeferred, forKey: Keys.localAISetupDeferred) }
    }
    /// Only used when `localRuntimeSource` is `.custom`.
    var localServerBinaryPath: String {
        didSet { defaults.set(localServerBinaryPath, forKey: Keys.localServerBinaryPath) }
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
    var apiKeyDraft: String = ""
    var hasStoredKey: Bool = false

    init(keychain: KeychainStore, defaults: UserDefaults = .standard) {
        self.keychain = keychain
        self.defaults = defaults
        if !defaults.bool(forKey: Keys.migratedLocalLlama) {
            Self.migrateToLocalLlama(defaults)
            defaults.set(true, forKey: Keys.migratedLocalLlama)
        }
        if !defaults.bool(forKey: Keys.migratedBundledRuntime) {
            Self.migrateToBundledRuntime(defaults)
            defaults.set(true, forKey: Keys.migratedBundledRuntime)
        }
        if !defaults.bool(forKey: Keys.migratedManagedModel) {
            Self.migrateToManagedModel(defaults)
            defaults.set(true, forKey: Keys.migratedManagedModel)
        }
        var kind = ProviderKind(rawValue: defaults.string(forKey: Keys.provider) ?? "") ?? .localLlama
        if !kind.isEnabled {
            kind = .localLlama
        }
        providerKind = kind
        let language = AppLanguage(rawValue: defaults.string(forKey: Keys.appLanguage) ?? "") ?? .system
        appLanguage = language
        launchAppLanguage = language
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
        learningEnabled = defaults.bool(forKey: Keys.learningEnabled)
        if defaults.object(forKey: Keys.localServerAutoStart) == nil {
            localServerAutoStart = true
        } else {
            localServerAutoStart = defaults.bool(forKey: Keys.localServerAutoStart)
        }
        localRuntimeSource =
            LocalRuntimeSource(rawValue: defaults.string(forKey: Keys.localRuntimeSource) ?? "") ?? .automatic
        localServerBinaryPath = defaults.string(forKey: Keys.localServerBinaryPath) ?? ""
        localAISetupDeferred = defaults.bool(forKey: Keys.localAISetupDeferred)
        localModelSource = LocalModelSource(rawValue: defaults.string(forKey: Keys.localModelSource) ?? "") ?? .managed
        localManagedModelID = defaults.string(forKey: Keys.localManagedModelID) ?? ModelCatalog.recommended.id
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

    /// Before `.localLlama` existed, "local" meant OpenAI-compatible pointing at our own llama-server port.
    private static func migrateToLocalLlama(_ defaults: UserDefaults) {
        let legacy = ProviderKind.openaiCompatible
        guard (defaults.string(forKey: Keys.provider) ?? legacy.rawValue) == legacy.rawValue else { return }
        let port = defaults.object(forKey: Keys.localServerPort) == nil
            ? 8000 : defaults.integer(forKey: Keys.localServerPort)
        let urlString = defaults.string(forKey: Keys.url(legacy)) ?? legacy.defaultBaseURL.absoluteString
        guard let url = URL(string: urlString),
              let host = url.host?.lowercased(),
              host == "127.0.0.1" || host == "localhost",
              (url.port ?? 80) == port
        else { return }
        defaults.set(ProviderKind.localLlama.rawValue, forKey: Keys.provider)
        defaults.set(
            defaults.string(forKey: Keys.localServerHFModel) ?? defaultLocalHFModel,
            forKey: Keys.model(.localLlama)
        )
    }

    /// Older versions stored the `llama-server` path they found (usually a Homebrew one). The
    /// known Homebrew defaults now mean "use Lint's own runtime"; any other path was chosen by the
    /// user and stays as a custom setting.
    private static func migrateToBundledRuntime(_ defaults: UserDefaults) {
        let migrated = LocalRuntimeMigration.migrate(storedBinaryPath: defaults.string(forKey: Keys.localServerBinaryPath))
        defaults.set(migrated.source.rawValue, forKey: Keys.localRuntimeSource)
        defaults.set(migrated.customPath, forKey: Keys.localServerBinaryPath)
    }

    /// Older versions had only the `-hf` spec. See `LocalModelMigration` for what happens to it.
    private static func migrateToManagedModel(_ defaults: UserDefaults) {
        let migrated = LocalModelMigration.migrate(
            storedSpec: defaults.string(forKey: Keys.model(.localLlama)),
            hasCompleteHuggingFaceCopy: { HuggingFaceCache.containsCompleteCopy(of: $0) }
        )
        defaults.set(migrated.source.rawValue, forKey: Keys.localModelSource)
        defaults.set(migrated.managedModelID, forKey: Keys.localManagedModelID)
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

    var learningConfig: LearningConfig {
        LearningConfig(enabled: learningEnabled)
    }

    /// Local llama.cpp provider — Lint launches and talks to its own llama-server.
    var wantsManagedLocalServer: Bool {
        providerKind == .localLlama && localServerAutoStart
    }

    /// The local server's settings as plain values. The `-hf` spec is the `.localLlama` provider's model field.
    var localAIConfiguration: LocalAIConfiguration {
        LocalAIConfiguration(
            runtimeSource: localRuntimeSource,
            customBinaryPath: localServerBinaryPath,
            modelSource: localModelSource,
            managedModel: ModelCatalog.descriptor(id: localManagedModelID) ?? ModelCatalog.recommended,
            huggingFaceSpec: defaults.string(forKey: Keys.model(.localLlama)) ?? Self.defaultLocalHFModel,
            port: localServerPort,
            extraArguments: localServerExtraArgs,
            autoStart: localServerAutoStart
        )
    }

    func runtimeConfig() throws -> LLMRuntimeConfig {
        try saveAPIKeyIfNeeded()
        let urlString = providerKind == .localLlama
            ? "http://127.0.0.1:\(localServerPort)/v1"
            : baseURLString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: urlString),
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
