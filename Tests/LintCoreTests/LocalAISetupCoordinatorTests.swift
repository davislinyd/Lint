import XCTest

@testable import LintCore

@MainActor
final class FakeServer: LocalServerControlling {
    var status: LocalServerStatus = .stopped
    var logTail = ""
    var healthy = false
    var sleeping: Bool?
    var startError: Error?
    var onStart: (() -> Void)?
    private(set) var startedPlans: [LlamaServerLaunchPlan] = []
    private(set) var stopCalls = 0

    func isHealthy(port: Int) async -> Bool { healthy }

    func isSleeping(port: Int) async -> Bool? { sleeping }

    func start(plan: LlamaServerLaunchPlan, port: Int) async throws -> Bool {
        if healthy { return false }
        onStart?()
        startedPlans.append(plan)
        if let startError {
            status = .failed(startError.localizedDescription)
            logTail = "llama_model_load: error loading model"
            throw startError
        }
        healthy = true
        status = .running(pid: 1234, managedByLint: true)
        return true
    }

    @discardableResult
    func stop(port: Int) -> String {
        stopCalls += 1
        healthy = false
        status = .stopped
        return "stopped"
    }

    func stopIfStartedByUs() { _ = stop(port: 0) }

    func refreshStatus(port: Int) async {
        if healthy {
            if case .running = status {} else { status = .running(pid: nil, managedByLint: false) }
        } else if case .starting = status {
        } else if case .failed = status {
        } else {
            status = .stopped
        }
    }
}

final class FakeResolver: LlamaRuntimeResolving, @unchecked Sendable {
    var status: LlamaRuntimeStatus
    init(_ status: LlamaRuntimeStatus) { self.status = status }
    func resolve(source: LocalRuntimeSource, customPath: String) -> LlamaRuntimeStatus { status }
}

@MainActor
final class ConfigBox {
    var value: LocalAIConfiguration
    init(_ value: LocalAIConfiguration) { self.value = value }
}

@MainActor
final class LocalAISetupCoordinatorTests: XCTestCase {
    struct Env {
        var coordinator: LocalAISetupCoordinator
        var server: FakeServer
        var resolver: FakeResolver
        var transport: FakeTransport
        var config: ConfigBox
        var paths: LocalAIPaths
        var model: ModelDescriptor
    }

    private static let bundled = LlamaRuntimeStatus.ready(
        LlamaRuntimeLocation(binaryURL: URL(fileURLWithPath: "/Applications/Lint.app/Contents/Resources/LlamaRuntime/arm64/llama-server"), origin: .bundled)
    )

    private func makeEnv(
        runtime: LlamaRuntimeStatus = LocalAISetupCoordinatorTests.bundled, disk: Int64 = 1 << 40,
        modelSource: LocalModelSource = .managed, autoStart: Bool = true
    ) throws -> Env {
        let (model, remote) = TestModel.twoShards()
        let paths = LocalAIPaths(root: try TestSupport.makeTempDirectory())
        let transport = FakeTransport(remote: remote)
        let server = FakeServer()
        let resolver = FakeResolver(runtime)
        let config = ConfigBox(LocalAIConfiguration(modelSource: modelSource, managedModel: model, huggingFaceSpec: "someone/model:q4", port: 8000, extraArguments: "-ngl 99", autoStart: autoStart))
        let coordinator = LocalAISetupCoordinator(
            configuration: { config.value },
            resolver: resolver,
            models: LocalModelManager(paths: paths),
            downloader: ModelDownloadManager(paths: paths, transport: transport, diskSpace: FakeDiskSpace(bytes: disk)),
            server: server,
            settleDelay: .zero
        )
        return Env(coordinator: coordinator, server: server, resolver: resolver, transport: transport, config: config, paths: paths, model: model)
    }

