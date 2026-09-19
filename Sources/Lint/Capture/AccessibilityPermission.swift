import AppKit
import ApplicationServices

enum AccessibilityPermission {
    static var isTrusted: Bool {
        AXIsProcessTrusted()
    }

    /// Path the user must enable in System Settings → Privacy → Accessibility.
    static var currentAppPath: String {
        Bundle.main.bundleURL.path
    }

    static func prompt() {
        // String key avoids Swift 6 concurrency warning on kAXTrustedCheckOptionPrompt.
        let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        AXIsProcessTrustedWithOptions(options)
    }

    /// Opens the Accessibility privacy pane when possible.
    /// Do not use `x-apple.systemsettings:...` on newer macOS — it can show a
    /// Finder "no application to open URL" sheet even when open returns false.
    @discardableResult
    static func openSystemSettings() -> Bool {
        let deepLinks = [
            "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility",
            "x-apple.systempreferences:com.apple.preference.security",
        ]
        for raw in deepLinks {
            if let url = URL(string: raw), NSWorkspace.shared.open(url) {
                return true
            }
        }

        let appCandidates = [
            URL(fileURLWithPath: "/System/Applications/System Settings.app"),
            URL(fileURLWithPath: "/Applications/System Settings.app"),
        ]
        for appURL in appCandidates where FileManager.default.fileExists(atPath: appURL.path) {
            if NSWorkspace.shared.open(appURL) {
                return true
            }
        }

        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.systempreferences") {
            return NSWorkspace.shared.open(url)
        }
        return false
    }
}
