import XCTest

@testable import LintCore

final class LlamaRuntimeResolverTests: XCTestCase {
    private func resolver(
        _ fixture: RuntimeFixture?, resources: URL? = nil, architecture: CPUArchitecture = .arm64,
        fallback: [String] = [], checker: any CodeSignatureChecking = AcceptAnySignature()
    ) -> LlamaRuntimeResolver {
        LlamaRuntimeResolver(
            resourcesDirectory: resources ?? fixture?.resources, architecture: architecture,
            fallbackCandidates: fallback, verifier: LlamaRuntimeVerifier(signatureChecker: checker)
        )
    }

    private func makeExecutable(_ name: String, in directory: URL) throws -> String {
        let url = directory.appendingPathComponent(name)
        try Data("#!/bin/sh\n".utf8).write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        return url.path
    }

    // MARK: - Automatic

    func testAutomaticUsesTheBundledRuntime() throws {
        let root = try TestSupport.makeTempDirectory()
        let fixture = try RuntimeFixture.make(in: root)
        let status = resolver(fixture).resolve(source: .automatic, customPath: "")
        let location = try XCTUnwrap(status.location)
        XCTAssertEqual(location.origin, .bundled)
        XCTAssertEqual(location.binaryURL, fixture.runtimeDirectory.appendingPathComponent("llama-server"))
        XCTAssertEqual(location.info?.displayVersion, "llama.cpp b1")
    }

    func testAutomaticPrefersBundledOverAnInstalledHomebrewBinary() throws {
        let root = try TestSupport.makeTempDirectory()
        let fixture = try RuntimeFixture.make(in: root)
        let brew = try makeExecutable("llama-server", in: root)
        let status = resolver(fixture, fallback: [brew]).resolve(source: .automatic, customPath: "")
        XCTAssertEqual(status.location?.origin, .bundled)
    }

