import Foundation

/// The small part of HTTP/1.1 Lint's API port speaks: one request per connection, a body only by
/// `Content-Length`, and a closed connection after every response. Anything outside that is refused
/// rather than guessed at, so a malformed or hostile request never reaches llama-server.
enum LocalAPIHTTP {
    static let maxRequestLineBytes = 8 * 1024
    static let maxHeadBytes = 16 * 1024
    static let maxHeaderFields = 100
    static let maxBodyBytes = 4 * 1024 * 1024

    struct Head: Equatable {
        var method: String
        /// The path without the query string.
        var path: String
        var headers: [(name: String, value: String)]

        /// The first value of a header, by name, ignoring case.
        func header(_ name: String) -> String? {
            headers.first { $0.name.caseInsensitiveCompare(name) == .orderedSame }?.value
        }

        func values(_ name: String) -> [String] {
            headers.filter { $0.name.caseInsensitiveCompare(name) == .orderedSame }.map(\.value)
        }

        static func == (lhs: Head, rhs: Head) -> Bool {
            lhs.method == rhs.method && lhs.path == rhs.path
                && lhs.headers.map(\.name) == rhs.headers.map(\.name) && lhs.headers.map(\.value) == rhs.headers.map(\.value)
        }
    }

    /// Why a request is refused before it is routed; each maps to a status and an OpenAI-style error.
    enum Refusal: Error, Equatable {
        case badRequest
        case headTooLarge
        case lengthRequired
        case bodyTooLarge

        var status: Int {
            switch self {
            case .badRequest: 400
            case .headTooLarge: 431
            case .lengthRequired: 411
            case .bodyTooLarge: 413
            }
        }

        var code: String {
            switch self {
            case .badRequest: "bad_request"
            case .headTooLarge: "request_header_fields_too_large"
            case .lengthRequired: "length_required"
            case .bodyTooLarge: "payload_too_large"
            }
        }
    }

    /// The request head at the start of `buffer`, and how many bytes it took, or nil until the blank
    /// line that ends it has arrived.
    static func parseHead(_ buffer: Data) throws(Refusal) -> (head: Head, length: Int)? {
        let end = buffer.firstRange(of: Data("\r\n\r\n".utf8))
        guard let end else {
            if buffer.count > maxHeadBytes { throw .headTooLarge }
            if let firstLine = buffer.firstRange(of: Data("\r\n".utf8)), firstLine.lowerBound > maxRequestLineBytes {
                throw .headTooLarge
            }
            if buffer.firstRange(of: Data("\r\n".utf8)) == nil, buffer.count > maxRequestLineBytes { throw .headTooLarge }
            return nil
        }
        let headBytes = buffer[buffer.startIndex..<end.lowerBound]
        if headBytes.count > maxHeadBytes { throw .headTooLarge }
        // Only printable ASCII, tabs and line breaks belong in a head.
        guard headBytes.allSatisfy({ $0 == 0x09 || $0 == 0x0D || $0 == 0x0A || (0x20...0x7E).contains($0) }),
              let text = String(data: headBytes, encoding: .ascii)
        else { throw .badRequest }

        let lines = text.components(separatedBy: "\r\n")
        guard let requestLine = lines.first else { throw .badRequest }
        if requestLine.utf8.count > maxRequestLineBytes { throw .headTooLarge }
        let parts = requestLine.split(separator: " ", omittingEmptySubsequences: false)
        guard parts.count == 3,
              !parts[0].isEmpty, parts[0].allSatisfy({ $0.isUppercase && $0.isLetter }),
              parts[1].hasPrefix("/"),
              parts[2] == "HTTP/1.1" || parts[2] == "HTTP/1.0"
        else { throw .badRequest }
        let target = String(parts[1])
        let path = String(target.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false).first ?? "")

        var headers: [(name: String, value: String)] = []
        for line in lines.dropFirst() {
            // Obsolete line folding hides one header inside another.
            if line.hasPrefix(" ") || line.hasPrefix("\t") { throw .badRequest }
            guard let colon = line.firstIndex(of: ":") else { throw .badRequest }
            let name = String(line[line.startIndex..<colon])
            guard !name.isEmpty, name.allSatisfy(isTokenCharacter) else { throw .badRequest }
            let value = line[line.index(after: colon)...].trimmingCharacters(in: CharacterSet(charactersIn: " \t"))
            headers.append((name, value))
            if headers.count > maxHeaderFields { throw .headTooLarge }
        }
        return (Head(method: String(parts[0]), path: path, headers: headers), end.upperBound - buffer.startIndex)
    }

    /// How many body bytes follow the head.
    static func bodyLength(of head: Head) throws(Refusal) -> Int {
        let lengths = head.values("Content-Length")
        let encodings = head.values("Transfer-Encoding")
        if !encodings.isEmpty {
            // Both at once is how request smuggling works; a chunked body alone is just unsupported.
            throw lengths.isEmpty ? .lengthRequired : .badRequest
        }
        guard let first = lengths.first else { return 0 }
        guard lengths.allSatisfy({ $0 == first }), !first.isEmpty, first.count <= 12,
              first.allSatisfy({ $0.isASCII && $0.isNumber }), let length = Int(first)
        else { throw .badRequest }
        if length > maxBodyBytes { throw .bodyTooLarge }
        return length
    }

    private static func isTokenCharacter(_ character: Character) -> Bool {
        guard character.isASCII else { return false }
        return character.isLetter || character.isNumber || "!#$%&'*+-.^_`|~".contains(character)
    }

    // MARK: - Writing

    static func responseHead(status: Int, headers: [(String, String)]) -> Data {
        var text = "HTTP/1.1 \(status) \(reason(status))\r\n"
        for (name, value) in headers { text += "\(name): \(value)\r\n" }
        text += "\r\n"
        return Data(text.utf8)
    }

    /// A whole response with a body of known length; the connection closes after it.
    static func response(status: Int, headers: [(String, String)] = [], body: Data = Data()) -> Data {
        var all = headers
        all.append(("Content-Length", "\(body.count)"))
        all.append(("Connection", "close"))
        return responseHead(status: status, headers: all) + body
    }

    /// The JSON body of an error, in the shape OpenAI's clients read.
    static func errorBody(message: String, type: String, code: String) -> Data {
        let object: [String: Any] = ["error": ["message": message, "type": type, "code": code]]
        return (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])) ?? Data()
    }

    static func chunk(_ data: Data) -> Data {
        Data(String(data.count, radix: 16).utf8) + Data("\r\n".utf8) + data + Data("\r\n".utf8)
    }

    static let lastChunk = Data("0\r\n\r\n".utf8)

    static func reason(_ status: Int) -> String {
        switch status {
        case 100: "Continue"
        case 200: "OK"
        case 204: "No Content"
        case 400: "Bad Request"
        case 401: "Unauthorized"
        case 403: "Forbidden"
        case 404: "Not Found"
        case 405: "Method Not Allowed"
        case 408: "Request Timeout"
        case 411: "Length Required"
        case 413: "Payload Too Large"
        case 431: "Request Header Fields Too Large"
        case 500: "Internal Server Error"
        case 502: "Bad Gateway"
        case 503: "Service Unavailable"
        case 504: "Gateway Timeout"
        default: HTTPURLResponse.localizedString(forStatusCode: status).capitalized
        }
    }
}
