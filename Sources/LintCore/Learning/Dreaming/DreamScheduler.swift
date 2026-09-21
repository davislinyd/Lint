import Foundation

/// Whether the user is waiting on a suggestion. The app layer reports it (`LearningCoordinator.
/// setInteractiveActivity`); it can be read and set from anywhere without waiting, because
/// reporting it must never queue behind the work it is meant to hold back.
final class InteractiveGate: @unchecked Sendable {
    private let lock = NSLock()
    private var active = false
    private var reports = 0

    func set(_ active: Bool) {
        lock.lock()
        self.active = active
        reports += 1
        lock.unlock()
    }

    var isBusy: Bool {
        lock.lock()
        defer { lock.unlock() }
        return active
    }

    /// Goes up with every report, so that something that happened and ended between two looks
    /// still shows.
    var activity: Int {
        lock.lock()
        defer { lock.unlock() }
        return reports
    }
}

/// Decides when organizing memories runs: only marked as pending by a few triggers, and run once,
/// after things have been quiet for a while. Nothing here is on the clock (a Mac may be asleep at
/// any hour): a pass happens after start-up when it has been long enough, after enough new
/// learning, or when memories pile up.
///
/// Several triggers in a row (feedback, feedback, feedback) restart the same wait and end in one
/// pass. A pass never starts while the user is waiting on a suggestion, or has just been, and one
/// that is running gives way to the user (see `MemoryDreamCoordinator.run(yieldingTo:)`) and is
/// tried again later. A pass that fails is tried again much later, and never reaches the caller.
actor DreamScheduler {
    /// One pass over the memories. Nil if there was nothing to run (another pass had it).
    typealias Pass = @Sendable () async -> DreamRunStatus?

    private let gate: InteractiveGate
    private let clock: @Sendable () -> Date
    private let sleep: @Sendable (Duration) async throws -> Void
    private let idleDelay: Duration
    private let retryDelay: Duration
    private let pass: Pass

    private var pending = false
    private var running = false
    private var generation = 0
    private var waiter: Task<Void, Never>?
    private var changesSinceLastPass = 0
    private var lastPass: Date?

    init(
        gate: InteractiveGate,
        clock: @escaping @Sendable () -> Date = { Date() },
        sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) },
        idleDelay: Duration = LearningPolicy.dreamIdleDelay,
        retryDelay: Duration = LearningPolicy.dreamRetryDelay,
        pass: @escaping Pass
    ) {
        self.gate = gate
        self.clock = clock
        self.sleep = sleep
        self.idleDelay = idleDelay
        self.retryDelay = retryDelay
        self.pass = pass
    }

    // MARK: triggers

    /// The app has started (or learning was switched on): it has been long enough since the last pass.
    func noteStartup(lastCompletedPass: Date?) {
        lastPass = lastCompletedPass
        guard let lastCompletedPass else { return markPending() }
        if clock().timeIntervalSince(lastCompletedPass) > LearningPolicy.dreamStartupInterval { markPending() }
    }

    /// Memories were learned from, or weakened: this many meaningful changes.
    func noteChanges(_ count: Int) {
        changesSinceLastPass += count
        if changesSinceLastPass >= LearningPolicy.dreamChangeThreshold { markPending() }
    }

    /// This many memories are candidates or in use. Repeated passes could not thin them out any
    /// further than the last one did, so this only counts once a while has passed since.
    func notePressure(memories: Int) {
        guard memories >= LearningPolicy.dreamPressureThreshold else { return }
        if let lastPass, clock().timeIntervalSince(lastPass) < LearningPolicy.dreamPressureCooldown { return }
        markPending()
    }

    func markPending() {
        pending = true
        if !running { schedule(after: idleDelay) }
    }

    /// Nothing is due any more (learning was switched off).
    func cancelPending() {
        pending = false
        waiter?.cancel()
        waiter = nil
    }

    /// A pass happened without the scheduler (the user asked for one): it counts as this one.
    func didRun() {
        lastPass = clock()
        changesSinceLastPass = 0
        cancelPending()
    }

    // MARK: waiting and running

    private func schedule(after delay: Duration) {
        waiter?.cancel()
        generation += 1
        let mine = generation
        waiter = Task(priority: .utility) { [weak self] in
            await self?.wait(delay, generation: mine)
        }
    }

    /// Waits until nothing has been reported for a whole `idleDelay` and nobody is waiting on a suggestion.
    private func wait(_ first: Duration, generation mine: Int) async {
        var delay = first
        do {
            while true {
                let seen = gate.activity
                try await sleep(delay)
                guard mine == generation, pending else { return }
                if !gate.isBusy, gate.activity == seen { break }
                delay = idleDelay
            }
        } catch {
            return
        }
        await runPass()
    }

    private func runPass() async {
        guard pending, !running else { return }
        pending = false
        running = true
        let status = await pass()
        running = false
        switch status {
        case .completed?, nil:
            lastPass = clock()
            changesSinceLastPass = 0
        case .cancelled?, .running?:
            pending = true
        case .failed?:
            pending = true
        }
        if pending { schedule(after: status == .failed ? retryDelay : idleDelay) }
    }
}
