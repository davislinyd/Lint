import Foundation

/// Where the local llama.cpp runtime comes from. `automatic` is the default: Lint's own bundled
/// runtime. `custom` is an advanced override pointing at another `llama-server` binary.
public enum LocalRuntimeSource: String, Codable, CaseIterable, Sendable, Identifiable {
    case automatic
    case custom

    public var id: String { rawValue }
}

/// `runtime-info.json`, written next to `llama-server` by `Scripts/fetch-llama-runtime.sh` and
/// bundled in `Lint.app/Contents/Resources/LlamaRuntime/<arch>/`.
///
/// It lists file names only. Signing changes a file's bytes, so sizes and hashes recorded before
/// signing would be wrong afterwards; the code signature is what proves integrity.
public struct LlamaRuntimeInfo: Codable, Equatable, Sendable {
    public static let fileName = "runtime-info.json"
    public static let supportedSchemaVersion = 1

    public var schemaVersion: Int
    public var upstream: String
    public var tag: String
    public var build: Int
    public var commit: String
    public var architecture: CPUArchitecture
    public var assetName: String
    public var archiveSHA256: String
    public var binary: String
    public var files: [String]

    public init(
        schemaVersion: Int = LlamaRuntimeInfo.supportedSchemaVersion,
        upstream: String, tag: String, build: Int, commit: String,
        architecture: CPUArchitecture, assetName: String, archiveSHA256: String,
        binary: String = "llama-server", files: [String]
    ) {
        self.schemaVersion = schemaVersion
        self.upstream = upstream
        self.tag = tag
        self.build = build
        self.commit = commit
        self.architecture = architecture
        self.assetName = assetName
        self.archiveSHA256 = archiveSHA256
        self.binary = binary
        self.files = files
    }

    /// For the settings page, e.g. "llama.cpp b11046".
    public var displayVersion: String { "llama.cpp \(tag)" }
}
