import Foundation

/// Starts / watches a Homebrew `llama-server` so Lint can use a local GGUF model
/// without the user keeping a Terminal session open.
@MainActor
final class LocalLlamaServerManager {
    static let shared = LocalLlamaServerManager()

    enum Status: Equatable {
        case stopped
        case starting
        case running(pid: Int32?, managedByLint: Bool)
        case failed(String)
    }

    enum BinaryState: Equatable {
        case found(path: String)
        case missing
        case brewUnavailable
    }

    private(set) var status: Status = .stopped
    private var process: Process?
    private var startedByUs = false
    private var logPipe: Pipe?

    private init() {}

    /// True when the OpenAI-compatible `/v1/models` endpoint answers.
    func isHealthy(port: Int) async -> Bool {
        guard let url = URL(string: "http://127.0.0.1:\(port)/v1/models") else { return false }
        var request = URLRequest(url: url)
        request.timeoutInterval = 1.5
        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            return (response as? HTTPURLResponse)?.statusCode == 200
        } catch {
            return false
        }
    }

    /// If auto-start is on and nothing is listening, launch `llama-server` with the saved args.
    func ensureRunning(settings: SettingsStore) async throws {
        let port = settings.localServerPort
        if await isHealthy(port: port) {
            status = .running(pid: process?.processIdentifier, managedByLint: startedByUs)
            return
        }
        guard settings.localServerAutoStart else {
            throw LocalServerError.notRunning(
                String(localized: "本機 llama-server 未在埠 \(port) 運行。可在設定開啟「自動啟動」，或先在終端機手動啟動。")
            )
        }
        try await start(settings: settings)
    }

    /// - Returns: `true` if a new process was launched; `false` if something was already healthy on the port.
    @discardableResult
    func start(settings: SettingsStore) async throws -> Bool {
        if await isHealthy(port: settings.localServerPort) {
            status = .running(pid: nil, managedByLint: false)
            return false
        }
        if let process, process.isRunning {
            status = .starting
            try await waitUntilHealthy(port: settings.localServerPort, timeoutSeconds: 180)
            status = .running(pid: process.processIdentifier, managedByLint: true)
            return false
        }

        let preferred = settings.localServerBinaryPath.trimmingCharacters(in: .whitespacesAndNewlines)
        let binary: String
        switch Self.detectBinary(preferred: preferred) {
        case .found(let path):
            binary = path
            if settings.localServerBinaryPath != path {
                settings.localServerBinaryPath = path
            }
        case .missing:
            let message = String(localized: "本機尚未安裝 llama-server。請在設定按「安裝 llama-server」，或終端機執行：brew install llama.cpp")
            status = .failed(message)
            throw LocalServerError.binaryMissing(message)
        case .brewUnavailable:
            let message = String(localized: "找不到 llama-server，且本機沒有 Homebrew。請先安裝 https://brew.sh 後再試。")
            status = .failed(message)
            throw LocalServerError.binaryMissing(message)
        }

        let port = settings.localServerPort
        let hf = settings.model.trimmingCharacters(in: .whitespacesAndNewlines)
        var args = [
            "-hf", hf.isEmpty ? SettingsStore.defaultLocalHFModel : hf,
            "--host", "127.0.0.1",
            "--port", "\(port)",
        ]
        args.append(contentsOf: Self.splitArgs(settings.localServerExtraArgs))

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: binary)
        proc.arguments = args
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = pipe
        logPipe = pipe

        status = .starting
        do {
            try proc.run()
        } catch {
            let message = String(localized: "無法啟動 llama-server：\(error.localizedDescription)")
            status = .failed(message)
            throw LocalServerError.launchFailed(message)
        }
        process = proc
        startedByUs = true

        // Drain logs so the pipe does not fill up.
        pipe.fileHandleForReading.readabilityHandler = { handle in
            _ = handle.availableData
        }

        do {
            try await waitUntilHealthy(port: port, timeoutSeconds: 180)
            status = .running(pid: proc.processIdentifier, managedByLint: true)
            return true
        } catch {
            stopIfStartedByUs()
            status = .failed(error.localizedDescription)
            throw error
        }
    }

    func stopIfStartedByUs() {
        guard startedByUs, let process else {
            return
        }
        process.terminate()
        self.process = nil
        startedByUs = false
        logPipe?.fileHandleForReading.readabilityHandler = nil
        logPipe = nil
        status = .stopped
    }

    /// Stop Lint-managed process, and optionally any listener on `port` (e.g. Terminal).
    @discardableResult
    func stop(port: Int, includingExternal: Bool = true) -> String {
        var stoppedManaged = false
        if startedByUs, let process {
            process.terminate()
            self.process = nil
            startedByUs = false
            logPipe?.fileHandleForReading.readabilityHandler = nil
            logPipe = nil
            stoppedManaged = true
        }

        var killedExternal: [Int32] = []
        if includingExternal {
            for pid in Self.listeningPIDs(on: port) {
                // Skip if we just terminated our own Process (same pid).
                kill(pid, SIGTERM)
                killedExternal.append(pid)
            }
        }

        process = nil
        startedByUs = false
        status = .stopped

        if stoppedManaged && killedExternal.isEmpty {
            return String(localized: "已停止 Lint 管理的 llama-server")
        }
        if !killedExternal.isEmpty {
            let pids = killedExternal.map(String.init).joined(separator: ", ")
            return String(localized: "已停止埠 \(port) 上的服務（PID \(pids)）")
        }
        if stoppedManaged {
            return String(localized: "已停止服務")
        }
        return String(localized: "埠 \(port) 上沒有偵測到監聽中的服務")
    }

    /// Stop whatever is on the port, then start with current settings (applies new args).
    func restart(settings: SettingsStore) async throws {
        let port = settings.localServerPort
        _ = stop(port: port, includingExternal: true)
        // Wait for the port to free / health to drop.
        for _ in 0..<30 {
            if !(await isHealthy(port: port)) { break }
            try? await Task.sleep(for: .milliseconds(200))
        }
        try await start(settings: settings)
    }

    static func listeningPIDs(on port: Int) -> [Int32] {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/sbin/lsof")
        proc.arguments = ["-nP", "-iTCP:\(port)", "-sTCP:LISTEN", "-t"]
        let out = Pipe()
        proc.standardOutput = out
        proc.standardError = Pipe()
        do {
            try proc.run()
        } catch {
            return []
        }
        proc.waitUntilExit()
        let text = String(data: out.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        return text
            .split(whereSeparator: \.isNewline)
            .compactMap { Int32($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
    }

    func refreshStatus(port: Int) async {
        if await isHealthy(port: port) {
            status = .running(pid: process?.processIdentifier, managedByLint: startedByUs)
        } else if case .starting = status {
            // keep
        } else if process?.isRunning == true {
            status = .starting
        } else {
            process = nil
            startedByUs = false
            status = .stopped
        }
    }

    // MARK: - Model files

    /// Where llama-server keeps the `-hf` model: the model's own folder in the
    /// HuggingFace hub cache once downloaded, otherwise the cache root. Nil if neither exists yet.
    static func modelFolder(hfModel: String) -> URL? {
        let env = ProcessInfo.processInfo.environment
        let hub: URL
        if let path = env["HF_HUB_CACHE"], !path.isEmpty {
            hub = URL(fileURLWithPath: path)
        } else if let home = env["HF_HOME"], !home.isEmpty {
            hub = URL(fileURLWithPath: home).appendingPathComponent("hub")
        } else {
            hub = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(".cache/huggingface/hub")
        }

        let repo = hfModel.split(separator: ":").first.map(String.init) ?? hfModel
        let model = hub.appendingPathComponent("models--" + repo.replacingOccurrences(of: "/", with: "--"))
        for url in [model, hub] where FileManager.default.fileExists(atPath: url.path) {
            return url
        }
        return nil
    }

    // MARK: - Binary detection / Homebrew install

    /// Common install locations + `PATH` lookup.
    static func detectBinary(preferred: String? = nil) -> BinaryState {
        var candidates: [String] = []
        if let preferred, !preferred.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            candidates.append(preferred.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        candidates.append(contentsOf: [
            SettingsStore.defaultLocalServerBinary,
            "/usr/local/bin/llama-server",
            "/opt/homebrew/bin/llama-server",
        ])
        if let pathEnv = ProcessInfo.processInfo.environment["PATH"] {
            for dir in pathEnv.split(separator: ":") {
                candidates.append("\(dir)/llama-server")
            }
        }
        var seen = Set<String>()
        for path in candidates where seen.insert(path).inserted {
            if FileManager.default.isExecutableFile(atPath: path) {
                return .found(path: path)
            }
        }
        return brewExecutable() == nil ? .brewUnavailable : .missing
    }

    static func brewExecutable() -> String? {
        for path in ["/opt/homebrew/bin/brew", "/usr/local/bin/brew"] {
            if FileManager.default.isExecutableFile(atPath: path) { return path }
        }
        return nil
    }

    /// Runs `brew install llama.cpp`. Caller must have confirmed with the user.
    func installViaHomebrew() async throws -> String {
        guard let brew = Self.brewExecutable() else {
            throw LocalServerError.binaryMissing(
                String(localized: "本機沒有 Homebrew。請先安裝：https://brew.sh  之後再回來按「安裝 llama-server」。")
            )
        }
        status = .starting
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: brew)
        proc.arguments = ["install", "llama.cpp"]
        let out = Pipe()
        let err = Pipe()
        proc.standardOutput = out
        proc.standardError = err
        do {
            try proc.run()
        } catch {
            let message = String(localized: "無法執行 brew：\(error.localizedDescription)")
            status = .failed(message)
            throw LocalServerError.launchFailed(message)
        }
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            DispatchQueue.global(qos: .userInitiated).async {
                proc.waitUntilExit()
                cont.resume()
            }
        }
        let stderr = String(data: err.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        let stdout = String(data: out.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        guard proc.terminationStatus == 0 else {
            let message = String(localized: "brew install llama.cpp 失敗（code \(proc.terminationStatus)）。\n\(stderr.isEmpty ? stdout : stderr)")
            status = .failed(message)
            throw LocalServerError.launchFailed(message)
        }
        switch Self.detectBinary() {
        case .found(let path):
            status = .stopped
            return path
        default:
            let message = String(localized: "brew 回報成功，但仍找不到 llama-server。請確認 `brew --prefix llama.cpp`。")
            status = .failed(message)
            throw LocalServerError.binaryMissing(message)
        }
    }

    private func waitUntilHealthy(port: Int, timeoutSeconds: Int) async throws {
        let deadline = ContinuousClock.now + .seconds(timeoutSeconds)
        while ContinuousClock.now < deadline {
            if await isHealthy(port: port) { return }
            if let process, !process.isRunning {
                throw LocalServerError.launchFailed(String(localized: "llama-server 已結束（可能是參數錯誤或模型下載失敗）。請在終端機手動跑一次查看訊息。"))
            }
            try? await Task.sleep(for: .milliseconds(500))
        }
        throw LocalServerError.timeout(String(localized: "等待 llama-server 就緒逾時（\(timeoutSeconds)s）。首次下載 GGUF 會較久，可先在終端機啟動一次。"))
    }

    private static func splitArgs(_ line: String) -> [String] {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        return trimmed.split(whereSeparator: \.isWhitespace).map(String.init)
    }
}

enum LocalServerError: LocalizedError {
    case notRunning(String)
    case binaryMissing(String)
    case launchFailed(String)
    case timeout(String)

    var errorDescription: String? {
        switch self {
        case .notRunning(let s), .binaryMissing(let s), .launchFailed(let s), .timeout(let s):
            return s
        }
    }
}
