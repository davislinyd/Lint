import Foundation

/// Decides, from the counts, whether a trait holds: is part of how the user writes.
enum ObservationAdjuster {
    /// A trait is taken up once it was seen this often lately and kept this much of the time. The
    /// count is taken to the nearest whole observation: counts fade all the time, so eight
    /// observations made today already read a hair under 8.
    static let minimumSamples = 8.0
    static let establishRatio = 0.8
    /// One that holds already is only dropped once it is kept less than this much of the time, so
    /// that it does not come and go around one threshold.
    static let withdrawRatio = 0.6

    static func holds(_ counter: DecayedCounter, held: Bool) -> Bool {
        guard counter.total > 0 else { return false }
        let ratio = counter.positive / counter.total
        if held { return ratio >= withdrawRatio }
        return counter.total.rounded() >= minimumSamples && ratio >= establishRatio
    }
}
