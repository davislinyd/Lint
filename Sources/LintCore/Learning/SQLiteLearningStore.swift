import Foundation
import GRDB

enum LearningStoreError: Error {
    case cannotCreateFile(URL)
    case invalidRow(String)
}

/// Column names are snake_case, dates are epoch seconds and IDs are text, so the file stays
/// readable with the `sqlite3` CLI.
struct SQLiteLearningStore: LearningStore {
    private let dbQueue: DatabaseQueue

    /// `url == nil` keeps the database in memory (tests).
    init(url: URL?) throws {
        var configuration = Configuration()
        configuration.label = "LintLearning"
        // A deleted memory should not linger in the file's free pages.
        configuration.prepareDatabase { db in
            try db.execute(sql: "PRAGMA secure_delete = ON")
        }
        if let url {
            let fileManager = FileManager.default
            try fileManager.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            if !fileManager.fileExists(atPath: url.path) {
                // Created owner-only up front; SQLite would otherwise apply the umask default.
                guard fileManager.createFile(
                    atPath: url.path, contents: nil, attributes: [.posixPermissions: 0o600]
                ) else {
                    throw LearningStoreError.cannotCreateFile(url)
                }
            }
            dbQueue = try DatabaseQueue(path: url.path, configuration: configuration)
        } else {
            dbQueue = try DatabaseQueue(configuration: configuration)
        }
        try Self.migrator.migrate(dbQueue)
    }

    static var migrator: DatabaseMigrator {
        var migrator = DatabaseMigrator()
        migrator.registerMigration("v1_learning") { db in
            try db.create(table: "writing_memory") { t in
                t.column("id", .text).primaryKey()
                t.column("dedup_key", .text).notNull().unique()
                t.column("kind", .text).notNull()
                t.column("language", .text).notNull()
                t.column("mode_scope", .text)
                t.column("triggers", .text).notNull()
                t.column("instruction", .text).notNull()
                t.column("negative_example", .text)
                t.column("preferred_example", .text)
                t.column("evidence_score", .double).notNull()
                t.column("occurrence_count", .integer).notNull()
                t.column("state", .text).notNull()
                t.column("user_edited", .boolean).notNull()
                t.column("created_at", .double).notNull()
                t.column("last_confirmed_at", .double).notNull()
            }
            try db.create(table: "feedback_event") { t in
                t.column("id", .text).primaryKey()
                t.column("created_at", .double).notNull().indexed()
                t.column("mode", .text).notNull()
                t.column("action", .text).notNull()
                t.column("source_hmac", .text).notNull()
                t.column("suggestion_hmac", .text)
                t.column("final_hmac", .text)
                t.column("provider", .text).notNull()
                t.column("model", .text).notNull()
                t.column("used_memory_ids", .text).notNull()
            }
        }
        // Memories once kept a short stretch of the user's own words as an example. Nothing ever used
        // them, so they are gone. Dropping the columns rewrites the rows, and the old snippets leave
        // the file with them (`LearningStoreTests` checks the bytes).
        migrator.registerMigration("v2_drop_examples") { db in
            try db.alter(table: "writing_memory") { t in
                t.drop(column: "negative_example")
                t.drop(column: "preferred_example")
            }
        }
        // Organizing memories: a memory gets a level and usage counters, and a generalized memory
        // keeps a record of the specific ones it stands in for. Every new column has a default, so an
        // existing database loads as it was (all `specific`). The relation rows go with either end
        // of the relation, but deleting a parent never deletes what it was derived from.
        migrator.registerMigration("v3_dreaming") { db in
            try db.alter(table: "writing_memory") { t in
                t.add(column: "level", .text).notNull().defaults(to: MemoryLevel.specific.rawValue)
                t.add(column: "superseded_by", .text)
                t.add(column: "retrieval_count", .integer).notNull().defaults(to: 0)
                t.add(column: "successful_use_count", .integer).notNull().defaults(to: 0)
                t.add(column: "contradiction_count", .integer).notNull().defaults(to: 0)
                t.add(column: "last_used_at", .double)
                t.add(column: "last_consolidated_at", .double)
            }
            try db.create(index: "writing_memory_superseded_by", on: "writing_memory", columns: ["superseded_by"])
            try db.create(table: "memory_relation") { t in
                t.column("parent_id", .text).notNull().references("writing_memory", onDelete: .cascade)
                t.column("child_id", .text).notNull().references("writing_memory", onDelete: .cascade)
                t.column("relation", .text).notNull()
                t.column("created_at", .double).notNull()
                t.primaryKey(["parent_id", "child_id"])
            }
            try db.create(index: "memory_relation_child", on: "memory_relation", columns: ["child_id"])
            // Numbers only, never text.
            try db.create(table: "dream_run") { t in
                t.column("id", .text).primaryKey()
                t.column("started_at", .double).notNull()
                t.column("finished_at", .double)
                t.column("algorithm_version", .integer).notNull()
                t.column("input_memory_count", .integer).notNull()
                t.column("cluster_count", .integer).notNull()
                t.column("generated_count", .integer).notNull()
                t.column("superseded_count", .integer).notNull()
                t.column("status", .text).notNull()
            }
            // Patterns the user deleted after they were derived; a `dedup_key`, never any text.
            try db.create(table: "dream_veto") { t in
                t.column("dedup_key", .text).primaryKey()
                t.column("created_at", .double).notNull()
            }
        }
        return migrator
    }

