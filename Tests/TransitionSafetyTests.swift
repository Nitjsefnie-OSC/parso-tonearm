import XCTest
@testable import TonearmCore

private final class TestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var _now = Date(timeIntervalSince1970: 1_000_000)
    private var _up: TimeInterval = 5_000
    var now: Date { lock.withLock { _now } }
    var up: TimeInterval { lock.withLock { _up } }
    func advance(_ s: TimeInterval) { lock.withLock { _now += s; _up += s } }
    var clock: TransitionSafetyClock {
        TransitionSafetyClock(now: { [self] in now }, uptime: { [self] in up })
    }
}

@MainActor
final class TransitionSafetyTests: XCTestCase {
    private var dir: URL!
    private var store: TransitionSafetyStateStore!
    private var defaults: UserDefaults!
    private var clock: TestClock!
    private let suite = "tonearm.transition-safety.tests"

    override func setUp() async throws {
        try await super.setUp()
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("ts-\(UUID().uuidString)")
        store = TransitionSafetyStateStore(url: dir.appendingPathComponent("s.json"))
        defaults = UserDefaults(suiteName: suite)
        defaults.removePersistentDomain(forName: suite)
        defaults.set(true, forKey: "smartTransitionsEverywhere")
        defaults.set(true, forKey: "smartTransitionsEnabled")
        defaults.set("edge-choices", forKey: "perEdge")
        clock = TestClock()
    }

    override func tearDown() async throws {
        defaults.removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(at: dir)
        try await super.tearDown()
    }

    private func monitor() -> TransitionSafetyMonitor { TransitionSafetyMonitor(store: store, clock: clock.clock) }

    func testActiveRecentSentinelPausesOnlyEverywhere() {
        monitor().enter(.planningIncoming)
        clock.advance(5)
        let outcome = TransitionLaunchRecovery.run(store: store, defaults: defaults, clock: clock.clock)
        XCTAssertTrue(outcome.plainPlayback)
        XCTAssertTrue(outcome.showsNotice)
        XCTAssertFalse(defaults.bool(forKey: "smartTransitionsEverywhere"))
        XCTAssertTrue(defaults.bool(forKey: "smartTransitionsEnabled"))
        XCTAssertEqual(defaults.string(forKey: "perEdge"), "edge-choices")
        guard case .loaded(let state) = store.load() else { return XCTFail() }
        XCTAssertEqual(state.interruptedCount, 1)
        XCTAssertNil(state.operation)
    }

    func testPlayerRestoreChoosesPlainPlayback() {
        let player = AudioPlayer.shared
        player.plainRestoreAfterRecovery = true
        player.isRestoring = true
        XCTAssertFalse(player.wantsMixDecks)
        player.isRestoring = false
        player.plainRestoreAfterRecovery = false
    }

    func testCleanResolutionsDoNotTriggerRecovery() {
        for reason in [TransitionSafetyResolution.completed, .cancelled, .safeFallback, .userDisabled] {
            let m = monitor()
            m.enter(.decodingCurrent)
            m.resolve(reason)
            let outcome = TransitionLaunchRecovery.run(store: store, defaults: defaults, clock: clock.clock)
            XCTAssertFalse(outcome.plainPlayback, "\(reason)")
            XCTAssertTrue(defaults.bool(forKey: "smartTransitionsEverywhere"))
        }
    }

    func testStaleSentinelIsRetiredWithoutRecovery() {
        monitor().enter(.overlap)
        clock.advance(TransitionLaunchRecovery.maxSuspectAge + 1)
        let outcome = TransitionLaunchRecovery.run(store: store, defaults: defaults, clock: clock.clock)
        XCTAssertFalse(outcome.plainPlayback)
        XCTAssertTrue(defaults.bool(forKey: "smartTransitionsEverywhere"))
        guard case .loaded(let state) = store.load() else { return XCTFail() }
        XCTAssertNil(state.operation)
    }

    func testRebootedSentinelIsNotSuspect() {
        monitor().enter(.scheduled)
        let rebooted = TransitionSafetyClock(now: { [clock] in clock!.now }, uptime: { 1 })
        XCTAssertFalse(TransitionLaunchRecovery.run(store: store, defaults: defaults, clock: rebooted).plainPlayback)
    }

