import Foundation

public enum LiveCheckDecision: Equatable, Sendable {
    case skipDisabled
    case skipDenylisted
    case skipSecure
    case skipTooShort
    case allow
}

public enum LiveCheckPolicy {
    public static let minimumCharacters = 8

    /// Password managers and the system password UI. Checked against the app on this Mac or the
    /// vendor's own bundle ID. A banking site in a browser is not on this list.
    public static let denylistedBundleIDs: Set<String> = [
        "com.1password.1password",
        "com.agilebits.onepassword7",
        "com.bitwarden.desktop",
        "org.keepassxc.keepassxc",
        "com.apple.Passwords",
        "com.apple.keychainaccess",
    ]

    /// Missing means the toggle was never turned off: on, as it always was. A stored value is kept.
    public static func enabledValue(stored: Bool?) -> Bool {
        stored ?? true
    }

    public static func shouldPoll(watchSelection: Bool, watchTyping: Bool) -> Bool {
        watchSelection || watchTyping
    }

    public static func isDenylisted(_ bundleID: String?) -> Bool {
        guard let bundleID else { return false }
        return denylistedBundleIDs.contains(bundleID)
    }

    public static func blocksReading(bundleID: String?, isSecure: Bool) -> Bool {
        isSecure || isDenylisted(bundleID)
    }

    public static func decide(
        featureEnabled: Bool,
        bundleID: String?,
        isSecure: Bool,
        characterCount: Int
    ) -> LiveCheckDecision {
        guard featureEnabled else { return .skipDisabled }
        if isSecure { return .skipSecure }
        if isDenylisted(bundleID) { return .skipDenylisted }
        if characterCount < minimumCharacters { return .skipTooShort }
        return .allow
    }
}
