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
    /// The key this Lint gives llama-server, made once per process and kept only in memory: a server
    /// left behind by an earlier Lint, or started by anyone else, does not have it.
    let serverKey = LocalAPIKey.generate()
    private(set) var isUnprotected = false
    private var process: Process?
    private var startedByUs = false
    private var logBuffer: BoundedLogBuffer?
    private var logPipe: Pipe?
    /// The process whose start was already logged: several requests can wait for the same launch.
    private var loggedStartOf: Int32?

    private init() {}

    /// Lint's own llama-server while it runs, loading included; nil for a server Lint attached to.
    var runningPID: Int32? {
        guard let process, process.isRunning else { return nil }
        return process.processIdentifier
    }

    /// What the OpenAI-compatible `/v1/models` endpoint answers to Lint's key.
    ///
    /// This is also the check that runs while nothing is happening, so it must not undo
    /// `--sleep-idle-seconds`. Measured against the bundled build (b11046): a server whose model is
    /// asleep still answers `/v1/models` with 200 straight away, polling it does not reload the
    /// model, and it does not reset the idle timer — a server polled every 15 s went to sleep on
    /// schedule and stayed there. Only a completion request wakes it.
    func probe(port: Int) async -> LocalServerProbe {
        await probe(port: port, key: serverKey)
    }

    private func probe(port: Int, key: LocalAPIKey?) async -> LocalServerProbe {
        guard let url = URL(string: "http://\(LlamaServerLaunchPlan.host):\(port)/v1/models") else { return .unreachable }
        var request = URLRequest(url: url)
        request.timeoutInterval = 1.5
        if let key { request.setValue("Bearer \(key.value)", forHTTPHeaderField: "Authorization") }
        guard let (_, response) = try? await URLSession.shared.data(for: request),
              let status = (response as? HTTPURLResponse)?.statusCode
        else { return .unreachable }
        switch status {
        case 200: return .ready
        case 401: return .rejectedKey
        default: return .unexpected(status)
        }
    }

    /// `is_sleeping` from `/props`. Measured against b11046: polling `/props` every 15 s neither
    /// reset the idle timer (the model went to sleep on schedule) nor woke a sleeping model. It answers
    /// within milliseconds while generating, and not at all while a request loads the model back.
    func isSleeping(port: Int) async -> Bool? {
        guard let url = URL(string: "http://\(LlamaServerLaunchPlan.host):\(port)/props") else { return nil }
        var request = URLRequest(url: url)
        request.timeoutInterval = 1.5
        request.setValue("Bearer \(serverKey.value)", forHTTPHeaderField: "Authorization")
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let props = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        return props["is_sleeping"] as? Bool
    }

    /// Launches `plan` and waits until it answers, unless something already does on `port`.
    /// - Returns: `true` if a new process was launched; `false` if something was already healthy on the port.
    @discardableResult
    func start(plan: LlamaServerLaunchPlan, port: Int) async throws -> Bool {
        let answer = await probe(port: port)
        let ownProcessRunning = process?.isRunning == true
        if answer == .ready, ownProcessRunning, let process {
            status = .running(pid: process.processIdentifier, managedByLint: true)
            return false
        }
        if !ownProcessRunning {
            let orphan = Self.isLintsOrphan(port: port, executable: plan.executableURL)
            let withoutKey = answer == .ready ? await probe(port: port, key: nil) : nil
            switch ForeignServerPolicy.decide(withLintsKey: answer, withoutKey: withoutKey, isLintsOrphan: orphan) {
            case .attach(let unprotected)?:
                isUnprotected = unprotected
                status = .running(pid: nil, managedByLint: false)
                DiagnosticLog.shared.log("server", "attached to a running server port=\(port) unprotected=\(unprotected)")
                return false
            case .replace?:
                DiagnosticLog.shared.log("server", "replacing a server an earlier Lint left on port=\(port)")
                for pid in Self.listeningPIDs(on: port) { kill(pid, SIGTERM) }
                for _ in 0..<30 {
                    if await probe(port: port) == .unreachable { break }
                    try await Task.sleep(for: .milliseconds(200))
                }
            case .refuse?:
                let failure = LocalAIError.portInUse(port: port)
                status = .failed(failure.localizedDescription)
                DiagnosticLog.shared.log("server", "port=\(port) is held by a server that wants another key")
                throw failure
            case nil:
                break
            }
        }
        // A cancelled task's health check fails without asking the server: never launch because of it.
        try Task.checkCancellation()
        if let process, process.isRunning {
            // Still loading from an earlier attempt: wait for that process instead of starting another.
            status = .starting
            try await awaitHealthy(port: port, process: process)
            return false
        }

        let proc = Process()
        proc.executableURL = plan.executableURL
        proc.arguments = plan.arguments
        proc.environment = LlamaServerEnvironment.make(inherited: ProcessInfo.processInfo.environment)
        // The key goes in through standard input (`--api-key-file /dev/stdin`), never the arguments.
        let input = Pipe()
        proc.standardInput = input
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
            DiagnosticLog.shared.log("server", "launch failed \(DiagnosticLog.describe(error))")
            throw failure
        }
        try? input.fileHandleForWriting.write(contentsOf: Data((serverKey.value + "\n").utf8))
        try? input.fileHandleForWriting.close()
        try? input.fileHandleForReading.close()
        isUnprotected = false
        process = proc
        startedByUs = true
        DiagnosticLog.shared.log(
            "server",
            "launch \(plan.executableURL.path) pid=\(proc.processIdentifier) port=\(port) args=\(plan.arguments.joined(separator: " "))"
        )

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
        let started = ContinuousClock.now
        do {
            try await waitUntilHealthy(port: port, timeoutSeconds: Self.startupTimeoutSeconds)
            status = .running(pid: proc.processIdentifier, managedByLint: true)
            logStartOnce(proc, "ready pid=\(proc.processIdentifier) after \((ContinuousClock.now - started).components.seconds) s")
            // A custom llama-server that ignores `--api-key-file` would answer anyone.
            if await probe(port: port, key: nil) == .ready {
                isUnprotected = true
                DiagnosticLog.shared.log("server", "server not protected: it answers without a key")
            }
        } catch LocalAIError.startTimeout(let seconds) {
            logTail = logBuffer?.tail() ?? ""
            let failure = LocalAIError.startTimeout(seconds: seconds)
            status = .failed(failure.localizedDescription)
            logStartOnce(proc, "not ready after \(seconds) s, left running", tail: logTail)
            throw failure
        } catch is CancellationError {
            // The caller gave up (e.g. a newer selection replaced its suggestion), not the server: it keeps
            // loading, stays `.starting`, and the next start attaches to it.
            throw CancellationError()
        } catch {
            logTail = logBuffer?.tail() ?? ""
            logStartOnce(proc, "start failed \(DiagnosticLog.describe(error))", tail: logTail)
            stopIfStartedByUs()
            status = .failed(error.localizedDescription)
            throw error
        }
    }

    /// How a launch ended, then the server's last lines: what it printed while starting (paths, flags,
    /// the model's load), not anyone's text.
    private func logStartOnce(_ proc: Process, _ message: String, tail: String = "") {
        guard loggedStartOf != proc.processIdentifier else { return }
        loggedStartOf = proc.processIdentifier
        DiagnosticLog.shared.log("server", message)
        for line in tail.split(whereSeparator: \.isNewline) {
            DiagnosticLog.shared.log("server", "| \(line)")
        }
    }

    func stopIfStartedByUs() {
        guard startedByUs, let process else {
            return
        }
        DiagnosticLog.shared.log("server", "stop pid=\(process.processIdentifier)")
        process.terminate()
        self.process = nil
        startedByUs = false
        logPipe?.fileHandleForReading.readabilityHandler = nil
        logPipe = nil
        status = .stopped
        isUnprotected = false
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
        isUnprotected = false
        DiagnosticLog.shared.log("server", "stop port=\(port) managed=\(stoppedManaged) other pids=\(killedExternal)")

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

    nonisolated static func listeningPIDs(on port: Int) -> [Int32] {
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

    /// A listener on `port` runs Lint's runtime binary and its parent is gone (pid 1): the
    /// llama-server of a Lint that crashed or was killed, still holding that Lint's key.
    nonisolated static func isLintsOrphan(port: Int, executable: URL) -> Bool {
        let expected = executable.resolvingSymlinksInPath().standardizedFileURL.path
        return listeningPIDs(on: port).contains { pid in
            var info = proc_bsdinfo()
            let size = Int32(MemoryLayout<proc_bsdinfo>.size)
            guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size, info.pbi_ppid == 1 else { return false }
            var path = [CChar](repeating: 0, count: Int(MAXPATHLEN) * 4)
            guard proc_pidpath(pid, &path, UInt32(path.count)) > 0 else { return false }
            let running = URL(fileURLWithPath: String(cString: path)).resolvingSymlinksInPath().standardizedFileURL.path
            return running == expected
        }
    }

    func refreshStatus(port: Int) async {
        let answer = await probe(port: port)
        let healthy = answer == .ready
        let running = process?.isRunning == true
        if answer == .rejectedKey, !running {
            status = .failed(LocalAIError.portInUse(port: port).localizedDescription)
            return
        }
        let wasAttached: Bool
        if case .running(_, managedByLint: false) = status { wasAttached = true } else { wasAttached = false }
        status = status.refreshed(
            healthy: healthy, managedProcessRunning: running,
            pid: process?.processIdentifier, managedByLint: startedByUs
        )
        // Found already running, and it takes Lint's key: one started without a key answers anyone.
        // Asked once, when it is found, not on every refresh.
        if healthy, !running, !wasAttached {
            isUnprotected = await probe(port: port, key: nil) == .ready
            DiagnosticLog.shared.log("server", "attached to a running server port=\(port) unprotected=\(isUnprotected)")
        }
        if !running, !healthy, case .stopped = status {
            process = nil
            startedByUs = false
            isUnprotected = false
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
            // Not `try?`: in a cancelled task both the check and the sleep return at once, and the loop
            // spun for the whole timeout, starving URLSession so real checks timed out too, then called a
            // running server failed.
            try await Task.sleep(for: .milliseconds(500))
        }
        throw LocalAIError.startTimeout(seconds: timeoutSeconds)
    }
}
