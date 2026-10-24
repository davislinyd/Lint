import XCTest

@testable import LintCore

final class LocalAPIPolicyTests: XCTestCase {
    func testOnlyThisMacsLoopbackAtTheAPIPortIsAcceptedAsHost() {
        XCTAssertTrue(LocalAPIPolicy.isAllowedHost("127.0.0.1:8001", port: 8001))
        XCTAssertTrue(LocalAPIPolicy.isAllowedHost("LOCALHOST:8001", port: 8001))
        for host in [nil, "", "127.0.0.1", "127.0.0.1:8000", "rebind.example:8001", "localhost.evil.example:8001",
                     "127.0.0.1.evil.example:8001", "[::1]:8001", "0.0.0.0:8001"] {
            XCTAssertFalse(LocalAPIPolicy.isAllowedHost(host, port: 8001), "\(host ?? "nil")")
        }
    }

    func testTheDefaultsLetLocalPagesInAtAnyPortAndNothingElse() {
        let allowed = AllowedOrigin.defaults.compactMap(AllowedOrigin.parse)
        XCTAssertEqual(allowed.count, 3)
        for origin in ["http://localhost:3000", "http://localhost", "http://127.0.0.1:5500", "https://localhost:8443"] {
            XCTAssertTrue(LocalAPIPolicy.isAllowedOrigin(origin, allowed: allowed), origin)
        }
        for origin in ["https://example.com", "http://localhost.evil.example", "http://127.0.0.1.evil.example:80", "null",
                       "http://[::1]:3000", "file://", "chrome-extension://abc", "https://127.0.0.1:443", ""] {
            XCTAssertFalse(LocalAPIPolicy.isAllowedOrigin(origin, allowed: allowed), origin)
        }
    }

    func testAnAddedWebsiteMatchesOnlyItself() throws {
        let site = try XCTUnwrap(AllowedOrigin.parse("https://tool.example.com"))
        XCTAssertTrue(site.matches("https://tool.example.com"))
        XCTAssertTrue(site.matches("https://tool.example.com:443"))
        XCTAssertFalse(site.matches("https://tool.example.com:8443"))
        XCTAssertFalse(site.matches("http://tool.example.com"))
        XCTAssertFalse(site.matches("https://evil.tool.example.com"))
        XCTAssertFalse(site.matches("https://tool.example.com.evil.example"))
    }

    func testWhatAUserTypesIsNormalizedOrRefused() {
        XCTAssertEqual(AllowedOrigin.normalizeUserEntry(" HTTPS://Tool.Example.com/ "), "https://tool.example.com")
        XCTAssertEqual(AllowedOrigin.normalizeUserEntry("https://tool.example.com:443"), "https://tool.example.com")
        XCTAssertEqual(AllowedOrigin.normalizeUserEntry("https://tool.example.com:8443"), "https://tool.example.com:8443")
        XCTAssertEqual(AllowedOrigin.normalizeUserEntry("http://Tool.Example.com:80"), "http://tool.example.com")
        XCTAssertEqual(AllowedOrigin.normalizeUserEntry("http://192.168.1.5:3000"), "http://192.168.1.5:3000")
        XCTAssertEqual(AllowedOrigin.normalizeUserEntry("https://*.Example.com/"), "https://*.example.com")
        XCTAssertEqual(AllowedOrigin.normalizeUserEntry("http://*.example.com:8080"), "http://*.example.com:8080")
        for entry in ["*", "https://*", "https://*.com", "https://*.*.example.com", "https://a.*.example.com",
                      "https://*example.com", "https://*.168.1.5", "https://*.example.com:*", "http://localhost:*",
                      "ftp://tool.example.com", "https://tool.example.com/path", "https://user:pw@tool.example.com",
                      "https://tool.example.com?x=1", "tool.example.com", ""] {
            XCTAssertNil(AllowedOrigin.normalizeUserEntry(entry), entry)
        }
        XCTAssertNil(AllowedOrigin.parse("https://tool.example.com:*"), "any port only for this Mac's own pages")
    }

    func testAnHTTPWebsiteMatchesOnlyPlainHTTP() throws {
        let site = try XCTUnwrap(AllowedOrigin.parse("http://192.168.1.5:3000"))
        XCTAssertTrue(site.matches("http://192.168.1.5:3000"))
        XCTAssertFalse(site.matches("https://192.168.1.5:3000"))
        XCTAssertFalse(site.matches("http://192.168.1.5"))
    }

