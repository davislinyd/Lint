import XCTest

@testable import LintCore

/// Runs Scripts/fetch-llama-runtime.sh and Scripts/sign-llama-runtime.sh against small archives built
/// on the spot (file:// URLs, no network, nothing from upstream). The archives hold tiny binaries
/// compiled with clang; the scripts must never run them, and these tests do not either.
final class RuntimeScriptTests: XCTestCase {
    nonisolated(unsafe) private static var binaries: [String: URL] = [:] // "arm64" / "x86_64" -> directory with llama-server + libfixture.0.dylib
    nonisolated(unsafe) private static var setupError: String?

    override class func setUp() {
        super.setUp()
        guard let clang = try? TestSupport.run("/usr/bin/xcrun", ["--find", "clang"]), clang.status == 0 else {
            setupError = "clang is not available"
            return
        }
        let compiler = clang.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let root = try? TestSupport.makeTempDirectory("fixtures") else { setupError = "no temp directory"; return }
        do {
            try "int fixture_value(void) { return 42; }\n".write(to: root.appendingPathComponent("lib.c"), atomically: true, encoding: .utf8)
            try "int fixture_value(void);\nint main(void) { return fixture_value() == 42 ? 0 : 1; }\n"
                .write(to: root.appendingPathComponent("main.c"), atomically: true, encoding: .utf8)
            for arch in ["arm64", "x86_64"] {
                let dir = root.appendingPathComponent(arch, isDirectory: true)
                try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                let lib = try TestSupport.run(compiler, [
                    "-arch", arch, "-dynamiclib", "-install_name", "@rpath/libfixture.0.dylib",
                    "-o", dir.appendingPathComponent("libfixture.0.dylib").path, root.appendingPathComponent("lib.c").path,
                ])
                let bin = try TestSupport.run(compiler, [
                    "-arch", arch, "-o", dir.appendingPathComponent("llama-server").path, root.appendingPathComponent("main.c").path,
                    "-L", dir.path, "-lfixture.0", "-Wl,-rpath,@loader_path",
                ])
                guard lib.status == 0, bin.status == 0 else {
                    setupError = "cannot build the \(arch) fixture: \(lib.stderr)\(bin.stderr)"
                    return
                }
                binaries[arch] = dir
            }
        } catch {
            setupError = "\(error)"
        }
    }

    override func setUpWithError() throws {
        if let error = Self.setupError { throw XCTSkip(error) }
    }

    // MARK: - Fixture archives

    private struct Fixture {
        var root: URL
        var archive: URL
        var sha: String
        var cache: URL { root.appendingPathComponent("cache") }
        var stage: URL { root.appendingPathComponent("stage") }
        var manifest: URL { root.appendingPathComponent("manifest.json") }
    }

    /// Builds `llama-bTEST-bin-macos-<arch>.tar.gz` from the compiled fixture and a manifest for it.
    private func makeFixture(
        binariesFor arch: String = "arm64", withDependency: Bool = true, withLicense: Bool = true,
        manifestArch: String = "arm64", url: ((URL) -> String)? = nil, sha: ((String) -> String)? = nil
    ) throws -> Fixture {
        let root = try TestSupport.makeTempDirectory()
        let top = root.appendingPathComponent("build/llama-bTEST", isDirectory: true)
        try FileManager.default.createDirectory(at: top, withIntermediateDirectories: true)
        let source = try XCTUnwrap(Self.binaries[arch])
        try FileManager.default.copyItem(at: source.appendingPathComponent("llama-server"), to: top.appendingPathComponent("llama-server"))
        if withDependency {
            try FileManager.default.copyItem(at: source.appendingPathComponent("libfixture.0.dylib"), to: top.appendingPathComponent("libfixture.0.dylib"))
        }
        // An unrelated file the runtime does not need must not be staged.
        try Data("unused".utf8).write(to: top.appendingPathComponent("llama-unused-tool"))
        if withLicense { try Data("MIT License\nfixture\n".utf8).write(to: top.appendingPathComponent("LICENSE")) }
        let archive = root.appendingPathComponent("llama-bTEST-bin-macos-\(manifestArch).tar.gz")
        let tar = try TestSupport.run("/usr/bin/tar", ["-czf", archive.path, "-C", top.deletingLastPathComponent().path, "llama-bTEST"])
        XCTAssertEqual(tar.status, 0, tar.stderr)
        let digest = try TestSupport.run("/usr/bin/shasum", ["-a", "256", archive.path]).stdout.split(separator: " ").first.map(String.init) ?? ""
        let fixture = Fixture(root: root, archive: archive, sha: digest)

        let manifest = """
        {
          "schemaVersion": 1,
          "upstream": { "project": "test/llama.cpp", "tag": "bTEST", "build": 1, "commit": "abcdef0" },
          "runtimes": {
            "\(manifestArch)": {
              "assetName": "\(archive.lastPathComponent)",
              "url": "\(url?(archive) ?? archive.absoluteString)",
              "sha256": "\(sha?(digest) ?? digest)",
              "archiveRoot": "llama-bTEST"
            }
          },
          "licenses": []
        }
        """
        try manifest.write(to: fixture.manifest, atomically: true, encoding: .utf8)
        return fixture
    }

