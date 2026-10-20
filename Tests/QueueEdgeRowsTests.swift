import XCTest
@testable import TonearmCore

final class QueueEdgeRowsTests: XCTestCase {
    private func live(_ from: Int64?, _ to: Int64?, phase: TransitionRuntimePhase = .ready,
                      style: TransitionDisplayStyle? = .phraseBlend,
                      range: ClosedRange<Double>? = 125...137) -> TransitionPresentation {
        TransitionPresentation(phase: phase, plannedStyle: style, actualStyle: style,
                               outgoingTrackID: from, incomingTrackID: to, overlapRange: range, preparation: .ready)
    }

    private func rows(_ ids: [Int64], at index: Int = 0, repeat mode: RepeatMode = .off, on: Bool = true,
                      live: TransitionPresentation) -> [QueueEdgeRow] {
        QueueEdgeResolver.rows(trackIDs: ids, currentIndex: index, repeatMode: mode,
                               smartBlendEnabled: on, live: live)
    }

    func testRepeatedIDsGetDistinctKeysAndOnlyActiveEdgeIsLive() {
        let r = rows([1, 2, 1, 2], live: live(1, 2))
        XCTAssertEqual(r.count, 3)
        XCTAssertEqual(Set(r.map(\.key)).count, 3)
        XCTAssertEqual(r[0].timeline.kind, .phrase)
        XCTAssertEqual(r[2].presentation.phase, .notPlanned) // same IDs 1→2, different occurrence
        XCTAssertEqual(r[2].summary, "Not planned yet")
    }

    func testStaleLiveStateIsRejectedAfterReorderOrDelete() {
        // Live says 1→2 but the queue now has 1→3 after the current track.
        let r = rows([1, 3, 2], live: live(1, 2))
        XCTAssertEqual(r[0].presentation.phase, .notPlanned)
        XCTAssertNil(r[0].timeline.outgoingBoundary)
    }

    func testOutgoingTailKeepsActiveEdgeAndUpcomingIsUnplanned() {
        let r = rows([1, 2, 3], at: 1, live: live(1, 2, phase: .outgoingTail))
        XCTAssertEqual(r[0].key, QueueEdgeKey(position: 0, fromTrackID: 1, toTrackID: 2))
        XCTAssertEqual(r[0].presentation.phase, .outgoingTail)
        XCTAssertEqual(r[1].key, QueueEdgeKey(position: 1, fromTrackID: 2, toTrackID: 3))
        XCTAssertEqual(r[1].presentation.phase, .notPlanned)
    }

    func testLoopEndAndRepeatOne() {
        XCTAssertEqual(rows([1, 2], live: live(1, 2)).count, 1) // end: no outgoing edge on last
        let loop = rows([1, 2], at: 1, repeat: .all, live: live(2, 1))
        XCTAssertEqual(loop.count, 2)
        XCTAssertEqual(loop[1].key.toTrackID, 1)
        XCTAssertEqual(loop[1].timeline.kind, .phrase)
        let loopIdle = rows([1, 2], at: 0, repeat: .all, live: live(1, 2))
        XCTAssertEqual(loopIdle[1].summary, "Loops back to the first track")
        let one = rows([1, 2], repeat: .one, live: live(1, 2))
        XCTAssertEqual(one[0].summary, "Repeating this track")
    }

    func testSettingsOffNeverShowsBlend() {
        let r = rows([1, 2, 3], on: false, live: live(1, 2))
        XCTAssertTrue(r.allSatisfy { $0.summary == "Smart transitions are off" })
    }

    func testMissingTimingAndFallbackNeverFabricateTiming() {
        let none = rows([1, 2], live: live(1, 2, range: nil))
        XCTAssertNil(none[0].timeline.outgoingBoundary)
        XCTAssertTrue(none[0].accessibilityLabel.contains("timing unavailable"))
        let fb = rows([1, 2], live: TransitionPresentation(phase: .fallback))
        XCTAssertEqual(fb[0].timeline.kind, .fallback)
        XCTAssertNil(fb[0].timeline.incomingBoundary)
    }

    func testPhraseCutShowsBoundaries() {
        let r = rows([1, 2], live: live(1, 2))
        XCTAssertEqual(r[0].summary, "Phrase · Out 2:05 → In 2:17 · Ready")
    }
}