    private func waitUntil(_ description: String, timeout: TimeInterval = 10, _ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            if Date() > deadline { return XCTFail("timed out waiting for \(description)") }
            try await Task.sleep(for: .milliseconds(5))
        }
    }

    // MARK: - Runtime

    func testAFreshMacWithTheBundledRuntimeOnlyNeedsTheModel() async throws {
        let env = try makeEnv()
        XCTAssertEqual(env.coordinator.state, .checking)
        await env.coordinator.refresh()
        XCTAssertEqual(env.coordinator.state, .modelMissing)
        XCTAssertTrue(env.coordinator.runtimeReady)
        XCTAssertFalse(env.coordinator.modelReady)
        XCTAssertTrue(env.coordinator.needsSetup)
        XCTAssertFalse(env.coordinator.isSetupComplete)
        XCTAssertTrue(env.server.startedPlans.isEmpty, "nothing starts, and nothing downloads, on its own")
        XCTAssertTrue(env.transport.calls.isEmpty)
    }

    func testAMissingRuntimeIsAFriendlyStateNotAConnectionError() async throws {
        let env = try makeEnv(runtime: .missing(source: .automatic))
        await env.coordinator.refresh()
        XCTAssertEqual(env.coordinator.state, .runtimeMissing)
        XCTAssertTrue(env.coordinator.needsSetup)

        do {
            try await env.coordinator.ensureServerRunning()
            XCTFail("must not pretend to work")
        } catch let error as LocalAIError {
            guard case .runtimeUnavailable(let message) = error else { return XCTFail("\(error)") }
            XCTAssertTrue(error.needsSetup)
            for forbidden in ["127.0.0.1", "refused", "brew", "Homebrew"] {
                XCTAssertFalse(message.localizedCaseInsensitiveContains(forbidden), "'\(forbidden)' in: \(message)")
            }
            XCTAssertFalse(message.isEmpty)
        }
        XCTAssertTrue(env.server.startedPlans.isEmpty)

        env.resolver.status = .invalid(source: .automatic, reason: "libggml.0.dylib is missing")
        await env.coordinator.refresh()
        XCTAssertEqual(env.coordinator.state, .runtimeInvalid("libggml.0.dylib is missing"))
    }

    // MARK: - Model

    func testAMissingModelGivesNotSetUpNeverARawConnectionError() async throws {
        let env = try makeEnv()
        await env.coordinator.refresh()
        do {
            try await env.coordinator.ensureServerRunning()
            XCTFail("must throw")
        } catch let error as LocalAIError {
            XCTAssertEqual(error, .notSetUp)
            XCTAssertTrue(error.needsSetup)
            let text = try XCTUnwrap(error.errorDescription)
            XCTAssertEqual(text, String(localized: "本機 AI 尚未設定。"))
            for forbidden in ["127.0.0.1", "8000", "refused", "URLError"] { XCTAssertFalse(text.contains(forbidden)) }
        }
        XCTAssertTrue(env.server.startedPlans.isEmpty, "no server start attempt without a model")
    }

    func testInstallingTheModelStartsTheServerWithTheLocalFile() async throws {
        let env = try makeEnv()
        await env.coordinator.refresh()
        env.coordinator.installModel()
        try await waitUntil("the server to be ready") { env.coordinator.state == .serverReady }

        XCTAssertEqual(env.coordinator.downloadState, .installed)
        XCTAssertTrue(env.coordinator.modelReady)
        let plan = try XCTUnwrap(env.server.startedPlans.first)
        let firstShard = env.paths.installDirectory(for: env.model).appendingPathComponent("m-00001-of-00002.gguf")
        XCTAssertEqual(Array(plan.arguments.prefix(6)), ["-m", firstShard.path, "--host", "127.0.0.1", "--port", "8000"])
        XCTAssertEqual(Array(plan.arguments.suffix(2)), ["-ngl", "99"], "the advanced setting comes last")
        XCTAssertFalse(plan.arguments.contains("-hf"))
        XCTAssertEqual(env.server.startedPlans.count, 1)

        env.coordinator.setAccessibilityTrusted(true)
        XCTAssertTrue(env.coordinator.isSetupComplete)
    }

    func testCancellingTheDownloadLeavesASafeStateAndRetryResumes() async throws {
        let env = try makeEnv()
        env.transport.pauseAfterBytes = 3000
        let paused = expectation(description: "paused")
        env.transport.onPause = { paused.fulfill() }
        await env.coordinator.refresh()

        env.coordinator.installModel()
        await fulfillment(of: [paused], timeout: 10)
        try await waitUntil("progress to show") { if case .downloading(let n, _) = env.coordinator.downloadState { n >= 3000 } else { false } }
        XCTAssertEqual(env.coordinator.state, .modelDownloading)

        env.coordinator.cancelInstall()
        try await waitUntil("the cancellation to settle") { env.coordinator.downloadState == .cancelled }
        XCTAssertEqual(env.coordinator.state, .modelMissing, "a cancelled download is 'not installed', never half-installed")
        XCTAssertEqual(env.coordinator.partialBytes, 3000, "the partial download is kept for resuming")
        XCTAssertTrue(env.server.startedPlans.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: env.paths.installDirectory(for: env.model).path))

        env.transport.pauseAfterBytes = nil
        env.coordinator.installModel()
        try await waitUntil("the retry to finish") { env.coordinator.state == .serverReady }
        XCTAssertEqual(env.transport.calls.map(\.existingBytes), [0, 3000, 0])
    }

    func testAFailedDownloadCanBeRetried() async throws {
        let env = try makeEnv()
        env.transport.failure = { _ in ModelInstallError.network("The Internet connection appears to be offline.") }
        await env.coordinator.refresh()
        env.coordinator.installModel()
        try await waitUntil("the failure") { if case .failed = env.coordinator.downloadState { true } else { false } }
        XCTAssertEqual(env.coordinator.state, .modelMissing)
        XCTAssertEqual(env.coordinator.downloadState, .failed(.network("The Internet connection appears to be offline.")))
        XCTAssertTrue(env.server.startedPlans.isEmpty)

        env.transport.failure = nil
        env.coordinator.installModel()
        try await waitUntil("the retry") { env.coordinator.state == .serverReady }
    }

    func testTooLittleDiskSpaceStopsBeforeDownloading() async throws {
        let env = try makeEnv(disk: 100)
        await env.coordinator.refresh()
        env.coordinator.installModel()
        try await waitUntil("the disk check") { if case .failed = env.coordinator.downloadState { true } else { false } }
        guard case .failed(.insufficientDiskSpace(let required, let available)) = env.coordinator.downloadState else { return XCTFail() }
        XCTAssertGreaterThan(required, available)
        XCTAssertTrue(env.transport.calls.isEmpty)
        XCTAssertEqual(env.coordinator.state, .modelMissing)
    }

    func testAnInvalidInstalledModelIsReportedAndNotLaunched() async throws {
        let env = try makeEnv()
        let dir = env.paths.installDirectory(for: env.model)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data("junk".utf8).write(to: dir.appendingPathComponent("m-00001-of-00002.gguf"))
        await env.coordinator.refresh()
        guard case .modelInvalid = env.coordinator.state else { return XCTFail("\(env.coordinator.state)") }
        do {
            try await env.coordinator.ensureServerRunning()
            XCTFail("a damaged model must not be launched")
        } catch let error as LocalAIError {
            guard case .modelInvalid = error else { return XCTFail("\(error)") }
            XCTAssertTrue(error.needsSetup)
        }
        XCTAssertTrue(env.server.startedPlans.isEmpty)
    }

    func testTheCustomModelSourceSkipsTheManagedModelChecks() async throws {
        let env = try makeEnv(modelSource: .custom)
        await env.coordinator.refresh()
        XCTAssertEqual(env.coordinator.state, .serverStopped)
        XCTAssertFalse(env.coordinator.needsSetup)
        try await env.coordinator.ensureServerRunning()
        XCTAssertEqual(env.server.startedPlans.first?.arguments.prefix(2), ["-hf", "someone/model:q4"])
        XCTAssertEqual(env.coordinator.state, .serverReady)
    }

    func testTurningAutoStartOffKeepsTheServerStoppedAfterInstall() async throws {
        let env = try makeEnv(autoStart: false)
        await env.coordinator.refresh()
        env.coordinator.installModel()
        try await waitUntil("the install") { env.coordinator.downloadState == .installed }
        XCTAssertEqual(env.coordinator.state, .serverStopped)
        XCTAssertTrue(env.server.startedPlans.isEmpty)
        do {
            try await env.coordinator.ensureServerRunning()
            XCTFail("must not start by itself")
        } catch let error as LocalAIError {
            XCTAssertEqual(error, .serverNotRunning(port: 8000))
            XCTAssertFalse(error.needsSetup)
        }
        try await env.coordinator.startServer() // an explicit start still works
        XCTAssertEqual(env.coordinator.state, .serverReady)
    }

    // MARK: - Server

    func testAServerThatFailsToStartIsAFailedStateWithBoundedDiagnostics() async throws {
        let env = try makeEnv()
        env.coordinator.installModel()
        try await waitUntil("the install") { env.coordinator.downloadState == .installed }
        env.server.healthy = false
        env.server.status = .stopped
        env.server.startError = LocalAIError.launchFailed("llama-server 已結束")
        await env.coordinator.refresh()
        do {
            try await env.coordinator.startServer()
            XCTFail("must throw")
        } catch {
            XCTAssertEqual(error as? LocalAIError, .launchFailed("llama-server 已結束"))
        }
        XCTAssertEqual(env.coordinator.state, .failed("llama-server 已結束"))
        XCTAssertEqual(env.coordinator.serverLogTail, "llama_model_load: error loading model")
    }

    func testAServerAlreadyRunningOnThePortIsReadyAndNotStartedAgain() async throws {
        let env = try makeEnv()
        env.coordinator.installModel()
        try await waitUntil("the install") { env.coordinator.downloadState == .installed }
        env.server.status = .stopped
        env.server.healthy = true // e.g. started from Terminal
        try await env.coordinator.ensureServerRunning()
        XCTAssertEqual(env.coordinator.state, .serverReady)
        XCTAssertLessThanOrEqual(env.server.startedPlans.count, 1)
    }

    func testACancelledRequestNeitherStartsTheServerNorCallsItStopped() async throws {
        let env = try makeEnv()
        env.coordinator.installModel()
        try await waitUntil("the server") { env.coordinator.state == .serverReady }
        env.server.status = .starting
        env.server.healthy = false // still loading, or its check failed only because the task was cancelled
        let starts = env.server.startedPlans.count
        let request = Task { try await env.coordinator.ensureServerRunning() }
        request.cancel() // a newer selection replaced this suggestion
        do {
            try await request.value
            XCTFail("must throw")
        } catch {
            XCTAssertTrue(error is CancellationError, "got \(error)")
        }
        XCTAssertEqual(env.server.startedPlans.count, starts)
    }

    func testLookingAgainNeverWipesAFailureButFollowsTheProcess() {
        let failed = LocalServerStatus.failed("llama-server 已結束")
        XCTAssertEqual(failed.refreshed(healthy: false, managedProcessRunning: false, pid: nil, managedByLint: false), failed,
                       "the reason stays until the next start")
        XCTAssertEqual(failed.refreshed(healthy: false, managedProcessRunning: true, pid: 5, managedByLint: true), .starting,
                       "a process that is still loading is not a failure any more")
        XCTAssertEqual(failed.refreshed(healthy: true, managedProcessRunning: true, pid: 5, managedByLint: true), .running(pid: 5, managedByLint: true))
        XCTAssertEqual(LocalServerStatus.running(pid: 5, managedByLint: true).refreshed(healthy: false, managedProcessRunning: false, pid: nil, managedByLint: false), .stopped)
        XCTAssertEqual(LocalServerStatus.starting.refreshed(healthy: false, managedProcessRunning: false, pid: nil, managedByLint: false), .starting)
        XCTAssertEqual(LocalServerStatus.stopped.refreshed(healthy: true, managedProcessRunning: false, pid: nil, managedByLint: false), .running(pid: nil, managedByLint: false),
                       "something started in Terminal is running, just not by Lint")
    }

    func testRestartStopsThenStartsAgain() async throws {
        let env = try makeEnv()
        env.coordinator.installModel()
        try await waitUntil("the server") { env.coordinator.state == .serverReady }
        let starts = env.server.startedPlans.count
        try await env.coordinator.restartServer()
        XCTAssertEqual(env.server.stopCalls, 1)
        XCTAssertEqual(env.server.startedPlans.count, starts + 1)
        XCTAssertEqual(env.coordinator.state, .serverReady)

        await env.coordinator.stopServer()
        XCTAssertEqual(env.coordinator.state, .serverStopped)
    }

    func testRemovingTheModelStopsTheServerAndReturnsToModelMissing() async throws {
        let env = try makeEnv()
        env.coordinator.installModel()
        try await waitUntil("the server") { env.coordinator.state == .serverReady }
        await env.coordinator.removeModel()
        XCTAssertEqual(env.coordinator.state, .modelMissing)
        XCTAssertFalse(FileManager.default.fileExists(atPath: env.paths.installDirectory(for: env.model).path))
        XCTAssertGreaterThan(env.server.stopCalls, 0)
    }

    func testTheSetupNeverThrowsFromNormalUsageWhileIncomplete() async throws {
        // Every entry point a normal request or a settings screen uses, in every incomplete state.
        for runtime in [LlamaRuntimeStatus.missing(source: .automatic), .invalid(source: .automatic, reason: "x"), Self.bundled] {
            let env = try makeEnv(runtime: runtime)
            await env.coordinator.refresh()
            _ = env.coordinator.state
            _ = env.coordinator.needsSetup
            _ = env.coordinator.isSetupComplete
            do { try await env.coordinator.ensureServerRunning() } catch is LocalAIError {}
            do { try await env.coordinator.startServer() } catch is LocalAIError {}
            await env.coordinator.stopServer()
            env.coordinator.cancelInstall()
            await env.coordinator.removeModel()
        }
    }
}
/// Switching the managed model: the running server holds the old one, so it is stopped and started
/// again — but nothing is deleted, and a model that is already on disk is never downloaded twice.
@MainActor
final class ManagedModelSwitchTests: XCTestCase {
    func testSwitchingModelsRestartsTheServerWithoutDownloadingOrDeletingAnything() async throws {
        let (first, firstRemote) = TestModel.make(id: "first", shards: [("a.gguf", TestModel.payload("a", count: 4000))])
        let (second, secondRemote) = TestModel.make(id: "second", shards: [("b.gguf", TestModel.payload("b", count: 5000))])
        let paths = LocalAIPaths(root: try TestSupport.makeTempDirectory())
        let transport = FakeTransport(remote: firstRemote.merging(secondRemote) { a, _ in a })
        let downloader = ModelDownloadManager(paths: paths, transport: transport, diskSpace: FakeDiskSpace(bytes: 1 << 40))
        let server = FakeServer()
        let config = ConfigBox(LocalAIConfiguration(managedModel: first, extraArguments: ""))
        let coordinator = LocalAISetupCoordinator(
            configuration: { config.value },
            resolver: FakeResolver(.ready(LlamaRuntimeLocation(binaryURL: URL(fileURLWithPath: "/llama-server"), origin: .bundled))),
            models: LocalModelManager(paths: paths), downloader: downloader, server: server, settleDelay: .zero
        )
        let firstInstalled = await downloader.install(first)
        XCTAssertEqual(firstInstalled, .installed)
        let secondInstalled = await downloader.install(second)
        XCTAssertEqual(secondInstalled, .installed)
        await coordinator.refresh()
        let manager = LocalModelManager(paths: paths)
        XCTAssertTrue(coordinator.installedModelIDs.contains("first"), "the selected model reports as installed")
        try await coordinator.startServer()
        XCTAssertEqual(server.startedPlans.count, 1)
        XCTAssertTrue(server.startedPlans[0].arguments.contains(paths.installDirectory(for: first).appendingPathComponent("a.gguf").path))

        let downloadsBefore = transport.calls.count
        config.value.managedModel = second
        await coordinator.managedModelChanged()

        XCTAssertEqual(server.stopCalls, 1, "the old model was loaded; that process is stopped")
        XCTAssertEqual(server.startedPlans.count, 2)
        XCTAssertTrue(server.startedPlans[1].arguments.contains(paths.installDirectory(for: second).appendingPathComponent("b.gguf").path))
        XCTAssertEqual(transport.calls.count, downloadsBefore, "an installed model is never downloaded again")
        XCTAssertEqual(coordinator.state, .serverReady)

        // And back again: the first model is still there, untouched.
        config.value.managedModel = first
        await coordinator.managedModelChanged()
        XCTAssertEqual(transport.calls.count, downloadsBefore)
        for model in [first, second] {
            guard case .installed = manager.status(of: model) else {
                return XCTFail("\(model.id) was deleted by a switch")
            }
        }
        XCTAssertEqual(coordinator.state, .serverReady)
    }

