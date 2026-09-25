import Foundation

extension UpdateDisk {
    public static func live() -> UpdateDisk {
        let session = GuardedURLSession.make()
        let space = SystemDiskSpaceProvider()
        return UpdateDisk(
            availableBytes: { try space.availableBytes(at: $0) },
            isWritable: { app in
                let parent = app.deletingLastPathComponent()
                let files = FileManager.default
                guard files.isWritableFile(atPath: parent.path) else { return false }
                if files.fileExists(atPath: app.path), !files.isWritableFile(atPath: app.path) { return false }
                return true
            },
            teamID: { app in
                guard let signature = try CodeSign.signature(of: app) else {
                    throw UpdateFailure.developmentBuild
                }
                return signature.teamIdentifier
            },
            createDirectory: {
                try FileManager.default.createDirectory(at: $0, withIntermediateDirectories: true)
            },
            download: { remote, destination in
                guard GitHubReleaseCatalog.allows(remote) else { throw UpdateFailure.untrustedURL }
                var request = URLRequest(url: remote)
                request.cachePolicy = .reloadIgnoringLocalCacheData
                request.timeoutInterval = 60
                let (temporary, response) = try await session.download(for: request)
                guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                    throw UpdateFailure.downloadFailed
                }
                let files = FileManager.default
                if files.fileExists(atPath: destination.path) {
                    try files.removeItem(at: destination)
                }
                try files.moveItem(at: temporary, to: destination)
            },
            readText: { try String(contentsOf: $0, encoding: .utf8) },
            sha256: { try FileDigest.sha256(of: $0) },
            mount: { image in
                let output = try ProcessOutput.capture(
                    "/usr/bin/hdiutil",
                    ["attach", image.path, "-nobrowse", "-readonly", "-noautoopen", "-plist"]
                )
                guard output.status == 0, let point = DiskImageMount.mountPoint(inPlist: output.data) else {
                    throw UpdateFailure.mountFailed
                }
                return point
            },
            unmount: { point in
                let first = try ProcessOutput.capture("/usr/bin/hdiutil", ["detach", point.path, "-quiet"])
                if first.status != 0 {
                    _ = try ProcessOutput.capture("/usr/bin/hdiutil", ["detach", point.path, "-force", "-quiet"])
                }
            },
            shortVersion: { try AppBundleVersion.shortVersion(of: $0) },
            signature: { app in
                guard let signature = try CodeSign.signature(of: app) else {
                    throw UpdateFailure.signatureRejected
                }
                return signature
            },
            gatekeeperAccepts: { app in
                let output = try ProcessOutput.capture(
                    "/usr/sbin/spctl",
                    ["--assess", "--type", "execute", "--verbose=4", app.path]
                )
                return output.status == 0
            },
            ditto: { source, destination in
                let output = try ProcessOutput.capture("/usr/bin/ditto", [source.path, destination.path])
                guard output.status == 0 else { throw UpdateFailure.downloadFailed }
            },
            remove: {
                if FileManager.default.fileExists(atPath: $0.path) {
                    try FileManager.default.removeItem(at: $0)
                }
            },
            beginSwap: { pid, destination, incoming in
                try UpdateSwap.launch(pid: pid, destination: destination, incoming: incoming, home: FileManager.default.homeDirectoryForCurrentUser)
            }
        )
    }
}

public struct UpdateClient: Sendable {
    public var perform: @Sendable (URLRequest) async throws -> (Data, Int)

    public init(perform: @escaping @Sendable (URLRequest) async throws -> (Data, Int)) {
        self.perform = perform
    }

    public func latest(architecture: CPUArchitecture, userAgent: String) async throws -> UpdateRelease {
        var request = URLRequest(url: GitHubReleaseCatalog.latestURL)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 30
        request.cachePolicy = .reloadIgnoringLocalCacheData
        guard let url = request.url, GitHubReleaseCatalog.allows(url) else { throw UpdateFailure.untrustedURL }
        let data: Data
        let status: Int
        do {
            (data, status) = try await perform(request)
        } catch let failure as UpdateFailure {
            throw failure
        } catch {
            throw UpdateFailure.unreachable
        }
        switch status {
        case 200:
            return try GitHubReleaseCatalog.parse(data: data, architecture: architecture)
        case 404:
            throw UpdateFailure.noPublishedRelease
        case 403, 429:
            throw UpdateFailure.rateLimited
        default:
            throw UpdateFailure.unreachable
        }
    }

    public static func live() -> UpdateClient {
        let session = GuardedURLSession.make()
        return UpdateClient { request in
            let (data, response) = try await session.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            return (data, status)
        }
    }
}

enum GuardedURLSession {
    static func make() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 60
        configuration.timeoutIntervalForResource = 600
        return URLSession(configuration: configuration, delegate: RedirectGuard.shared, delegateQueue: nil)
    }
}

private final class RedirectGuard: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    static let shared = RedirectGuard()

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest
    ) async -> URLRequest? {
        guard let url = request.url, GitHubReleaseCatalog.allows(url) else { return nil }
        return request
    }
}

enum AppBundleVersion {
    static func shortVersion(of app: URL) throws -> String {
        let url = app.appendingPathComponent("Contents/Info.plist")
        let data = try Data(contentsOf: url)
        guard let plist = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let version = plist["CFBundleShortVersionString"] as? String
        else { throw UpdateFailure.versionMismatch }
        return version
    }
}

enum CodeSign {
    static func signature(of app: URL) throws -> UpdateSignature? {
        let verify = try ProcessOutput.capture(
            "/usr/bin/codesign",
            ["--verify", "--deep", "--strict", "--verbose=2", app.path]
        )
        guard verify.status == 0 else { return nil }
        let details = try ProcessOutput.capture("/usr/bin/codesign", ["-dvv", app.path])
        guard details.status == 0 else { return nil }
        return CodeSignDump.parse(details.text)
    }
}

struct ProcessOutput {
    var status: Int32
    var data: Data
    var text: String { String(data: data, encoding: .utf8) ?? "" }

    static func capture(_ executable: String, _ arguments: [String]) throws -> ProcessOutput {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        process.standardInput = FileHandle.nullDevice
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return ProcessOutput(status: process.terminationStatus, data: data)
    }
}
