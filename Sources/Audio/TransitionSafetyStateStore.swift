import Foundation

/// Which part of the risky mix-deck lifecycle is running.
public enum TransitionSafetyPhase: String, Codable, Sendable, Equatable {
    case startingCurrent, decodingCurrent, planningIncoming, scheduled, overlap
}

/// How a risky operation ended cleanly.
public enum TransitionSafetyResolution: String, Codable, Sendable, Equatable {
    case completed, cancelled, safeFallback, userDisabled
}

/// What the listener has been told about a recovery, and chose.
public enum TransitionRecoveryState: String, Codable, Sendable, Equatable {
    case none, noticePending, keptPaused
}

/// The record of one risky mix transition/decode operation. Privacy-safe by
/// construction: opaque ids, phases, timestamps and numbers only — never a
/// title, URL, path, bookmark or artwork.
public struct TransitionSafetyOperation: Codable, Sendable, Equatable {
    public var operationID: String
    public var phase: TransitionSafetyPhase
    public var isActive: Bool
    public var resolution: TransitionSafetyResolution?
    public var startedAt: Date
    public var heartbeatAt: Date
    /// `ProcessInfo.systemUptime` at start / heartbeat; resets on reboot.
    public var startedUptime: TimeInterval
    public var heartbeatUptime: TimeInterval
    public var generation: Int
    public var estimatedBytes: Int64?
}

public struct TransitionSafetyState: Codable, Sendable, Equatable {
    public static let currentVersion = 1
    public var schemaVersion: Int = TransitionSafetyState.currentVersion
    public var operation: TransitionSafetyOperation?
    public var recovery: TransitionRecoveryState = .none
    /// Diagnostics only: interrupted operations seen so far. Never escalates behavior.
    public var interruptedCount: Int = 0
    public var lastInterruptedAt: Date?
}

/// Atomic, versioned file store for the transition-risk sentinel, separate
/// from `PlaybackStateStore`.
public struct TransitionSafetyStateStore: Sendable {
    public enum LoadResult: Equatable, Sendable {
        case missing
        case loaded(TransitionSafetyState)
        /// Unreadable or from an unknown schema version: risk can't be ruled out.
        case unreadable
    }

    public let url: URL

    public init(url: URL) { self.url = url }

    public static var `default`: TransitionSafetyStateStore {
        let base = (try? FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                                 appropriateFor: nil, create: true))
            ?? FileManager.default.temporaryDirectory
        return TransitionSafetyStateStore(url: base.appendingPathComponent("Tonearm")
            .appendingPathComponent("transition-safety.v1.json"))
    }

    public func load() -> LoadResult {
        guard let data = try? Data(contentsOf: url) else { return .missing }
        guard let state = try? JSONDecoder().decode(TransitionSafetyState.self, from: data),
              state.schemaVersion == TransitionSafetyState.currentVersion else { return .unreadable }
        return .loaded(state)
    }

    @discardableResult
    public func save(_ state: TransitionSafetyState) -> Bool {
        guard let data = try? JSONEncoder().encode(state) else { return false }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)
        return (try? data.write(to: url, options: .atomic)) != nil
    }

    func currentState() -> TransitionSafetyState {
        if case .loaded(let state) = load() { return state }
        return TransitionSafetyState()
    }
}

/// Injectable time sources.
public struct TransitionSafetyClock: Sendable {
    public var now: @Sendable () -> Date
    public var uptime: @Sendable () -> TimeInterval
    public init(now: @escaping @Sendable () -> Date, uptime: @escaping @Sendable () -> TimeInterval) {
        self.now = now
        self.uptime = uptime
    }
    public static let system = TransitionSafetyClock(now: { Date() },
                                                     uptime: { ProcessInfo.processInfo.systemUptime })
}

/// Launch-time inspection of the sentinel.
public enum TransitionLaunchRecovery {
    /// A sentinel older than this can't plausibly be from the prior launch.
    public static let maxSuspectAge: TimeInterval = 10 * 60
    public static let everywhereKey = "smartTransitionsEverywhere"

    public struct Outcome: Equatable, Sendable {
        /// Restoration must use plain (AVPlayer) playback this launch.
        public var plainPlayback: Bool
        public var showsNotice: Bool
    }

