import Foundation

/// What Listen hands to the real player for one starter blend: the rows built from the immutable
/// release assets plus the blend's occurrence IDs, in the same order.
public struct StarterPlayRequest: Sendable {
    public let blendID: String
    public let occurrenceIDs: [UUID]
    public let rows: [TrackRow]
    /// The precomputed plan of every adjacent edge; empty on the sequential fallback, which makes no
    /// claim about transitions.
    public let edgePlans: [StarterEdgePlan]
    /// True when every adjacent edge has a concrete plan.
    public var isPrepared: Bool { !edgePlans.isEmpty && edgePlans.count == rows.count - 1 }

    public init(blendID: String, occurrenceIDs: [UUID], rows: [TrackRow], edgePlans: [StarterEdgePlan] = []) {
        self.blendID = blendID
        self.occurrenceIDs = occurrenceIDs
        self.rows = rows
        self.edgePlans = edgePlans
    }
}

/// Drives the per-card Play of the starter blends. Every track is a versioned GitHub release
/// asset, so a start needs no catalogue lookup, download, model or index: the rows are built
/// from the checked-in pack and playback starts after one small range probe confirms the release
/// is reachable. A failure is scoped to the card that hit it, and a second tap or a recreated view
/// while a start is in flight does not start playback twice.
@MainActor
public final class StarterBlendPlayback: ObservableObject {
    public enum CardState: Equatable, Sendable {
        case idle
        case loading
        /// A release asset could not be reached. `retryable` says whether trying again can help.
        case unavailable(String, retryable: Bool)
    }

    /// Confirms the first asset of a blend is reachable (bounded retry lives in the reader).
    public typealias Probe = @Sendable (_ url: URL) async throws -> Void
    public typealias Start = @MainActor (StarterPlayRequest) -> Void

    @Published public private(set) var states: [String: CardState] = [:]

    private let probe: Probe
    private let start: Start
    private var inFlight: Set<String> = []
    private var pending: [String: StarterPlayRequest] = [:]

    public init(probe: @escaping Probe = StarterBlendPlayback.releaseProbe, start: @escaping Start) {
        self.probe = probe
        self.start = start
    }

    /// The production probe: a one-byte validated range request through `ReleaseRangeReader`.
    public static let releaseProbe: Probe = { url in
        _ = try await ReleaseRangeReader(url: url).contentLength()
    }

    public func state(for blend: StarterBlend) -> CardState { states[blend.id] ?? .idle }

    /// Safe fallback after `.unavailable`: plays the tracks in order from the same release assets,
    /// without promising any transition.
    public func playSequentially(_ blend: StarterBlend) {
        guard case .unavailable(_, retryable: true) = state(for: blend), let request = pending[blend.id] else { return }
        pending[blend.id] = nil
        states[blend.id] = .idle
        start(StarterPlayRequest(blendID: request.blendID, occurrenceIDs: request.occurrenceIDs,
                                 rows: request.rows, edgePlans: []))
    }

    static func message(for error: Error) -> (String, retryable: Bool) {
        if let range = error as? RangeFetchError {
            let retryable = range.isRetryable
            return (retryable ? "Couldn't reach this blend's audio right now. \(range.message)"
                              : "This blend's audio is unavailable. \(range.message)", retryable)
        }
        return ("Couldn't start this blend: \(error.localizedDescription)", true)
    }

    /// Rows for `blend`, one per track, streamed from the release.
    static func rows(for blend: StarterBlend) -> [TrackRow] {
        let source = Source(id: nil, kind: .jamendoGenre, iaIdentifier: blend.id, originalURL: nil,
                            title: blend.title, addedAt: Date(), lastResolvedAt: nil,
                            followUpdates: false, licenseText: StarterBlendCatalog.attribution,
                            memberCapHit: false)
        return blend.trackIDs.enumerated().map { offset, trackID in
            let url = StarterBlendPack.assetURL(trackID: trackID)
            let facts = StarterBlendPack.facts(trackID: trackID)
            let title = "\(blend.title) \(offset + 1)"
            let metadata = RemoteTrackMetadata(title: title, trackNumber: offset + 1,
                                               durationSec: facts?.duration, codec: "AAC",
                                               bitRateKbps: 128, genre: blend.summary.components(separatedBy: " · ").first)
            let node = RemoteNode(id: trackID, title: title, path: url.absoluteString, kind: .audio,
                                  durationSec: facts?.duration, metadata: metadata)
            let resolved = ResolvedAsset(url: url, supportsByteRanges: true, metadata: metadata)
            // Row ids are unique per pack track (`-trackID`), so a pair never collides across blends.
            var row = RemoteTrackRowFactory.row(source: source, node: node, resolved: resolved,
                                                index: (Int(trackID) ?? offset + 1) - 1)
            row.asset?.remoteNodeID = trackID
            return row
        }
    }

    /// Starts the blend. Returns when playback was requested or the card is unavailable.
    public func play(_ blend: StarterBlend) async {
        guard inFlight.insert(blend.id).inserted else { return }
        defer { inFlight.remove(blend.id) }
        states[blend.id] = .loading
        let document = blend.document
        let selectable = Set(blend.selectableTrackIDs)
        // Only catalog blend-eligible tracks may be selected, in the blend's order.
        let pairs = zip(document.occurrences, blend.trackIDs).filter { selectable.contains($0.1) }
        let rows = Self.rows(for: blend).filter { selectable.contains($0.asset?.remoteNodeID ?? "") }
        let request = StarterPlayRequest(blendID: blend.id, occurrenceIDs: pairs.map(\.0.id), rows: rows,
                                         edgePlans: blend.edgePlans)
        guard let first = blend.trackIDs.first else { return }
        do {
            try await probe(StarterBlendPack.assetURL(trackID: first))
        } catch is CancellationError {
            states[blend.id] = .idle
            return
        } catch {
            let (message, retryable) = Self.message(for: error)
            pending[blend.id] = request
            states[blend.id] = .unavailable(message, retryable: retryable)
            return
        }
        pending[blend.id] = nil
        states[blend.id] = .idle
        start(request)
    }
}