    func saveMemory(_ memory: WritingMemory) async throws {
        try await dbQueue.write { db in
            try MemoryRecord(memory).save(db)
        }
    }

    func mergeMemory(dedupKey: String, _ transform: @escaping @Sendable (WritingMemory?) -> WritingMemory) async throws {
        try await dbQueue.write { db in
            let existing = try MemoryRecord.filter(Column("dedup_key") == dedupKey).fetchOne(db)?.memory
            try MemoryRecord(transform(existing)).save(db)
        }
    }

    func updateMemory(id: UUID, _ transform: @escaping @Sendable (inout WritingMemory) -> Void) async throws {
        try await dbQueue.write { db in
            guard var memory = try MemoryRecord.fetchOne(db, key: id.uuidString)?.memory else { return }
            transform(&memory)
            try MemoryRecord(memory).save(db)
        }
    }

    func updateMemory(dedupKey: String, _ transform: @escaping @Sendable (inout WritingMemory) -> Void) async throws {
        try await dbQueue.write { db in
            guard var memory = try MemoryRecord.filter(Column("dedup_key") == dedupKey).fetchOne(db)?.memory
            else { return }
            transform(&memory)
            try MemoryRecord(memory).save(db)
        }
    }

    func memory(id: UUID) async throws -> WritingMemory? {
        try await dbQueue.read { db in
            try MemoryRecord.fetchOne(db, key: id.uuidString)?.memory
        }
    }

    func memory(dedupKey: String) async throws -> WritingMemory? {
        try await dbQueue.read { db in
            try MemoryRecord.filter(Column("dedup_key") == dedupKey).fetchOne(db)?.memory
        }
    }

    func memories() async throws -> [WritingMemory] {
        try await dbQueue.read { db in
            try MemoryRecord.order(Column("created_at")).fetchAll(db).map(\.memory)
        }
    }

    func deleteMemory(id: UUID) async throws {
        try await dbQueue.write { db in
            guard let memory = try MemoryRecord.fetchOne(db, key: id.uuidString)?.memory else { return }
            if memory.level != .specific {
                try db.execute(
                    sql: "INSERT OR IGNORE INTO dream_veto (dedup_key, created_at) VALUES (?, ?)",
                    arguments: [memory.dedupKey, Date().timeIntervalSince1970]
                )
            }
            // The memories it stood in for must not stay hidden behind something that is gone.
            try db.execute(
                sql: "UPDATE writing_memory SET superseded_by = NULL WHERE superseded_by = ?",
                arguments: [id.uuidString]
            )
            _ = try MemoryRecord.deleteOne(db, key: id.uuidString)
        }
    }

    func deleteAllMemories() async throws {
        try await dbQueue.write { db in
            try db.execute(sql: "DELETE FROM writing_memory")
            try db.execute(sql: "DELETE FROM dream_veto")
        }
    }

