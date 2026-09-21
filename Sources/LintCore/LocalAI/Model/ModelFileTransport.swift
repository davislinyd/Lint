import Foundation

/// Fetches one file over the network into a partial file. Kept behind a protocol so the install
/// logic is tested without a network.
public protocol ModelFileTransport: Sendable {
    /// Downloads `url` into `partialURL`. If `partialURL` already holds the start of the file, the
    /// implementation continues after those bytes when the server supports it, or starts over when
    /// it does not. `progress` receives the number of bytes of this file now on disk.
    ///
    /// On return the whole remote file is at `partialURL`. Throws `CancellationError` when the
    /// calling task is cancelled (the partial file stays), and `ModelInstallError` otherwise.
    func download(
        from url: URL, to partialURL: URL, expectedSize: Int64?, progress: @escaping @Sendable (Int64) -> Void
    ) async throws
}

/// Native URLSession download with HTTP Range resume. No curl, wget, Python or Homebrew involved.
public final class URLSessionModelTransport: ModelFileTransport, Sendable {
    private let makeConfiguration: @Sendable () -> URLSessionConfiguration

    /// `configuration` is only replaced in tests (with a stub URLProtocol).
    public init(configuration: @escaping @Sendable () -> URLSessionConfiguration = URLSessionModelTransport.defaultConfiguration) {
        self.makeConfiguration = configuration
    }

    public static func defaultConfiguration() -> URLSessionConfiguration {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 60 // no bytes for a minute = stalled
        configuration.timeoutIntervalForResource = 60 * 60 * 24
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        return configuration
    }

    public func download(
        from url: URL, to partialURL: URL, expectedSize: Int64?, progress: @escaping @Sendable (Int64) -> Void
    ) async throws {
        var request = URLRequest(url: url)
        // Range arithmetic must be on the raw bytes.
        request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
        let existing = fileSize(at: partialURL) ?? 0
        if existing > 0 { request.setValue("bytes=\(existing)-", forHTTPHeaderField: "Range") }

        let job = DownloadJob(partialURL: partialURL, existing: existing, expectedSize: expectedSize, progress: progress)
        try await withTaskCancellationHandler {
            try await job.run(configuration: makeConfiguration(), request: request)
        } onCancel: {
            job.cancel()
        }
    }
}

/// One download: a data task whose bytes are appended to the partial file as they arrive.
private final class DownloadJob: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let partialURL: URL
    private let existing: Int64
    private let expectedSize: Int64?
    private let progress: @Sendable (Int64) -> Void

    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, Error>?
    private var task: URLSessionDataTask?
    private var session: URLSession?
    private var cancelled = false

    // Touched only on the session's serial delegate queue.
    private var handle: FileHandle?
    private var written: Int64 = 0
    private var failure: Error?
    private var completedEarly = false
    private var lastProgress = Date.distantPast

    init(partialURL: URL, existing: Int64, expectedSize: Int64?, progress: @escaping @Sendable (Int64) -> Void) {
        self.partialURL = partialURL
        self.existing = existing
        self.expectedSize = expectedSize
        self.progress = progress
    }

    func run(configuration: URLSessionConfiguration, request: URLRequest) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            lock.lock()
            if cancelled {
                lock.unlock()
                continuation.resume(throwing: CancellationError())
                return
            }
            self.continuation = continuation
            let session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
            let task = session.dataTask(with: request)
            self.session = session
            self.task = task
            lock.unlock()
            task.resume()
        }
    }

    func cancel() {
        lock.lock()
        cancelled = true
        let task = self.task
        lock.unlock()
        task?.cancel() // before `run` created the task, `run` sees `cancelled` instead
    }

    private func fail(_ error: Error) {
        if failure == nil { failure = error }
        task?.cancel()
    }

    // MARK: URLSessionDataDelegate (serial queue)

    func urlSession(
        _ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
    ) {
        guard let http = response as? HTTPURLResponse else {
            fail(ModelInstallError.network("unexpected response"))
            completionHandler(.cancel)
            return
        }
        do {
            switch http.statusCode {
            case 206:
                // Only accept a continuation that starts exactly where the partial file ends.
                guard existing > 0, Self.rangeStart(of: http) == existing else {
                    throw ModelInstallError.network("the server sent an unexpected range")
                }
                try openHandle(startingOver: false)
                written = existing
            case 200:
                // The whole file: a first attempt, or the server ignored the Range header.
                try openHandle(startingOver: true)
                written = 0
            case 416:
                if let expectedSize, existing == expectedSize {
                    completedEarly = true // already complete
                } else {
                    try? FileManager.default.removeItem(at: partialURL)
                    throw ModelInstallError.httpStatus(416)
                }
                completionHandler(.cancel)
                return
            default:
                throw ModelInstallError.httpStatus(http.statusCode)
            }
            completionHandler(.allow)
        } catch {
            fail(error)
            completionHandler(.cancel)
        }
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        guard failure == nil, let handle else { return }
        do {
            try handle.write(contentsOf: data)
        } catch {
            fail(ModelInstallError.filesystem(error.localizedDescription))
            return
        }
        written += Int64(data.count)
        let now = Date()
        if now.timeIntervalSince(lastProgress) >= 0.1 {
            lastProgress = now
            progress(written)
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        try? handle?.close()
        handle = nil
        let result: Result<Void, Error>
        if let failure {
            result = .failure(failure)
        } else if completedEarly {
            result = .success(())
        } else if let error {
            if (error as? URLError)?.code == .cancelled {
                result = .failure(CancellationError())
            } else {
                result = .failure(ModelInstallError.network(error.localizedDescription))
            }
        } else {
            progress(written)
            result = .success(())
        }
        lock.lock()
        let continuation = self.continuation
        self.continuation = nil
        let session = self.session
        lock.unlock()
        session?.finishTasksAndInvalidate()
        continuation?.resume(with: result)
    }

    private func openHandle(startingOver: Bool) throws {
        let fileManager = FileManager.default
        if !fileManager.fileExists(atPath: partialURL.path) {
            guard fileManager.createFile(atPath: partialURL.path, contents: nil) else {
                throw ModelInstallError.filesystem("cannot create \(partialURL.lastPathComponent)")
            }
        }
        let handle = try FileHandle(forUpdating: partialURL)
        if startingOver {
            try handle.truncate(atOffset: 0)
        } else {
            try handle.seekToEnd()
        }
        self.handle = handle
    }

    /// The first byte of a `Content-Range: bytes 100-999/1000` header.
    private static func rangeStart(of response: HTTPURLResponse) -> Int64? {
        guard let value = response.value(forHTTPHeaderField: "Content-Range"), value.hasPrefix("bytes ") else { return nil }
        let range = value.dropFirst("bytes ".count).split(separator: "/").first ?? ""
        return range.split(separator: "-").first.flatMap { Int64($0) }
    }
}
