import Foundation

/// Decides who uses the local model: Lint always first, other apps (through Lint's API port) when
/// Lint leaves it alone.
///
/// llama-server runs one request at a time, in the order they arrive. When Lint begins a request,
/// the external request in progress is interrupted at once (`onPreempt` closes its connection, and
/// llama-server stops; measured 0.17-0.66 s), and no external request starts while Lint's run or
/// for `quietPeriod` after the last one, so a burst (live watch, a suggestion and its translation)
/// is not split, and Lint's prompt stays in the model's cache.
///
/// Lint's side never waits: `beginLint` and `LintTicket.end` take a lock and return, so reporting
/// can never queue behind the work it is meant to hold back (the same reason as `InteractiveGate`).
/// Only external requests wait.
public final class ModelPriorityGate: @unchecked Sendable {
    public enum GateError: Error, Equatable {
        /// Too many external requests are already waiting.
        case queueFull
        /// Waited longer than the request's budget.
        case timedOut
        /// The API was stopped.
        case closed
    }

    /// Ends Lint's use of the model; ending twice is harmless.
    public final class LintTicket: @unchecked Sendable {
        private let lock = NSLock()
        private var ended = false
        private weak var gate: ModelPriorityGate?

        fileprivate init(gate: ModelPriorityGate) {
            self.gate = gate
        }

        public func end() {
            let first = lock.withLock {
                defer { ended = true }
                return !ended
            }
            if first { gate?.lintEnded() }
        }
    }

    /// An external request's turn with the model.
    public final class ExternalLease: @unchecked Sendable {
        fileprivate let id: Int
        fileprivate let onPreempt: @Sendable () -> Void
        private weak var gate: ModelPriorityGate?
        private let lock = NSLock()
        private var preempted = false
        private var released = false

        fileprivate init(id: Int, gate: ModelPriorityGate, onPreempt: @escaping @Sendable () -> Void) {
            self.id = id
            self.gate = gate
            self.onPreempt = onPreempt
        }

        /// Lint took the model during this turn.
        public var wasPreempted: Bool { lock.withLock { preempted } }

        /// Marks the turn as interrupted; true the first time.
        fileprivate func markPreempted() -> Bool {
            lock.withLock {
                defer { preempted = true }
                return !preempted
            }
        }

        public func release() {
            let first = lock.withLock {
                defer { released = true }
                return !released
            }
            if first { gate?.released(self) }
        }
    }

    private struct Waiter {
        let id: Int
        let continuation: CheckedContinuation<ExternalLease, any Error>
        let onPreempt: @Sendable () -> Void
        var timer: Task<Void, Never>?
    }

    private let quietPeriod: Duration
    private let maxWaiting: Int
    private let sleep: @Sendable (Duration) async throws -> Void
    private let lock = NSLock()
    private var lintRequests = 0
    /// No Lint request or typing for `quietPeriod`.
    private var quiet = true
    /// Goes up with every Lint request and keystroke, so a quiet-period timer that was overtaken does nothing.
    private var activity = 0
    private var active: ExternalLease?
    private var waiters: [Waiter] = []
    private var nextID = 0
    private var ranSinceLint = false

