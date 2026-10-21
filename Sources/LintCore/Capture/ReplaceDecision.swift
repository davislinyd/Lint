import Foundation

/// What a replace is allowed to do to the captured field.
/// Select-all exists only when that field's whole value is the captured snippet.
/// A write goes only over the checked text. A field that can be read has to show the new text afterwards,
/// and the original merely being gone is not enough; a field that cannot be read at all proves nothing,
/// so the replace counts as done.
public enum ReplaceAttempt: Equatable, Sendable {
    /// Replace the one occurrence of the original snippet in the field value.
    case setFieldValue(String)
    /// Rich text: select and write only the changed pieces of the one occurrence, last first, then put
    /// the caret at `caret`, the end of the corrected snippet.
    case replaceSpans([ReplaceSpan], caret: Int)
    case setSelectedText
    case pasteIntoRestoredSelection
    case selectAllAndPaste
}

public enum ReplaceDirective: Equatable, Sendable {
    case perform(ReplaceAttempt)
    case success
    case failure(ReplaceRefusal)
}

public enum ReplaceRefusal: Equatable, Sendable {
    case noCapture
    case sourceNotFrontmost
    case notWholeField
    case ambiguous
    case unverified

    public var message: String {
        switch self {
        case .noCapture:
            String(localized: "沒有可覆蓋的選取")
        case .unverified:
            String(localized: "無法確認已寫入。若不對請還原（⌘Z）。")
        case .sourceNotFrontmost, .notWholeField, .ambiguous:
            String(localized: "沒有寫入。")
        }
    }
}

public struct ReplaceSnapshot: Equatable, Sendable {
    public var hasCapture: Bool
    public var sourceFrontmost: Bool
    public var hasElement: Bool
    /// `nil` when the field value cannot be read. That is not permission to select all.
    public var fieldValue: String?
    public var original: String
    public var newText: String
    /// `true` only when the captured range was selected again and that selection reads as the original.
    public var rangeRestored: Bool
    public var liveSelectedText: String?
    /// The field holds rich text (a web contenteditable). Writing its whole value would flatten mentions,
    /// links and formatting, and Chromium does it behind the editor's back, so the editor falls out of step.
    public var isRichText: Bool

    public init(
        hasCapture: Bool,
        sourceFrontmost: Bool,
        hasElement: Bool,
        fieldValue: String?,
        original: String,
        newText: String,
        rangeRestored: Bool,
        liveSelectedText: String?,
        isRichText: Bool
    ) {
        self.hasCapture = hasCapture
        self.sourceFrontmost = sourceFrontmost
        self.hasElement = hasElement
        self.fieldValue = fieldValue
        self.original = original
        self.newText = newText
        self.rangeRestored = rangeRestored
        self.liveSelectedText = liveSelectedText
        self.isRichText = isRichText
    }
}

public enum ReplaceDecision {
    public static func first(_ snapshot: ReplaceSnapshot) -> ReplaceDirective {
        guard snapshot.hasCapture else { return .failure(.noCapture) }
        guard snapshot.sourceFrontmost else { return .failure(.sourceNotFrontmost) }
        guard snapshot.hasElement else { return .failure(.notWholeField) }
        return edit(snapshot)
    }

    /// The AX write did not land. The next step still may not select all of a larger field.
    public static func afterAXWriteFailed(_ attempt: ReplaceAttempt, _ snapshot: ReplaceSnapshot) -> ReplaceDirective {
        guard snapshot.hasCapture else { return .failure(.noCapture) }
        guard snapshot.sourceFrontmost else { return .failure(.sourceNotFrontmost) }
        switch attempt {
        case .setFieldValue:
            if canTargetSelection(snapshot) { return .perform(.setSelectedText) }
            if let field = snapshot.fieldValue, allowsSelectAll(field: field, original: snapshot.original) {
                return .perform(.selectAllAndPaste)
            }
            return .failure(.notWholeField)
        case .replaceSpans:
            // Nothing was written: the pieces did not read back. Paste over the checked selection instead;
            // a rich-text field never gets its whole value written.
            if canTargetSelection(snapshot) { return .perform(.pasteIntoRestoredSelection) }
            if let field = snapshot.fieldValue, allowsSelectAll(field: field, original: snapshot.original) {
                return .perform(.selectAllAndPaste)
            }
            return .failure(.notWholeField)
        case .setSelectedText:
            if canTargetSelection(snapshot) { return .perform(.pasteIntoRestoredSelection) }
            if let field = snapshot.fieldValue, allowsSelectAll(field: field, original: snapshot.original) {
                return .perform(.selectAllAndPaste)
            }
            return .failure(.notWholeField)
        case .pasteIntoRestoredSelection, .selectAllAndPaste:
            return .failure(.unverified)
        }
    }

