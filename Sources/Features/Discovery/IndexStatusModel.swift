// SPDX-License-Identifier: GPL-3.0-or-later
//
// Tonearm (Platterhead DJ) — Copyright (C) 2026 John Arley Burns.
// See ../../../LICENSE.

#if !os(watchOS)
import Foundation
import SwiftUI
import TonearmDiscovery

/// Observable backing model for the sound-index status surface (plan §10, C07).
/// It maps the persisted `IndexStatusSnapshot` (real services —
/// `IndexJobRepository.coverage`, `DiscoverySettingsStore`, `discovery_runtime`)
/// to `IndexStatusPresentation` and exposes the real scheduler controls.
///
/// The pure state → display mapping lives in `TonearmDiscovery`
/// (`IndexStatusPresentation.make`) and is unit-tested there; this class only
/// owns refresh cadence and action plumbing.
@MainActor
final class IndexStatusModel: ObservableObject {
    @Published private(set) var presentation: IndexStatusPresentation?
    @Published private(set) var snapshot: IndexStatusSnapshot?
    @Published private(set) var errorMessage: String?
    @Published var isBusy = false

    /// Why the last refresh did not produce fresh data. `nil` once loaded.
    /// The last good `snapshot`/`presentation` and `lastUpdated` are kept
    /// while this is set, so the screen never blanks or spins.
    @Published private(set) var loadState: SnapshotLoadState?
    @Published private(set) var isLoading = false
    @Published private(set) var lastUpdated: Date?

    private let controller: DiscoveryRuntimeController
    private let coordinator: SnapshotCoordinator<IndexStatusSnapshot>
    private var pollTask: Task<Void, Never>?

    init(controller: DiscoveryRuntimeController = .shared) {
        self.controller = controller
        self.coordinator = SnapshotCoordinator { [controller] in
            try await controller.statusSnapshotOrThrow()
        }
    }

    deinit {
        pollTask?.cancel()
        let coordinator = coordinator
        Task { await coordinator.shutdown() }
    }

    /// Whether the compact Library banner should be shown at all.
    var showsBanner: Bool { presentation?.showsBanner ?? false }

    /// Reads through the single-flight coordinator: concurrent callers join
    /// one read, and a blocked read is bounded rather than stacked.
    func refresh() async {
        isLoading = true
        defer { isLoading = false }
        let outcome = await coordinator.load()
        if outcome.state == .cancelled { return }
        if let snap = outcome.value {
            snapshot = snap
            lastUpdated = outcome.updatedAt
            presentation = IndexStatusPresentation.make(from: snap)
        }
        switch outcome.state {
        case .loaded:
            loadState = nil
            errorMessage = nil
        case .failed(let message):
            loadState = outcome.state
            errorMessage = controller.lastStatusError ?? message
        default:
            loadState = outcome.state
            errorMessage = nil
        }
    }

    /// Discards in-flight/older data after a state change (control action,
    /// build completion) so a late old read cannot overwrite the newer one.
    func invalidateAndRefresh() async {
        await coordinator.invalidate()
        await refresh()
    }

    /// Begin a light poll while a status view is on screen (plan §10.5:
    /// "Publish UI snapshots at most twice per second" — we poll every 2 s).
    func startPolling() {
        guard pollTask == nil else { return }
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refresh()
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }

    func stopPolling() {
        pollTask?.cancel()
        pollTask = nil
    }

    func setPaused(_ paused: Bool) async {
        isBusy = true
        await controller.setPaused(paused)
        await invalidateAndRefresh()
        isBusy = false
    }

    func setChargingOnly(_ on: Bool) async {
        isBusy = true
        await controller.setChargingOnly(on)
        await invalidateAndRefresh()
        isBusy = false
    }

    func setRemoteIndexingEnabled(_ on: Bool) async {
        isBusy = true
        await controller.setRemoteIndexingEnabled(on)
        await invalidateAndRefresh()
        isBusy = false
    }

    func setRemoteIndexingWiFiOnly(_ on: Bool) async {
        isBusy = true
        await controller.setRemoteIndexingWiFiOnly(on)
        await invalidateAndRefresh()
        isBusy = false
    }

    /// Real, current estimate for the "are you sure?" confirmation shown
    /// before letting the user turn off Wi-Fi-only remote sampling.
    func remoteIndexingEstimate() async -> (trackCount: Int, estimatedBytes: Int64) {
        await controller.remoteIndexingEstimate()
    }

    func retryFailed() async {
        isBusy = true
        _ = await controller.retryFailed()
        await invalidateAndRefresh()
        isBusy = false
    }

    /// Manual re-reconcile — real report: reconciliation only runs
    /// automatically at launch, so a setting change or a missed track
    /// mid-session never gets picked up until the next relaunch otherwise.
    @discardableResult
    func enqueueUnindexedTracks() async -> Int {
        isBusy = true
        let count = await controller.enqueueUnindexedTracks()
        await invalidateAndRefresh()
        isBusy = false
        return count
    }

    /// Backs the tappable detail sheet on each `countsCard` row — real track titles for the
    /// bucket the user tapped, on-device only.
    func trackSummaries(for bucket: IndexJobRepository.TrackListBucket) async
        -> [IndexJobRepository.TrackSummary]
    {
        await controller.trackSummaries(for: bucket)
    }

    func diagnosticsText() async -> String {
        guard let diag = await controller.diagnostics() else {
            return String(localized: "Diagnostics unavailable.")
        }
        return diag.plainText() + "\n\n" + diag.jsonString()
    }
}
#endif
