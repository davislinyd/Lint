import Foundation

enum HTTPStream {
    static func ssePayloads(
        session: URLSession,
        request: URLRequest
    ) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let (bytes, response) = try await session.bytes(for: request)
                    if let http = response as? HTTPURLResponse, http.statusCode >= 400 {
                        var body = ""
                        for try await line in bytes.lines {
                            body.append(line)
                            if body.count > 2000 { break }
                        }
                        throw LLMError.httpStatus(http.statusCode, body)
                    }
                    for try await line in bytes.lines {
                        if Task.isCancelled { break }
                        if let payload = SSEParser.payload(fromLine: line) {
                            if payload == "[DONE]" { break }
                            continuation.yield(payload)
                        }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}
