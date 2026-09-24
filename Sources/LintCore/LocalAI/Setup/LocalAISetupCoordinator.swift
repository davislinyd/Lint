import Foundation
import Observation

public protocol LlamaRuntimeResolving: Sendable {
    func resolve(source: LocalRuntimeSource, customPath: String) -> LlamaRuntimeStatus
}

extension LlamaRuntimeResolver: LlamaRuntimeResolving {}

/// Where local AI stands, for the setup screen and the settings page.
public enum LocalAISetupState: Equatable, Sendable {
    case checking
    /// No usable llama.cpp runtime (normally only a damaged install, or a bad custom path).
    case runtimeMissing
    /// A runtime is there but cannot be trusted or used; the reason is for diagnostics.
    case runtimeInvalid(String)
    /// The model has not been downloaded yet. The normal state right after installing Lint.
    case modelMissing
    /// `downloadState` has the details (progress, verifying, installing).
    case modelDownloading
    case modelInvalid(String)
    /// Runtime and model are ready; the server is not running.
    case serverStopped
    case serverStarting
    case serverReady
    /// The server could not be started; the message is safe to show.
    case failed(String)
}

/// Owns the local-AI setup flow: it looks at the runtime, the model, the server and the
/// Accessibility permission, and performs the user's choices (download, start, stop, remove). The
/// UI only observes it and calls these methods; nothing in a view touches files, downloads or
/// processes.
@MainActor
@Observable
public final class LocalAISetupCoordinator {
    @ObservationIgnored private let configurationProvider: () -> LocalAIConfiguration
    @ObservationIgnored private let resolver: any LlamaRuntimeResolving
    @ObservationIgnored private let models: LocalModelManager
    @ObservationIgnored private let downloader: ModelDownloadManager
    @ObservationIgnored private let server: any LocalServerControlling
    @ObservationIgnored private let settleDelay: Duration
    @ObservationIgnored private var installTask: Task<Void, Never>?
    @ObservationIgnored private var installGeneration = 0

    public private(set) var hasChecked = false
    public private(set) var runtime: LlamaRuntimeStatus = .missing(source: .automatic)
    public private(set) var model: LocalModelStatus = .notInstalled
    /// Bytes of an unfinished download that a retry would continue from.
    public private(set) var partialBytes: Int64 = 0
    public private(set) var downloadState: ModelDownloadState = .idle
    /// Every catalog model that is completely installed, so the picker can say which of the others
    /// would need a download. Switching back to one of these never downloads anything again.
    public private(set) var installedModelIDs: Set<String> = []
    public private(set) var serverStatus: LocalServerStatus = .stopped
    public private(set) var serverLogTail = ""
    public private(set) var accessibilityTrusted: Bool

    public init(
        configuration: @escaping () -> LocalAIConfiguration,
        resolver: any LlamaRuntimeResolving = LlamaRuntimeResolver(),
        models: LocalModelManager = LocalModelManager(),
        downloader: ModelDownloadManager = ModelDownloadManager(),
        server: any LocalServerControlling,
        accessibilityTrusted: Bool = false,
        settleDelay: Duration = .milliseconds(400)
    ) {
        self.configurationProvider = configuration
        self.resolver = resolver
        self.models = models
        self.downloader = downloader
        self.server = server
        self.accessibilityTrusted = accessibilityTrusted
        self.settleDelay = settleDelay
    }

    public var configuration: LocalAIConfiguration { configurationProvider() }
    public var paths: LocalAIPaths { models.paths }

    // MARK: - State

    public var state: LocalAISetupState {
        guard hasChecked else { return .checking }
        switch runtime {
        case .missing: return .runtimeMissing
        case .invalid(_, let reason): return .runtimeInvalid(reason)
        case .ready: break
        }
        if configuration.modelSource == .managed {
            if downloadState.isActive { return .modelDownloading }
            switch model {
            case .notInstalled: return .modelMissing
            case .invalid(let reason): return .modelInvalid(reason)
            case .installed: break
            }
        }
        switch serverStatus {
        case .running: return .serverReady
        case .starting: return .serverStarting
        case .failed(let message): return .failed(message)
        case .stopped: return .serverStopped
        }
    }

    public var runtimeReady: Bool { runtime.isReady }

    public var modelReady: Bool {
        if configuration.modelSource == .custom { return true }
        if case .installed = model { return true }
        return false
    }

    /// The runtime or the model still needs attention: the setup screen has something to do.
    public var needsSetup: Bool { hasChecked && !(runtimeReady && modelReady) }

    /// Everything the setup screen covers is done: local AI works and Lint may read text.
    public var isSetupComplete: Bool { state == .serverReady && accessibilityTrusted }

    public func setAccessibilityTrusted(_ trusted: Bool) {
        if accessibilityTrusted != trusted { accessibilityTrusted = trusted }
    }

    // MARK: - Checking

    /// Looks at the runtime, the model and the server again. Cheap; never downloads or starts anything.
    public func refresh() async {
        let configuration = self.configuration
        // Checking the runtime's signatures reads ~24 MB the first time; keep that off the main thread.
        let resolver = self.resolver
        runtime = await Task.detached(priority: .userInitiated) {
            resolver.resolve(source: configuration.runtimeSource, customPath: configuration.customBinaryPath)
        }.value
        model = models.status(of: configuration.managedModel)
        partialBytes = models.partialDownloadBytes(of: configuration.managedModel)
        var candidates = ModelCatalog.all
        if !candidates.contains(where: { $0.id == configuration.managedModel.id }) {
            candidates.append(configuration.managedModel)
        }
        installedModelIDs = Set(candidates.filter {
            if $0.id == configuration.managedModel.id, case .installed = model { return true }
            if case .installed = models.status(of: $0) { return true }
            return false
        }.map(\.id))
        await server.refreshStatus(port: configuration.port)
        serverStatus = server.status
        serverLogTail = server.logTail
        hasChecked = true
    }

