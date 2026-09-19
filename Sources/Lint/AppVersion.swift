import Foundation

enum AppVersion {
    /// Single source of truth is CFBundleShortVersionString in Resources/Info.plist.
    static var short: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
    }

    static var build: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "0"
    }

    static var display: String { "版本 \(short)" }
}
