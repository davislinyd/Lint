import GRDB
import XCTest
@testable import LintCore

final class LearningStoreTests: XCTestCase {
    private func makeTempDirectory() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("LintLearningTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        return dir
    }

    private func memory(
        key: String = "spelling:en:prospective>perspective",
        state: MemoryState = .candidate,
        modeScope: WritingMode? = nil
    ) -> WritingMemory {
        WritingMemory(
            id: UUID(),
            dedupKey: key,
            kind: .spelling,
            language: "en",
            modeScope: modeScope,
            triggers: ["prospective"],
            instruction: "Check whether \"perspective\" was meant.",
            evidenceScore: 0.35,
            occurrenceCount: 2,
            state: state,
            userEdited: false,
            createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            lastConfirmedAt: Date(timeIntervalSince1970: 1_700_000_500)
        )
    }

    private func event(at seconds: TimeInterval, action: FeedbackAction = .accepted) -> FeedbackEvent {
        FeedbackEvent(
            id: UUID(),
            createdAt: Date(timeIntervalSince1970: seconds),
            mode: .proofread,
            action: action,
            sourceHMAC: "src",
            suggestionHMAC: "sug",
            finalHMAC: nil,
            provider: "localLlama",
            model: "qwen",
            usedMemoryIDs: [UUID()]
        )
    }

    func testMemoryRoundTripKeepsEveryField() async throws {
        let store = try SQLiteLearningStore(url: nil)
        let saved = memory(modeScope: .translate)
        try await store.saveMemory(saved)
        let loaded = try await store.memory(id: saved.id)
        XCTAssertEqual(loaded, saved)
        let byKey = try await store.memory(dedupKey: saved.dedupKey)
        XCTAssertEqual(byKey, saved)
    }

    func testSavingSameIDUpdatesInsteadOfDuplicating() async throws {
        let store = try SQLiteLearningStore(url: nil)
        var saved = memory()
        try await store.saveMemory(saved)
        saved.evidenceScore = 1.05
        saved.state = .active
        try await store.saveMemory(saved)
        let all = try await store.memories()
        XCTAssertEqual(all, [saved])
    }

    func testDedupKeyIsUniqueAcrossDifferentIDs() async throws {
        let store = try SQLiteLearningStore(url: nil)
        try await store.saveMemory(memory())
        do {
            try await store.saveMemory(memory())
            XCTFail("second memory with the same dedupKey should be rejected")
        } catch {}
        let count = try await store.memories().count
        XCTAssertEqual(count, 1)
    }

    func testDeleteMemory() async throws {
        let store = try SQLiteLearningStore(url: nil)
        let kept = memory(key: "grammar:en:articles")
        let dropped = memory()
        try await store.saveMemory(kept)
        try await store.saveMemory(dropped)
        try await store.deleteMemory(id: dropped.id)
        let remaining = try await store.memories()
        XCTAssertEqual(remaining, [kept])
    }

    func testMergeMemoryInsertsThenSeesTheExistingRow() async throws {
        let store = try SQLiteLearningStore(url: nil)
        let base = memory()
        try await store.mergeMemory(dedupKey: base.dedupKey) { existing in
            XCTAssertNil(existing)
            return base
        }
        try await store.mergeMemory(dedupKey: base.dedupKey) { existing in
            var updated = existing ?? base
            XCTAssertEqual(existing, base)
            updated.occurrenceCount += 1
            return updated
        }
        let all = try await store.memories()
        XCTAssertEqual(all.count, 1)
        XCTAssertEqual(all.first?.occurrenceCount, base.occurrenceCount + 1)
    }

    func testUpdateMemoryChangesOneRowAndIgnoresAMissingOne() async throws {
        let store = try SQLiteLearningStore(url: nil)
        let target = memory(key: "a")
        let other = memory(key: "b")
        try await store.saveMemory(target)
        try await store.saveMemory(other)
        try await store.updateMemory(id: target.id) { $0.state = .pinned }
        try await store.updateMemory(id: UUID()) { $0.state = .disabled }
        let pinned = try await store.memory(id: target.id)
        let untouched = try await store.memory(id: other.id)
        XCTAssertEqual(pinned?.state, .pinned)
        XCTAssertEqual(untouched, other)
    }