    func testReenableAndKeepPaused() {
        monitor().enter(.startingCurrent)
        TransitionLaunchRecovery.run(store: store, defaults: defaults, clock: clock.clock)
        TransitionLaunchRecovery.keepPaused(store: store)
        XCTAssertFalse(defaults.bool(forKey: "smartTransitionsEverywhere"))
        // A second interruption after Keep paused pauses again but doesn't re-show the notice.
        monitor().enter(.startingCurrent)
        let again = TransitionLaunchRecovery.run(store: store, defaults: defaults, clock: clock.clock)
        XCTAssertTrue(again.plainPlayback)
        XCTAssertFalse(again.showsNotice)
        TransitionLaunchRecovery.reenable(store: store, defaults: defaults)
        XCTAssertTrue(defaults.bool(forKey: "smartTransitionsEverywhere"))
        guard case .loaded(let state) = store.load() else { return XCTFail() }
        XCTAssertEqual(state.recovery, .none)
    }

    func testWritesBeforeWorkHeartbeatsAndResolves() {
        let m = monitor()
        m.enter(.startingCurrent, estimatedBytes: 1_000)
        guard case .loaded(let first) = store.load() else { return XCTFail("written before work") }
        XCTAssertEqual(first.operation?.isActive, true)
        XCTAssertEqual(first.operation?.phase, .startingCurrent)
        m.heartbeat()   // bounded: too soon, no change
        clock.advance(TransitionSafetyMonitor.heartbeatInterval + 1)
        m.heartbeat()
        guard case .loaded(let beat) = store.load() else { return XCTFail() }
        XCTAssertGreaterThan(beat.operation!.heartbeatAt, first.operation!.heartbeatAt)
        for reason in [TransitionSafetyResolution.completed, .cancelled, .safeFallback] {
            m.enter(.planningIncoming)
            m.resolve(reason)
            guard case .loaded(let done) = store.load() else { return XCTFail() }
            XCTAssertEqual(done.operation?.isActive, false)
            XCTAssertEqual(done.operation?.resolution, reason)
        }
    }

    func testCorruptOrUnknownVersionNeverCrashesAndIsConservative() throws {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data("{not json".utf8).write(to: store.url)
        XCTAssertTrue(TransitionLaunchRecovery.run(store: store, defaults: defaults, clock: clock.clock).plainPlayback)
        var future = TransitionSafetyState()
        future.schemaVersion = 99
        try JSONEncoder().encode(future).write(to: store.url)
        XCTAssertEqual(store.load(), .unreadable)
        XCTAssertTrue(TransitionLaunchRecovery.run(store: store, defaults: defaults, clock: clock.clock).plainPlayback)
        // Missing file is no risk.
        try? FileManager.default.removeItem(at: store.url)
        XCTAssertFalse(TransitionLaunchRecovery.run(store: store, defaults: defaults, clock: clock.clock).plainPlayback)
    }

    func testRecoveryIsIdempotent() {
        monitor().enter(.decodingCurrent)
        _ = TransitionLaunchRecovery.run(store: store, defaults: defaults, clock: clock.clock)
        let data = try? Data(contentsOf: store.url)
        let second = TransitionLaunchRecovery.run(store: store, defaults: defaults, clock: clock.clock)
        XCTAssertFalse(second.plainPlayback)
        XCTAssertTrue(second.showsNotice, "notice stays pending until the listener answers")
        XCTAssertEqual(try? Data(contentsOf: store.url), data, "no write on a repeated launch")
    }

    func testSerializedStateIsPrivacySafe() throws {
        let m = monitor()
        m.enter(.overlap, estimatedBytes: 4_096)
        let text = String(decoding: try Data(contentsOf: store.url), as: UTF8.self).lowercased()
        for forbidden in ["title", "url", "path", "bookmark", "artwork", "file:", "/"] {
            XCTAssertFalse(text.contains(forbidden), forbidden)
        }
    }

    // MARK: Journal assessment, worker lifetime, failures

    func testKillDuringEachPhaseIsInterruptedNotConfirmedCrash() {
        for phase in [TransitionSafetyPhase.decodingCurrent, .planningIncoming, .overlap] {
            try? FileManager.default.removeItem(at: store.url)
            monitor().enter(phase)
            clock.advance(3)
            let outcome = TransitionLaunchRecovery.run(store: store, defaults: defaults, clock: clock.clock)
            guard case .interrupted(_, let seen, .recent) = outcome.assessment else {
                return XCTFail("\(phase): \(outcome.assessment)")
            }
            XCTAssertEqual(seen, phase)
        }
    }

