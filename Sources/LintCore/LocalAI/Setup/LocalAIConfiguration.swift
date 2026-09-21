import Foundation

/// Which model the local server loads.
public enum LocalModelSource: String, Codable, CaseIterable, Sendable, Identifiable {
    /// A model from Lint's catalog, downloaded and verified by Lint into Application Support.
    case managed
    /// Advanced: a Hugging Face `-hf` spec that llama-server resolves (and downloads) itself.
    case custom

    public var id: String { rawValue }
}

/// Why local AI cannot run. `errorDescription` is what a normal user reads; it never shows a raw
/// connection error, and never sends anyone to Homebrew.
public enum LocalAIError: Error, Equatable, LocalizedError, Sendable {
    /// The model has not been installed yet: the normal state on a fresh Mac.
    case notSetUp
    case runtimeUnavailable(String)
    case modelInvalid(String)
    /// Nothing listens on the port and auto-start is off.
    case serverNotRunning(port: Int)
    case launchFailed(String)
    case startTimeout(seconds: Int)

    /// Setup (rather than a retry) is what fixes it: the panel offers a "Set Up Local AI" button.
    public var needsSetup: Bool {
        switch self {
        case .notSetUp, .runtimeUnavailable, .modelInvalid: true
        case .serverNotRunning, .launchFailed, .startTimeout: false
        }
    }

    public var errorDescription: String? {
        switch self {
        case .notSetUp:
            return String(localized: "本機 AI 尚未設定。")
        case .runtimeUnavailable(let message):
            return message
        case .modelInvalid:
            return String(localized: "本機 AI 模型不完整或已損毀，請重新下載。")
        case .serverNotRunning(let port):
            return String(localized: "本機 llama-server 未在埠 \(port) 運行。可在設定開啟「自動啟動」，或先在終端機手動啟動。")
        case .launchFailed(let message):
            return message
        case .startTimeout(let seconds):
            return String(localized: "等待 llama-server 就緒逾時（\(seconds)s）。首次載入模型會較久，它仍在載入，請稍後再試。")
        }
    }
}

/// Everything about the local server that comes from settings, as plain values.
public struct LocalAIConfiguration: Equatable, Sendable {
    public var runtimeSource: LocalRuntimeSource
    public var customBinaryPath: String
    public var modelSource: LocalModelSource
    /// The catalog model used when `modelSource` is `.managed`.
    public var managedModel: ModelDescriptor
    public var huggingFaceSpec: String
    public var port: Int
    public var extraArguments: String
    public var autoStart: Bool

    public init(
        runtimeSource: LocalRuntimeSource = .automatic,
        customBinaryPath: String = "",
        modelSource: LocalModelSource = .managed,
        managedModel: ModelDescriptor = ModelCatalog.recommended,
        huggingFaceSpec: String = ModelCatalog.recommended.huggingFaceSpec,
        port: Int = 8000,
        extraArguments: String = "",
        autoStart: Bool = true
    ) {
        self.runtimeSource = runtimeSource
        self.customBinaryPath = customBinaryPath
        self.modelSource = modelSource
        self.managedModel = managedModel
        self.huggingFaceSpec = huggingFaceSpec
        self.port = port
        self.extraArguments = extraArguments
        self.autoStart = autoStart
    }

    public var effectiveHuggingFaceSpec: String {
        let spec = huggingFaceSpec.trimmingCharacters(in: .whitespacesAndNewlines)
        return spec.isEmpty ? ModelCatalog.recommended.huggingFaceSpec : spec
    }

    /// The model llama-server is started with. A managed model is always passed as a local file
    /// (`-m`), so starting the server never downloads anything.
    public func modelReference(using models: LocalModelManager) -> Result<LocalModelReference, LocalAIError> {
        switch modelSource {
        case .custom:
            return .success(.huggingFace(effectiveHuggingFaceSpec))
        case .managed:
            switch models.status(of: managedModel) {
            case .installed(let file): return .success(.file(file))
            case .notInstalled: return .failure(.notSetUp)
            case .invalid(let reason): return .failure(.modelInvalid(reason))
            }
        }
    }

    public func launchPlan(runtime: LlamaRuntimeLocation, model: LocalModelReference) -> LlamaServerLaunchPlan {
        LlamaServerLaunchPlan.make(runtime: runtime.binaryURL, model: model, port: port, extraArguments: extraArguments)
    }
}

/// One-time choice, on the first launch that knows about managed models, between the two model sources
/// for a user who already has a setting.
public enum LocalModelMigration {
    public struct Result: Equatable, Sendable {
        public var source: LocalModelSource
        public var managedModelID: String
    }

    /// - A new user (no stored model): managed, recommended model.
    /// - The old default spec and the model is not in the Hugging Face cache: managed, so Lint installs it.
    /// - The old default spec and the model is already in the cache: keep using it as before (custom
    ///   `-hf`), so an existing setup keeps working without a second 4.7 GB download; switching to
    ///   the managed model stays one click in Settings.
    /// - Any other spec: the user's own choice, kept as custom.
    public static func migrate(
        storedSpec: String?,
        hasCompleteHuggingFaceCopy: (ModelDescriptor) -> Bool,
        catalog: [ModelDescriptor] = ModelCatalog.all
    ) -> Result {
        let spec = (storedSpec ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let recommended = ModelCatalog.recommended
        if spec.isEmpty { return Result(source: .managed, managedModelID: recommended.id) }
        guard let match = catalog.first(where: { $0.huggingFaceSpec.lowercased() == spec.lowercased() }) else {
            return Result(source: .custom, managedModelID: recommended.id)
        }
        return hasCompleteHuggingFaceCopy(match)
            ? Result(source: .custom, managedModelID: match.id)
            : Result(source: .managed, managedModelID: match.id)
    }
}