    func testMovingTheAppResolvesUnderTheNewLocation() throws {
        let root = try TestSupport.makeTempDirectory()
        let first = try RuntimeFixture.make(in: root.appendingPathComponent("Applications"))
        let firstPath = try XCTUnwrap(resolver(first).resolve(source: .automatic, customPath: "").location).binaryURL.path
        XCTAssertTrue(firstPath.hasPrefix(root.appendingPathComponent("Applications").path))

        // "Move" the app: same content, different place, old place gone.
        let moved = root.appendingPathComponent("Home/Applications/Resources", isDirectory: true)
        try FileManager.default.createDirectory(at: moved.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.moveItem(at: first.resources, to: moved)

        let secondPath = try XCTUnwrap(
            resolver(nil, resources: moved).resolve(source: .automatic, customPath: "").location
        ).binaryURL.path
        XCTAssertTrue(secondPath.hasPrefix(moved.path))
        XCTAssertNotEqual(firstPath, secondPath)
        XCTAssertFalse(FileManager.default.fileExists(atPath: firstPath))
    }

    func testMissingBundledRuntimeFallsBackToAnExternalBinary() throws {
        let root = try TestSupport.makeTempDirectory()
        let brew = try makeExecutable("llama-server", in: root)
        let status = resolver(nil, resources: root.appendingPathComponent("NoRuntimeHere"), fallback: ["/nonexistent/llama-server", brew])
            .resolve(source: .automatic, customPath: "")
        XCTAssertEqual(status.location?.origin, .externalFallback)
        XCTAssertEqual(status.location?.binaryURL.path, brew)
    }

    func testNothingAvailableIsAFriendlyMissingStateNotAnError() throws {
        let root = try TestSupport.makeTempDirectory()
        let status = resolver(nil, resources: root, fallback: ["/nonexistent/llama-server"]).resolve(source: .automatic, customPath: "")
        XCTAssertEqual(status, .missing(source: .automatic))
        let message = try XCTUnwrap(status.userMessage)
        XCTAssertFalse(message.localizedCaseInsensitiveContains("brew"), "the repair hint must not send users to Homebrew")
        XCTAssertFalse(message.localizedCaseInsensitiveContains("homebrew"))
    }

    func testADamagedBundledRuntimeIsNeverReplacedByAnExternalOne() throws {
        let root = try TestSupport.makeTempDirectory()
        let fixture = try RuntimeFixture.make(in: root)
        let brew = try makeExecutable("llama-server", in: root)
        try FileManager.default.removeItem(at: fixture.runtimeDirectory.appendingPathComponent("libggml.0.dylib"))
        let status = resolver(fixture, fallback: [brew]).resolve(source: .automatic, customPath: "")
        guard case .invalid(.automatic, let reason) = status else { return XCTFail("expected invalid, got \(status)") }
        XCTAssertTrue(reason.contains("libggml.0.dylib"))
        XCTAssertNotNil(status.userMessage)
    }

    // MARK: - Verification

    func testArchitectureMismatchInRuntimeInfoIsRejected() throws {
        let root = try TestSupport.makeTempDirectory()
        // An x86_64 runtime shipped in an arm64 app's directory.
        let fixture = try RuntimeFixture.make(in: root, architecture: .arm64)
        let info = LlamaRuntimeInfo(
            upstream: "u", tag: "t", build: 1, commit: "c", architecture: .x86_64,
            assetName: "a", archiveSHA256: "", files: ["libggml.0.dylib", "llama-server"]
        )
        try JSONEncoder().encode(info).write(to: fixture.runtimeDirectory.appendingPathComponent(LlamaRuntimeInfo.fileName))
        let result = LlamaRuntimeVerifier(signatureChecker: AcceptAnySignature())
            .verify(directory: fixture.runtimeDirectory, expected: .arm64)
        XCTAssertEqual(result, .failure(.architectureMismatch(expected: .arm64, found: .x86_64)))
    }

    func testABinaryOfTheWrongArchitectureIsRejected() throws {
        let root = try TestSupport.makeTempDirectory()
        let fixture = try RuntimeFixture.make(in: root, architecture: .arm64)
        try FakeMachO.thin(.x86_64).write(to: fixture.runtimeDirectory.appendingPathComponent("llama-server"))
        XCTAssertEqual(
            LlamaRuntimeVerifier(signatureChecker: AcceptAnySignature()).verify(directory: fixture.runtimeDirectory, expected: .arm64),
            .failure(.wrongFileArchitecture(file: "llama-server", expected: .arm64))
        )
    }

    func testAFatBinaryIsRejectedBecauseTheRuntimeIsPerArchitecture() throws {
        let root = try TestSupport.makeTempDirectory()
        let fixture = try RuntimeFixture.make(in: root, architecture: .arm64)
        try FakeMachO.fat([.arm64, .x86_64]).write(to: fixture.runtimeDirectory.appendingPathComponent("llama-server"))
        XCTAssertEqual(
            LlamaRuntimeVerifier(signatureChecker: AcceptAnySignature()).verify(directory: fixture.runtimeDirectory, expected: .arm64),
            .failure(.wrongFileArchitecture(file: "llama-server", expected: .arm64))
        )
    }

    func testAnInvalidSignatureIsRejected() throws {
        let root = try TestSupport.makeTempDirectory()
        let fixture = try RuntimeFixture.make(in: root)
        let status = resolver(fixture, checker: RejectingSignatureChecker(rejected: ["libggml.0.dylib"]))
            .resolve(source: .automatic, customPath: "")
        XCTAssertEqual(status, .invalid(source: .automatic, reason: LlamaRuntimeVerificationError.invalidSignature("libggml.0.dylib").reason))
    }

    func testBrokenOrUnsafeRuntimeInfoIsRejected() throws {
        let root = try TestSupport.makeTempDirectory()
        let fixture = try RuntimeFixture.make(in: root)
        let infoURL = fixture.runtimeDirectory.appendingPathComponent(LlamaRuntimeInfo.fileName)
        let verifier = LlamaRuntimeVerifier(signatureChecker: AcceptAnySignature())

        try Data("not json".utf8).write(to: infoURL)
        XCTAssertEqual(verifier.verify(directory: fixture.runtimeDirectory, expected: .arm64), .failure(.infoUnreadable))

        try FileManager.default.removeItem(at: infoURL)
        XCTAssertEqual(verifier.verify(directory: fixture.runtimeDirectory, expected: .arm64), .failure(.infoMissing))

        let unsafe = LlamaRuntimeInfo(
            upstream: "u", tag: "t", build: 1, commit: "c", architecture: .arm64,
            assetName: "a", archiveSHA256: "", files: ["../../etc/passwd", "llama-server"]
        )
        try JSONEncoder().encode(unsafe).write(to: infoURL)
        XCTAssertEqual(verifier.verify(directory: fixture.runtimeDirectory, expected: .arm64), .failure(.unexpectedFileName("../../etc/passwd")))
    }

    func testANonExecutableBinaryIsRejected() throws {
        let root = try TestSupport.makeTempDirectory()
        let fixture = try RuntimeFixture.make(in: root)
        let binary = fixture.runtimeDirectory.appendingPathComponent("llama-server")
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: binary.path)
        XCTAssertEqual(
            LlamaRuntimeVerifier(signatureChecker: AcceptAnySignature()).verify(directory: fixture.runtimeDirectory, expected: .arm64),
            .failure(.notExecutable("llama-server"))
        )
    }