    // MARK: - Model

    /// Starts the download for the managed model. Only ever called from a user's click.
    public func installModel() {
        guard installTask == nil else { return }
        let descriptor = configuration.managedModel
        installGeneration += 1
        let generation = installGeneration
        downloadState = .checking
        installTask = Task { [weak self] in
            guard let coordinator = self else { return }
            let final = await coordinator.downloader.install(descriptor) { [weak coordinator] state in
                Task { @MainActor in coordinator?.applyProgress(state, generation: generation) }
            }
            await coordinator.finishInstall(final, generation: generation)
        }
    }

    /// Stops the download; what was downloaded is kept so a retry continues from there.
    public func cancelInstall() {
        installTask?.cancel()
    }

    private func applyProgress(_ state: ModelDownloadState, generation: Int) {
        // Progress can arrive after the task already reported its final state; never let it overwrite that.
        guard generation == installGeneration, installTask != nil, state.isActive else { return }
        downloadState = state
    }

    private func finishInstall(_ final: ModelDownloadState, generation: Int) async {
        guard generation == installGeneration else { return }
        installTask = nil
        downloadState = final
        await refresh()
        if case .installed = final, configuration.autoStart, state == .serverStopped {
            try? await startServer() // a failure is reflected in `state`
        }
    }

    /// Called after the selected managed model changed. The running server is loaded with the old
    /// model, so it is stopped; nothing is deleted and a model that is already installed is never
    /// downloaded again. The new model starts when it is ready and auto-start is on.
    public func managedModelChanged() async {
        cancelInstall()
        await installTask?.value
        if downloadState.isActive || downloadState == .cancelled || downloadState == .installed {
            downloadState = .idle
        }
        server.stopIfStartedByUs()
        await refresh()
        if configuration.autoStart, state == .serverStopped {
            try? await startServer() // a failure is reflected in `state`
        }
    }

    /// Deletes the managed model and any unfinished download of it.
    public func removeModel() async {
        cancelInstall()
        await installTask?.value
        server.stopIfStartedByUs()
        do {
            try models.remove(configuration.managedModel)
        } catch {
            downloadState = .failed(.filesystem(error.localizedDescription))
        }
        if downloadState == .installed || downloadState == .cancelled { downloadState = .idle }
        await refresh()
    }

    // MARK: - Server

    /// Makes sure the server answers, starting it if allowed. This is what a request calls: when local
    /// AI is not set up it throws a `LocalAIError` with a friendly message, never a connection error.
    public func ensureServerRunning() async throws {
        let configuration = self.configuration
        if await server.isHealthy(port: configuration.port) {
            if case .running = serverStatus {} else {
                await server.refreshStatus(port: configuration.port)
                serverStatus = server.status
            }
            return
        }
        guard configuration.autoStart else { throw LocalAIError.serverNotRunning(port: configuration.port) }
        try await launch(configuration)
    }

    public func startServer() async throws {
        try await launch(configuration)
    }

    public func restartServer() async throws {
        let configuration = self.configuration
        server.stop(port: configuration.port)
        // Wait for the port to free up before starting again.
        for _ in 0..<30 {
            if !(await server.isHealthy(port: configuration.port)) { break }
            try? await Task.sleep(for: settleDelay / 2)
        }
        try await launch(configuration)
    }

    @discardableResult
    public func stopServer() async -> String {
        let message = server.stop(port: configuration.port)
        // Give the process a moment to release the port.
        try? await Task.sleep(for: settleDelay)
        await refresh()
        return message
    }

    /// Apple Intelligence is taking the requests, so a llama-server Lint started only holds memory the
    /// system model may need. Seen once on a 16 GB Mac under memory pressure: while Lint's llama-server
    /// held Gemma 4 E4B, Apple's model reported a context size of 0 and failed every request, and it
    /// recovered about a minute after llama-server released the model. A second attempt with the
    /// model resident did not fail, so that is not proven to be the cause; the memory is freed either
    /// way. A server Lint did not start is left alone.
    public func releaseForAppleIntelligence() {
        guard case .running(_, managedByLint: true) = serverStatus else { return }
        server.stopIfStartedByUs()
        serverStatus = server.status
    }

    /// Called when the app quits.
    public func stopManagedServer() {
        server.stopIfStartedByUs()
    }

    private func launch(_ configuration: LocalAIConfiguration) async throws {
        let status = resolver.resolve(source: configuration.runtimeSource, customPath: configuration.customBinaryPath)
        guard case .ready(let location) = status else {
            throw LocalAIError.runtimeUnavailable(status.userMessage ?? "")
        }
        let reference = try configuration.modelReference(using: models).get()
        serverStatus = .starting
        do {
            try await server.start(plan: configuration.launchPlan(runtime: location, model: reference), port: configuration.port)
        } catch {
            serverStatus = server.status
            serverLogTail = server.logTail
            throw error
        }
        serverStatus = server.status
        serverLogTail = server.logTail
    }
}
