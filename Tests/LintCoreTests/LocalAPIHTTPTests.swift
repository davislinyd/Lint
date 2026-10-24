import XCTest

@testable import LintCore

final class LocalAPIHTTPTests: XCTestCase {
    private func parse(_ text: String) throws(LocalAPIHTTP.Refusal) -> (head: LocalAPIHTTP.Head, length: Int)? {
        try LocalAPIHTTP.parseHead(Data(text.utf8))
    }

    private func refusal(_ text: String) -> LocalAPIHTTP.Refusal? {
        do {
            _ = try parse(text)
            return nil
        } catch {
            return error
        }
    }

    func testAnOrdinaryRequestIsRead() throws {
        let raw = "POST /v1/chat/completions?x=1 HTTP/1.1\r\nHost: 127.0.0.1:8001\r\nContent-Length: 2\r\nAuthorization:  Bearer abc \r\n\r\n{}"
        let parsed = try XCTUnwrap(try parse(raw))
        XCTAssertEqual(parsed.head.method, "POST")
        XCTAssertEqual(parsed.head.path, "/v1/chat/completions", "the query is not part of the route")
        XCTAssertEqual(parsed.head.header("host"), "127.0.0.1:8001")
        XCTAssertEqual(parsed.head.header("AUTHORIZATION"), "Bearer abc")
        XCTAssertEqual(parsed.length, raw.utf8.count - 2, "the body starts after the blank line")
        XCTAssertEqual(try LocalAPIHTTP.bodyLength(of: parsed.head), 2)
    }

    func testAHeadIsOnlyReadOnceItHasEnded() throws {
        XCTAssertNil(try parse("GET /health HTTP/1.1\r\nHost: localhost:8001\r\n"))
    }

    func testMalformedHeadsAreRefused() {
        XCTAssertEqual(refusal("GET http://evil.example/v1/models HTTP/1.1\r\n\r\n"), .badRequest, "absolute-form targets")
        XCTAssertEqual(refusal("GET * HTTP/1.1\r\n\r\n"), .badRequest)
        XCTAssertEqual(refusal("get /health HTTP/1.1\r\n\r\n"), .badRequest)
        XCTAssertEqual(refusal("GET /health HTTP/2\r\n\r\n"), .badRequest)
        XCTAssertEqual(refusal("GET  /health HTTP/1.1\r\n\r\n"), .badRequest)
        XCTAssertEqual(refusal("GET /health HTTP/1.1\r\nHost: a\r\n folded: value\r\n\r\n"), .badRequest, "obsolete line folding")
        XCTAssertEqual(refusal("GET /health HTTP/1.1\r\nNo colon here\r\n\r\n"), .badRequest)
        XCTAssertEqual(refusal("GET /health HTTP/1.1\r\nBad Name: x\r\n\r\n"), .badRequest)
        XCTAssertEqual(refusal("GET /health HTTP/1.1\r\nHost: café\r\n\r\n"), .badRequest, "nothing but ASCII")
    }

    func testOversizedHeadsAreRefused() {
        XCTAssertEqual(refusal("GET /" + String(repeating: "a", count: 9000) + " HTTP/1.1\r\n\r\n"), .headTooLarge)
        XCTAssertEqual(refusal("GET /" + String(repeating: "a", count: 9000)), .headTooLarge, "even before the line ends")
        let many = (0...100).map { "X-\($0): y\r\n" }.joined()
        XCTAssertEqual(refusal("GET /health HTTP/1.1\r\n\(many)\r\n"), .headTooLarge)
        XCTAssertEqual(refusal("GET /health HTTP/1.1\r\nX: \(String(repeating: "y", count: 17000))"), .headTooLarge)
    }

    func testOnlyAPlainContentLengthBodyIsAccepted() throws {
        func length(_ headers: String) throws(LocalAPIHTTP.Refusal) -> Int {
            let parsed = try parse("POST /v1/completions HTTP/1.1\r\n\(headers)\r\n")!
            return try LocalAPIHTTP.bodyLength(of: parsed.head)
        }
        XCTAssertEqual(try length(""), 0)
        XCTAssertEqual(try length("Content-Length: 10\r\nContent-Length: 10\r\n"), 10)
        XCTAssertThrowsError(try length("Transfer-Encoding: chunked\r\n")) { XCTAssertEqual($0 as? LocalAPIHTTP.Refusal, .lengthRequired) }
        XCTAssertThrowsError(try length("Content-Length: 5\r\nTransfer-Encoding: chunked\r\n")) { XCTAssertEqual($0 as? LocalAPIHTTP.Refusal, .badRequest) }
        XCTAssertThrowsError(try length("Content-Length: 5\r\nContent-Length: 6\r\n")) { XCTAssertEqual($0 as? LocalAPIHTTP.Refusal, .badRequest) }
        XCTAssertThrowsError(try length("Content-Length: -1\r\n")) { XCTAssertEqual($0 as? LocalAPIHTTP.Refusal, .badRequest) }
        XCTAssertThrowsError(try length("Content-Length: 1e3\r\n")) { XCTAssertEqual($0 as? LocalAPIHTTP.Refusal, .badRequest) }
        XCTAssertThrowsError(try length("Content-Length: \(4 * 1024 * 1024 + 1)\r\n")) { XCTAssertEqual($0 as? LocalAPIHTTP.Refusal, .bodyTooLarge) }
    }

    func testResponsesAreWrittenAsHTTP11ThatClosesTheConnection() {
        let text = String(decoding: LocalAPIHTTP.response(status: 401, headers: [("WWW-Authenticate", "Bearer")], body: Data("{}".utf8)), as: UTF8.self)
        XCTAssertEqual(text, "HTTP/1.1 401 Unauthorized\r\nWWW-Authenticate: Bearer\r\nContent-Length: 2\r\nConnection: close\r\n\r\n{}")
        XCTAssertEqual(String(decoding: LocalAPIHTTP.chunk(Data(String(repeating: "x", count: 26).utf8)), as: UTF8.self), "1a\r\n" + String(repeating: "x", count: 26) + "\r\n")
        XCTAssertEqual(String(decoding: LocalAPIHTTP.lastChunk, as: UTF8.self), "0\r\n\r\n")
    }

    func testErrorsHaveTheShapeOpenAIClientsRead() throws {
        let body = LocalAPIHTTP.errorBody(message: "Lint is using the model.", type: "server_error", code: "lint_busy")
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: [String: String]])
        XCTAssertEqual(object["error"], ["message": "Lint is using the model.", "type": "server_error", "code": "lint_busy"])
    }
}
