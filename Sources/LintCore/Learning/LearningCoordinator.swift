import Foundation

/// Entry point of the learning subsystem. Everything here runs off the main actor, and a
/// disabled feature never touches the disk.
public actor LearningCoordinator {
    private let storeURL: URL?
    private var store: (any LearningStore)?

    /// `~/Library/Application Support/Lint/LintLearning.sqlite`
    public static var defaultStoreURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Lint", isDirectory: true)
            .appendingPathComponent("LintLearning.sqlite")
    }

    /// `storeURL == nil` keeps everything in memory (tests).
    public init(storeURL: URL? = LearningCoordinator.defaultStoreURL) {
        self.storeURL = storeURL
    }

    /// Creates and migrates the database when learning is on, and trims old events.
    /// Does nothing otherwise.
    public func prepare(config: LearningConfig) async {
        guard config.enabled, let store = openStore(create: true) else { return }
        let cutoff = Date(timeIntervalSinceNow: -Double(LearningPolicy.eventRetentionDays) * 86_400)
        do {
            try await store.pruneEvents(keepingLast: LearningPolicy.eventRetentionCount, olderThan: cutoff)
        } catch {
            NSLog("Lint learning: prune failed: \(error.localizedDescription)")
        }
    }

    /// Reads whatever is on disk, also while learning is off, so the data stays visible.
    public func stats() async -> LearningStats {
        guard let store = openStore(create: false) else { return .empty }
        do {
            return try await store.stats()
        } catch {
            NSLog("Lint learning: stats failed: \(error.localizedDescription)")
            return .empty
        }
    }

    /// Wipes all memories and events, also while learning is off.
    public func resetAll() async {
        guard let store = openStore(create: false) else { return }
        do {
            try await store.resetAll()
        } catch {
            NSLog("Lint learning: reset failed: \(error.localizedDescription)")
        }
    }

    private func openStore(create: Bool) -> (any LearningStore)? {
        if let store { return store }
        if !create, let storeURL, !FileManager.default.fileExists(atPath: storeURL.path) {
            return nil
        }
        do {
            let opened = try SQLiteLearningStore(url: storeURL)
            store = opened
            return opened
        } catch {
            NSLog("Lint learning: cannot open store: \(error.localizedDescription)")
            return nil
        }
    }
}
