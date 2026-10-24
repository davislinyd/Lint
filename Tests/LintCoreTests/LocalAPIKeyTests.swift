import XCTest

@testable import LintCore

final class LocalAPIKeyTests: XCTestCase {
    func testAKeyIs32RandomBytesInBase64URL() {
        let keys = (0..<50).map { _ in LocalAPIKey.generate().value }
        XCTAssertEqual(Set(keys).count, keys.count)
        for key in keys {
            XCTAssertEqual(key.count, 43)
            XCTAssertTrue(key.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") }, key)
        }
    }

    func testAKeyNeverShowsUpWhenPrintedOrLogged() {
        let key = LocalAPIKey.generate()
        for text in ["\(key)", String(describing: key), String(reflecting: key), "\([key])", "\(Mirror(reflecting: key).children.map(\.value))"] {
            XCTAssertFalse(text.contains(key.value), text)
        }
    }

    func testOnlyTheSameKeyMatches() {
        let key = LocalAPIKey(value: "abc")
        XCTAssertTrue(key.matches("abc"))
        XCTAssertFalse(key.matches("abd"))
        XCTAssertFalse(key.matches("ab"))
        XCTAssertFalse(key.matches(""))
        XCTAssertFalse(key.matches("abcabc"))
    }

    func testTheStoreCreatesTheKeyOnceAndReadsItOnlyOnce() throws {
        let box = KeyBox()
        let store = LocalAPIKeyStore(read: { box.read() }, write: { box.write($0) })
        let first = try store.current()
        let second = try store.current()
        XCTAssertEqual(first.value, second.value)
        XCTAssertEqual(box.reads, 1, "cached after the first look")
        XCTAssertEqual(box.writes, 1)
        XCTAssertEqual(box.stored, first.value)

        let again = LocalAPIKeyStore(read: { box.read() }, write: { box.write($0) })
        XCTAssertEqual(try again.current().value, first.value, "a stored key is kept across launches")
        XCTAssertEqual(box.writes, 1)
    }

    func testRegeneratingReplacesTheStoredKey() throws {
        let box = KeyBox()
        let store = LocalAPIKeyStore(read: { box.read() }, write: { box.write($0) })
        let old = try store.current()
        let new = try store.regenerate()
        XCTAssertNotEqual(old.value, new.value)
        XCTAssertEqual(try store.current().value, new.value)
        XCTAssertEqual(box.stored, new.value)
    }

    func testAFailedReadIsNotRetriedUntilTheKeyIsRegenerated() throws {
        let box = KeyBox()
        box.failReads = true
        let store = LocalAPIKeyStore(read: { try box.readOrFail() }, write: { box.write($0) })
        XCTAssertThrowsError(try store.current())
        XCTAssertThrowsError(try store.current())
        XCTAssertEqual(box.reads, 1, "one prompt, not one per request")
        let new = try store.regenerate()
        XCTAssertEqual(try store.current().value, new.value)
    }

    func testAStoredValueThatIsNotAKeyIsReplaced() throws {
        let box = KeyBox()
        box.stored = "short"
        let store = LocalAPIKeyStore(read: { box.read() }, write: { box.write($0) })
        XCTAssertEqual(try store.current().value.count, 43)
        XCTAssertNotEqual(box.stored, "short")
    }
}

private final class KeyBox: @unchecked Sendable {
    private let lock = NSLock()
    var stored: String?
    var failReads = false
    private(set) var reads = 0
    private(set) var writes = 0

    struct Denied: Error {}

    func readOrFail() throws -> String? {
        let fail = lock.withLock { failReads }
        let value = read()
        if fail { throw Denied() }
        return value
    }

    func read() -> String? {
        lock.lock()
        defer { lock.unlock() }
        reads += 1
        return stored
    }

    func write(_ value: String) {
        lock.lock()
        defer { lock.unlock() }
        writes += 1
        stored = value
    }
}
