import Foundation
@testable import LintCore

/// Memories the way the extractor writes them, for the tests of organizing memories.
enum DreamFixtures {
    static let now = Date(timeIntervalSince1970: 1_800_000_000)

    /// A memory for a preposition the user deleted after a verb (`grammar:en:<verb> <preposition>`).
    /// By default it is established: active, seen three times, ten days old.
    static func preposition(
        _ verb: String,
        _ preposition: String = "about",
        evidence: Double = 1.2,
        count: Int = 3,
        state: MemoryState = .active,
        ageDays: Double = 10,
        confirmedDaysAgo: Double = 1,
        userEdited: Bool = false
    ) -> WritingMemory {
        let phrase = "\(verb) \(preposition)"
        return WritingMemory(
            id: UUID(),
            dedupKey: "grammar:en:\(phrase)",
            kind: .grammar, language: "en", modeScope: nil,
            triggers: [phrase],
            instruction: "「\(phrase)」中的「\(preposition)」有時是多餘的（使用者曾刪掉）；請確認是否應寫成「\(verb)」，僅在語意需要時修正。",
            evidenceScore: evidence, occurrenceCount: count, state: state, userEdited: userEdited,
            createdAt: now.addingTimeInterval(-ageDays * 86_400),
            lastConfirmedAt: now.addingTimeInterval(-confirmedDaysAgo * 86_400)
        )
    }

    /// A memory that belongs to no family; `instruction` is all that says what it is about.
    static func plain(
        _ key: String,
        kind: MemoryKind = .style,
        language: String = "en",
        scope: WritingMode? = nil,
        triggers: [String] = [],
        instruction: String = "使用者偏好簡潔的用詞。",
        evidence: Double = 1.2,
        count: Int = 3,
        state: MemoryState = .active,
        ageDays: Double = 10
    ) -> WritingMemory {
        WritingMemory(
            id: UUID(), dedupKey: key, kind: kind, language: language, modeScope: scope,
            triggers: triggers, instruction: instruction, evidenceScore: evidence,
            occurrenceCount: count, state: state, userEdited: false,
            createdAt: now.addingTimeInterval(-ageDays * 86_400),
            lastConfirmedAt: now.addingTimeInterval(-86_400)
        )
    }

    static let verbs = ["mention", "emphasize", "reply", "describe", "explain", "return"]

    static func prepositions(_ count: Int) -> [WritingMemory] {
        verbs.prefix(count).map { preposition($0) }
    }

    static func cluster(_ members: [WritingMemory]) -> MemoryCluster {
        MemoryCluster(
            language: members[0].language, kind: members[0].kind, modeScope: members[0].modeScope,
            members: members
        )
    }
}
