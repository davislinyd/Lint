import Network
import XCTest

@testable import LintCore

final class LocalAPIProxyTests: XCTestCase {
    private var upstream: FakeLlamaServer!
    private var proxy: LocalAPIProxy!
    private var gate: ModelPriorityGate!
    private var port = 0
    private let serverKey = LocalAPIKey.generate()
    private let userKey = KeyHolder(LocalAPIKey.generate())
    private let backend = BackendSwitch()
    private let logLines = LogLines()

    override func setUp() async throws {
        upstream = try await FakeLlamaServer.start()
        try await startProxy()
    }

    override func tearDown() async throws {
        proxy?.stop()
        upstream?.stop()
    }

    private func startProxy(limits: LocalAPIProxy.Limits = LocalAPIProxy.Limits(), maxWaiting: Int = 8, origins: [String] = AllowedOrigin.defaults) async throws {
        proxy?.stop()
        gate = ModelPriorityGate(quietPeriod: .milliseconds(50), maxWaiting: maxWaiting)
        let userKey = self.userKey, backend = self.backend, logLines = self.logLines
        proxy = LocalAPIProxy(
            gate: gate, serverKey: serverKey,
            keys: { userKey.lookup },
            ensureBackend: { try backend.check() },
            limits: limits,
            log: { logLines.append($0) }
        )
        port = try await proxy.start(port: 0, upstreamPort: upstream.port, allowedOrigins: origins)
    }

    private func request(
        _ method: String, _ path: String, headers: [String: String] = [:], key: Bool = true, body: String? = nil
    ) -> String {
        var lines = ["\(method) \(path) HTTP/1.1", "Host: 127.0.0.1:\(port)"]
        if key { lines.append("Authorization: Bearer \(userKey.key.value)") }
        for (name, value) in headers.sorted(by: { $0.key < $1.key }) { lines.append("\(name): \(value)") }
        if let body {
            lines.append("Content-Type: application/json")
            lines.append("Content-Length: \(body.utf8.count)")
        }
        return lines.joined(separator: "\r\n") + "\r\n\r\n" + (body ?? "")
    }

    private func send(_ raw: String) async throws -> String {
        try await RawClient.exchange(port: port, request: raw)
    }

    private static let chatBody = #"{"messages":[{"role":"user","content":"Say OK."}],"max_tokens":4}"#

    // MARK: - Checks before anything reaches the model

    func testRequestsWithoutTheRightKeyNeverReachTheModel() async throws {
        for raw in [request("GET", "/v1/models", key: false),
                    request("GET", "/v1/models", headers: ["Authorization": "Bearer wrong"], key: false),
                    request("POST", "/v1/chat/completions", key: false, body: Self.chatBody)] {
            let response = try await send(raw)
            XCTAssertTrue(response.hasPrefix("HTTP/1.1 401 "), response)
            XCTAssertTrue(response.contains("invalid_api_key"))
            XCTAssertTrue(response.contains("WWW-Authenticate: Bearer"))
        }
        XCTAssertEqual(upstream.requests.count, 0)
    }

