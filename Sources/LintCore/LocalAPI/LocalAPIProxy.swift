import Foundation
import Network

/// Why an external request cannot reach the model now; `LocalAPIProxy` answers 503 with the reason.
public enum LocalAPIBackendUnavailable: Error, Sendable {
    /// Lint's requests do not go to its local model (Apple Intelligence, another provider).
    case notLocalEngine
    /// The server is not running and cannot be started (auto-start off, not set up, failed).
    case notRunning
    case restarting
}

/// Lint's API port: lets other apps on this Mac use the local model, behind a key, without ever
/// getting ahead of Lint.
///
/// It listens on 127.0.0.1 only, checks every request (Host, Origin, key) before anything reaches
/// llama-server, and forwards only the OpenAI routes it knows, with Lint's own key for llama-server.
/// Model requests take turns through `ModelPriorityGate`: one at a time, never while Lint uses the
/// model, and interrupted when Lint starts. An interrupted request that had not sent anything back
/// yet is sent again once Lint is done, so the client only sees a delay.
public final class LocalAPIProxy: @unchecked Sendable {
    public struct Limits: Sendable {
        /// How long one request may wait for the model in all, across interruptions.
        public var maxWait: Duration = .seconds(120)
        public var maxPreemptions = 5
        public var maxConnections = 32
        public var headTimeout: Duration = .seconds(10)
        public var bodyTimeout: Duration = .seconds(60)
        /// Silence from llama-server longer than this ends the request (a model load can take long).
        public var upstreamTimeout: TimeInterval = 300
        public var maxBufferedResponse = 8 * 1024 * 1024

        public init() {}
    }

    public enum StartError: Error, Equatable {
        case portUnavailable(port: Int)
    }

    private let gate: ModelPriorityGate
    private let serverKey: LocalAPIKey
    private let keys: @Sendable () -> LocalAPIKeyring.Lookup
    private let ensureBackend: @Sendable () async throws -> Void
    private let limits: Limits
    private let log: @Sendable (String) -> Void
    private let queue = DispatchQueue(label: "app.lint.local-api")
    private let lock = NSLock()
    private var listener: NWListener?
    private var port = 0
    private var upstreamPort = 8000
    private var allowedOrigins: [AllowedOrigin] = []
    private var allowAnyWebsite = false
    private var allowBrowserExtensions = false
    private var openConnections = 0
    private var rejections: [String: Int] = [:]
    private var lastSummary = ContinuousClock.now

    /// - Parameters:
    ///   - serverKey: the key Lint started llama-server with.
    ///   - keys: the keys a client may present, and whether one of them could not be read.
    ///   - ensureBackend: makes sure llama-server runs, as for Lint's own requests, or throws
    ///     `LocalAPIBackendUnavailable`.
    public init(
        gate: ModelPriorityGate,
        serverKey: LocalAPIKey,
        keys: @escaping @Sendable () -> LocalAPIKeyring.Lookup,
        ensureBackend: @escaping @Sendable () async throws -> Void,
        limits: Limits = Limits(),
        log: @escaping @Sendable (String) -> Void = { DiagnosticLog.shared.log("api", $0) }
    ) {
        self.gate = gate
        self.serverKey = serverKey
        self.keys = keys
        self.ensureBackend = ensureBackend
        self.limits = limits
        self.log = log
    }

    // MARK: - Listening

