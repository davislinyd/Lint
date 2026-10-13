import Foundation

/// A proofreading suggestion Lint made for a stretch of a field. It carries the texts, which live in
/// memory only, and only while that field is followed (`FieldSessionTracker`).
public struct ObservedSuggestion: Sendable, Equatable {
    /// The text the suggestion was made from.
    public var original: String
    public var suggestion: String
    public var tone: WritingTone
    public var provider: String
    public var model: String
    /// Memories that were in the prompt that produced it.
    public var usedMemoryIDs: [UUID]
    /// The field's text before and after `original` when the suggestion was made (see `located`).
    public var prefix: String
    public var suffix: String

    public init(
        original: String,
        suggestion: String,
        tone: WritingTone,
        provider: String,
        model: String,
        usedMemoryIDs: [UUID] = [],
        prefix: String = "",
        suffix: String = ""
    ) {
        self.original = original
        self.suggestion = suggestion
        self.tone = tone
        self.provider = provider
        self.model = model
        self.usedMemoryIDs = usedMemoryIDs
        self.prefix = prefix
        self.suffix = suffix
    }

    /// The model left the text as it was: there is nothing to take or to turn down.
    public var changesNothing: Bool {
        Self.trimmed(original) == Self.trimmed(suggestion)
    }

    /// This suggestion with `prefix` and `suffix` taken from `value`, the field's whole text.
    /// `original` sits at `utf16Range` if that is what is there, else at its only occurrence; nil
    /// when the field does not show where it sits.
    public func located(in value: String, utf16Range: Range<Int>?) -> ObservedSuggestion? {
        var range: Range<String.Index>?
        if let utf16Range, utf16Range.lowerBound >= 0, utf16Range.upperBound <= value.utf16.count {
            let hinted = String.Index(utf16Offset: utf16Range.lowerBound, in: value)
                ..< String.Index(utf16Offset: utf16Range.upperBound, in: value)
            if value[hinted] == original { range = hinted }
        }
        if range == nil, let first = value.range(of: original),
           value.range(of: original, range: first.upperBound..<value.endIndex) == nil {
            range = first
        }
        guard let range else { return nil }
        var located = self
        located.prefix = String(value[..<range.lowerBound])
        located.suffix = String(value[range.upperBound...])
        return located
    }

    /// What `value`, the field's whole text now, holds where `original` was: the text between
    /// `prefix` and `suffix`. Nil when the field no longer starts and ends that way. Whitespace
    /// around the field's text does not count.
    func stretch(of value: String) -> String? {
        let value = Self.trimmed(value)
        let prefix = String(prefix.drop(while: \.isWhitespace))
        let suffix = String(suffix.reversed().drop(while: \.isWhitespace).reversed())
        guard value.count >= prefix.count + suffix.count, value.hasPrefix(prefix), value.hasSuffix(suffix)
        else { return nil }
        return Self.trimmed(String(value.dropFirst(prefix.count).dropLast(suffix.count)))
    }

    private static func trimmed(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// Which field a suggestion was made in.
public struct ObservedField: Sendable, Equatable {
    /// Bundle ID of the app the field is in.
    public var app: String
    /// Tells the fields seen in this run of Lint apart.
    public var id: Int

    public init(app: String, id: Int) {
        self.app = app
        self.id = id
    }
}

/// How the suggestions made in one field fared, from the first one until the field was sent or left.
public struct SessionOutcome: Sendable, Equatable {
    public enum Result: String, Sendable {
        /// A suggestion was written over the text or copied.
        case adopted
        /// A suggestion was looked at, and none was used.
        case dismissed
        /// A suggestion was ready, and none was looked at.
        case ignored
    }

    public enum Ending: String, Sendable {
        /// The field was emptied after holding text: what a chat field does when a message is sent.
        case sent
        /// The field could no longer be read.
        case gone
        /// Nothing happened in the field for a long time.
        case timedOut
        /// Lint made a suggestion in another field.
        case movedOn
    }

    public var app: String
    public var result: Result
    public var ending: Ending
    /// The suggestion `result` is about: the one used, else the one looked at last, else the newest
    /// one that was ready.
    public var suggestion: ObservedSuggestion
    /// What Replace wrote, when that is how the suggestion was used.
    public var written: String?
    /// What the field held where `suggestion.original` was, just before it was sent. Nil unless the
    /// field was sent, and when the text around that stretch had changed.
    public var sentText: String?
}

/// Two counts that fade, so that they say how something went lately: "for" and "against".
public struct DecayedCounter: Sendable, Equatable {
    public var positive: Double
    public var negative: Double
    public var updatedAt: Date

    /// Both counts halve every this many days.
    static let halfLifeDays = 30.0

    public init(positive: Double = 0, negative: Double = 0, updatedAt: Date) {
        self.positive = positive
        self.negative = negative
        self.updatedAt = updatedAt
    }

    public var total: Double { positive + negative }

    /// The counts as they stand at `date`.
    public func faded(to date: Date) -> DecayedCounter {
        let days = max(0, date.timeIntervalSince(updatedAt)) / 86_400
        let factor = pow(0.5, days / Self.halfLifeDays)
        return DecayedCounter(positive: positive * factor, negative: negative * factor, updatedAt: max(date, updatedAt))
    }
}
