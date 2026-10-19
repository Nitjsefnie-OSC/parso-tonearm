#if !os(watchOS)
import XCTest
import Synchronization
@testable import TonearmCore

/// Offline renders of the bounded-buffer deck path (no engine, no I/O).
final class BoundedDeckMixerTests: XCTestCase {
    /// Deterministic procedural media of any length: nothing is ever stored.
    final class Source: DeckChunkSource {
        let seed: Float
        let stalled = Atomic<Bool>(false)
        let maxFrameRequested = Atomic<Int>(0)
        let framesRequested = Atomic<Int>(0)
        init(seed: Float) { self.seed = seed }
        static func value(_ frame: Int64, seed: Float) -> Float { 0.4 * sin(Float(frame % 100_000) * 0.01 + seed) }
        func read(startFrame: Int64, count: Int) throws -> [[Float]] {
            if stalled.load(ordering: .relaxed) { return [[], []] }
            framesRequested.add(count, ordering: .relaxed)
            maxFrameRequested.store(max(maxFrameRequested.load(ordering: .relaxed), Int(startFrame) + count), ordering: .relaxed)
            let s = (0..<count).map { Self.value(startFrame + Int64($0), seed: seed) }
            return [s, s]
        }
    }

    private let hours3: Int64 = 3 * 3600 * 44_100
    private func mixer(capacity: Int = 44_100, preroll: Int = 0) -> BoundedDeckMixer {
        BoundedDeckMixer(capacityFrames: capacity, maxBlockFrames: 512, prerollFrames: preroll)
    }
    private func plan(start: Int64, fade: Int = 4_410, min: Int = 4_410, tempo: Double = 1) -> BoundedOverlapPlan {
        BoundedOverlapPlan(startClock: start, fadeFrames: fade, incomingStartFrame: 0, incomingTotalFrames: hours3,
                           incomingTempo: tempo, minIncomingBufferedFrames: min)
    }

    func testMultiHourFileStartsWithoutFullDecode() throws {
        let m = mixer()
        let src = Source(seed: 0)
        m.begin(totalFrames: hours3, startFrame: 0)
        try m.decks[0].refill(from: src)
        XCTAssertLessThanOrEqual(src.framesRequested.load(ordering: .relaxed), 44_100)
        XCTAssertEqual(m.snapshot().current.bufferedSeconds, 1, accuracy: 0.001)
        let out = m.renderOffline(frames: 1_000)
        XCTAssertEqual(out[0][500], Source.value(500, seed: 0), accuracy: 1e-6)
    }

    func testTwoLongSourcesOverlapUnderFixedMemory() throws {
        let m = mixer(capacity: 22_050)
        let a = Source(seed: 0), b = Source(seed: 1)
        m.begin(totalFrames: hours3, startFrame: hours3 - 200_000)
        m.schedule(plan(start: 100_000))
        var rendered = 0
        while rendered < 120_000 {
            try m.decks[0].refill(from: a); try m.decks[1].refill(from: b)
            _ = m.renderOffline(frames: 4_096); rendered += 4_096
        }
        let snap = m.snapshot()
        XCTAssertEqual(snap.residentBytes, 2 * 22_050 * 2 * 4)
        XCTAssertLessThanOrEqual(snap.residentBytes, 1_000_000)
        XCTAssertEqual(snap.current.underruns + snap.incoming.underruns, 0)
        XCTAssertLessThan(b.framesRequested.load(ordering: .relaxed), 100_000)
    }

    func testNonUnitTempoPreservesSourcePosition() throws {
        let m = mixer()
        m.begin(totalFrames: hours3, startFrame: 10_000, tempo: 1.25)
        let src = Source(seed: 0)
        var rendered = 0
        while rendered < 20_000 { try m.decks[0].refill(from: src); _ = m.renderOffline(frames: 2_000); rendered += 2_000 }
        XCTAssertEqual(m.decks[0].positionFrame, 10_000 + 25_000)
    }

    func testPrerollDelaysConsumptionUntilLookaheadBuffered() throws {
        let m = mixer(preroll: 1_000)
        m.begin(totalFrames: hours3, startFrame: 0)
        _ = m.decks[0].write(DeckChunk(generation: m.decks[0].generation, startFrame: 0,
                                       channels: [[Float](repeating: 0.1, count: 600), [Float](repeating: 0.1, count: 600)]))
        _ = m.renderOffline(frames: 100)
        XCTAssertEqual(m.decks[0].positionFrame, 0)
        XCTAssertEqual(m.decks[0].underrunCount, 1)   // explicit, counted
    }

    func testSeekInvalidatesStaleChunksAndCancelledGenerationCannotRefill() throws {
        let m = mixer()
        m.begin(totalFrames: hours3, startFrame: 0)
        let stale = m.decks[0].nextRequest()
        m.seek(to: 50_000)
        let chunk = DeckChunk(generation: stale.generation, startFrame: stale.startFrame,
                              channels: [[Float](repeating: 1, count: 100), [Float](repeating: 1, count: 100)])
        XCTAssertEqual(m.decks[0].write(chunk), .stale)
        XCTAssertEqual(m.decks[0].bufferedFrames, 0)
        try m.decks[0].refill(from: Source(seed: 0))
        let out = m.renderOffline(frames: 10)
        XCTAssertEqual(out[0][0], Source.value(50_000, seed: 0), accuracy: 1e-6)
        // A deck reused for another track refuses the old track's decode too.
        let old = m.decks[1].nextRequest()
        m.decks[1].retarget(totalFrames: 1_000, startFrame: 0)
        XCTAssertEqual(m.decks[1].write(DeckChunk(generation: old.generation, startFrame: 0, channels: chunk.channels)), .stale)
    }