    /// Starts listening on 127.0.0.1:`port` (0 picks a free port) and returns the port.
    @discardableResult
    public func start(
        port: Int, upstreamPort: Int, allowedOrigins: [String], allowAnyWebsite: Bool = false, allowBrowserExtensions: Bool = false
    ) async throws -> Int {
        stop()
        update(
            upstreamPort: upstreamPort, allowedOrigins: allowedOrigins, allowAnyWebsite: allowAnyWebsite,
            allowBrowserExtensions: allowBrowserExtensions
        )
        let parameters = NWParameters.tcp
        parameters.requiredInterfaceType = .loopback
        guard let wanted = NWEndpoint.Port(rawValue: UInt16(clamping: port)) else { throw StartError.portUnavailable(port: port) }
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: wanted)
        let listener: NWListener
        do {
            listener = try NWListener(using: parameters)
        } catch {
            throw StartError.portUnavailable(port: port)
        }
        listener.newConnectionHandler = { [weak self] connection in self?.accept(connection) }
        let bound: Int = try await withCheckedThrowingContinuation { continuation in
            let once = Once()
            listener.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    once.run { continuation.resume(returning: Int(listener.port?.rawValue ?? 0)) }
                case .failed, .waiting:
                    once.run {
                        listener.cancel()
                        continuation.resume(throwing: StartError.portUnavailable(port: port))
                    }
                case .cancelled:
                    once.run { continuation.resume(throwing: StartError.portUnavailable(port: port)) }
                default:
                    break
                }
            }
            listener.start(queue: queue)
        }
        lock.withLock {
            self.listener = listener
            self.port = bound
        }
        log("listening port=\(bound)")
        return bound
    }

    /// New settings that apply to the next request; the port keeps listening.
    public func update(upstreamPort: Int, allowedOrigins: [String], allowAnyWebsite: Bool = false, allowBrowserExtensions: Bool = false) {
        let parsed = allowedOrigins.compactMap(AllowedOrigin.parse)
        lock.withLock {
            self.upstreamPort = upstreamPort
            self.allowedOrigins = parsed
            self.allowAnyWebsite = allowAnyWebsite
            self.allowBrowserExtensions = allowBrowserExtensions
        }
    }

    /// Stops listening; the request in progress is interrupted and the waiting ones are refused.
    public func stop() {
        let listener: NWListener? = lock.withLock {
            defer { self.listener = nil }
            return self.listener
        }
        guard let listener else { return }
        listener.cancel()
        gate.cancelAllExternal()
        flushSummary(force: true)
        log("stopped")
    }

    public var isListening: Bool { lock.withLock { listener != nil } }

    // MARK: - Connections

    private func accept(_ connection: NWConnection) {
        let client = APIConnection(connection, queue: queue)
        let admitted = lock.withLock {
            guard openConnections < limits.maxConnections else { return false }
            openConnections += 1
            return true
        }
        Task {
            if admitted {
                await handle(client)
                lock.withLock { openConnections -= 1 }
            } else {
                try? await client.send(Self.error(503, "Too many connections.", code: "too_many_connections", retryAfter: 5))
            }
            client.close()
        }
    }

    private struct Settings {
        var port: Int
        var upstreamPort: Int
        var allowedOrigins: [AllowedOrigin]
        var allowAnyWebsite: Bool
        var allowBrowserExtensions: Bool
    }

    private var settings: Settings {
        lock.withLock {
            Settings(
                port: port, upstreamPort: upstreamPort, allowedOrigins: allowedOrigins, allowAnyWebsite: allowAnyWebsite,
                allowBrowserExtensions: allowBrowserExtensions
            )
        }
    }

    private static let routes: [String: String] = [
        "/health": "GET", "/v1/models": "GET", "/v1/chat/completions": "POST", "/v1/completions": "POST",
    ]

    private func handle(_ client: APIConnection) async {
        // The head, within its time limit.
        let headTimer = Task { [limits] in
            try await Task.sleep(for: limits.headTimeout)
            client.close()
        }
        var buffer = Data()
        let head: LocalAPIHTTP.Head
        do {
            while true {
                if let parsed = try LocalAPIHTTP.parseHead(buffer) {
                    head = parsed.head
                    buffer = Data(buffer[(buffer.startIndex + parsed.length)...])
                    break
                }
                guard let data = try await client.receive() else { headTimer.cancel(); return }
                buffer.append(data)
            }
        } catch let refusal as LocalAPIHTTP.Refusal {
            headTimer.cancel()
            reject(refusal.code)
            try? await client.send(Self.error(refusal.status, "The request could not be read.", code: refusal.code))
            return
        } catch {
            headTimer.cancel()
            return
        }
        headTimer.cancel()

        let settings = self.settings
        guard LocalAPIPolicy.isAllowedHost(head.header("Host"), port: settings.port) else {
            reject("invalid_host")
            try? await client.send(Self.error(403, "Use 127.0.0.1 or localhost to reach Lint.", code: "invalid_host"))
            return
        }
        var cors: [(String, String)] = []
        if let origin = head.header("Origin") {
            guard LocalAPIPolicy.isAllowedOrigin(
                origin, allowed: settings.allowedOrigins, anyWebsite: settings.allowAnyWebsite,
                browserExtensions: settings.allowBrowserExtensions
            ) else {
                reject("origin_not_allowed")
                try? await client.send(Self.error(403, "This website is not allowed to use Lint's model. Add it in Lint's settings.", code: "origin_not_allowed"))
                return
            }
            cors = LocalAPIPolicy.corsHeaders(origin: origin)
        }
        guard let method = Self.routes[head.path] else {
            reject("unknown_endpoint")
            try? await client.send(Self.error(404, "Unknown endpoint.", code: "unknown_endpoint", extra: cors))
            return
        }
        if head.method == "OPTIONS" {
            var headers: [(String, String)] = [("Allow", "\(method), OPTIONS")]
            if let origin = head.header("Origin") {
                headers += LocalAPIPolicy.preflightHeaders(
                    origin: origin,
                    privateNetworkRequested: head.header("Access-Control-Request-Private-Network")?.lowercased() == "true"
                )
            }
            try? await client.send(LocalAPIHTTP.response(status: 204, headers: headers))
            return
        }
        guard head.method == method else {
            reject("method_not_allowed")
            try? await client.send(Self.error(405, "Use \(method).", code: "method_not_allowed", extra: cors + [("Allow", "\(method), OPTIONS")]))
            return
        }
        if head.path == "/health" {
            try? await client.send(LocalAPIHTTP.response(
                status: 200, headers: cors + [("Content-Type", "application/json")], body: Data(#"{"status":"ok"}"#.utf8)
            ))
            return
        }
        let presented = LocalAPIPolicy.presentedKey(authorization: head.header("Authorization"), apiKeyHeader: head.header("X-Api-Key"))
        let lookup = keys()
        // Every key is compared, in constant time each, so the time taken does not tell which one matched.
        let matching = presented.map { presented in lookup.keys.filter { $0.key.matches(presented) } } ?? []
        guard let match = matching.first else {
            if presented != nil, lookup.unreadable {
                try? await client.send(Self.error(503, "Lint's API key could not be read.", code: "key_unavailable", extra: cors, retryAfter: 30))
                return
            }
            reject("invalid_api_key")
            try? await client.send(Self.error(401, "A valid API key is required.", code: "invalid_api_key", extra: cors + [("WWW-Authenticate", "Bearer")]))
            return
        }

        // The body, within its time limit.
        let length: Int
        do {
            length = try LocalAPIHTTP.bodyLength(of: head)
        } catch {
            reject(error.code)
            try? await client.send(Self.error(error.status, "The request body could not be read.", code: error.code, extra: cors))
            return
        }
        if head.header("Expect")?.lowercased() == "100-continue" {
            try? await client.send(LocalAPIHTTP.responseHead(status: 100, headers: []))
        }
        let bodyTimer = Task { [limits] in
            try await Task.sleep(for: limits.bodyTimeout)
            client.close()
        }
        while buffer.count < length {
            guard let data = try? await client.receive() else { bodyTimer.cancel(); return }
            buffer.append(data)
        }
        bodyTimer.cancel()
        let body = buffer.prefix(length)

        let forward = Forward(
            method: head.method, path: head.path, body: Data(body),
            contentType: head.header("Content-Type") ?? "application/json",
            upstreamPort: settings.upstreamPort, cors: cors, keyID: match.shortID
        )
        // A client that hangs up stops whatever its request is doing: waiting, or generating.
        let work = Task { await self.serve(forward, to: client) }
        let watcher = Task {
            while true {
                guard let data = try? await client.receive(), !data.isEmpty else {
                    work.cancel()
                    return
                }
            }
        }
        await work.value
        watcher.cancel()
    }

    // MARK: - Forwarding

    private struct Forward: Sendable {
        var method: String
        var path: String
        var body: Data
        var contentType: String
        var upstreamPort: Int
        var cors: [(String, String)]
        /// Which key let the request in, for the log (`LocalAPIKeyRecord.shortID`).
        var keyID: String

        var isModelRequest: Bool { method == "POST" }
    }

    private func serve(_ forward: Forward, to client: APIConnection) async {
        let started = ContinuousClock.now
        guard forward.isModelRequest else {
            // `/v1/models` only reads; it never waits for the model.
            let outcome = await attempt(forward, client: client, interruption: Interruption())
            if case .failed(let status, let code, let message, let retryAfter) = outcome {
                try? await client.send(Self.error(status, message, code: code, extra: forward.cors, retryAfter: retryAfter))
            }
            noteModels()
            return
        }
        let deadline = started + limits.maxWait
        var preemptions = 0
        var front = false
        var final: Outcome
        while true {
            let remaining = deadline - ContinuousClock.now
            guard remaining > .zero else {
                final = .failed(503, "lint_busy", "Lint is using the model. Try again shortly.", 30)
                break
            }
            let interruption = Interruption()
            let lease: ModelPriorityGate.ExternalLease
            do {
                lease = try await gate.acquireExternal(front: front, budget: remaining, onPreempt: { interruption.interrupt() })
            } catch ModelPriorityGate.GateError.queueFull {
                final = .failed(503, "queue_full", "Too many requests are waiting for the model.", 5)
                break
            } catch ModelPriorityGate.GateError.timedOut {
                final = .failed(503, "lint_busy", "Lint is using the model. Try again shortly.", 30)
                break
            } catch ModelPriorityGate.GateError.closed {
                final = .failed(503, "api_stopped", "Lint stopped its API.", 10)
                break
            } catch {
                final = .clientGone
                break
            }
            let outcome = await attempt(forward, client: client, interruption: interruption)
            lease.release()
            if case .interruptedBeforeReply = outcome {
                preemptions += 1
                if preemptions > limits.maxPreemptions {
                    final = .failed(503, "lint_busy", "Lint is using the model. Try again shortly.", 30)
                    break
                }
                front = true
                continue
            }
            final = outcome
            break
        }
        if case .failed(let status, let code, let message, let retryAfter) = final {
            try? await client.send(Self.error(status, message, code: code, extra: forward.cors, retryAfter: retryAfter))
        }
        let milliseconds = Int((ContinuousClock.now - started) / .milliseconds(1))
        let interruptions = preemptions + (final.status == "preempted" ? 1 : 0)
        log("\(forward.method) \(forward.path) status=\(final.status) ms=\(milliseconds) preempted=\(interruptions) retried=\(preemptions) key=\(forward.keyID)")
    }

    private enum Outcome {
        case completed(Int)
        case interruptedBeforeReply
        case interruptedMidReply
        case clientGone
        case brokenMidReply
        case failed(Int, String, String, Int?)

        var status: String {
            switch self {
            case .completed(let status): "\(status)"
            case .interruptedBeforeReply, .interruptedMidReply: "preempted"
            case .clientGone: "client-gone"
            case .brokenMidReply: "broken"
            case .failed(let status, let code, _, _): "\(status)-\(code)"
            }
        }
    }

    private struct ClientGone: Error {}

    /// One try at a request, with the model to itself until `interruption` fires.
    private func attempt(_ forward: Forward, client: APIConnection, interruption: Interruption) async -> Outcome {
        if forward.isModelRequest {
            do {
                try await ensureBackend()
            } catch LocalAPIBackendUnavailable.restarting {
                return interruption.isInterrupted ? .interruptedBeforeReply : .failed(503, "restarting", "Lint's model is restarting.", 10)
            } catch LocalAPIBackendUnavailable.notLocalEngine {
                return .failed(503, "model_not_running", "Lint is not using its local model now.", 60)
            } catch {
                if Task.isCancelled { return .clientGone }
                return interruption.isInterrupted ? .interruptedBeforeReply : .failed(503, "model_not_running", "Lint's local model is not running.", 10)
            }
        }
        guard let url = URL(string: "http://127.0.0.1:\(forward.upstreamPort)\(forward.path)") else {
            return .failed(500, "internal_error", "The request could not be forwarded.", nil)
        }
        var request = URLRequest(url: url)
        request.httpMethod = forward.method
        request.timeoutInterval = limits.upstreamTimeout
        request.setValue("Bearer \(serverKey.value)", forHTTPHeaderField: "Authorization")
        if forward.isModelRequest {
            request.setValue(forward.contentType, forHTTPHeaderField: "Content-Type")
            request.httpBody = forward.body
        }
        let upstream = LocalAPIUpstream(request: request)
        guard interruption.attach(upstream) else { return .interruptedBeforeReply }
        upstream.start()

        var response: HTTPURLResponse?
        var streaming = false
        var relayed = false
        var buffered = Data()
        do {
            try await withTaskCancellationHandler {
                for try await event in upstream.events {
                    switch event {
                    case .response(let http):
                        response = http
                        let type = http.value(forHTTPHeaderField: "Content-Type") ?? ""
                        streaming = http.statusCode == 200 && type.lowercased().hasPrefix("text/event-stream")
                    case .data(let data):
                        if streaming {
                            if !relayed {
                                let headers = forward.cors + [("Content-Type", "text/event-stream"), ("Cache-Control", "no-cache"),
                                                              ("Transfer-Encoding", "chunked"), ("Connection", "close")]
                                try await sendToClient(client, LocalAPIHTTP.responseHead(status: 200, headers: headers))
                                relayed = true
                            }
                            try await sendToClient(client, LocalAPIHTTP.chunk(data))
                        } else {
                            buffered.append(data)
                            if buffered.count > limits.maxBufferedResponse { throw UpstreamTooLarge() }
                        }
                    }
                }
            } onCancel: {
                upstream.cancel()
            }
        } catch is ClientGone {
            upstream.cancel()
            return .clientGone
        } catch {
            if interruption.isInterrupted {
                guard relayed else { return .interruptedBeforeReply }
                let event = "data: " + String(decoding: LocalAPIHTTP.errorBody(
                    message: "Lint needed the model and interrupted this answer.", type: "server_error", code: "preempted_by_lint"
                ), as: UTF8.self) + "\n\n"
                // No terminating chunk: the transfer reads as cut short.
                try? await client.send(LocalAPIHTTP.chunk(Data(event.utf8)))
                return .interruptedMidReply
            }
            if Task.isCancelled { return .clientGone }
            if relayed { return .brokenMidReply }
            if error is UpstreamTooLarge { return .failed(502, "upstream_error", "The model's answer was too large.", nil) }
            if let urlError = error as? URLError {
                if urlError.code == .timedOut { return .failed(504, "upstream_timeout", "The model did not answer in time.", nil) }
                if response == nil { return .failed(503, "model_not_running", "Lint's local model is not running.", 10) }
            }
            return .failed(502, "upstream_error", "The model's answer was cut off.", nil)
        }
        if interruption.isInterrupted, !relayed { return .interruptedBeforeReply }
        guard let response else { return .failed(502, "upstream_error", "The model did not answer.", nil) }
        do {
            if streaming {
                if !relayed {
                    let headers = forward.cors + [("Content-Type", "text/event-stream"), ("Transfer-Encoding", "chunked"), ("Connection", "close")]
                    try await sendToClient(client, LocalAPIHTTP.responseHead(status: 200, headers: headers))
                }
                try await sendToClient(client, LocalAPIHTTP.lastChunk)
                return .completed(200)
            }
            if response.statusCode == 401 {
                // llama-server refused Lint's own key: not the client's fault.
                return .failed(502, "upstream_error", "Lint's local model refused the request.", nil)
            }
            var headers = forward.cors
            headers.append(("Content-Type", response.value(forHTTPHeaderField: "Content-Type") ?? "application/json"))
            if let retryAfter = response.value(forHTTPHeaderField: "Retry-After") {
                headers.append(("Retry-After", retryAfter))
            } else if response.statusCode == 503 {
                headers.append(("Retry-After", "5"))
            }
            try await sendToClient(client, LocalAPIHTTP.response(status: response.statusCode, headers: headers, body: buffered))
            return .completed(response.statusCode)
        } catch {
            return .clientGone
        }
    }

    private struct UpstreamTooLarge: Error {}

    private func sendToClient(_ client: APIConnection, _ data: Data) async throws {
        do {
            try await client.send(data)
        } catch {
            throw ClientGone()
        }
    }

    private static func error(_ status: Int, _ message: String, code: String, extra: [(String, String)] = [], retryAfter: Int? = nil) -> Data {
        var headers = extra
        headers.append(("Content-Type", "application/json"))
        if let retryAfter { headers.append(("Retry-After", "\(retryAfter)")) }
        let type = status >= 500 ? "server_error" : "invalid_request_error"
        return LocalAPIHTTP.response(status: status, headers: headers, body: LocalAPIHTTP.errorBody(message: message, type: type, code: code))
    }

    // MARK: - Log

    /// Refused requests and `/v1/models` are counted and logged once a minute, so a client that keeps
    /// trying cannot fill the diagnostic log. No origin, header or body is ever logged.
    private func reject(_ code: String) {
        lock.withLock { rejections[code, default: 0] += 1 }
        flushSummary(force: false)
    }

    private func noteModels() {
        lock.withLock { rejections["models", default: 0] += 1 }
        flushSummary(force: false)
    }

    private func flushSummary(force: Bool) {
        let counts: [String: Int]? = lock.withLock {
            guard !rejections.isEmpty, force || ContinuousClock.now - lastSummary >= .seconds(60) else { return nil }
            defer {
                rejections = [:]
                lastSummary = .now
            }
            return rejections
        }
        guard let counts else { return }
        log("summary " + counts.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: " "))
    }
}

