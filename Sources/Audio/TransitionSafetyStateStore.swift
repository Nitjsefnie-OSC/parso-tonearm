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

/// What a launch learned about the previous run's risky transition work.
/// UI-agnostic: a separate policy decides what to do with it.
public enum TransitionRecoveryAssessment: Equatable, Sendable {
    public enum Context: String, Equatable, Sendable {
        /// Same boot, within `TransitionLaunchRecovery.maxSuspectAge` of the last heartbeat (monotonic).
        case recent
        /// Same boot but long ago, so unlikely to be the previous launch.
        case stale
        /// Written on an earlier boot.
        case afterReboot
    }
    /// No unresolved risky work. An ordinary force-quit while stable lands here.
    case clean
    /// Risky work was unresolved. The cause is unknown (force-quit, jetsam, crash, power loss):
    /// never reported as a crash without evidence.
    case interrupted(operationID: String, phase: TransitionSafetyPhase, context: Context)
    /// Interrupted, and the caller supplied independent crash evidence for this operation ID.
    case confirmedCrash(operationID: String, phase: TransitionSafetyPhase)
    /// The journal could not be read or decoded; risk can't be ruled out.
    case journalUnreadable
    /// The journal could not be rewritten after evaluation; the record stays for the next launch.
    case journalWriteFailed
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
        public var assessment: TransitionRecoveryAssessment = .clean
    }

    /// Decides whether the previous launch was interrupted mid risky operation.
    /// Only `smartTransitionsEverywhere` is touched. Idempotent: the sentinel is
    /// retired in the same write, so a repeated launch changes nothing.
    @discardableResult
    public static func run(store: TransitionSafetyStateStore, defaults: UserDefaults,
                           clock: TransitionSafetyClock = .system,
                           confirmedCrashOperationIDs: Set<String> = []) -> Outcome {
        var state: TransitionSafetyState
        var suspect = false
        var assessment = TransitionRecoveryAssessment.clean
        switch store.load() {
        case .missing:
            return Outcome(plainPlayback: false, showsNotice: false)
        case .unreadable:
            state = TransitionSafetyState()
            suspect = true
            assessment = .journalUnreadable
        case .loaded(let loaded):
            state = loaded
            if let op = loaded.operation {
                if op.isActive, op.resolution == nil {
                    let context = context(of: op, clock: clock)
                    suspect = context == .recent
                    assessment = confirmedCrashOperationIDs.contains(op.operationID)
                        ? .confirmedCrash(operationID: op.operationID, phase: op.phase)
                        : .interrupted(operationID: op.operationID, phase: op.phase, context: context)
                    if case .confirmedCrash = assessment { suspect = true }
                }
                state.operation = nil           // retire: a stale or suspect record is consumed once
            }
        }
        if suspect {
            if defaults.bool(forKey: everywhereKey) { defaults.set(false, forKey: everywhereKey) }
            state.interruptedCount += 1
            state.lastInterruptedAt = clock.now()
            if state.recovery != .keptPaused { state.recovery = .noticePending }
            if !store.save(state) { assessment = .journalWriteFailed }
        } else if case .loaded(let before) = store.load(), before != state {
            if !store.save(state) { assessment = .journalWriteFailed }
        }
        let failedWrite = assessment == .journalWriteFailed
        return Outcome(plainPlayback: suspect || failedWrite,
                       showsNotice: state.recovery == .noticePending, assessment: assessment)
    }

    /// Classifies an unresolved record using uptime only, so wall-clock changes can't affect it.
    /// A reboot resets uptime: such a record is from a previous boot, not an interrupted launch.
    static func context(of op: TransitionSafetyOperation,
                        clock: TransitionSafetyClock) -> TransitionRecoveryAssessment.Context {
        let elapsed = clock.uptime() - op.heartbeatUptime
        guard elapsed >= 0 else { return .afterReboot }
        return elapsed <= maxSuspectAge ? .recent : .stale
    }

    static func isSuspect(_ op: TransitionSafetyOperation, clock: TransitionSafetyClock) -> Bool {
        guard op.isActive, op.resolution == nil else { return false }
        return context(of: op, clock: clock) == .recent
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
    /// True when the most recent journal write failed. Explicit, never retried silently.
    public private(set) var lastWriteFailed = false
    /// Decode/planning workers still running. The sentinel outlives logical
    /// handoff and cancellation until every one has actually exited.
    public private(set) var activeWorkers = 0
    private var deferredResolution: TransitionSafetyResolution?

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
    /// Returns false when the journal could not be written; the caller must then not start the risky work.
    @discardableResult
    public func enter(_ phase: TransitionSafetyPhase, estimatedBytes: Int64? = nil) -> Bool {
        deferredResolution = nil
        let now = clock.now(), up = clock.uptime()
        let previous = state.operation
        if var op = state.operation, op.isActive {
            guard op.phase != phase else { heartbeat(); return !lastWriteFailed }
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
        if write(up) { return true }
        state.operation = previous      // not journaled, so not active: the caller must not start the work
        return false
    }

    /// A decode/planning worker is about to run. Call after a successful `enter`.
    public func workerStarted() { activeWorkers += 1 }

    /// The worker has really exited (not merely been cancelled). Applies a deferred resolution.
    public func workerExited() {
        guard activeWorkers > 0 else { return }
        activeWorkers -= 1
        if activeWorkers == 0, let deferred = deferredResolution {
            deferredResolution = nil
            resolve(deferred)
        }
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
    /// While a worker is still running the sentinel stays active; the resolution applies when it exits.
    public func resolve(_ resolution: TransitionSafetyResolution) {
        guard var op = state.operation, op.isActive else { return }
        if activeWorkers > 0 { deferredResolution = resolution; return }
        op.isActive = false
        op.resolution = resolution
        op.heartbeatAt = clock.now()
        op.heartbeatUptime = clock.uptime()
        state.operation = op
        write(op.heartbeatUptime)
    }

    @discardableResult
    private func write(_ up: TimeInterval) -> Bool {
        lastWrite = up
        // Preserve recovery bookkeeping another writer (the listener's choice) may have changed.
        let onDisk = store.currentState()
        state.recovery = onDisk.recovery
        state.interruptedCount = onDisk.interruptedCount
        state.lastInterruptedAt = onDisk.lastInterruptedAt
        let ok = store.save(state)
        lastWriteFailed = !ok
        return ok
    }
}
