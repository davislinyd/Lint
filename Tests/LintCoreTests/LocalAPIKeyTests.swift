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

    func testWithoutAListTheKeyFromBeforeIsKeptAsTheDefault() throws {
        let box = KeyringBox()
        box.secrets[LocalAPIKeyring.legacyAccount] = String(repeating: "a", count: 43)
        let keyring = box.keyring()
        let records = keyring.records()
        XCTAssertEqual(records.map(\.account), [LocalAPIKeyring.legacyAccount])
        XCTAssertEqual(keyring.lookup().keys.map(\.key.value), [String(repeating: "a", count: 43)])
        XCTAssertNil(box.records, "nothing is written until the list changes")
    }

    func testTheDefaultKeyIsMadeTheFirstTimeItIsNeededAndReadOnlyOnce() throws {
        let box = KeyringBox()
        let keyring = box.keyring()
        let first = keyring.lookup()
        let second = keyring.lookup()
        XCTAssertEqual(first.keys.count, 1)
        XCTAssertEqual(first.keys.map(\.key.value), second.keys.map(\.key.value))
        XCTAssertEqual(box.secrets[LocalAPIKeyring.legacyAccount], first.keys.first?.key.value)
        XCTAssertEqual(box.reads, 1, "cached after the first look")
        XCTAssertEqual(box.writes, 1)
        XCTAssertEqual(box.keyring().lookup().keys.map(\.key.value), first.keys.map(\.key.value), "kept across launches")
    }

    func testEveryKeyWorksUntilItIsRevoked() throws {
        let box = KeyringBox()
        let keyring = box.keyring()
        let legacy = try XCTUnwrap(keyring.lookup().keys.first)
        let (alice, aliceKey) = try keyring.create(name: "  Alice's script ")
        let (bob, bobKey) = try keyring.create(name: "Bob's page")
        XCTAssertEqual(alice.name, "Alice's script")
        XCTAssertNotEqual(alice.id, bob.id)
        XCTAssertNotEqual(alice.account, bob.account)
        XCTAssertEqual(Set(keyring.lookup().keys.map(\.key.value)), [legacy.key.value, aliceKey.value, bobKey.value])

        keyring.revoke(id: alice.id)
        XCTAssertEqual(keyring.records().map(\.id), [legacy.id, bob.id])
        XCTAssertEqual(Set(keyring.lookup().keys.map(\.key.value)), [legacy.key.value, bobKey.value], "revoked at once")
        XCTAssertNil(box.secrets[alice.account], "its secret is deleted")

        let relaunched = box.keyring()
        XCTAssertEqual(relaunched.records().map(\.id), [legacy.id, bob.id], "the list is kept")
        XCTAssertEqual(Set(relaunched.lookup().keys.map(\.key.value)), [legacy.key.value, bobKey.value])
    }

    func testRevokingEveryKeyLeavesNone() throws {
        let box = KeyringBox()
        let keyring = box.keyring()
        for record in keyring.records() { keyring.revoke(id: record.id) }
        XCTAssertTrue(keyring.lookup().keys.isEmpty)
        XCTAssertTrue(box.keyring().records().isEmpty, "an empty list stays empty; no default key comes back")
    }

    func testNamesAndTheNumberOfKeysAreLimited() throws {
        let keyring = KeyringBox().keyring()
        XCTAssertThrowsError(try keyring.create(name: "   "))
        XCTAssertThrowsError(try keyring.create(name: String(repeating: "x", count: LocalAPIKeyring.maxNameLength + 1)))
        for index in 1..<LocalAPIKeyring.maxKeys { _ = try keyring.create(name: "Key \(index)") }
        XCTAssertEqual(keyring.records().count, LocalAPIKeyring.maxKeys)
        XCTAssertThrowsError(try keyring.create(name: "One too many"))
    }

    func testAFailedReadIsRememberedForThatKeyOnly() throws {
        let box = KeyringBox()
        let keyring = box.keyring()
        _ = keyring.lookup()
        let (bob, bobKey) = try keyring.create(name: "Bob")
        box.failingAccounts = [LocalAPIKeyring.legacyAccount]
        let relaunched = box.keyring()
        let lookup = relaunched.lookup()
        XCTAssertTrue(lookup.unreadable)
        XCTAssertEqual(lookup.keys.map(\.id), [bob.id])
        XCTAssertEqual(lookup.keys.map(\.key.value), [bobKey.value])
        let reads = box.reads
        _ = relaunched.lookup()
        XCTAssertEqual(box.reads, reads, "one prompt, not one per request")
    }

    func testAStoredValueThatIsNotAKeyIsReplaced() throws {
        let box = KeyringBox()
        box.secrets[LocalAPIKeyring.legacyAccount] = "short"
        XCTAssertEqual(box.keyring().lookup().keys.first?.key.value.count, 43)
        XCTAssertNotEqual(box.secrets[LocalAPIKeyring.legacyAccount], "short")
    }

    func testTheListHoldsNoSecrets() throws {
        let box = KeyringBox()
        let keyring = box.keyring()
        let (_, key) = try keyring.create(name: "Alice")
        let stored = String(decoding: try XCTUnwrap(box.records), as: UTF8.self)
        XCTAssertFalse(stored.contains(key.value))
        XCTAssertTrue(stored.contains("Alice"))
    }
}

private final class KeyringBox: @unchecked Sendable {
    private let lock = NSLock()
    var secrets: [String: String] = [:]
    var records: Data?
    var failingAccounts: Set<String> = []
    private(set) var reads = 0
    private(set) var writes = 0

    struct Denied: Error {}

    func keyring() -> LocalAPIKeyring {
        LocalAPIKeyring(
            readSecret: { account in try self.withLock {
                self.reads += 1
                if self.failingAccounts.contains(account) { throw Denied() }
                return self.secrets[account]
            } },
            writeSecret: { value, account in self.withLock { self.writes += 1; self.secrets[account] = value } },
            deleteSecret: { account in self.withLock { self.secrets[account] = nil } },
            loadRecords: { self.withLock { self.records } },
            saveRecords: { data in self.withLock { self.records = data } }
        )
    }

    private func withLock<T>(_ body: () throws -> T) rethrows -> T {
        lock.lock()
        defer { lock.unlock() }
        return try body()
    }
}
