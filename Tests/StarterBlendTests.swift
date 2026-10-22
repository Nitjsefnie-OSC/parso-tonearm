import XCTest
@testable import TonearmCore

@MainActor
private final class StartLog {
    var requests: [StarterPlayRequest] = []
}

private let failureStrings = ["Fallback · Smart blend unavailable", "Not planned yet", "Smart blend unavailable"]

@MainActor
final class StarterBlendTests: XCTestCase {

    static let expected: [(String, [String])] = [
        ("starter.morning-light", ["337997", "1424003", "337069", "1180864", "642026", "1077690"]),
        ("starter.deep-focus", ["455018", "117009", "971563", "1097061", "26403", "1100130"]),
        ("starter.night-drive", ["1163782", "1828808", "1121468", "1739551", "1493402", "1560522"]),
        ("starter.acoustic-evening", ["1229422", "398193", "1418240", "1308980", "1849464", "1212932"]),
        ("starter.upbeat-energy", ["2053669", "2228244", "1901830", "2126638", "2133921", "1977152"]),
        ("starter.rainy-day", ["1891078", "1891935", "1974389", "2220789", "2169489", "1960412"])
    ]

    func testCatalogHasTheSixRevisedPacksInOrder() {
        XCTAssertEqual(StarterBlendCatalog.blends.map(\.id), Self.expected.map(\.0))
        for (blend, expected) in zip(StarterBlendCatalog.blends, Self.expected) {
            XCTAssertEqual(blend.trackIDs, expected.1)
            XCTAssertEqual(Set(blend.trackIDs).count, 6, "unique tracks")
        }
        XCTAssertEqual(Set(StarterBlendCatalog.blends.flatMap(\.trackIDs)).count, 36)
    }

    func testManifestAndPlansAreComplete() {
        XCTAssertEqual(StarterBlendPack.trackFacts.count, 36)
        XCTAssertEqual(StarterBlendPack.edgePlans.count, 30)
        for blend in StarterBlendCatalog.blends {
            let plans = blend.edgePlans
            XCTAssertEqual(plans.count, 5, blend.id)
            XCTAssertEqual(plans.map(\.edge), [1, 2, 3, 4, 5])
            for (index, plan) in plans.enumerated() {
                XCTAssertEqual(plan.outgoing, blend.trackIDs[index])
                XCTAssertEqual(plan.incoming, blend.trackIDs[index + 1])
                XCTAssertGreaterThan(plan.tempo, 0.5)
                XCTAssertGreaterThan(plan.period, 0.2)
                XCTAssertGreaterThan(plan.incomingGain, 0)
                if plan.style == .phraseCut {
                    XCTAssertEqual(plan.overlapBeats, 0)
                    XCTAssertEqual(plan.swapSeconds, plan.blendStartSeconds)
                } else {
                    XCTAssertEqual(plan.overlapBeats, 64)
                    // The swap is the midpoint downbeat: half the overlap after the start.
                    XCTAssertEqual(plan.swapSeconds - plan.blendStartSeconds,
                                   Double(plan.overlapBeats / 2) * plan.period, accuracy: 1e-6)
                    XCTAssertEqual(plan.blendEndSeconds - plan.blendStartSeconds,
                                   Double(plan.overlapBeats) * plan.period, accuracy: 1e-6)
                }
                let out = StarterBlendPack.facts(trackID: plan.outgoing)
                XCTAssertNotNil(out)
                XCTAssertLessThan(plan.blendStartSeconds, out?.duration ?? 0)
            }
        }
        XCTAssertEqual(StarterBlendPack.edgePlans.filter { $0.style == .phraseCut }.count, 2)
        XCTAssertEqual(StarterBlendPack.edgePlans.filter { $0.style == .doubleDrop }.count, 3)
        XCTAssertEqual(StarterBlendPack.edgePlans.filter { $0.style == .bassSwap }.count, 25)
    }

    func testFirstPublishedPlanIsPreservedExactly() throws {
        let plan = try XCTUnwrap(StarterBlendPack.plan(from: "337997", to: "1424003"))
        XCTAssertEqual(plan.style, .bassSwap)
        XCTAssertEqual(plan.tempo, 1.027062079171714)
        XCTAssertEqual(plan.incomingGain, 1.8138238773630753)
        XCTAssertEqual(plan.overlapBeats, 64)
        XCTAssertEqual(plan.outgoingBeat, 270)
        XCTAssertEqual(plan.incomingBeat, 32)
        XCTAssertEqual(plan.blendStartSeconds, 173.87837804159568)
        XCTAssertEqual(plan.swapSeconds, 197.24420019525732)
        XCTAssertEqual(plan.incomingOffsetSeconds, 173.77569620595946)
    }

