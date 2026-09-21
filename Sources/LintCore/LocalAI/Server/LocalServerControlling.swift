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

/// The process side of the local server, behind a protocol so the setup logic is tested without
/// starting a real llama-server.
@MainActor
public protocol LocalServerControlling: AnyObject {
    var status: LocalServerStatus { get }
    /// The last lines llama-server printed when it failed (bounded), for diagnostics only.
    var logTail: String { get }

    /// True when the OpenAI-compatible `/v1/models` endpoint answers on loopback.
    func isHealthy(port: Int) async -> Bool
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
