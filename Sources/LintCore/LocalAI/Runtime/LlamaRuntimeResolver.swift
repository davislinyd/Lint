import Foundation

/// A `llama-server` Lint may launch, and where it came from.
public struct LlamaRuntimeLocation: Equatable, Sendable {
    public enum Origin: Equatable, Sendable {
        /// Lint's own runtime inside the app bundle.
        case bundled
        /// The advanced "custom path" override.
        case custom
        /// A `llama-server` found in a standard location or on `PATH` (for example a Homebrew
        /// install) because this build has no bundled runtime. A compatibility fallback only.
        case externalFallback
    }

    public var binaryURL: URL
    public var origin: Origin
    /// Present for the bundled runtime.
    public var info: LlamaRuntimeInfo?

    public init(binaryURL: URL, origin: Origin, info: LlamaRuntimeInfo? = nil) {
        self.binaryURL = binaryURL
        self.origin = origin
        self.info = info
    }
}

public enum LlamaRuntimeStatus: Equatable, Sendable {
    case ready(LlamaRuntimeLocation)
    /// Nothing usable was found.
    case missing(source: LocalRuntimeSource)
    /// Something was found but cannot be trusted or used (wrong architecture, damaged, not executable).
    case invalid(source: LocalRuntimeSource, reason: String)

    public var location: LlamaRuntimeLocation? {
        if case .ready(let location) = self { return location }
        return nil
    }

    public var isReady: Bool { location != nil }

    /// The text for a normal user. It never suggests Homebrew as a repair.
    public var userMessage: String? {
        switch self {
        case .ready:
            return nil
        case .missing(let source), .invalid(let source, _):
            switch source {
            case .automatic:
                return String(localized: "Lint 的本機 AI 執行環境損毀或不完整。請重新安裝 Lint，或改用其他模型來源。")
            case .custom:
                return String(localized: "找不到可執行的自訂 llama-server。請在設定檢查路徑，或改回「自動（Lint 內建）」。")
            }
        }
    }
}

/// Decides which `llama-server` to run. Resolution is always computed from the running app's own
/// location and never stored, so moving Lint.app (say from /Applications to ~/Applications)
/// cannot leave a stale path behind.
///
/// Order for `.automatic`:
///  1. the bundled runtime for this process's architecture, verified;
///  2. if the bundle simply has no runtime (a development build): a `llama-server` in a standard
///     location or on `PATH`, as a compatibility fallback.
/// A bundled runtime that is present but damaged is reported as `.invalid`, never silently replaced.
/// For `.custom` only the given path is considered.
public struct LlamaRuntimeResolver: Sendable {
    public var resourcesDirectory: URL?
    public var architecture: CPUArchitecture
    public var fallbackCandidates: [String]
    public var verifier: LlamaRuntimeVerifier

    public init(
        resourcesDirectory: URL? = Bundle.main.resourceURL,
        architecture: CPUArchitecture = .current,
        fallbackCandidates: [String] = LlamaRuntimeResolver.defaultFallbackCandidates(),
        verifier: LlamaRuntimeVerifier = LlamaRuntimeVerifier()
    ) {
        self.resourcesDirectory = resourcesDirectory
        self.architecture = architecture
        self.fallbackCandidates = fallbackCandidates
        self.verifier = verifier
    }

    /// Well-known Homebrew locations, then `PATH`.
    public static func defaultFallbackCandidates(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> [String] {
        var candidates = ["/opt/homebrew/bin/llama-server", "/usr/local/bin/llama-server"]
        if let path = environment["PATH"] {
            for directory in path.split(separator: ":") where !directory.isEmpty {
                candidates.append("\(directory)/llama-server")
            }
        }
        return candidates
    }

    public var bundledRuntimeDirectory: URL? {
        resourcesDirectory?.appendingPathComponent("LlamaRuntime", isDirectory: true)
            .appendingPathComponent(architecture.rawValue, isDirectory: true)
    }

    public func resolve(source: LocalRuntimeSource, customPath: String) -> LlamaRuntimeStatus {
        switch source {
        case .automatic: resolveAutomatic()
        case .custom: resolveCustom(customPath)
        }
    }

    private func resolveAutomatic() -> LlamaRuntimeStatus {
        if let directory = bundledRuntimeDirectory {
            switch verifier.verify(directory: directory, expected: architecture) {
            case .success(let info):
                let binary = directory.appendingPathComponent(info.binary)
                return .ready(LlamaRuntimeLocation(binaryURL: binary, origin: .bundled, info: info))
            case .failure(.directoryMissing):
                break // no bundled runtime at all: fall through to the compatibility fallback
            case .failure(let error):
                return .invalid(source: .automatic, reason: error.reason)
            }
        }
        var seen = Set<String>()
        for path in fallbackCandidates where seen.insert(path).inserted {
            if FileManager.default.isExecutableFile(atPath: path) {
                return .ready(LlamaRuntimeLocation(binaryURL: URL(fileURLWithPath: path), origin: .externalFallback))
            }
        }
        return .missing(source: .automatic)
    }

    private func resolveCustom(_ customPath: String) -> LlamaRuntimeStatus {
        let path = customPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !path.isEmpty else { return .missing(source: .custom) }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory), !isDirectory.boolValue else {
            return .missing(source: .custom)
        }
        guard FileManager.default.isExecutableFile(atPath: path) else {
            return .invalid(source: .custom, reason: "\(path) is not executable")
        }
        return .ready(LlamaRuntimeLocation(binaryURL: URL(fileURLWithPath: path), origin: .custom))
    }
}

/// One-time migration of the old "llama-server path" setting, which used to be filled in
/// automatically with whatever Homebrew path was found.
public enum LocalRuntimeMigration {
    /// The paths older versions offered as the default or wrote after detecting Homebrew.
    public static let historicalHomebrewPaths = [
        "/opt/homebrew/bin/llama-server",
        "/usr/local/bin/llama-server",
    ]

    public struct Result: Equatable, Sendable {
        public var source: LocalRuntimeSource
        public var customPath: String
    }

    /// A stored path that is one of those historical defaults (or empty) means "no opinion":
    /// use Lint's own runtime. Any other path was chosen by the user and stays a custom setting.
    public static func migrate(storedBinaryPath: String?) -> Result {
        let path = (storedBinaryPath ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if path.isEmpty || historicalHomebrewPaths.contains(path) {
            return Result(source: .automatic, customPath: "")
        }
        return Result(source: .custom, customPath: path)
    }
}
