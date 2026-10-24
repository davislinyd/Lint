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

/// The key other apps use, kept in the Keychain. It is made the first time it is needed (the
/// feature is off by default, so most installs never touch this item) and read once.
///
/// A read can block while macOS asks the user whether Lint may use the item (a build signed
/// differently, an item someone else created), so it is never done on the main thread, and a
/// read that failed is not tried again until the user regenerates the key: otherwise every request,
/// or every second, would raise the same prompt.
public final class LocalAPIKeyStore: @unchecked Sendable {
    public static let keychainAccount = "localAPI.userKey"

    private let read: @Sendable () throws -> String?
    private let write: @Sendable (String) throws -> Void
    private let lock = NSLock()
    private var cached: LocalAPIKey?
    private var failure: (any Error)?

    public convenience init(keychain: KeychainStore = KeychainStore()) {
        self.init(
            read: { try keychain.get(account: LocalAPIKeyStore.keychainAccount) },
            write: { try keychain.set($0, account: LocalAPIKeyStore.keychainAccount) }
        )
    }

    init(read: @escaping @Sendable () throws -> String?, write: @escaping @Sendable (String) throws -> Void) {
        self.read = read
        self.write = write
    }

    public func current() throws -> LocalAPIKey {
        lock.lock()
        defer { lock.unlock() }
        if let cached { return cached }
        if let failure { throw failure }
        do {
            if let stored = try read().map(LocalAPIKey.init(value:)), stored.isWellFormed {
                cached = stored
                return stored
            }
            return try storeNewKey()
        } catch {
            failure = error
            throw error
        }
    }

    /// A new key; the old one stops working at once. Also the way out after a failed read.
    @discardableResult
    public func regenerate() throws -> LocalAPIKey {
        lock.lock()
        defer { lock.unlock() }
        failure = nil
        return try storeNewKey()
    }

    private func storeNewKey() throws -> LocalAPIKey {
        let key = LocalAPIKey.generate()
        try write(key.value)
        cached = key
        return key
    }
}
