import XCTest

@testable import LintCore

@MainActor
final class LocalAPIServiceTests: XCTestCase {
    private func config(
        enabled: Bool = true, port: Int = 8001, upstream: Int = 8000, origins: [String] = AllowedOrigin.defaults, extensions: Bool = false
    ) -> LocalAPIService.Configuration {
        LocalAPIService.Configuration(
            enabled: enabled, port: port, upstreamPort: upstream, allowedOrigins: origins, allowBrowserExtensions: extensions
        )
    }

    func testItIsOffUntilSwitchedOn() async {
        let listener = FakeListener()
        let service = LocalAPIService(proxy: listener)
        await service.apply(config(enabled: false))
        XCTAssertEqual(service.state, .off)
        XCTAssertEqual(listener.starts, [])
        await service.apply(config())
        XCTAssertEqual(service.state, .listening(port: 8001))
        XCTAssertEqual(listener.starts, [8001])
    }

    func testNewWebsitesOrANewModelPortDoNotRestartTheListener() async {
        let listener = FakeListener()
        let service = LocalAPIService(proxy: listener)
        await service.apply(config())
        await service.apply(config())
        await service.apply(config(origins: AllowedOrigin.defaults + ["https://tool.example.com"]))
        await service.apply(config(upstream: 8123))
        XCTAssertEqual(listener.starts, [8001])
        XCTAssertEqual(listener.updates.last?.0, 8123)
        XCTAssertEqual(listener.updates.first?.1, AllowedOrigin.defaults + ["https://tool.example.com"])
    }

    func testAllowingExtensionsAppliesWithoutListeningAgain() async {
        let listener = FakeListener()
        let service = LocalAPIService(proxy: listener)
        await service.apply(config())
        await service.apply(config(extensions: true))
        XCTAssertEqual(listener.updates.last?.2, true)
        await service.apply(config())
        XCTAssertEqual(listener.updates.last?.2, false)
        XCTAssertEqual(listener.starts, [8001])
    }

    func testANewPortListensAgainAndSwitchingOffStops() async {
        let listener = FakeListener()
        let service = LocalAPIService(proxy: listener)
        await service.apply(config())
        await service.apply(config(port: 8002))
        XCTAssertEqual(listener.starts, [8001, 8002])
        XCTAssertEqual(service.state, .listening(port: 8002))
        await service.apply(config(enabled: false))
        XCTAssertEqual(service.state, .off)
        XCTAssertGreaterThanOrEqual(listener.stops, 1)
    }

    func testABusyPortIsReportedAndOnlyTriedAgainAfterAChange() async {
        let listener = FakeListener()
        listener.busy = [8001]
        let service = LocalAPIService(proxy: listener)
        await service.apply(config())
        guard case .failed(let message) = service.state else { return XCTFail("\(service.state)") }
        XCTAssertTrue(message.contains("8001"), message)
        await service.apply(config())
        XCTAssertEqual(listener.starts, [8001], "not every second")
        await service.apply(config(port: 8002))
        XCTAssertEqual(service.state, .listening(port: 8002))
    }

    func testTheModelsOwnPortIsRefused() async {
        let listener = FakeListener()
        let service = LocalAPIService(proxy: listener)
        await service.apply(config(port: 8000, upstream: 8000))
        guard case .failed = service.state else { return XCTFail("\(service.state)") }
        XCTAssertEqual(listener.starts, [], "Lint's restart would kill whatever listens on the model's port, Lint included")
    }
}

private final class FakeListener: LocalAPIListening, @unchecked Sendable {
    private let lock = NSLock()
    var busy: Set<Int> = []
    private(set) var starts: [Int] = []
    private(set) var updates: [(Int, [String], Bool)] = []
    private(set) var stops = 0

    func start(port: Int, upstreamPort: Int, allowedOrigins: [String], allowBrowserExtensions: Bool) async throws -> Int {
        lock.withLock { starts.append(port) }
        if busy.contains(port) { throw LocalAPIProxy.StartError.portUnavailable(port: port) }
        return port
    }

    func update(upstreamPort: Int, allowedOrigins: [String], allowBrowserExtensions: Bool) {
        lock.withLock { updates.append((upstreamPort, allowedOrigins, allowBrowserExtensions)) }
    }

    func stop() {
        lock.withLock { stops += 1 }
    }
}
