import Foundation
import LintCore
import Observation

/// UI language. Bundles resolve their language from `AppleLanguages` once at launch,
/// so a change only takes effect after a restart.
/// Declared in the menu's order: the system first, then the English names alphabetically.
enum AppLanguage: String, CaseIterable, Identifiable {
    case system
    case en
    case indonesian = "id"
    case ja
    case ko
    case ptBR = "pt-BR"
    case zhHans = "zh-Hans"
    case th
    case zhHant = "zh-Hant"
    case vi

    var id: String { rawValue }

    /// nil → follow the system language.
    var languageCode: String? {
        self == .system ? nil : rawValue
    }

    /// What the menu calls it, in English whatever the interface language; nil for `system`.
    var englishName: String? {
        switch self {
        case .system: nil
        case .en: "English"
        case .indonesian: "Indonesian"
        case .ja: "Japanese"
        case .ko: "Korean"
        case .ptBR: "Portuguese (Brazil)"
        case .zhHans: "Simplified Chinese"
        case .th: "Thai"
        case .zhHant: "Traditional Chinese"
        case .vi: "Vietnamese"
        }
    }
}

@MainActor
@Observable
final class SettingsStore {
    private enum Keys {
        static let provider = "app.lint.providerKind"
        static let appLanguage = "app.lint.appLanguage"
        static let translationLanguage = "app.lint.translationLanguage"
        static let customPrompt = "app.lint.customPrompt"
        static let lastMode = "app.lint.lastMode"
        static let proofreadTone = "app.lint.lastTone.proofread"
        static let translateTone = "app.lint.lastTone.translate"
        static let reasoningEffort = "app.lint.reasoningEffort"
        static let autoSuggestOnSelection = "app.lint.autoSuggestOnSelection"
        static let liveWatchWhileTyping = "app.lint.liveWatchWhileTyping"
        static let showReadyChipNearField = "app.lint.showReadyChipNearField"
        static let fastMode = "app.lint.fastMode"
        /// On-disk key. The name stays so a switch that is already on stays on.
        static let memoryEnabled = "app.lint.learning.enabled"
        static let localServerAutoStart = "app.lint.localServer.autoStart"
        static let localServerBinaryPath = "app.lint.localServer.binaryPath"
        static let localRuntimeSource = "app.lint.localServer.runtimeSource"
        static let migratedBundledRuntime = "app.lint.localServer.migratedBundledRuntime"
        static let localModelSource = "app.lint.localServer.modelSource"
        static let localManagedModelID = "app.lint.localServer.managedModelID"
        static let migratedManagedModel = "app.lint.localServer.migratedManagedModel"
        static let migratedOffRetiredDefault = "app.lint.localServer.migratedOffRetiredDefault"
        static let migratedWritingTone = "app.lint.migratedWritingTone"
        static let migratedWritingEngine = "app.lint.migratedWritingEngine"
        static let localAISetupDeferred = "app.lint.localAI.setupDeferred"
        /// Legacy: the `-hf` spec now lives in `model(.localLlama)`; only read by the migration.
        static let localServerHFModel = "app.lint.localServer.hfModel"
        static let migratedLocalLlama = "app.lint.migratedLocalLlama"
        static let localServerPort = "app.lint.localServer.port"
        static let localServerExtraArgs = "app.lint.localServer.extraArgs"
        static let localServerIdleSleep = "app.lint.localServer.idleSleepSeconds"
        static let updateMode = "app.lint.update.mode"
        static let updateFrequency = "app.lint.update.frequency"
        static let migratedManagedTuning = "app.lint.localServer.migratedManagedTuning"
        static let migratedUninstalledDefault = "app.lint.localServer.migratedUninstalledDefault"
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
    /// What a translation and the reading aid under a suggestion are written in.
    var translationLanguage: TranslationLanguage {
        didSet { defaults.set(translationLanguage.rawValue, forKey: Keys.translationLanguage) }
    }
    /// Full system prompt overrides, one per mode and tone (`WritingPromptComposer.overrideKey`).
    /// Empty / missing → built-in default.
    var systemPromptOverrides: [String: String] {
        didSet { defaults.set(systemPromptOverrides, forKey: Keys.systemPromptOverrides) }
    }
    var lastMode: WritingMode {
        didSet { defaults.set(lastMode.rawValue, forKey: Keys.lastMode) }
    }
    /// The tone each task remembers for itself; a custom prompt has none.
    var tones: WritingToneMemory {
        didSet {
            defaults.set(tones.tone(for: .proofread).rawValue, forKey: Keys.proofreadTone)
            defaults.set(tones.tone(for: .translate).rawValue, forKey: Keys.translateTone)
        }
    }
    var reasoningEffort: ReasoningEffort {
        didSet { defaults.set(reasoningEffort.rawValue, forKey: Keys.reasoningEffort) }
    }
    var autoSuggestOnSelection: Bool {
        didSet {
            defaults.set(autoSuggestOnSelection, forKey: Keys.autoSuggestOnSelection)
            onCaptureWatchChanged?()
        }
    }
    var liveWatchWhileTyping: Bool {
        didSet {
            defaults.set(liveWatchWhileTyping, forKey: Keys.liveWatchWhileTyping)
            onCaptureWatchChanged?()
        }
    }
    /// When false, live-watch still prefetches but does not float a chip over the editor.
    var showReadyChipNearField: Bool {
        didSet { defaults.set(showReadyChipNearField, forKey: Keys.showReadyChipNearField) }
    }
    var fastMode: Bool {
        didSet { defaults.set(fastMode, forKey: Keys.fastMode) }
    }
    /// Memory is opt-in; while off, nothing is recorded and prompts are untouched.
    var memoryEnabled: Bool {
        didSet { defaults.set(memoryEnabled, forKey: Keys.memoryEnabled) }
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
    /// Only what the user typed. Lint's own tuning is not in here any more (see
    /// `LlamaServerLaunchPlan`); whatever is set here overrides it.
    var localServerExtraArgs: String {
        didSet { defaults.set(localServerExtraArgs, forKey: Keys.localServerExtraArgs) }
    }
    /// After this long with no suggestion, llama-server releases the model's memory. The process
    /// stays up; the next suggestion loads the model again.
    var localServerIdleSleep: IdleSleepOption {
        didSet { defaults.set(localServerIdleSleep.seconds, forKey: Keys.localServerIdleSleep) }
    }
    /// What to do when GitHub has a newer release, and how often to look.
    var updateMode: UpdateMode {
        didSet {
            defaults.set(updateMode.rawValue, forKey: Keys.updateMode)
            onUpdatePreferenceChanged?()
        }
    }
    var updateFrequency: UpdateCheckFrequency {
        didSet {
            defaults.set(updateFrequency.rawValue, forKey: Keys.updateFrequency)
            onUpdatePreferenceChanged?()
        }
    }
    /// Set by the app after init. `didSet` above does not run while this store is being created.
    var onUpdatePreferenceChanged: (() -> Void)?
    /// Start or stop background Accessibility polling when a watch toggle changes.
    var onCaptureWatchChanged: (() -> Void)?

    static let defaultLocalHFModel = ModelCatalog.recommended.huggingFaceSpec
    var apiKeyDraft: String = ""
    var hasStoredKey: Bool = false

    init(keychain: KeychainStore, defaults: UserDefaults = .standard) {
        self.keychain = keychain
        self.defaults = defaults
        // First, before any other migration writes a setting: afterwards every install looks old.
        if !defaults.bool(forKey: Keys.migratedWritingEngine) {
            Self.migrateToWritingEngine(defaults)
            defaults.set(true, forKey: Keys.migratedWritingEngine)
        }
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
        if !defaults.bool(forKey: Keys.migratedOffRetiredDefault) {
            Self.migrateOffRetiredDefault(defaults)
            defaults.set(true, forKey: Keys.migratedOffRetiredDefault)
        }
        if !defaults.bool(forKey: Keys.migratedUninstalledDefault) {
            Self.migrateUninstalledPreviousDefault(defaults)
            defaults.set(true, forKey: Keys.migratedUninstalledDefault)
        }
        if !defaults.bool(forKey: Keys.migratedManagedTuning) {
            Self.migrateToManagedTuning(defaults)
            defaults.set(true, forKey: Keys.migratedManagedTuning)
        }
        if !defaults.bool(forKey: Keys.migratedWritingTone) {
            Self.migrateToWritingTone(defaults)
            defaults.set(true, forKey: Keys.migratedWritingTone)
        }
        var kind = ProviderKind(rawValue: defaults.string(forKey: Keys.provider) ?? "") ?? .localLlama
        if !kind.isEnabled {
            kind = .localLlama
        }
        providerKind = kind
        let language = AppLanguage(rawValue: defaults.string(forKey: Keys.appLanguage) ?? "") ?? .system
        appLanguage = language
        launchAppLanguage = language
        translationLanguage = TranslationLanguage(rawValue: defaults.string(forKey: Keys.translationLanguage) ?? "")
            ?? .traditionalChinese
        customPrompt = defaults.string(forKey: Keys.customPrompt) ?? ""
        systemPromptOverrides =
            defaults.dictionary(forKey: Keys.systemPromptOverrides) as? [String: String] ?? [:]
        lastMode = LegacyWritingMode.resolve(defaults.string(forKey: Keys.lastMode) ?? "")?.mode ?? .proofread
        tones = WritingToneMemory(
            proofread: WritingTone(rawValue: defaults.string(forKey: Keys.proofreadTone) ?? "") ?? .preserve,
            translate: WritingTone(rawValue: defaults.string(forKey: Keys.translateTone) ?? "") ?? .preserve
        )
        reasoningEffort = ReasoningEffort(rawValue: defaults.string(forKey: Keys.reasoningEffort) ?? "") ?? .low
        if defaults.object(forKey: Keys.autoSuggestOnSelection) == nil {
            autoSuggestOnSelection = true
        } else {
            autoSuggestOnSelection = defaults.bool(forKey: Keys.autoSuggestOnSelection)
        }
        // The observer does not run in init, so a missing key was never toggled. Off.
        // A stored bool is the user's choice and stays.
        liveWatchWhileTyping = LiveCheckPolicy.enabledValue(
            stored: defaults.object(forKey: Keys.liveWatchWhileTyping) == nil
                ? nil
                : defaults.bool(forKey: Keys.liveWatchWhileTyping)
        )
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
        memoryEnabled = defaults.bool(forKey: Keys.memoryEnabled)
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
        localManagedModelID = ModelCatalog.resolveManagedModelID(defaults.string(forKey: Keys.localManagedModelID))
        if defaults.object(forKey: Keys.localServerPort) == nil {
            localServerPort = 8000
        } else {
            localServerPort = defaults.integer(forKey: Keys.localServerPort)
        }
        localServerExtraArgs = defaults.string(forKey: Keys.localServerExtraArgs) ?? ""
        localServerIdleSleep = IdleSleepOption.resolve(
            defaults.object(forKey: Keys.localServerIdleSleep) == nil
                ? nil : defaults.integer(forKey: Keys.localServerIdleSleep)
        )
        updateMode = UpdateMode(rawValue: defaults.string(forKey: Keys.updateMode) ?? "") ?? .manual
        updateFrequency = UpdateCheckFrequency(rawValue: defaults.string(forKey: Keys.updateFrequency) ?? "") ?? .weekly
        baseURLString = defaults.string(forKey: Keys.url(kind)) ?? kind.defaultBaseURL.absoluteString
        model = defaults.string(forKey: Keys.model(kind)) ?? kind.defaultModel
        if kind == .chatgptAccount, model == "auto" || model.isEmpty {
            model = ProviderKind.chatgptAccount.defaultModel
        }
        hasStoredKey = false
    }

    /// Apple Intelligence and Automatic arrived with this version. Whoever already had a setting keeps
    /// it; only a new install gets `WritingEngineMigration.newInstallDefault`.
    private static func migrateToWritingEngine(_ defaults: UserDefaults) {
        let isNewInstall = !defaults.dictionaryRepresentation().keys.contains { $0.hasPrefix("app.lint.") }
        if let kind = WritingEngineMigration.migrate(
            storedProvider: defaults.string(forKey: Keys.provider), isNewInstall: isNewInstall
        ) {
            defaults.set(kind.rawValue, forKey: Keys.provider)
        }
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

    /// The Qwen default was replaced by Gemma 4: a setting still pointing at it moves to the managed model.
    private static func migrateOffRetiredDefault(_ defaults: UserDefaults) {
        guard LocalModelMigration.isRetiredDefault(defaults.string(forKey: Keys.model(.localLlama))) else { return }
        defaults.set(LocalModelSource.managed.rawValue, forKey: Keys.localModelSource)
        defaults.set(ModelCatalog.recommended.id, forKey: Keys.localManagedModelID)
        defaults.removeObject(forKey: Keys.model(.localLlama))
    }

    /// Gemma 4 E4B replaced Gemma 4 12B as the default. An install that never downloaded 12B only had
    /// it stored as the old default, so it moves to the new one; one that has 12B on disk keeps it
    /// (see `LocalModelMigration.migrateUninstalledPreviousDefault`). Nothing is downloaded.
    private static func migrateUninstalledPreviousDefault(_ defaults: UserDefaults) {
        let source = LocalModelSource(rawValue: defaults.string(forKey: Keys.localModelSource) ?? "") ?? .managed
        let models = LocalModelManager()
        if let id = LocalModelMigration.migrateUninstalledPreviousDefault(
            storedID: defaults.string(forKey: Keys.localManagedModelID),
            source: source,
            hasLocalCopy: { models.hasLocalCopy(of: $0) }
        ) {
            defaults.set(id, forKey: Keys.localManagedModelID)
        }
    }

    /// Lint's tuning used to live in the one "extra arguments" string, which every install has a
    /// copy of. It now comes from the model's runtime profile, so a stored copy of an old built-in
    /// default is cleared and a string the user typed is left alone.
    private static func migrateToManagedTuning(_ defaults: UserDefaults) {
        let migrated = LocalServerArgumentsMigration.migrate(stored: defaults.string(forKey: Keys.localServerExtraArgs))
        defaults.set(migrated, forKey: Keys.localServerExtraArgs)
    }

    /// Tone used to be three modes of its own. What was stored as one becomes proofreading in that tone,
    /// and the prompt overrides follow (see `WritingSettingsMigration`). A tone that is already set is
    /// not overwritten.
    private static func migrateToWritingTone(_ defaults: UserDefaults) {
        if let stored = defaults.string(forKey: Keys.lastMode) {
            let migrated = WritingSettingsMigration.migrateLastMode(stored)
            defaults.set(migrated.mode.rawValue, forKey: Keys.lastMode)
            if let tone = migrated.proofreadTone, defaults.string(forKey: Keys.proofreadTone) == nil {
                defaults.set(tone.rawValue, forKey: Keys.proofreadTone)
            }
        }
        if let overrides = defaults.dictionary(forKey: Keys.systemPromptOverrides) as? [String: String] {
            defaults.set(WritingSettingsMigration.migrateOverrides(overrides), forKey: Keys.systemPromptOverrides)
        }
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


    func tone(for mode: WritingMode) -> WritingTone {
        tones.tone(for: mode)
    }

    func setTone(_ tone: WritingTone, for mode: WritingMode) {
        tones.set(tone, for: mode)
    }

    func defaultSystemPrompt(
        for mode: WritingMode, tone: WritingTone, profile: WritingPromptProfile = .standard
    ) -> String {
        WritingPromptComposer.compose(
            mode: mode, tone: tone, customPrompt: customPrompt, profile: profile,
            translationLanguage: translationLanguage
        )
    }

    /// The prompts the chosen engine gets (see `WritingPromptProfile.for(provider:)`): what the
    /// prompt settings show and compare an edit against.
    var promptProfile: WritingPromptProfile {
        WritingPromptProfile.for(provider: providerKind)
    }

    /// The user's own override wins whatever the engine: it is their wording of the task.
    func effectiveSystemPrompt(
        for mode: WritingMode, tone: WritingTone, profile: WritingPromptProfile = .standard
    ) -> String {
        if let override = systemPromptOverrides[WritingPromptComposer.overrideKey(mode: mode, tone: tone)] {
            let trimmed = override.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { return override }
        }
        return defaultSystemPrompt(for: mode, tone: tone, profile: profile)
    }

    func isSystemPromptOverridden(for mode: WritingMode, tone: WritingTone) -> Bool {
        guard let override = systemPromptOverrides[WritingPromptComposer.overrideKey(mode: mode, tone: tone)]
        else { return false }
        return !override.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    func setSystemPromptOverride(_ text: String, for mode: WritingMode, tone: WritingTone) {
        var copy = systemPromptOverrides
        let key = WritingPromptComposer.overrideKey(mode: mode, tone: tone)
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let builtIn = defaultSystemPrompt(for: mode, tone: tone, profile: promptProfile)
        if trimmed.isEmpty || text == builtIn {
            copy.removeValue(forKey: key)
        } else {
            copy[key] = text
        }
        systemPromptOverrides = copy
    }

    func resetSystemPromptOverride(for mode: WritingMode, tone: WritingTone) {
        var copy = systemPromptOverrides
        copy.removeValue(forKey: WritingPromptComposer.overrideKey(mode: mode, tone: tone))
        systemPromptOverrides = copy
    }

    var memoryConfig: MemoryConfig {
        MemoryConfig(enabled: memoryEnabled)
    }

    /// Lint launches and talks to its own llama-server for a request that goes to the local llama.cpp
    /// provider (chosen, or picked by Automatic because Apple Intelligence is unavailable).
    func wantsManagedLocalServer(for route: WritingEngineRoute) -> Bool {
        route == .provider(.localLlama) && localServerAutoStart
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
            idleSleepSeconds: localServerIdleSleep.seconds,
            extraArguments: localServerExtraArgs,
            autoStart: localServerAutoStart
        )
    }

    /// The configuration for the provider a request was routed to (see `WritingEngineRouter`).
    func runtimeConfig(for kind: ProviderKind) throws -> LLMRuntimeConfig {
        switch kind {
        case .appleIntelligence:
            // No endpoint, no key, no model name to choose: the system model on this Mac.
            return LLMRuntimeConfig(kind: kind, baseURL: kind.defaultBaseURL, model: kind.defaultModel, apiKey: "")
        case providerKind:
            return try runtimeConfig()
        case .localLlama:
            // Automatic, with Apple Intelligence unavailable: Lint's own local AI as it is set up.
            let model = defaults.string(forKey: Keys.model(.localLlama)) ?? ProviderKind.localLlama.defaultModel
            return LLMRuntimeConfig(
                kind: .localLlama, baseURL: URL(string: "http://127.0.0.1:\(localServerPort)/v1")!,
                model: model, apiKey: ""
            )
        default:
            throw LLMError.unresolvedProvider
        }
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
