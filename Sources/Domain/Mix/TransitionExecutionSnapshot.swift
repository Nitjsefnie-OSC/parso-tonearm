import Foundation

/// Where an occurrence edge is in its lifecycle. `completed`, `cancelled` and `denied` are terminal.
public enum TransitionExecutionPhase: String, Sendable, Equatable {
    /// Being prepared or scheduled; nothing of the incoming track is audible.
    case upcoming
    /// Both tracks are audible (overlapping styles only).
    case overlapping
    /// Ownership moved to the incoming track; the outgoing tail may still be audible.
    case handedOff
    case completed
    case cancelled
    case denied

    public var isTerminal: Bool { self == .completed || self == .cancelled || self == .denied }
}

/// Why an edge executed differently from how it was requested, or ended without completing.
public enum TransitionExecutionReason: Sendable, Equatable {
    /// The planned blend could not start in time (a seek past it, a slow download).
    case lateForPlannedBlend
    case plainFadeEdge
    case gaplessEdge
    case admissionDenied(String)
    case queueChanged
    case restarted
    case stopped
    case replaced
    case interrupted
}

/// Immutable record of one directed queue edge (outgoing → incoming occurrence) as the
/// production scheduler/renderer executes it. Produced only by `TransitionExecutionLedger`,
/// which owns the sequence numbers; consumers only ever hold copies.
public struct TransitionExecutionSnapshot: Sendable, Equatable {
    public static let currentVersion = 1

    public let version: Int
    public let key: TransitionEdgeKey
    public let queueGeneration: Int
    /// What the listener's settings/edge asked for.
    public let requestedStyle: TransitionDisplayStyle?
    /// What the planner produced.
    public let plannedStyle: TransitionDisplayStyle?
    /// What the renderer actually scheduled/played; nil until it has decided.
    public let executedStyle: TransitionDisplayStyle?
    public let readiness: GridPrepState
    public let phase: TransitionExecutionPhase
    public let reason: TransitionExecutionReason?
    public let sampleRate: Double
    /// Common output-clock frames; nil until the renderer reports them.
    public let overlapStartFrame: Int64?
    public let overlapEndFrame: Int64?
    public let handoffFrame: Int64?
    public let completedFrame: Int64?
    public let createdSequence: UInt64
    public let updateSequence: UInt64

    public var isTerminal: Bool { phase.isTerminal }
    /// Frames during which both tracks were/are audible; zero for a sequential handoff.
    public var overlapFrames: Int64 {
        guard let s = overlapStartFrame, let e = overlapEndFrame, executedStyle?.overlaps == true else { return 0 }
        return max(e - s, 0)
    }
    /// True only when the renderer executed an overlapping blend (not merely planned one).
    public var executedAsOverlap: Bool { executedStyle?.overlaps == true }

    fileprivate init(key: TransitionEdgeKey, generation: Int, created: UInt64, sampleRate: Double) {
        version = Self.currentVersion
        self.key = key
        queueGeneration = generation
        requestedStyle = nil; plannedStyle = nil; executedStyle = nil
        readiness = .notPrepared; phase = .upcoming; reason = nil
        self.sampleRate = sampleRate
        overlapStartFrame = nil; overlapEndFrame = nil; handoffFrame = nil; completedFrame = nil
        createdSequence = created; updateSequence = created
    }

    fileprivate func copy(generation: Int? = nil, sequence: UInt64, requested: TransitionDisplayStyle? = nil,
                          planned: TransitionDisplayStyle? = nil, executed: TransitionDisplayStyle? = nil,
                          readiness: GridPrepState? = nil, phase: TransitionExecutionPhase? = nil,
                          reason: TransitionExecutionReason? = nil, overlapStart: Int64? = nil,
                          overlapEnd: Int64? = nil, handoff: Int64? = nil, completed: Int64? = nil)
        -> TransitionExecutionSnapshot {
        TransitionExecutionSnapshot(copying: self, generation: generation ?? queueGeneration, sequence: sequence,
                                    requested: requested ?? requestedStyle, planned: planned ?? plannedStyle,
                                    executed: executed ?? executedStyle, readiness: readiness ?? self.readiness,
                                    phase: phase ?? self.phase, reason: reason ?? self.reason,
                                    overlapStart: overlapStart ?? overlapStartFrame,
                                    overlapEnd: overlapEnd ?? overlapEndFrame,
                                    handoff: handoff ?? handoffFrame, completed: completed ?? completedFrame)
    }

    private init(copying o: TransitionExecutionSnapshot, generation: Int, sequence: UInt64,
                 requested: TransitionDisplayStyle?, planned: TransitionDisplayStyle?,
                 executed: TransitionDisplayStyle?, readiness: GridPrepState, phase: TransitionExecutionPhase,
                 reason: TransitionExecutionReason?, overlapStart: Int64?, overlapEnd: Int64?,
                 handoff: Int64?, completed: Int64?) {
        version = o.version; key = o.key; queueGeneration = generation
        requestedStyle = requested; plannedStyle = planned; executedStyle = executed
        self.readiness = readiness; self.phase = phase; self.reason = reason
        sampleRate = o.sampleRate
        overlapStartFrame = overlapStart; overlapEndFrame = overlapEnd
        handoffFrame = handoff; completedFrame = completed
        createdSequence = o.createdSequence; updateSequence = sequence
    }
}

