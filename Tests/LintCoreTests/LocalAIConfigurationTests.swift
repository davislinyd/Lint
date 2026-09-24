import XCTest

@testable import LintCore

final class LocalAIConfigurationTests: XCTestCase {
    private var runtime: LlamaRuntimeLocation {
        LlamaRuntimeLocation(binaryURL: URL(fileURLWithPath: "/Applications/Lint.app/Contents/Resources/LlamaRuntime/arm64/llama-server"), origin: .bundled)
    }

    // MARK: - Managed model launches with -m

    func testAManagedInstalledModelLaunchesWithAnExplicitLocalFile() async throws {
        let (model, remote) = TestModel.twoShards()
        let paths = LocalAIPaths(root: try TestSupport.makeTempDirectory())
        let downloader = ModelDownloadManager(paths: paths, transport: FakeTransport(remote: remote), diskSpace: FakeDiskSpace(bytes: 1 << 40))
        let installed = await downloader.install(model)
        XCTAssertEqual(installed, .installed)

        let configuration = LocalAIConfiguration(modelSource: .managed, managedModel: model, port: 8123, extraArguments: "-ngl 99 --host 0.0.0.0")
        let reference = try configuration.modelReference(using: LocalModelManager(paths: paths)).get()
        let expected = paths.installDirectory(for: model).appendingPathComponent("m-00001-of-00002.gguf")
        XCTAssertEqual(reference, .file(expected), "the first shard; llama.cpp finds the second next to it")

        let plan = configuration.launchPlan(runtime: runtime, model: reference)
        XCTAssertEqual(plan.executableURL, runtime.binaryURL)
        XCTAssertEqual(Array(plan.arguments.prefix(6)), ["-m", expected.path, "--host", "127.0.0.1", "--port", "8123"])
        XCTAssertEqual(Array(plan.arguments.suffix(2)), ["-ngl", "99"], "the advanced field is appended last")
        XCTAssertFalse(plan.arguments.contains("-hf"), "starting the server must never download a model")
        XCTAssertFalse(plan.arguments.contains("0.0.0.0"), "the server stays on loopback")
    }

    func testAMissingManagedModelIsNotSetUpAndAnInvalidOneIsReported() throws {
        let paths = LocalAIPaths(root: try TestSupport.makeTempDirectory())
        let manager = LocalModelManager(paths: paths)
        let configuration = LocalAIConfiguration()
        XCTAssertEqual(configuration.modelReference(using: manager), .failure(.notSetUp))
        XCTAssertEqual(LocalAIError.notSetUp.errorDescription, String(localized: "本機 AI 尚未設定。"))

        let dir = paths.installDirectory(for: configuration.managedModel)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data("junk".utf8).write(to: dir.appendingPathComponent(configuration.managedModel.primaryFile.fileName))
        guard case .failure(.modelInvalid) = configuration.modelReference(using: manager) else {
            return XCTFail("a damaged model folder is reported, not launched")
        }
    }

    func testACustomHuggingFaceModelKeepsTheLegacyDashHF() {
        let configuration = LocalAIConfiguration(modelSource: .custom, huggingFaceSpec: " someone/model:q4 ")
        let reference = try! configuration.modelReference(using: LocalModelManager(paths: LocalAIPaths(root: URL(fileURLWithPath: "/nonexistent")))).get()
        XCTAssertEqual(reference, .huggingFace("someone/model:q4"))
        XCTAssertEqual(LocalAIConfiguration(modelSource: .custom, huggingFaceSpec: "  ").effectiveHuggingFaceSpec, ModelCatalog.recommended.huggingFaceSpec)
    }

    // MARK: - Model source migration