    func testUpdateMemoryByKeyChangesOnlyThatMemoryAndIgnoresAMissingKey() async throws {
        let store = try SQLiteLearningStore(url: nil)
        let target = memory(key: "spelling:en:a>b")
        let other = memory(key: "spelling:en:b>a")
        try await store.saveMemory(target)
        try await store.saveMemory(other)
        try await store.updateMemory(dedupKey: "spelling:en:a>b") { $0.evidenceScore = 0.1 }
        try await store.updateMemory(dedupKey: "spelling:en:missing>key") { $0.evidenceScore = 99 }
        let changed = try await store.memory(dedupKey: "spelling:en:a>b")
        let untouched = try await store.memory(dedupKey: "spelling:en:b>a")
        XCTAssertEqual(changed?.evidenceScore, 0.1)
        XCTAssertEqual(untouched, other)
        let count = try await store.memories().count
        XCTAssertEqual(count, 2, "nothing was created")
    }

    func testDeleteAllMemoriesKeepsEvents() async throws {
        let store = try SQLiteLearningStore(url: nil)
        try await store.saveMemory(memory(key: "a"))
        try await store.saveMemory(memory(key: "b"))
        try await store.insertEvent(event(at: 1), unlessDuplicateWithin: nil)
        try await store.deleteAllMemories()
        let stats = try await store.stats()
        XCTAssertEqual(stats.memoriesByState, [:])
        XCTAssertEqual(stats.eventCount, 1)
    }

    func testInsertEventsAndCount() async throws {
        let store = try SQLiteLearningStore(url: nil)
        try await store.insertEvent(event(at: 1), unlessDuplicateWithin: nil)
        try await store.insertEvent(event(at: 2, action: .editedAndAccepted), unlessDuplicateWithin: nil)
        let count = try await store.eventCount()
        XCTAssertEqual(count, 2)
    }

    func testDuplicateWithinWindowIsSkippedAndLaterOneIsKept() async throws {
        let store = try SQLiteLearningStore(url: nil)
        let hour: TimeInterval = 3_600
        let window = 24 * hour
        let first = try await store.insertEvent(event(at: 0), unlessDuplicateWithin: window)
        let sameDay = try await store.insertEvent(event(at: 12 * hour), unlessDuplicateWithin: window)
        let nextDay = try await store.insertEvent(event(at: 30 * hour), unlessDuplicateWithin: window)
        XCTAssertTrue(first)
        XCTAssertFalse(sameDay, "same source, action and (empty) final text within 24 h")
        XCTAssertTrue(nextDay)
        let count = try await store.eventCount()
        XCTAssertEqual(count, 2)
    }

    func testDedupeKeepsDifferentActionsAndFinalTexts() async throws {
        let store = try SQLiteLearningStore(url: nil)
        let window: TimeInterval = 24 * 3_600
        var edited = event(at: 0, action: .editedAndAccepted)
        edited.finalHMAC = "final-a"
        var otherFinal = event(at: 60, action: .editedAndAccepted)
        otherFinal.finalHMAC = "final-b"
        var otherAction = event(at: 120, action: .accepted)
        otherAction.finalHMAC = "final-a"
        var repeatedEdit = event(at: 180, action: .editedAndAccepted)
        repeatedEdit.finalHMAC = "final-a"

        let results = [
            try await store.insertEvent(edited, unlessDuplicateWithin: window),
            try await store.insertEvent(otherFinal, unlessDuplicateWithin: window),
            try await store.insertEvent(otherAction, unlessDuplicateWithin: window),
            try await store.insertEvent(repeatedEdit, unlessDuplicateWithin: window),
        ]
        XCTAssertEqual(results, [true, true, true, false])
    }

    func testPruneDropsOldEventsThenKeepsNewest() async throws {
        let store = try SQLiteLearningStore(url: nil)
        for seconds in [100, 200, 300, 400, 500] {
            try await store.insertEvent(event(at: TimeInterval(seconds)), unlessDuplicateWithin: nil)
        }
        try await store.pruneEvents(keepingLast: 10, olderThan: Date(timeIntervalSince1970: 250))
        let afterCutoff = try await store.eventCount()
        XCTAssertEqual(afterCutoff, 3)
        try await store.pruneEvents(keepingLast: 2, olderThan: Date(timeIntervalSince1970: 0))
        let afterCap = try await store.eventCount()
        XCTAssertEqual(afterCap, 2)
    }

