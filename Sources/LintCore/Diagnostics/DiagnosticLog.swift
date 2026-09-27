import Foundation

/// What Lint did and how it went, kept on this Mac so a user can look at it or hand it to a developer
/// (Settings → Diagnostics). Never sent anywhere by Lint.
///
/// It holds events, never the user's words: actions, outcomes, error names and codes, character
/// counts, durations, pids, ports, model ids and app names. Never the captured or selected text, a
/// model's answer, a prompt (it holds the memories), the literals a `WritingIssue` carries, a server's
/// reply body, or the description of an error Lint does not know (use `describe(_:)`).
///
/// Bounded by size: when `lint.log` would pass `maxFileBytes` it becomes `lint.1.log` (replacing the
/// older one) and a new `lint.log` starts, so at most two files, about 2 MB, are ever on disk.
public final class DiagnosticLog: @unchecked Sendable {
    /// Writes nothing until the app calls `start(in:)`, so tests never touch the user's log.
    public static let shared = DiagnosticLog(directory: nil)

    /// `~/Library/Logs/Lint`, where Console.app also lists it.
    public static var standardDirectory: URL {
        FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Logs/Lint", isDirectory: true)
    }

    static let currentName = "lint.log"
    static let previousName = "lint.1.log"
    /// Longest message kept; a longer one is cut.
    static let maxMessageLength = 1000

    private let lock = NSLock()
    private var directory: URL?
    private let maxFileBytes: Int
    private let now: @Sendable () -> Date

    public init(directory: URL?, maxFileBytes: Int = 1_000_000, now: @escaping @Sendable () -> Date = Date.init) {
        self.directory = directory
        self.maxFileBytes = max(1, maxFileBytes)
        self.now = now
    }

    public func start(in directory: URL) {
        lock.withLock { self.directory = directory }
    }

    /// The file being written, for "Show in Finder".
    public var currentFileURL: URL? {
        lock.withLock { directory?.appendingPathComponent(Self.currentName) }
    }

    /// One line: local time with offset, `[category]`, the message on a single line.
    public func log(_ category: String, _ message: String) {
        let time = now().formatted(Self.timestamp)
        let data = Data("\(time) [\(category)] \(Self.clean(message))\n".utf8)
        lock.withLock {
            guard let directory else { return }
            append(data, in: directory)
        }
    }

    /// The last `limit` lines of both files, oldest first.
    public func recentLines(_ limit: Int = 1000) -> String {
        lock.withLock {
            guard let directory else { return "" }
            var data = Data()
            for name in [Self.previousName, Self.currentName] {
                if let chunk = try? Data(contentsOf: directory.appendingPathComponent(name)) { data.append(chunk) }
            }
            return String(decoding: data, as: UTF8.self)
                .split(separator: "\n")
                .suffix(max(0, limit))
                .joined(separator: "\n")
        }
    }

    public func clear() {
        lock.withLock {
            guard let directory else { return }
            for name in [Self.previousName, Self.currentName] {
                try? FileManager.default.removeItem(at: directory.appendingPathComponent(name))
            }
        }
    }

    /// Opened and closed for every line, so a file deleted in Finder is simply created again.
    private func append(_ data: Data, in directory: URL) {
        let files = FileManager.default
        let current = directory.appendingPathComponent(Self.currentName)
        if !files.fileExists(atPath: directory.path) {
            try? files.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        }
        let size = (try? files.attributesOfItem(atPath: current.path)[.size] as? NSNumber)?.intValue ?? 0
        if size > 0, size + data.count > maxFileBytes {
            let previous = directory.appendingPathComponent(Self.previousName)
            try? files.removeItem(at: previous)
            // The size limit holds even if the rename fails.
            if (try? files.moveItem(at: current, to: previous)) == nil { try? files.removeItem(at: current) }
        }
        if !files.fileExists(atPath: current.path) {
            files.createFile(atPath: current.path, contents: nil, attributes: [.posixPermissions: 0o600])
        }
        guard let handle = try? FileHandle(forWritingTo: current) else { return }
        defer { try? handle.close() }
        _ = try? handle.seekToEnd()
        try? handle.write(contentsOf: data)
    }

