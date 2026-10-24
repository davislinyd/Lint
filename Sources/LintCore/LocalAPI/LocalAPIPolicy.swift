import Foundation

/// A web origin that may use Lint's API port from a browser: a scheme and a host (or every subdomain
/// of a domain, `*.`), and a port or any port (`*`). Settings stores them as text, such as
/// `http://localhost:*`, `https://tool.example.com` or `https://*.example.com`.
public struct AllowedOrigin: Equatable, Hashable, Sendable {
    public var scheme: String
    /// With `anySubdomain`, the domain whose subdomains match (not the domain itself).
    public var host: String
    /// nil matches any port.
    public var port: Int?
    public var anySubdomain = false

    /// Local pages, at any port: what a tool served on this Mac (or a dev server) uses.
    public static let defaults = ["http://localhost:*", "http://127.0.0.1:*", "https://localhost:*"]

    /// Reads a stored entry. Wildcard ports are only allowed for local hosts, and `*.` only in front
    /// of a domain name of two labels or more.
    public static func parse(_ text: String) -> AllowedOrigin? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let anyPort = trimmed.hasSuffix(":*")
        var base = anyPort ? String(trimmed.dropLast(2)) : trimmed
        var anySubdomain = false
        if let wildcard = base.range(of: "://*.") {
            base.replaceSubrange(wildcard, with: "://")
            anySubdomain = true
        }
        guard let origin = Origin(base), origin.path.isEmpty else { return nil }
        if anySubdomain {
            let labels = origin.host.split(separator: ".", omittingEmptySubsequences: false)
            guard labels.count >= 2, !labels.contains(where: \.isEmpty), origin.host.contains(where: \.isLetter) else { return nil }
        }
        if anyPort {
            guard !anySubdomain, origin.explicitPort == nil, Self.isLocalHost(origin.host) else { return nil }
            return AllowedOrigin(scheme: origin.scheme, host: origin.host, port: nil)
        }
        return AllowedOrigin(scheme: origin.scheme, host: origin.host, port: origin.port, anySubdomain: anySubdomain)
    }

    /// What a user typed in Settings, as it will be stored: `http(s)://[*.]host[:port]`, lowercase, no
    /// path, default port left out. nil for anything else (other schemes, any port, other wildcards, paths).
    public static func normalizeUserEntry(_ text: String) -> String? {
        var trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if trimmed.hasSuffix("/") { trimmed.removeLast() }
        guard !trimmed.hasSuffix(":*"), let origin = parse(trimmed), let port = origin.port else { return nil }
        let name = origin.anySubdomain ? "*.\(origin.host)" : origin.host
        let defaultPort = origin.scheme == "https" ? 443 : 80
        return port == defaultPort ? "\(origin.scheme)://\(name)" : "\(origin.scheme)://\(name):\(port)"
    }

    /// Whether the `Origin` header of a request is this one.
    public func matches(_ header: String) -> Bool {
        guard let origin = Origin(header.lowercased()), origin.path.isEmpty,
              origin.scheme == scheme, port == nil || origin.port == port
        else { return false }
        return anySubdomain ? origin.host.hasSuffix("." + host) : origin.host == host
    }

    public var text: String {
        let name = anySubdomain ? "*.\(host)" : host
        if let port { return "\(scheme)://\(name):\(port)" }
        return "\(scheme)://\(name):*"
    }

    static func isLocalHost(_ host: String) -> Bool {
        host == "localhost" || host == "127.0.0.1"
    }
}

/// The scheme, host and port of an origin or a URL without credentials.
private struct Origin {
    var scheme: String
    var host: String
    var port: Int
    var explicitPort: Int?
    var path: String

    init?(_ text: String) {
        guard let components = URLComponents(string: text),
              let scheme = components.scheme, scheme == "http" || scheme == "https",
              let host = components.host, !host.isEmpty,
              components.user == nil, components.password == nil,
              components.query == nil, components.fragment == nil,
              host.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "." || $0 == "-") })
        else { return nil }
        self.scheme = scheme
        self.host = host
        explicitPort = components.port
        port = components.port ?? (scheme == "https" ? 443 : 80)
        path = components.path
    }
}

/// The checks Lint's API port makes before a request goes anywhere.
enum LocalAPIPolicy {
    /// The `Host` header must name this Mac's loopback at the API port. A page that rebinds its own
    /// domain to 127.0.0.1 (DNS rebinding) still sends its own name here.
    static func isAllowedHost(_ header: String?, port: Int) -> Bool {
        guard let header else { return false }
        let host = header.lowercased()
        return host == "127.0.0.1:\(port)" || host == "localhost:\(port)"
    }

    /// With `browserExtensions`, any browser extension is let in too (it still needs a key); `null`
    /// (a file or a sandboxed frame) and other schemes never are.
    static func isAllowedOrigin(_ header: String, allowed: [AllowedOrigin], browserExtensions: Bool = false) -> Bool {
        if browserExtensions, isBrowserExtension(header) { return true }
        return allowed.contains { $0.matches(header) }
    }

    /// The origin a browser extension's own pages and background send: Chrome, Brave and Edge, Firefox, Safari.
    static func isBrowserExtension(_ header: String) -> Bool {
        guard let components = URLComponents(string: header.lowercased()),
              let scheme = components.scheme, ["chrome-extension", "moz-extension", "safari-web-extension"].contains(scheme),
              let id = components.host, !id.isEmpty, id.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") }),
              components.port == nil, components.path.isEmpty, components.query == nil, components.fragment == nil,
              components.user == nil
        else { return false }
        return true
    }

    /// The key a request presents: `Authorization: Bearer <key>` (any case for the scheme) or `X-Api-Key`.
    static func presentedKey(authorization: String?, apiKeyHeader: String?) -> String? {
        if let authorization {
            let parts = authorization.split(separator: " ", maxSplits: 1)
            if parts.count == 2, parts[0].caseInsensitiveCompare("Bearer") == .orderedSame {
                return parts[1].trimmingCharacters(in: .whitespaces)
            }
            return nil
        }
        return apiKeyHeader?.trimmingCharacters(in: .whitespaces)
    }

    /// Headers that let the page at `origin` read a response. No credentials: the key is a header,
    /// not a cookie.
    static func corsHeaders(origin: String) -> [(String, String)] {
        [("Access-Control-Allow-Origin", origin), ("Vary", "Origin")]
    }

    static func preflightHeaders(origin: String, privateNetworkRequested: Bool) -> [(String, String)] {
        var headers = corsHeaders(origin: origin)
        headers += [
            ("Access-Control-Allow-Methods", "GET, POST, OPTIONS"),
            ("Access-Control-Allow-Headers", "authorization, content-type, x-api-key"),
            ("Access-Control-Max-Age", "600"),
        ]
        if privateNetworkRequested { headers.append(("Access-Control-Allow-Private-Network", "true")) }
        return headers
    }
}
