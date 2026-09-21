import Foundation

/// Which model `llama-server` loads.
public enum LocalModelReference: Equatable, Sendable {
    /// A GGUF file on disk (`-m`). For a split model this is the first shard; llama.cpp finds the
    /// others next to it. The managed model always uses this, so starting the server never downloads.
    case file(URL)
    /// A Hugging Face spec (`-hf user/model:quant`) that llama-server resolves and downloads itself.
    /// Only for the advanced custom-model setting.
    case huggingFace(String)
}

/// The exact process to launch: the binary and its arguments. Pure data, so what Lint runs can be
/// tested without starting anything.
public struct LlamaServerLaunchPlan: Equatable, Sendable {
    /// llama-server only ever listens on loopback; the settings cannot change that.
    public static let host = "127.0.0.1"

    public var executableURL: URL
    public var arguments: [String]

    public init(executableURL: URL, arguments: [String]) {
        self.executableURL = executableURL
        self.arguments = arguments
    }

    public static func make(
        runtime: URL,
        model: LocalModelReference,
        port: Int,
        extraArguments: String
    ) -> LlamaServerLaunchPlan {
        var arguments: [String]
        switch model {
        case .file(let url): arguments = ["-m", url.path]
        case .huggingFace(let spec): arguments = ["-hf", spec]
        }
        arguments += ["--host", host, "--port", "\(port)"]
        arguments += splitArguments(extraArguments)
        return LlamaServerLaunchPlan(executableURL: runtime, arguments: arguments)
    }

    /// Splits the "extra arguments" setting on whitespace and drops any `--host` the user typed
    /// (both `--host x` and `--host=x`), because the server must stay bound to loopback.
    static func splitArguments(_ line: String) -> [String] {
        let tokens = line.split(whereSeparator: \.isWhitespace).map(String.init)
        var result: [String] = []
        var skipNext = false
        for token in tokens {
            if skipNext { skipNext = false; continue }
            if token == "--host" { skipNext = true; continue }
            if token.hasPrefix("--host=") { continue }
            result.append(token)
        }
        return result
    }
}
