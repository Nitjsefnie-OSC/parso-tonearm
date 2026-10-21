// SPDX-License-Identifier: GPL-3.0-or-later
//
// Tonearm (Platterhead DJ) — Copyright (C) 2026 John Arley Burns.
// See ../../LICENSE.

import Foundation
import os.log

/// Where a coordinated read ended up, without any user data (state categories
/// only, safe to log).
public enum SnapshotLoadState: Sendable, Equatable {
    /// The read finished and `Outcome.value` is current.
    case loaded
    /// An earlier read is still blocked (timed out and abandoned). No new read
    /// was admitted; `Outcome.value` is the last known good one, if any.
    case busy
    /// This read exceeded its deadline and was cancelled.
    case timedOut
    /// The read threw. Carries the error description for display.
    case failed(String)
    /// Debounced: a read just failed/timed out, so no new read was started yet.
    case retryingSoon
    /// The coordinator was shut down.
    case cancelled
}

/// Result of one `SnapshotCoordinator.load()`. `value`/`updatedAt` are always
/// the last known good snapshot, never cleared by a failed or in-flight read.
public struct SnapshotOutcome<Value: Sendable>: Sendable {
    public let state: SnapshotLoadState
    public let value: Value?
    public let updatedAt: Date?
    public let generation: Int
}

/// Single-flight, bounded owner of a (possibly blocking) snapshot read.
///
/// - Concurrent `load()` callers join the one in-flight read.
/// - At most ONE underlying read exists at any time. On timeout the read task
///   is cancelled and marked abandoned; while it is still running (a SQLite
///   read blocked inside GRDB cannot actually be interrupted — cancellation
///   only takes effect once the call returns or at its next suspension point)
///   further loads return `.busy` instead of stacking new reads behind it.
/// - A failed/timed-out read debounces the next admission by `retryCooldown`.
/// - `invalidate()` (state changed: e.g. a control action or build completion)
///   makes any in-flight result stale; it is discarded and exactly one fresh
///   read replaces it, so a late old result can never overwrite newer data.
public actor SnapshotCoordinator<Value: Sendable> {
    public typealias Read = @Sendable () async throws -> Value

    private let read: Read
    private let timeout: Duration
    private let retryCooldown: Duration
    private let now: @Sendable () -> Date
    private static var log: Logger { Logger(subsystem: "guru.parso.tonearm", category: "SnapshotCoordinator") }

    private var generation = 0
    private var readTask: Task<Value, Error>?
    private var watchdog: Task<Void, Never>?
    private var abandoned = false
    private var stale = false
    private var waiters: [CheckedContinuation<SnapshotOutcome<Value>, Never>] = []
    private var lastGood: (value: Value, at: Date, generation: Int)?
    private var lastFailure: SnapshotLoadState?
    private var cooldownUntil: ContinuousClock.Instant?
    private var isShutDown = false
    private(set) public var startedReads = 0

    public init(
        timeout: Duration = .seconds(5),
        retryCooldown: Duration = .seconds(1),
        now: @escaping @Sendable () -> Date = { Date() },
        read: @escaping Read
    ) {
        self.timeout = timeout
        self.retryCooldown = retryCooldown
        self.now = now
        self.read = read
    }

    deinit {
        readTask?.cancel()
        watchdog?.cancel()
    }

    /// Number of underlying reads currently alive (0 or 1) — regression
    /// instrumentation for "no task accumulation".
    public var inFlightReadCount: Int { readTask == nil ? 0 : 1 }

    public var lastKnownGood: (value: Value, updatedAt: Date)? {
        lastGood.map { ($0.value, $0.at) }
    }

    public func load() async -> SnapshotOutcome<Value> {
        if isShutDown { return outcome(.cancelled) }
        if readTask != nil {
            if abandoned { return outcome(.busy) }
            return await withCheckedContinuation { waiters.append($0) }
        }
        if let until = cooldownUntil, ContinuousClock.now < until, lastFailure != nil {
            return outcome(.retryingSoon)
        }
        startRead()
        return await withCheckedContinuation { waiters.append($0) }
    }

    /// Marks any in-flight or already-published data as superseded. The old
    /// in-flight read is cancelled and its result discarded; one fresh read is
    /// started when it finishes (or immediately if none is running).
    public func invalidate() {
        cooldownUntil = nil
        if readTask != nil {
            stale = true
            readTask?.cancel()
        }
    }

    /// Cancels everything and releases all waiters.
    public func shutdown() {
        isShutDown = true
        readTask?.cancel()
        watchdog?.cancel()
        finishWaiters(.cancelled)
    }

    // MARK: - Private

    private func outcome(_ state: SnapshotLoadState) -> SnapshotOutcome<Value> {
        SnapshotOutcome(state: state, value: lastGood?.value, updatedAt: lastGood?.at, generation: generation)
    }

    private func startRead() {
        generation += 1
        startedReads += 1
        let gen = generation
        abandoned = false
        stale = false
        let read = self.read
        let task = Task { try await read() }
        readTask = task
        Self.log.info("read start gen=\(gen, privacy: .public)")
        Task { [weak self] in
            let result = await task.result
            await self?.readFinished(gen, result)
        }
        let timeout = self.timeout
        watchdog = Task { [weak self] in
            try? await Task.sleep(for: timeout)
            guard !Task.isCancelled else { return }
            await self?.readTimedOut(gen)
        }
    }

    private func readTimedOut(_ gen: Int) {
        guard gen == generation, readTask != nil, !abandoned else { return }
        // Cooperative cancel only; see type docs for why the read may linger.
        readTask?.cancel()
        abandoned = true
        lastFailure = .timedOut
        cooldownUntil = ContinuousClock.now.advanced(by: retryCooldown)
        Self.log.info("read timed out gen=\(gen, privacy: .public) (abandoned, admission bounded)")
        finishWaiters(.timedOut)
    }

    private func readFinished(_ gen: Int, _ result: Result<Value, Error>) {
        guard gen == generation else { return }
        watchdog?.cancel()
        watchdog = nil
        readTask = nil
        let wasAbandoned = abandoned
        abandoned = false
        if isShutDown { return }

        if stale {
            stale = false
            Self.log.info("stale read discarded gen=\(gen, privacy: .public)")
            startRead()  // waiters (if any) carry over to the fresh read
            return
        }
        switch result {
        case .success(let value):
            // Atomic publish: a single assignment, only ever moving forward.
            if lastGood == nil || gen > lastGood!.generation {
                lastGood = (value, now(), gen)
            }
            lastFailure = nil
            cooldownUntil = nil
            Self.log.info("read done gen=\(gen, privacy: .public) late=\(wasAbandoned, privacy: .public)")
            if !wasAbandoned { finishWaiters(.loaded) }
        case .failure(let error):
            if wasAbandoned { return }  // already reported as timed out
            let state = SnapshotLoadState.failed(error is CancellationError ? "cancelled" : error.localizedDescription)
            lastFailure = state
            cooldownUntil = ContinuousClock.now.advanced(by: retryCooldown)
            Self.log.info("read failed gen=\(gen, privacy: .public)")
            finishWaiters(state)
        }
    }

    private func finishWaiters(_ state: SnapshotLoadState) {
        let pending = waiters
        waiters = []
        let out = outcome(state)
        for w in pending { w.resume(returning: out) }
    }
}