    func testAnySubdomainMatchesSubdomainsOnly() throws {
        let site = try XCTUnwrap(AllowedOrigin.parse("https://*.example.com"))
        XCTAssertEqual(site.text, "https://*.example.com:443")
        for origin in ["https://a.example.com", "https://a.b.example.com", "https://a.example.com:443"] {
            XCTAssertTrue(site.matches(origin), origin)
        }
        for origin in ["https://example.com", "https://evil-example.com", "https://a.example.com.evil.example",
                       "http://a.example.com", "https://a.example.com:8443", "null"] {
            XCTAssertFalse(site.matches(origin), origin)
        }
        let withPort = try XCTUnwrap(AllowedOrigin.parse("http://*.example.com:8080"))
        XCTAssertTrue(withPort.matches("http://dev.example.com:8080"))
        XCTAssertFalse(withPort.matches("http://dev.example.com"))
    }

    func testAnyWebsiteLetsEveryWebOriginInButNotNullOrOtherSchemes() {
        for origin in ["https://evil.example", "http://example.com", "https://tool.example.com:8443", "http://192.168.1.5:3000",
                       "http://localhost:3000"] {
            XCTAssertTrue(LocalAPIPolicy.isAllowedOrigin(origin, allowed: [], anyWebsite: true), origin)
            XCTAssertFalse(LocalAPIPolicy.isAllowedOrigin(origin, allowed: [], anyWebsite: false), origin)
        }
        for origin in ["null", "file://", "chrome-extension://abcdef", "moz-extension://abc", "", "https://a.example/path",
                       "http://[::1]:3000"] {
            XCTAssertFalse(LocalAPIPolicy.isAllowedOrigin(origin, allowed: [], anyWebsite: true), origin)
        }
    }

    func testBrowserExtensionsGetInOnlyWithTheirOwnSwitch() {
        let extensions = ["chrome-extension://abcdefghijklmnopabcdefghijklmnop", "moz-extension://0d3a6f0e-1111-4222-8333-444455556666",
                          "safari-web-extension://E3A1B2C4-0000-4000-8000-000000000000"]
        for origin in extensions {
            XCTAssertFalse(LocalAPIPolicy.isAllowedOrigin(origin, allowed: [], anyWebsite: true), origin)
            XCTAssertTrue(LocalAPIPolicy.isAllowedOrigin(origin, allowed: [], browserExtensions: true), origin)
        }
        for origin in ["null", "file://", "chrome-extension://", "chrome-extension://abc/page.html", "chrome-extension://abc:80",
                       "ms-browser-extension://abc", "https://evil.example"] {
            XCTAssertFalse(LocalAPIPolicy.isAllowedOrigin(origin, allowed: [], browserExtensions: true), origin)
        }
    }

    func testTheKeyComesFromABearerTokenOrXAPIKey() {
        XCTAssertEqual(LocalAPIPolicy.presentedKey(authorization: "Bearer abc", apiKeyHeader: nil), "abc")
        XCTAssertEqual(LocalAPIPolicy.presentedKey(authorization: "bearer abc", apiKeyHeader: nil), "abc")
        XCTAssertEqual(LocalAPIPolicy.presentedKey(authorization: nil, apiKeyHeader: "abc"), "abc")
        XCTAssertNil(LocalAPIPolicy.presentedKey(authorization: "Basic YWJj", apiKeyHeader: "abc"), "a wrong scheme is not rescued")
        XCTAssertNil(LocalAPIPolicy.presentedKey(authorization: nil, apiKeyHeader: nil))
    }

    func testAPreflightAllowsTheKeyHeadersAndNoCredentials() {
        let headers = LocalAPIPolicy.preflightHeaders(origin: "http://localhost:3000", privateNetworkRequested: true)
        let names = headers.map(\.0)
        XCTAssertTrue(headers.contains { $0 == ("Access-Control-Allow-Origin", "http://localhost:3000") })
        XCTAssertTrue(headers.contains { $0 == ("Access-Control-Allow-Headers", "authorization, content-type, x-api-key") })
        XCTAssertTrue(headers.contains { $0 == ("Access-Control-Allow-Private-Network", "true") })
        XCTAssertFalse(names.contains("Access-Control-Allow-Credentials"))
        XCTAssertFalse(LocalAPIPolicy.preflightHeaders(origin: "x", privateNetworkRequested: false).map(\.0).contains("Access-Control-Allow-Private-Network"))
    }
}