    func testStatsCountsMemoriesByStateAndEvents() async throws {
        let store = try SQLiteLearningStore(url: nil)
        try await store.saveMemory(memory(key: "a", state: .candidate))
        try await store.saveMemory(memory(key: "b", state: .candidate))
        try await store.saveMemory(memory(key: "c", state: .active))
        try await store.insertEvent(event(at: 1), unlessDuplicateWithin: nil)
        let stats = try await store.stats()
        XCTAssertEqual(stats.count(.candidate), 2)
        XCTAssertEqual(stats.count(.active), 1)
        XCTAssertEqual(stats.count(.pinned), 0)
        XCTAssertEqual(stats.eventCount, 1)
    }

    func testResetAllEmptiesTheStoreAndStaysUsable() async throws {
        let store = try SQLiteLearningStore(url: nil)
        try await store.saveMemory(memory())
        try await store.insertEvent(event(at: 1), unlessDuplicateWithin: nil)
        try await store.resetAll()
        let stats = try await store.stats()
        XCTAssertEqual(stats, .empty)
        try await store.saveMemory(memory())
        let count = try await store.memories().count
        XCTAssertEqual(count, 1)
    }

    func testFileStorePersistsAcrossReopenAndMigratesOnlyOnce() async throws {
        let url = try makeTempDirectory().appendingPathComponent("LintLearning.sqlite")
        let saved = memory()
        do {
            let store = try SQLiteLearningStore(url: url)
            try await store.saveMemory(saved)
        }
        let reopened = try SQLiteLearningStore(url: url)
        let loaded = try await reopened.memory(id: saved.id)
        XCTAssertEqual(loaded, saved)
    }

    func testOpeningAnOlderDatabaseScrubsTheExampleSnippetsFromTheFile() async throws {
        let url = try makeTempDirectory().appendingPathComponent("LintLearning.sqlite")
        // A database as the first version left it: the snippet columns exist and hold stretches of text.
        do {
            let queue = try DatabaseQueue(path: url.path)
            try SQLiteLearningStore.migrator.migrate(queue, upTo: "v1_learning")
            try await queue.write { db in
                for index in 0..<300 {
                    try db.execute(
                        sql: """
                        INSERT INTO writing_memory (id, dedup_key, kind, language, triggers, instruction,
                            negative_example, preferred_example, evidence_score, occurrence_count, state,
                            user_edited, created_at, last_confirmed_at)
                        VALUES (?, ?, 'spelling', 'en', '["teh"]', 'Check the word.',
                            'quokka roster teh', 'quokka roster the', 1.2, 3, 'active', 0, 1700000000, 1700000500)
                        """,
                        arguments: [UUID().uuidString, "spelling:en:teh\(index)>the"]
                    )
                }
            }
        }
        let before = try Data(contentsOf: url)
        XCTAssertNotNil(before.range(of: Data("quokka".utf8)), "sanity: the snippets are in the file")

        let store = try SQLiteLearningStore(url: url)

        let memories = try await store.memories()
        XCTAssertEqual(memories.count, 300)
        XCTAssertEqual(memories.first?.triggers, ["teh"])
        XCTAssertEqual(memories.first?.evidenceScore, 1.2)
        let after = try Data(contentsOf: url)
        XCTAssertNil(after.range(of: Data("quokka".utf8)), "and gone from the file itself")
    }

    func testFileIsOwnerOnly() throws {
        let dir = try makeTempDirectory().appendingPathComponent("Lint", isDirectory: true)
        let url = dir.appendingPathComponent("LintLearning.sqlite")
        _ = try SQLiteLearningStore(url: url)
        func permissions(_ url: URL) throws -> Int {
            let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
            return (attributes[.posixPermissions] as? NSNumber)?.intValue ?? -1
        }
        XCTAssertEqual(try permissions(url), 0o600)
        XCTAssertEqual(try permissions(dir), 0o700)
    }

    // MARK: organizing memories

