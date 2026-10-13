import Foundation

/// Decides, from the counts, what holds: whether a trait is part of how the user writes, whether an
/// app has gone quiet, and which tone is an app's own.
enum ObservationAdjuster {
    /// A trait is taken up once it was seen this often lately and kept this much of the time. The
    /// count is taken to the nearest whole observation: counts fade all the time, so eight
    /// observations made today already read a hair under 8.
    static let minimumSamples = 8.0
    static let establishRatio = 0.8
    /// One that holds already is only dropped once it is kept less than this much of the time, so
    /// that it does not come and go around one threshold.
    static let withdrawRatio = 0.6

    /// An app goes quiet once this many sessions there lately ended without a suggestion being
    /// used, and none with one.
    static let quietSessions = 30.0
    /// A tone becomes an app's own once suggestions in it were used there this often lately, and it
    /// was the tone of this much of what was used there.
    static let toneAdoptions = 3.0
    static let toneShare = 0.8

    static func isQuiet(_ counter: DecayedCounter) -> Bool {
        counter.negative.rounded() >= quietSessions && counter.positive < 1
    }

    /// The tone used in an app most of the time, from how often each was (as the counts stand now).
    static func tone(from adoptions: [WritingTone: Double]) -> WritingTone? {
        let total = adoptions.values.reduce(0, +)
        guard total > 0,
              let top = adoptions.max(by: { ($0.value, $1.key.rawValue) < ($1.value, $0.key.rawValue) }),
              top.value.rounded() >= toneAdoptions, top.value / total >= toneShare
        else { return nil }
        return top.key
    }

    static func holds(_ counter: DecayedCounter, held: Bool) -> Bool {
        guard counter.total > 0 else { return false }
        let ratio = counter.positive / counter.total
        if held { return ratio >= withdrawRatio }
        return counter.total.rounded() >= minimumSamples && ratio >= establishRatio
    }
}
