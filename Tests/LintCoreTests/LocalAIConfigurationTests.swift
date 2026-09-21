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
        XCTAssertEqual(plan.arguments, ["-m", expected.path, "--host", "127.0.0.1", "--port", "8123", "-ngl", "99"])
        XCTAssertFalse(plan.arguments.contains("-hf"), "starting the server must never download a model")
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