    func testSwitchingToAModelThatIsNotInstalledStopsAtTheDownloadPromptInsteadOfDownloading() async throws {
        let (installed, remote) = TestModel.make(id: "installed", shards: [("a.gguf", TestModel.payload("a", count: 4000))])
        let (missing, _) = TestModel.make(id: "missing", shards: [("b.gguf", TestModel.payload("b", count: 5000))])
        let paths = LocalAIPaths(root: try TestSupport.makeTempDirectory())
        let transport = FakeTransport(remote: remote)
        let downloader = ModelDownloadManager(paths: paths, transport: transport, diskSpace: FakeDiskSpace(bytes: 1 << 40))
        let server = FakeServer()
        let config = ConfigBox(LocalAIConfiguration(managedModel: installed, extraArguments: ""))
        let coordinator = LocalAISetupCoordinator(
            configuration: { config.value },
            resolver: FakeResolver(.ready(LlamaRuntimeLocation(binaryURL: URL(fileURLWithPath: "/llama-server"), origin: .bundled))),
            models: LocalModelManager(paths: paths), downloader: downloader, server: server, settleDelay: .zero
        )
        let done = await downloader.install(installed)
        XCTAssertEqual(done, .installed)
        await coordinator.refresh()
        let downloadsBefore = transport.calls.count

        config.value.managedModel = missing
        await coordinator.managedModelChanged()

        XCTAssertEqual(coordinator.state, .modelMissing, "the user is asked, never surprised by a download")
        XCTAssertEqual(transport.calls.count, downloadsBefore)
        guard case .installed = LocalModelManager(paths: paths).status(of: installed) else {
            return XCTFail("the model that was there is still there")
        }
    }
}

