import Foundation
import LintCore

/// Runs the local `llama-server` process: launch, health check, stop, and a short tail of its
/// output for diagnostics. Which binary and which model to run come in as a `LlamaServerLaunchPlan`
/// (decided by `LocalAISetupCoordinator`); installing anything is not this class's job.
@MainActor
final class LocalLlamaServerManager: LocalServerControlling {
    static let shared = LocalLlamaServerManager()

    private(set) var status: LocalServerStatus = .stopped
    /// The last lines llama-server printed, kept for diagnostics only (bounded; never the whole log).
    private(set) var logTail = ""
    private var process: Process?
    private var startedByUs = false
    private var logBuffer: BoundedLogBuffer?
    private var logPipe: Pipe?

    private init() {}

    /// True when the OpenAI-compatible `/v1/models` endpoint answers.
    ///
    /// This is also the check that runs while nothing is happening, so it must not undo
    /// `--sleep-idle-seconds`. Measured against the bundled build (b11046): a server whose model is
    /// asleep still answers `/v1/models` with 200 straight away, polling it does not reload the
    /// model, and it does not reset the idle timer — a server polled every 15 s went to sleep on
    /// schedule and stayed there. Only a completion request wakes it.
    func isHealthy(port: Int) async -> Bool {
        guard let url = URL(string: "http://\(LlamaServerLaunchPlan.host):\(port)/v1/models") else { return false }
        var request = URLRequest(url: url)
        request.timeoutInterval = 1.5
        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            return (response as? HTTPURLResponse)?.statusCode == 200
        } catch {
            return false
        }
    }

    /// Launches `plan` and waits until it answers, unless something already does on `port`.
    /// - Returns: `true` if a new process was launched; `false` if something was already healthy on the port.
    @discardableResult
    func start(plan: LlamaServerLaunchPlan, port: Int) async throws -> Bool {
        if await isHealthy(port: port) {
            status = .running(pid: nil, managedByLint: false)
            return false
        }
        if let process, process.isRunning {
            // Still loading from an earlier attempt: wait for that process instead of starting another.
            status = .starting
            try await awaitHealthy(port: port, process: process)
            return false
        }

        let proc = Process()
        proc.executableURL = plan.executableURL
        proc.arguments = plan.arguments
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = pipe
        let buffer = BoundedLogBuffer()
        logBuffer = buffer
        logTail = ""
        logPipe = pipe

        status = .starting
        do {
            try proc.run()
        } catch {
            let failure = LocalAIError.launchFailed(String(localized: "無法啟動 llama-server：\(error.localizedDescription)"))
            status = .failed(failure.localizedDescription)
            throw failure
        }
        process = proc
        startedByUs = true

        // Drain the pipe so it never fills up, keeping only the last few KB for diagnostics.
        pipe.fileHandleForReading.readabilityHandler = { handle in
            buffer.append(handle.availableData)
        }

        try await awaitHealthy(port: port, process: proc)
        return true
    }

    /// Waits until the server answers. If it exits, that is a failure and the process is cleaned up. If it is
    /// merely slow (a 4-5 GB model being paged in on a busy Mac can take minutes), it is left running: the
    /// error says so, and the next start attaches to the same process instead of loading everything again.
    private func awaitHealthy(port: Int, process proc: Process) async throws {
        do {
            try await waitUntilHealthy(port: port, timeoutSeconds: Self.startupTimeoutSeconds)
            status = .running(pid: proc.processIdentifier, managedByLint: true)
        } catch LocalAIError.startTimeout(let seconds) {
            logTail = logBuffer?.tail() ?? ""
            let failure = LocalAIError.startTimeout(seconds: seconds)
            status = .failed(failure.localizedDescription)
            throw failure
        } catch {
            logTail = logBuffer?.tail() ?? ""
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

    /// Stops Lint's own process and whatever else listens on `port` (e.g. one started in Terminal).
    @discardableResult
    func stop(port: Int) -> String {
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
        for pid in Self.listeningPIDs(on: port) {
            // Skip if we just terminated our own Process (same pid).
            kill(pid, SIGTERM)
            killedExternal.append(pid)
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
        let healthy = await isHealthy(port: port)
        let running = process?.isRunning == true
        status = status.refreshed(
            healthy: healthy, managedProcessRunning: running,
            pid: process?.processIdentifier, managedByLint: startedByUs
        )
        if !running, !healthy, case .stopped = status {
            process = nil
            startedByUs = false
        }
    }

    /// Loading a 4-5 GB model into memory takes a while, and minutes when the Mac is short of memory; a
    /// first `-hf` download takes longer still.
    private static let startupTimeoutSeconds = 600

    private func waitUntilHealthy(port: Int, timeoutSeconds: Int) async throws {
        let deadline = ContinuousClock.now + .seconds(timeoutSeconds)
        while ContinuousClock.now < deadline {
            if await isHealthy(port: port) { return }
            if let process, !process.isRunning {
                logTail = logBuffer?.tail() ?? ""
                throw LocalAIError.launchFailed(String(localized: "llama-server 已結束（可能是參數錯誤或模型下載失敗）。請在設定的「詳細資訊」查看最後的輸出。"))
            }
            try? await Task.sleep(for: .milliseconds(500))
        }
        throw LocalAIError.startTimeout(seconds: timeoutSeconds)
    }
}
