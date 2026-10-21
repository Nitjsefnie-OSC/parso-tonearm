import Foundation

/// What Listen hands to the real player for one starter blend: the resolved
/// rows plus the blend's occurrence IDs, in the same order.
public struct StarterPlayRequest: Sendable {
    public let blendID: String
    public let occurrenceIDs: [UUID]
    public let rows: [TrackRow]
    /// True when every edge has a concrete cached plan; false is the safe sequential fallback
    /// the listener chose after preparation could not finish.
    public let isPrepared: Bool

    public init(blendID: String, occurrenceIDs: [UUID], rows: [TrackRow], isPrepared: Bool = true) {
        self.blendID = blendID
        self.occurrenceIDs = occurrenceIDs
        self.rows = rows
        self.isPrepared = isPrepared
    }
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
        /// Downloading/analysing the blend's tracks; `done` of `total` are ready.
        case preparing(done: Int, total: Int)
        /// Preparation could not finish; `reason` says why. Retry, or play sequentially.
        case unprepared(String)
        case failed(String)
    }

    public typealias Fetch = @Sendable (_ ids: [String]) async throws -> [JamendoTrack]
    public typealias Start = @MainActor (StarterPlayRequest) -> Void
    /// Downloads and plans every edge of `rows`, reporting each track's state (the blend into it).
    public typealias Prepare = @MainActor (_ rows: [TrackRow],
                                           _ progress: @escaping @MainActor (Int64, GridPrepState) -> Void) async -> Void

    @Published public private(set) var states: [String: CardState] = [:]

    private let fetch: Fetch
    private let start: Start
    private let prepare: Prepare?
    private var inFlight: Set<String> = []
    private var pending: [String: StarterPlayRequest] = [:]

    public init(fetch: @escaping Fetch, prepare: Prepare? = nil, start: @escaping Start) {
        self.fetch = fetch
        self.prepare = prepare
        self.start = start
    }

    /// Safe fallback after `.unprepared`: plays the resolved tracks one after another, without
    /// promising the designed transitions.
    public func playSequentially(_ blend: StarterBlend) {
        guard case .unprepared = state(for: blend), let request = pending[blend.id] else { return }
        pending[blend.id] = nil
        states[blend.id] = .idle
        start(StarterPlayRequest(blendID: request.blendID, occurrenceIDs: request.occurrenceIDs,
                                 rows: request.rows, isPrepared: false))
    }

    static func reason(for state: GridPrepState?) -> String {
        switch state {
        case .waitingForNetwork?: return "You're offline. Connect to prepare this blend."
        case .waitingForWiFi?: return "Waiting for Wi-Fi to prepare this blend."
        case .cancelled?: return "Preparation was interrupted."
        case .failed(let message)?: return "Couldn't prepare this blend: \(message)"
        default: return "This blend couldn't be fully prepared."
        }
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
            let request = StarterPlayRequest(blendID: blend.id, occurrenceIDs: rowOccurrences, rows: rows)
            if let prepare {
                var prepStates: [Int64: GridPrepState] = [:]
                states[blend.id] = .preparing(done: 0, total: rows.count)
                await prepare(rows) { [weak self] id, state in
                    prepStates[id] = state
                    let done = prepStates.values.filter { $0 == .ready }.count
                    self?.states[blend.id] = .preparing(done: done, total: rows.count)
                }
                let ids = rows.compactMap(\.track.id)
                let blocker = ids.compactMap { prepStates[$0] }.first { $0 != .ready }
                guard ids.count == rows.count, ids.allSatisfy({ prepStates[$0] == .ready }) else {
                    pending[blend.id] = request
                    states[blend.id] = .unprepared(Self.reason(for: blocker))
                    return
                }
            }
            pending[blend.id] = nil
            states[blend.id] = .idle
            start(request)
        } catch {
            let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            states[blend.id] = .failed(message)
        }
    }
}