/// Choosing Apple Intelligence releases the memory of a llama-server Lint started, and nothing else.
@MainActor
final class AppleIntelligenceReleaseTests: XCTestCase {
    private func coordinator(_ server: FakeServer) -> LocalAISetupCoordinator {
        LocalAISetupCoordinator(
            configuration: { LocalAIConfiguration(extraArguments: "") },
            resolver: FakeResolver(.ready(LlamaRuntimeLocation(binaryURL: URL(fileURLWithPath: "/llama-server"), origin: .bundled))),
            server: server, settleDelay: .zero
        )
    }

    func testAServerLintStartedIsStopped() async throws {
        let server = FakeServer()
        server.status = .running(pid: 1234, managedByLint: true)
        server.healthy = true
        let coordinator = coordinator(server)
        await coordinator.refresh()
        coordinator.releaseForAppleIntelligence()
        XCTAssertEqual(server.stopCalls, 1)
        XCTAssertEqual(coordinator.serverStatus, .stopped)
        coordinator.releaseForAppleIntelligence()
        XCTAssertEqual(server.stopCalls, 1, "nothing to do the second time")
    }

    func testAServerSomeoneElseStartedIsLeftAlone() async throws {
        let server = FakeServer()
        server.status = .running(pid: nil, managedByLint: false)
        server.healthy = true
        let coordinator = coordinator(server)
        await coordinator.refresh()
        coordinator.releaseForAppleIntelligence()
        XCTAssertEqual(server.stopCalls, 0)
    }
}

