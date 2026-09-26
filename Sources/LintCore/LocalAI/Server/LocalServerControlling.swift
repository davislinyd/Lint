import Foundation

public enum LocalServerStatus: Equatable, Sendable {
    case stopped
    case starting
    case running(pid: Int32?, managedByLint: Bool)
    case failed(String)
}

extension LocalServerStatus {
    /// The status after looking at the port and at Lint's own process again. A failure keeps its reason
    /// until the next start (looking again must not wipe it, or the setup screen would say "not running"
    /// with no explanation), unless the process turns out to be alive, which means it is still loading.
    public func refreshed(healthy: Bool, managedProcessRunning: Bool, pid: Int32?, managedByLint: Bool) -> LocalServerStatus {
        if healthy { return .running(pid: pid, managedByLint: managedByLint) }
        if managedProcessRunning { return .starting }
        switch self {
        case .starting, .failed: return self
        case .stopped, .running: return .stopped
        }
    }
}

/// Whether a running server holds its model, from `is_sleeping` in `/props` (`--sleep-idle-seconds`).
public enum LocalModelSleepState: Equatable, Sendable {
    case awake
    case asleep
    /// Was asleep and `/props` stopped answering: measured against b11046, it answers within a few
    /// milliseconds while generating but not at all while a request loads the model back (29 s once).
    case waking
    /// Not asked yet, or a server that does not say (no `/props`, or no `is_sleeping` in it).
    case unknown

    /// The state after asking `/props` again; `isSleeping` is nil when it did not answer.
    public func updated(isSleeping: Bool?) -> LocalModelSleepState {
        switch isSleeping {
        case true?: return .asleep
        case false?: return .awake
        case nil: return self == .asleep || self == .waking ? .waking : .unknown
        }
    }
}

/// What the menu bar says about Lint's local model.
public enum LocalModelActivity: Equatable, Sendable {
    case notLoaded
    case loading
    case running
    /// The server is up but released the model's memory; the next request loads it again.
    case idle
    case restarting
    case failed(String)

    public static func resolve(
        serverStatus: LocalServerStatus, sleep: LocalModelSleepState, isRestarting: Bool
    ) -> LocalModelActivity {
        if isRestarting { return .restarting }
        switch serverStatus {
        case .stopped: return .notLoaded
        case .starting: return .loading
        case .failed(let reason): return .failed(reason)
        case .running:
            switch sleep {
            case .asleep: return .idle
            case .waking: return .loading
            case .awake, .unknown: return .running
            }
        }
    }
}

/// The process side of the local server, behind a protocol so the setup logic is tested without
/// starting a real llama-server.
@MainActor
public protocol LocalServerControlling: AnyObject {
    var status: LocalServerStatus { get }
    /// The last lines llama-server printed when it failed (bounded), for diagnostics only.
    var logTail: String { get }

    /// True when the OpenAI-compatible `/v1/models` endpoint answers on loopback. A server that
    /// released its model while idle still answers, and is still healthy: sleeping is not a
    /// failure, and the next suggestion loads the model again by itself.
    func isHealthy(port: Int) async -> Bool
    /// `is_sleeping` from `/props`, or nil when it did not answer or does not say. Like `isHealthy`,
    /// asking must not wake the model or reset its idle timer.
    func isSleeping(port: Int) async -> Bool?
    /// Launches `plan` and waits until it is healthy, unless something already is on `port`.
    /// - Returns: `true` if a new process was launched.
    @discardableResult
    func start(plan: LlamaServerLaunchPlan, port: Int) async throws -> Bool
    /// Stops Lint's own process and anything else listening on `port`; returns a message for the UI.
    @discardableResult
    func stop(port: Int) -> String
    func stopIfStartedByUs()
    func refreshStatus(port: Int) async
}