    private func fetch(_ fixture: Fixture, arch: String = "arm64", allowFileURLs: Bool = true) throws -> TestSupport.ProcessResult {
        try TestSupport.run(TestSupport.script("fetch-llama-runtime.sh"), ["--arch", arch], environment: [
            "LINT_LLAMA_MANIFEST": fixture.manifest.path,
            "LINT_LLAMA_CACHE_DIR": fixture.cache.path,
            "LINT_LLAMA_STAGE_DIR": fixture.stage.path,
            "LINT_LLAMA_ALLOW_FILE_URLS": allowFileURLs ? "1" : "0",
        ])
    }

    // MARK: - fetch-llama-runtime.sh

    func testFetchStagesTheRuntimeAndProducesInfoTheAppCanVerify() throws {
        let fixture = try makeFixture()
        let result = try fetch(fixture)
        XCTAssertEqual(result.status, 0, result.stderr)
        let stage = URL(fileURLWithPath: result.stdout.trimmingCharacters(in: .whitespacesAndNewlines))
        XCTAssertEqual(stage.path, fixture.stage.appendingPathComponent("arm64").path, "stdout is only the staging directory")

        let names = try FileManager.default.contentsOfDirectory(atPath: stage.path).sorted()
        XCTAssertEqual(names, ["libfixture.0.dylib", "licenses", "llama-server", "runtime-info.json"], "only what llama-server needs is staged")
        XCTAssertTrue(FileManager.default.fileExists(atPath: stage.appendingPathComponent("licenses/LICENSE").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: stage.appendingPathComponent("licenses/NOTICE-Lint.txt").path))

        let info = try JSONDecoder().decode(LlamaRuntimeInfo.self, from: Data(contentsOf: stage.appendingPathComponent("runtime-info.json")))
        XCTAssertEqual(info.tag, "bTEST")
        XCTAssertEqual(info.architecture, .arm64)
        XCTAssertEqual(info.archiveSHA256, fixture.sha)
        XCTAssertEqual(info.files, ["libfixture.0.dylib", "llama-server"])

        // What the script staged is exactly what the app-side verifier accepts (real Mach-O headers and signatures).
        XCTAssertEqual(LlamaRuntimeVerifier().verify(directory: stage, expected: .arm64), .success(info))
    }

