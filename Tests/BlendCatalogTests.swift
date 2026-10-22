import XCTest
import GRDB
@testable import TonearmCore

final class BlendCatalogTests: XCTestCase {
    private func facts(_ id: String, bpm: Double = 100) -> StarterTrackFacts {
        StarterTrackFacts(id: id, durationSeconds: 240, bpm: bpm, beatPeriod: 60 / bpm, beatPhase: 0.2, rmsDB: -12)
    }

    func testFreshInstallSeedsTheCatalogAtItsFinalStates() async throws {
        let store = try LibraryStore(inMemory: true)
        let tracks = try await store.blendCatalogTracks(atLeast: .unindexed, packTag: StarterBlendPack.v1.releaseTag)
        XCTAssertEqual(tracks.count, 36)
        XCTAssertTrue(tracks.allSatisfy { $0.state == .edgePlanned })
        for row in tracks {
            let f = try XCTUnwrap(row.facts, row.catalogKey)
            XCTAssertEqual(f, StarterBlendPack.trackFacts[row.trackID])
            XCTAssertTrue(f.isBlendReady)
        }
        for blend in StarterBlendCatalog.blends {
            for plan in blend.edgePlans {
                let stored = try await store.blendCatalogEdgePlan(
                    from: BlendCatalogTrack.key(pack: .v1, trackID: plan.outgoingTrackID),
                    to: BlendCatalogTrack.key(pack: .v1, trackID: plan.incomingTrackID))
                XCTAssertEqual(stored, plan, "\(blend.id) edge \(plan.edge) survives persistence exactly")
            }
        }
    }

    func testLifecycleMovesForwardOneStepAtATime() async throws {
        let store = try LibraryStore(inMemory: true)
        let a = "pack:a", b = "pack:b"
        try await store.registerBlendCatalogTrack(key: a, packTag: "pack")
        try await store.registerBlendCatalogTrack(key: b, packTag: "pack")
        var row = try await store.blendCatalogTrack(key: a)
        XCTAssertEqual(row?.state, .unindexed)
        // Not eligible yet: nothing selects it and no plan may be attached.
        let eligibleBefore = try await store.blendCatalogTracks(atLeast: .blendEligible, packTag: "pack")
        XCTAssertTrue(eligibleBefore.isEmpty)
        let plan = try XCTUnwrap(CatalogEdgePlanner.plan(blendID: "x", edge: 1, outgoing: facts("a"), incoming: facts("b")))
        do { try await store.recordBlendEdgePlan(plan, from: a, to: b, packTag: "pack"); XCTFail("unindexed cannot be planned") }
        catch { XCTAssertEqual(error as? BlendCatalogError, .illegalTransition(from: .unindexed, to: .edgePlanned)) }
        // Facts must be complete and valid.
        var bad = facts("a"); bad = StarterTrackFacts(id: "a", durationSeconds: 0, bpm: 100, beatPeriod: 0.6, beatPhase: 0, rmsDB: -10)
        do { try await store.markBlendEligible(key: a, facts: bad); XCTFail() }
        catch { XCTAssertEqual(error as? BlendCatalogError, .missingFacts(a)) }

        try await store.markBlendEligible(key: a, facts: facts("a"))
        try await store.markBlendEligible(key: b, facts: facts("b"))
        row = try await store.blendCatalogTrack(key: a)
        XCTAssertEqual(row?.state, .blendEligible)
        XCTAssertEqual(row?.facts, facts("a"))
        do { try await store.markBlendEligible(key: a, facts: facts("a")); XCTFail("no repeat/skip") }
        catch { XCTAssertEqual(error as? BlendCatalogError, .illegalTransition(from: .blendEligible, to: .blendEligible)) }
        let eligible = try await store.blendCatalogTracks(atLeast: .blendEligible, packTag: "pack")
        XCTAssertEqual(eligible.count, 2)

        try await store.recordBlendEdgePlan(plan, from: a, to: b, packTag: "pack")
        for key in [a, b] {
            let state = try await store.blendCatalogTrack(key: key)?.state
            XCTAssertEqual(state, .edgePlanned)
        }
        let stored = try await store.blendCatalogEdgePlan(from: a, to: b)
        XCTAssertEqual(stored, plan)
        do { try await store.markBlendEligible(key: "pack:missing", facts: facts("m")); XCTFail() }
        catch { XCTAssertEqual(error as? BlendCatalogError, .unknownTrack("pack:missing")) }
    }

    func testStateOrderingAndSteps() {
        XCTAssertTrue(BlendCatalogState.unindexed < .blendEligible)
        XCTAssertTrue(BlendCatalogState.blendEligible < .edgePlanned)
        XCTAssertTrue(BlendCatalogState.unindexed.canAdvance(to: .blendEligible))
        XCTAssertFalse(BlendCatalogState.unindexed.canAdvance(to: .edgePlanned))
        XCTAssertFalse(BlendCatalogState.edgePlanned.canAdvance(to: .blendEligible))
    }

    func testCatalogPlannerUsesOnlyStoredFactsAndRejectsMismatchedPairs() throws {
        let out = facts("a", bpm: 100), near = facts("b", bpm: 104), far = facts("c", bpm: 130)
        let plan = try XCTUnwrap(CatalogEdgePlanner.plan(blendID: "x", edge: 3, outgoing: out, incoming: near))
        XCTAssertEqual(plan.style, .bassSwap)
        XCTAssertEqual(plan.tempo, 100.0 / 104.0, accuracy: 1e-12)
        XCTAssertEqual(plan.overlapBeats, 32)
        let s = try XCTUnwrap(plan.schedule(outgoing: out, incoming: near))
        // The incoming's first beat lands on the overlap start, on the outgoing's beat grid.
        XCTAssertEqual(s.incomingStart, near.beatPhase, accuracy: 1e-9)
        let beats = (s.outgoingStart - out.beatPhase) / out.beatPeriod
        XCTAssertEqual(beats, beats.rounded(), accuracy: 1e-6, "starts on the outgoing's beat grid")
        XCTAssertLessThanOrEqual(s.outgoingStart + s.overlapSeconds, out.durationSeconds - CatalogEdgePlanner.tailSeconds + 0.01)
        XCTAssertGreaterThanOrEqual(plan.incomingGain ?? 0, 0.5)
        XCTAssertLessThanOrEqual(plan.incomingGain ?? 0, 1.6)
        XCTAssertNil(CatalogEdgePlanner.plan(blendID: "x", edge: 1, outgoing: out, incoming: far), "beyond ±8% tempo")
        let short = StarterTrackFacts(id: "s", durationSeconds: 30, bpm: 100, beatPeriod: 0.6, beatPhase: 0, rmsDB: -10)
        XCTAssertNil(CatalogEdgePlanner.plan(blendID: "x", edge: 1, outgoing: short, incoming: near), "no room for the overlap")
        XCTAssertNil(CatalogEdgePlanner.plan(blendID: "x", edge: 1, outgoing: out,
                                             incoming: StarterTrackFacts(id: "u", durationSeconds: 240, bpm: 0, beatPeriod: 0, beatPhase: 0, rmsDB: .nan)))
    }

    func testMigrationListIncludesTheCatalog() {
        XCTAssertEqual(Schema.migrationOrder.last, "v35")
    }
}
