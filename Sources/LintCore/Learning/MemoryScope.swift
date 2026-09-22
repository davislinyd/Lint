import Foundation

/// What a memory applies to as far as the task and the tone go. The one place that turns the mode
/// and tone of a piece of feedback into a scope, and a scope into the part of a `dedupKey` that
/// names it, so that every writer of keys agrees on both.
enum MemoryScope {
    typealias Scope = (mode: WritingMode?, tone: WritingTone?)

    /// Plain proofreading is the baseline that everything else is measured against: what is learned
    /// there applies everywhere. Another task keeps its own, and so does another tone, but the default
    /// tone (`preserve`) narrows nothing: it is no register of its own.
    static func of(mode: WritingMode, tone: WritingTone) -> Scope {
        if mode == .proofread, tone == .preserve { return (nil, nil) }
        return (mode, tone == .preserve ? nil : tone)
    }

    /// `nil` (applies everywhere), `translate`, or `proofread|formal`. Never contains `:` or `>`,
    /// which a key uses to tell its parts and its pattern apart.
    static func keySegment(mode: WritingMode?, tone: WritingTone?) -> String? {
        switch (mode, tone) {
        case (nil, nil): nil
        case (let mode?, nil): mode.rawValue
        case (let mode?, let tone?): "\(mode.rawValue)|\(tone.rawValue)"
        case (nil, let tone?): "any|\(tone.rawValue)"
        }
    }
}