    private static let timestamp = Date.ISO8601FormatStyle(
        timeZoneSeparator: .colon, includingFractionalSeconds: true, timeZone: .current
    )

    /// One line, the home folder as `~`, at most `maxMessageLength` characters.
    static func clean(_ message: String) -> String {
        var text = message.replacingOccurrences(of: NSHomeDirectory() + "/", with: "~/")
        text = text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline).joined(separator: " ⏎ ")
        if text.count > maxMessageLength { text = String(text.prefix(maxMessageLength)) + "…" }
        return text
    }

    /// An error as the log may keep it. A server's reply can echo the user's text and an unknown
    /// error's description can hold anything, so those are reduced to a status code or a domain and code.
    public static func describe(_ error: Error) -> String {
        switch error {
        case is CancellationError:
            return "cancelled"
        case let error as LLMError:
            if case .httpStatus(let code, let body) = error {
                return body.contains("exceed_context_size_error")
                    ? "LLMError.httpStatus(\(code)) exceed_context_size" : "LLMError.httpStatus(\(code))"
            }
            return "LLMError.\(error)"
        case let error as AppleIntelligenceError:
            if case .generationFailed(let diagnostic) = error {
                // The framework's description carries its own context: keep only the error's name.
                return "AppleIntelligenceError.generationFailed(\(diagnostic.prefix { $0 != "(" }))"
            }
            return "AppleIntelligenceError.\(error)"
        case let error as LocalAIError:
            return "LocalAIError.\(error)"
        case let error as ModelInstallError:
            return "ModelInstallError.\(error)"
        case let error as UpdateFailure:
            return "UpdateFailure.\(error.rawValue)"
        case let error as URLError:
            return "URLError(\(error.code.rawValue))"
        default:
            let bridged = error as NSError
            return "\(type(of: error)) (\(bridged.domain) \(bridged.code))"
        }
    }

    /// `macOS 26.0.1 (25A354) · arm64 · Apple M3 Pro · 36 GB`, in English whatever the system language
    /// (`operatingSystemVersionString` is localized).
    public static var systemSummary: String {
        let version = ProcessInfo.processInfo.operatingSystemVersion
        let os = "\(version.majorVersion).\(version.minorVersion).\(version.patchVersion)"
        let memory = ProcessInfo.processInfo.physicalMemory / 1_073_741_824
        return "macOS \(os) (\(sysctlString("kern.osversion"))) · \(CPUArchitecture.current.rawValue) · \(sysctlString("machdep.cpu.brand_string")) · \(memory) GB"
    }

    private static func sysctlString(_ name: String) -> String {
        var size = 0
        sysctlbyname(name, nil, &size, nil, 0)
        var value = [CChar](repeating: 0, count: max(size, 1))
        sysctlbyname(name, &value, &size, nil, 0)
        return String(decoding: value.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }
}

extension GuardedWritingResult.Outcome {
    /// The outcome and the kinds of issue, never what an issue quotes from the text.
    public var diagnosticName: String {
        switch self {
        case .accepted: "accepted"
        case .acceptedAfterRetry(let issues): "acceptedAfterRetry(\(WritingIssue.diagnosticNames(issues)))"
        case .keptSource(let issues): "keptSource(\(WritingIssue.diagnosticNames(issues)))"
        case .flagged(let issues): "flagged(\(WritingIssue.diagnosticNames(issues)))"
        }
    }
}

extension WritingIssue {
    static func diagnosticNames(_ issues: [WritingIssue]) -> String {
        issues.map(\.diagnosticName).joined(separator: ",")
    }

    var diagnosticName: String {
        switch self {
        case .empty: "empty"
        case .leakedReasoning: "leakedReasoning"
        case .missing(let items): "missing×\(items.count)"
        case .languageChanged(let from, let to): "languageChanged(\(from)→\(to))"
        case .excessiveChange(let ratio): "excessiveChange(\(String(format: "%.2f", ratio)))"
        case .structureChanged: "structureChanged"
        case .added(let items): "added×\(items.count)"
        case .leakedInstructions: "leakedInstructions"
        }
    }
}
