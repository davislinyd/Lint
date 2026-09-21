import XCTest

@testable import LintCore

/// An in-process "server" behind `URLProtocol`, so the real `URLSessionModelTransport` (delegate,
/// Range handling, redirects, cancellation) runs without a network.
final class StubServerProtocol: URLProtocol, @unchecked Sendable {
    struct Behavior {
        var content: Data
        var honorRange = true
        var forceStatus: Int?
        var failAfterBytes: Int?
        var wrongContentRangeStart: Int64?
        var redirectFrom: String?      // requests for this path answer 302 to /file
        var stallAfterBytes: Int?      // deliver this many bytes, then never finish (until cancelled)
        var chunkSize = 700
    }

    nonisolated(unsafe) static var behavior = Behavior(content: Data())
    nonisolated(unsafe) static var requests: [URLRequest] = []
    nonisolated(unsafe) static var onStall: (() -> Void)?
    private var stopped = false

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func stopLoading() { stopped = true }

    override func startLoading() {
        let behavior = Self.behavior
        Self.requests.append(request)
        let url = request.url!

        if let from = behavior.redirectFrom, url.path == from {
            var next = request
            next.url = URL(string: "https://cdn.example.test/file")
            let response = HTTPURLResponse(url: url, statusCode: 302, httpVersion: "HTTP/1.1", headerFields: ["Location": next.url!.absoluteString])!
            client?.urlProtocol(self, wasRedirectedTo: next, redirectResponse: response)
            return
        }

        var start = 0
        var status = 200
        var headers = ["Content-Length": "\(behavior.content.count)"]
        if let range = request.value(forHTTPHeaderField: "Range"), behavior.honorRange,
           let first = range.dropFirst("bytes=".count).split(separator: "-").first, let offset = Int(first) {
            if offset >= behavior.content.count {
                respond(416, headers: ["Content-Range": "bytes */\(behavior.content.count)"], body: Data())
                return
            }
            start = offset
            status = 206
            let shown = behavior.wrongContentRangeStart ?? Int64(offset)
            headers = [
                "Content-Length": "\(behavior.content.count - offset)",
                "Content-Range": "bytes \(shown)-\(behavior.content.count - 1)/\(behavior.content.count)",
            ]
        }
        if let forced = behavior.forceStatus {
            respond(forced, headers: [:], body: Data("error".utf8))
            return
        }
        let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        var offset = start
        while offset < behavior.content.count, !stopped {
            let end = min(offset + behavior.chunkSize, behavior.content.count)
            client?.urlProtocol(self, didLoad: behavior.content[offset..<end])
            offset = end
            // A real connection delivers bytes over time; without a pause URLSession may drop
            // queued data when the load fails right after it.
            Thread.sleep(forTimeInterval: 0.01)
            if let limit = behavior.failAfterBytes, offset - start >= limit {
                Thread.sleep(forTimeInterval: 0.1)
                client?.urlProtocol(self, didFailWithError: URLError(.networkConnectionLost))
                return
            }
            if let limit = behavior.stallAfterBytes, offset - start >= limit {
                Thread.sleep(forTimeInterval: 0.1)
                Self.onStall?()
                return // no didFinishLoading: the client waits until it cancels
            }
        }
        if !stopped { client?.urlProtocolDidFinishLoading(self) }
    }

    private func respond(_ status: Int, headers: [String: String], body: Data) {
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }
}

final class URLSessionModelTransportTests: XCTestCase {
    private let url = URL(string: "https://models.example.test/file")!
    private let content = TestModel.payload("net", count: 5000)

    private func makeTransport() -> URLSessionModelTransport {
        URLSessionModelTransport(configuration: {
            let configuration = URLSessionModelTransport.defaultConfiguration()
            configuration.protocolClasses = [StubServerProtocol.self]
            return configuration
        })
    }

    override func setUp() {
        super.setUp()
        StubServerProtocol.behavior = .init(content: content)
        StubServerProtocol.requests = []
        StubServerProtocol.onStall = nil
    }

    private func partial() throws -> URL {
        try TestSupport.makeTempDirectory().appendingPathComponent("model.gguf.partial")
    }

    private func range(_ request: URLRequest) -> String? { request.value(forHTTPHeaderField: "Range") }

    func testAFreshDownloadWritesTheWholeFileAndReportsProgress() async throws {
        let file = try partial()
        let seen = ProgressLog()
        try await makeTransport().download(from: url, to: file, expectedSize: Int64(content.count)) { seen.add($0) }
        XCTAssertEqual(try Data(contentsOf: file), content)
        XCTAssertNil(range(StubServerProtocol.requests[0]), "no Range header for a fresh download")
        XCTAssertEqual(StubServerProtocol.requests[0].value(forHTTPHeaderField: "Accept-Encoding"), "identity")
        XCTAssertEqual(seen.values.last, Int64(content.count))
        XCTAssertEqual(seen.values, seen.values.sorted())
    }

    func testAnInterruptedDownloadResumesWithARangeRequest() async throws {
        let file = try partial()
        try content.prefix(1800).write(to: file)
        try await makeTransport().download(from: url, to: file, expectedSize: Int64(content.count)) { _ in }
        XCTAssertEqual(range(StubServerProtocol.requests[0]), "bytes=1800-")
        XCTAssertEqual(try Data(contentsOf: file), content, "the missing tail is appended; nothing is duplicated")
    }

