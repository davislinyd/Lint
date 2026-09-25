import Foundation

/// `MAJOR.MINOR.PATCH` as Lint publishes it (`0.5.2`, or a tag `v0.5.2`).
/// Build metadata and pre-release suffixes are not versions Lint will install.
public struct SemanticVersion: Comparable, Hashable, Sendable {
    public let major: Int
    public let minor: Int
    public let patch: Int

    public init(major: Int, minor: Int, patch: Int) {
        self.major = major
        self.minor = minor
        self.patch = patch
    }

    public init?(parsing raw: String) {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.first == "v" || text.first == "V" {
            text.removeFirst()
        }
        let parts = text.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3,
              let major = Self.number(parts[0]),
              let minor = Self.number(parts[1]),
              let patch = Self.number(parts[2])
        else { return nil }
        self.major = major
        self.minor = minor
        self.patch = patch
    }

    public var dotted: String { "\(major).\(minor).\(patch)" }

    public static func < (lhs: SemanticVersion, rhs: SemanticVersion) -> Bool {
        (lhs.major, lhs.minor, lhs.patch) < (rhs.major, rhs.minor, rhs.patch)
    }

    private static func number(_ part: Substring) -> Int? {
        guard !part.isEmpty, part.allSatisfy(\.isNumber), let value = Int(part), value >= 0 else { return nil }
        return value
    }
}