    func sources(ofParent parentID: UUID) async throws -> [WritingMemory] {
        try await dbQueue.read { db in
            try MemoryRecord.fetchAll(
                db,
                sql: """
                SELECT m.* FROM writing_memory m
                    JOIN memory_relation r ON r.child_id = m.id
                    WHERE r.parent_id = ?
                    ORDER BY m.created_at, m.id
                """,
                arguments: [parentID.uuidString]
            ).map(\.memory)
        }
    }

    func sourceCounts() async throws -> [UUID: Int] {
        try await dbQueue.read { db in
            var counts: [UUID: Int] = [:]
            let rows = try Row.fetchAll(
                db, sql: "SELECT parent_id, COUNT(*) AS n FROM memory_relation GROUP BY parent_id"
            )
            for row in rows {
                let parent: String = row["parent_id"]
                if let id = UUID(uuidString: parent) { counts[id] = row["n"] }
            }
            return counts
        }
    }

    func isVetoed(dedupKey: String) async throws -> Bool {
        try await dbQueue.read { db in
            try Bool.fetchOne(
                db,
                sql: "SELECT EXISTS(SELECT 1 FROM dream_veto WHERE dedup_key = ?)",
                arguments: [dedupKey]
            ) ?? false
        }
    }

    func recordDreamRun(_ run: DreamRun) async throws {
        try await dbQueue.write { db in
            try DreamRunRecord(run).save(db)
        }
    }

    func lastCompletedDreamRun() async throws -> DreamRun? {
        try await dbQueue.read { db in
            try DreamRunRecord.fetchOne(
                db,
                sql: """
                SELECT * FROM dream_run WHERE status = ? AND finished_at IS NOT NULL
                    ORDER BY finished_at DESC LIMIT 1
                """,
                arguments: [DreamRunStatus.completed.rawValue]
            )?.run
        }
    }

    @discardableResult
    func insertEvent(_ event: FeedbackEvent, unlessDuplicateWithin window: TimeInterval?) async throws -> Bool {
        try await dbQueue.write { db in
            if let window {
                let duplicate = try Bool.fetchOne(
                    db,
                    sql: """
                    SELECT EXISTS(SELECT 1 FROM feedback_event
                        WHERE source_hmac = ? AND action = ? AND final_hmac IS ? AND created_at >= ?)
                    """,
                    arguments: [
                        event.sourceHMAC, event.action.rawValue, event.finalHMAC,
                        event.createdAt.timeIntervalSince1970 - window,
                    ]
                ) ?? false
                if duplicate { return false }
            }
            try EventRecord(event).insert(db)
            return true
        }
    }

    func eventCount() async throws -> Int {
        try await dbQueue.read { db in
            try EventRecord.fetchCount(db)
        }
    }

    func pruneEvents(keepingLast maxCount: Int, olderThan cutoff: Date) async throws {
        try await dbQueue.write { db in
            try db.execute(
                sql: "DELETE FROM feedback_event WHERE created_at < ?",
                arguments: [cutoff.timeIntervalSince1970]
            )
            try db.execute(
                sql: """
                DELETE FROM feedback_event WHERE id NOT IN
                    (SELECT id FROM feedback_event ORDER BY created_at DESC LIMIT ?)
                """,
                arguments: [maxCount]
            )
        }
    }

    func stats() async throws -> LearningStats {
        try await dbQueue.read { db in
            var counts: [MemoryState: Int] = [:]
            let rows = try Row.fetchAll(
                db, sql: "SELECT state, COUNT(*) AS n FROM writing_memory GROUP BY state"
            )
            for row in rows {
                let raw: String = row["state"]
                if let state = MemoryState(rawValue: raw) {
                    counts[state] = row["n"]
                }
            }
            var levels: [MemoryLevel: Int] = [:]
            for row in try Row.fetchAll(
                db, sql: "SELECT level, COUNT(*) AS n FROM writing_memory GROUP BY level"
            ) {
                let raw: String = row["level"]
                if let level = MemoryLevel(rawValue: raw) {
                    levels[level] = row["n"]
                }
            }
            // Counted by what is usable now, so a memory whose parent has faded is not "covered".
            let superseded = try Int.fetchOne(
                db,
                sql: """
                SELECT COUNT(*) FROM writing_memory child
                    JOIN writing_memory parent ON child.superseded_by = parent.id
                    WHERE parent.state IN (?, ?)
                """,
                arguments: [MemoryState.active.rawValue, MemoryState.pinned.rawValue]
            ) ?? 0
            let lastOrganized = try Double.fetchOne(
                db,
                sql: "SELECT MAX(finished_at) FROM dream_run WHERE status = ?",
                arguments: [DreamRunStatus.completed.rawValue]
            )
            return LearningStats(
                memoriesByState: counts,
                eventCount: try EventRecord.fetchCount(db),
                memoriesByLevel: levels,
                supersededCount: superseded,
                lastOrganizedAt: lastOrganized.map { Date(timeIntervalSince1970: $0) }
            )
        }
    }

