#if !os(watchOS)
import XCTest
@testable import TonearmCore

/// Drives the real `AudioPlayer` through the production execution-event path
/// (`mixDecksExecution` → ledger → `transitionPresentation` / `displayedTransitionSnapshot`) and
/// checks what the Now Playing overlap card would render. Removing the snapshot adapter from
/// `AudioPlayer.transitionPresentation` makes these fail.
@MainActor
final class NowPlayingOverlapCardTests: XCTestCase {
    private let source = Source(id: 1, kind: .iaItem, iaIdentifier: "x", originalURL: nil,
                                title: "S", addedAt: Date(), lastResolvedAt: nil,
                                followUpdates: false, licenseText: nil, memberCapHit: false)

    private func row(_ id: Int64) -> TrackRow {
        let track = Track(id: id, albumId: 1, sourceId: 1, title: "Track \(id)", trackNo: nil, discNo: nil,
                          durationSec: 180, codec: "MP3", sampleRate: nil, bitDepthOrBitrate: nil, sortKey: "\(id)")
        let asset = Asset(id: id, trackId: id, kind: .remote, bookmark: nil, relPath: nil,
                          remoteURL: "https://example.invalid/\(id).mp3", altRemoteURL: nil,
                          sizeBytes: nil, unsupportedReason: nil)
        return TrackRow(track: track, album: Album(id: 1, sourceId: 1, title: "A", artist: nil),
                        source: source, asset: asset)
    }

    private var player: AudioPlayer { AudioPlayer.shared }

    override func setUp() async throws {
        player.queue = [row(1), row(2)]
        player.index = 0
        player.repeatMode = .off
        player.isOutgoingTransitionTailAudible = false
        player.transitionPrepState = .ready
        player.transitionPlan = TransitionPlan(fromTrackID: 1, toTrackID: 2, style: .beatmatchedBlend,
                                               exitTime: 100, overlapSeconds: 12, confidence: 0.8)
        player.currentTime = 106
    }

    override func tearDown() async throws {
        player.transitionExecution.cancelAll(reason: .stopped)
        player.transitionPlan = nil
        player.currentTime = 0
        player.queue = []
    }

    private var key: TransitionEdgeKey {
        TransitionEdgeKey(from: player.queueOccurrences[0], to: player.queueOccurrences[1])
    }

    private func schedule(executed: TransitionDisplayStyle, reason: TransitionExecutionReason? = nil) {
        let overlaps = executed.overlaps
        player.mixDecksExecution(.scheduled(key: key, generation: player.mixDecksQueueGeneration,
                                            requested: .beatMatched, planned: .beatMatched, executed: executed,
                                            reason: reason, overlapStartFrame: overlaps ? 4_800_000 : nil,
                                            overlapEndFrame: overlaps ? 4_800_000 + 576_000 : nil,
                                            handoffFrame: 5_376_000, sampleRate: 48_000))
    }

    func testActiveOverlapRendersExecutedStyleAndRealTiming() throws {
        schedule(executed: .plainCrossfade)
        player.mixDecksExecution(.overlapBegan(key: key, generation: player.mixDecksQueueGeneration, atFrame: 4_800_000))
        let p = player.transitionPresentation
        XCTAssertEqual(p.phase, .overlap)
        XCTAssertEqual(p.plannedStyle, .beatMatched)
        XCTAssertEqual(p.actualStyle, .plainCrossfade, "executed style, not the planned one")
        let m = try XCTUnwrap(OverlapCardModel(p, snapshot: player.displayedTransitionSnapshot, position: player.currentTime))
        XCTAssertEqual(m.styleLabel, "Crossfade")
        XCTAssertEqual(m.rail, .overlapNow)
        XCTAssertEqual(try XCTUnwrap(m.outgoingRemaining), 6, accuracy: 0.01)
        XCTAssertEqual(try XCTUnwrap(m.incomingEntry), 6, accuracy: 0.01)
        let spoken = m.spokenSummary(outgoingTitle: "Track 1", incomingTitle: "Track 2")
        XCTAssertTrue(spoken.contains("Blending Track 1 into Track 2"))
        XCTAssertTrue(spoken.contains("Crossfade") && spoken.contains("Overlap now") && spoken.contains("6 seconds remaining"))
    }

