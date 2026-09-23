import CryptoKit
import Foundation

public enum LocalModelStatus: Equatable, Sendable {
    case notInstalled
    /// Complete and checked; `primaryFile` is what `llama-server -m` gets.
    case installed(primaryFile: URL)
    /// Something is in the model's folder but it is not a usable model (missing shard, wrong size, not GGUF).
    case invalid(String)
}

public enum GGUFFile {
    /// Every GGUF file starts with the ASCII bytes "GGUF".
    public static func hasMagic(at url: URL) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? handle.close() }
        return (try? handle.read(upToCount: 4)) == Data("GGUF".utf8)
    }
}

public enum FileDigest {
    /// Streams the file through SHA-256 (multi-gigabyte files never sit in memory) and stops promptly
    /// if the surrounding task is cancelled.
    public static func sha256(of url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while true {
            try Task.checkCancellation()
            guard let chunk = try handle.read(upToCount: 4 * 1024 * 1024), !chunk.isEmpty else { break }
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

func fileSize(at url: URL) -> Int64? {
    guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
          let size = attributes[.size] as? NSNumber
    else { return nil }
    return size.int64Value
}

/// What is installed under `Application Support/Lint/Models`, and removing it. It never downloads
/// anything (see `ModelDownloadManager`), and an unfinished download is never reported as installed.
public struct LocalModelManager: Sendable {
    public let paths: LocalAIPaths

    public init(paths: LocalAIPaths = .standard()) {
        self.paths = paths
    }

    public func status(of model: ModelDescriptor) -> LocalModelStatus {
        let directory = paths.installDirectory(for: model)
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: directory.path, isDirectory: &isDirectory) else {
            return .notInstalled
        }
        guard isDirectory.boolValue else { return .invalid("\(model.id) is not a folder") }
        for file in model.files {
            guard file.hasSafeFileName else { return .invalid("unsafe file name \(file.fileName)") }
            let url = directory.appendingPathComponent(file.fileName)
            guard let size = fileSize(at: url) else { return .invalid("\(file.fileName) is missing") }
            if let expected = file.sizeBytes, size != expected {
                return .invalid("\(file.fileName) is \(size) bytes, expected \(expected)")
            }
            guard GGUFFile.hasMagic(at: url) else { return .invalid("\(file.fileName) is not a GGUF file") }
        }
        return .installed(primaryFile: directory.appendingPathComponent(model.primaryFile.fileName))
    }

    /// Bytes already downloaded for `model` and waiting to be finished or installed.
    public func partialDownloadBytes(of model: ModelDescriptor) -> Int64 {
        let directory = paths.stagingDirectory(for: model)
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: directory.path) else { return 0 }
        return names.reduce(0) { $0 + (fileSize(at: directory.appendingPathComponent($1)) ?? 0) }
    }

    /// Anything of `model` on disk: installed, damaged, or partly downloaded.
    public func hasLocalCopy(of model: ModelDescriptor) -> Bool {
        if case .notInstalled = status(of: model) { return partialDownloadBytes(of: model) > 0 }
        return true
    }

    /// Deletes the installed model and any unfinished download of it.
    public func remove(_ model: ModelDescriptor) throws {
        for directory in [paths.installDirectory(for: model), paths.stagingDirectory(for: model)]
        where FileManager.default.fileExists(atPath: directory.path) {
            try FileManager.default.removeItem(at: directory)
        }
    }
}

/// The Hugging Face hub cache that `llama-server -hf` (and the `huggingface-cli`) fill.
public enum HuggingFaceCache {
    public static func hubDirectory(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        home: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> URL {
        if let path = environment["HF_HUB_CACHE"], !path.isEmpty { return URL(fileURLWithPath: path) }
        if let path = environment["HF_HOME"], !path.isEmpty {
            return URL(fileURLWithPath: path).appendingPathComponent("hub")
        }
        return home.appendingPathComponent(".cache/huggingface/hub")
    }

    /// The model's own folder in the cache once downloaded, otherwise the cache root; nil if neither exists.
    public static func modelFolder(spec: String, hub: URL = hubDirectory()) -> URL? {
        let repository = spec.split(separator: ":").first.map(String.init) ?? spec
        let model = hub.appendingPathComponent("models--" + repository.replacingOccurrences(of: "/", with: "--"))
        for url in [model, hub] where FileManager.default.fileExists(atPath: url.path) {
            return url
        }
        return nil
    }

    /// True when every file of `model` is in the cache at its expected size, so an existing
    /// `-hf` setup keeps working without downloading the model a second time.
    public static func containsCompleteCopy(of model: ModelDescriptor, hub: URL = hubDirectory()) -> Bool {
        let snapshots = hub
            .appendingPathComponent("models--" + model.repository.replacingOccurrences(of: "/", with: "--"))
            .appendingPathComponent("snapshots")
        guard let revisions = try? FileManager.default.contentsOfDirectory(atPath: snapshots.path) else { return false }
        return revisions.contains { revision in
            model.files.allSatisfy { file in
                guard file.hasSafeFileName else { return false }
                let url = snapshots.appendingPathComponent(revision).appendingPathComponent(file.fileName)
                    .resolvingSymlinksInPath()
                guard let size = fileSize(at: url) else { return false }
                return file.sizeBytes.map { $0 == size } ?? true
            }
        }
    }
}
