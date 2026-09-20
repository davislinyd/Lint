import Foundation

/// Runs `operation`, but gives back `fallback` if it has not finished within `timeout`, or as soon
/// as the caller is cancelled. The caller is never held up by an operation that is slow or ignores
/// cancellation: that is cancelled and left to finish in the background, and its result dropped.
/// (A task group would wait for it.)
func withTimeout<T: Sendable>(
    _ timeout: Duration,
    fallback: T,
    _ operation: @escaping @Sendable () async -> T
) async -> T {
    let race = Race<T>()
    return await withTaskCancellationHandler {
        await withCheckedContinuation { (continuation: CheckedContinuation<T, Never>) in
            race.start(continuation)
            race.add(Task { race.finish(await operation()) })
            race.add(Task {
                try? await Task.sleep(for: timeout)
                race.finish(fallback)
            })
        }
    } onCancel: {
        race.finish(fallback)
    }
}

/// The first result wins and resumes the caller exactly once; the other tasks are cancelled.
private final class Race<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<T, Never>?
    private var result: T?
    private var finished = false
    private var tasks: [Task<Void, Never>] = []

    func start(_ continuation: CheckedContinuation<T, Never>) {
        lock.lock()
        // Already decided, e.g. the caller was cancelled before it began waiting.
        if let result {
            lock.unlock()
            continuation.resume(returning: result)
            return
        }
        self.continuation = continuation
        lock.unlock()
    }

    func add(_ task: Task<Void, Never>) {
        lock.lock()
        defer { lock.unlock() }
        if finished { task.cancel() } else { tasks.append(task) }
    }

    func finish(_ value: T) {
        lock.lock()
        guard !finished else {
            lock.unlock()
            return
        }
        finished = true
        let continuation = continuation
        if continuation == nil { result = value }
        let tasks = tasks
        self.continuation = nil
        self.tasks = []
        lock.unlock()
        continuation?.resume(returning: value)
        for task in tasks { task.cancel() }
    }
}
