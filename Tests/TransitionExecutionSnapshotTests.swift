#if !os(watchOS)
import XCTest
import AVFoundation
@testable import TonearmCore

final class TransitionExecutionLedgerTests: XCTestCase {
    private let a = QueueOccurrenceID(), b = QueueOccurrenceID(), c = QueueOccurrenceID()
    private func key(_ f: QueueOccurrenceID, _ t: QueueOccurrenceID) -> TransitionEdgeKey { .init(from: f, to: t) }
    private func schedule(_ l: inout TransitionExecutionLedger, _ k: TransitionEdgeKey, gen: Int,
                          executed: TransitionDisplayStyle = .phraseBlend) {
        l.record(k, generation: gen, .scheduled(requested: .phraseBlend, planned: .phraseBlend, executed: executed,
                                                readiness: .ready, reason: executed == .gapless ? .lateForPlannedBlend : nil,
                                                overlapStart: executed.overlaps ? 1_000 : nil,
                                                overlapEnd: executed.overlaps ? 5_000 : nil, handoff: 5_000, sampleRate: 48_000))
    }

    func testSimultaneousPrepAndLifecycle() {
        var l = TransitionExecutionLedger()
        l.advanceGeneration(order: [a, b, c], loops: false)
        schedule(&l, key(a, b), gen: 1)
        schedule(&l, key(b, c), gen: 1)
        XCTAssertEqual(l.upcoming.count, 2)
        l.record(key(a, b), generation: 1, .overlapBegan(atFrame: 1_000))
        l.record(key(a, b), generation: 1, .handedOff(atFrame: 5_000))
        XCTAssertEqual(l.active?.key, key(a, b))
        XCTAssertEqual(l.snapshot(for: key(b, c))?.phase, .upcoming)
        l.outgoingFinished(key(a, b), generation: 1, atFrame: 6_000)
        XCTAssertEqual(l.snapshot(for: key(a, b))?.phase, .completed)
        XCTAssertNil(l.active)
    }

    func testSequentialFallbackIsNeverLabelledOverlap() {
        var l = TransitionExecutionLedger()
        schedule(&l, key(a, b), gen: 0, executed: .gapless)
        XCTAssertFalse(l.record(key(a, b), generation: 0, .overlapBegan(atFrame: 10)))
        let s = l.snapshot(for: key(a, b))!
        XCTAssertEqual(s.plannedStyle, .phraseBlend)
        XCTAssertEqual(s.executedStyle, .gapless)
        XCTAssertFalse(s.executedAsOverlap)
        XCTAssertEqual(s.overlapFrames, 0)
        XCTAssertEqual(s.reason, .lateForPlannedBlend)
    }

    func testDuplicateTracksAreDistinctEdgesAndStaleGenerationIsRejected() {
        let a2 = QueueOccurrenceID()
        var l = TransitionExecutionLedger()
        schedule(&l, key(a, a2), gen: 0)
        schedule(&l, key(a2, a), gen: 0)
        XCTAssertNotNil(l.snapshot(for: key(a, a2)))
        XCTAssertNil(l.snapshot(for: key(a, a)))
        l.advanceGeneration(order: [a2, a], loops: false)       // reorder
        XCTAssertEqual(l.snapshot(for: key(a, a2))?.phase, .cancelled)
        let before = l
        XCTAssertFalse(l.record(key(a2, a), generation: 0, .handedOff(atFrame: 1)), "obsolete generation")
        XCTAssertEqual(l, before)
    }

    func testLoopWrapAndDeleteAndLateCompletion() {
        var l = TransitionExecutionLedger()
        schedule(&l, key(c, a), gen: 0)
        l.advanceGeneration(order: [a, b, c], loops: true)
        XCTAssertEqual(l.snapshot(for: key(c, a))?.phase, .upcoming, "wrap edge survives with loop")
        l.advanceGeneration(order: [a, c], loops: false)
        XCTAssertEqual(l.snapshot(for: key(c, a))?.phase, .cancelled)
        XCTAssertFalse(l.record(key(c, a), generation: l.generation, .completed(atFrame: 9)), "late completion cannot resurrect")
        XCTAssertEqual(l.snapshot(for: key(c, a))?.phase, .cancelled)
    }