    func testAServerThatIgnoresRangeRestartsFromScratch() async throws {
        StubServerProtocol.behavior.honorRange = false
        let file = try partial()
        try Data("stale bytes that must not survive".utf8).write(to: file)
        try await makeTransport().download(from: url, to: file, expectedSize: Int64(content.count)) { _ in }
        XCTAssertEqual(try Data(contentsOf: file), content)
    }

    func testRangeSurvivesARedirectToTheCDN() async throws {
        // Hugging Face answers the resolve URL with a redirect to its CDN.
        StubServerProtocol.behavior.redirectFrom = "/resolve"
        let redirecting = URL(string: "https://models.example.test/resolve")!
        let file = try partial()
        try content.prefix(2000).write(to: file)
        try await makeTransport().download(from: redirecting, to: file, expectedSize: Int64(content.count)) { _ in }
        XCTAssertEqual(StubServerProtocol.requests.count, 2)
        XCTAssertEqual(StubServerProtocol.requests[1].url?.host, "cdn.example.test")
        XCTAssertEqual(range(StubServerProtocol.requests[1]), "bytes=2000-", "the redirected request must still ask for the remaining bytes")
        XCTAssertEqual(try Data(contentsOf: file), content)
    }

    func testHTTPErrorStatusesFailWithoutTouchingTheFile() async throws {
        for status in [404, 500, 503] {
            StubServerProtocol.behavior.forceStatus = status
            let file = try partial()
            do {
                try await makeTransport().download(from: url, to: file, expectedSize: nil) { _ in }
                XCTFail("\(status) must throw")
            } catch let error as ModelInstallError {
                XCTAssertEqual(error, .httpStatus(status))
            }
            XCTAssertNil(fileSize(at: file).flatMap { $0 > 0 ? $0 : nil }, "no body of an error page may be written as model data")
        }
    }

    func testRangeNotSatisfiableMeansCompleteOnlyWhenTheSizeMatches() async throws {
        let file = try partial()
        try content.write(to: file)
        try await makeTransport().download(from: url, to: file, expectedSize: Int64(content.count)) { _ in }
        XCTAssertEqual(try Data(contentsOf: file), content, "already complete: 416 is success")

        let bigger = try partial()
        try (content + Data(repeating: 1, count: 100)).write(to: bigger)
        do {
            try await makeTransport().download(from: url, to: bigger, expectedSize: Int64(content.count + 500)) { _ in }
            XCTFail("a 416 for an incomplete file must throw")
        } catch let error as ModelInstallError {
            XCTAssertEqual(error, .httpStatus(416))
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: bigger.path), "the unusable partial is discarded")
    }

    func testAContentRangeThatDoesNotContinueWhereWeStoppedIsRejected() async throws {
        StubServerProtocol.behavior.wrongContentRangeStart = 0
        let file = try partial()
        try content.prefix(1000).write(to: file)
        do {
            try await makeTransport().download(from: url, to: file, expectedSize: Int64(content.count)) { _ in }
            XCTFail("must not append data from the wrong offset")
        } catch let error as ModelInstallError {
            guard case .network = error else { return XCTFail("\(error)") }
        }
        XCTAssertEqual(fileSize(at: file), 1000, "the file is left as it was")
    }

    func testAConnectionLossKeepsTheBytesReceivedSoFar() async throws {
        StubServerProtocol.behavior.failAfterBytes = 2100
        let file = try partial()
        do {
            try await makeTransport().download(from: url, to: file, expectedSize: Int64(content.count)) { _ in }
            XCTFail("a lost connection must throw")
        } catch let error as ModelInstallError {
            guard case .network = error else { return XCTFail("\(error)") }
            XCTAssertFalse((error.errorDescription ?? "").isEmpty)
        }
        let kept = try XCTUnwrap(fileSize(at: file))
        XCTAssertEqual(try Data(contentsOf: file), content.prefix(Int(kept)), "what was written is a correct prefix, so resuming is safe")
        XCTAssertGreaterThan(kept, 0)

        StubServerProtocol.behavior.failAfterBytes = nil
        try await makeTransport().download(from: url, to: file, expectedSize: Int64(content.count)) { _ in }
        XCTAssertEqual(try Data(contentsOf: file), content)
    }

    func testCancellingStopsTheDownloadAndKeepsThePartialFile() async throws {
        StubServerProtocol.behavior.stallAfterBytes = 1400
        let stalled = expectation(description: "stalled")
        StubServerProtocol.onStall = { stalled.fulfill() }
        let file = try partial()
        let transport = makeTransport()
        let expected = Int64(content.count)
        let url = self.url
        let task = Task { try await transport.download(from: url, to: file, expectedSize: expected) { _ in } }
        await fulfillment(of: [stalled], timeout: 10)
        task.cancel()
        do {
            try await task.value
            XCTFail("must throw")
        } catch is CancellationError {
        }
        XCTAssertEqual(fileSize(at: file), 1400)
    }

    func testAnAlreadyCancelledTaskDoesNothing() async throws {
        let file = try partial()
        let transport = makeTransport()
        let url = self.url
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            try await transport.download(from: url, to: file, expectedSize: nil) { _ in }
        }
        do {
            try await task.value
            XCTFail("must throw")
        } catch is CancellationError {
        }
    }
}

final class ProgressLog: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [Int64] = []
    func add(_ value: Int64) { lock.withLock { storage.append(value) } }
    var values: [Int64] { lock.withLock { storage } }
}