/// What the menu bar says about the local model: the server's status, `is_sleeping` from `/props`,
/// and a restart in progress.
@MainActor
final class LocalModelActivityTests: XCTestCase {
    private func coordinator(_ server: FakeServer) -> LocalAISetupCoordinator {
        LocalAISetupCoordinator(
            configuration: { LocalAIConfiguration(modelSource: .custom, extraArguments: "") },
            resolver: FakeResolver(.ready(LlamaRuntimeLocation(binaryURL: URL(fileURLWithPath: "/llama-server"), origin: .bundled))),
            server: server, settleDelay: .zero
        )
    }

    private func runningServer() -> FakeServer {
        let server = FakeServer()
        server.status = .running(pid: 1234, managedByLint: true)
        server.healthy = true
        return server
    }

    func testEachServerStatusHasItsActivity() {
        func resolve(_ status: LocalServerStatus, _ sleep: LocalModelSleepState, restarting: Bool = false) -> LocalModelActivity {
            .resolve(serverStatus: status, sleep: sleep, isRestarting: restarting)
        }
        let running = LocalServerStatus.running(pid: 1, managedByLint: true)
        XCTAssertEqual(resolve(.stopped, .unknown), .notLoaded)
        XCTAssertEqual(resolve(.starting, .unknown), .loading)
        XCTAssertEqual(resolve(.failed("no model"), .unknown), .failed("no model"))
        XCTAssertEqual(resolve(running, .awake), .running)
        XCTAssertEqual(resolve(running, .unknown), .running, "a server that does not say whether it sleeps is running")
        XCTAssertEqual(resolve(running, .asleep), .idle)
        XCTAssertEqual(resolve(running, .waking), .loading)
        XCTAssertEqual(resolve(.stopped, .unknown, restarting: true), .restarting)
        XCTAssertEqual(resolve(.starting, .unknown, restarting: true), .restarting)
    }

