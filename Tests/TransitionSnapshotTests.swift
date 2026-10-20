import XCTest
@testable import TonearmCore

final class TransitionSnapshotTests: XCTestCase {
    private let a = QueueOccurrenceID(), b = QueueOccurrenceID(), c = QueueOccurrenceID()
    private func key(_ f: QueueOccurrenceID, _ t: QueueOccurrenceID) -> TransitionEdgeKey { .init(from: f, to: t) }
    private func plan(_ style: TransitionStyle = .phraseFade, from: Int64 = 1, to: Int64 = 2,
                      overlap: Double = 12) -> TransitionPlan {
        TransitionPlan(fromTrackID: from, toTrackID: to, style: style, exitTime: 100, entryTime: 4,
                       overlapSeconds: overlap, blendRate: 1.02, confidence: 0.8)
    }
    private func planned(_ k: TransitionEdgeKey) -> TransitionSnapshot {
        .make(key: k, plan: plan(), frames: .init(start: 1000, handoff: 1500, end: 2000, sampleRate: 48000))
    }

    func testActiveOnly() {
        var book = TransitionSnapshotBook()
        book.publish(planned(key(a, b)))
        XCTAssertNotNil(book.snapshot(for: key(a, b)))
        XCTAssertNil(book.upcoming)
        XCTAssertNil(book.snapshot(for: key(b, c)))
    }

    func testActivePlusUpcomingAndTailRetention() {
        var book = TransitionSnapshotBook()
        let ab = planned(key(a, b))
        book.publish(ab)
        book.publish(planned(key(b, c)))
        book.handoffBegan()
        book.publish(.checking(key(b, c)))
        XCTAssertEqual(book.active, ab, "B→C must not replace the audible A→B")
        XCTAssertEqual(book.snapshot(for: key(b, c))?.state, .checking)
        book.outgoingInaudible()
        XCTAssertEqual(book.active?.key, key(b, c))
        XCTAssertNil(book.snapshot(for: key(a, b)))
    }

    func testRepeatedTrackIDsAreDistinctEdges() {
        let a2 = QueueOccurrenceID()
        var book = TransitionSnapshotBook()
        book.publish(.make(key: key(a, b), plan: plan(from: 1, to: 1), frames: .init(start: 0, handoff: 1, end: 2, sampleRate: 48000)))
        book.publish(.unplanned(key(b, a2), .notPlannedYet))
        XCTAssertEqual(book.snapshot(for: key(a, b))?.state, .planned)
        XCTAssertEqual(book.snapshot(for: key(b, a2))?.state, .unplanned(.notPlannedYet))
        XCTAssertNil(book.snapshot(for: key(a, a2)))
    }

    func testReorderAndDeleteInvalidate() {
        var book = TransitionSnapshotBook()
        book.publish(planned(key(a, b)))
        book.publish(planned(key(b, c)))
        book.invalidate(queue: [a, c, b], loops: false)
        XCTAssertNil(book.active)
        XCTAssertNil(book.upcoming)
        book.publish(planned(key(a, b)))
        book.invalidate(queue: [a, c], loops: false)
        XCTAssertNil(book.active, "deleting B makes A→B stale")
    }

    func testReplacementQueueInvalidatesAll() {
        var book = TransitionSnapshotBook()
        book.publish(planned(key(a, b)))
        book.publish(planned(key(b, c)))
        book.invalidate(queue: [QueueOccurrenceID(), QueueOccurrenceID()], loops: true)
        XCTAssertNil(book.active)
        XCTAssertNil(book.upcoming)
    }

    func testStaleInvalidationDoesNotDropAudibleTail() {
        var book = TransitionSnapshotBook()
        book.publish(planned(key(a, b)))
        book.handoffBegan()
        book.invalidate(queue: [b, c], loops: false)
        XCTAssertNotNil(book.active)
        book.outgoingInaudible()
        XCTAssertNil(book.active)
    }

    func testLoopWrapEdge() {
        var book = TransitionSnapshotBook()
        book.publish(planned(key(c, a)))
        book.invalidate(queue: [a, b, c], loops: true)
        XCTAssertNotNil(book.active)
        book.invalidate(queue: [a, b, c], loops: false)
        XCTAssertNil(book.active)
    }

    func testEndQueueRepeatOneSettingsOffAreUnplannedWithoutTiming() {
        for reason in [TransitionUnplannedReason.endOfQueue, .repeatOne, .settingsOff] {
            let s = TransitionSnapshot.unplanned(key(a, b), reason)
            XCTAssertEqual(s.state, .unplanned(reason))
            XCTAssertNil(s.style)
            XCTAssertNil(s.frames)
            XCTAssertNil(s.sourceExitSeconds)
        }
    }

    func testPhraseCutNoOverlap() {
        let f = TransitionClockFrames(start: 5000, handoff: 5000, end: 5000, sampleRate: 48000)
        XCTAssertEqual(f.overlapFrames, 0)
        let s = TransitionSnapshot.make(key: key(a, b), plan: plan(overlap: 0), frames: f, displayStyle: .phraseBlend)
        XCTAssertEqual(s.state, .planned)
        XCTAssertEqual(s.frames?.overlapFrames, 0)
    }

    func testMissingTimingIsNotInvented() {
        let s = TransitionSnapshot.make(key: key(a, b), plan: plan(overlap: 0))
        XCTAssertEqual(s.state, .unplanned(.missingTiming))
        XCTAssertNil(s.frames)
        XCTAssertNil(s.style)
    }

    func testActualEngineStyleAndCachedFlag() {
        let s = TransitionSnapshot.make(key: key(a, b), plan: plan(), frames: .init(start: 1, handoff: 2, end: 3, sampleRate: 44100),
                                        displayStyle: .bassSwap, isCached: true)
        XCTAssertEqual(s.style, .bassSwap)
        XCTAssertTrue(s.isCached)
        XCTAssertEqual(s.tempo?.blendRate, 1.02)
        XCTAssertEqual(s.confidence, 0.8)
    }

    func testFallbackSnapshot() {
        var p = plan(.gapless, overlap: 0)
        p.downgradedFrom = .phraseFade
        let s = TransitionSnapshot.make(key: key(a, b), plan: p)
        if case .unplanned(.fallback) = s.state {} else { XCTFail("expected fallback") }
    }

    func testUnknownAndChecking() {
        XCTAssertEqual(TransitionSnapshot.unknown(key(a, b)).state, .unknown)
        XCTAssertEqual(TransitionSnapshot.checking(key(a, b)).state, .checking)
    }

    func testNewActiveAfterJumpClearsUpcoming() {
        var book = TransitionSnapshotBook()
        book.publish(planned(key(a, b)))
        book.publish(planned(key(b, c)))
        book.publish(planned(key(c, a)))
        XCTAssertEqual(book.active?.key, key(c, a))
        XCTAssertNil(book.upcoming)
    }
}