    func testPauseFreezesDecksAndTimeline() throws {
        let m = mixer()
        m.begin(totalFrames: hours3, startFrame: 0)
        try m.decks[0].refill(from: Source(seed: 0))
        _ = m.renderOffline(frames: 1_000)
        m.pause(.interruption)
        let out = m.renderOffline(frames: 2_000)
        XCTAssertEqual(out[0].max(), 0)
        XCTAssertEqual(m.clock, 1_000)
        XCTAssertEqual(m.decks[0].positionFrame, 1_000)
        XCTAssertEqual(m.snapshot().phase, .paused(.interruption))
        m.resume()
        _ = m.renderOffline(frames: 500)
        XCTAssertEqual(m.decks[0].positionFrame, 1_500)
    }

    func testDiskStallNeverStartsIncomingFadePrematurely() throws {
        let m = mixer()
        let a = Source(seed: 0), b = Source(seed: 1)
        b.stalled.store(true, ordering: .relaxed)
        m.begin(totalFrames: hours3, startFrame: 0)
        m.schedule(plan(start: 2_000))
        for _ in 0..<8 { try m.decks[0].refill(from: a); _ = m.renderOffline(frames: 1_024) }
        XCTAssertEqual(m.overlap, .pending(plan(start: 2_000)))
        XCTAssertEqual(m.snapshot().phase, .waitingForIncoming)
        XCTAssertGreaterThan(m.snapshot().stalledFrames, 0)
        XCTAssertEqual(m.decks[1].positionFrame, 0)
        // Outgoing was never attenuated while waiting.
        let out = m.renderOffline(frames: 256)
        let start = m.clock - 256
        _ = start
        XCTAssertEqual(out[0].map(abs).max() ?? 0, 0.4, accuracy: 0.05)
        b.stalled.store(false, ordering: .relaxed)
        try m.decks[1].refill(from: b)
        _ = m.renderOffline(frames: 64)
        guard case .active(_, let fadeStart) = m.overlap else { return XCTFail("fade should have started") }
        XCTAssertGreaterThanOrEqual(fadeStart, 8_192)
    }

    func testGainEnvelopeTimingAndHandOff() throws {
        let m = mixer(capacity: 22_050)
        let a = Source(seed: 0), b = Source(seed: 1)
        m.begin(totalFrames: hours3, startFrame: 0)
        m.schedule(plan(start: 5_000, fade: 4_000))
        var out: [Float] = []
        while out.count < 12_000 {
            try m.decks[0].refill(from: a); try m.decks[1].refill(from: b)
            out += m.renderOffline(frames: 1_000)[0]
        }
        for t in [0, 1_000, 2_000, 3_999] {
            let x = Double(t) / 4_000 * .pi / 2
            let expected = Float(cos(x)) * Source.value(Int64(5_000 + t), seed: 0) + Float(sin(x)) * Source.value(Int64(t), seed: 1)
            XCTAssertEqual(out[5_000 + t], expected, accuracy: 1e-4)
        }
        // Before the join: outgoing alone. After the fade: incoming alone, from its own source position.
        XCTAssertEqual(out[4_999], Source.value(4_999, seed: 0), accuracy: 1e-6)
        XCTAssertEqual(out[9_500], Source.value(4_500, seed: 1), accuracy: 1e-6)
        XCTAssertEqual(m.main, 1)
        XCTAssertEqual(m.snapshot().incoming.underruns + m.snapshot().current.underruns, 0)
    }

    func testContinuityAcrossChunkAndWrapBoundaries() throws {
        let m = mixer(capacity: 3_000)
        let src = Source(seed: 0)
        m.begin(totalFrames: hours3, startFrame: 0)
        var out: [Float] = []
        while out.count < 20_000 { try m.decks[0].refill(from: src, maxChunkFrames: 777); out += m.renderOffline(frames: 1_000)[0] }
        for i in stride(from: 0, to: 20_000, by: 97) { XCTAssertEqual(out[i], Source.value(Int64(i), seed: 0), accuracy: 1e-6) }
        XCTAssertEqual(m.decks[0].underrunCount, 0)
    }

    func testOutputClipsAndCounts() throws {
        let m = mixer()
        m.begin(totalFrames: 100_000, startFrame: 0)
        m.decks[0].write(DeckChunk(generation: m.decks[0].generation, startFrame: 0,
                                   channels: [[Float](repeating: 1.5, count: 512), [Float](repeating: -1.5, count: 512)]))
        let out = m.renderOffline(frames: 512)
        XCTAssertEqual(out[0].max(), 1)
        XCTAssertEqual(out[1].min(), -1)
        XCTAssertEqual(m.snapshot().clippedSamples, 1_024)
    }

    func testOversizedMediaIsStillDeniedWholeTrackMixing() {
        let hours = TransitionTrackMetadata(durationSec: 3 * 3600, sampleRate: 44_100)
        let decision = TransitionAdmissionController.decide(
            outgoing: nil, incoming: hours, system: TransitionSystemState(availableBytes: 8 << 30))
        XCTAssertFalse(decision.allowsWholeTrackMixing)
    }
}
#endif