    func testNoAnswerFromPropsMeansWakingOnlyAfterSleep() {
        XCTAssertEqual(LocalModelSleepState.unknown.updated(isSleeping: nil), .unknown)
        XCTAssertEqual(LocalModelSleepState.awake.updated(isSleeping: nil), .unknown)
        XCTAssertEqual(LocalModelSleepState.asleep.updated(isSleeping: nil), .waking)
        XCTAssertEqual(LocalModelSleepState.waking.updated(isSleeping: nil), .waking)
        XCTAssertEqual(LocalModelSleepState.waking.updated(isSleeping: false), .awake)
        XCTAssertEqual(LocalModelSleepState.awake.updated(isSleeping: true), .asleep)
    }

    func testRefreshingFollowsSleepWakeAndStop() async {
        let server = runningServer()
        let coordinator = coordinator(server)
        server.sleeping = false
        await coordinator.refreshServerActivity()
        XCTAssertEqual(coordinator.activity, .running)
        server.sleeping = true
        await coordinator.refreshServerActivity()
        XCTAssertEqual(coordinator.activity, .idle)
        server.sleeping = nil
        await coordinator.refreshServerActivity()
        XCTAssertEqual(coordinator.activity, .loading)
        server.sleeping = false
        await coordinator.refreshServerActivity()
        XCTAssertEqual(coordinator.activity, .running)

        server.healthy = false
        server.status = .stopped
        await coordinator.refreshServerActivity()
        XCTAssertEqual(coordinator.activity, .notLoaded)
        XCTAssertEqual(coordinator.modelSleep, .unknown)
    }

