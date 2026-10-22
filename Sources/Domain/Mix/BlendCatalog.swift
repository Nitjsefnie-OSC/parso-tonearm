import Foundation

/// Where a catalog track is on the way to being blendable. Only `blendEligible` and later tracks
/// may be selected for a blend; nothing here is produced by a model at play time.
public enum BlendCatalogState: String, Codable, Sendable, Equatable, Comparable, CaseIterable {
    /// Known to the catalog, facts missing: never selected.
    case unindexed
    /// Every fact a blend needs is present (tempo, beat grid, duration, loudness).
    case blendEligible
    /// At least one adjacent edge has a concrete, executable plan.
    case edgePlanned

    private var rank: Int { Self.allCases.firstIndex(of: self) ?? 0 }
    public static func < (lhs: Self, rhs: Self) -> Bool { lhs.rank < rhs.rank }

    /// The lifecycle only moves forward one step at a time (`unindexed → blendEligible → edgePlanned`).
    public func canAdvance(to next: BlendCatalogState) -> Bool { next.rank == rank + 1 }
}

public extension StarterTrackFacts {
    /// Whether this track carries every fact a blend needs.
    var isBlendReady: Bool {
        [durationSeconds, bpm, beatPeriod].allSatisfy { $0.isFinite && $0 > 0 }
            && beatPhase.isFinite && beatPhase >= 0 && rmsDB.isFinite
    }
}

/// Plans an edge from catalog facts alone (tempo, beat grid, duration, loudness): arithmetic on
/// stored values, no audio and no model. Used where a pair has no supplied plan (Keep Playing
/// past the end of a pack). Returns nil when the pair does not qualify.
public enum CatalogEdgePlanner {
    public static let overlapBeats = 32
    public static let maxTempoDifference = 0.08
    static let tailSeconds = 6.0
    static let gainRange: ClosedRange<Double> = 0.5...1.6

    public static func plan(blendID: String, edge: Int, outgoing: StarterTrackFacts,
                            incoming: StarterTrackFacts) -> StarterEdgePlan? {
        guard outgoing.isBlendReady, incoming.isBlendReady else { return nil }
        let tempo = outgoing.bpm / incoming.bpm
        guard abs(tempo - 1) <= maxTempoDifference else { return nil }
        let lastBeat = Int((outgoing.durationSeconds - tailSeconds - outgoing.beatPhase) / outgoing.beatPeriod)
        let endBeat = (lastBeat / 16) * 16               // a phrase line
        let startBeat = endBeat - overlapBeats
        guard startBeat >= 16 else { return nil }
        let start = outgoing.beatTime(startBeat), end = outgoing.beatTime(endBeat)
        let incomingNeeded = incoming.beatPhase + Double(overlapBeats) * incoming.beatPeriod + 8
        guard incoming.durationSeconds > incomingNeeded else { return nil }
        let gain = min(max(pow(10, (outgoing.rmsDB - incoming.rmsDB) / 20), gainRange.lowerBound), gainRange.upperBound)
        return StarterEdgePlan(
            blendID: blendID, edge: edge, outgoingTrackID: outgoing.id, incomingTrackID: incoming.id,
            style: .bassSwap, tempo: tempo, overlapBeats: overlapBeats, incomingGain: gain,
            outgoingSwapBeat: startBeat + 16, incomingSwapBeat: 16, blendStartSeconds: start,
            swapSeconds: outgoing.beatTime(startBeat + 16), blendEndSeconds: end,
            incomingOffsetSeconds: start - incoming.beatPhase / tempo)
    }
}
