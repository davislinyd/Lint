import Foundation
import Security

/// Whether a file carries a valid code signature (integrity, not identity).
public protocol CodeSignatureChecking: Sendable {
    func hasValidSignature(at url: URL) -> Bool
}

/// The real check: `SecStaticCodeCheckValidity` across all architectures, strictly (the same as
/// `codesign --verify --strict`, which also rejects bytes appended after the signed range). A
/// truncated or altered dylib fails it, which lets Lint say "damaged runtime" instead of a
/// mysterious dyld exit.
///
/// Validating the whole runtime hashes about 24 MB and takes ~0.1 s, and the settings and setup
/// screens ask again and again, so a result is remembered for as long as the file is unchanged
/// (same path, size, modification time and inode). Any change to the file is checked afresh.
public struct SecurityFrameworkSignatureChecker: CodeSignatureChecking {
    private static let cache = SignatureResultCache()

    public init() {}

    public func hasValidSignature(at url: URL) -> Bool {
        let identity = FileIdentity(url)
        if let identity, let known = Self.cache.result(for: identity) { return known }
        let result = Self.validate(url)
        if let identity { Self.cache.store(result, for: identity) }
        return result
    }

    private static func validate(_ url: URL) -> Bool {
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(url as CFURL, [], &code) == errSecSuccess, let code else { return false }
        let flags = SecCSFlags(rawValue: kSecCSCheckAllArchitectures | kSecCSStrictValidate)
        return SecStaticCodeCheckValidityWithErrors(code, flags, nil, nil) == errSecSuccess
    }
}

private struct FileIdentity: Hashable {
    let path: String
    let size: Int64
    let modified: TimeInterval
    let inode: UInt64

    init?(_ url: URL) {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = (attributes[.size] as? NSNumber)?.int64Value,
              let modified = (attributes[.modificationDate] as? Date)?.timeIntervalSince1970,
              let inode = (attributes[.systemFileNumber] as? NSNumber)?.uint64Value
        else { return nil }
        self.path = url.path
        self.size = size
        self.modified = modified
        self.inode = inode
    }
}

private final class SignatureResultCache: @unchecked Sendable {
    private let lock = NSLock()
    private var results: [FileIdentity: Bool] = [:]

    func result(for identity: FileIdentity) -> Bool? { lock.withLock { results[identity] } }
    func store(_ result: Bool, for identity: FileIdentity) { lock.withLock { results[identity] = result } }
}

/// For tests, where the fixtures are not real signed binaries.
public struct AcceptAnySignature: CodeSignatureChecking {
    public init() {}
    public func hasValidSignature(at url: URL) -> Bool { true }
}

public enum LlamaRuntimeVerificationError: Error, Equatable, Sendable {
    case directoryMissing
    case infoMissing
    case infoUnreadable
    case unsupportedSchema(Int)
    case architectureMismatch(expected: CPUArchitecture, found: CPUArchitecture)
    case unexpectedFileName(String)
    case fileMissing(String)
    case notExecutable(String)
    case notMachO(String)
    case wrongFileArchitecture(file: String, expected: CPUArchitecture)
    case invalidSignature(String)

    /// English, for logs and diagnostics. Users see `LlamaRuntimeStatus.userMessage` instead.
    public var reason: String {
        switch self {
        case .directoryMissing: "the runtime directory is missing"
        case .infoMissing: "runtime-info.json is missing"
        case .infoUnreadable: "runtime-info.json cannot be read"
        case .unsupportedSchema(let v): "runtime-info.json schema \(v) is not supported"
        case .architectureMismatch(let expected, let found):
            "the runtime is built for \(found.rawValue) but this Lint is \(expected.rawValue)"
        case .unexpectedFileName(let name): "runtime-info.json lists an unexpected file name '\(name)'"
        case .fileMissing(let name): "\(name) is missing"
        case .notExecutable(let name): "\(name) is not executable"
        case .notMachO(let name): "\(name) is not a Mach-O file"
        case .wrongFileArchitecture(let file, let expected): "\(file) is not a \(expected.rawValue) binary"
        case .invalidSignature(let name): "the code signature of \(name) is invalid"
        }
    }
}

/// Checks that a bundled runtime directory is complete and matches the running Lint, without
/// executing anything in it.
public struct LlamaRuntimeVerifier: Sendable {
    private let signatureChecker: any CodeSignatureChecking

    public init(signatureChecker: any CodeSignatureChecking = SecurityFrameworkSignatureChecker()) {
        self.signatureChecker = signatureChecker
    }

    public func verify(
        directory: URL,
        expected architecture: CPUArchitecture
    ) -> Result<LlamaRuntimeInfo, LlamaRuntimeVerificationError> {
        let fileManager = FileManager.default
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: directory.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            return .failure(.directoryMissing)
        }
        let infoURL = directory.appendingPathComponent(LlamaRuntimeInfo.fileName)
        guard fileManager.fileExists(atPath: infoURL.path) else { return .failure(.infoMissing) }
        guard let data = try? Data(contentsOf: infoURL),
              let info = try? JSONDecoder().decode(LlamaRuntimeInfo.self, from: data)
        else { return .failure(.infoUnreadable) }
        guard info.schemaVersion == LlamaRuntimeInfo.supportedSchemaVersion else {
            return .failure(.unsupportedSchema(info.schemaVersion))
        }
        guard info.architecture == architecture else {
            return .failure(.architectureMismatch(expected: architecture, found: info.architecture))
        }

        // The binary is always checked, even if `files` forgot to list it.
        var names = info.files
        if !names.contains(info.binary) { names.append(info.binary) }
        for name in names {
            // Names come from a bundled file; keep them plain so they cannot point elsewhere.
            guard !name.isEmpty, !name.contains("/"), name != ".", name != ".." else {
                return .failure(.unexpectedFileName(name))
            }
            let url = directory.appendingPathComponent(name)
            guard fileManager.fileExists(atPath: url.path) else { return .failure(.fileMissing(name)) }
            guard let found = MachOInspector.architectures(of: url) else { return .failure(.notMachO(name)) }
            guard found == [architecture] else {
                return .failure(.wrongFileArchitecture(file: name, expected: architecture))
            }
            guard signatureChecker.hasValidSignature(at: url) else { return .failure(.invalidSignature(name)) }
        }
        guard fileManager.isExecutableFile(atPath: directory.appendingPathComponent(info.binary).path) else {
            return .failure(.notExecutable(info.binary))
        }
        return .success(info)
    }
}