    func testAWrongHashMakesFetchFailBeforeAnythingIsUsed() throws {
        let fixture = try makeFixture(sha: { _ in String(repeating: "a", count: 64) })
        let result = try fetch(fixture)
        XCTAssertNotEqual(result.status, 0)
        XCTAssertTrue(result.stderr.contains("SHA-256 mismatch"), result.stderr)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.stage.path), "nothing may be staged from an unverified archive")
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.cache.appendingPathComponent(fixture.archive.lastPathComponent).path),
                       "an archive that failed the check must not stay in the cache")
    }

    func testACachedFileIsVerifiedAgainNotTrusted() throws {
        let fixture = try makeFixture()
        try FileManager.default.createDirectory(at: fixture.cache, withIntermediateDirectories: true)
        try Data("corrupted cache".utf8).write(to: fixture.cache.appendingPathComponent(fixture.archive.lastPathComponent))
        let result = try fetch(fixture)
        XCTAssertEqual(result.status, 0, result.stderr)
        XCTAssertTrue(result.stderr.contains("cached copy fails its SHA-256 check"), result.stderr)

        // And the good cache is reused, but still verified.
        let again = try fetch(fixture)
        XCTAssertEqual(again.status, 0, again.stderr)
        XCTAssertTrue(again.stderr.contains("cached copy verified"), again.stderr)
    }

    func testAnArchitectureMismatchFails() throws {
        let fixture = try makeFixture(binariesFor: "x86_64", manifestArch: "arm64")
        let result = try fetch(fixture, arch: "arm64")
        XCTAssertNotEqual(result.status, 0)
        XCTAssertTrue(result.stderr.contains("expected exactly 'arm64'"), result.stderr)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.stage.path))
    }

    func testAnUnresolvedDependencyFails() throws {
        let fixture = try makeFixture(withDependency: false)
        let result = try fetch(fixture)
        XCTAssertNotEqual(result.status, 0)
        XCTAssertTrue(result.stderr.contains("unresolved dependency"), result.stderr)
        XCTAssertTrue(result.stderr.contains("libfixture.0.dylib"), result.stderr)
    }

    func testAnArchiveWithoutALicenseIsRefused() throws {
        let fixture = try makeFixture(withLicense: false)
        let result = try fetch(fixture)
        XCTAssertNotEqual(result.status, 0)
        XCTAssertTrue(result.stderr.contains("LICENSE"), result.stderr)
    }

    func testOnlyPinnedHTTPSURLsAreAccepted() throws {
        let plainHTTP = try makeFixture(url: { _ in "http://example.com/llama-bTEST.tar.gz" })
        XCTAssertTrue(try fetch(plainHTTP).stderr.contains("must be an https:// URL"))

        let latest = try makeFixture(url: { _ in "https://github.com/ggml-org/llama.cpp/releases/latest/download/x.tar.gz" })
        XCTAssertTrue(try fetch(latest).stderr.contains("'latest'"))

        let file = try makeFixture()
        let refused = try fetch(file, allowFileURLs: false)
        XCTAssertNotEqual(refused.status, 0)
        XCTAssertTrue(refused.stderr.contains("only https is allowed"), refused.stderr)
    }

    func testAnArchitectureWithoutAPinFailsClearly() throws {
        let fixture = try makeFixture()
        let result = try fetch(fixture, arch: "x86_64")
        XCTAssertNotEqual(result.status, 0)
        XCTAssertTrue(result.stderr.contains("pins no llama.cpp runtime for x86_64"), result.stderr)

        let missing = try TestSupport.run(TestSupport.script("fetch-llama-runtime.sh"), [])
        XCTAssertNotEqual(missing.status, 0)
        XCTAssertTrue(missing.stderr.contains("--arch is required"), missing.stderr)
        let unknown = try TestSupport.run(TestSupport.script("fetch-llama-runtime.sh"), ["--arch", "riscv"])
        XCTAssertNotEqual(unknown.status, 0)
    }

    func testTheShippedManifestPinsExactVerifiedReleases() throws {
        let data = try Data(contentsOf: TestSupport.repoRoot.appendingPathComponent("Resources/LlamaRuntimeManifest.json"))
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(json["schemaVersion"] as? Int, 1)
        let upstream = try XCTUnwrap(json["upstream"] as? [String: Any])
        let tag = try XCTUnwrap(upstream["tag"] as? String)
        XCTAssertTrue(tag.range(of: "^b[0-9]+$", options: .regularExpression) != nil, "pinned to an exact upstream build tag, not 'latest'")
        XCTAssertEqual((upstream["commit"] as? String)?.count, 40)
        let runtimes = try XCTUnwrap(json["runtimes"] as? [String: [String: Any]])
        XCTAssertNotNil(runtimes["arm64"], "the architecture Lint ships today must be pinned")
        for (arch, entry) in runtimes {
            XCTAssertTrue(["arm64", "x86_64"].contains(arch))
            let url = try XCTUnwrap(entry["url"] as? String)
            XCTAssertTrue(url.hasPrefix("https://"), url)
            XCTAssertTrue(url.contains("/\(tag)/"), "\(arch): the URL must contain the pinned tag")
            XCTAssertFalse(url.contains("latest"))
            let sha = try XCTUnwrap(entry["sha256"] as? String)
            XCTAssertNotNil(sha.range(of: "^[0-9a-f]{64}$", options: .regularExpression), "\(arch): sha256")
        }
    }

    // MARK: - sign-llama-runtime.sh

    private func stageAndSign() throws -> URL {
        let fixture = try makeFixture()
        let staged = URL(fileURLWithPath: try fetch(fixture).stdout.trimmingCharacters(in: .whitespacesAndNewlines))
        let result = try TestSupport.run(TestSupport.script("sign-llama-runtime.sh"), [staged.path, "-"])
        XCTAssertEqual(result.status, 0, result.stderr)
        return staged
    }

    func testSigningCoversEveryFile() throws {
        let staged = try stageAndSign()
        for name in ["llama-server", "libfixture.0.dylib"] {
            let url = staged.appendingPathComponent(name)
            let verify = try TestSupport.run("/usr/bin/codesign", ["--verify", "--strict", url.path])
            XCTAssertEqual(verify.status, 0, verify.stderr)
            let details = try TestSupport.run("/usr/bin/codesign", ["-dvv", url.path])
            XCTAssertTrue(details.stderr.contains("Identifier=app.lint.assistant."), details.stderr)
            XCTAssertFalse(details.stderr.contains("(runtime)"), "development signing must not enable Hardened Runtime (library validation would reject ad-hoc dylibs)")
        }
        XCTAssertEqual(LlamaRuntimeVerifier().verify(directory: staged, expected: .arm64).isSuccess, true)
    }

    func testAByteAppendedToASignedDylibIsDetected() throws {
        let staged = try stageAndSign()
        let handle = try FileHandle(forWritingTo: staged.appendingPathComponent("libfixture.0.dylib"))
        try handle.seekToEnd()
        try handle.write(contentsOf: Data([0x78]))
        try handle.close()
        XCTAssertEqual(LlamaRuntimeVerifier().verify(directory: staged, expected: .arm64), .failure(.invalidSignature("libfixture.0.dylib")))
    }

    func testARememberedSignatureResultNeverHidesALaterChange() throws {
        let staged = try stageAndSign()
        let binary = staged.appendingPathComponent("llama-server")
        let checker = SecurityFrameworkSignatureChecker()
        XCTAssertTrue(checker.hasValidSignature(at: binary))
        XCTAssertTrue(checker.hasValidSignature(at: binary), "unchanged: answered from memory")

        // A real change rewrites the file, which changes its modification time, so it is checked afresh.
        var bytes = try Data(contentsOf: binary)
        bytes[bytes.count / 3] ^= 0xFF
        try bytes.write(to: binary)
        XCTAssertFalse(SecurityFrameworkSignatureChecker().hasValidSignature(at: binary), "a modified file is checked again")
        XCTAssertFalse(checker.hasValidSignature(at: binary))
    }

    func testAChangedByteInASignedBinaryIsDetected() throws {
        let staged = try stageAndSign()
        let binary = staged.appendingPathComponent("llama-server")
        var bytes = try Data(contentsOf: binary)
        bytes[bytes.count / 3] ^= 0xFF
        try bytes.write(to: binary)
        XCTAssertEqual(LlamaRuntimeVerifier().verify(directory: staged, expected: .arm64), .failure(.invalidSignature("llama-server")))
    }

    func testAReleaseRuntimeCannotBeAdHocSigned() throws {
        let fixture = try makeFixture()
        let staged = URL(fileURLWithPath: try fetch(fixture).stdout.trimmingCharacters(in: .whitespacesAndNewlines))
        let result = try TestSupport.run(TestSupport.script("sign-llama-runtime.sh"), [staged.path, "-", "--release"])
        XCTAssertNotEqual(result.status, 0)
        XCTAssertTrue(result.stderr.contains("cannot be ad-hoc signed"), result.stderr)
    }

    // MARK: - Scripts stay free of Homebrew

    func testTheRuntimeScriptsDoNotUseHomebrew() throws {
        for name in ["fetch-llama-runtime.sh", "sign-llama-runtime.sh", "package-app.sh"] {
            let text = try String(contentsOfFile: TestSupport.script(name), encoding: .utf8)
            for line in text.split(separator: "\n") where !line.trimmingCharacters(in: .whitespaces).hasPrefix("#") {
                XCTAssertFalse(line.contains("brew"), "\(name) must not call Homebrew: \(line)")
            }
        }
    }
}

extension Result {
    fileprivate var isSuccess: Bool {
        if case .success = self { return true }
        return false
    }
}