    func testRenderPlanRescalesToTheOutgoingDeckTempo() throws {
        let plan = try XCTUnwrap(StarterBlendPack.plan(from: "1424003", to: "337069"))
        let native = plan.renderPlan()
        XCTAssertEqual(native.blendStart, plan.blendStartSeconds)
        XCTAssertEqual(native.swapTime, plan.swapSeconds, accuracy: 1e-6)
        let t = 1.027062079171714
        let scaled = plan.renderPlan(outgoingTempo: t)
        // Same musical moment in both time bases.
        XCTAssertEqual(scaled.blendStart * t, plan.blendStartSeconds, accuracy: 1e-9)
        XCTAssertEqual(scaled.swapTime * t, plan.swapSeconds, accuracy: 1e-6)
        // Incoming source position at the swap is unchanged.
        XCTAssertEqual((scaled.swapTime - scaled.incomingOffset) * scaled.tempo,
                       (native.swapTime - native.incomingOffset) * native.tempo, accuracy: 1e-6)
    }

    func testTrackStateMachineAndSelection() {
        XCTAssertEqual(StarterBlendPack.state(trackID: "999"), .unindexed)
        XCTAssertFalse(BlendTrackState.unindexed.isSelectable)
        XCTAssertLessThan(BlendTrackState.blendEligible, .edgePlanned)
        for blend in StarterBlendCatalog.blends {
            for id in blend.trackIDs { XCTAssertEqual(StarterBlendPack.state(trackID: id), .edgePlanned) }
            XCTAssertEqual(blend.selectableTrackIDs, blend.trackIDs)
        }
    }

    func testDocumentCarriesPlansPackIdentityAndReplays() throws {
        for blend in StarterBlendCatalog.blends {
            let document = blend.document
            XCTAssertEqual(document, blend.document, "deterministic")
            XCTAssertEqual(document.origin, .starter)
            XCTAssertEqual(document.pack, StarterPackIdentity(blendID: blend.id))
            XCTAssertEqual(document.edges.compactMap(\.plan), blend.edgePlans)
            XCTAssertEqual(document.occurrences.compactMap(StarterBlendCatalog.trackID(of:)), blend.trackIDs)

            let data = try JSONEncoder().encode(document)
            let decoded = try JSONDecoder().decode(BlendDocument.self, from: data)
            XCTAssertEqual(decoded, document)
            XCTAssertEqual(StarterBlendCatalog.blend(replaying: decoded)?.id, blend.id)
        }
        var foreign = StarterBlendCatalog.blends[0].document
        foreign.pack = StarterPackIdentity(releaseTag: "starter-blends-aac-v2", blendID: "starter.morning-light")
        XCTAssertNil(StarterBlendCatalog.blend(replaying: foreign))
    }

    func testAssetURLsAreVersionedReleaseAssetsNeverJamendo() {
        for id in StarterBlendCatalog.blends.flatMap(\.trackIDs) {
            let url = StarterBlendPack.assetURL(trackID: id)
            XCTAssertEqual(url.absoluteString,
                           "https://github.com/johnarleyburns/parso-tonearm/releases/download/starter-blends-aac-v1/\(id).m4a")
            XCTAssertTrue(StarterBlendPack.isReleaseAsset(url))
            XCTAssertEqual(StarterBlendPack.trackID(ofAsset: url), id)
        }
        XCTAssertFalse(StarterBlendPack.isReleaseAsset(URL(string: "https://storage.jamendo.com/x/1.m4a")!))
    }