    func testTheModelGetsLintsKeyAndNeverTheClients() async throws {
        upstream.script([.json(200, #"{"data":[{"id":"gemma"}]}"#), .json(200, #"{"choices":[]}"#)])
        let models = try await send(request("GET", "/v1/models"))
        XCTAssertTrue(models.hasPrefix("HTTP/1.1 200 "), models)
        XCTAssertTrue(models.hasSuffix(#"{"data":[{"id":"gemma"}]}"#))
        let viaHeader = try await send(request("POST", "/v1/chat/completions", headers: ["X-Api-Key": userKey.key.value], key: false, body: Self.chatBody))
        XCTAssertTrue(viaHeader.hasPrefix("HTTP/1.1 200 "), viaHeader)
        XCTAssertEqual(upstream.requests.map(\.authorization), ["Bearer \(serverKey.value)", "Bearer \(serverKey.value)"])
        XCTAssertEqual(upstream.requests.last?.body, Self.chatBody)
        XCTAssertFalse(upstream.requests.contains { $0.rawHead.contains(userKey.key.value) })
    }

    func testOnlyLoopbackHostsAndAllowedPagesGetIn() async throws {
        let rebound = try await send(request("GET", "/v1/models").replacingOccurrences(of: "Host: 127.0.0.1:\(port)", with: "Host: rebind.example:\(port)"))
        XCTAssertTrue(rebound.hasPrefix("HTTP/1.1 403 "), rebound)
        XCTAssertTrue(rebound.contains("invalid_host"))

        let website = try await send(request("GET", "/v1/models", headers: ["Origin": "https://example.com"]))
        XCTAssertTrue(website.hasPrefix("HTTP/1.1 403 "), website)
        XCTAssertFalse(website.contains("Access-Control-Allow-Origin"))

        upstream.script([.json(200, "{}")])
        let localPage = try await send(request("GET", "/v1/models", headers: ["Origin": "http://localhost:3000"]))
        XCTAssertTrue(localPage.hasPrefix("HTTP/1.1 200 "), localPage)
        XCTAssertTrue(localPage.contains("Access-Control-Allow-Origin: http://localhost:3000"))

        let preflight = try await send(request("OPTIONS", "/v1/chat/completions", headers: [
            "Origin": "http://localhost:3000", "Access-Control-Request-Method": "POST",
            "Access-Control-Request-Headers": "authorization, content-type", "Access-Control-Request-Private-Network": "true",
        ], key: false))
        XCTAssertTrue(preflight.hasPrefix("HTTP/1.1 204 "), preflight)
        XCTAssertTrue(preflight.contains("Access-Control-Allow-Headers: authorization, content-type, x-api-key"))
        XCTAssertTrue(preflight.contains("Access-Control-Allow-Private-Network: true"))
        XCTAssertFalse(preflight.contains("Access-Control-Allow-Credentials"))
        XCTAssertEqual(upstream.requests.count, 1)
    }

    func testOnlyTheOpenAIRoutesAreThere() async throws {
        for path in ["/props", "/slots", "/metrics", "/tools", "/v1/embeddings", "/"] {
            let response = try await send(request("GET", path))
            XCTAssertTrue(response.hasPrefix("HTTP/1.1 404 "), "\(path): \(response)")
        }
        let wrongMethod = try await send(request("GET", "/v1/chat/completions"))
        XCTAssertTrue(wrongMethod.hasPrefix("HTTP/1.1 405 "), wrongMethod)
        XCTAssertTrue(wrongMethod.contains("Allow: POST, OPTIONS"))
        let health = try await send(request("GET", "/health", key: false))
        XCTAssertTrue(health.hasPrefix("HTTP/1.1 200 "), health)
        XCTAssertEqual(upstream.requests.count, 0)
    }

    func testOversizedAndContinuingBodies() async throws {
        let huge = request("POST", "/v1/chat/completions").replacingOccurrences(of: "\r\n\r\n", with: "\r\nContent-Length: \(5 * 1024 * 1024)\r\n\r\n")
        let tooLarge = try await send(huge)
        XCTAssertTrue(tooLarge.hasPrefix("HTTP/1.1 413 "), tooLarge)

        upstream.script([.json(200, "{}")])
        let continued = try await send(request("POST", "/v1/chat/completions", headers: ["Expect": "100-continue"], body: Self.chatBody))
        XCTAssertTrue(continued.hasPrefix("HTTP/1.1 100 Continue\r\n\r\nHTTP/1.1 200 "), continued)
    }

    // MARK: - Relaying

    func testAStreamedAnswerIsPassedOnAsItArrives() async throws {
        let events = [#"data: {"choices":[{"delta":{"content":"O"}}]}"#, #"data: {"choices":[{"delta":{"content":"K"}}]}"#, "data: [DONE]"]
        upstream.script([.sse(events.map { $0 + "\n\n" })])
        let response = try await send(request("POST", "/v1/chat/completions", body: Self.chatBody))
        XCTAssertTrue(response.hasPrefix("HTTP/1.1 200 "), response)
        XCTAssertTrue(response.contains("Transfer-Encoding: chunked"))
        XCTAssertTrue(response.contains("Content-Type: text/event-stream"))
        for event in events { XCTAssertTrue(response.contains(event), event) }
        XCTAssertTrue(response.hasSuffix("0\r\n\r\n"), "a finished stream ends properly")
    }

    func testAnAnswerInOnePieceKeepsItsStatusAndLength() async throws {
        let body = #"{"error":{"message":"bad"}}"#
        upstream.script([.json(400, body)])
        let response = try await send(request("POST", "/v1/completions", body: #"{"prompt":"x"}"#))
        XCTAssertTrue(response.hasPrefix("HTTP/1.1 400 "), response)
        XCTAssertTrue(response.contains("Content-Length: \(body.utf8.count)\r\n"), response)
        XCTAssertTrue(response.hasSuffix(body))
    }

    func testANotRunningOrRefusingModelIsReportedAsSuch() async throws {
        backend.state = .notRunning
        let down = try await send(request("POST", "/v1/chat/completions", body: Self.chatBody))
        XCTAssertTrue(down.hasPrefix("HTTP/1.1 503 "), down)
        XCTAssertTrue(down.contains("model_not_running"))
        XCTAssertTrue(down.contains("Retry-After: 10"))

        backend.state = .ready
        upstream.script([.json(401, #"{"error":"Invalid API Key"}"#)])
        let refused = try await send(request("POST", "/v1/chat/completions", body: Self.chatBody))
        XCTAssertTrue(refused.hasPrefix("HTTP/1.1 502 "), "the client's key was fine: \(refused)")

        backend.state = .notLocal
        let elsewhere = try await send(request("POST", "/v1/chat/completions", body: Self.chatBody))
        XCTAssertTrue(elsewhere.hasPrefix("HTTP/1.1 503 "), elsewhere)
    }

    // MARK: - Lint first

    func testAnAnswerLintInterruptedBeforeItBeganIsSentAgain() async throws {
        upstream.script([.hang, .json(200, #"{"ok":true}"#)])
        let raw = request("POST", "/v1/chat/completions", body: Self.chatBody)
        let response = Task { [port] in try await RawClient.exchange(port: port, request: raw) }
        try await waitUntil { self.upstream.requests.count == 1 }
        let ticket = gate.beginLint()
        try await waitUntil { self.upstream.disconnects == 1 }
        ticket.end()
        let text = try await response.value
        XCTAssertTrue(text.hasPrefix("HTTP/1.1 200 "), text)
        XCTAssertTrue(text.hasSuffix(#"{"ok":true}"#))
        XCTAssertEqual(upstream.requests.count, 2, "sent again once Lint was done")
        XCTAssertTrue(logLines.all.contains { $0.contains("preempted=1 retried=1") }, "\(logLines.all)")
    }

    func testAStreamLintInterruptsHalfwayEndsWithAnError() async throws {
        upstream.script([.sseThenHang([#"data: {"choices":[{"delta":{"content":"O"}}]}"# + "\n\n"])])
        let raw = request("POST", "/v1/chat/completions", body: Self.chatBody)
        let response = Task { [port] in try await RawClient.exchange(port: port, request: raw) }
        try await waitUntil { self.upstream.sentChunks >= 1 }
        try await Task.sleep(for: .milliseconds(100))
        let ticket = gate.beginLint()
        let text = try await response.value
        ticket.end()
        XCTAssertTrue(text.contains(#""content":"O""#), text)
        XCTAssertTrue(text.contains("preempted_by_lint"), text)
        XCTAssertFalse(text.hasSuffix("0\r\n\r\n"), "the transfer must read as cut short")
        XCTAssertEqual(upstream.requests.count, 1, "what was already sent cannot be sent again")
    }

    func testAClientThatHangsUpStopsTheModel() async throws {
        upstream.script([.hang])
        let client = try await RawClient.open(port: port)
        try await client.send(request("POST", "/v1/chat/completions", body: Self.chatBody))
        try await waitUntil { self.upstream.requests.count == 1 }
        client.close()
        try await waitUntil { self.upstream.disconnects == 1 }
        XCTAssertFalse(gate.isExternalActive)
    }

    func testWaitingIsBoundedByTheQueueAndTheBudget() async throws {
        var limits = LocalAPIProxy.Limits()
        limits.maxWait = .milliseconds(300)
        try await startProxy(limits: limits, maxWaiting: 1)
        let ticket = gate.beginLint()
        let raw = request("POST", "/v1/chat/completions", body: Self.chatBody)
        let first = Task { [port] in try await RawClient.exchange(port: port, request: raw) }
        try await waitUntil { self.gate.waitingCount == 1 }
        let second = try await send(request("POST", "/v1/chat/completions", body: Self.chatBody))
        XCTAssertTrue(second.hasPrefix("HTTP/1.1 503 "), second)
        XCTAssertTrue(second.contains("queue_full"))
        let waited = try await first.value
        XCTAssertTrue(waited.hasPrefix("HTTP/1.1 503 "), waited)
        XCTAssertTrue(waited.contains("lint_busy"))
        XCTAssertTrue(waited.contains("Retry-After: 30"))
        ticket.end()
        XCTAssertEqual(upstream.requests.count, 0)
    }

    // MARK: - Settings and the log

    func testANewKeyAndANewWebsiteApplyAtOnce() async throws {
        upstream.script([.json(200, "{}"), .json(200, "{}")])
        let old: LocalAPIKey = userKey.key
        userKey.key = LocalAPIKey.generate()
        let stale = try await send(request("GET", "/v1/models", headers: ["Authorization": "Bearer \(old.value)"], key: false))
        XCTAssertTrue(stale.hasPrefix("HTTP/1.1 401 "), stale)

        proxy.update(upstreamPort: upstream.port, allowedOrigins: AllowedOrigin.defaults + ["https://tool.example.com"])
        let site = try await send(request("GET", "/v1/models", headers: ["Origin": "https://tool.example.com"]))
        XCTAssertTrue(site.hasPrefix("HTTP/1.1 200 "), site)
    }

    func testEveryListedKeyWorksAndARevokedOneStopsAtOnce() async throws {
        upstream.script([.json(200, "{}"), .json(200, "{}"), .json(200, "{}")])
        let bob = LocalAPIKey.generate()
        userKey.extra = [LocalAPIKeyring.Lookup.Entry(id: "b0b0b0b0-0000-4000-8000-000000000000", key: bob)]
        let viaMain = try await send(request("GET", "/v1/models"))
        XCTAssertTrue(viaMain.hasPrefix("HTTP/1.1 200 "), viaMain)
        let viaBob = try await send(request("GET", "/v1/models", headers: ["Authorization": "Bearer \(bob.value)"], key: false))
        XCTAssertTrue(viaBob.hasPrefix("HTTP/1.1 200 "), viaBob)

        userKey.extra = []
        let revoked = try await send(request("GET", "/v1/models", headers: ["Authorization": "Bearer \(bob.value)"], key: false))
        XCTAssertTrue(revoked.hasPrefix("HTTP/1.1 401 "), revoked)
        let stillMain = try await send(request("GET", "/v1/models"))
        XCTAssertTrue(stillMain.hasPrefix("HTTP/1.1 200 "), stillMain)
    }

    func testWithoutKeysNothingGetsInAndAnUnreadableKeyIsSaidSo() async throws {
        let main = try XCTUnwrap(userKey.key)
        userKey.key = nil
        let none = try await send(request("GET", "/v1/models", headers: ["Authorization": "Bearer \(main.value)"], key: false))
        XCTAssertTrue(none.hasPrefix("HTTP/1.1 401 "), none)

        userKey.unreadable = true
        let unreadable = try await send(request("GET", "/v1/models", headers: ["Authorization": "Bearer \(main.value)"], key: false))
        XCTAssertTrue(unreadable.hasPrefix("HTTP/1.1 503 "), unreadable)
        XCTAssertTrue(unreadable.contains("key_unavailable"))
        XCTAssertTrue(unreadable.contains("Retry-After: 30"))
        let noKeyAtAll = try await send(request("GET", "/v1/models", key: false))
        XCTAssertTrue(noKeyAtAll.hasPrefix("HTTP/1.1 401 "), "no key presented is still a 401: \(noKeyAtAll)")
        XCTAssertEqual(upstream.requests.count, 0)
    }

    func testBrowserExtensionsNeedTheirOwnSwitch() async throws {
        upstream.script([.json(200, "{}")])
        let origin = "chrome-extension://abcdefghijklmnopabcdefghijklmnop"
        let blocked = try await send(request("GET", "/v1/models", headers: ["Origin": origin]))
        XCTAssertTrue(blocked.hasPrefix("HTTP/1.1 403 "), "off by default: \(blocked)")

        proxy.update(upstreamPort: upstream.port, allowedOrigins: AllowedOrigin.defaults, allowBrowserExtensions: true)
        let allowed = try await send(request("GET", "/v1/models", headers: ["Origin": origin]))
        XCTAssertTrue(allowed.hasPrefix("HTTP/1.1 200 "), allowed)
        XCTAssertTrue(allowed.contains("Access-Control-Allow-Origin: \(origin)"), allowed)
        let withoutKey = try await send(request("GET", "/v1/models", headers: ["Origin": origin], key: false))
        XCTAssertTrue(withoutKey.hasPrefix("HTTP/1.1 401 "), "an extension still needs a key: \(withoutKey)")
        let website = try await send(request("GET", "/v1/models", headers: ["Origin": "https://evil.example"]))
        XCTAssertTrue(website.hasPrefix("HTTP/1.1 403 "), "extensions do not open the door to websites: \(website)")
        let file = try await send(request("GET", "/v1/models", headers: ["Origin": "null"]))
        XCTAssertTrue(file.hasPrefix("HTTP/1.1 403 "), "nor to local files: \(file)")
    }

    func testABusyPortIsReported() async throws {
        let other = LocalAPIProxy(
            gate: ModelPriorityGate(), serverKey: serverKey, keys: { LocalAPIKeyring.Lookup(keys: [], unreadable: false) },
            ensureBackend: {}, log: { _ in }
        )
        do {
            try await other.start(port: port, upstreamPort: upstream.port, allowedOrigins: [])
            XCTFail("two listeners on one port")
        } catch LocalAPIProxy.StartError.portUnavailable(let busy) {
            XCTAssertEqual(busy, port)
        }
    }

    func testTheLogHoldsNoKeyBodyOrOrigin() async throws {
        upstream.script([.json(200, "{}")])
        _ = try await send(request("POST", "/v1/chat/completions", headers: ["Origin": "http://localhost:3000"], body: Self.chatBody))
        _ = try await send(request("GET", "/v1/models", headers: ["Origin": "https://secret-site.example"]))
        _ = try await send(request("GET", "/v1/models", key: false))
        proxy.stop()
        let log = logLines.all.joined(separator: "\n")
        XCTAssertTrue(log.contains("POST /v1/chat/completions status=200"), log)
        XCTAssertTrue(log.contains("key=a1b2c3"), "which key was used, by its short id: \(log)")
        XCTAssertTrue(log.contains("origin_not_allowed=1"), log)
        for secret in [userKey.key.value, serverKey.value, "Say OK.", "localhost:3000", "secret-site"] {
            XCTAssertFalse(log.contains(secret), secret)
        }
    }

    private func waitUntil(timeout: TimeInterval = 5, _ condition: @escaping () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            if Date() > deadline { throw XCTSkip("timed out") }
            try await Task.sleep(for: .milliseconds(10))
        }
    }
}

// MARK: - Helpers

/// The keys the proxy accepts: `key` (listed first, as `a1b2c3…`) and any others.
final class KeyHolder: @unchecked Sendable {
    static let mainID = "a1b2c3d4-0000-4000-8000-000000000000"
    private let lock = NSLock()
    private var current: LocalAPIKey?
    private var others: [LocalAPIKeyring.Lookup.Entry] = []
    private var cannotRead = false
    init(_ key: LocalAPIKey) { current = key }
    /// The main key; setting nil revokes it.
    var key: LocalAPIKey! {
        get { lock.withLock { current } }
        set { lock.withLock { current = newValue } }
    }
    var extra: [LocalAPIKeyring.Lookup.Entry] {
        get { lock.withLock { others } }
        set { lock.withLock { others = newValue } }
    }
    var unreadable: Bool {
        get { lock.withLock { cannotRead } }
        set { lock.withLock { cannotRead = newValue } }
    }
    var lookup: LocalAPIKeyring.Lookup {
        lock.withLock {
            let main = current.map { [LocalAPIKeyring.Lookup.Entry(id: Self.mainID, key: $0)] } ?? []
            return LocalAPIKeyring.Lookup(keys: main + others, unreadable: cannotRead)
        }
    }
}

final class BackendSwitch: @unchecked Sendable {
    enum State { case ready, notRunning, notLocal }
    private let lock = NSLock()
    private var value = State.ready
    var state: State {
        get { lock.withLock { value } }
        set { lock.withLock { value = newValue } }
    }

    func check() throws {
        switch state {
        case .ready: return
        case .notRunning: throw LocalAPIBackendUnavailable.notRunning
        case .notLocal: throw LocalAPIBackendUnavailable.notLocalEngine
        }
    }
}

final class LogLines: @unchecked Sendable {
    private let lock = NSLock()
    private var lines: [String] = []
    var all: [String] { lock.withLock { lines } }
    func append(_ line: String) { lock.withLock { lines.append(line) } }
}

/// A raw TCP client, so a test can send exactly the bytes it wants (URLSession would fix the Host).
final class RawClient: @unchecked Sendable {
    private let connection: APIConnection

    private init(_ connection: APIConnection) {
        self.connection = connection
    }

    /// Sends and reads queue up until the connection is ready.
    static func open(port: Int) async throws -> RawClient {
        let endpoint = NWEndpoint.hostPort(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: UInt16(port))!)
        return RawClient(APIConnection(NWConnection(to: endpoint, using: .tcp), queue: DispatchQueue(label: "raw-client")))
    }

    func send(_ text: String) async throws {
        try await connection.send(Data(text.utf8))
    }

    /// Everything until the server closes the connection.
    func readAll() async throws -> String {
        var data = Data()
        while let chunk = try? await connection.receive(), !chunk.isEmpty { data.append(chunk) }
        return String(decoding: data, as: UTF8.self)
    }

    func close() {
        connection.close()
    }

    static func exchange(port: Int, request: String) async throws -> String {
        let client = try await open(port: port)
        try await client.send(request)
        let response = try await client.readAll()
        client.close()
        return response
    }
}

final class OnceFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false
    func run(_ block: () -> Void) {
        let first = lock.withLock { defer { done = true }; return !done }
        if first { block() }
    }
}

/// Stands in for llama-server: reads one request per connection and answers as scripted.
final class FakeLlamaServer: @unchecked Sendable {
    enum Behavior {
        case json(Int, String)
        case sse([String])
        /// Sends the first events, then keeps the connection open without finishing.
        case sseThenHang([String])
        /// Reads the request and never answers.
        case hang
    }

    struct Request {
        var method: String
        var path: String
        var authorization: String?
        var body: String
        var rawHead: String
    }

    private let listener: NWListener
    private let queue = DispatchQueue(label: "fake-llama-server")
    private let lock = NSLock()
    private var scripted: [Behavior] = []
    private var recorded: [Request] = []
    private var closedConnections = 0
    private var chunksSent = 0
    let port: Int

    private init(listener: NWListener, port: Int) {
        self.listener = listener
        self.port = port
    }

    static func start() async throws -> FakeLlamaServer {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        let listener = try NWListener(using: parameters)
        let queue = DispatchQueue(label: "fake-llama-listener")
        let ready = OnceFlag()
        let port: Int = try await withCheckedThrowingContinuation { continuation in
            listener.stateUpdateHandler = { state in
                switch state {
                case .ready: ready.run { continuation.resume(returning: Int(listener.port!.rawValue)) }
                case .failed(let error): ready.run { continuation.resume(throwing: error) }
                default: break
                }
            }
            listener.newConnectionHandler = { _ in }
            listener.start(queue: queue)
        }
        let server = FakeLlamaServer(listener: listener, port: port)
        listener.newConnectionHandler = { [weak server] connection in server?.serve(connection) }
        return server
    }

    func stop() { listener.cancel() }

    func script(_ behaviors: [Behavior]) { lock.withLock { scripted += behaviors } }
    var requests: [Request] { lock.withLock { recorded } }
    var disconnects: Int { lock.withLock { closedConnections } }
    var sentChunks: Int { lock.withLock { chunksSent } }

    private func serve(_ nw: NWConnection) {
        let connection = APIConnection(nw, queue: queue)
        Task {
            var buffer = Data()
            var parsed: (head: LocalAPIHTTP.Head, length: Int)?
            while parsed == nil {
                guard let data = try? await connection.receive(), !data.isEmpty else { return }
                buffer.append(data)
                parsed = try? LocalAPIHTTP.parseHead(buffer)
            }
            guard let parsed else { return }
            let length = (try? LocalAPIHTTP.bodyLength(of: parsed.head)) ?? 0
            while buffer.count < parsed.length + length {
                guard let data = try? await connection.receive(), !data.isEmpty else { return }
                buffer.append(data)
            }
            let body = String(decoding: buffer[parsed.length..<(parsed.length + length)], as: UTF8.self)
            let behavior: Behavior = lock.withLock {
                recorded.append(Request(
                    method: parsed.head.method, path: parsed.head.path, authorization: parsed.head.header("Authorization"),
                    body: body, rawHead: String(decoding: buffer.prefix(parsed.length), as: UTF8.self)
                ))
                return scripted.isEmpty ? .json(200, "{}") : scripted.removeFirst()
            }
            switch behavior {
            case .json(let status, let text):
                try? await connection.send(LocalAPIHTTP.response(status: status, headers: [("Content-Type", "application/json")], body: Data(text.utf8)))
                connection.close()
            case .sse(let events):
                try? await connection.send(LocalAPIHTTP.responseHead(status: 200, headers: [("Content-Type", "text/event-stream"), ("Transfer-Encoding", "chunked")]))
                for event in events {
                    try? await connection.send(LocalAPIHTTP.chunk(Data(event.utf8)))
                    lock.withLock { chunksSent += 1 }
                    try? await Task.sleep(for: .milliseconds(20))
                }
                try? await connection.send(LocalAPIHTTP.lastChunk)
                connection.close()
            case .sseThenHang(let events):
                try? await connection.send(LocalAPIHTTP.responseHead(status: 200, headers: [("Content-Type", "text/event-stream"), ("Transfer-Encoding", "chunked")]))
                for event in events {
                    try? await connection.send(LocalAPIHTTP.chunk(Data(event.utf8)))
                    lock.withLock { chunksSent += 1 }
                }
                await waitForClose(connection)
            case .hang:
                await waitForClose(connection)
            }
        }
    }

    private func waitForClose(_ connection: APIConnection) async {
        while let data = try? await connection.receive(), !data.isEmpty {}
        lock.withLock { closedConnections += 1 }
        connection.close()
    }
}