    func testPausedPositionFreezesDisclosedTiming() throws {
        schedule(executed: .beatMatched)
        player.mixDecksExecution(.overlapBegan(key: key, generation: player.mixDecksQueueGeneration, atFrame: 4_800_000))
        let a = OverlapCardModel(player.transitionPresentation, snapshot: player.displayedTransitionSnapshot, position: player.currentTime)
        let b = OverlapCardModel(player.transitionPresentation, snapshot: player.displayedTransitionSnapshot, position: player.currentTime)
        XCTAssertEqual(a, b)
    }

    func testPlannedOverlapIsNotShownBeforeRendererBegins() {
        schedule(executed: .beatMatched)
        let p = player.transitionPresentation
        XCTAssertFalse(p.isBlendingNow, "position in the window but renderer has not begun the overlap")
        XCTAssertNil(OverlapCardModel(p, snapshot: player.displayedTransitionSnapshot, position: 106))
    }

    func testPreparingIsTruthful() {
        player.currentTime = 10
        player.transitionPrepState = .analyzing(0.4)
        let p = player.transitionPresentation
        XCTAssertEqual(p.phase, .preparing)
        XCTAssertFalse(p.isBlendingNow)
    }

    func testDeniedShowsReason() {
        player.mixDecksExecution(.reset(.interrupted))
        player.transitionExecution.record(key, generation: player.mixDecksQueueGeneration,
                                          .denied(.admissionDenied("tempo"), readiness: .ready))
        let p = player.transitionPresentation
        XCTAssertEqual(p.phase, .fallback)
        XCTAssertFalse(p.isBlendingNow)
        XCTAssertEqual(p.fallbackDetail, "Blend denied: not safe to overlap these tracks")
    }

    func testSequentialFallbackNeverShowsOverlap() {
        schedule(executed: .gapless, reason: .lateForPlannedBlend)
        let p = player.transitionPresentation
        XCTAssertFalse(p.isBlendingNow)
        XCTAssertEqual(p.actualStyle, .gapless)
        XCTAssertEqual(p.plannedStyle, .beatMatched)
        XCTAssertTrue(p.fallbackDetail?.hasPrefix("Sequential handoff") == true)
        XCTAssertNil(OverlapCardModel(p, snapshot: player.displayedTransitionSnapshot, position: 106))
    }

    func testNoTransitionAtEndOfQueue() {
        player.queue = [row(1)]
        player.transitionPlan = nil
        XCTAssertEqual(player.transitionPresentation, .none)
    }

    func testQueueReplacementDropsOverlapDisplay() {
        schedule(executed: .beatMatched)
        player.mixDecksExecution(.overlapBegan(key: key, generation: player.mixDecksQueueGeneration, atFrame: 4_800_000))
        XCTAssertTrue(player.transitionPresentation.isBlendingNow)
        player.queue = [row(7), row(8)]
        XCTAssertFalse(player.transitionPresentation.isBlendingNow, "no false overlap after replacement")
    }

    func testOutgoingTailIsNotFullOutgoingProgress() throws {
        schedule(executed: .beatMatched)
        let gen = player.mixDecksQueueGeneration
        player.mixDecksExecution(.overlapBegan(key: key, generation: gen, atFrame: 4_800_000))
        player.mixDecksExecution(.handedOff(key: key, generation: gen, atFrame: 5_376_000))
        player.isOutgoingTransitionTailAudible = true
        let m = try XCTUnwrap(OverlapCardModel(player.transitionPresentation,
                                               snapshot: player.displayedTransitionSnapshot, position: 0))
        XCTAssertEqual(m.rail, .incoming)
        XCTAssertEqual(m.outgoingCaption, "fading out")
    }
}
#endif