    func testFreshInstallStartsWithoutPreparationAndUsesReleaseRows() async {
        let blend = StarterBlendCatalog.blends[0]
        let log = StartLog()
        let playback = StarterBlendPlayback(probe: { _ in }, start: { log.requests.append($0) })
        await playback.play(blend)
        XCTAssertEqual(log.requests.count, 1)
        let request = log.requests[0]
        XCTAssertTrue(request.isPrepared)
        XCTAssertEqual(request.edgePlans, blend.edgePlans)
        XCTAssertEqual(request.occurrenceIDs, blend.document.occurrences.map(\.id))
        XCTAssertEqual(request.rows.compactMap { $0.asset?.remoteURL },
                       blend.trackIDs.map { StarterBlendPack.assetURL(trackID: $0).absoluteString })
        XCTAssertEqual(Set(request.rows.compactMap(\.track.id)).count, 6, "unique row ids")
        XCTAssertEqual(playback.state(for: blend), .idle)
        for row in request.rows { XCTAssertEqual(row.asset?.transientRemoteSupportsByteRanges, true) }
    }

    func testAllSixCardsStart() async {
        let log = StartLog()
        let playback = StarterBlendPlayback(probe: { _ in }, start: { log.requests.append($0) })
        for blend in StarterBlendCatalog.blends { await playback.play(blend) }
        XCTAssertEqual(log.requests.map(\.blendID), StarterBlendCatalog.blends.map(\.id))
        XCTAssertTrue(log.requests.allSatisfy(\.isPrepared))
    }

    func testPreparedBlendNeverShowsTheFalseFallbackStrings() async {
        let blend = StarterBlendCatalog.blends[1]
        let log = StartLog()
        let playback = StarterBlendPlayback(probe: { _ in }, start: { log.requests.append($0) })
        await playback.play(blend)
        XCTAssertEqual(playback.state(for: blend), .idle)
        let text = ([blend.title, blend.summary] + log.requests[0].rows.map(\.track.title)
                    + blend.document.edges.compactMap(\.requestedStyle)).joined(separator: "\n")
        for string in failureStrings { XCTAssertFalse(text.contains(string)) }
        XCTAssertTrue(blend.document.edges.allSatisfy { $0.plan != nil }, "every edge has a concrete plan")
    }

    func testUnavailableAssetIsRetryableAndOffersSequentialPlayback() async {
        let blend = StarterBlendCatalog.blends[0]
        let other = StarterBlendCatalog.blends[1]
        let log = StartLog()
        let outage = OutageFlag()
        let playback = StarterBlendPlayback(
            probe: { _ in if outage.isDown { throw RangeFetchError.retryable("HTTP 503") } },
            start: { log.requests.append($0) })
        await playback.play(blend)
        guard case .unavailable(let message, let retryable) = playback.state(for: blend) else {
            return XCTFail("expected unavailable")
        }
        XCTAssertTrue(retryable)
        XCTAssertTrue(message.contains("503"))
        for string in failureStrings { XCTAssertFalse(message.contains(string)) }
        XCTAssertTrue(log.requests.isEmpty)
        XCTAssertEqual(playback.state(for: other), .idle, "failure is scoped to the card")

        playback.playSequentially(blend)
        XCTAssertEqual(log.requests.count, 1)
        XCTAssertFalse(log.requests[0].isPrepared, "sequential makes no smart-blend claim")
        XCTAssertEqual(log.requests[0].rows.count, 6)

        await playback.play(blend)
        outage.isDown = false
        await playback.play(blend)
        XCTAssertEqual(log.requests.count, 2)
        XCTAssertTrue(log.requests[1].isPrepared)
    }

    func testPermanentlyMissingAssetIsNotRetryable() async {
        let blend = StarterBlendCatalog.blends[2]
        let playback = StarterBlendPlayback(probe: { _ in throw RangeFetchError.permanent("HTTP 404") },
                                            start: { _ in XCTFail("must not start") })
        await playback.play(blend)
        guard case .unavailable(_, let retryable) = playback.state(for: blend) else { return XCTFail() }
        XCTAssertFalse(retryable)
        playback.playSequentially(blend)   // not offered for a permanent failure's pending request
    }

    func testRepeatedTapWhileInFlightStartsOnce() async {
        let blend = StarterBlendCatalog.blends[0]
        let log = StartLog()
        let playback = StarterBlendPlayback(probe: { _ in try await Task.sleep(nanoseconds: 50_000_000) },
                                            start: { log.requests.append($0) })
        async let a: Void = playback.play(blend)
        async let b: Void = playback.play(blend)
        _ = await (a, b)
        XCTAssertEqual(log.requests.count, 1)
    }
}

private final class OutageFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var down = true
    var isDown: Bool {
        get { lock.withLock { down } }
        set { lock.withLock { down = newValue } }
    }
}
