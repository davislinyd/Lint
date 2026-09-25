import CryptoKit
import Foundation

/// Entry point for remembering and dreaming. Everything here runs off the main actor, and a
/// disabled feature never touches the disk.
public actor MemoryCoordinator {
    /// Keychain account. The name stays so hashes already on disk still match.
    private static let hmacKeyAccount = "learning.hmacKey"

    private let storeURL: URL?
    private let hmacKeyProvider: @Sendable () throws -> Data
    private var store: (any MemoryStore)?
    private var hmacKey: SymmetricKey?
    private let clock: @Sendable () -> Date
    private var retriever: MemoryRetriever?
    private var retrieverBuiltAt = Date.distantPast
    /// Bumped by every change to the memories, so a read that raced with a change is not cached.
    private var memoryVersion = 0
    /// Whether the user is waiting on a suggestion (see `setInteractiveActivity`). Held outside the
    /// actor, so that reporting it never waits for anything the coordinator is busy with.
    private let gate = InteractiveGate()
    private let organizingSleep: @Sendable (Duration) async throws -> Void
    private var organizer: MemoryDreamCoordinator?
    private var scheduler: DreamScheduler?
    /// Memory is on, so dreaming may run in the background.
    private var organizingAllowed = false

    /// Longest instruction a memory keeps, however it was edited.
    public static let maxInstructionLength = MemoryPolicy.maxInstructionLength

    /// `~/Library/Application Support/Lint/LintLearning.sqlite`
    public static var defaultStoreURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Lint", isDirectory: true)
            .appendingPathComponent("LintLearning.sqlite")
    }

    /// `storeURL == nil` keeps everything in memory (tests).
    public init(storeURL: URL? = MemoryCoordinator.defaultStoreURL) {
        self.init(storeURL: storeURL, hmacKey: { try MemoryCoordinator.keychainHMACKey() })
    }

    init(
        storeURL: URL?,
        hmacKey: @escaping @Sendable () throws -> Data,
        clock: @escaping @Sendable () -> Date = { Date() },
        organizingSleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }
    ) {
        self.storeURL = storeURL
        self.hmacKeyProvider = hmacKey
        self.clock = clock
        self.organizingSleep = organizingSleep
    }

    /// Creates and migrates the database when memory is on, trims old events and asks for the
    /// memories to be dreamed when that is due. Does nothing otherwise.
    public func prepare(config: MemoryConfig) async {
        organizingAllowed = config.enabled
        guard config.enabled else {
            await scheduler?.cancelPending()
            return
        }
        guard let store = openStore(create: true) else { return }
        let cutoff = clock().addingTimeInterval(-Double(MemoryPolicy.eventRetentionDays) * 86_400)
        do {
            try await store.pruneEvents(keepingLast: MemoryPolicy.eventRetentionCount, olderThan: cutoff)
        } catch {
            NSLog("Lint memory: prune failed: \(error.localizedDescription)")
        }
        let lastPass = (try? await store.lastCompletedDreamRun())?.finishedAt
        await scheduler?.noteStartup(lastCompletedPass: lastPass)
        await noteMemoryPressure(store: store)
    }

    /// Records what the user did with a suggestion. Nothing is kept while memory is off, or when
    /// the suggestion never finished generating.
    public func recordFeedback(_ feedback: MemoryFeedback, config: MemoryConfig) async {
        organizingAllowed = config.enabled
        guard config.enabled, feedback.canFormMemory,
              let key = symmetricKey(),
              let store = openStore(create: true),
              let event = FeedbackCollector(key: key).event(for: feedback, now: clock())
        else { return }
        do {
            let inserted = try await store.insertEvent(
                event, unlessDuplicateWithin: MemoryPolicy.eventDedupeWindow
            )
            await scheduler?.noteActivity()
            // A repeat of the same feedback is not new evidence.
            if inserted {
                let changes = await remember(from: feedback, action: event.action, at: event.createdAt, store: store)
                if changes > 0 {
                    await scheduler?.noteChanges(changes)
                    await noteMemoryPressure(store: store)
                }
            }
        } catch {
            NSLog("Lint memory: could not record feedback: \(error.localizedDescription)")
        }
    }

    /// `prompt` with the memories relevant to `text` added at its end, and the memories used.
    /// It comes back untouched while memory is off or nothing is relevant, and also when this
    /// takes longer than `timeout`: a suggestion must never wait on the memory. An `english`
    /// prompt gets them worded in English.
    public nonisolated func personalize(
        prompt: String,
        for text: String,
        mode: WritingMode,
        tone: WritingTone = .preserve,
        english: Bool = false,
        translationLanguage: TranslationLanguage = .traditionalChinese,
        config: MemoryConfig,
        timeout: Duration = .milliseconds(150)
    ) async -> PersonalizedPrompt {
        let unchanged = PersonalizedPrompt(systemPrompt: prompt, usedMemoryIDs: [])
        guard config.enabled else { return unchanged }
        return await withTimeout(timeout, fallback: unchanged) {
            let memories = await self.relevantMemories(
                for: text,
                mode: mode,
                tone: tone,
                outputLanguage: mode == .translate ? translationLanguage.rawValue : nil,
                config: config
            )
            return PromptComposer.compose(base: prompt, memories: memories, english: english)
        }
    }

    /// The few memories worth reminding the model about for this text: short-term, long-term or
    /// pinned ones whose trigger is in it, plus general habits that fit its language. Empty while
    /// memory is off.
    /// `outputLanguage` is the language written when it differs from the text's (translation).
    public func relevantMemories(
        for text: String,
        mode: WritingMode,
        tone: WritingTone = .preserve,
        outputLanguage: String? = nil,
        config: MemoryConfig
    ) async -> [WritingMemory] {
        guard config.enabled, let store = openStore(create: false) else { return [] }
        let query = MemoryRetriever.Query(text: text, mode: mode, tone: tone, outputLanguage: outputLanguage)
        let now = clock()
        // Evidence keeps fading and short-term memories run out, so an old retriever is rebuilt
        // even if nothing changed.
        if let retriever, now.timeIntervalSince(retrieverBuiltAt) < MemoryPolicy.retrieverMaxAge {
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
            NSLog("Lint memory: could not read memories: \(error.localizedDescription)")
            return []
        }
    }

    /// Every memory as it stands now (see `MemoryLifecycle.settled`), which can be ahead of what was
    /// last written: dreaming is what writes it down.
    public func memories() async -> [WritingMemory] {
        guard let store = openStore(create: false) else { return [] }
        do {
            let now = clock()
            return try await store.memories().map { MemoryLifecycle.settled($0, at: now) }
        } catch {
            NSLog("Lint memory: could not read memories: \(error.localizedDescription)")
            return []
        }
    }

    /// Says whether the user is waiting on a suggestion right now. Dreaming does not
    /// start while they are, or shortly after, and one that is running gives way. Does not wait.
    public nonisolated func setInteractiveActivity(_ active: Bool) {
        gate.set(active)
    }

    /// Dreams now, on the user's request: it does not wait for a quiet moment. Only
    /// what is on this Mac is used, and nothing is started or downloaded for it.
    public func dream(config: MemoryConfig) async -> DreamOutcome {
        guard config.enabled, openStore(create: false) != nil, let organizer else { return .unavailable }
        let run = await organizer.run()
        invalidateMemories()
        guard let run else { return .alreadyRunning }
        guard run.status == .completed else { return .failed }
        await scheduler?.didRun()
        return .finished(
            remembered: run.rememberedCount, forgotten: run.forgottenCount, erased: run.erasedCount,
            newRules: run.generatedCount, coveredMemories: run.supersededCount
        )
    }

    /// How many memories each generalized or core memory was derived from.
    public func sourceCounts() async -> [UUID: Int] {
        guard let store = openStore(create: false) else { return [:] }
        do {
            return try await store.sourceCounts()
        } catch {
            NSLog("Lint memory: could not read the sources: \(error.localizedDescription)")
            return [:]
        }
    }

    /// The specific memories a generalized or core memory was derived from, oldest first.
    public func sources(of id: UUID) async -> [WritingMemory] {
        guard let store = openStore(create: false) else { return [] }
        do {
            return try await store.sources(ofParent: id)
        } catch {
            NSLog("Lint memory: could not read the sources: \(error.localizedDescription)")
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
                .prefix(MemoryPolicy.maxInstructionLength)
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
            NSLog("Lint memory: could not delete a memory: \(error.localizedDescription)")
        }
    }

    public func deleteAllMemories() async {
        guard let store = openStore(create: false) else { return }
        do {
            try await store.deleteAllMemories()
            invalidateMemories()
        } catch {
            NSLog("Lint memory: could not clear memories: \(error.localizedDescription)")
        }
    }

    /// Reads whatever is on disk, also while memory is off, so the data stays visible. The memories
    /// are counted as they stand now, like `memories()`.
    public func stats() async -> MemoryStats {
        guard let store = openStore(create: false) else { return .empty }
        do {
            var stats = try await store.stats()
            let now = clock()
            let current = try await store.memories().map { MemoryLifecycle.settled($0, at: now) }
            stats.memoriesByState = Dictionary(grouping: current, by: \.state).mapValues(\.count)
            stats.memoriesByLevel = Dictionary(grouping: current, by: \.level).mapValues(\.count)
            let rulesInUse = Set(current.filter { $0.level != .specific && MemoryLifecycle.isUsed($0) }.map(\.id))
            stats.supersededCount = current.filter { $0.supersededBy.map(rulesInUse.contains) ?? false }.count
            return stats
        } catch {
            NSLog("Lint memory: stats failed: \(error.localizedDescription)")
            return .empty
        }
    }

    /// Wipes all memories and events, also while memory is off.
    public func resetAll() async {
        guard let store = openStore(create: false) else { return }
        do {
            try await store.resetAll()
            invalidateMemories()
        } catch {
            NSLog("Lint memory: reset failed: \(error.localizedDescription)")
        }
    }

    /// Returns how many memories were remembered or weakened: what counts towards a dream.
    private func remember(
        from feedback: MemoryFeedback,
        action: FeedbackAction,
        at now: Date,
        store: any MemoryStore
    ) async -> Int {
        let weight = MemoryPolicy.evidenceWeight(for: action)
        guard weight > 0 else { return 0 }
        await countUse(of: feedback.usedMemoryIDs, at: now, store: store)
        let extractor = MemoryExtractor()
        let injected = await injectedPatterns(feedback.usedMemoryIDs, store: store)
        let extraction = extractor.extraction(from: feedback, action: action, injected: Set(injected.keys))
        let against = MemoryPolicy.contradictionWeight(for: action)
        var changed = false
        var changes = 0
        for candidate in extraction.candidates {
            do {
                try await store.mergeMemory(dedupKey: candidate.dedupKey) { existing in
                    MemoryLifecycle.merging(
                        candidate, weight: weight, at: now,
                        into: existing.map { MemoryLifecycle.settled($0, at: now) }
                    )
                }
                changed = true
                changes += 1
                // Seen again, so seen again by the rule that stands in for it too.
                if await support(parentOf: candidate.dedupKey, weight: weight, at: now, store: store) {
                    changed = true
                }
            } catch {
                NSLog("Lint memory: could not update a memory: \(error.localizedDescription)")
            }
            // Wanting `b` where a memory asks for `a` is evidence against that memory.
            if let opposite = MemoryExtractor.reversedKey(of: candidate.dedupKey),
               await weaken(opposite, by: against, at: now, store: store) {
                changed = true
                changes += 1
            }
        }
        for key in extraction.contradicted where await weaken(key, by: against, at: now, store: store) {
            changed = true
            changes += 1
        }
        // The habit was still there, and the model handled it as reminded: keep the memory alive,
        // and count the reminder as having worked for whichever memory in the prompt gave it.
        for key in extraction.reminded {
            do {
                try await store.updateMemory(dedupKey: key) { memory in
                    memory = MemoryLifecycle.refreshed(MemoryLifecycle.settled(memory, at: now), at: now)
                }
                changed = true
            } catch {
                NSLog("Lint memory: could not refresh a memory: \(error.localizedDescription)")
            }
            for id in injected[key] ?? [] where await creditSuccess(id, at: now, store: store) {
                changed = true
            }
        }
        if changed { invalidateMemories() }
        return changes
    }

    /// Memories that are candidates or in use pile up: dreaming may thin them out.
    private func noteMemoryPressure(store: any MemoryStore) async {
        guard let stats = try? await store.stats() else { return }
        await scheduler?.notePressure(memories: stats.count(.candidate) + stats.count(.active))
    }

    /// The scheduled pass: not while memory is off, and it gives way to the user.
    private func runScheduledOrganizing() async -> DreamRunStatus? {
        guard organizingAllowed, let organizer else { return .completed }
        let run = await organizer.run(yieldingTo: gate)
        invalidateMemories()
        return run?.status
    }

    /// The suggestion that carried these memories was used, so they were: counted once each. That
    /// says nothing about the text, and changes nothing about what is retrieved.
    private func countUse(of ids: [UUID], at now: Date, store: any MemoryStore) async {
        for id in Set(ids) {
            do {
                try await store.updateMemory(id: id) { memory in
                    memory.retrievalCount += 1
                    memory.lastUsedAt = now
                }
            } catch {
                NSLog("Lint memory: could not count the use of a memory: \(error.localizedDescription)")
            }
        }
    }

    /// The model applied what the memory reminded it of and the user accepted that. A generalized
    /// or core memory that gave the reminder is kept alive by it, as a specific one is.
    private func creditSuccess(_ id: UUID, at now: Date, store: any MemoryStore) async -> Bool {
        do {
            try await store.updateMemory(id: id) { memory in
                memory.successfulUseCount += 1
                if memory.level != .specific { memory = MemoryLifecycle.refreshed(memory, at: now) }
            }
            return true
        } catch {
            NSLog("Lint memory: could not count a successful use: \(error.localizedDescription)")
            return false
        }
    }

    /// A specific memory was seen again: so was the pattern of the generalized or core memory that
    /// stands in for it, as long as that one is in use (not forgotten or switched off). False if
    /// nothing was written.
    private func support(parentOf dedupKey: String, weight: Double, at now: Date, store: any MemoryStore) async -> Bool {
        guard let parentID = (try? await store.memory(dedupKey: dedupKey))?.supersededBy else { return false }
        do {
            try await store.updateMemory(id: parentID) { memory in
                let current = MemoryLifecycle.settled(memory, at: now)
                guard MemoryLifecycle.isUsed(current) else { return }
                memory = MemoryLifecycle.supported(current, weight: weight, at: now)
            }
            return true
        } catch {
            NSLog("Lint memory: could not update a rule: \(error.localizedDescription)")
            return false
        }
    }

    /// Does nothing if there is no such memory. False if it could not be written. What goes against a
    /// memory goes against the rule that stands in for it too.
    private func weaken(_ dedupKey: String, by amount: Double, at now: Date, store: any MemoryStore) async -> Bool {
        do {
            let parentID = try await store.memory(dedupKey: dedupKey)?.supersededBy
            try await store.updateMemory(dedupKey: dedupKey) { memory in
                memory = MemoryLifecycle.weakened(MemoryLifecycle.settled(memory, at: now), by: amount, at: now)
            }
            if let parentID {
                try await store.updateMemory(id: parentID) { memory in
                    memory = MemoryLifecycle.weakened(MemoryLifecycle.settled(memory, at: now), by: amount, at: now)
                }
            }
            return true
        } catch {
            NSLog("Lint memory: could not weaken a memory: \(error.localizedDescription)")
            return false
        }
    }

    /// The patterns (by `dedupKey`) the prompt reminded the model of, each with the memories that gave
    /// the reminder: the memory of that pattern itself, and any generalized or core memory that
    /// stands in for it. A memory deleted since is simply not counted.
    private func injectedPatterns(_ ids: [UUID], store: any MemoryStore) async -> [String: Set<UUID>] {
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

    /// What the user acts on is the memory as it stands now, which is what Settings showed them.
    private func change(_ id: UUID, _ transform: @escaping @Sendable (inout WritingMemory) -> Void) async {
        guard let store = openStore(create: false) else { return }
        let now = clock()
        do {
            try await store.updateMemory(id: id) { memory in
                memory = MemoryLifecycle.settled(memory, at: now)
                transform(&memory)
            }
            invalidateMemories()
        } catch {
            NSLog("Lint memory: could not change a memory: \(error.localizedDescription)")
        }
    }

    private func symmetricKey() -> SymmetricKey? {
        if let hmacKey { return hmacKey }
        do {
            let key = SymmetricKey(data: try hmacKeyProvider())
            hmacKey = key
            return key
        } catch {
            NSLog("Lint memory: no HMAC key: \(error)")
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

    private func openStore(create: Bool) -> (any MemoryStore)? {
        if let store { return store }
        if !create, let storeURL, !FileManager.default.fileExists(atPath: storeURL.path) {
            return nil
        }
        do {
            let opened = try SQLiteMemoryStore(url: storeURL)
            store = opened
            organizer = MemoryDreamCoordinator(store: opened, clock: clock)
            scheduler = DreamScheduler(gate: gate, clock: clock, sleep: organizingSleep) { [weak self] in
                await self?.runScheduledOrganizing()
            }
            return opened
        } catch {
            NSLog("Lint memory: cannot open store: \(error.localizedDescription)")
            return nil
        }
    }
}