    /// Decides whether the previous launch was interrupted mid risky operation.
    /// Only `smartTransitionsEverywhere` is touched. Idempotent: the sentinel is
    /// retired in the same write, so a repeated launch changes nothing.
    @discardableResult
    public static func run(store: TransitionSafetyStateStore, defaults: UserDefaults,
                           clock: TransitionSafetyClock = .system) -> Outcome {
        var state: TransitionSafetyState
        var suspect = false
        switch store.load() {
        case .missing:
            return Outcome(plainPlayback: false, showsNotice: false)
        case .unreadable:
            state = TransitionSafetyState()
            suspect = true
        case .loaded(let loaded):
            state = loaded
            if let op = loaded.operation {
                suspect = isSuspect(op, clock: clock)
                state.operation = nil           // retire: a stale or suspect record is consumed once
            }
        }
        if suspect {
            if defaults.bool(forKey: everywhereKey) { defaults.set(false, forKey: everywhereKey) }
            state.interruptedCount += 1
            state.lastInterruptedAt = clock.now()
            if state.recovery != .keptPaused { state.recovery = .noticePending }
            store.save(state)
        } else if case .loaded(let before) = store.load(), before != state {
            store.save(state)
        }
        return Outcome(plainPlayback: suspect, showsNotice: state.recovery == .noticePending)
    }

    static func isSuspect(_ op: TransitionSafetyOperation, clock: TransitionSafetyClock) -> Bool {
        guard op.isActive, op.resolution == nil else { return false }
        let age = clock.now().timeIntervalSince(op.heartbeatAt)
        guard age >= 0, age <= maxSuspectAge else { return false }
        // A reboot resets uptime: the record is from a previous boot, not an interrupted launch.
        return clock.uptime() >= op.heartbeatUptime
    }

    /// Listener chose "Re-enable": clears recovery and turns only Everywhere back on.
    public static func reenable(store: TransitionSafetyStateStore, defaults: UserDefaults) {
        var state = store.currentState()
        state.recovery = .none
        store.save(state)
        defaults.set(true, forKey: everywhereKey)
    }

    /// Listener chose "Keep paused": the safe setting stays and the notice isn't shown again.
    public static func keepPaused(store: TransitionSafetyStateStore) {
        var state = store.currentState()
        state.recovery = .keptPaused
        store.save(state)
    }
}

/// Writes the sentinel around risky mix-deck work.
@MainActor
public final class TransitionSafetyMonitor {
    public static let heartbeatInterval: TimeInterval = 5

    private let store: TransitionSafetyStateStore
    private let clock: TransitionSafetyClock
    private var state: TransitionSafetyState
    private var lastWrite: TimeInterval = 0
    public private(set) var generation = 0

    public init(store: TransitionSafetyStateStore, clock: TransitionSafetyClock = .system) {
        self.store = store
        self.clock = clock
        state = store.currentState()
        state.operation = nil
    }

    public var isActive: Bool { state.operation?.isActive == true }
    public var phase: TransitionSafetyPhase? { isActive ? state.operation?.phase : nil }

    /// Bump when the queue/session changes so records can be told apart.
    public func advanceGeneration() { generation += 1 }

    /// Marks risky work as running in `phase`. Writes before returning, so call
    /// it before the decode or mixer start it protects.
    public func enter(_ phase: TransitionSafetyPhase, estimatedBytes: Int64? = nil) {
        let now = clock.now(), up = clock.uptime()
        if var op = state.operation, op.isActive {
            guard op.phase != phase else { heartbeat(); return }
            op.phase = phase
            op.heartbeatAt = now
            op.heartbeatUptime = up
            if let estimatedBytes { op.estimatedBytes = estimatedBytes }
            state.operation = op
        } else {
            state.operation = TransitionSafetyOperation(
                operationID: UUID().uuidString, phase: phase, isActive: true, resolution: nil,
                startedAt: now, heartbeatAt: now, startedUptime: up, heartbeatUptime: up,
                generation: generation, estimatedBytes: estimatedBytes)
        }
        write(up)
    }

    /// Bounded-rate liveness update; cheap to call from a tick.
    public func heartbeat() {
        guard var op = state.operation, op.isActive else { return }
        let up = clock.uptime()
        guard up - lastWrite >= Self.heartbeatInterval else { return }
        op.heartbeatAt = clock.now()
        op.heartbeatUptime = up
        state.operation = op
        write(up)
    }

    /// Risky work ended cleanly (or reached a stable non-risky state).
    public func resolve(_ resolution: TransitionSafetyResolution) {
        guard var op = state.operation, op.isActive else { return }
        op.isActive = false
        op.resolution = resolution
        op.heartbeatAt = clock.now()
        op.heartbeatUptime = clock.uptime()
        state.operation = op
        write(op.heartbeatUptime)
    }

    private func write(_ up: TimeInterval) {
        lastWrite = up
        // Preserve recovery bookkeeping another writer (the listener's choice) may have changed.
        let onDisk = store.currentState()
        state.recovery = onDisk.recovery
        state.interruptedCount = onDisk.interruptedCount
        state.lastInterruptedAt = onDisk.lastInterruptedAt
        store.save(state)
    }
}