    func testRestartIsShownUntilTheServerIsBack() async throws {
        let server = runningServer()
        let coordinator = coordinator(server)
        server.sleeping = true
        await coordinator.refreshServerActivity()
        XCTAssertEqual(coordinator.activity, .idle)

        var duringStart: [LocalModelActivity] = []
        server.onStart = { duringStart.append(coordinator.activity) }
        try await coordinator.restartServer()
        XCTAssertEqual(duringStart, [.restarting])
        XCTAssertFalse(coordinator.isRestarting)
        XCTAssertEqual(coordinator.activity, .running, "a restarted server holds its model")
    }
}

/// A model picked from the menu bar: one that is not installed is downloaded (the menu asks first)
/// and started; one that is installed is only switched to; the same one is only started.
@MainActor
final class MenuModelChoiceTests: XCTestCase {
    private struct Env {
        let coordinator: LocalAISetupCoordinator
        let server: FakeServer
        let transport: FakeTransport
        let config: ConfigBox
        let paths: LocalAIPaths
        let first: ModelDescriptor
        let second: ModelDescriptor
    }

    /// `first` is installed and selected; `second` is installed only when asked.
    private func makeEnv(installSecond: Bool) async throws -> Env {
        let (first, firstRemote) = TestModel.make(id: "first", shards: [("a.gguf", TestModel.payload("a", count: 4000))])
        let (second, secondRemote) = TestModel.make(id: "second", shards: [("b.gguf", TestModel.payload("b", count: 5000))])
        let paths = LocalAIPaths(root: try TestSupport.makeTempDirectory())
        let transport = FakeTransport(remote: firstRemote.merging(secondRemote) { a, _ in a })
        let downloader = ModelDownloadManager(paths: paths, transport: transport, diskSpace: FakeDiskSpace(bytes: 1 << 40))
        let server = FakeServer()
        let config = ConfigBox(LocalAIConfiguration(managedModel: first, extraArguments: ""))
        let coordinator = LocalAISetupCoordinator(
            configuration: { config.value },
            resolver: FakeResolver(.ready(LlamaRuntimeLocation(binaryURL: URL(fileURLWithPath: "/llama-server"), origin: .bundled))),
            models: LocalModelManager(paths: paths), downloader: downloader, server: server, settleDelay: .zero
        )
        let firstInstalled = await downloader.install(first)
        XCTAssertEqual(firstInstalled, .installed)
        if installSecond {
            let secondInstalled = await downloader.install(second)
            XCTAssertEqual(secondInstalled, .installed)
        }
        await coordinator.refresh()
        return Env(coordinator: coordinator, server: server, transport: transport, config: config, paths: paths, first: first, second: second)
    }