    private func dreamRun(
        status: DreamRunStatus = .completed, startedAt: TimeInterval = 1_800_000_000, finished: Bool = true
    ) -> DreamRun {
        DreamRun(
            id: UUID(),
            startedAt: Date(timeIntervalSince1970: startedAt),
            finishedAt: finished ? Date(timeIntervalSince1970: startedAt + 5) : nil,
            algorithmVersion: 1, inputMemoryCount: 40, clusterCount: 3, generatedCount: 1, supersededCount: 4,
            status: status
        )
    }

    /// A generalized parent and `count` specific memories that it stands in for, related in the file.
    private func makeFamily(
        in store: SQLiteLearningStore, url: URL, count: Int = 3, parentState: MemoryState = .active
    ) async throws -> (parent: WritingMemory, children: [WritingMemory]) {
        var parent = memory(key: "dream:test:parent", state: parentState)
        parent.level = .generalized
        try await store.saveMemory(parent)
        var children: [WritingMemory] = []
        for index in 0..<count {
            var child = memory(key: "grammar:en:verb\(index) about", state: .active)
            child.supersededBy = parent.id
            child.createdAt = Date(timeIntervalSince1970: 1_700_000_000 + Double(index))
            try await store.saveMemory(child)
            children.append(child)
        }
        let queue = try DatabaseQueue(path: url.path)
        let (parentID, childIDs) = (parent.id, children.map(\.id))
        try await queue.write { db in
            for childID in childIDs {
                try db.execute(
                    sql: """
                    INSERT INTO memory_relation (parent_id, child_id, relation, created_at)
                    VALUES (?, ?, 'summarizes', 1700000000)
                    """,
                    arguments: [parentID.uuidString, childID.uuidString]
                )
            }
        }
        return (parent, children)
    }

