import XCTest

@testable import LintCore

@MainActor
final class FakeServer: LocalServerControlling {
    var status: LocalServerStatus = .stopped
    var logTail = ""
    var healthy = false
    var startError: Error?
    private(set) var startedPlans: [LlamaServerLaunchPlan] = []
    private(set) var stopCalls = 0

    func isHealthy(port: Int) async -> Bool { healthy }

    func start(plan: LlamaServerLaunchPlan, port: Int) async throws -> Bool {
        if healthy { return false }
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
