#if !os(watchOS)
import XCTest
@testable import TonearmCore

/// Card → request → AudioPlayer → streaming decks → renderer, with procedural sources standing in for
/// the release's byte ranges (everything else is the shipping code).
@MainActor
final class StarterBlendProductionPathTests: XCTestCase {
    private var directory: URL!
    private var suite: String!

    override func setUp() async throws {
        try await super.setUp()
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("tonearm-starter-path-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        PlaybackStateFileStore.fileURLOverride = directory.appendingPathComponent("playback-state.v2.json")
        suite = "test.starter.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        PlaybackStateStore.defaultsProvider = { defaults }
        reset()
    }

    override func tearDown() async throws {
        reset()
        PlaybackStateStore.defaultsProvider = { PlaybackStateStore.sharedDefaults() }
        PlaybackStateFileStore.fileURLOverride = nil
        try? FileManager.default.removeItem(at: directory)
        UserDefaults().removePersistentDomain(forName: suite)
        try await super.tearDown()
    }

    private func reset() {
        let player = AudioPlayer.shared
        player.keepPlayingEnabled = false
        player.keepPlayingProvider = nil
        player.keepPlayingExtensionTask?.cancel()
        player.endStarterSession()
        player.starterSourceFactoryOverride = nil
        player.starterStatusHandler = nil
        player.resetRestoreForTesting()
        if !player.queue.isEmpty { player.removeFromQueue(atOffsets: IndexSet(0..<player.queue.count)) }
        player.repeatMode = .off
        player.shuffle = false
    }

    private func wait(_ stream: () -> StarterStreamPlayer?, timeout: Double = 10, _ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            guard Date() < deadline else {
                let snap = stream()?.snapshot()
                let message = "timed out; snapshot \(String(describing: snap)) index \(AudioPlayer.shared.index)"
                XCTFail(message)
                throw NSError(domain: "StarterTest", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
            }
            try await Task.sleep(nanoseconds: 1_000_000)
            stream()?.tick()
        }
    }

    /// Renders until the stream hands over to track `index` (or `limit` frames pass).
    private func render(until index: Int, player: AudioPlayer, limit: Int = 44_100 * 70) async throws {
        var rendered = 0
        while player.index < index, rendered < limit, let stream = player.starterStream {
            let cell = try XCTUnwrap(stream.cell)
            let pending: BoundedOverlapPlan? = cell.perform { if case .pending(let p) = $0.overlap { return p }; return nil }
            if let pending, let trigger = pending.outgoingTriggerFrame,
               cell.perform({ $0.decks[$0.main].positionFrame }) + 4_096 >= trigger {
                try await wait({ stream }) { cell.perform { $0.decks[$0.incomingIndex].bufferedFrames } >= pending.minIncomingBufferedFrames + 4_096 }
            }
            let main = cell.perform { $0.main }
            try await wait({ stream }) { stream.bufferedFrames(deck: main) >= 4_096 }
            _ = stream.renderOffline(frames: 512)
            rendered += 512
            if (rendered / 512) % 4 == 0 { stream.tick(); await Task.yield() }
        }
        player.starterStream?.tick()
    }

    private func start(_ blend: StarterBlend, factory: SynthCatalog.Factory) async throws -> AudioPlayer {
        let player = AudioPlayer.shared
        player.starterSourceFactoryOverride = factory.make
        let playback = StarterBlendPlayback(start: { player.playStarterBlend($0) })
        await playback.play(blend)
        return player
    }

    func testStartingABlendStreamsOnTheBoundedDecksNotTheResidentOnes() async throws {
        let blend = StarterBlendCatalog.blends[0]
        let factory = SynthCatalog.Factory(blend)
        var statuses: [StarterStreamStatus] = []
        AudioPlayer.shared.starterStatusHandler = { statuses.append($0) }
        let player = try await start(blend, factory: factory)
        XCTAssertEqual(player.activeStarterBlendID, blend.id)
        XCTAssertNotNil(player.starterStream)
        XCTAssertNil(player.mixDecks, "Starter Blends never use the resident whole-track decks")
        XCTAssertFalse(player.wantsMixDecks)
        XCTAssertEqual(player.queue.count, 6)
        XCTAssertEqual(statuses.first, .buffering(blendID: blend.id))
        try await wait({ player.starterStream }) { statuses.contains(.blending(blendID: blend.id)) }
        XCTAssertGreaterThanOrEqual(player.starterStream?.bufferedFrames(deck: 0) ?? 0, 44_100, "started after ordinary buffering")
        XCTAssertTrue(player.isPlaying)
    }

    func testAllFiveEdgesAreConcreteAndReadyAsSoonAsTheBlendIsLoaded() async throws {
        let blend = StarterBlendCatalog.blends[1]
        let player = try await start(blend, factory: SynthCatalog.Factory(blend))
        for i in 0..<5 {
            let key = TransitionEdgeKey(from: player.queueOccurrences[i], to: player.queueOccurrences[i + 1])
            let snapshot = try XCTUnwrap(player.transitionExecution.snapshot(for: key), "edge \(i + 1)")
            let style = AudioPlayer.displayStyle(blend.edgePlans[i].style)
            XCTAssertEqual(snapshot.plannedStyle, style)
            XCTAssertEqual(snapshot.executedStyle, style)
            XCTAssertEqual(snapshot.readiness, .ready)
            XCTAssertNil(snapshot.reason, "no fallback reason")
        }
    }

    func testPlannedEdgeIsExecutedAndPublishedThroughTheProductionPlayer() async throws {
        let blend = StarterBlendCatalog.blends[0]
        let factory = SynthCatalog.Factory(blend)
        let player = try await start(blend, factory: factory)
        let stream = try XCTUnwrap(player.starterStream)
        let plan = blend.edgePlans[0]
        try await wait({ stream }) { !stream.isBuffering }
        // Jump the controller to just before the supplied overlap (what a listener's seek does).
        player.seek(to: (plan.blendStartSeconds ?? 0) - 3)
        try await wait({ stream }) { stream.cell?.perform { if case .pending = $0.overlap { return true }; return false } ?? false }
        try await render(until: 1, player: player)
        XCTAssertEqual(player.index, 1, "the stream advanced the queue at the planned handoff")
        let key = TransitionEdgeKey(from: player.queueOccurrences[0], to: player.queueOccurrences[1])
        let snapshot = try XCTUnwrap(player.transitionExecution.snapshot(for: key))
        XCTAssertEqual(snapshot.executedStyle, .bassSwap)
        XCTAssertTrue(snapshot.isTerminal || snapshot.phase == .handedOff)
        XCTAssertNotNil(snapshot.handoffFrame)
        XCTAssertEqual(player.duration, blend.edgePlans.isEmpty ? 0 : StarterBlendPack.trackFacts[blend.trackIDs[1]]?.durationSeconds ?? 0, accuracy: 0.01)
    }

    func testUnavailableAssetFallsBackToSequentialWithoutClaimingABlend() async throws {
        for (error, retryable) in [(ReleaseRangeError.permanent("not found (HTTP 404)"), false),
                                   (ReleaseRangeError.transient("offline"), true)] {
            reset()
            let blend = StarterBlendCatalog.blends[0]
            let factory = SynthCatalog.Factory(blend)
            factory.failing[blend.trackIDs[2]] = error
            var statuses: [StarterStreamStatus] = []
            AudioPlayer.shared.starterStatusHandler = { statuses.append($0) }
            let player = try await start(blend, factory: factory)
            player.skipToIndex(2)
            try await wait({ player.starterStream }) { player.starterStream == nil && statuses.contains { if case .sequential = $0 { return true }; return false } }
            guard case .sequential(let id, let reason, let canRetry)? = statuses.last else { return XCTFail("\(statuses)") }
            XCTAssertEqual(id, blend.id)
            XCTAssertEqual(canRetry, retryable)
            XCTAssertTrue(reason.hasPrefix("Track 3:"), reason)
            XCTAssertNil(player.starterStream)
            XCTAssertNil(player.mixDecks)
            XCTAssertEqual(player.index, 2, "plays the unavailable track's slot in order")
            XCTAssertTrue(player.transitionExecution.liveSnapshots.isEmpty, "no edge claims a blend")
            XCTAssertFalse(statuses.contains(.blending(blendID: blend.id)) && statuses.last == .blending(blendID: blend.id))
            player.pause()
        }
    }

    func testSavedBlendReplaysWithItsPackAndPlans() async throws {
        let blend = StarterBlendCatalog.blends[3]
        let repo = BlendRepository(url: directory.appendingPathComponent("blends.json"))
        try await repo.save(blend.document)
        let fresh = BlendRepository(url: directory.appendingPathComponent("blends.json"))
        let found = await fresh.blend(id: blend.document.id)
        let saved = try XCTUnwrap(found)
        XCTAssertEqual(saved.pack, .v1)
        XCTAssertEqual(saved.edges.compactMap(\.plan), blend.edgePlans)
        let request = try XCTUnwrap(BlendReplay.starterRequest(for: saved))
        XCTAssertEqual(request.edgePlans, blend.edgePlans)
        XCTAssertEqual(request.trackIDs, blend.trackIDs)
        XCTAssertEqual(request.pack, StarterBlendPack.v1)
        XCTAssertEqual(request.blendID, blend.id)

        let player = AudioPlayer.shared
        player.starterSourceFactoryOverride = SynthCatalog.Factory(blend).make
        player.playStarterBlend(request)
        XCTAssertEqual(player.activeStarterBlendID, blend.id)
        XCTAssertEqual(player.starterSession?.plans, blend.edgePlans, "the persisted plans reach the renderer's session")
        XCTAssertEqual(player.starterSession?.pack, .v1)
        XCTAssertNil(player.mixDecks)
    }

    func testDocumentWithoutPlansDoesNotReplayAsABlend() {
        var doc = StarterBlendCatalog.blends[0].document
        doc.edges[2].plan = nil
        XCTAssertNil(BlendReplay.starterRequest(for: doc))
        doc = StarterBlendCatalog.blends[0].document
        doc.pack = nil
        XCTAssertNil(BlendReplay.starterRequest(for: doc))
    }

    func testKeepPlayingContinuesFromBlendEligibleCatalogTracksWithoutAModel() async throws {
        let blend = StarterBlendCatalog.blends[1]            // deep-focus: catalog candidates exist after its last track
        let factory = SynthCatalog.Factory(blend)
        let player = try await start(blend, factory: factory)
        struct Forbidden: KeepPlayingSimilarityProviding {
            func continuationTrackIDs(after recentlyPlayed: [Int64], excluding: Set<Int64>,
                                      matchingTracksOnly: Bool, limit: Int) async -> KeepPlayingLookup {
                XCTFail("Keep Playing consulted the similarity model for a Starter Blend")
                return .unavailable
            }
        }
        player.keepPlayingProvider = Forbidden()
        player.keepPlayingEnabled = true
        await player.extendKeepPlayingQueueForTesting()
        XCTAssertGreaterThan(player.queue.count, 6)
        let session = try XCTUnwrap(player.starterSession)
        XCTAssertEqual(session.trackIDs.count, player.queue.count)
        XCTAssertEqual(session.plans.count, session.trackIDs.count - 1)
        XCTAssertEqual(Array(session.plans.prefix(5)), blend.edgePlans)
        let catalogRows = try await LibraryStore.shared.blendCatalogTracks(atLeast: .blendEligible)
        let eligible = Set(catalogRows.map(\.trackID))
        for id in session.trackIDs.dropFirst(6) { XCTAssertTrue(eligible.contains(id), "\(id) is blend-eligible") }
        let joining = session.plans[5]
        XCTAssertEqual(joining.outgoingTrackID, blend.trackIDs.last)
        XCTAssertEqual(joining.style, .bassSwap)
        let stored = try await LibraryStore.shared.blendCatalogEdgePlan(
            from: BlendCatalogTrack.key(pack: .v1, trackID: joining.outgoingTrackID),
            to: BlendCatalogTrack.key(pack: .v1, trackID: joining.incomingTrackID))
        XCTAssertEqual(stored, joining, "the derived plan is persisted with the catalog")
        for row in player.queue.dropFirst(6) { XCTAssertTrue(StarterBlendPack.v1.owns(URL(string: row.asset?.remoteURL ?? "")!)) }
    }

    func testKeepPlayingWithNothingEligibleSaysSoInsteadOfGuessing() async throws {
        let blend = StarterBlendCatalog.blends[2]            // night-drive: nothing in the catalog follows its last track
        let player = try await start(blend, factory: SynthCatalog.Factory(blend))
        player.keepPlayingEnabled = true
        await player.extendKeepPlayingQueueForTesting()
        XCTAssertEqual(player.queue.count, 6)
        XCTAssertTrue(player.keepPlayingLastExtensionWasFallback)
        XCTAssertEqual(player.keepPlayingFallbackReason, .unavailable)
    }

    func testAnotherQueueEndsTheStarterSession() async throws {
        let blend = StarterBlendCatalog.blends[0]
        let player = try await start(blend, factory: SynthCatalog.Factory(blend))
        XCTAssertNotNil(player.starterStream)
        player.play(tracks: [StarterBlendPlayback.rows(for: StarterBlendCatalog.blends[1])[0]], startAt: 0)
        // The new queue is itself a plain (non-session) queue.
        XCTAssertNil(player.starterSession)
        XCTAssertNil(player.starterStream)
        player.pause()
    }

    func testReorderedQueueStopsTheBlendAndSaysWhy() async throws {
        let blend = StarterBlendCatalog.blends[0]
        var statuses: [StarterStreamStatus] = []
        AudioPlayer.shared.starterStatusHandler = { statuses.append($0) }
        let player = try await start(blend, factory: SynthCatalog.Factory(blend))
        player.queue.reverse()
        player.starterQueueOrderChanged()
        guard case .sequential(_, let reason, let retryable)? = statuses.last else { return XCTFail("\(statuses)") }
        XCTAssertTrue(reason.contains("queue order changed"))
        XCTAssertFalse(retryable)
        XCTAssertNil(player.starterStream)
        player.pause()
    }
}
#endif