    private func waitUntil(_ description: String, timeout: TimeInterval = 10, _ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            if Date() > deadline { return XCTFail("timed out waiting for \(description)") }
            try await Task.sleep(for: .milliseconds(5))
        }
    }

    private func modelPath(_ env: Env, _ model: ModelDescriptor, _ file: String) -> String {
        env.paths.installDirectory(for: model).appendingPathComponent(file).path
    }

    func testAMissingModelIsDownloadedAndThenStarted() async throws {
        let env = try await makeEnv(installSecond: false)
        try await env.coordinator.startServer()
        XCTAssertFalse(env.coordinator.isInstalled(env.second))
        let downloadsBefore = env.transport.calls.count

        env.config.value.managedModel = env.second
        await env.coordinator.useManagedModel(changed: true)
        try await waitUntil("the new model to run") {
            env.coordinator.state == .serverReady && env.server.startedPlans.count == 2
        }

        XCTAssertEqual(env.server.stopCalls, 1, "the old model's process is stopped first")
        XCTAssertTrue(env.server.startedPlans[1].arguments.contains(modelPath(env, env.second, "b.gguf")))
        XCTAssertEqual(env.transport.calls.dropFirst(downloadsBefore).map(\.fileName), ["b.gguf"])
        XCTAssertTrue(env.coordinator.isInstalled(env.second))
        XCTAssertEqual(env.coordinator.activity, .running)
    }

    func testAnInstalledModelIsSwitchedToWithoutADownload() async throws {
        let env = try await makeEnv(installSecond: true)
        try await env.coordinator.startServer()
        let downloadsBefore = env.transport.calls.count

        env.config.value.managedModel = env.second
        await env.coordinator.useManagedModel(changed: true)

        XCTAssertEqual(env.server.startedPlans.count, 2)
        XCTAssertTrue(env.server.startedPlans[1].arguments.contains(modelPath(env, env.second, "b.gguf")))
        XCTAssertEqual(env.transport.calls.count, downloadsBefore)
        XCTAssertEqual(env.coordinator.state, .serverReady)
    }

    func testTheSameModelIsOnlyStartedAndNeverRestarted() async throws {
        let env = try await makeEnv(installSecond: false)
        XCTAssertEqual(env.coordinator.state, .serverStopped)

        await env.coordinator.useManagedModel(changed: false)
        XCTAssertEqual(env.server.startedPlans.count, 1)
        XCTAssertEqual(env.coordinator.state, .serverReady)

        await env.coordinator.useManagedModel(changed: false)
        XCTAssertEqual(env.server.startedPlans.count, 1, "a running server with this model is left alone")
        XCTAssertEqual(env.server.stopCalls, 0)
    }

    func testAFailedDownloadIsForgottenWhenAnotherModelIsChosen() async throws {
        let env = try await makeEnv(installSecond: false)
        env.transport.failure = { _ in ModelInstallError.network("offline") }
        env.config.value.managedModel = env.second
        await env.coordinator.useManagedModel(changed: true)
        try await waitUntil("the failure") { if case .failed = env.coordinator.downloadState { true } else { false } }
        XCTAssertEqual(env.coordinator.activity, .failed(ModelInstallError.network("offline").localizedDescription))

        env.config.value.managedModel = env.first
        await env.coordinator.useManagedModel(changed: true)
        XCTAssertEqual(env.coordinator.downloadState, .idle)
        XCTAssertEqual(env.coordinator.activity, .running)
    }

    func testADownloadIsShownAheadOfTheServer() {
        let running = LocalServerStatus.running(pid: 1, managedByLint: true)
        let downloading = ModelDownloadState.downloading(bytesReceived: 1, totalBytes: 4)
        XCTAssertEqual(
            LocalModelActivity.resolve(serverStatus: .stopped, sleep: .unknown, isRestarting: false, download: downloading),
            .downloading(downloading)
        )
        XCTAssertEqual(
            LocalModelActivity.resolve(serverStatus: running, sleep: .awake, isRestarting: false, download: .verifying),
            .downloading(.verifying)
        )
        XCTAssertEqual(
            LocalModelActivity.resolve(serverStatus: running, sleep: .awake, isRestarting: true, download: downloading),
            .restarting
        )
        XCTAssertEqual(
            LocalModelActivity.resolve(serverStatus: running, sleep: .awake, isRestarting: false, download: .failed(.network("x"))),
            .running, "a failed download does not hide a server that works"
        )
        XCTAssertEqual(
            LocalModelActivity.resolve(serverStatus: .stopped, sleep: .unknown, isRestarting: false, download: .cancelled),
            .notLoaded
        )
    }
}