    func resetAll() async throws {
        try await dbQueue.write { db in
            try db.execute(sql: "DELETE FROM writing_memory")
            try db.execute(sql: "DELETE FROM feedback_event")
            try db.execute(sql: "DELETE FROM dream_run")
            try db.execute(sql: "DELETE FROM dream_veto")
        }
        try await dbQueue.vacuum()
    }
}

// MARK: - Rows

private struct MemoryRecord: FetchableRecord, PersistableRecord {
    static let databaseTableName = "writing_memory"

    var memory: WritingMemory

    init(_ memory: WritingMemory) {
        self.memory = memory
    }

    init(row: Row) throws {
        let id: String = row["id"]
        let kind: String = row["kind"]
        let state: String = row["state"]
        let modeScope: String? = row["mode_scope"]
        let triggers: String = row["triggers"]
        let level: String = row["level"]
        let supersededBy: String? = row["superseded_by"]
        guard let uuid = UUID(uuidString: id),
              let kind = MemoryKind(rawValue: kind),
              let state = MemoryState(rawValue: state),
              let level = MemoryLevel(rawValue: level)
        else {
            throw LearningStoreError.invalidRow("writing_memory \(id)")
        }
        var parent: UUID?
        if let supersededBy {
            guard let uuid = UUID(uuidString: supersededBy) else {
                throw LearningStoreError.invalidRow("writing_memory.superseded_by \(supersededBy)")
            }
            parent = uuid
        }
        let lastUsedAt: Double? = row["last_used_at"]
        let lastConsolidatedAt: Double? = row["last_consolidated_at"]
        var scope: WritingMode?
        if let modeScope {
            guard let mode = WritingMode(rawValue: modeScope) else {
                throw LearningStoreError.invalidRow("writing_memory.mode_scope \(modeScope)")
            }
            scope = mode
        }
        memory = WritingMemory(
            id: uuid,
            dedupKey: row["dedup_key"],
            kind: kind,
            language: row["language"],
            modeScope: scope,
            triggers: try JSONDecoder().decode([String].self, from: Data(triggers.utf8)),
            instruction: row["instruction"],
            evidenceScore: row["evidence_score"],
            occurrenceCount: row["occurrence_count"],
            state: state,
            userEdited: row["user_edited"],
            createdAt: Date(timeIntervalSince1970: row["created_at"]),
            lastConfirmedAt: Date(timeIntervalSince1970: row["last_confirmed_at"]),
            level: level,
            supersededBy: parent,
            retrievalCount: row["retrieval_count"],
            successfulUseCount: row["successful_use_count"],
            contradictionCount: row["contradiction_count"],
            lastUsedAt: lastUsedAt.map { Date(timeIntervalSince1970: $0) },
            lastConsolidatedAt: lastConsolidatedAt.map { Date(timeIntervalSince1970: $0) }
        )
    }