    func testConfirmedCrashNeedsEvidence() {
        let m = monitor()
        m.enter(.overlap)
        guard case .loaded(let s) = store.load(), let id = s.operation?.operationID else { return XCTFail() }
        let outcome = TransitionLaunchRecovery.run(store: store, defaults: defaults, clock: clock.clock,
                                                   confirmedCrashOperationIDs: [id])
        XCTAssertEqual(outcome.assessment, .confirmedCrash(operationID: id, phase: .overlap))
    }

    func testStableForceQuitIsClean() {
        let m = monitor()
        m.enter(.overlap)
        m.resolve(.completed)
        let outcome = TransitionLaunchRecovery.run(store: store, defaults: defaults, clock: clock.clock)
        XCTAssertEqual(outcome.assessment, .clean)
        XCTAssertFalse(outcome.plainPlayback)
    }

    func testCancellationKeepsSentinelUntilWorkerExits() {
        let m = monitor()
        m.enter(.decodingCurrent)
        m.workerStarted()
        m.resolve(.cancelled)
        m.resolve(.completed)
        guard case .loaded(let during) = store.load() else { return XCTFail() }
        XCTAssertEqual(during.operation?.isActive, true, "decode still running")
        clock.advance(TransitionLaunchRecovery.maxSuspectAge * 2)
        m.heartbeat()
        m.workerExited()
        guard case .loaded(let after) = store.load() else { return XCTFail() }
        XCTAssertEqual(after.operation?.isActive, false)
        XCTAssertEqual(after.operation?.resolution, .completed)
    }

    func testRebootAndClockChangeAreClassifiedByUptime() {
        monitor().enter(.planningIncoming)
        let skewed = TransitionSafetyClock(now: { Date(timeIntervalSince1970: 1) }, uptime: { [clock] in clock!.up + 2 })
        guard case .interrupted(_, _, .recent) = TransitionLaunchRecovery.run(store: store, defaults: defaults, clock: skewed).assessment
        else { return XCTFail("clock change must not matter") }
        monitor().enter(.planningIncoming)
        let rebooted = TransitionSafetyClock(now: { [clock] in clock!.now + 86_400 }, uptime: { 1 })
        guard case .interrupted(_, _, .afterReboot) = TransitionLaunchRecovery.run(store: store, defaults: defaults, clock: rebooted).assessment
        else { return XCTFail() }
    }

    func testRepeatedLaunchAssessmentIsIdempotent() {
        monitor().enter(.decodingCurrent)
        _ = TransitionLaunchRecovery.run(store: store, defaults: defaults, clock: clock.clock)
        XCTAssertEqual(TransitionLaunchRecovery.run(store: store, defaults: defaults, clock: clock.clock).assessment, .clean)
    }

    func testUnreadableJournalAssessment() throws {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data("{not json".utf8).write(to: store.url)
        XCTAssertEqual(TransitionLaunchRecovery.run(store: store, defaults: defaults, clock: clock.clock).assessment,
                       .journalUnreadable)
    }

    func testFailedWriteRefusesRiskyWorkAndIsExplicit() throws {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let blocker = dir.appendingPathComponent("file")
        try Data("x".utf8).write(to: blocker)
        let bad = TransitionSafetyStateStore(url: blocker.appendingPathComponent("s.json"))
        let m = TransitionSafetyMonitor(store: bad, clock: clock.clock)
        var started = false
        if m.enter(.decodingCurrent) { started = true }
        XCTAssertFalse(started, "no risky work after a failed journal write")
        XCTAssertTrue(m.lastWriteFailed)
        XCTAssertFalse(m.isActive)
    }

    func testStoredBytesAreOpaqueAndBounded() throws {
        monitor().enter(.planningIncoming, estimatedBytes: 10)
        let text = String(decoding: try Data(contentsOf: store.url), as: UTF8.self)
        let object = try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any]
        let op = object?["operation"] as? [String: Any]
        XCTAssertEqual(Set(op?.keys.map { $0 } ?? []),
                       ["operationID", "phase", "isActive", "startedAt", "heartbeatAt", "startedUptime",
                        "heartbeatUptime", "generation", "estimatedBytes"])
        XCTAssertNotNil(UUID(uuidString: op?["operationID"] as? String ?? ""))
    }
}
