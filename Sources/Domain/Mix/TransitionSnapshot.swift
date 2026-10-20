import Foundation

/// Identity of one slot in the play queue. Distinct from the track ID so the same
/// track queued twice, reordered, or looped is never ambiguous.
public struct QueueOccurrenceID: Hashable, Sendable, Codable {
    public let rawValue: UUID
    public init(_ rawValue: UUID = UUID()) { self.rawValue = rawValue }
}

/// An edge between two queue occurrences. Snapshots are selected by this key only.
public struct TransitionEdgeKey: Hashable, Sendable, Codable {
    public let from: QueueOccurrenceID
    public let to: QueueOccurrenceID
    public init(from: QueueOccurrenceID, to: QueueOccurrenceID) {
        self.from = from
        self.to = to
    }
}

/// Why an edge has no executable blend plan. Never carries invented timing.
public enum TransitionUnplannedReason: Sendable, Equatable {
    case settingsOff
    case endOfQueue
    case repeatOne
    case notPlannedYet
    case missingTiming
    /// The engine fell back to a sequential handoff; `message` is the engine's reason.
    case fallback(String)
}

public enum TransitionSnapshotState: Sendable, Equatable {
    /// Nothing is known about this edge.
    case unknown
    /// The engine is still preparing/analyzing; no plan yet.
    case checking
    case unplanned(TransitionUnplannedReason)
    case planned
}

/// Tempo mapping of the incoming track onto the outgoing grid.
public struct TransitionTempoMapping: Sendable, Equatable {
    public let blendRate: Double
    public let bpmDeltaPct: Double?
    public init(blendRate: Double, bpmDeltaPct: Double? = nil) {
        self.blendRate = blendRate
        self.bpmDeltaPct = bpmDeltaPct
    }
}

/// Common-output-clock frames (at `sampleRate`) for a planned edge.
public struct TransitionClockFrames: Sendable, Equatable {
    public let start: Int64
    public let handoff: Int64
    public let end: Int64
    public let sampleRate: Double
    public init(start: Int64, handoff: Int64, end: Int64, sampleRate: Double) {
        self.start = start
        self.handoff = handoff
        self.end = end
        self.sampleRate = sampleRate
    }
    /// Frames during which both tracks are audible; zero for a cut with no overlap.
    public var overlapFrames: Int64 { max(end - start, 0) }
}

/// Immutable description of one A→B edge as the engine will (or did) execute it.
/// Fields that are not known are nil; consumers must not infer countdowns, overlap
/// or duration from their absence.
public struct TransitionSnapshot: Sendable, Equatable {
    public let key: TransitionEdgeKey
    public let fromTrackID: Int64?
    public let toTrackID: Int64?
    public let state: TransitionSnapshotState
    /// Actual engine style; nil unless `state == .planned`.
    public let style: TransitionDisplayStyle?
    public let sourceExitSeconds: Double?
    public let sourceEntrySeconds: Double?
    public let frames: TransitionClockFrames?
    public let tempo: TransitionTempoMapping?
    public let preparation: GridPrepState?
    public let confidence: Double?
    /// A future plan computed earlier and not re-verified against the live engine.
    public let isCached: Bool

    public init(key: TransitionEdgeKey, fromTrackID: Int64? = nil, toTrackID: Int64? = nil,
                state: TransitionSnapshotState, style: TransitionDisplayStyle? = nil,
                sourceExitSeconds: Double? = nil, sourceEntrySeconds: Double? = nil,
                frames: TransitionClockFrames? = nil, tempo: TransitionTempoMapping? = nil,
                preparation: GridPrepState? = nil, confidence: Double? = nil, isCached: Bool = false) {
        self.key = key
        self.fromTrackID = fromTrackID
        self.toTrackID = toTrackID
        self.state = state
        self.style = style
        self.sourceExitSeconds = sourceExitSeconds
        self.sourceEntrySeconds = sourceEntrySeconds
        self.frames = frames
        self.tempo = tempo
        self.preparation = preparation
        self.confidence = confidence
        self.isCached = isCached
    }

    public static func unknown(_ key: TransitionEdgeKey) -> TransitionSnapshot {
        TransitionSnapshot(key: key, state: .unknown)
    }

    public static func checking(_ key: TransitionEdgeKey, preparation: GridPrepState? = nil) -> TransitionSnapshot {
        TransitionSnapshot(key: key, state: .checking, preparation: preparation)
    }

