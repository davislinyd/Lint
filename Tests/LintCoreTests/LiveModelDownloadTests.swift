import XCTest

@testable import LintCore

/// Hits the real Hugging Face (a 1.2 MB public GGUF), so it only runs with LINT_LIVE_DOWNLOAD=1.
/// It proves what the stub tests cannot: redirects to the CDN and Range resume work for real.
final class LiveModelDownloadTests: XCTestCase {
    private let model = ModelDescriptor(
        id: "live-tiny-llama", displayName: "stories260K", repository: "ggml-org/tiny-llamas",
        revision: "99dd1a73db5a37100bd4ae633f4cfce6560e1567", quantization: "F32", license: "n/a",
        files: [
            ModelFile(
                fileName: "stories260K.gguf",
                url: URL(string: "https://huggingface.co/ggml-org/tiny-llamas/resolve/99dd1a73db5a37100bd4ae633f4cfce6560e1567/stories260K.gguf")!,
                sizeBytes: 1_185_376,
                sha256: "047bf46455a544931cff6fef14d7910154c56afbc23ab1c5e56a72e69912c04b"
            )
        ],
        recommended: false, huggingFaceSpec: "ggml-org/tiny-llamas"
    )

    func testARealDownloadInstallsAndAPartialOneResumes() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["LINT_LIVE_DOWNLOAD"] == "1", "set LINT_LIVE_DOWNLOAD=1 to download a 1.2 MB file from Hugging Face")
        let paths = LocalAIPaths(root: try TestSupport.makeTempDirectory())
        let manager = ModelDownloadManager(paths: paths)
        let log = StateLog()

        let first = await manager.install(model) { log.append($0) }
        XCTAssertEqual(first, .installed, "\(log.states)")
        let installed = LocalModelManager(paths: paths).status(of: model)
        guard case .installed(let file) = installed else { return XCTFail("\(installed)") }
        XCTAssertEqual(try FileDigest.sha256(of: file), model.files[0].sha256)
        XCTAssertTrue(log.contains { if case .downloading = $0 { true } else { false } })

        // Simulate an interrupted download: keep only the first 400 000 bytes as a partial file.
        let bytes = try Data(contentsOf: file)
        try LocalModelManager(paths: paths).remove(model)
        let staging = paths.stagingDirectory(for: model)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        try bytes.prefix(400_000).write(to: staging.appendingPathComponent("stories260K.gguf.partial"))

        let resumed = await manager.install(model)
        XCTAssertEqual(resumed, .installed)
        guard case .installed(let again) = LocalModelManager(paths: paths).status(of: model) else { return XCTFail() }
        XCTAssertEqual(try Data(contentsOf: again), bytes, "the resumed file equals the original, byte for byte")
    }
}