    public init(
        quietPeriod: Duration = .seconds(3),
        maxWaiting: Int = 8,
        sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }
    ) {
        self.quietPeriod = quietPeriod
        self.maxWaiting = maxWaiting
        self.sleep = sleep
    }

    // MARK: - Lint

    /// Lint is about to use the model. Interrupts the external request in progress, if any.
    public func beginLint() -> LintTicket {
        let interrupted: ExternalLease? = lock.withLock {
            lintRequests += 1
            quiet = false
            activity += 1
            ranSinceLint = false
            guard let active, active.markPreempted() else { return nil }
            return active
        }
        interrupted?.onPreempt()
        return LintTicket(gate: self)
    }

    /// The user is typing: Lint will ask for a suggestion soon, so no external request starts now.
    /// Nothing in progress is interrupted.
    public func noteLintActivity() {
        let generation: Int? = lock.withLock {
            quiet = false
            activity += 1
            return lintRequests == 0 ? activity : nil
        }
        if let generation { startQuietPeriod(generation) }
    }

    fileprivate func lintEnded() {
        let generation: Int? = lock.withLock {
            lintRequests = max(0, lintRequests - 1)
            activity += 1
            return lintRequests == 0 ? activity : nil
        }
        if let generation { startQuietPeriod(generation) }
    }

    private func startQuietPeriod(_ generation: Int) {
        Task { [weak self, quietPeriod, sleep] in
            try? await sleep(quietPeriod)
            self?.quietPeriodEnded(generation)
        }
    }

    private func quietPeriodEnded(_ generation: Int) {
        let granted: [(CheckedContinuation<ExternalLease, any Error>, ExternalLease)] = lock.withLock {
            guard generation == activity, lintRequests == 0 else { return [] }
            quiet = true
            return grantNextLocked()
        }
        for (continuation, lease) in granted { continuation.resume(returning: lease) }
    }

    // MARK: - State

    public var isExternalActive: Bool { lock.withLock { active != nil } }

    /// An external request had the model after Lint's last request, so Lint's prompt may no longer be
    /// in its cache.
    public var externalRanSinceLastLint: Bool { lock.withLock { ranSinceLint } }

    public var waitingCount: Int { lock.withLock { waiters.count } }

    // MARK: - External requests

    /// Waits for a turn with the model.
    /// - Parameters:
    ///   - front: a request Lint interrupted before it sent anything comes back to the head of the
    ///     queue (and is never turned away for a full queue).
    ///   - budget: how long it may wait.
    ///   - onPreempt: called (once) when Lint takes the model during this turn.
    public func acquireExternal(
        front: Bool = false, budget: Duration, onPreempt: @escaping @Sendable () -> Void
    ) async throws -> ExternalLease {
        let id = lock.withLock {
            nextID += 1
            return nextID
        }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<ExternalLease, any Error>) in
                enqueue(Waiter(id: id, continuation: continuation, onPreempt: onPreempt), front: front, budget: budget)
            }
        } onCancel: {
            fail(id, with: CancellationError())
        }
    }

    private func enqueue(_ waiter: Waiter, front: Bool, budget: Duration) {
        enum Outcome { case rejected(GateError), queued, granted([(CheckedContinuation<ExternalLease, any Error>, ExternalLease)]) }
        let outcome: Outcome = lock.withLock {
            if Task.isCancelled { return .rejected(.closed) }
            if !front, waiters.count >= maxWaiting { return .rejected(.queueFull) }
            if front { waiters.insert(waiter, at: 0) } else { waiters.append(waiter) }
            let granted = grantNextLocked()
            return granted.isEmpty ? .queued : .granted(granted)
        }
        switch outcome {
        case .rejected(let error):
            waiter.continuation.resume(throwing: Task.isCancelled ? CancellationError() : error)
        case .granted(let granted):
            for (continuation, lease) in granted { continuation.resume(returning: lease) }
            if !granted.contains(where: { $0.1.id == waiter.id }) { startTimer(for: waiter.id, budget: budget) }
        case .queued:
            startTimer(for: waiter.id, budget: budget)
        }
    }

    private func startTimer(for id: Int, budget: Duration) {
        let timer = Task { [weak self, sleep] in
            do { try await sleep(budget) } catch { return }
            self?.fail(id, with: GateError.timedOut)
        }
        let stillWaiting = lock.withLock {
            guard let index = waiters.firstIndex(where: { $0.id == id }) else { return false }
            waiters[index].timer = timer
            return true
        }
        if !stillWaiting { timer.cancel() }
    }

    private func fail(_ id: Int, with error: any Error) {
        let removed: Waiter? = lock.withLock {
            guard let index = waiters.firstIndex(where: { $0.id == id }) else { return nil }
            return waiters.remove(at: index)
        }
        removed?.timer?.cancel()
        removed?.continuation.resume(throwing: error)
    }

    /// Grants the head of the queue its turn if the model is free. Call with the lock held; resume the
    /// returned continuations after unlocking.
    private func grantNextLocked() -> [(CheckedContinuation<ExternalLease, any Error>, ExternalLease)] {
        guard active == nil, lintRequests == 0, quiet, !waiters.isEmpty else { return [] }
        let waiter = waiters.removeFirst()
        waiter.timer?.cancel()
        let lease = ExternalLease(id: waiter.id, gate: self, onPreempt: waiter.onPreempt)
        active = lease
        ranSinceLint = true
        return [(waiter.continuation, lease)]
    }

    fileprivate func released(_ lease: ExternalLease) {
        let granted: [(CheckedContinuation<ExternalLease, any Error>, ExternalLease)] = lock.withLock {
            guard active === lease else { return [] }
            active = nil
            return grantNextLocked()
        }
        for (continuation, next) in granted { continuation.resume(returning: next) }
    }

    /// The API stopped: interrupts the request in progress and fails every waiting one with `.closed`.
    /// The gate stays usable; the next external request waits as usual.
    public func cancelAllExternal() {
        let (interrupted, failed): (ExternalLease?, [Waiter]) = lock.withLock {
            let all = waiters
            waiters = []
            guard let active, active.markPreempted() else { return (nil, all) }
            return (active, all)
        }
        interrupted?.onPreempt()
        for waiter in failed {
            waiter.timer?.cancel()
            waiter.continuation.resume(throwing: GateError.closed)
        }
    }
}