    func testReplacementAndRestartCancelAndCleanupIsBounded() {
        var l = TransitionExecutionLedger()
        schedule(&l, key(a, b), gen: 0)
        let held = l.snapshot(for: key(a, b))!
        l.cancelAll(reason: .restarted)
        XCTAssertTrue(l.live.isEmpty)
        XCTAssertEqual(held.phase, .upcoming, "earlier copies are immutable")
        for _ in 0..<(TransitionExecutionLedger.recentLimit + 5) {
            let x = QueueOccurrenceID(), y = QueueOccurrenceID()
            schedule(&l, key(x, y), gen: 0)
            l.cancelAll(reason: .stopped)
        }
        XCTAssertEqual(l.recent.count, TransitionExecutionLedger.recentLimit)
        XCTAssertLessThan(held.updateSequence, l.sequence)
    }
}

/// The real MixDeckPlayer → renderer path drives a host that feeds the ledger.
@MainActor
final class TransitionExecutionRendererTests: XCTestCase {
    final class Host: MixDeckHost {
        var urls: [URL] = []
        var occurrences: [QueueOccurrenceID] = []
        var ledger = TransitionExecutionLedger()
        var edge: MixDeckEdge = .blend
        var producerCalls = 0
        var ended = false
        var mixDecksCurrentIndex = 0
        var mixDecksQueueGeneration: Int { ledger.generation }
        func mixDecksOccurrence(at index: Int) -> QueueOccurrenceID? { occurrences.indices.contains(index) ? occurrences[index] : nil }
        func mixDecksUpcomingIndex(after index: Int) -> Int? { index + 1 < urls.count ? index + 1 : nil }
        func mixDecksTrack(at index: Int) -> (trackID: Int64, source: MixTrackSource, bpm: Double?)? {
            guard urls.indices.contains(index) else { return nil }
            return (Int64(index + 1), .file(urls[index], container: .auto, securityScoped: false), 124)
        }
        func mixDecksDidAdvance(to index: Int, trackID: Int64, duration: Double) -> Int { mixDecksCurrentIndex = index; return index }
        func mixDecksDidReachEnd(trackID: Int64) { ended = true }
        func mixDecksCouldNotPlay(index: Int, reason: String) {}
        func mixDecksPosition(seconds: Double) {}
        func mixDecksLoading(_ loading: Bool) {}
        func mixDecksEdge(from: Int, to: Int) -> MixDeckEdge { edge }
        func mixDecksPublish(plan: TransitionPlan?, state: GridPrepState) {}
        func mixDecksExecution(_ event: MixDeckExecutionEvent) {
            producerCalls += 1
            switch event {
            case let .scheduled(key, g, req, plan, exec, reason, s, e, h, sr):
                ledger.record(key, generation: g, .scheduled(requested: req, planned: plan, executed: exec, readiness: .ready,
                                                             reason: reason, overlapStart: s, overlapEnd: e, handoff: h, sampleRate: sr))
            case let .overlapBegan(key, g, f): ledger.record(key, generation: g, .overlapBegan(atFrame: f))
            case let .handedOff(key, g, f): ledger.record(key, generation: g, .handedOff(atFrame: f))
            case let .outgoingFinished(key, g, f): ledger.outgoingFinished(key, generation: g, atFrame: f)
            case .reset(let r): ledger.cancelAll(reason: r)
            }
        }
    }

