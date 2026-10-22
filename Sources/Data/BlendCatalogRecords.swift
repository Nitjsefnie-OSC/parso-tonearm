import Foundation
import GRDB

/// Persistent catalog row for one blendable track: its lifecycle state and every fact a blend needs.
/// `catalogKey` is `<pack release tag>:<track id>` for Starter assets.
public struct BlendCatalogTrack: Codable, Equatable, Sendable, FetchableRecord, PersistableRecord {
    public static let databaseTableName = "blend_catalog_track"
    public var catalogKey: String
    public var packTag: String
    public var state: BlendCatalogState
    public var durationSeconds: Double?
    public var bpm: Double?
    public var beatPeriod: Double?
    public var beatPhase: Double?
    public var rmsDB: Double?
    public var updatedAt: Date

    public static func key(pack: StarterBlendPack, trackID: String) -> String { "\(pack.releaseTag):\(trackID)" }

    public var trackID: String { String(catalogKey.split(separator: ":", maxSplits: 1).last ?? "") }

    /// The stored facts, when complete.
    public var facts: StarterTrackFacts? {
        guard let durationSeconds, let bpm, let beatPeriod, let beatPhase, let rmsDB else { return nil }
        return StarterTrackFacts(id: trackID, durationSeconds: durationSeconds, bpm: bpm, beatPeriod: beatPeriod,
                                 beatPhase: beatPhase, rmsDB: rmsDB)
    }
}

/// A concrete edge plan stored with the catalog (supplied by a pack, or derived from catalog facts).
public struct BlendCatalogEdge: Codable, Equatable, Sendable, FetchableRecord, PersistableRecord {
    public static let databaseTableName = "blend_catalog_edge"
    public var fromKey: String
    public var toKey: String
    public var packTag: String
    public var planJSON: Data

    public var plan: StarterEdgePlan? { try? JSONDecoder().decode(StarterEdgePlan.self, from: planJSON) }
}
