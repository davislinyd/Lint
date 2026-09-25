import XCTest

@testable import LintCore

final class UpdateTests: XCTestCase {
    private let hex = String(repeating: "0123456789abcdef", count: 4)
    private let home = URL(fileURLWithPath: "/Users/someone", isDirectory: true)

    // MARK: version

    func testNewerVersionsSortNumerically() {
        let older = SemanticVersion(parsing: "0.5.1")
        let middle = SemanticVersion(parsing: "v0.5.2")
        let newer = SemanticVersion(parsing: "0.10.0")
        XCTAssertEqual(older, SemanticVersion(major: 0, minor: 5, patch: 1))
        XCTAssertLessThan(older!, middle!)
        XCTAssertLessThan(middle!, newer!)
        XCTAssertFalse(middle! > newer!)
        XCTAssertEqual(middle, SemanticVersion(parsing: "0.5.2"))
    }

    func testTheSameOrOlderReleaseIsNotAnUpdate() {
        let local = SemanticVersion(parsing: "0.5.2")!
        XCTAssertEqual(
            UpdatePolicy.action(mode: .automatic, trigger: .scheduled, local: local, remote: local),
            .upToDate
        )
        XCTAssertEqual(
            UpdatePolicy.action(mode: .automatic, trigger: .userInstall, local: local, remote: SemanticVersion(parsing: "0.5.1")),
            .upToDate
        )
        XCTAssertEqual(
            UpdatePolicy.action(mode: .automatic, trigger: .scheduled, local: local, remote: nil),
            .upToDate
        )
    }

    func testVersionsThatAreNotAReleaseAreIgnored() {
        XCTAssertNil(SemanticVersion(parsing: "v0.5"))
        XCTAssertNil(SemanticVersion(parsing: "1.2.3-beta"))
        XCTAssertNil(SemanticVersion(parsing: "dev"))
        XCTAssertNil(SemanticVersion(parsing: "1.2.3.4"))
    }

    // MARK: schedule and mode

