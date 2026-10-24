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
///  1. **Lint's own** — the model, `--host`, `--port`, the key and the CORS lockdown. The settings
///     cannot change these; the server only ever listens on loopback and only answers Lint.
///  2. **Tuning** — `ModelRuntimeProfile` plus the sizes every model shares, and the idle-sleep
///     setting. Lint picks these for its workload.
///  3. **The advanced "extra arguments" setting** — appended last. Anything it sets also *removes*
///     Lint's own copy of that option from layer 2, so a flag never appears twice with two values.
public struct LlamaServerLaunchPlan: Equatable, Sendable {
    /// llama-server only ever listens on loopback; the settings cannot change that.
    public static let host = "127.0.0.1"

    /// llama-server reads its key from standard input, where `LocalLlamaServerManager` writes it:
    /// on the command line every user could read it and the diagnostic log would record it.
    static let keyArguments = ["--api-key-file", "/dev/stdin"]
    /// No browser may talk to llama-server: Lint uses URLSession, and other apps go through Lint's
    /// own API port. Without these b11046 sends back any Origin it is given (measured 2026-10-24).
    /// `lint.invalid` can never be a page's origin.
    static let corsLockdownArguments = ["--no-cors-credentials", "--cors-origins", "http://lint.invalid"]

    public var executableURL: URL
    public var arguments: [String]

    public init(executableURL: URL, arguments: [String]) {
        self.executableURL = executableURL
        self.arguments = arguments
    }

    /// - Parameters:
    ///   - alias: the name `/v1/models` gives the model; without it a file's absolute path, which holds
    ///     the user's name, is shown to every client.
    ///   - lockDownCORS: only the bundled runtime is known to have the CORS flags. A custom
    ///     llama-server may predate them and would not start; the key is what keeps others out.
    public static func make(
        runtime: URL,
        model: LocalModelReference,
        port: Int,
        profile: ModelRuntimeProfile = .unknownModel,
        idleSleepSeconds: Int = 0,
        extraArguments: String,
        alias: String? = nil,
        lockDownCORS: Bool = true
    ) -> LlamaServerLaunchPlan {
        var arguments: [String]
        switch model {
        case .file(let url): arguments = ["-m", url.path]
        case .huggingFace(let spec): arguments = ["-hf", spec]
        }
        arguments += ["--host", host, "--port", "\(port)"]
        arguments += keyArguments
        if lockDownCORS { arguments += corsLockdownArguments }
        let extras = splitArguments(extraArguments)
        if let alias, !optionNames(in: extras).contains(.alias) {
            arguments += ["--alias", alias]
        }
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
        // Reads per-layer embeddings (2.15 GiB of Gemma 4 E4B's 4.8) a row per token instead of
        // loading them: `auto` only does that above 4 GiB. About 2 GB less stays resident, and on a
        // Mac short of memory a load from disk went from 12-20 s to 6-8 s (with memory to spare it
        // made no difference). Models without such tensors are unaffected.
        add(["--lazy-mode", "on"])
        // Caps the prompt cache in RAM. b11046 lets it grow to 8 GiB and keeps it while the model
        // sleeps, and each proofread of a longer text (from about 250 tokens) stored the previous one
        // there, about 83 MiB with Gemma 4 E4B, never read back: 30 such texts took the server from
        // 343 MB to 2 GB. 128 MiB still holds the prompts of the modes Lint switches between; with no
        // cache at all, switching back to a mode made the slowest replies about 18% slower.
        add(["--cache-ram", "128"])
        add(profile.reasoningArguments)
        if idleSleepSeconds > 0 {
            add(["--sleep-idle-seconds", "\(idleSleepSeconds)"])
        }
        return arguments
    }

    /// Options the "extra arguments" setting may not set, because the server must stay bound to
    /// loopback, ask for Lint's key and answer no browser. These take a value (`--x v` or `--x=v`).
    static let protectedOptions: Set<String> = [
        "--host", "--api-key", "--api-key-file", "--cors-origins", "--cors-headers", "--cors-methods",
    ]
    /// The same, for flags that take no value: they must not swallow the token after them.
    static let protectedFlags: Set<String> = ["--cors-credentials", "--no-cors-credentials"]

    /// Splits the "extra arguments" setting on whitespace and drops the protected options.
    static func splitArguments(_ line: String) -> [String] {
        let tokens = line.split(whereSeparator: \.isWhitespace).map(String.init)
        var result: [String] = []
        var skipNext = false
        for token in tokens {
            if skipNext { skipNext = false; continue }
            if protectedFlags.contains(token) { continue }
            if protectedOptions.contains(token) { skipNext = true; continue }
            if let name = token.split(separator: "=", maxSplits: 1).first, token.contains("="),
               protectedOptions.contains(String(name)) { continue }
            result.append(token)
        }
        return result
    }

    /// One llama-server option, under every spelling it accepts. Only the options Lint sets itself
    /// are listed: the point is to notice that the user set the same one.
    enum OptionFamily: Hashable {
        case context, cacheTypeK, cacheTypeV, batch, ubatch, gpuLayers, flashAttention
        case parallel, threads, jinja, chatParsing, reasoning, idleSleep, lazyMode, cacheRAM, alias

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
            case "-lzm", "--lazy-mode": return .lazyMode
            case "-cram", "--cache-ram": return .cacheRAM
            case "-a", "--alias": return .alias
            default: return nil
            }
        }
    }

    static func optionNames(in arguments: [String]) -> Set<OptionFamily> {
        Set(arguments.compactMap(OptionFamily.of))
    }
}
