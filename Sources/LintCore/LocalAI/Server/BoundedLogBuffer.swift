import Foundation

/// Keeps only the last few kilobytes of a process's output, so a failed llama-server can be
/// explained (last lines) without storing or showing its whole log.
public final class BoundedLogBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private let capacity: Int
    private var bytes = Data()
    private var truncated = false

    public init(capacity: Int = 16 * 1024) {
        self.capacity = max(1, capacity)
    }

    public func append(_ chunk: Data) {
        lock.lock()
        defer { lock.unlock() }
        bytes.append(chunk)
        if bytes.count > capacity {
            bytes = bytes.suffix(capacity)
            truncated = true
        }
    }

    /// The last `lines` non-empty lines, at most `maxCharacters` characters long.
    public func tail(lines: Int = 8, maxCharacters: Int = 1200) -> String {
        lock.lock()
        let snapshot = bytes
        let cut = truncated
        lock.unlock()

        var text = String(decoding: snapshot, as: UTF8.self)
        var all = text.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }
        // The first line of a truncated buffer is probably cut in the middle.
        if cut, !all.isEmpty { all.removeFirst() }
        text = all.filter { !$0.isEmpty }.suffix(max(0, lines)).joined(separator: "\n")
        if text.count > maxCharacters { text = "…" + String(text.suffix(maxCharacters)) }
        return text
    }
}