    private func count(_ table: String, in url: URL) throws -> Int {
        let queue = try DatabaseQueue(path: url.path)
        return try queue.read { db in try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM \(table)") ?? -1 }
    }

    private func makeFileStore() throws -> (store: SQLiteLearningStore, url: URL) {
        let url = try makeTempDirectory().appendingPathComponent("LintLearning.sqlite")
        return (try SQLiteLearningStore(url: url), url)
    }

    func testTheOrganizingFieldsRoundTrip() async throws {
        let store = try SQLiteLearningStore(url: nil)
        var saved = memory()
        saved.level = .core
        saved.supersededBy = UUID()
        saved.retrievalCount = 7
        saved.successfulUseCount = 4
        saved.contradictionCount = 2
        saved.lastUsedAt = Date(timeIntervalSince1970: 1_700_001_000)
        saved.lastConsolidatedAt = Date(timeIntervalSince1970: 1_700_002_000)
        try await store.saveMemory(saved)
        let loaded = try await store.memory(id: saved.id)
        XCTAssertEqual(loaded, saved)
    }

    func testAV1DatabaseUpgradesWithEveryMemoryDefaultedToSpecific() async throws {
        let url = try makeTempDirectory().appendingPathComponent("LintLearning.sqlite")
        let id = UUID()
        do {
            let queue = try DatabaseQueue(path: url.path)
            try SQLiteLearningStore.migrator.migrate(queue, upTo: "v1_learning")
            try await queue.write { db in
                try db.execute(
                    sql: """
                    INSERT INTO writing_memory (id, dedup_key, kind, language, mode_scope, triggers, instruction,
                        negative_example, preferred_example, evidence_score, occurrence_count, state,
                        user_edited, created_at, last_confirmed_at)
                    VALUES (?, 'grammar:en:discuss about', 'grammar', 'en', 'toneFormal', '["discuss about"]', 'Old rule.',
                        'x', 'y', 1.4, 4, 'pinned', 1, 1700000000, 1700000500)
                    """,
                    arguments: [id.uuidString]
                )
            }
        }

        let store = try SQLiteLearningStore(url: url)

        let loaded = try await store.memory(id: id)
        let memory = try XCTUnwrap(loaded)
        XCTAssertEqual(memory.level, .specific)
        XCTAssertNil(memory.supersededBy)
        XCTAssertEqual([memory.retrievalCount, memory.successfulUseCount, memory.contradictionCount], [0, 0, 0])
        XCTAssertNil(memory.lastUsedAt)
        XCTAssertNil(memory.lastConsolidatedAt)
        XCTAssertEqual(memory.evidenceScore, 1.4)
        XCTAssertEqual(memory.occurrenceCount, 4)
        XCTAssertEqual(memory.state, .pinned)
        XCTAssertEqual(memory.modeScope, .toneFormal)
        XCTAssertTrue(memory.userEdited)
        XCTAssertEqual(memory.triggers, ["discuss about"])
    }

    func testAV2DatabaseUpgradesAndTheNewTablesStartEmpty() async throws {
        let url = try makeTempDirectory().appendingPathComponent("LintLearning.sqlite")
        do {
            let queue = try DatabaseQueue(path: url.path)
            try SQLiteLearningStore.migrator.migrate(queue, upTo: "v2_drop_examples")
            try await queue.write { db in
                for index in 0..<3 {
                    try db.execute(
                        sql: """
                        INSERT INTO writing_memory (id, dedup_key, kind, language, triggers, instruction,
                            evidence_score, occurrence_count, state, user_edited, created_at, last_confirmed_at)
                        VALUES (?, ?, 'spelling', 'en', '["teh"]', 'Check the word.', 1.2, 3, 'active', 0,
                            1700000000, 1700000500)
                        """,
                        arguments: [UUID().uuidString, "spelling:en:teh\(index)>the"]
                    )
                }
            }
        }

        let store = try SQLiteLearningStore(url: url)

        let memories = try await store.memories()
        XCTAssertEqual(memories.count, 3)
        XCTAssertTrue(memories.allSatisfy { $0.level == .specific && $0.supersededBy == nil })
        let sourceCounts = try await store.sourceCounts()
        XCTAssertTrue(sourceCounts.isEmpty)
        let lastRun = try await store.lastCompletedDreamRun()
        XCTAssertNil(lastRun)
        let stats = try await store.stats()
        XCTAssertEqual(stats.count(.specific), 3)
        XCTAssertEqual(stats.supersededCount, 0)
        XCTAssertNil(stats.lastOrganizedAt)
    }

    func testADatabaseWithANewerMigrationStillOpensForAnOlderMigrator() throws {
        let (_, url) = try makeFileStore()
        // What the 0.2.0 build knows about: it must not refuse a file that has gone further.
        var older = DatabaseMigrator()
        older.registerMigration("v1_learning") { _ in }
        older.registerMigration("v2_drop_examples") { _ in }
        let queue = try DatabaseQueue(path: url.path)
        XCTAssertNoThrow(try older.migrate(queue))
    }

    func testDeletingAParentKeepsItsSourcesAndFreesThem() async throws {
        let (store, url) = try makeFileStore()
        let family = try await makeFamily(in: store, url: url)

        try await store.deleteMemory(id: family.parent.id)

        let remaining = try await store.memories()
        XCTAssertEqual(remaining.map(\.id).sorted { $0.uuidString < $1.uuidString },
                       family.children.map(\.id).sorted { $0.uuidString < $1.uuidString })
        XCTAssertTrue(remaining.allSatisfy { $0.supersededBy == nil }, "nothing stays hidden behind a deleted parent")
        XCTAssertEqual(try count("memory_relation", in: url), 0)
        let vetoed = try await store.isVetoed(dedupKey: family.parent.dedupKey)
        XCTAssertTrue(vetoed)
    }

    func testDeletingASourceLeavesTheParentAndTheOtherSources() async throws {
        let (store, url) = try makeFileStore()
        let family = try await makeFamily(in: store, url: url)

        try await store.deleteMemory(id: family.children[0].id)

        let sources = try await store.sources(ofParent: family.parent.id)
        XCTAssertEqual(sources.map(\.id), family.children.dropFirst().map(\.id))
        let parent = try await store.memory(id: family.parent.id)
        XCTAssertEqual(parent?.level, .generalized)
        let vetoed = try await store.isVetoed(dedupKey: family.children[0].dedupKey)
        XCTAssertFalse(vetoed, "only a derived memory is remembered as deleted")
    }

    func testDeletingASpecificMemoryLeavesNoVeto() async throws {
        let store = try SQLiteLearningStore(url: nil)
        let plain = memory()
        try await store.saveMemory(plain)
        try await store.deleteMemory(id: plain.id)
        let vetoed = try await store.isVetoed(dedupKey: plain.dedupKey)
        XCTAssertFalse(vetoed)
    }

    func testDeletingAMemoryThatIsGoneDoesNothing() async throws {
        let store = try SQLiteLearningStore(url: nil)
        try await store.deleteMemory(id: UUID())
        let memories = try await store.memories()
        XCTAssertTrue(memories.isEmpty)
    }

    func testClearingAllMemoriesClearsRelationsAndVetoesButKeepsEvents() async throws {
        let (store, url) = try makeFileStore()
        let family = try await makeFamily(in: store, url: url)
        try await store.deleteMemory(id: family.parent.id)
        try await store.insertEvent(event(at: 1_700_000_000), unlessDuplicateWithin: nil)

        try await store.deleteAllMemories()

        XCTAssertEqual(try count("memory_relation", in: url), 0)
        XCTAssertEqual(try count("dream_veto", in: url), 0)
        let events = try await store.eventCount()
        XCTAssertEqual(events, 1)
    }

    func testResetAllClearsTheOrganizingRecords() async throws {
        let (store, url) = try makeFileStore()
        let family = try await makeFamily(in: store, url: url)
        try await store.deleteMemory(id: family.parent.id)
        try await store.recordDreamRun(dreamRun())

        try await store.resetAll()

        XCTAssertEqual(try count("dream_run", in: url), 0)
        XCTAssertEqual(try count("dream_veto", in: url), 0)
        XCTAssertEqual(try count("memory_relation", in: url), 0)
        let lastRun = try await store.lastCompletedDreamRun()
        XCTAssertNil(lastRun)
    }

    func testSourcesAreListedOldestFirstAndCountedPerParent() async throws {
        let (store, url) = try makeFileStore()
        let family = try await makeFamily(in: store, url: url, count: 4)

        let sources = try await store.sources(ofParent: family.parent.id)
        XCTAssertEqual(sources.map(\.id), family.children.map(\.id))
        let counts = try await store.sourceCounts()
        XCTAssertEqual(counts, [family.parent.id: 4])
        let none = try await store.sources(ofParent: UUID())
        XCTAssertTrue(none.isEmpty)
    }

    func testDreamRunsRoundTripAndOnlyACompletedOneCountsAsTheLast() async throws {
        let store = try SQLiteLearningStore(url: nil)
        var running = dreamRun(status: .running, startedAt: 1_800_000_000, finished: false)
        try await store.recordDreamRun(running)
        let whileRunning = try await store.lastCompletedDreamRun()
        XCTAssertNil(whileRunning)

        running.status = .completed
        running.finishedAt = Date(timeIntervalSince1970: 1_800_000_009)
        try await store.recordDreamRun(running)
        let completed = try await store.lastCompletedDreamRun()
        XCTAssertEqual(completed, running, "the same id is updated, not added")

        try await store.recordDreamRun(dreamRun(status: .failed, startedAt: 1_800_100_000))
        try await store.recordDreamRun(dreamRun(status: .cancelled, startedAt: 1_800_200_000))
        let older = dreamRun(status: .completed, startedAt: 1_700_000_000)
        try await store.recordDreamRun(older)
        let last = try await store.lastCompletedDreamRun()
        XCTAssertEqual(last, running, "the newest completed one, whatever else has happened since")
    }

    func testStatsCountLevelsCoveredMemoriesAndTheLastOrganizingPass() async throws {
        let (store, url) = try makeFileStore()
        let family = try await makeFamily(in: store, url: url, count: 3)
        // One more, covered by a parent that cannot be used.
        var faded = memory(key: "dream:test:faded", state: .archived)
        faded.level = .core
        try await store.saveMemory(faded)
        var orphan = memory(key: "grammar:en:orphan about")
        orphan.supersededBy = faded.id
        try await store.saveMemory(orphan)
        try await store.recordDreamRun(dreamRun(startedAt: 1_800_000_000))

        let stats = try await store.stats()

        XCTAssertEqual(stats.count(.specific), 4)
        XCTAssertEqual(stats.count(.generalized), 1)
        XCTAssertEqual(stats.count(.core), 1)
        XCTAssertEqual(stats.supersededCount, family.children.count, "a memory behind an unusable parent is not covered")
        XCTAssertEqual(stats.lastOrganizedAt, Date(timeIntervalSince1970: 1_800_000_005))
    }

    // MARK: applying a consolidation

    private func derivedMemory(_ key: String = "dream:test") -> WritingMemory {
        var parent = DreamFixtures.plain(key, kind: .grammar)
        parent.level = .generalized
        return parent
    }

    private func relationRows(_ url: URL) throws -> Int {
        try count("memory_relation", in: url)
    }

    func testApplyingAConsolidationStoresTheParentRelatesItAndCoversTheSources() async throws {
        let (store, url) = try makeFileStore()
        let sources = DreamFixtures.prepositions(3)
        for source in sources { try await store.saveMemory(source) }
        let parent = derivedMemory()

        let outcome = try await store.applyConsolidation(
            parentDedupKey: parent.dedupKey, sourceIDs: sources.map(\.id), at: DreamFixtures.now
        ) { application in
            XCTAssertNil(application.existingParent)
            XCTAssertEqual(application.sources, sources)
            XCTAssertTrue(application.linkedSourceIDs.isEmpty)
            return parent
        }

        XCTAssertEqual(outcome, .applied(parentID: parent.id, created: true, newlyCovered: 3))
        let stored = try await store.memory(id: parent.id)
        XCTAssertEqual(stored, parent)
        let related = try await store.sources(ofParent: parent.id)
        XCTAssertEqual(Set(related.map(\.id)), Set(sources.map(\.id)))
        XCTAssertTrue(related.allSatisfy { $0.supersededBy == parent.id && $0.lastConsolidatedAt == DreamFixtures.now })
        XCTAssertEqual(try relationRows(url), 3)
    }

    func testTheSourcesAreHandedOverInTheOrderAskedFor() async throws {
        let store = try SQLiteLearningStore(url: nil)
        let sources = DreamFixtures.prepositions(3)
        for source in sources { try await store.saveMemory(source) }
        let reversed = sources.reversed().map(\.id)
        let parent = derivedMemory()

        _ = try await store.applyConsolidation(
            parentDedupKey: parent.dedupKey, sourceIDs: reversed, at: DreamFixtures.now
        ) { application in
            XCTAssertEqual(application.sources.map(\.id), reversed)
            return parent
        }
    }

    func testASourceThatChangedSinceItWasChosenStopsTheWholeConsolidation() async throws {
        let cases: [(String, (inout WritingMemory) -> Void)] = [
            ("pinned", { $0.state = .pinned }),
            ("disabled", { $0.state = .disabled }),
            ("no longer active", { $0.state = .candidate }),
            ("hand-edited", { $0.userEdited = true }),
            ("already generalized", { $0.level = .generalized }),
        ]
        for (name, change) in cases {
            let (store, url) = try makeFileStore()
            var sources = DreamFixtures.prepositions(3)
            change(&sources[1])
            for source in sources { try await store.saveMemory(source) }
            let before = try await store.memories()

            let outcome = try await store.applyConsolidation(
                parentDedupKey: "dream:test", sourceIDs: sources.map(\.id), at: DreamFixtures.now
            ) { _ in XCTFail("\(name): nothing should be built"); return nil }

            XCTAssertEqual(outcome, .skipped(.sourceChanged), name)
            let after = try await store.memories()
            XCTAssertEqual(after, before, name)
            XCTAssertEqual(try relationRows(url), 0, name)
        }

        let store = try SQLiteLearningStore(url: nil)
        let sources = DreamFixtures.prepositions(3)
        for source in sources.dropLast() { try await store.saveMemory(source) }
        let gone = try await store.applyConsolidation(
            parentDedupKey: "dream:test", sourceIDs: sources.map(\.id), at: DreamFixtures.now
        ) { _ in nil }
        XCTAssertEqual(gone, .skipped(.sourceChanged), "a source that has been deleted")
    }

    func testASourceBehindAnotherUsableMemoryIsLeftThereButNotBehindOneThatIsNot() async throws {
        for (coverState, expected) in [(MemoryState.active, false), (.pinned, false), (.archived, true), (.disabled, true), (.candidate, true)] {
            let store = try SQLiteLearningStore(url: nil)
            let other = { var other = derivedMemory("dream:other"); other.state = coverState; return other }()
            try await store.saveMemory(other)
            var sources = DreamFixtures.prepositions(3)
            sources[0].supersededBy = other.id
            for source in sources { try await store.saveMemory(source) }
            let parent = derivedMemory()

            let outcome = try await store.applyConsolidation(
                parentDedupKey: parent.dedupKey, sourceIDs: sources.map(\.id), at: DreamFixtures.now
            ) { _ in parent }

            if expected {
                XCTAssertEqual(outcome, .applied(parentID: parent.id, created: true, newlyCovered: 3), "\(coverState)")
            } else {
                XCTAssertEqual(outcome, .skipped(.sourceChanged), "\(coverState)")
            }
        }
    }

    func testAMemoryTheUserDeletedIsNotStoredAgain() async throws {
        let (store, url) = try makeFileStore()
        let sources = DreamFixtures.prepositions(3)
        for source in sources { try await store.saveMemory(source) }
        let parent = derivedMemory()
        _ = try await store.applyConsolidation(
            parentDedupKey: parent.dedupKey, sourceIDs: sources.map(\.id), at: DreamFixtures.now
        ) { _ in parent }
        try await store.deleteMemory(id: parent.id)
        let before = try await store.memories()

        let outcome = try await store.applyConsolidation(
            parentDedupKey: parent.dedupKey, sourceIDs: sources.map(\.id), at: DreamFixtures.now
        ) { _ in XCTFail("nothing should be built"); return nil }

        XCTAssertEqual(outcome, .skipped(.vetoed))
        let after = try await store.memories()
        XCTAssertEqual(after, before)
        XCTAssertEqual(try relationRows(url), 0)
    }

    func testNothingIsWrittenWhenThereIsNothingToBuildOrItCannotBeKept() async throws {
        let (store, url) = try makeFileStore()
        let sources = DreamFixtures.prepositions(3)
        for source in sources { try await store.saveMemory(source) }
        let before = try await store.memories()

        let declined = try await store.applyConsolidation(
            parentDedupKey: "dream:test", sourceIDs: sources.map(\.id), at: DreamFixtures.now
        ) { _ in nil }
        XCTAssertEqual(declined, .skipped(.declined))
        // A derived memory is never a specific one.
        let specific = try await store.applyConsolidation(
            parentDedupKey: "dream:test", sourceIDs: sources.map(\.id), at: DreamFixtures.now
        ) { _ in DreamFixtures.plain("dream:test") }
        XCTAssertEqual(specific, .skipped(.declined))

        let after = try await store.memories()
        XCTAssertEqual(after, before)
        XCTAssertEqual(try relationRows(url), 0)
    }

    func testTheStoredMemoryKeepsItsKeyAndTheIdentityOfTheOneThatExists() async throws {
        let (store, url) = try makeFileStore()
        let first = DreamFixtures.prepositions(3)
        for source in first { try await store.saveMemory(source) }
        let parent = derivedMemory()
        _ = try await store.applyConsolidation(
            parentDedupKey: parent.dedupKey, sourceIDs: first.map(\.id), at: DreamFixtures.now
        ) { _ in
            var wrongKey = parent
            wrongKey.dedupKey = "grammar:en:something else"
            return wrongKey
        }
        let stored = try await store.memory(dedupKey: "dream:test")
        XCTAssertEqual(stored?.id, parent.id, "stored under the key it was asked for")

        let late = DreamFixtures.preposition("describe")
        try await store.saveMemory(late)
        let outcome = try await store.applyConsolidation(
            parentDedupKey: parent.dedupKey, sourceIDs: (first + [late]).map(\.id), at: DreamFixtures.now
        ) { application in
            XCTAssertEqual(application.existingParent?.id, parent.id)
            XCTAssertEqual(application.linkedSourceIDs, Set(first.map(\.id)))
            var other = parent
            other.id = UUID()
            other.instruction = "joined"
            return other
        }

        XCTAssertEqual(outcome, .applied(parentID: parent.id, created: false, newlyCovered: 1))
        let all = try await store.memories().filter { $0.level != .specific }
        XCTAssertEqual(all.map(\.id), [parent.id], "no second copy")
        XCTAssertEqual(all.first?.instruction, "joined")
        XCTAssertEqual(try relationRows(url), 4)
    }
}