    func testFrequencySkipsACheckThatIsNotDue() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        XCTAssertFalse(UpdatePolicy.isDue(
            frequency: .daily, lastCheck: now, now: now.addingTimeInterval(3_600), checkedThisLaunch: false
        ))
        XCTAssertTrue(UpdatePolicy.isDue(
            frequency: .daily, lastCheck: now, now: now.addingTimeInterval(86_400), checkedThisLaunch: false
        ))
        XCTAssertFalse(UpdatePolicy.isDue(
            frequency: .weekly, lastCheck: now, now: now.addingTimeInterval(6 * 86_400), checkedThisLaunch: false
        ))
        XCTAssertTrue(UpdatePolicy.isDue(
            frequency: .weekly, lastCheck: now, now: now.addingTimeInterval(7 * 86_400), checkedThisLaunch: false
        ))
        XCTAssertFalse(UpdatePolicy.isDue(
            frequency: .monthly, lastCheck: now, now: now.addingTimeInterval(29 * 86_400), checkedThisLaunch: false
        ))
        XCTAssertTrue(UpdatePolicy.isDue(
            frequency: .monthly, lastCheck: now, now: now.addingTimeInterval(30 * 86_400), checkedThisLaunch: false
        ))
        XCTAssertTrue(UpdatePolicy.isDue(frequency: .daily, lastCheck: nil, now: now, checkedThisLaunch: true))
    }

    func testLaunchFrequencyChecksOncePerProcess() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        XCTAssertTrue(UpdatePolicy.isDue(frequency: .launch, lastCheck: now, now: now, checkedThisLaunch: false))
        XCTAssertFalse(UpdatePolicy.isDue(frequency: .launch, lastCheck: nil, now: now, checkedThisLaunch: true))
    }

    func testModeDecidesWhetherANewerReleaseIsInstalled() {
        let local = SemanticVersion(parsing: "0.5.1")!
        let remote = SemanticVersion(parsing: "0.5.2")!
        XCTAssertEqual(UpdatePolicy.action(mode: .checkOnly, trigger: .scheduled, local: local, remote: remote), .report(remote))
        XCTAssertEqual(UpdatePolicy.action(mode: .checkOnly, trigger: .userCheck, local: local, remote: remote), .report(remote))
        XCTAssertEqual(UpdatePolicy.action(mode: .checkOnly, trigger: .userInstall, local: local, remote: remote), .report(remote))
        XCTAssertEqual(UpdatePolicy.action(mode: .manual, trigger: .scheduled, local: local, remote: remote), .report(remote))
        XCTAssertEqual(UpdatePolicy.action(mode: .manual, trigger: .userCheck, local: local, remote: remote), .report(remote))
        XCTAssertEqual(UpdatePolicy.action(mode: .manual, trigger: .userInstall, local: local, remote: remote), .install(remote))
        XCTAssertEqual(UpdatePolicy.action(mode: .automatic, trigger: .scheduled, local: local, remote: remote), .install(remote))
        XCTAssertEqual(UpdatePolicy.action(mode: .automatic, trigger: .userCheck, local: local, remote: remote), .install(remote))
    }

    // MARK: catalog

    func testCatalogSelectsTheMatchingDiskImageAndIgnoresPreviews() throws {
        let data = payload(assets: [
            asset(name: "Lint-0.5.2-macOS-arm64-preview.dmg", digest: "sha256:\(hex)"),
            asset(name: "Lint-0.5.2-macOS-arm64-unnotarized.dmg", digest: "sha256:\(hex)"),
            asset(name: "Lint-0.5.2-macOS-arm64.dmg", digest: "sha256:\(hex)"),
            asset(name: "Lint-0.5.2-macOS-arm64.dmg.sha256", size: 80),
            asset(name: "Lint-0.5.2-macOS-x86_64.dmg", digest: "sha256:\(hex)"),
        ])
        let release = try GitHubReleaseCatalog.parse(data: data, architecture: .arm64)
        XCTAssertEqual(release.version.dotted, "0.5.2")
        XCTAssertEqual(release.diskImage.lastPathComponent, "Lint-0.5.2-macOS-arm64.dmg")
        XCTAssertEqual(release.checksumFile?.lastPathComponent, "Lint-0.5.2-macOS-arm64.dmg.sha256")
        XCTAssertEqual(release.assetDigest, hex)
        XCTAssertEqual(release.byteSize, 100)
    }

    func testCatalogRejectsATagThatDisagreesWithTheFileName() {
        let data = payload(assets: [
            asset(name: "Lint-0.5.1-macOS-arm64.dmg", digest: "sha256:\(hex)"),
        ])
        XCTAssertThrows(UpdateFailure.identityMismatch) {
            try GitHubReleaseCatalog.parse(data: data, architecture: .arm64)
        }
    }

    func testCatalogRejectsAnUntrustedHostAndAPreviewOnlyRelease() {
        let evil = payload(assets: [
            asset(
                name: "Lint-0.5.2-macOS-arm64.dmg",
                url: "https://evil.example/Lint-0.5.2-macOS-arm64.dmg",
                digest: "sha256:\(hex)"
            ),
        ])
        XCTAssertThrows(UpdateFailure.untrustedURL) {
            try GitHubReleaseCatalog.parse(data: evil, architecture: .arm64)
        }
        let preview = payload(assets: [
            asset(name: "Lint-0.5.2-macOS-arm64-preview.dmg", digest: "sha256:\(hex)"),
        ])
        XCTAssertThrows(UpdateFailure.noAssetForArchitecture) {
            try GitHubReleaseCatalog.parse(data: preview, architecture: .arm64)
        }
        let intel = payload(assets: [
            asset(name: "Lint-0.5.2-macOS-arm64.dmg", digest: "sha256:\(hex)"),
        ])
        XCTAssertThrows(UpdateFailure.noAssetForArchitecture) {
            try GitHubReleaseCatalog.parse(data: intel, architecture: .x86_64)
        }
    }

    func testCatalogRejectsPrereleasesAndReleasesWithoutAChecksum() {
        let preview = payload(prerelease: true, assets: [
            asset(name: "Lint-0.5.2-macOS-arm64.dmg", digest: "sha256:\(hex)"),
        ])
        XCTAssertThrows(UpdateFailure.noPublishedRelease) {
            try GitHubReleaseCatalog.parse(data: preview, architecture: .arm64)
        }
        let bare = payload(assets: [
            asset(name: "Lint-0.5.2-macOS-arm64.dmg"),
        ])
        XCTAssertThrows(UpdateFailure.missingChecksum) {
            try GitHubReleaseCatalog.parse(data: bare, architecture: .arm64)
        }
        XCTAssertNil(SemanticVersion(parsing: "not-a-release"))
        XCTAssertThrows(UpdateFailure.malformedRelease) {
            try GitHubReleaseCatalog.parse(data: payload(tag: "beta", assets: []), architecture: .arm64)
        }
    }

    func testChecksumFileUsesTheFirstField() {
        XCTAssertEqual(
            GitHubReleaseCatalog.checksumHex(in: "\(hex)  Lint-0.5.2-macOS-arm64.dmg\n"),
            hex
        )
        XCTAssertEqual(GitHubReleaseCatalog.checksumHex(in: "\n# note\n\(hex.uppercased())\n"), hex)
        XCTAssertNil(GitHubReleaseCatalog.checksumHex(in: "nope\n"))
        XCTAssertEqual(
            GitHubReleaseCatalog.resolvedChecksum(assetDigest: "sha256:\(hex)", checksumFile: "\(hex)  name\n"),
            .success(hex)
        )
        XCTAssertEqual(
            GitHubReleaseCatalog.resolvedChecksum(assetDigest: hex, checksumFile: String(repeating: "ab", count: 32) + "  name\n"),
            .failure(.checksumConflict)
        )
    }

    func testInstallLocationsAreTheTwoApplicationFolders() {
        XCTAssertTrue(UpdateLocation.isAllowed(URL(fileURLWithPath: "/Applications/Lint.app"), home: home))
        XCTAssertTrue(UpdateLocation.isAllowed(
            URL(fileURLWithPath: "/System/Volumes/Data/Applications/Lint.app"), home: home
        ))
        XCTAssertTrue(UpdateLocation.isAllowed(home.appendingPathComponent("Applications/Lint.app"), home: home))
        XCTAssertFalse(UpdateLocation.isAllowed(
            URL(fileURLWithPath: "/Users/someone/git/lint/dist/Lint.app"), home: home
        ))
    }

    func testCodeSignDumpRequiresTheReleaseIdentity() {
        let dump = """
        Identifier=app.lint.assistant
        TeamIdentifier=N964GDJY6A
        Authority=Developer ID Application: Example (N964GDJY6A)
        CodeDirectory v=20500 size=1 flags=0x10000(runtime) hashes=1
        """
        let signature = CodeSignDump.parse(dump)
        XCTAssertEqual(signature?.acceptsReleasePayload, true)
        XCTAssertEqual(CodeSignDump.parse("Identifier=app.lint.assistant\nTeamIdentifier=not set\n")?.acceptsReleasePayload, false)
    }

    // MARK: installer refusals

    func testACopyOutsideTheInstallLocationsIsNotReplaced() async {
        let fake = FakeDisk(hash: hex)
        let app = URL(fileURLWithPath: "/tmp/Lint.app")
        await assertRefusal(.outsideInstallLocations, fake: fake, app: app, release: release())
        XCTAssertTrue(fake.downloads.isEmpty)
    }

    func testADevelopmentSignatureIsNotReplaced() async {
        let fake = FakeDisk(hash: hex)
        fake.team = "UZCY4CEJAN"
        await assertRefusal(.developmentBuild, fake: fake, app: installed, release: release())
        XCTAssertTrue(fake.downloads.isEmpty)
    }

    func testAnUnwritableInstallIsNotDownloaded() async {
        let fake = FakeDisk(hash: hex)
        fake.writable = false
        await assertRefusal(.notWritable, fake: fake, app: installed, release: release())
        XCTAssertTrue(fake.downloads.isEmpty)
    }

    func testLowDiskSpaceSkipsTheDownload() async {
        let fake = FakeDisk(hash: hex)
        fake.bytes = 299
        await assertRefusal(.insufficientDisk, fake: fake, app: installed, release: release(size: 100))
        XCTAssertTrue(fake.downloads.isEmpty)
    }

    func testAChecksumMismatchDoesNotReplaceTheApp() async {
        let fake = FakeDisk(hash: String(repeating: "0", count: 64))
        fake.fileHex = hex
        await assertRefusal(.hashMismatch, fake: fake, app: installed, release: release())
        XCTAssertFalse(fake.downloads.isEmpty)
    }

    func testDisagreeingPublishedChecksumsDoNotReplaceTheApp() async {
        let fake = FakeDisk(hash: hex)
        fake.fileHex = String(repeating: "ab", count: 32)
        await assertRefusal(.checksumConflict, fake: fake, app: installed, release: release())
    }

    func testABadSignatureDoesNotReplaceTheApp() async {
        let fake = FakeDisk(hash: hex)
        fake.acceptSignature = false
        await assertRefusal(.signatureRejected, fake: fake, app: installed, release: release())
    }

    func testAPayloadVersionMismatchDoesNotReplaceTheApp() async {
        let fake = FakeDisk(hash: hex)
        fake.version = "0.5.1"
        await assertRefusal(.versionMismatch, fake: fake, app: installed, release: release())
    }

    func testStoppingTheCommitLeavesTheAppInPlace() async {
        let fake = FakeDisk(hash: hex)
        await assertRefusal(.cancelled, fake: fake, app: installed, release: release(), commit: false)
    }

    func testAVerifiedReleaseReachesTheSwapWithoutDeletingTheRunningApp() async throws {
        let fake = FakeDisk(hash: hex)
        let staging = try TestSupport.makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: staging) }
        try await UpdateInstaller(disk: fake.disk()).install(
            release: release(),
            runningApp: installed,
            home: home,
            stagingRoot: staging,
            processID: 1
        )
        XCTAssertEqual(fake.swappedTo.map(UpdateLocation.pathKey), [UpdateLocation.pathKey(installed)])
        XCTAssertFalse(fake.removed.contains { UpdateLocation.pathKey($0) == UpdateLocation.pathKey(installed) })
    }

    func testTheSwapScriptReplacesAnInstalledCopyAndRefusesAnywhereElse() throws {
        let root = try TestSupport.makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let dest = root.appendingPathComponent("Applications/Lint.app", isDirectory: true)
        let incoming = root.appendingPathComponent("Applications/Lint.app.incoming", isDirectory: true)
        try FileManager.default.createDirectory(at: dest, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: incoming, withIntermediateDirectories: true)
        try Data("old".utf8).write(to: dest.appendingPathComponent("marker"))
        try Data("new".utf8).write(to: incoming.appendingPathComponent("marker"))
        let exited = Process()
        exited.executableURL = URL(fileURLWithPath: "/usr/bin/true")
        try exited.run()
        exited.waitUntilExit()
        let status = try UpdateSwap.runScript(
            pid: exited.processIdentifier,
            destination: dest,
            incoming: incoming,
            home: root,
            environment: ["LINT_UPDATE_SKIP_OPEN": "1"],
            wait: true
        )
        XCTAssertEqual(status, 0)
        XCTAssertEqual(try String(contentsOf: dest.appendingPathComponent("marker"), encoding: .utf8), "new")
        XCTAssertFalse(FileManager.default.fileExists(atPath: incoming.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: dest.path + ".previous"))

        let elsewhere = try TestSupport.makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: elsewhere) }
        let foreign = elsewhere.appendingPathComponent("Lint.app", isDirectory: true)
        try FileManager.default.createDirectory(at: foreign, withIntermediateDirectories: true)
        try Data("stay".utf8).write(to: foreign.appendingPathComponent("marker"))
        let foreignIncoming = elsewhere.appendingPathComponent("Lint.app.incoming", isDirectory: true)
        try FileManager.default.createDirectory(at: foreignIncoming, withIntermediateDirectories: true)
        let refused = try UpdateSwap.runScript(
            pid: 1,
            destination: foreign,
            incoming: foreignIncoming,
            home: root,
            environment: ["LINT_UPDATE_SKIP_OPEN": "1"],
            wait: true
        )
        XCTAssertEqual(refused, 2)
        XCTAssertEqual(try String(contentsOf: foreign.appendingPathComponent("marker"), encoding: .utf8), "stay")
    }

    // MARK: fixtures

    private var installed: URL { URL(fileURLWithPath: "/Applications/Lint.app", isDirectory: true) }

    private func release(size: Int64 = 100) -> UpdateRelease {
        UpdateRelease(
            version: SemanticVersion(parsing: "0.5.2")!,
            page: URL(string: "https://github.com/davislinyd/Lint/releases/tag/v0.5.2")!,
            diskImage: URL(string: "https://github.com/davislinyd/Lint/releases/download/v0.5.2/Lint-0.5.2-macOS-arm64.dmg")!,
            checksumFile: URL(string: "https://github.com/davislinyd/Lint/releases/download/v0.5.2/Lint-0.5.2-macOS-arm64.dmg.sha256")!,
            assetDigest: hex,
            byteSize: size
        )
    }

    private func assertRefusal(
        _ expected: UpdateFailure,
        fake: FakeDisk,
        app: URL,
        release: UpdateRelease,
        commit: Bool = true
    ) async {
        do {
            try await UpdateInstaller(disk: fake.disk()).install(
                release: release,
                runningApp: app,
                home: home,
                stagingRoot: URL(fileURLWithPath: "/tmp/lint-update-tests", isDirectory: true),
                processID: 1,
                shouldCommit: { commit }
            )
            XCTFail("expected \(expected.rawValue)")
        } catch let failure as UpdateFailure {
            XCTAssertEqual(failure, expected)
        } catch {
            XCTFail("unexpected \(error)")
        }
        XCTAssertTrue(fake.swappedTo.isEmpty)
        XCTAssertFalse(fake.removed.contains { UpdateLocation.pathKey($0) == UpdateLocation.pathKey(app) })
    }

    private func payload(
        tag: String = "v0.5.2",
        prerelease: Bool = false,
        draft: Bool = false,
        assets: [String]
    ) -> Data {
        let json = """
        {"tag_name":"\(tag)","html_url":"https://github.com/davislinyd/Lint/releases/tag/v0.5.2","draft":\(draft),"prerelease":\(prerelease),"assets":[\(assets.joined(separator: ","))]}
        """
        return Data(json.utf8)
    }

    private func asset(
        name: String,
        url: String? = nil,
        size: Int = 100,
        digest: String? = nil
    ) -> String {
        let remote = url ?? "https://github.com/davislinyd/Lint/releases/download/v0.5.2/\(name)"
        let digestField = digest.map { ",\"digest\":\"\($0)\"" } ?? ""
        return #"{"name":"\#(name)","browser_download_url":"\#(remote)","size":\#(size)\#(digestField)}"#
    }
}

