import Foundation

/// What Listen hands to the real player for one starter blend: the resolved
/// rows plus the blend's occurrence IDs, in the same order.
public struct StarterPlayRequest: Sendable {
    public let blendID: String
    public let occurrenceIDs: [UUID]
    public let rows: [TrackRow]
}

/// Drives the per-card Play of the starter blends. Resolution goes through the
/// existing Jamendo route (`JamendoAPI` → `JamendoGenreProvider.resolve` →
/// `RemoteTrackRowFactory`) and never waits on CLAP/model/index readiness. A
/// failure is scoped to the card that hit it, and a second tap or a recreated
/// view while a start is in flight does not start playback twice.
@MainActor
public final class StarterBlendPlayback: ObservableObject {
    public enum CardState: Equatable, Sendable {
        case idle
        case loading
        case failed(String)
    }

    public typealias Fetch = @Sendable (_ ids: [String]) async throws -> [JamendoTrack]
    public typealias Start = @MainActor (StarterPlayRequest) -> Void

    @Published public private(set) var states: [String: CardState] = [:]

    private let fetch: Fetch
    private let start: Start
    private var inFlight: Set<String> = []

    public init(fetch: @escaping Fetch, start: @escaping Start) {
        self.fetch = fetch
        self.start = start
    }

    public func state(for blend: StarterBlend) -> CardState { states[blend.id] ?? .idle }

    /// Starts the blend. Returns when playback was requested or the card failed.
    public func play(_ blend: StarterBlend) async {
        guard inFlight.insert(blend.id).inserted else { return }
        defer { inFlight.remove(blend.id) }
        states[blend.id] = .loading
        do {
            let tracks = try await fetch(blend.jamendoTrackIDs)
            let byID = Dictionary(tracks.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            let document = blend.document
            var occurrenceIDs: [UUID] = []
            var ordered: [JamendoTrack] = []
            for (occurrence, trackID) in zip(document.occurrences, blend.jamendoTrackIDs) {
                guard let track = byID[trackID] else { continue }
                occurrenceIDs.append(occurrence.id)
                ordered.append(track)
            }
            guard !ordered.isEmpty else { throw JamendoGenreError.catalogue("no playable tracks") }

            let provider = JamendoGenreProvider(clientID: "")
            let source = Source(id: nil, kind: .jamendoGenre, iaIdentifier: blend.id, originalURL: nil,
                                title: blend.title, addedAt: Date(), lastResolvedAt: nil,
                                followUpdates: false, licenseText: StarterBlendCatalog.attribution,
                                memberCapHit: false)
            var rows: [TrackRow] = []
            var rowOccurrences: [UUID] = []
            for (index, (node, occurrenceID)) in zip(JamendoGenreProvider.nodes(from: ordered),
                                                      occurrenceIDs).enumerated() {
                guard let resolved = try? await provider.resolve(node: node) else { continue }
                rows.append(RemoteTrackRowFactory.row(source: source, node: node,
                                                      resolved: resolved, index: index))
                rowOccurrences.append(occurrenceID)
            }
            guard !rows.isEmpty else { throw JamendoGenreError.transport }
            states[blend.id] = .idle
            start(StarterPlayRequest(blendID: blend.id, occurrenceIDs: rowOccurrences, rows: rows))
        } catch {
            let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            states[blend.id] = .failed(message)
        }
    }
}
