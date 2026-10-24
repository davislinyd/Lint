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

/// What `/v1/models` said when asked with Lint's key.
public enum LocalServerProbe: Equatable, Sendable {
    /// Nothing answered.
    case unreachable
    case ready
    /// A server answered but wants another key: not one Lint started in this process.
    case rejectedKey
    /// Anything else, such as 503 while a model loads (b11046 says so before it looks at the key).
    case unexpected(Int)
}

/// What to do about a llama-server on Lint's port that this Lint did not start.
public enum ForeignServerDecision: Equatable, Sendable {
    /// Use it. `unprotected`: it answers without a key, so anyone on this Mac can use it directly.
    case attach(unprotected: Bool)
    /// It is a Lint llama-server whose Lint is gone: stop it and start one with this process's key.
    case replace
    /// Someone else's server, protected by a key Lint does not have: leave it alone and say so.
    case refuse
}

public enum ForeignServerPolicy {
    /// - Parameters:
    ///   - withLintsKey: the answer to Lint's key.
    ///   - withoutKey: the answer to no key; only needed when Lint's key was accepted.
    ///   - isLintsOrphan: the listener runs Lint's runtime binary and its parent is gone (pid 1).
    /// - Returns: nil when there is nothing to decide yet (nothing listens, or it is still loading).
    public static func decide(
        withLintsKey: LocalServerProbe, withoutKey: LocalServerProbe?, isLintsOrphan: Bool
    ) -> ForeignServerDecision? {
        switch withLintsKey {
        case .unreachable, .unexpected: return nil
        case .rejectedKey: return isLintsOrphan ? .replace : .refuse
        case .ready:
            if isLintsOrphan { return .replace }
            return .attach(unprotected: withoutKey == .ready)
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
    /// A model download in progress, from looking at the disk to installing the verified files.
    case downloading(ModelDownloadState)

    public static func resolve(
        serverStatus: LocalServerStatus, sleep: LocalModelSleepState, isRestarting: Bool,
        download: ModelDownloadState = .idle
    ) -> LocalModelActivity {
        if isRestarting { return .restarting }
        if download.isActive { return .downloading(download) }
        switch serverStatus {
        case .stopped:
            // A failed download is why nothing runs: say so until the next attempt.
            if case .failed(let error) = download { return .failed(error.localizedDescription) }
            return .notLoaded
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

    /// What `/v1/models` answers on loopback to Lint's key. A server that released its model while
    /// idle still answers, and is still ready: sleeping is not a failure, and the next suggestion
    /// loads the model again by itself.
    func probe(port: Int) async -> LocalServerProbe
    /// `is_sleeping` from `/props`, or nil when it did not answer or does not say. Like `probe`,
    /// asking must not wake the model or reset its idle timer.
    func isSleeping(port: Int) async -> Bool?
    /// The server Lint uses answers without a key (one started by someone else, without `--api-key`).
    var isUnprotected: Bool { get }
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

extension LocalServerControlling {
    /// A server that takes Lint's key answers.
    public func isHealthy(port: Int) async -> Bool {
        await probe(port: port) == .ready
    }
}
