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
///
/// Arguments are composed in three layers, and that order is the precedence:
///
///  1. **Lint's own** — the model, `--host`, `--port`. The settings cannot change these; the server
///     only ever listens on loopback.
///  2. **Tuning** — `ModelRuntimeProfile` plus the sizes every model shares, and the idle-sleep
///     setting. Lint picks these for its workload.
///  3. **The advanced "extra arguments" setting** — appended last. Anything it sets also *removes*
///     Lint's own copy of that option from layer 2, so a flag never appears twice with two values.
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
        profile: ModelRuntimeProfile = .unknownModel,
        idleSleepSeconds: Int = 0,
        extraArguments: String
    ) -> LlamaServerLaunchPlan {
        var arguments: [String]
        switch model {
        case .file(let url): arguments = ["-m", url.path]
        case .huggingFace(let spec): arguments = ["-hf", spec]
        }
        arguments += ["--host", host, "--port", "\(port)"]
        let extras = splitArguments(extraArguments)
        arguments += tuningArguments(profile: profile, idleSleepSeconds: idleSleepSeconds, overriddenBy: extras)
        arguments += extras
        return LlamaServerLaunchPlan(executableURL: runtime, arguments: arguments)
    }

    /// Lint's tuning defaults, minus every option the user's own arguments already set. Public so
    /// the settings page can show exactly what an override would be overriding.
    public static func tuningArguments(
        profile: ModelRuntimeProfile,
        idleSleepSeconds: Int,
        overriddenBy extras: [String]
    ) -> [String] {
        let overridden = optionNames(in: extras)
        var arguments: [String] = []
        func add(_ tokens: [String]) {
            guard let flag = tokens.first, let family = OptionFamily.of(flag) else { return }
            guard !overridden.contains(family) else { return }
            arguments += tokens
        }
        // The chat template is applied by llama.cpp, and its output is parsed, so reasoning and
        // tool calls never reach `content`. Both are the build's defaults; they are spelled out
        // because Lint depends on them.
        add(["--jinja"])
        add(["--no-skip-chat-parsing"])
        add(["-ngl", "99"]) // unified memory: splitting layers off the GPU frees nothing
        add(["-fa", "on"])  // also what a quantized KV cache needs
        add(["-c", "\(profile.contextTokens)"])
        add(["-np", "1"])
        add(["-t", "6"])
        add(["-ctk", profile.kvCacheType])
        add(["-ctv", profile.kvCacheType])
        add(["-b", "\(profile.batchTokens)"])
        add(["-ub", "\(profile.ubatchTokens)"])
        add(profile.reasoningArguments)
        if idleSleepSeconds > 0 {
            add(["--sleep-idle-seconds", "\(idleSleepSeconds)"])
        }
        return arguments
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

    /// One llama-server option, under every spelling it accepts. Only the options Lint sets itself
    /// are listed: the point is to notice that the user set the same one.
    enum OptionFamily: Hashable {
        case context, cacheTypeK, cacheTypeV, batch, ubatch, gpuLayers, flashAttention
        case parallel, threads, jinja, chatParsing, reasoning, idleSleep

        static func of(_ token: String) -> OptionFamily? {
            let flag = token.split(separator: "=", maxSplits: 1).first.map(String.init) ?? token
            switch flag {
            case "-c", "--ctx-size": return .context
            case "-ctk", "--cache-type-k": return .cacheTypeK
            case "-ctv", "--cache-type-v": return .cacheTypeV
            case "-b", "--batch-size": return .batch
            case "-ub", "--ubatch-size": return .ubatch
            case "-ngl", "--gpu-layers", "--n-gpu-layers": return .gpuLayers
            case "-fa", "--flash-attn": return .flashAttention
            case "-np", "--parallel": return .parallel
            case "-t", "--threads": return .threads
            case "--jinja", "--no-jinja": return .jinja
            case "--skip-chat-parsing", "--no-skip-chat-parsing": return .chatParsing
            case "-rea", "--reasoning": return .reasoning
            case "--sleep-idle-seconds": return .idleSleep
            default: return nil
            }
        }
    }

    static func optionNames(in arguments: [String]) -> Set<OptionFamily> {
        Set(arguments.compactMap(OptionFamily.of))
    }
}
