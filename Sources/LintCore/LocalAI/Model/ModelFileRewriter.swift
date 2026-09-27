import CryptoKit
import Darwin
import Foundation

public enum ModelFileRewriteError: Error, Equatable {
    case notEnoughSpace(needed: Int64, available: Int64)
    case sizeMismatch(file: String)
    case checksumMismatch(file: String)
}

/// Rewrites an installed model's files in one sequential pass, once per file.
///
/// A download appends each network chunk as it arrives, for minutes, so APFS scatters the file.
/// Measured on a 16 GB M1 Pro: Gemma 4 E4B as downloaded was in about 300,000 extents and read from
/// disk at 440 MB/s; the same bytes written in one pass read at 3.4 GB/s, and llama-server loaded
/// them from disk in 4 s instead of 14 s.
public struct ModelFileRewriter: Sendable {
    /// Set on a file this wrote, so it is never rewritten again.
    static let attribute = "app.lint.rewritten"
    private static let chunkBytes = 16 * 1024 * 1024

    private let diskSpace: any DiskSpaceProviding

    public init(diskSpace: any DiskSpaceProviding = SystemDiskSpaceProvider()) {
        self.diskSpace = diskSpace
    }

    /// Rewrites each installed file of `model` that has not been rewritten yet. A file is replaced
    /// only by a complete copy whose SHA-256 matches the catalog; on any failure the original stays
    /// as it was, and the next call tries again.
    public func rewriteIfNeeded(_ model: ModelDescriptor, in paths: LocalAIPaths) throws {
        let directory = paths.installDirectory(for: model)
        for file in model.files where file.hasSafeFileName {
            let url = directory.appendingPathComponent(file.fileName)
            guard FileManager.default.fileExists(atPath: url.path), !Self.isRewritten(url) else { continue }
            try rewrite(url, sha256: file.sha256)
        }
    }

    static func isRewritten(_ url: URL) -> Bool {
        getxattr(url.path, attribute, nil, 0, 0, 0) >= 0
    }

    private func rewrite(_ url: URL, sha256: String?) throws {
        let temporary = url.deletingLastPathComponent().appendingPathComponent("." + url.lastPathComponent + ".rewrite")
        try? FileManager.default.removeItem(at: temporary) // left by an interrupted rewrite
        let size = fileSize(at: url) ?? 0
        let available = try diskSpace.availableBytes(at: url)
        guard available > size else { throw ModelFileRewriteError.notEnoughSpace(needed: size, available: available) }

        do {
            guard FileManager.default.createFile(atPath: temporary.path, contents: nil) else {
                throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: temporary.path])
            }
            let input = try FileHandle(forReadingFrom: url)
            defer { try? input.close() }
            let output = try FileHandle(forWritingTo: temporary)
            defer { try? output.close() }
            // Neither copy is worth keeping in the page cache: llama-server maps the file itself.
            _ = fcntl(input.fileDescriptor, F_NOCACHE, 1)
            _ = fcntl(output.fileDescriptor, F_NOCACHE, 1)

            var hasher = SHA256()
            var written: Int64 = 0
            while let chunk = try input.read(upToCount: Self.chunkBytes), !chunk.isEmpty {
                hasher.update(data: chunk)
                try output.write(contentsOf: chunk)
                written += Int64(chunk.count)
            }
            try output.synchronize()
            guard written == size else { throw ModelFileRewriteError.sizeMismatch(file: url.lastPathComponent) }
            if let sha256 {
                let digest = hasher.finalize().map { String(format: "%02x", $0) }.joined()
                guard digest == sha256.lowercased() else {
                    throw ModelFileRewriteError.checksumMismatch(file: url.lastPathComponent)
                }
            }
            guard setxattr(temporary.path, Self.attribute, "1", 1, 0, 0) == 0,
                  Darwin.rename(temporary.path, url.path) == 0
            else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        } catch {
            try? FileManager.default.removeItem(at: temporary)
            throw error
        }
    }
}