    public static func unplanned(_ key: TransitionEdgeKey, _ reason: TransitionUnplannedReason) -> TransitionSnapshot {
        TransitionSnapshot(key: key, state: .unplanned(reason))
    }

    /// Builds a snapshot from an engine plan. A plan without usable timing for an
    /// overlapping style is reported as `.unplanned(.missingTiming)` rather than guessed.
    public static func make(key: TransitionEdgeKey, plan: TransitionPlan, preparation: GridPrepState? = nil,
                            frames: TransitionClockFrames? = nil, displayStyle: TransitionDisplayStyle? = nil,
                            isCached: Bool = false) -> TransitionSnapshot {
        let style = displayStyle ?? TransitionDisplayStyle(plan.style)
        if plan.style == .gapless && plan.downgradedFrom != nil {
            return TransitionSnapshot(key: key, fromTrackID: plan.fromTrackID, toTrackID: plan.toTrackID,
                                      state: .unplanned(.fallback(String(describing: plan.reasons))),
                                      preparation: preparation, isCached: isCached)
        }
        if style.overlaps, plan.overlapSeconds <= 0, frames == nil {
            return TransitionSnapshot(key: key, fromTrackID: plan.fromTrackID, toTrackID: plan.toTrackID,
                                      state: .unplanned(.missingTiming), preparation: preparation, isCached: isCached)
        }
        return TransitionSnapshot(key: key, fromTrackID: plan.fromTrackID, toTrackID: plan.toTrackID,
                                  state: .planned, style: style,
                                  sourceExitSeconds: plan.exitTime, sourceEntrySeconds: plan.entryTime,
                                  frames: frames,
                                  tempo: TransitionTempoMapping(blendRate: plan.blendRate, bpmDeltaPct: plan.bpmDeltaPct),
                                  preparation: preparation,
                                  confidence: plan.confidence > 0 ? plan.confidence : nil, isCached: isCached)
    }
}

/// Holds the active A→B snapshot and the upcoming B→C snapshot independently.
/// The active edge is retained after ownership moves to B until A is inaudible, so a
/// B→C publication can never replace it. Lookup is by exact edge key only.
public struct TransitionSnapshotBook: Sendable, Equatable {
    public private(set) var active: TransitionSnapshot?
    public private(set) var upcoming: TransitionSnapshot?
    /// True after handoff while the outgoing track is still audible.
    public private(set) var isActiveTailAudible = false

    public init() {}

    /// The snapshot for exactly this edge, or nil. Never falls back to another edge.
    public func snapshot(for key: TransitionEdgeKey) -> TransitionSnapshot? {
        if active?.key == key { return active }
        if upcoming?.key == key { return upcoming }
        return nil
    }

    /// Publishes a snapshot. A key matching a held edge replaces it; otherwise it becomes the
    /// active edge when none is held (or the held one is inaudible), else the upcoming edge.
    public mutating func publish(_ snapshot: TransitionSnapshot) {
        if active?.key == snapshot.key {
            active = snapshot
        } else if upcoming?.key == snapshot.key {
            upcoming = snapshot
        } else if active == nil {
            active = snapshot
        } else if isActiveTailAudible || snapshot.key.from == active?.key.to {
            upcoming = snapshot
        } else {
            // A different edge while a non-tail active edge is held: playback jumped.
            active = snapshot
            upcoming = nil
        }
    }

    /// Engine handoff: logical ownership moved to B, A stays audible.
    public mutating func handoffBegan() {
        if active != nil { isActiveTailAudible = true }
    }

    /// A is inaudible: B→C (if any) becomes the active edge.
    public mutating func outgoingInaudible() {
        isActiveTailAudible = false
        active = upcoming
        upcoming = nil
    }

    /// Drops snapshots that no longer match the queue. `order` is the queue's occurrence
    /// IDs; an edge survives only if `to` directly follows `from` (or wraps when `loops`).
    /// The retained, still-audible active edge is exempt until `outgoingInaudible()`.
    public mutating func invalidate(queue order: [QueueOccurrenceID], loops: Bool) {
        func valid(_ key: TransitionEdgeKey) -> Bool {
            guard let i = order.firstIndex(of: key.from) else { return false }
            if i + 1 < order.count { return order[i + 1] == key.to }
            return loops && order.first == key.to
        }
        if let a = active, !(isActiveTailAudible || valid(a.key)) { active = nil }
        if let u = upcoming, !valid(u.key) { upcoming = nil }
    }

    public mutating func reset() {
        active = nil
        upcoming = nil
        isActiveTailAudible = false
    }
}
