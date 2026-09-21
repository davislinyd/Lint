import Foundation

/// Where Lint keeps large, downloaded data. Never inside the signed Lint.app.
///
///     ~/Library/Application Support/Lint/
///         Models/<model id>/…        installed models (complete and verified)
///         Downloads/<model id>/…     in-progress downloads (`*.partial`) and verified files waiting to be installed
public struct LocalAIPaths: Equatable, Sendable {
    public var root: URL

    public init(root: URL) {
        self.root = root
    }

    /// `~/Library/Application Support/Lint`. `LINT_APP_SUPPORT_DIR` points it somewhere else, which is
    /// how a development build is tried out without touching the real models and downloads.
    public static func standard(environment: [String: String] = ProcessInfo.processInfo.environment) -> LocalAIPaths {
        if let override = environment["LINT_APP_SUPPORT_DIR"], override.hasPrefix("/") {
            return LocalAIPaths(root: URL(fileURLWithPath: override, isDirectory: true))
        }
        return LocalAIPaths(
            root: FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("Lint", isDirectory: true)
        )
    }

    public var modelsDirectory: URL { root.appendingPathComponent("Models", isDirectory: true) }
    public var downloadsDirectory: URL { root.appendingPathComponent("Downloads", isDirectory: true) }

    public func installDirectory(for model: ModelDescriptor) -> URL {
        modelsDirectory.appendingPathComponent(model.id, isDirectory: true)
    }

    public func stagingDirectory(for model: ModelDescriptor) -> URL {
        downloadsDirectory.appendingPathComponent(model.id, isDirectory: true)
    }
}
