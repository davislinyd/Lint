import XCTest

@testable import LintCore

final class BoundedLogBufferTests: XCTestCase {
    func testKeepsOnlyTheLastBytesAndDropsACutFirstLine() {
        let buffer = BoundedLogBuffer(capacity: 40)
        for index in 0..<100 { buffer.append(Data("line number \(index)\n".utf8)) }
        let tail = buffer.tail(lines: 50)
        XCTAssertTrue(tail.hasSuffix("line number 99"))
        XCTAssertFalse(tail.contains("line number 0\n"))
        XCTAssertLessThanOrEqual(tail.split(separator: "\n").count, 3, "40 bytes hold about three of these lines")
        XCTAssertTrue(tail.split(separator: "\n").allSatisfy { $0.hasPrefix("line number ") }, "no half-cut line: \(tail)")
    }

    func testTailLimitsLinesAndCharacters() {
        let buffer = BoundedLogBuffer()
        buffer.append(Data((1...30).map { "row \($0)\n\n" }.joined().utf8))
        XCTAssertEqual(buffer.tail(lines: 2), "row 29\nrow 30")
        let long = BoundedLogBuffer()
        long.append(Data(String(repeating: "x", count: 5000).utf8))
        XCTAssertLessThanOrEqual(long.tail(maxCharacters: 100).count, 101)
    }

    func testAnEmptyBufferHasNoTailAndInvalidUTF8DoesNotCrash() {
        let buffer = BoundedLogBuffer()
        XCTAssertEqual(buffer.tail(), "")
        buffer.append(Data([0xFF, 0xFE, 0x41, 0x0A]))
        XCTAssertTrue(buffer.tail().hasSuffix("A"))
    }
}