    func testMigrationOfExistingModelSettings() {
        let recommended = ModelCatalog.recommended
        let none: (ModelDescriptor) -> Bool = { _ in false }
        let cached: (ModelDescriptor) -> Bool = { _ in true }

        XCTAssertEqual(LocalModelMigration.migrate(storedSpec: nil, hasCompleteHuggingFaceCopy: none), .init(source: .managed, managedModelID: recommended.id), "a new user gets the managed model")
        XCTAssertEqual(LocalModelMigration.migrate(storedSpec: "  ", hasCompleteHuggingFaceCopy: cached), .init(source: .managed, managedModelID: recommended.id))
        XCTAssertEqual(LocalModelMigration.migrate(storedSpec: recommended.huggingFaceSpec, hasCompleteHuggingFaceCopy: none), .init(source: .managed, managedModelID: recommended.id),
                       "the old default, not downloaded yet: Lint installs it")
        XCTAssertEqual(LocalModelMigration.migrate(storedSpec: recommended.huggingFaceSpec.uppercased(), hasCompleteHuggingFaceCopy: cached), .init(source: .custom, managedModelID: recommended.id),
                       "the old default that is already cached keeps working with no second download")
        XCTAssertEqual(LocalModelMigration.migrate(storedSpec: "unsloth/gemma-3-4b-it-GGUF:Q4_K_M", hasCompleteHuggingFaceCopy: none), .init(source: .custom, managedModelID: recommended.id),
                       "the user's own model is never replaced")
        for copy in [none, cached] {
            XCTAssertEqual(LocalModelMigration.migrate(storedSpec: " Qwen/Qwen2.5-7B-Instruct-GGUF:Q4_K_M ", hasCompleteHuggingFaceCopy: copy), .init(source: .managed, managedModelID: recommended.id),
                           "the retired Qwen default was never a choice: it moves to the recommended model, cached or not")
        }
        XCTAssertTrue(LocalModelMigration.isRetiredDefault(LocalModelMigration.retiredDefaultSpec))
        XCTAssertFalse(LocalModelMigration.isRetiredDefault(nil))
        XCTAssertFalse(LocalModelMigration.isRetiredDefault(recommended.huggingFaceSpec))
        XCTAssertFalse(LocalModelMigration.isRetiredDefault("Qwen/Qwen2.5-14B-Instruct-GGUF:q4_k_m"), "only the exact old default")
    }
}

/// The tuning and the idle-sleep setting reach llama-server through the configuration, and only a
/// model Lint manages brings a profile of its own.
final class LocalAIConfigurationTuningTests: XCTestCase {
    private var runtime: LlamaRuntimeLocation {
        LlamaRuntimeLocation(binaryURL: URL(fileURLWithPath: "/llama-server"), origin: .bundled)
    }

    func testAManagedModelBringsItsOwnProfileAndACustomOneGetsLintsNeutralTuning() {
        let gemma = LocalAIConfiguration(modelSource: .managed, managedModel: ModelCatalog.gemma4_12bQATQ4_0)
        XCTAssertEqual(gemma.runtimeProfile, ModelCatalog.gemma4_12bQATQ4_0.runtimeProfile)
        XCTAssertEqual(gemma.runtimeProfile.reasoningArguments, ["--reasoning", "off"], "Gemma 4 thinks unless told not to")

        let custom = LocalAIConfiguration(modelSource: .custom, huggingFaceSpec: "someone/model:q4")
        XCTAssertEqual(custom.runtimeProfile, .unknownModel)
        XCTAssertEqual(custom.runtimeProfile.reasoningArguments, ["--reasoning", "off"], "Lint never wants reasoning text")
    }

    func testTheIdleSleepSettingReachesTheCommandLine() {
        let model = LocalModelReference.file(URL(fileURLWithPath: "/m.gguf"))
        let off = LocalAIConfiguration(idleSleepSeconds: 0).launchPlan(runtime: runtime, model: model)
        XCTAssertFalse(off.arguments.contains("--sleep-idle-seconds"))

        let on = LocalAIConfiguration(idleSleepSeconds: 600).launchPlan(runtime: runtime, model: model)
        let index = try? XCTUnwrap(on.arguments.firstIndex(of: "--sleep-idle-seconds"))
        XCTAssertEqual(index.map { on.arguments[$0 + 1] }, "600")
        XCTAssertEqual(LocalAIConfiguration().idleSleepSeconds, 300, "on by default, at five minutes")
    }