    public static func afterAXWriteSucceeded(
        fieldBefore: String?, fieldAfter: String?, newText: String
    ) -> ReplaceDirective {
        afterWrite(fieldBefore: fieldBefore, fieldAfter: fieldAfter, newText: newText)
    }

    public static func afterPaste(fieldBefore: String?, fieldAfter: String?, newText: String) -> ReplaceDirective {
        afterWrite(fieldBefore: fieldBefore, fieldAfter: fieldAfter, newText: newText)
    }

    /// Rich text: every piece read as its new text right after its write. Chromium can keep reporting a
    /// contenteditable's old value after an edit, so the field value decides only when a piece did not.
    public static func afterSpans(
        piecesReadBack: Bool, fieldBefore: String?, fieldAfter: String?, newText: String
    ) -> ReplaceDirective {
        piecesReadBack ? .success : afterWrite(fieldBefore: fieldBefore, fieldAfter: fieldAfter, newText: newText)
    }

    /// A field that can be read after the write has to show the new text. One that could not be read
    /// before it and cannot be read after it (web views and Electron often hide their value) proves
    /// nothing either way; the write went only over the checked text, so the replace counts as done.
    private static func afterWrite(fieldBefore: String?, fieldAfter: String?, newText: String) -> ReplaceDirective {
        if isReadable(fieldAfter) {
            return confirmed(fieldAfter: fieldAfter, newText: newText) ? .success : .failure(.unverified)
        }
        return isReadable(fieldBefore) ? .failure(.unverified) : .success
    }

    private static func isReadable(_ field: String?) -> Bool {
        !(field ?? "").isEmpty
    }

    /// True only when the captured snippet is the entire field, ignoring surrounding whitespace.
    public static func allowsSelectAll(field: String, original: String) -> Bool {
        let captured = normalized(original)
        return !captured.isEmpty && normalized(field) == captured
    }

    /// The new text has to be visible in the field. The original disappearing is not enough.
    public static func confirmed(fieldAfter: String?, newText: String) -> Bool {
        guard let fieldAfter, !newText.isEmpty else { return false }
        return fieldAfter.contains(newText)
    }

    public static func liveMatches(_ live: String?, original: String) -> Bool {
        guard let live else { return false }
        let captured = normalized(original)
        return !captured.isEmpty && normalized(live) == captured
    }

    private static func edit(_ snapshot: ReplaceSnapshot) -> ReplaceDirective {
        if let field = snapshot.fieldValue {
            if snapshot.isRichText, let range = singleOccurrence(field, of: snapshot.original) {
                let base = field.utf16.distance(from: field.utf16.startIndex, to: range.lowerBound)
                let spans = ReplaceSpans.spans(original: snapshot.original, newText: snapshot.newText, base: base)
                return .perform(.replaceSpans(spans, caret: base + snapshot.newText.utf16.count))
            }
            if let updated = replacingSingle(field, original: snapshot.original, with: snapshot.newText) {
                return .perform(.setFieldValue(updated))
            }
            if occurrenceCount(field, of: snapshot.original) > 1 {
                if canTargetSelection(snapshot) { return .perform(.setSelectedText) }
                return .failure(.ambiguous)
            }
            if allowsSelectAll(field: field, original: snapshot.original) {
                return .perform(.selectAllAndPaste)
            }
            if canTargetSelection(snapshot) { return .perform(.setSelectedText) }
            return .failure(.notWholeField)
        }
        if canTargetSelection(snapshot) { return .perform(.setSelectedText) }
        return .failure(.notWholeField)
    }

    private static func canTargetSelection(_ snapshot: ReplaceSnapshot) -> Bool {
        snapshot.rangeRestored || liveMatches(snapshot.liveSelectedText, original: snapshot.original)
    }

    private static func singleOccurrence(_ field: String, of original: String) -> Range<String.Index>? {
        guard occurrenceCount(field, of: original) == 1 else { return nil }
        return field.range(of: original)
    }

    private static func replacingSingle(_ field: String, original: String, with newText: String) -> String? {
        singleOccurrence(field, of: original).map { field.replacingCharacters(in: $0, with: newText) }
    }

    private static func occurrenceCount(_ field: String, of original: String) -> Int {
        guard !original.isEmpty else { return 0 }
        var count = 0
        var search = field.startIndex
        while let range = field.range(of: original, range: search..<field.endIndex) {
            count += 1
            search = range.upperBound
        }
        return count
    }

    private static func normalized(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
