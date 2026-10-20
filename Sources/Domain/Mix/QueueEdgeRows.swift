import Foundation

/// Identity of one queue edge: the outgoing occurrence's position plus both track IDs.
/// The same track queued twice yields distinct keys, and any reorder/delete that changes
/// a neighbour changes the key, so a cached card can never be mistaken for the new edge.
public struct QueueEdgeKey: Hashable, Sendable {
    public let position: Int
    public let fromTrackID: Int64?
    public let toTrackID: Int64?
    public init(position: Int, fromTrackID: Int64?, toTrackID: Int64?) {
        self.position = position
        self.fromTrackID = fromTrackID
        self.toTrackID = toTrackID
    }
}

/// One outgoing edge shown under a queue occurrence.
public struct QueueEdgeRow: Sendable, Equatable, Identifiable {
    public let key: QueueEdgeKey
    public let presentation: TransitionPresentation
    /// Why the edge has no blend plan when that is a queue-level fact (settings, repeat, loop).
    public let reason: String?
    public var id: QueueEdgeKey { key }

    public var timeline: QueueEdgeTimeline { QueueEdgeTimeline(presentation) }
    public var summary: String { reason ?? timeline.summary }
    public var accessibilityLabel: String {
        reason.map { String(localized: "Transition", bundle: .module) + ", " + $0 } ?? timeline.accessibilityLabel
    }
}

/// Builds the per-edge rows for the Queue from the live engine presentation. Live state is
/// attached only to the edge whose track IDs it names; every other edge is "planned when up next".
public enum QueueEdgeResolver {
    public static func rows(trackIDs: [Int64?], currentIndex: Int, repeatMode: RepeatMode,
                            smartBlendEnabled: Bool, live: TransitionPresentation) -> [QueueEdgeRow] {
        guard !trackIDs.isEmpty else { return [] }
        let last = trackIDs.count - 1
        // During an outgoing tail the live A→B edge belongs to the previous occurrence.
        let liveIndex = live.phase == .outgoingTail ? currentIndex - 1 : currentIndex
        var rows: [QueueEdgeRow] = []
        for i in 0...last {
            let loops = i == last && repeatMode == .all && trackIDs.count > 1
            if i == last && !loops { continue } // end of queue: no outgoing edge
            let next = loops ? 0 : i + 1
            let key = QueueEdgeKey(position: i, fromTrackID: trackIDs[i], toTrackID: trackIDs[next])
            var presentation = TransitionPresentation(phase: .notPlanned)
            var reason: String?
            if !smartBlendEnabled {
                reason = String(localized: "Smart transitions are off", bundle: .module)
            } else if repeatMode == .one && i == currentIndex {
                reason = String(localized: "Repeating this track", bundle: .module)
            } else if i == liveIndex, live.phase != .noEdge, matches(live, key) {
                presentation = live
            } else if loops {
                reason = String(localized: "Loops back to the first track", bundle: .module)
            }
            rows.append(QueueEdgeRow(key: key, presentation: presentation, reason: reason))
        }
        return rows
    }

    private static func matches(_ live: TransitionPresentation, _ key: QueueEdgeKey) -> Bool {
        (live.outgoingTrackID == nil || live.outgoingTrackID == key.fromTrackID)
            && (live.incomingTrackID == nil || live.incomingTrackID == key.toTrackID)
    }
}
