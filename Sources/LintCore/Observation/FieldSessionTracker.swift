import Foundation

/// Follows one field from the first suggestion Lint made in it until its text is sent, and says how
/// those suggestions fared. Pure: what was read from the field, and when, is handed in, so the rules
/// can be tested without a field. The texts it holds go with the session.
public struct FieldSessionTracker: Sendable {
    public enum Event: Sendable, Equatable {
        /// A finished suggestion waits behind the chip; the user has not looked at it.
        case suggestionReady(ObservedSuggestion, in: ObservedField)
        /// A finished suggestion is on screen.
        case opened(ObservedSuggestion, in: ObservedField)
        /// Replace wrote this over the text the suggestion on screen was made for.
        case replaced(written: String)
        /// The suggestion on screen was copied.
        case copied
        /// The field's whole text now, or nil when it could not be read.
        case fieldRead(String?)
    }

    /// A session with nothing new for this long ends.
    static let idleLimit: TimeInterval = 10 * 60
    /// A field that could not be read for this long is gone.
    static let unreadableLimit: TimeInterval = 2

    private struct Session {
        var field: ObservedField
        /// The suggestion looked at last.
        var opened: ObservedSuggestion?
        /// The newest suggestion that was ready and has not been looked at.
        var ready: ObservedSuggestion?
        /// The suggestion used last, and what Replace wrote if that is how.
        var adopted: ObservedSuggestion?
        var written: String?
        /// The field's text as last read twice in a row: a single read can catch it halfway
        /// through a change.
        var settled: String
        var lastRead: String?
        var unreadableSince: Date?
        var lastActivity: Date

        func outcome(_ ending: SessionOutcome.Ending) -> SessionOutcome? {
            guard let suggestion = adopted ?? opened ?? ready else { return nil }
            return SessionOutcome(
                app: field.app,
                result: adopted != nil ? .adopted : opened != nil ? .dismissed : .ignored,
                ending: ending,
                suggestion: suggestion,
                written: written,
                sentText: ending == .sent ? suggestion.stretch(of: settled) : nil
            )
        }
    }

    private var session: Session?

    public init() {}

    /// A field is being followed, so it has to be read.
    public var isTracking: Bool { session != nil }

    /// Returns how a session went when `event` ends one. A suggestion for another field ends the
    /// session of the field followed so far and starts one for its own.
    public mutating func handle(_ event: Event, at now: Date) -> SessionOutcome? {
        switch event {
        case .suggestionReady(let suggestion, let field):
            return note(suggestion, in: field, opened: false, at: now)
        case .opened(let suggestion, let field):
            return note(suggestion, in: field, opened: true, at: now)
        case .replaced(let written):
            guard var current = session, let used = current.opened else { return nil }
            current.adopted = used
            current.written = written
            // What the field holds now; a send right after Replace can come before the next read.
            current.settled = used.prefix + written + used.suffix
            current.lastActivity = now
            session = current
            return nil
        case .copied:
            guard var current = session, let used = current.opened else { return nil }
            current.adopted = used
            current.written = nil
            current.lastActivity = now
            session = current
            return nil
        case .fieldRead(let value):
            return read(value, at: now)
        }
    }

    /// Stops following the field, as when it can no longer be read.
    public mutating func giveUp() -> SessionOutcome? {
        defer { session = nil }
        return session?.outcome(.gone)
    }

    private mutating func note(
        _ suggestion: ObservedSuggestion, in field: ObservedField, opened: Bool, at now: Date
    ) -> SessionOutcome? {
        // Text the model left alone, such as what Replace just wrote being checked again.
        guard !suggestion.changesNothing else { return nil }
        var ended: SessionOutcome?
        if let current = session, current.field != field {
            ended = current.outcome(.movedOn)
            session = nil
        }
        var current = session ?? Session(field: field, settled: "", lastActivity: now)
        if opened {
            current.opened = suggestion
            current.ready = nil
        } else {
            current.ready = suggestion
        }
        current.settled = suggestion.prefix + suggestion.original + suggestion.suffix
        current.lastActivity = now
        session = current
        return ended
    }

    private mutating func read(_ value: String?, at now: Date) -> SessionOutcome? {
        guard var current = session else { return nil }
        if let value {
            current.unreadableSince = nil
            if value != current.lastRead {
                current.lastRead = value
                current.lastActivity = now
            } else if value != current.settled {
                if Self.isBlank(value), !Self.isBlank(current.settled) {
                    session = nil
                    return current.outcome(.sent)
                }
                current.settled = value
            }
        } else {
            if let since = current.unreadableSince {
                if now.timeIntervalSince(since) >= Self.unreadableLimit {
                    session = nil
                    return current.outcome(.gone)
                }
            } else {
                current.unreadableSince = now
            }
        }
        if now.timeIntervalSince(current.lastActivity) >= Self.idleLimit {
            session = nil
            return current.outcome(.timedOut)
        }
        session = current
        return nil
    }

    private static func isBlank(_ text: String) -> Bool {
        text.allSatisfy(\.isWhitespace)
    }
}
