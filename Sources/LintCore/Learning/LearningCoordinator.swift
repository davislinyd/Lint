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
    private let clock: @Sendable () -> Date
    private var retriever: MemoryRetriever?
    private var retrieverBuiltAt = Date.distantPast
    /// Bumped by every change to the memories, so a read that raced with a change is not cached.
    private var memoryVersion = 0
    private var lastSettled: Date?

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

    init(
        storeURL: URL?,
        hmacKey: @escaping @Sendable () throws -> Data,
        clock: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.storeURL = storeURL
        self.hmacKeyProvider = hmacKey
        self.clock = clock
    }

    /// Creates and migrates the database when learning is on, trims old events and archives
    /// memories that have faded. Does nothing otherwise.
    public func prepare(config: LearningConfig) async {
        guard config.enabled, let store = openStore(create: true) else { return }
        let cutoff = clock().addingTimeInterval(-Double(LearningPolicy.eventRetentionDays) * 86_400)
        do {
            try await store.pruneEvents(keepingLast: LearningPolicy.eventRetentionCount, olderThan: cutoff)
        } catch {
            NSLog("Lint learning: prune failed: \(error.localizedDescription)")
        }
        await settleIfDue(store: store)
    }

    /// Records what the user did with a suggestion. Nothing is kept while learning is off, or when
    /// the suggestion never finished generating.
    public func recordFeedback(_ feedback: LearningFeedback, config: LearningConfig) async {
        guard config.enabled, feedback.isLearnable,
              let key = symmetricKey(),
              let store = openStore(create: true),
              let event = FeedbackCollector(key: key).event(for: feedback, now: clock())
        else { return }
        do {
            let inserted = try await store.insertEvent(
                event, unlessDuplicateWithin: LearningPolicy.eventDedupeWindow
            )
            // A repeat of the same feedback is not new evidence.
            if inserted {
                await learn(from: feedback, action: event.action, at: event.createdAt, store: store)
            }
        } catch {
            NSLog("Lint learning: could not record feedback: \(error.localizedDescription)")
        }
    }

    /// `prompt` with the memories relevant to `text` added at its end, and the memories used.
    /// It comes back untouched while learning is off or nothing is relevant, and also when this
    /// takes longer than `timeout`: a suggestion must never wait on the learning.
    /// `translateTarget` only matters in translation, where it says which language is written.
    public nonisolated func personalize(
        prompt: String,
        for text: String,
        mode: WritingMode,
        translateTarget: String = "",
        config: LearningConfig,
        timeout: Duration = .milliseconds(150)
    ) async -> PersonalizedPrompt {
        let unchanged = PersonalizedPrompt(systemPrompt: prompt, usedMemoryIDs: [])
        guard config.enabled else { return unchanged }
        return await withTimeout(timeout, fallback: unchanged) {
            let memories = await self.relevantMemories(
                for: text,
                mode: mode,
                outputLanguage: mode == .translate ? TextProfile.languageTag(forTarget: translateTarget) : nil,
                config: config
            )
            return PromptComposer.compose(base: prompt, memories: memories)
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
        let now = clock()
        // Evidence keeps fading, so a day-old retriever is rebuilt even if nothing changed.
        if let retriever, now.timeIntervalSince(retrieverBuiltAt) < LearningPolicy.settleInterval {
            return retriever.select(for: query)
        }
        let versionBeforeReading = memoryVersion
        do {
            let fresh = MemoryRetriever(memories: try await store.memories(), now: now)
            if versionBeforeReading == memoryVersion {
                retriever = fresh
                retrieverBuiltAt = now
            }
            return fresh.select(for: query)
        } catch {
            NSLog("Lint learning: could not read memories: \(error.localizedDescription)")
            return []
        }
    }

    public func memories() async -> [WritingMemory] {
        guard let store = openStore(create: false) else { return [] }
        await settleIfDue(store: store)
        do {
            return try await store.memories()
        } catch {
            NSLog("Lint learning: could not read memories: \(error.localizedDescription)")
            return []
        }
    }

    /// Pinned memories are always eligible and do not fade. Unpinning returns one to the state its
    /// evidence earns, fading again from now.
    public func setPinned(_ pinned: Bool, id: UUID) async {
        let now = clock()
        await change(id) { memory in
            memory = pinned
                ? MemoryLifecycle.held(memory, as: .pinned, at: now)
                : MemoryLifecycle.resumed(memory, at: now)
        }
    }

    /// Enabling also restores a memory that had faded away and been archived.
    public func setEnabled(_ enabled: Bool, id: UUID) async {
        let now = clock()
        await change(id) { memory in
            memory = enabled
                ? MemoryLifecycle.resumed(memory, at: now)
                : MemoryLifecycle.held(memory, as: .disabled, at: now)
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
        await settleIfDue(store: store)
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
        at now: Date,
        store: any LearningStore
    ) async {
        let weight = LearningPolicy.evidenceWeight(for: action)
        guard weight > 0 else { return }
        await countUse(of: feedback.usedMemoryIDs, at: now, store: store)
        let extractor = MemoryExtractor()
        let injected = await injectedPatterns(feedback.usedMemoryIDs, store: store)
        let extraction = extractor.extraction(from: feedback, action: action, injected: Set(injected.keys))
        let against = LearningPolicy.contradictionWeight(for: action)
        var changed = false
        for candidate in extraction.candidates {
            do {
                try await store.mergeMemory(dedupKey: candidate.dedupKey) { existing in
                    MemoryLifecycle.merging(candidate, weight: weight, at: now, into: existing)
                }
                changed = true
                // Seen again, so seen again by the rule that stands in for it too.
                if await support(parentOf: candidate.dedupKey, weight: weight, at: now, store: store) {
                    changed = true
                }
            } catch {
                NSLog("Lint learning: could not update a memory: \(error.localizedDescription)")
            }
            // Wanting `b` where a memory asks for `a` is evidence against that memory.
            if let opposite = MemoryExtractor.reversedKey(of: candidate.dedupKey),
               await weaken(opposite, by: against, at: now, store: store) {
                changed = true
            }
        }
        for key in extraction.contradicted where await weaken(key, by: against, at: now, store: store) {
            changed = true
        }
        // The habit was still there, and the model handled it as reminded: keep the memory alive,
        // and count the reminder as having worked for whichever memory in the prompt gave it.
        for key in extraction.reminded {
            do {
                try await store.updateMemory(dedupKey: key) { memory in
                    memory = MemoryLifecycle.refreshed(memory, at: now)
                }
                changed = true
            } catch {
                NSLog("Lint learning: could not refresh a memory: \(error.localizedDescription)")
            }
            for id in injected[key] ?? [] where await creditSuccess(id, at: now, store: store) {
                changed = true
            }
        }
        if changed { invalidateMemories() }
    }

    /// The suggestion that carried these memories was used, so they were: counted once each. That
    /// says nothing about the text, and changes nothing about what is retrieved.
    private func countUse(of ids: [UUID], at now: Date, store: any LearningStore) async {
        for id in Set(ids) {
            do {
                try await store.updateMemory(id: id) { memory in
                    memory.retrievalCount += 1
                    memory.lastUsedAt = now
                }
            } catch {
                NSLog("Lint learning: could not count the use of a memory: \(error.localizedDescription)")
            }
        }
    }

    /// The model applied what the memory reminded it of and the user accepted that. A generalized
    /// or core memory that gave the reminder is kept alive by it, as a specific one is.
    private func creditSuccess(_ id: UUID, at now: Date, store: any LearningStore) async -> Bool {
        do {
            try await store.updateMemory(id: id) { memory in
                memory.successfulUseCount += 1
                if memory.level != .specific { memory = MemoryLifecycle.refreshed(memory, at: now) }
            }
            return true
        } catch {
            NSLog("Lint learning: could not count a successful use: \(error.localizedDescription)")
            return false
        }
    }

    /// A specific memory was seen again: so was the pattern of the generalized or core memory that
    /// stands in for it, as long as that one is not put away or switched off. False if nothing
    /// was written.
    private func support(parentOf dedupKey: String, weight: Double, at now: Date, store: any LearningStore) async -> Bool {
        guard let parentID = (try? await store.memory(dedupKey: dedupKey))?.supersededBy else { return false }
        do {
            try await store.updateMemory(id: parentID) { memory in
                guard memory.state == .candidate || memory.state == .active || memory.state == .pinned else { return }
                memory = MemoryLifecycle.supported(memory, weight: weight, at: now)
            }
            return true
        } catch {
            NSLog("Lint learning: could not update a rule: \(error.localizedDescription)")
            return false
        }
    }

    /// Does nothing if there is no such memory. False if it could not be written. What goes against a
    /// memory goes against the rule that stands in for it too.
    private func weaken(_ dedupKey: String, by amount: Double, at now: Date, store: any LearningStore) async -> Bool {
        do {
            let parentID = try await store.memory(dedupKey: dedupKey)?.supersededBy
            try await store.updateMemory(dedupKey: dedupKey) { memory in
                memory = MemoryLifecycle.weakened(memory, by: amount, at: now)
            }
            if let parentID {
                try await store.updateMemory(id: parentID) { memory in
                    memory = MemoryLifecycle.weakened(memory, by: amount, at: now)
                }
            }
            return true
        } catch {
            NSLog("Lint learning: could not weaken a memory: \(error.localizedDescription)")
            return false
        }
    }

    /// Archives the memories that have faded away and turns faded active ones back into candidates,
    /// at most once a day. (Retrieval judges fading by itself, so this only keeps what is stored,
    /// and shown, up to date.)
    private func settleIfDue(store: any LearningStore) async {
        let now = clock()
        if let lastSettled, now.timeIntervalSince(lastSettled) < LearningPolicy.settleInterval { return }
        lastSettled = now
        do {
            var changed = false
            for memory in try await store.memories() where MemoryLifecycle.settled(memory, at: now) != memory {
                try await store.updateMemory(id: memory.id) { memory in
                    memory = MemoryLifecycle.settled(memory, at: now)
                }
                changed = true
            }
            if changed { invalidateMemories() }
        } catch {
            NSLog("Lint learning: settling memories failed: \(error.localizedDescription)")
        }
    }

    /// The patterns (by `dedupKey`) the prompt reminded the model of, each with the memories that gave
    /// the reminder: the memory of that pattern itself, and any generalized or core memory that
    /// stands in for it. A memory deleted since is simply not counted.
    private func injectedPatterns(_ ids: [UUID], store: any LearningStore) async -> [String: Set<UUID>] {
        var patterns: [String: Set<UUID>] = [:]
        for id in ids {
            guard let memory = try? await store.memory(id: id) else { continue }
            patterns[memory.dedupKey, default: []].insert(id)
            guard memory.level != .specific else { continue }
            for source in (try? await store.sources(ofParent: id)) ?? [] {
                patterns[source.dedupKey, default: []].insert(id)
            }
        }
        return patterns
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
