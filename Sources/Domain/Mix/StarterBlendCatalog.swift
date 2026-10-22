import Foundation

/// The built-in, deterministic set of six Starter Blends Listen shows before any model
/// download, indexing, sign-in or library scan. Metadata only: ordered pack track ids and the
/// precomputed plan of every edge. Audio is range-streamed from the immutable GitHub release
/// `StarterBlendPack.releaseTag`; nothing is downloaded or analysed ahead of playing.
public struct StarterBlend: Identifiable, Sendable, Equatable {
    public let id: String
    public let title: String
    /// Short mood/tempo line shown on the card.
    public let summary: String
    /// SF Symbol and hue (0…1) drawn when no artwork is available.
    public let artworkSymbol: String
    public let artworkHue: Double
    /// Pack track ids, in play order (also the release asset names).
    public let trackIDs: [String]
    /// `TransitionStyle.rawValue` requested between every adjacent pair.
    public let requestedStyle: String

    /// Stable, restart-safe document for this blend. Blend and occurrence UUIDs
    /// are derived from the catalog position so they never change between
    /// launches or devices.
    public var document: BlendDocument {
        StarterBlendCatalog.document(for: self)
    }

    /// The concrete plan of every adjacent edge, in play order.
    public var edgePlans: [StarterEdgePlan] { StarterBlendPack.plans(blendID: id) }

    public var packIdentity: StarterPackIdentity { StarterPackIdentity(blendID: id) }

    /// The tracks that may be selected: catalog state `blendEligible` or later.
    public var selectableTrackIDs: [String] {
        trackIDs.filter { StarterBlendPack.state(trackID: $0).isSelectable }
    }
}

public enum StarterBlendCatalog {
    public static let creditsURL = URL(string: "https://www.jamendo.com/about")!
    public static let attribution = "Music from Jamendo, released under CC0 and hosted by Tonearm."

    private static let epoch = Date(timeIntervalSince1970: 1_767_225_600)

    public static let blends: [StarterBlend] = [
        make("starter.morning-light", "Morning Light", "Singer-Songwriter · gentle and bright, slow to mid tempo",
             "sunrise.fill", 0.10, ["337997", "1424003", "337069", "1180864", "642026", "1077690"]),
        make("starter.deep-focus", "Deep Focus", "Ambient · calm, steady and unobtrusive, slow tempo",
             "brain.head.profile", 0.58, ["455018", "117009", "971563", "1097061", "26403", "1100130"]),
        make("starter.night-drive", "Night Drive", "Synthwave · moody electronic pulse, mid tempo",
             "car.fill", 0.72, ["1163782", "1828808", "1121468", "1739551", "1493402", "1560522"]),
        make("starter.acoustic-evening", "Acoustic Evening", "Singer-Songwriter · warm guitars and voices, relaxed tempo",
             "guitars.fill", 0.07, ["1229422", "398193", "1418240", "1308980", "1849464", "1212932"]),
        make("starter.upbeat-energy", "Upbeat Energy", "Dance Pop · driving and positive, fast tempo",
             "bolt.fill", 0.95, ["2053669", "2228244", "1901830", "2126638", "2133921", "1977152"]),
        make("starter.rainy-day", "Rainy Day", "Contemporary Piano · soft piano and ambient textures, very slow",
             "cloud.rain.fill", 0.55, ["1891078", "1891935", "1974389", "2220789", "2169489", "1960412"])
    ]

    public static func blend(id: String) -> StarterBlend? { blends.first { $0.id == id } }

    /// The blend a saved document replays, from its pack identity (never from a title).
    /// Nil when it was made from another pack version, which this build cannot replay.
    public static func blend(replaying document: BlendDocument) -> StarterBlend? {
        guard let pack = document.pack, pack.releaseTag == StarterBlendPack.releaseTag,
              pack.schemaVersion == StarterBlendPack.schemaVersion else { return nil }
        return blend(id: pack.blendID)
    }

    /// Pack track id behind a document occurrence (`starter:<tag>:<id>`).
    public static func trackID(of occurrence: BlendDocument.Occurrence) -> String? {
        let prefix = "starter:\(StarterBlendPack.releaseTag):"
        guard let sync = occurrence.source.syncID, sync.hasPrefix(prefix) else { return nil }
        return String(sync.dropFirst(prefix.count))
    }

    private static func make(_ id: String, _ title: String, _ summary: String,
                             _ symbol: String, _ hue: Double, _ tracks: [String]) -> StarterBlend {
        StarterBlend(id: id, title: title, summary: summary, artworkSymbol: symbol, artworkHue: hue,
                     trackIDs: tracks, requestedStyle: TransitionStyle.beatmatchedBlend.rawValue)
    }

    /// The `BlendDocument` for a starter blend (origin `.starter`): its ordered, unique,
    /// edge-planned tracks, the concrete plan on every edge and the pack identity to replay it.
    static func document(for blend: StarterBlend) -> BlendDocument {
        let index = blends.firstIndex { $0.id == blend.id } ?? 0
        let occurrences = blend.trackIDs.enumerated().map { offset, trackID in
            BlendDocument.Occurrence(
                id: stableUUID(blend: index, slot: offset + 1),
                source: .init(syncID: "starter:\(StarterBlendPack.releaseTag):\(trackID)",
                              title: "Track \(trackID)", isRemote: true))
        }
        let plans = blend.edgePlans
        var document = BlendDocument(id: stableUUID(blend: index, slot: 0), title: blend.title,
                             artworkReference: nil, origin: .starter, now: epoch,
                             occurrences: occurrences,
                             requestedStyles: Array(repeating: blend.requestedStyle,
                                                    count: max(0, occurrences.count - 1)),
                             pack: blend.packIdentity)
        for edge in document.edges.indices {
            document.edges[edge].id = stableUUID(blend: index, slot: 0x1000 + edge)
            document.edges[edge].plan = plans.first {
                $0.outgoing == blend.trackIDs[edge] && $0.incoming == blend.trackIDs[edge + 1]
            }
            if let plan = document.edges[edge].plan {
                document.edges[edge].requestedStyle = (plan.style == .phraseCut
                    ? TransitionStyle.phraseFade : TransitionStyle.beatmatchedBlend).rawValue
            }
        }
        return document
    }

    private static func stableUUID(blend: Int, slot: Int) -> UUID {
        UUID(uuidString: String(format: "5EED0000-%04X-4000-8000-%012X", blend, slot))!
    }
}