/// Publishes occurrence-edge execution snapshots with a bounded lifecycle. Value type: a copy
/// handed to a consumer never changes. Writes carrying an obsolete queue generation, or aimed at
/// a terminal edge, are rejected, so a late completion cannot resurrect or overwrite current state.
public struct TransitionExecutionLedger: Sendable, Equatable {
    public static let recentLimit = 8
    public private(set) var generation = 0
    public private(set) var sequence: UInt64 = 0
    /// Upcoming and active (non-terminal) edges.
    public private(set) var live: [TransitionEdgeKey: TransitionExecutionSnapshot] = [:]
    /// Most recent terminal edges, oldest first, at most `recentLimit`.
    public private(set) var recent: [TransitionExecutionSnapshot] = []

    public init() {}

    public func snapshot(for key: TransitionEdgeKey) -> TransitionExecutionSnapshot? {
        live[key] ?? recent.last(where: { $0.key == key })
    }

    /// Live snapshots ordered by creation.
    public var liveSnapshots: [TransitionExecutionSnapshot] { live.values.sorted { $0.createdSequence < $1.createdSequence } }
    /// The edge currently audible (overlapping, or handed off with a tail), if any.
    public var active: TransitionExecutionSnapshot? {
        liveSnapshots.first { $0.phase == .overlapping || $0.phase == .handedOff }
    }
    public var upcoming: [TransitionExecutionSnapshot] { liveSnapshots.filter { $0.phase == .upcoming } }

    public enum Update: Sendable {
        case scheduled(requested: TransitionDisplayStyle?, planned: TransitionDisplayStyle?,
                       executed: TransitionDisplayStyle, readiness: GridPrepState, reason: TransitionExecutionReason?,
                       overlapStart: Int64?, overlapEnd: Int64?, handoff: Int64?, sampleRate: Double)
        case readiness(GridPrepState)
        case overlapBegan(atFrame: Int64)
        case handedOff(atFrame: Int64)
        case completed(atFrame: Int64)
        case denied(TransitionExecutionReason, readiness: GridPrepState)
    }

    /// Applies a renderer report. Returns false (and changes nothing) when the generation is
    /// obsolete or the edge is already terminal.
    @discardableResult
    public mutating func record(_ key: TransitionEdgeKey, generation gen: Int, _ update: Update) -> Bool {
        guard gen >= generation else { return false }
        if gen > generation { generation = gen }
        // Only scheduling and readiness may create an edge; a late progress report for an edge that
        // is gone (cancelled, completed, replaced) is dropped instead of resurrecting it.
        if live[key] == nil {
            switch update {
            case .scheduled, .readiness, .denied: break
            default: return false
            }
        }
        sequence += 1
        var s = live[key] ?? TransitionExecutionSnapshot(key: key, generation: gen, created: sequence, sampleRate: 48_000)
        switch update {
        case let .scheduled(req, plan, exec, ready, reason, os, oe, h, sr):
            s = TransitionExecutionSnapshot(key: key, generation: gen, created: s.createdSequence, sampleRate: sr)
                .copy(sequence: sequence, requested: req, planned: plan, executed: exec, readiness: ready,
                      phase: .upcoming, reason: reason, overlapStart: os, overlapEnd: oe, handoff: h)
        case .readiness(let r):
            s = s.copy(generation: gen, sequence: sequence, readiness: r)
        case .overlapBegan(let f):
            guard s.executedAsOverlap else { sequence -= 1; return false }
            s = s.copy(sequence: sequence, phase: .overlapping, overlapStart: f)
        case .handedOff(let f):
            s = s.copy(sequence: sequence, phase: .handedOff, handoff: f)
        case .completed(let f):
            s = s.copy(sequence: sequence, phase: .completed, completed: f)
        case let .denied(reason, ready):
            s = s.copy(sequence: sequence, readiness: ready, phase: .denied, reason: reason)
        }
        store(s)
        return true
    }

    /// The queue changed. Edges whose `to` no longer directly follows `from` are cancelled; the
    /// handed-off edge keeps its audible tail. Survivors are re-stamped into the new generation.
    public mutating func advanceGeneration(order: [QueueOccurrenceID], loops: Bool) {
        generation += 1
        func valid(_ key: TransitionEdgeKey) -> Bool {
            guard let i = order.firstIndex(of: key.from) else { return false }
            if i + 1 < order.count { return order[i + 1] == key.to }
            return loops && order.first == key.to
        }
        for (key, s) in live {
            if s.phase == .handedOff || valid(key) {
                sequence += 1
                live[key] = s.copy(generation: generation, sequence: sequence)
            } else {
                cancel(key, reason: .queueChanged)
            }
        }
    }

    /// The tail of a handed-off edge is inaudible.
    public mutating func outgoingFinished(_ key: TransitionEdgeKey, generation gen: Int, atFrame frame: Int64) {
        record(key, generation: gen, .completed(atFrame: frame))
    }

    /// Cancels every non-terminal edge (restart, stop, replacement, interruption, route change).
    public mutating func cancelAll(reason: TransitionExecutionReason) {
        for key in live.keys { cancel(key, reason: reason) }
    }

    public mutating func reset() {
        live = [:]
        recent = []
    }

    private mutating func cancel(_ key: TransitionEdgeKey, reason: TransitionExecutionReason) {
        guard let s = live[key] else { return }
        sequence += 1
        store(s.copy(sequence: sequence, phase: .cancelled, reason: reason))
    }

    private mutating func store(_ s: TransitionExecutionSnapshot) {
        if s.isTerminal {
            live[s.key] = nil
            recent.append(s)
            if recent.count > Self.recentLimit { recent.removeFirst(recent.count - Self.recentLimit) }
        } else {
            live[s.key] = s
        }
    }
}
