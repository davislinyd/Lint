import Foundation
import Observation

/// What `LocalAPIService` needs from the proxy, so its start/stop logic is tested without sockets.
public protocol LocalAPIListening: AnyObject, Sendable {
    @discardableResult
    func start(port: Int, upstreamPort: Int, allowedOrigins: [String]) async throws -> Int
    func update(upstreamPort: Int, allowedOrigins: [String])
    func stop()
}

extension LocalAPIProxy: LocalAPIListening {}

/// Keeps Lint's API port as the settings say: listening only while it is switched on and Lint's
/// requests go to its local model. A new key or a new list of websites applies to the next request;
/// only a new port means listening again. llama-server is never restarted for any of this.
@MainActor
@Observable
public final class LocalAPIService {
    public enum State: Equatable, Sendable {
        case off
        case listening(port: Int)
        /// The message is for Settings.
        case failed(String)
    }

    public struct Configuration: Equatable, Sendable {
        public var enabled: Bool
        public var port: Int
        /// llama-server's port.
        public var upstreamPort: Int
        public var allowedOrigins: [String]

        public init(enabled: Bool, port: Int, upstreamPort: Int, allowedOrigins: [String]) {
            self.enabled = enabled
            self.port = port
            self.upstreamPort = upstreamPort
            self.allowedOrigins = allowedOrigins
        }
    }

    public private(set) var state: State = .off
    @ObservationIgnored private let proxy: any LocalAPIListening
    @ObservationIgnored private var applied: Configuration?
    @ObservationIgnored private var wanted: Configuration?
    @ObservationIgnored private var running: Task<Void, Never>?

    public init(proxy: any LocalAPIListening) {
        self.proxy = proxy
    }

    /// Brings the port in line with `configuration`. Cheap when nothing changed, so it can be called
    /// every second; a port that failed is only tried again once something changes.
    public func apply(_ configuration: Configuration) async {
        wanted = configuration
        if running == nil { running = Task { await self.reconcile() } }
        await running?.value
    }

    public func stop() {
        proxy.stop()
        state = .off
        applied = nil
        wanted = nil
    }

    /// Runs until what is wanted is what was applied; a change made meanwhile is picked up by the loop.
    private func reconcile() async {
        while let target = wanted, target != applied {
            await realize(target)
            applied = target
        }
        running = nil
    }

    private func realize(_ target: Configuration) async {
        guard target.enabled else {
            if state != .off { proxy.stop() }
            state = .off
            return
        }
        guard target.port != target.upstreamPort else {
            proxy.stop()
            state = .failed(String(localized: "API 埠不能和本機模型的埠（\(String(target.upstreamPort))）相同。"))
            return
        }
        if case .listening(let port) = state, port == target.port {
            proxy.update(upstreamPort: target.upstreamPort, allowedOrigins: target.allowedOrigins)
            return
        }
        do {
            let port = try await proxy.start(port: target.port, upstreamPort: target.upstreamPort, allowedOrigins: target.allowedOrigins)
            state = .listening(port: port)
        } catch {
            state = .failed(String(localized: "埠 \(String(target.port)) 已被其他程式使用，請改用別的埠。"))
        }
    }
}