    private func click(seconds: Double) throws -> URL {
        let sr = MixDeckPlayer.sampleRate
        let frames = Int(seconds * sr)
        let format = AVAudioFormat(standardFormatWithSampleRate: sr, channels: 2)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames))!
        buffer.frameLength = AVAudioFrameCount(frames)
        let spacing = 60 / 124 * sr
        for c in 0..<2 {
            let ch = buffer.floatChannelData![c]
            for i in 0..<frames {
                let p = Double(i).truncatingRemainder(dividingBy: spacing)
                ch[i] = 0.5 * (p < 2_000 ? Float(sin(2 * .pi * 55 * p / sr) * exp(-p / 600)) : 0) + 0.05 * Float(sin(2 * .pi * 440 * Double(i) / sr))
            }
        }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("exec-\(UUID().uuidString).wav")
        try AVAudioFile(forWriting: url, settings: format.settings).write(from: buffer)
        return url
    }

    private func run(edge: MixDeckEdge) async throws -> Host {
        let a = try click(seconds: 12), b = try click(seconds: 10)
        defer { [a, b].forEach { try? FileManager.default.removeItem(at: $0) } }
        let host = Host()
        host.edge = edge
        host.urls = [a, b]
        host.occurrences = [QueueOccurrenceID(), QueueOccurrenceID()]
        let player = try MixDeckPlayer(host: host, offline: true)
        player.start(index: 0, at: 0, autoplay: true)
        let sr = MixDeckPlayer.sampleRate
        while !host.ended, Double(player.masterFrame) < 120 * sr {
            while player.isPreparing { try await Task.sleep(nanoseconds: 20_000_000) }
            _ = player.renderOffline(frames: 4_096)
        }
        return host
    }

    func testBlendIsExecutedAsOverlapOnTheCommonClock() async throws {
        let host = try await run(edge: .blend)
        XCTAssertGreaterThan(host.producerCalls, 0, "the scheduler must call the snapshot producer")
        let s = try XCTUnwrap(host.ledger.snapshot(for: TransitionEdgeKey(from: host.occurrences[0], to: host.occurrences[1])))
        XCTAssertEqual(s.phase, .completed)
        if s.executedAsOverlap {
            XCTAssertGreaterThan(s.overlapFrames, 0)
            let start = try XCTUnwrap(s.overlapStartFrame), handoff = try XCTUnwrap(s.handoffFrame)
            XCTAssertLessThanOrEqual(start, handoff)
            XCTAssertLessThanOrEqual(handoff, try XCTUnwrap(s.completedFrame))
        } else {
            XCTAssertEqual(s.executedStyle, .gapless)
            XCTAssertNotNil(s.reason, "a fallback states why")
        }
    }

    func testGaplessEdgeIsLabelledSequentialNotOverlap() async throws {
        let host = try await run(edge: .gapless)
        let s = try XCTUnwrap(host.ledger.snapshot(for: TransitionEdgeKey(from: host.occurrences[0], to: host.occurrences[1])))
        XCTAssertEqual(s.executedStyle, .gapless)
        XCTAssertEqual(s.overlapFrames, 0)
        XCTAssertEqual(s.reason, .gaplessEdge)
        XCTAssertEqual(s.phase, .completed)
    }

    func testRestartCancelsPendingEdge() async throws {
        let a = try click(seconds: 30), b = try click(seconds: 20)
        defer { [a, b].forEach { try? FileManager.default.removeItem(at: $0) } }
        let host = Host()
        host.urls = [a, b]
        host.occurrences = [QueueOccurrenceID(), QueueOccurrenceID()]
        let player = try MixDeckPlayer(host: host, offline: true)
        player.start(index: 0, at: 0, autoplay: true)
        while player.isPreparing || player.scheduled == nil {
            try await Task.sleep(nanoseconds: 20_000_000)
            _ = player.renderOffline(frames: 4_096)
        }
        let key = TransitionEdgeKey(from: host.occurrences[0], to: host.occurrences[1])
        XCTAssertEqual(host.ledger.snapshot(for: key)?.phase, .upcoming)
        host.mixDecksCurrentIndex = 1
        player.start(index: 1, at: 0, autoplay: true)   // skip forward
        XCTAssertEqual(host.ledger.snapshot(for: key)?.phase, .cancelled)
        XCTAssertNil(player.scheduled)
    }
}
#endif