/// Lets Lint stop the request it interrupts: before it reaches llama-server, or by closing the connection.
private final class Interruption: @unchecked Sendable {
    private let lock = NSLock()
    private var interrupted = false
    private var upstream: LocalAPIUpstream?

    var isInterrupted: Bool { lock.withLock { interrupted } }

    func interrupt() {
        let upstream = lock.withLock {
            interrupted = true
            return self.upstream
        }
        upstream?.cancel()
    }

    /// False if Lint already interrupted this turn.
    func attach(_ upstream: LocalAPIUpstream) -> Bool {
        lock.withLock {
            guard !interrupted else { return false }
            self.upstream = upstream
            return true
        }
    }
}

/// Runs a block at most once, from any thread.
private final class Once: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false

    func run(_ block: () -> Void) {
        let first = lock.withLock {
            defer { done = true }
            return !done
        }
        if first { block() }
    }
}

/// A client connection, read and written with async calls.
final class APIConnection: @unchecked Sendable {
    private let connection: NWConnection

    init(_ connection: NWConnection, queue: DispatchQueue) {
        self.connection = connection
        connection.start(queue: queue)
    }

    /// The next bytes, or nil once the client has closed its side.
    func receive() async throws -> Data? {
        try await withCheckedThrowingContinuation { continuation in
            connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { data, _, isComplete, error in
                if let data, !data.isEmpty {
                    continuation.resume(returning: data)
                } else if let error {
                    continuation.resume(throwing: error)
                } else if isComplete {
                    continuation.resume(returning: nil)
                } else {
                    continuation.resume(returning: Data())
                }
            }
        }
    }

    func send(_ data: Data) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connection.send(content: data, completion: .contentProcessed { error in
                if let error { continuation.resume(throwing: error) } else { continuation.resume() }
            })
        }
    }

    func close() {
        connection.cancel()
    }
}
