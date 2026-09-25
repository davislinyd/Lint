import Foundation

public enum UpdateFailure: String, Error, Equatable, Sendable {
    case malformedRelease
    case untrustedURL
    case noAssetForArchitecture
    case identityMismatch
    case noPublishedRelease
    case rateLimited
    case unreachable
    case missingChecksum
    case checksumConflict
    case hashMismatch
    case signatureRejected
    case outsideInstallLocations
    case notWritable
    case insufficientDisk
    case developmentBuild
    case versionMismatch
    case mountFailed
    case downloadFailed
    case cancelled
}

public struct UpdateRelease: Equatable, Sendable {
    public var version: SemanticVersion
    public var page: URL
    public var diskImage: URL
    public var checksumFile: URL?
    /// Lowercase hex from the asset's `digest`, when GitHub sent a sha256 digest.
    public var assetDigest: String?
    public var byteSize: Int64

    public init(
        version: SemanticVersion,
        page: URL,
        diskImage: URL,
        checksumFile: URL?,
        assetDigest: String?,
        byteSize: Int64
    ) {
        self.version = version
        self.page = page
        self.diskImage = diskImage
        self.checksumFile = checksumFile
        self.assetDigest = assetDigest
        self.byteSize = byteSize
    }
}

/// The Developer ID team a replacement app must carry. A development or ad-hoc
/// signature is never an update, even if the bytes match a checksum.
public enum UpdateTrust {
    public static let teamID = "N964GDJY6A"
    public static let bundleID = "app.lint.assistant"
}

public enum GitHubReleaseCatalog {
    public static let latestURL = URL(string: "https://api.github.com/repos/davislinyd/Lint/releases/latest")!

    public static let allowedHosts: Set<String> = [
        "github.com",
        "api.github.com",
        "release-assets.githubusercontent.com",
        "objects.githubusercontent.com",
    ]

    public static func allows(_ url: URL) -> Bool {
        guard url.scheme?.lowercased() == "https", let host = url.host?.lowercased() else { return false }
        return allowedHosts.contains(host)
    }

    public static func parse(data: Data, architecture: CPUArchitecture) throws -> UpdateRelease {
        let payload: ReleasePayload
        do {
            payload = try JSONDecoder().decode(ReleasePayload.self, from: data)
        } catch {
            throw UpdateFailure.malformedRelease
        }
        if payload.draft == true || payload.prerelease == true {
            throw UpdateFailure.noPublishedRelease
        }
        guard let version = SemanticVersion(parsing: payload.tagName) else {
            throw UpdateFailure.malformedRelease
        }
        guard let page = URL(string: payload.htmlURL), allows(page) else {
            throw UpdateFailure.untrustedURL
        }

        var match: ReleasePayload.Asset?
        for asset in payload.assets {
            guard let assetVersion = officialVersion(in: asset.name, architecture: architecture) else { continue }
            guard assetVersion == version else { throw UpdateFailure.identityMismatch }
            guard match == nil else { throw UpdateFailure.malformedRelease }
            match = asset
        }
        guard let match else { throw UpdateFailure.noAssetForArchitecture }
        guard let imageURL = URL(string: match.browserDownloadURL), allows(imageURL) else {
            throw UpdateFailure.untrustedURL
        }
        guard let byteSize = match.size, byteSize > 0 else { throw UpdateFailure.malformedRelease }

        let digest = normalizedDigest(match.digest)
        let checksumName = match.name + ".sha256"
        let checksumAsset = payload.assets.first { $0.name == checksumName }
        var checksumURL: URL?
        if let checksumAsset {
            guard let url = URL(string: checksumAsset.browserDownloadURL), allows(url) else {
                throw UpdateFailure.untrustedURL
            }
            checksumURL = url
        }
        if digest == nil && checksumURL == nil {
            throw UpdateFailure.missingChecksum
        }
        return UpdateRelease(
            version: version,
            page: page,
            diskImage: imageURL,
            checksumFile: checksumURL,
            assetDigest: digest,
            byteSize: byteSize
        )
    }

    /// First field of the first checksum line (`shasum -a 256` writes `hex  name`).
    public static func checksumHex(in text: String) -> String? {
        for raw in text.split(whereSeparator: \.isNewline) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") { continue }
            guard let field = line.split(whereSeparator: \.isWhitespace).first else { return nil }
            return normalizedDigest(String(field))
        }
        return nil
    }

    /// Both published checksums, when both exist, have to be the same hash.
    public static func resolvedChecksum(assetDigest: String?, checksumFile: String?) -> Result<String, UpdateFailure> {
        let digest = normalizedDigest(assetDigest)
        switch (digest, checksumFile) {
        case let (digest?, file?):
            guard let fileHex = checksumHex(in: file), fileHex == digest else {
                return .failure(.checksumConflict)
            }
            return .success(digest)
        case let (digest?, nil):
            return .success(digest)
        case let (nil, file?):
            guard let fileHex = checksumHex(in: file) else { return .failure(.checksumConflict) }
            return .success(fileHex)
        case (nil, nil):
            return .failure(.missingChecksum)
        }
    }

    static func officialVersion(in name: String, architecture: CPUArchitecture) -> SemanticVersion? {
        let prefix = "Lint-"
        let suffix = "-macOS-\(architecture.rawValue).dmg"
        guard name.hasPrefix(prefix), name.hasSuffix(suffix) else { return nil }
        return SemanticVersion(parsing: String(name.dropFirst(prefix.count).dropLast(suffix.count)))
    }

    static func normalizedDigest(_ raw: String?) -> String? {
        guard var text = raw?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(), !text.isEmpty else {
            return nil
        }
        let prefix = "sha256:"
        if text.hasPrefix(prefix) { text.removeFirst(prefix.count) }
        guard text.count == 64, text.allSatisfy(\.isHexDigit) else { return nil }
        return text
    }
}

private struct ReleasePayload: Decodable {
    var tagName: String
    var htmlURL: String
    var draft: Bool?
    var prerelease: Bool?
    var assets: [Asset]

    struct Asset: Decodable {
        var name: String
        var browserDownloadURL: String
        var size: Int64?
        var digest: String?
    }

    enum CodingKeys: String, CodingKey {
        case tagName = "tag_name"
        case htmlURL = "html_url"
        case draft
        case prerelease
        case assets
    }
}

extension ReleasePayload.Asset {
    enum CodingKeys: String, CodingKey {
        case name
        case browserDownloadURL = "browser_download_url"
        case size
        case digest
    }
}
