import XCTest
@testable import TonearmCore

final class TransitionDisclosureTests: XCTestCase {
    private func overlap(_ range: ClosedRange<Double>? = 100...112, phase: TransitionRuntimePhase = .overlap,
                         style: TransitionDisplayStyle = .beatMatched) -> TransitionPresentation {
        TransitionPresentation(phase: phase, plannedStyle: style, actualStyle: style,
                               outgoingTrackID: 1, incomingTrackID: 2, overlapRange: range)
    }

    func testMidOverlapShowsSectionMatchTypeAndProgress() throws {
        let d = try XCTUnwrap(TransitionDisclosure(overlap(), position: 106))
        XCTAssertEqual(d.section, .overlap)
        XCTAssertEqual(d.matchType, "Beat-matched")
        XCTAssertEqual(d.progressPercent, 50)
        XCTAssertEqual(d.outgoingTrackID, 1)
        XCTAssertEqual(d.incomingTrackID, 2)
        XCTAssertEqual(d.spokenSummary, "Overlap, Beat-matched, overlap 50 %")
    }

    func testOutgoingTailIsIncomingSectionAtFullProgress() throws {
        let d = try XCTUnwrap(TransitionDisclosure(overlap(phase: .outgoingTail), position: 200))
        XCTAssertEqual(d.section, .incoming)
        XCTAssertEqual(d.progressPercent, 100)
    }

    func testUnknownTimingOmitsProgress() throws {
        let d = try XCTUnwrap(TransitionDisclosure(overlap(nil, style: .smartBlend), position: 5))
        XCTAssertNil(d.overlapProgress)
        XCTAssertEqual(d.spokenSummary, "Overlap, Smart blend")
    }

    func testProgressClampsAndNoTransitionFallbackHasNoDisclosure() {
        XCTAssertEqual(TransitionDisclosure(overlap(), position: 500)?.progressPercent, 100)
        XCTAssertNil(TransitionDisclosure(.none, position: 0))
        XCTAssertNil(TransitionDisclosure(TransitionPresentation(phase: .fallback), position: 0))
        XCTAssertNil(TransitionDisclosure(overlap(phase: .ready), position: 0))
    }
}