    func testAStoredModelThisBuildDoesNotKnowFallsBackToTheRecommendedOne() {
        XCTAssertEqual(ModelCatalog.resolveManagedModelID("qwen2.5-7b-instruct-q4_k_m"), ModelCatalog.recommended.id)
        XCTAssertEqual(ModelCatalog.resolveManagedModelID(nil), ModelCatalog.recommended.id)
        XCTAssertEqual(ModelCatalog.resolveManagedModelID(" gemma-4-12b-it-qat-q4_0 "), "gemma-4-12b-it-qat-q4_0")
    }
}

/// Gemma 4 E4B replaced Gemma 4 12B as the default. Everyone who has 12B keeps it; an install that
/// only had 12B stored as the old default, and never downloaded it, starts from E4B.
final class UninstalledDefaultMigrationTests: XCTestCase {
    private let gemma12 = "gemma-4-12b-it-qat-q4_0"
    private let e4b = "gemma-4-e4b-it-qat-q4_0"
    private let none: (ModelDescriptor) -> Bool = { _ in false }
    private let gemma12OnDisk: (ModelDescriptor) -> Bool = { $0.id == "gemma-4-12b-it-qat-q4_0" }

    private func migrate(_ stored: String?, _ source: LocalModelSource = .managed, disk: (ModelDescriptor) -> Bool) -> String {
        LocalModelMigration.migrateUninstalledPreviousDefault(storedID: stored, source: source, hasLocalCopy: disk) ?? (stored ?? "")
    }

    func testAFreshInstallGetsE4B() {
        XCTAssertEqual(LocalModelMigration.migrate(storedSpec: nil, hasCompleteHuggingFaceCopy: none).managedModelID, e4b)
        XCTAssertNil(LocalModelMigration.migrateUninstalledPreviousDefault(storedID: nil, source: .managed, hasLocalCopy: none))
        XCTAssertEqual(ModelCatalog.resolveManagedModelID(nil), e4b)
    }

    func testSomeoneWith12BOnDiskStaysOn12B() {
        XCTAssertEqual(migrate(gemma12, disk: gemma12OnDisk), gemma12, "installed, damaged or partly downloaded all count")
    }

    func test12BStoredButNeverDownloadedStartsFromE4B() {
        XCTAssertEqual(migrate(gemma12, disk: none), e4b, "nothing to keep; nothing is downloaded either")
    }

    func testAnythingElseIsLeftAlone() {
        XCTAssertEqual(migrate("qwen3-4b-instruct-2507-q4_k_m", disk: none), "qwen3-4b-instruct-2507-q4_k_m", "a model the user chose")
        XCTAssertEqual(migrate(e4b, disk: none), e4b)
        XCTAssertEqual(migrate(gemma12, .custom, disk: none), gemma12, "a custom -hf source keeps its stored id")
    }

    func testMigratingTwiceGivesTheSameAnswer() {
        for (stored, disk) in [(gemma12, none), (gemma12, gemma12OnDisk), (e4b, none), ("llama-9000", none)] {
            let once = migrate(stored, disk: disk)
            XCTAssertEqual(migrate(once, disk: disk), once, "stored \(stored)")
        }
    }

    func testALocalCopyIsAnInstallADamagedFolderOrAPartialDownload() throws {
        let paths = LocalAIPaths(root: try TestSupport.makeTempDirectory())
        let manager = LocalModelManager(paths: paths)
        let model = ModelCatalog.gemma4_12bQATQ4_0
        XCTAssertFalse(manager.hasLocalCopy(of: model))
        let staging = paths.stagingDirectory(for: model)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        try Data("GGUFpartial".utf8).write(to: staging.appendingPathComponent(model.primaryFile.fileName + ".partial"))
        XCTAssertTrue(manager.hasLocalCopy(of: model), "a download that was started")
        try FileManager.default.removeItem(at: staging)
        try FileManager.default.createDirectory(at: paths.installDirectory(for: model), withIntermediateDirectories: true)
        XCTAssertTrue(manager.hasLocalCopy(of: model), "a damaged install is still the user's")
    }
}