    func encode(to container: inout PersistenceContainer) throws {
        container["id"] = memory.id.uuidString
        container["dedup_key"] = memory.dedupKey
        container["kind"] = memory.kind.rawValue
        container["language"] = memory.language
        container["mode_scope"] = memory.modeScope?.rawValue
        container["triggers"] = String(decoding: try JSONEncoder().encode(memory.triggers), as: UTF8.self)
        container["instruction"] = memory.instruction
        container["evidence_score"] = memory.evidenceScore
        container["occurrence_count"] = memory.occurrenceCount
        container["state"] = memory.state.rawValue
        container["user_edited"] = memory.userEdited
        container["created_at"] = memory.createdAt.timeIntervalSince1970
        container["last_confirmed_at"] = memory.lastConfirmedAt.timeIntervalSince1970
        container["level"] = memory.level.rawValue
        container["superseded_by"] = memory.supersededBy?.uuidString
        container["retrieval_count"] = memory.retrievalCount
        container["successful_use_count"] = memory.successfulUseCount
        container["contradiction_count"] = memory.contradictionCount
        container["last_used_at"] = memory.lastUsedAt?.timeIntervalSince1970
        container["last_consolidated_at"] = memory.lastConsolidatedAt?.timeIntervalSince1970
    }
}

private struct DreamRunRecord: FetchableRecord, PersistableRecord {
    static let databaseTableName = "dream_run"

    var run: DreamRun

    init(_ run: DreamRun) {
        self.run = run
    }

    init(row: Row) throws {
        let id: String = row["id"]
        let status: String = row["status"]
        guard let uuid = UUID(uuidString: id), let status = DreamRunStatus(rawValue: status) else {
            throw LearningStoreError.invalidRow("dream_run \(id)")
        }
        let finishedAt: Double? = row["finished_at"]
        run = DreamRun(
            id: uuid,
            startedAt: Date(timeIntervalSince1970: row["started_at"]),
            finishedAt: finishedAt.map { Date(timeIntervalSince1970: $0) },
            algorithmVersion: row["algorithm_version"],
            inputMemoryCount: row["input_memory_count"],
            clusterCount: row["cluster_count"],
            generatedCount: row["generated_count"],
            supersededCount: row["superseded_count"],
            status: status
        )
    }

    func encode(to container: inout PersistenceContainer) throws {
        container["id"] = run.id.uuidString
        container["started_at"] = run.startedAt.timeIntervalSince1970
        container["finished_at"] = run.finishedAt?.timeIntervalSince1970
        container["algorithm_version"] = run.algorithmVersion
        container["input_memory_count"] = run.inputMemoryCount
        container["cluster_count"] = run.clusterCount
        container["generated_count"] = run.generatedCount
        container["superseded_count"] = run.supersededCount
        container["status"] = run.status.rawValue
    }
}

private struct EventRecord: FetchableRecord, PersistableRecord {
    static let databaseTableName = "feedback_event"

    var event: FeedbackEvent

    init(_ event: FeedbackEvent) {
        self.event = event
    }

    init(row: Row) throws {
        let id: String = row["id"]
        let mode: String = row["mode"]
        let action: String = row["action"]
        let usedIDs: String = row["used_memory_ids"]
        guard let uuid = UUID(uuidString: id),
              let mode = WritingMode(rawValue: mode),
              let action = FeedbackAction(rawValue: action)
        else {
            throw LearningStoreError.invalidRow("feedback_event \(id)")
        }
        event = FeedbackEvent(
            id: uuid,
            createdAt: Date(timeIntervalSince1970: row["created_at"]),
            mode: mode,
            action: action,
            sourceHMAC: row["source_hmac"],
            suggestionHMAC: row["suggestion_hmac"],
            finalHMAC: row["final_hmac"],
            provider: row["provider"],
            model: row["model"],
            usedMemoryIDs: try JSONDecoder().decode([UUID].self, from: Data(usedIDs.utf8))
        )
    }

    func encode(to container: inout PersistenceContainer) throws {
        container["id"] = event.id.uuidString
        container["created_at"] = event.createdAt.timeIntervalSince1970
        container["mode"] = event.mode.rawValue
        container["action"] = event.action.rawValue
        container["source_hmac"] = event.sourceHMAC
        container["suggestion_hmac"] = event.suggestionHMAC
        container["final_hmac"] = event.finalHMAC
        container["provider"] = event.provider
        container["model"] = event.model
        container["used_memory_ids"] = String(
            decoding: try JSONEncoder().encode(event.usedMemoryIDs), as: UTF8.self
        )
    }
}