    // MARK: - Custom

    func testACustomPathIsUsedInsteadOfTheBundledRuntime() throws {
        let root = try TestSupport.makeTempDirectory()
        let fixture = try RuntimeFixture.make(in: root)
        let custom = try makeExecutable("my-llama-server", in: root)
        let status = resolver(fixture).resolve(source: .custom, customPath: "  \(custom)\n")
        XCTAssertEqual(status.location?.origin, .custom)
        XCTAssertEqual(status.location?.binaryURL.path, custom)
    }

    func testACustomPathThatDoesNotWorkDoesNotFallBackToTheBundledRuntime() throws {
        let root = try TestSupport.makeTempDirectory()
        let fixture = try RuntimeFixture.make(in: root)
        XCTAssertEqual(resolver(fixture).resolve(source: .custom, customPath: ""), .missing(source: .custom))
        XCTAssertEqual(resolver(fixture).resolve(source: .custom, customPath: root.path + "/nope"), .missing(source: .custom))
        XCTAssertEqual(resolver(fixture).resolve(source: .custom, customPath: root.path), .missing(source: .custom), "a directory is not a binary")

        let plain = root.appendingPathComponent("plain")
        try Data("x".utf8).write(to: plain)
        guard case .invalid(.custom, _) = resolver(fixture).resolve(source: .custom, customPath: plain.path) else {
            return XCTFail("a non-executable file must be invalid")
        }
    }

    // MARK: - Migration

    func testHistoricalHomebrewDefaultsMigrateToAutomatic() {
        for path in ["/opt/homebrew/bin/llama-server", "/usr/local/bin/llama-server", " /opt/homebrew/bin/llama-server\n", "", "  "] {
            XCTAssertEqual(
                LocalRuntimeMigration.migrate(storedBinaryPath: path),
                .init(source: .automatic, customPath: ""), "'\(path)'"
            )
        }
        XCTAssertEqual(LocalRuntimeMigration.migrate(storedBinaryPath: nil), .init(source: .automatic, customPath: ""))
    }

    func testAGenuinelyCustomOldPathIsPreserved() {
        for path in ["/Users/me/llama.cpp/build/bin/llama-server", "/opt/homebrew/opt/llama.cpp/bin/llama-server", "/usr/bin/llama-server"] {
            XCTAssertEqual(LocalRuntimeMigration.migrate(storedBinaryPath: path), .init(source: .custom, customPath: path))
        }
    }

    // MARK: - Mach-O

    func testMachOInspectorReadsThinFatAndRejectsOtherFiles() throws {
        let root = try TestSupport.makeTempDirectory()
        func write(_ data: Data, _ name: String) throws -> URL {
            let url = root.appendingPathComponent(name)
            try data.write(to: url)
            return url
        }
        XCTAssertEqual(MachOInspector.architectures(of: try write(FakeMachO.thin(.arm64), "a")), [.arm64])
        XCTAssertEqual(MachOInspector.architectures(of: try write(FakeMachO.thin(.x86_64), "b")), [.x86_64])
        XCTAssertEqual(MachOInspector.architectures(of: try write(FakeMachO.fat([.x86_64, .arm64]), "c")), [.x86_64, .arm64])
        XCTAssertNil(MachOInspector.architectures(of: try write(Data("#!/bin/sh\necho hi\n".utf8), "d")))
        XCTAssertNil(MachOInspector.architectures(of: root.appendingPathComponent("missing")))
        // A real system binary is a Mach-O too.
        XCTAssertNotNil(MachOInspector.architectures(of: URL(fileURLWithPath: "/bin/ls")))
    }
}
