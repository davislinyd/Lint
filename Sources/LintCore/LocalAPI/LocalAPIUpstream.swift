import Foundation

/// One request from Lint's API port to llama-server, read as it arrives, so a streamed answer can be
/// passed on chunk by chunk. Cancelling it closes the connection, and llama-server then stops
/// generating (measured on b11046, streamed or not).
final class LocalAPIUpstream: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    enum Event: Sendable {
        case response(HTTPURLResponse)
        case data(Data)
    }

    let events: AsyncThrowingStream<Event, Error>
    private let continuation: AsyncThrowingStream<Event, Error>.Continuation
    private let request: URLRequest
    private let lock = NSLock()
    private var task: URLSessionDataTask?
    private var cancelled = false

    init(request: URLRequest) {
        (events, continuation) = AsyncThrowingStream.makeStream(of: Event.self)
        self.request = request
        super.init()
    }

    func start() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.urlCache = nil
        configuration.httpShouldSetCookies = false
        configuration.connectionProxyDictionary = [:]
        let session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
        let task = session.dataTask(with: request)
        let startNow = lock.withLock {
            self.task = task
            return !cancelled
        }
        if startNow {
            task.resume()
            session.finishTasksAndInvalidate()
        } else {
            session.invalidateAndCancel()
            continuation.finish(throwing: CancellationError())
        }
    }

    func cancel() {
        let task = lock.withLock {
            cancelled = true
            return self.task
        }
        task?.cancel()
        if task == nil { continuation.finish(throwing: CancellationError()) }
    }

    func urlSession(
        _ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
        completionHandler: @escaping @Sendable (URLSession.ResponseDisposition) -> Void
    ) {
        if let http = response as? HTTPURLResponse { continuation.yield(.response(http)) }
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        continuation.yield(.data(data))
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?) {
        if let error { continuation.finish(throwing: error) } else { continuation.finish() }
    }
}