private extension UpdateTests {
    func XCTAssertThrows(_ expected: UpdateFailure, _ body: () throws -> some Any) {
        do {
            _ = try body()
            XCTFail("expected \(expected)")
        } catch let failure as UpdateFailure {
            XCTAssertEqual(failure, expected)
        } catch {
            XCTFail("unexpected \(error)")
        }
    }
}

private final class FakeDisk: @unchecked Sendable {
    var downloads: [URL] = []
    var swappedTo: [URL] = []
    var removed: [URL] = []
    var actualHash: String
    var fileHex: String?
    var version = "0.5.2"
    var acceptSignature = true
    var gatekeeper = true
    var bytes: Int64 = 1 << 40
    var writable = true
    var team = UpdateTrust.teamID

    init(hash: String) {
        actualHash = hash
    }

    func disk() -> UpdateDisk {
        UpdateDisk(
            availableBytes: { [self] _ in
                self.bytes
            },
            isWritable: { [self] _ in self.writable },
            teamID: { [self] _ in self.team },
            createDirectory: { _ in },
            download: { [self] remote, _ in
                self.downloads.append(remote)
            },
            readText: { [self] _ in
                let hex = self.fileHex ?? self.actualHash
                return "\(hex)  Lint-0.5.2-macOS-arm64.dmg\n"
            },
            sha256: { [self] _ in self.actualHash },
            mount: { _ in URL(fileURLWithPath: "/Volumes/Lint", isDirectory: true) },
            unmount: { _ in },
            shortVersion: { [self] _ in self.version },
            signature: { [self] _ in
                UpdateSignature(
                    identifier: UpdateTrust.bundleID,
                    teamIdentifier: self.acceptSignature ? UpdateTrust.teamID : "OTHER",
                    isDeveloperIDApplication: self.acceptSignature,
                    hasHardenedRuntime: self.acceptSignature
                )
            },
            gatekeeperAccepts: { [self] _ in self.gatekeeper },
            ditto: { _, _ in },
            remove: { [self] url in
                self.removed.append(url)
            },
            beginSwap: { [self] _, destination, _ in
                self.swappedTo.append(destination)
            }
        )
    }
}
