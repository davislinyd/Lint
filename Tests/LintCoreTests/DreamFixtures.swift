import Foundation
@testable import LintCore

/// Memories the way the extractor writes them, for the tests of dreaming.
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
        tone: WritingTone? = nil,
        triggers: [String] = [],
        instruction: String = "使用者偏好簡潔的用詞。",
        evidence: Double = 1.2,
        count: Int = 3,
        state: MemoryState = .active,
        ageDays: Double = 10
    ) -> WritingMemory {
        WritingMemory(
            id: UUID(), dedupKey: key, kind: kind, language: language,
            modeScope: scope, toneScope: tone,
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
            toneScope: members[0].toneScope, members: members
        )
    }
}

/// A clock the test moves by hand.
final class DreamClock: @unchecked Sendable {
    private let lock = NSLock()
    private var current: Date

    init(_ start: Date = DreamFixtures.now) {
        current = start
    }

    var now: Date {
        lock.lock()
        defer { lock.unlock() }
        return current
    }

    func advance(hours: Double) {
        lock.lock()
        current = current.addingTimeInterval(hours * 3_600)
        lock.unlock()
    }

    var reader: @Sendable () -> Date {
        { [self] in now }
    }
}

/// A sleep that lasts until the test says so, and notes how long each one was asked to be. A sleep
/// that is cancelled ends at once, as a real one does.
final class ManualSleeper: @unchecked Sendable {
    private let lock = NSLock()
    private var waiters: [Int: CheckedContinuation<Void, any Error>] = [:]
    private var next = 0
    private var asked: [Duration] = []

    var waitingCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return waiters.count
    }

    var durations: [Duration] {
        lock.lock()
        defer { lock.unlock() }
        return asked
    }

    private func register(_ duration: Duration) -> Int {
        lock.withLock {
            let id = next
            next += 1
            asked.append(duration)
            return id
        }
    }

    func sleep(_ duration: Duration) async throws {
        let id = register(duration)
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                lock.lock()
                if Task.isCancelled {
                    lock.unlock()
                    continuation.resume(throwing: CancellationError())
                } else {
                    waiters[id] = continuation
                    lock.unlock()
                }
            }
        } onCancel: {
            lock.lock()
            let continuation = waiters.removeValue(forKey: id)
            lock.unlock()
            continuation?.resume(throwing: CancellationError())
        }
    }

    /// Ends every sleep that is going on now.
    func wake() {
        lock.lock()
        let all = waiters
        waiters = [:]
        lock.unlock()
        for continuation in all.values { continuation.resume() }
    }

    var reader: @Sendable (Duration) async throws -> Void {
        { [self] in try await sleep($0) }
    }
}

/// Polls until `condition` holds, for what happens on other tasks. False if it never did.
func eventually(timeout: TimeInterval = 3, _ condition: () async -> Bool) async -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if await condition() { return true }
        try? await Task.sleep(nanoseconds: 2_000_000)
    }
    return await condition()
}

/// Gives what should not happen a moment to happen anyway.
func settle() async {
    try? await Task.sleep(nanoseconds: 60_000_000)
}
