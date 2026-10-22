import Foundation

/// Catalog state of a track for blending. A track only ever moves forward:
/// `unindexed` (nothing known), `blendEligible` (tempo, grid and level facts are in the catalog,
/// so it may be selected) and `edgePlanned` (a concrete plan exists for at least one edge it
/// takes part in). Only `blendEligible` or later tracks may be selected for a blend.
public enum BlendTrackState: Int, Codable, Sendable, Comparable, CaseIterable {
    case unindexed
    case blendEligible
    case edgePlanned

    public static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
    public var isSelectable: Bool { self >= .blendEligible }
}

/// Everything the renderer needs to know about one pack track, from the release's
/// `starter-transition-candidates.json`. Read from the checked-in catalog; never computed in the app.
public struct StarterTrackFacts: Sendable, Equatable {
    public let id: String
    public let duration: Double
    public let bpm: Double
    /// Beat period (s) and grid phase (s) of the constant-tempo beat grid.
    public let period: Double
    public let phase: Double
    public let rmsDB: Double
    /// Beat indices where the bass comes in / goes out.
    public let drops: [Int]
    public let exits: [Int]
}

/// One precomputed edge of a Starter Blend, exactly as published in the release. Times are in
/// the outgoing track's own (native tempo) time base; `tempo` is the incoming track's
/// source-seconds per output-second. For a phrase cut the overlap is zero and the start, swap and
/// end times are the cut.
public struct StarterEdgePlan: Codable, Sendable, Equatable {
    public enum Style: String, Codable, Sendable { case doubleDrop = "double-drop", bassSwap = "bass-swap", phraseCut = "phrase-cut" }

    public let blendID: String
    /// 1-based position of the edge in its blend (edge 1 joins tracks 1 and 2).
    public let edge: Int
    public let outgoing: String
    public let incoming: String
    public let style: Style
    public let reason: String
    /// Outgoing beat period (s) at native tempo.
    public let period: Double
    public let tempo: Double
    public let incomingGain: Double
    public let overlapBeats: Int
    /// Outgoing swap (or cut) beat and the incoming beat it lands on.
    public let outgoingBeat: Int
    public let incomingBeat: Int
    public let blendStartSeconds: Double
    public let swapSeconds: Double
    public let blendEndSeconds: Double
    public let incomingOffsetSeconds: Double
}

/// Which pack, at which version, a blend was made from. Stored with every saved Starter Blend so
/// it replays from the same immutable release assets and edge plans.
public struct StarterPackIdentity: Codable, Sendable, Equatable, Hashable {
    public var releaseTag: String
    public var schemaVersion: Int
    public var blendID: String
    public init(releaseTag: String = StarterBlendPack.releaseTag,
                schemaVersion: Int = StarterBlendPack.schemaVersion, blendID: String) {
        self.releaseTag = releaseTag; self.schemaVersion = schemaVersion; self.blendID = blendID
    }
}

/// The Starter Blend pack published as the immutable GitHub release `starter-blends-aac-v1`:
/// 36 CC0 AAC-LC `.m4a` files, one per track id, and 30 precomputed edge plans.
public enum StarterBlendPack {
    public static let releaseTag = "starter-blends-aac-v1"
    public static let schemaVersion = 1
    public static let audioFormat = "aac-lc-128k-m4a"
    public static let releaseBaseURL = URL(string:
        "https://github.com/johnarleyburns/parso-tonearm/releases/download/\(releaseTag)/")!
    public static let manifestURL = releaseBaseURL.appendingPathComponent("starter-blend-source.json")
    public static let transitionsURL = releaseBaseURL.appendingPathComponent("starter-transition-candidates.json")

    /// The immutable, versioned URL of one track's audio.
    public static func assetURL(trackID: String) -> URL {
        releaseBaseURL.appendingPathComponent("\(trackID).m4a")
    }

    /// Whether `url` is a Starter Blend release asset (these only play through the range path).
    public static func isReleaseAsset(_ url: URL) -> Bool {
        url.absoluteString.hasPrefix(releaseBaseURL.absoluteString) && url.pathExtension.lowercased() == "m4a"
    }

    /// The numeric track id of a release asset URL.
    public static func trackID(ofAsset url: URL) -> String? {
        isReleaseAsset(url) ? url.deletingPathExtension().lastPathComponent : nil
    }

    private static let factsByID = Dictionary(uniqueKeysWithValues: trackFacts.map { ($0.id, $0) })

    public static func facts(trackID: String) -> StarterTrackFacts? { factsByID[trackID] }

    /// The edge plans of a blend in play order.
    public static func plans(blendID: String) -> [StarterEdgePlan] {
        edgePlans.filter { $0.blendID == blendID }.sorted { $0.edge < $1.edge }
    }

    public static func plan(from outgoing: String, to incoming: String) -> StarterEdgePlan? {
        edgePlans.first { $0.outgoing == outgoing && $0.incoming == incoming }
    }

    /// `unindexed → blendEligible → edgePlanned` for a pack track.
    public static func state(trackID: String) -> BlendTrackState {
        guard factsByID[trackID] != nil else { return .unindexed }
        return edgePlans.contains { $0.outgoing == trackID || $0.incoming == trackID } ? .edgePlanned : .blendEligible
    }
}

/// A release edge plan expressed in the time base of a deck that plays the outgoing track at
/// `outgoingTempo` (the tempo the blend before it left it at; 1 for the first track). This is the
/// exact rescaling the mix engine's `BlendPlan` uses, so a precomputed plan can be handed to the
/// renderer without planning: `blendStart`, `incomingOffset` and `period` shrink by the outgoing
/// tempo, the incoming `tempo` grows by it.
public struct StarterRenderPlan: Sendable, Equatable {
    public let style: StarterEdgePlan.Style
    public let period: Double
    public let tempo: Double
    public let incomingGain: Double
    public let blendStart: Double
    public let incomingOffset: Double
    public let overlapBeats: Int
    public var swapTime: Double { blendStart + Double(overlapBeats / 2) * period }
    public var blendEnd: Double { blendStart + Double(overlapBeats) * period }
}

extension StarterEdgePlan {
    public func renderPlan(outgoingTempo t: Double = 1) -> StarterRenderPlan {
        StarterRenderPlan(style: style, period: period / t, tempo: tempo * t, incomingGain: incomingGain,
                          blendStart: blendStartSeconds / t, incomingOffset: incomingOffsetSeconds / t,
                          overlapBeats: overlapBeats)
    }
}
