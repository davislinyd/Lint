import Foundation
import XCTest

@testable import LintCore

enum TestSupport {
    static var repoRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    static func makeTempDirectory(_ name: String = #function) throws -> URL {
        let sanitized = name.filter { $0.isLetter || $0.isNumber }
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("lint-tests-\(sanitized)-\(UUID().uuidString.prefix(8))", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    struct ProcessResult {
        var status: Int32
        var stdout: String
        var stderr: String
    }

    static func run(
        _ executable: String, _ arguments: [String] = [], environment: [String: String] = [:], currentDirectory: URL? = nil
    ) throws -> ProcessResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        var env = ProcessInfo.processInfo.environment
        for (key, value) in environment { env[key] = value }
        process.environment = env
        process.currentDirectoryURL = currentDirectory
        let out = Pipe()
        let err = Pipe()
        process.standardOutput = out
        process.standardError = err
        try process.run()
        // Read before waiting so a chatty process cannot fill the pipe and block.
        let outData = out.fileHandleForReading.readDataToEndOfFile()
        let errData = err.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return ProcessResult(
            status: process.terminationStatus,
            stdout: String(decoding: outData, as: UTF8.self),
            stderr: String(decoding: errData, as: UTF8.self)
        )
    }

    static func script(_ name: String) -> String {
        repoRoot.appendingPathComponent("Scripts/\(name)").path
    }
}

/// Bytes that look like a Mach-O header to `MachOInspector` (and nothing else). Never executed.
enum FakeMachO {
    static func thin(_ architecture: CPUArchitecture) -> Data {
        let cpuType: UInt32 = architecture == .arm64 ? 0x0100_000C : 0x0100_0007
        return header(magic: 0xFEED_FACF, cpuType: cpuType) + Data(repeating: 0, count: 64)
    }

    private static func header(magic: UInt32, cpuType: UInt32) -> Data {
        var data = Data()
        for value in [magic, cpuType] {
            var le = value.littleEndian
            withUnsafeBytes(of: &le) { data.append(contentsOf: $0) }
        }
        return data
    }

    static func fat(_ architectures: [CPUArchitecture]) -> Data {
        func be(_ value: UInt32) -> [UInt8] { [24, 16, 8, 0].map { UInt8((value >> UInt32($0)) & 0xFF) } }
        var bytes = be(0xCAFE_BABE) + be(UInt32(architectures.count))
        for arch in architectures {
            bytes += be(arch == .arm64 ? 0x0100_000C : 0x0100_0007) + be(0) + be(0x4000) + be(0x100) + be(14)
        }
        return Data(bytes) + Data(repeating: 0, count: 64)
    }
}

/// A fake app `Resources` directory holding `LlamaRuntime/<arch>/…`.
struct RuntimeFixture {
    let resources: URL
    let architecture: CPUArchitecture
    var runtimeDirectory: URL {
        resources.appendingPathComponent("LlamaRuntime/\(architecture.rawValue)", isDirectory: true)
    }

    static func make(
        in root: URL, architecture: CPUArchitecture = .arm64, files: [String] = ["libggml.0.dylib", "llama-server"]
    ) throws -> RuntimeFixture {
        let fixture = RuntimeFixture(resources: root.appendingPathComponent("Resources", isDirectory: true), architecture: architecture)
        try FileManager.default.createDirectory(at: fixture.runtimeDirectory, withIntermediateDirectories: true)
        for name in files {
            let url = fixture.runtimeDirectory.appendingPathComponent(name)
            try FakeMachO.thin(architecture).write(to: url)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        }
        let info = LlamaRuntimeInfo(
            upstream: "test/llama.cpp", tag: "b1", build: 1, commit: "abc",
            architecture: architecture, assetName: "x.tar.gz", archiveSHA256: String(repeating: "0", count: 64),
            files: files
        )
        try JSONEncoder().encode(info).write(to: fixture.runtimeDirectory.appendingPathComponent(LlamaRuntimeInfo.fileName))
        return fixture
    }
}

struct RejectingSignatureChecker: CodeSignatureChecking {
    var rejected: Set<String>
    func hasValidSignature(at url: URL) -> Bool { !rejected.contains(url.lastPathComponent) }
}
