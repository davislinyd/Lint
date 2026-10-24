import CryptoKit
import Foundation

/// A secret that opens the local model: Lint's own key for llama-server, or the key other apps
/// give Lint's API port. 32 random bytes in base64url (43 characters).
///
/// Printing one never shows it, so a key that ends up in a log line or an error by mistake does not leak.
public struct LocalAPIKey: Sendable, CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    public let value: String

    public init(value: String) {
        self.value = value
    }

    public static func generate() -> LocalAPIKey {
        let bytes = SymmetricKey(size: .bits256).withUnsafeBytes { Data($0) }
        let base64URL = bytes.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        return LocalAPIKey(value: base64URL)
    }

    /// Whether `candidate` is this key, in time that does not depend on where they first differ.
    public func matches<S: StringProtocol>(_ candidate: S) -> Bool {
        let expected = SHA256.hash(data: Data(value.utf8))
        let given = SHA256.hash(data: Data(candidate.utf8))
        var difference: UInt8 = 0
        for (a, b) in zip(expected, given) { difference |= a ^ b }
        return difference == 0
    }

    var isWellFormed: Bool {
        value.count == 43 && value.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") }
    }

    public var description: String { "LocalAPIKey(redacted)" }
    public var debugDescription: String { description }
    public var customMirror: Mirror { Mirror(self, children: [:]) }
}

/// One of the keys other apps use, as Settings lists it. None of this is secret: the key itself is
/// in the Keychain under `account`.
public struct LocalAPIKeyRecord: Codable, Equatable, Identifiable, Sendable {
    public var id: String
    /// What the user called it, such as the app or page it was given to.
    public var name: String
    /// nil for the key from before there could be several.
    public var created: Date?
    public var account: String

    /// What the diagnostic log shows of a key: enough to tell keys apart, nothing the user wrote.
    public var shortID: String { String(id.prefix(6)) }
}

/// The keys other apps use: a list of named keys, each kept in the Keychain and read once.
///
/// Before there could be several keys there was one, under `legacyAccount`. Without a stored list,
/// that one is the list, so it keeps working; it is made the first time it is needed (the feature is
/// off by default, so most installs never touch the Keychain).
///
/// A read can block while macOS asks the user whether Lint may use an item (a build signed
/// differently, an item someone else created), so it is never done on the main thread, and a read
/// that failed is not tried again for that key: otherwise every request would raise the same prompt.
public final class LocalAPIKeyring: @unchecked Sendable {
    public static let legacyAccount = "localAPI.userKey"
    public static let recordsDefaultsKey = "app.lint.localAPI.keys"
    public static let maxKeys = 50
    public static let maxNameLength = 40

    /// The keys a request may present, and whether any key could not be read.
    public struct Lookup: Sendable {
        public struct Entry: Sendable {
            public var id: String
            public var key: LocalAPIKey

            public var shortID: String { String(id.prefix(6)) }
        }

        public var keys: [Entry]
        public var unreadable: Bool
    }

    public enum KeyringError: Error, Equatable {
        case invalidName
        case tooManyKeys
    }

    private let readSecret: @Sendable (String) throws -> String?
    private let writeSecret: @Sendable (String, String) throws -> Void
    private let deleteSecret: @Sendable (String) throws -> Void
    private let loadRecords: @Sendable () -> Data?
    private let saveRecords: @Sendable (Data) -> Void
    private let lock = NSLock()
    private var cachedRecords: [LocalAPIKeyRecord]?
    private var cachedKeys: [String: LocalAPIKey] = [:]
    private var unreadableIDs: Set<String> = []

    public convenience init(keychain: KeychainStore = KeychainStore()) {
        self.init(
            readSecret: { try keychain.get(account: $0) },
            writeSecret: { try keychain.set($0, account: $1) },
            deleteSecret: { try keychain.delete(account: $0) },
            loadRecords: { UserDefaults.standard.data(forKey: LocalAPIKeyring.recordsDefaultsKey) },
            saveRecords: { UserDefaults.standard.set($0, forKey: LocalAPIKeyring.recordsDefaultsKey) }
        )
    }

    init(
        readSecret: @escaping @Sendable (String) throws -> String?,
        writeSecret: @escaping @Sendable (_ value: String, _ account: String) throws -> Void,
        deleteSecret: @escaping @Sendable (String) throws -> Void,
        loadRecords: @escaping @Sendable () -> Data?,
        saveRecords: @escaping @Sendable (Data) -> Void
    ) {
        self.readSecret = readSecret
        self.writeSecret = writeSecret
        self.deleteSecret = deleteSecret
        self.loadRecords = loadRecords
        self.saveRecords = saveRecords
    }

    public func records() -> [LocalAPIKeyRecord] {
        lock.withLock { recordsLocked() }
    }

    /// Every key that can be read, each read from the Keychain (or made, if it is missing) the first time.
    public func lookup() -> Lookup {
        lock.withLock {
            var lookup = Lookup(keys: [], unreadable: false)
            for record in recordsLocked() {
                if let key = keyLocked(for: record) {
                    lookup.keys.append(Lookup.Entry(id: record.id, key: key))
                } else {
                    lookup.unreadable = true
                }
            }
            return lookup
        }
    }

    /// A new key, kept in the Keychain before it is listed.
    @discardableResult
    public func create(name: String) throws -> (LocalAPIKeyRecord, LocalAPIKey) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= Self.maxNameLength else { throw KeyringError.invalidName }
        return try lock.withLock {
            var records = recordsLocked()
            guard records.count < Self.maxKeys else { throw KeyringError.tooManyKeys }
            let id = UUID().uuidString.lowercased()
            let record = LocalAPIKeyRecord(id: id, name: trimmed, created: Date(), account: "localAPI.key.\(id)")
            let key = LocalAPIKey.generate()
            try writeSecret(key.value, record.account)
            records.append(record)
            storeLocked(records)
            cachedKeys[id] = key
            return (record, key)
        }
    }

    /// Stops a key working at once (requests already let in finish) and deletes it from the Keychain.
    public func revoke(id: String) {
        lock.withLock {
            var records = recordsLocked()
            guard let index = records.firstIndex(where: { $0.id == id }) else { return }
            let record = records.remove(at: index)
            storeLocked(records)
            cachedKeys[id] = nil
            unreadableIDs.remove(id)
            // A secret that could not be deleted is no longer listed, so nothing accepts it.
            try? deleteSecret(record.account)
        }
    }

    private func recordsLocked() -> [LocalAPIKeyRecord] {
        if let cachedRecords { return cachedRecords }
        let stored = loadRecords().flatMap { try? JSONDecoder().decode([LocalAPIKeyRecord].self, from: $0) }
        let records = stored ?? [LocalAPIKeyRecord(
            id: "legacy", name: String(localized: "預設"), created: nil, account: Self.legacyAccount
        )]
        cachedRecords = records
        return records
    }

    private func storeLocked(_ records: [LocalAPIKeyRecord]) {
        cachedRecords = records
        if let data = try? JSONEncoder().encode(records) { saveRecords(data) }
    }

    private func keyLocked(for record: LocalAPIKeyRecord) -> LocalAPIKey? {
        if let key = cachedKeys[record.id] { return key }
        if unreadableIDs.contains(record.id) { return nil }
        do {
            if let stored = try readSecret(record.account).map(LocalAPIKey.init(value:)), stored.isWellFormed {
                cachedKeys[record.id] = stored
                return stored
            }
            let key = LocalAPIKey.generate()
            try writeSecret(key.value, record.account)
            cachedKeys[record.id] = key
            return key
        } catch {
            unreadableIDs.insert(record.id)
            return nil
        }
    }
}
