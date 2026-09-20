import CryptoKit
import Foundation

/// Entry point of the learning subsystem. Everything here runs off the main actor, and a
/// disabled feature never touches the disk.
public actor LearningCoordinator {
    private static let hmacKeyAccount = "learning.hmacKey"

    private let storeURL: URL?
    private let hmacKeyProvider: @Sendable () throws -> Data
    private var store: (any LearningStore)?
    private var hmacKey: SymmetricKey?
    private var retriever: MemoryRetriever?
    /// Bumped by every change to the memories, so a read that raced with a change is not cached.
    private var memoryVersion = 0

    /// Longest instruction a memory keeps, however it was edited.
    public static let maxInstructionLength = LearningPolicy.maxInstructionLength

    /// `~/Library/Application Support/Lint/LintLearning.sqlite`
    public static var defaultStoreURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Lint", isDirectory: true)
            .appendingPathComponent("LintLearning.sqlite")
    }

    /// `storeURL == nil` keeps everything in memory (tests).
    public init(storeURL: URL? = LearningCoordinator.defaultStoreURL) {
        self.init(storeURL: storeURL, hmacKey: { try LearningCoordinator.keychainHMACKey() })
    }

    init(storeURL: URL?, hmacKey: @escaping @Sendable () throws -> Data) {
        self.storeURL = storeURL
        self.hmacKeyProvider = hmacKey
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

    /// Records what the user did with a suggestion. Nothing is kept while learning is off, or when
    /// the suggestion never finished generating.
    public func recordFeedback(_ feedback: LearningFeedback, config: LearningConfig) async {
        guard config.enabled, feedback.isLearnable,
              let key = symmetricKey(),
              let store = openStore(create: true),
              let event = FeedbackCollector(key: key).event(for: feedback, now: Date())
        else { return }
        do {
            let inserted = try await store.insertEvent(
                event, unlessDuplicateWithin: LearningPolicy.eventDedupeWindow
            )
            // A repeat of the same feedback is not new evidence.
            if inserted {
                await learn(from: feedback, action: event.action, config: config, at: event.createdAt, store: store)
            }
        } catch {
            NSLog("Lint learning: could not record feedback: \(error.localizedDescription)")
        }
    }

    /// The few memories worth reminding the model about for this text: active or pinned ones whose
    /// trigger is in it, plus general habits that fit its language. Empty while learning is off.
    /// `outputLanguage` is the language written when it differs from the text's (translation).
    public func relevantMemories(
        for text: String,
        mode: WritingMode,
        outputLanguage: String? = nil,
        config: LearningConfig
    ) async -> [WritingMemory] {
        guard config.enabled, let store = openStore(create: false) else { return [] }
        let query = MemoryRetriever.Query(text: text, mode: mode, outputLanguage: outputLanguage)
        if let retriever { return retriever.select(for: query) }
        let versionBeforeReading = memoryVersion
        do {
            let fresh = MemoryRetriever(memories: try await store.memories())
            if versionBeforeReading == memoryVersion { retriever = fresh }
            return fresh.select(for: query)
        } catch {
            NSLog("Lint learning: could not read memories: \(error.localizedDescription)")
            return []
        }
    }

    public func memories() async -> [WritingMemory] {
        guard let store = openStore(create: false) else { return [] }
        do {
            return try await store.memories()
        } catch {
            NSLog("Lint learning: could not read memories: \(error.localizedDescription)")
            return []
        }
    }

    /// Pinned memories are always eligible; unpinning returns one to the state its evidence earns.
    public func setPinned(_ pinned: Bool, id: UUID) async {
        await change(id) { memory in
            memory.state = pinned ? .pinned : MemoryLifecycle.restingState(evidenceScore: memory.evidenceScore)
        }
    }

    public func setEnabled(_ enabled: Bool, id: UUID) async {
        await change(id) { memory in
            memory.state = enabled ? MemoryLifecycle.restingState(evidenceScore: memory.evidenceScore) : .disabled
        }
    }

    /// The user's own wording replaces the generated one, and is never overwritten by new evidence.
    public func setInstruction(_ text: String, id: UUID) async {
        let cleaned = String(
            text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
                .prefix(LearningPolicy.maxInstructionLength)
        )
        guard !cleaned.isEmpty else { return }
        await change(id) { memory in
            memory.instruction = cleaned
            memory.userEdited = true
        }
    }

    public func deleteMemory(id: UUID) async {
        guard let store = openStore(create: false) else { return }
        do {
            try await store.deleteMemory(id: id)
            invalidateMemories()
        } catch {
            NSLog("Lint learning: could not delete a memory: \(error.localizedDescription)")
        }
    }

    public func deleteAllMemories() async {
        guard let store = openStore(create: false) else { return }
        do {
            try await store.deleteAllMemories()
            invalidateMemories()
        } catch {
            NSLog("Lint learning: could not clear memories: \(error.localizedDescription)")
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
            invalidateMemories()
        } catch {
            NSLog("Lint learning: reset failed: \(error.localizedDescription)")
        }
    }

    private func learn(
        from feedback: LearningFeedback,
        action: FeedbackAction,
        config: LearningConfig,
        at now: Date,
        store: any LearningStore
    ) async {
        let weight = LearningPolicy.evidenceWeight(for: action)
        guard weight > 0 else { return }
        let extractor = MemoryExtractor(storeExamples: config.storeExamples)
        for candidate in extractor.candidates(from: feedback, action: action) {
            do {
                try await store.mergeMemory(dedupKey: candidate.dedupKey) { existing in
                    MemoryLifecycle.merging(candidate, weight: weight, at: now, into: existing)
                }
                invalidateMemories()
            } catch {
                NSLog("Lint learning: could not update a memory: \(error.localizedDescription)")
            }
        }
    }

    private func invalidateMemories() {
        retriever = nil
        memoryVersion += 1
    }

    private func change(_ id: UUID, _ transform: @escaping @Sendable (inout WritingMemory) -> Void) async {
        guard let store = openStore(create: false) else { return }
        do {
            try await store.updateMemory(id: id, transform)
            invalidateMemories()
        } catch {
            NSLog("Lint learning: could not change a memory: \(error.localizedDescription)")
        }
    }

    private func symmetricKey() -> SymmetricKey? {
        if let hmacKey { return hmacKey }
        do {
            let key = SymmetricKey(data: try hmacKeyProvider())
            hmacKey = key
            return key
        } catch {
            NSLog("Lint learning: no HMAC key: \(error)")
            return nil
        }
    }

    /// One random key per install, kept in the Keychain rather than next to the data it protects.
    private static func keychainHMACKey() throws -> Data {
        let keychain = KeychainStore()
        if let stored = try keychain.get(account: hmacKeyAccount),
           let data = Data(base64Encoded: stored), data.count == 32 {
            return data
        }
        let data = SymmetricKey(size: .bits256).withUnsafeBytes { Data($0) }
        try keychain.set(data.base64EncodedString(), account: hmacKeyAccount)
        return data
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
