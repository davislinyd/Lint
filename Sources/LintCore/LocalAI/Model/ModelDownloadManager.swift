import Foundation

/// Installs a catalog model into `Application Support/Lint/Models`, safely:
///
///     download → `Downloads/<id>/<file>.partial`
///              → check size, GGUF header and SHA-256 → rename to `Downloads/<id>/<file>`
///              → all files verified → move the folder to `Models/<id>` in one step
///
/// A file is only ever at its final name after it passed every check, and `Models/<id>` only
/// appears when the whole model is complete, so an interrupted or corrupt download can never be
/// mistaken for an installed model. Cancelling or failing keeps the partial data so a retry can
/// resume, except for a file that failed verification, which is deleted.
///
/// Downloads are always started by the user; nothing here runs on its own.
public actor ModelDownloadManager {
    private let paths: LocalAIPaths
    private let transport: any ModelFileTransport
    private let diskSpace: any DiskSpaceProviding
    private let safetyFactor: Double
    private var installing = false

    /// - Parameter safetyFactor: free space required beyond what is still to be downloaded (1.2 = 20% headroom).
    public init(
        paths: LocalAIPaths = .standard(),
        transport: any ModelFileTransport = URLSessionModelTransport(),
        diskSpace: any DiskSpaceProviding = SystemDiskSpaceProvider(),
        safetyFactor: Double = 1.2
    ) {
        self.paths = paths
        self.transport = transport
        self.diskSpace = diskSpace
        self.safetyFactor = safetyFactor
    }

    /// Runs until the model is installed, fails, or the calling task is cancelled, reporting each step
    /// to `onState`. Returns the final state; it never throws.
    @discardableResult
    public func install(
        _ model: ModelDescriptor,
        onState: @escaping @Sendable (ModelDownloadState) -> Void = { _ in }
    ) async -> ModelDownloadState {
        guard !installing else { return .downloading(bytesReceived: 0, totalBytes: model.totalBytes) }
        installing = true
        defer { installing = false }

        func finish(_ state: ModelDownloadState) -> ModelDownloadState {
            onState(state)
            return state
        }
        do {
            onState(.checking)
            if case .installed = LocalModelManager(paths: paths).status(of: model) { return finish(.installed) }
            for file in model.files where !file.hasSafeFileName {
                throw ModelInstallError.unsafeFileName(file.fileName)
            }
            let staging = paths.stagingDirectory(for: model)
            try createDirectory(paths.modelsDirectory)
            try createDirectory(staging)
            try checkDiskSpace(model, staging: staging)

            for file in model.files {
                try Task.checkCancellation()
                // Everything of the other files that is already on disk counts as progress from the start,
                // so a later shard that is already complete does not make the bar jump at the end.
                let baseline = model.files.filter { $0 != file }.reduce(Int64(0)) { $0 + presentBytes($1, staging: staging) }
                try await fetch(file, staging: staging, baseline: baseline, total: model.totalBytes, onState: onState)
            }

            onState(.installing)
            try Task.checkCancellation()
            try moveIntoPlace(model, staging: staging)
            guard case .installed = LocalModelManager(paths: paths).status(of: model) else {
                throw ModelInstallError.filesystem("the installed model did not pass the final check")
            }
            return finish(.installed)
        } catch is CancellationError {
            return finish(.cancelled)
        } catch let error as ModelInstallError {
            return finish(.failed(error))
        } catch {
            return finish(.failed(.filesystem(error.localizedDescription)))
        }
    }

    // MARK: - Steps

    /// Free space needed for what is still missing, plus headroom; checked before any byte is downloaded.
    private func checkDiskSpace(_ model: ModelDescriptor, staging: URL) throws {
        var remaining: Int64 = 0
        var anySize = false
        for file in model.files {
            guard let size = file.sizeBytes else { continue }
            anySize = true
            let have = fileSize(at: staging.appendingPathComponent(file.fileName))
                ?? fileSize(at: partialURL(file, staging: staging)) ?? 0
            remaining += max(0, size - have)
        }
        guard anySize else { return } // nothing to base a check on; a full disk still surfaces as a write error
        let required = Int64((Double(remaining) * safetyFactor).rounded(.up))
        let available: Int64
        do {
            available = try diskSpace.availableBytes(at: staging)
        } catch {
            return // cannot tell; do not block the install on it
        }
        if available < required {
            throw ModelInstallError.insufficientDiskSpace(requiredBytes: required, availableBytes: available)
        }
    }

    /// Bytes of `file` already in `staging`: the verified file, or else what a partial download holds.
    private func presentBytes(_ file: ModelFile, staging: URL) -> Int64 {
        let bytes = fileSize(at: staging.appendingPathComponent(file.fileName))
            ?? fileSize(at: partialURL(file, staging: staging)) ?? 0
        return file.sizeBytes.map { min(bytes, $0) } ?? bytes
    }

    /// Makes `file` present and verified at its final name inside `staging`. `baseline` is what the other
    /// files already contribute to the progress that is reported.
    private func fetch(
        _ file: ModelFile, staging: URL, baseline: Int64, total: Int64?,
        onState: @escaping @Sendable (ModelDownloadState) -> Void
    ) async throws {
        let final = staging.appendingPathComponent(file.fileName)
        let partial = partialURL(file, staging: staging)

        // Verified by an earlier attempt that stopped before the final move: check again, never trust.
        if fileSize(at: final) != nil {
            onState(.verifying)
            do {
                try verify(final, file)
                return
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                try? FileManager.default.removeItem(at: final)
            }
        }

        var have = fileSize(at: partial) ?? 0
        if let expected = file.sizeBytes, have > expected {
            try? FileManager.default.removeItem(at: partial)
            have = 0
        }
        if have == 0 || have != file.sizeBytes {
            onState(.downloading(bytesReceived: baseline + have, totalBytes: total))
            try await transport.download(from: file.url, to: partial, expectedSize: file.sizeBytes) { received in
                onState(.downloading(bytesReceived: baseline + received, totalBytes: total))
            }
        }

        try Task.checkCancellation()
        onState(.verifying)
        do {
            try verify(partial, file)
        } catch let error as ModelInstallError {
            try? FileManager.default.removeItem(at: partial) // never keep, or reuse, a file that failed a check
            throw error
        }
        try FileManager.default.moveItem(at: partial, to: final)
    }

    private func verify(_ url: URL, _ file: ModelFile) throws {
        let actual = fileSize(at: url) ?? 0
        if let expected = file.sizeBytes, actual != expected {
            throw ModelInstallError.sizeMismatch(file: file.fileName, expected: expected, actual: actual)
        }
        guard GGUFFile.hasMagic(at: url) else { throw ModelInstallError.notAGGUFFile(file: file.fileName) }
        if let expected = file.sha256 {
            let digest = try FileDigest.sha256(of: url)
            guard digest == expected.lowercased() else { throw ModelInstallError.checksumMismatch(file: file.fileName) }
        }
    }

    /// The last step, and the only one that makes a model visible: a single directory rename.
    private func moveIntoPlace(_ model: ModelDescriptor, staging: URL) throws {
        let fileManager = FileManager.default
        let wanted = Set(model.files.map(\.fileName))
        for name in (try? fileManager.contentsOfDirectory(atPath: staging.path)) ?? [] where !wanted.contains(name) {
            try? fileManager.removeItem(at: staging.appendingPathComponent(name)) // stray leftovers
        }
        let destination = paths.installDirectory(for: model)
        // Only an invalid leftover can be here: a valid install returned before downloading anything.
        if fileManager.fileExists(atPath: destination.path) { try fileManager.removeItem(at: destination) }
        try fileManager.moveItem(at: staging, to: destination)
    }

    private func partialURL(_ file: ModelFile, staging: URL) -> URL {
        staging.appendingPathComponent(file.fileName + ".partial")
    }

    private func createDirectory(_ url: URL) throws {
        do {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        } catch {
            throw ModelInstallError.filesystem(error.localizedDescription)
        }
    }
}
