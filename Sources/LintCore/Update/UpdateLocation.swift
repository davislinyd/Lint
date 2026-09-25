import Foundation

public struct UpdateSignature: Equatable, Sendable {
    public var identifier: String
    public var teamIdentifier: String
    public var isDeveloperIDApplication: Bool
    public var hasHardenedRuntime: Bool

    public init(
        identifier: String,
        teamIdentifier: String,
        isDeveloperIDApplication: Bool,
        hasHardenedRuntime: Bool
    ) {
        self.identifier = identifier
        self.teamIdentifier = teamIdentifier
        self.isDeveloperIDApplication = isDeveloperIDApplication
        self.hasHardenedRuntime = hasHardenedRuntime
    }

    public var acceptsReleasePayload: Bool {
        identifier == UpdateTrust.bundleID
            && teamIdentifier == UpdateTrust.teamID
            && isDeveloperIDApplication
            && hasHardenedRuntime
    }
}

/// Where an update is allowed to replace Lint. Anywhere else can still be checked.
public enum UpdateLocation {
    public static let systemApp = URL(fileURLWithPath: "/Applications/Lint.app", isDirectory: true)

    public static func userApp(home: URL) -> URL {
        home.appendingPathComponent("Applications/Lint.app", isDirectory: true)
    }

    public static func isAllowed(_ app: URL, home: URL) -> Bool {
        let path = pathKey(app)
        return path == pathKey(systemApp) || path == pathKey(userApp(home: home))
    }

    public static func isIncoming(_ incoming: URL, for destination: URL) -> Bool {
        pathKey(incoming) == pathKey(destination) + ".incoming"
    }

    /// `/Applications` and `/Users` are firmlinks. Bundle URLs sometimes keep the
    /// `/System/Volumes/Data` prefix and sometimes do not; both are the same app.
    public static func pathKey(_ url: URL) -> String {
        var path = url.standardizedFileURL.path
        let prefix = "/System/Volumes/Data"
        if path.hasPrefix(prefix + "/") {
            path.removeFirst(prefix.count)
        }
        while path.count > 1 && path.hasSuffix("/") {
            path.removeLast()
        }
        return path
    }
}

enum CodeSignDump {
    static func parse(_ text: String) -> UpdateSignature? {
        var identifier = ""
        var team = ""
        var developerID = false
        var runtime = false
        for raw in text.split(whereSeparator: \.isNewline) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if let value = line.dropPrefix("Identifier=") { identifier = value }
            if let value = line.dropPrefix("TeamIdentifier=") { team = value }
            if line.hasPrefix("Authority=Developer ID Application:") { developerID = true }
            if line.contains("flags="), line.contains("(runtime)") { runtime = true }
        }
        guard !identifier.isEmpty else { return nil }
        return UpdateSignature(
            identifier: identifier,
            teamIdentifier: team,
            isDeveloperIDApplication: developerID,
            hasHardenedRuntime: runtime
        )
    }
}

enum DiskImageMount {
    static func mountPoint(inPlist data: Data) -> URL? {
        guard let root = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let entities = root["system-entities"] as? [[String: Any]]
        else { return nil }
        for entity in entities {
            if let path = entity["mount-point"] as? String, !path.isEmpty {
                return URL(fileURLWithPath: path, isDirectory: true)
            }
        }
        return nil
    }
}

private extension String {
    func dropPrefix(_ prefix: String) -> String? {
        guard hasPrefix(prefix) else { return nil }
        return String(dropFirst(prefix.count))
    }
}

private extension Substring {
    func dropPrefix(_ prefix: String) -> String? {
        String(self).dropPrefix(prefix)
    }
}
