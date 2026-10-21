import os
import XCTest
@testable import TonearmCore

private func jt(_ id: String) -> JamendoTrack {
        JamendoTrack(id: id, name: "T\(id)", duration: 100, artistID: nil, artistName: "A",
                     albumName: nil, albumID: nil, licenseCcurl: nil,
                     audio: "https://example.test/\(id).mp3", audiodownload: nil,
                     audiodownloadAllowed: nil, albumImage: nil, musicinfo: nil)
}

@MainActor
private final class StartLog {
    var requests: [StarterPlayRequest] = []
}

@MainActor
final class StarterBlendTests: XCTestCase {

    func testCatalogIsDeterministicAndComplete() {
        XCTAssertGreaterThanOrEqual(StarterBlendCatalog.blends.count, 6)
        XCTAssertEqual(Set(StarterBlendCatalog.blends.map(\.id)).count, StarterBlendCatalog.blends.count)
        for blend in StarterBlendCatalog.blends {
            XCTAssertFalse(blend.jamendoTrackIDs.isEmpty)
            XCTAssertEqual(blend.document, blend.document)
            XCTAssertEqual(blend.document.origin, .starter)
            XCTAssertEqual(blend.document.occurrences.count, blend.jamendoTrackIDs.count)
            XCTAssertEqual(blend.document.edges.map(\.requestedStyle),
                           Array(repeating: blend.requestedStyle, count: blend.jamendoTrackIDs.count - 1))
        }
    }

    func testPlayProducesOneRequestWithOrderedOccurrences() async throws {
        let blend = StarterBlendCatalog.blends[0]
        let log = StartLog()
        // Jamendo may return tracks in any order.
        let playback = StarterBlendPlayback(
            fetch: { ids in ids.reversed().map { jt($0) } },
            start: { log.requests.append($0) })
        await playback.play(blend)
        let requests = log.requests
        XCTAssertEqual(requests.count, 1)
        XCTAssertEqual(requests[0].occurrenceIDs, blend.document.occurrences.map(\.id))
        XCTAssertEqual(requests[0].rows.map(\.track.title), blend.jamendoTrackIDs.map { "T\($0)" })
    }

    func testFailureIsCardScopedAndRetryable() async {
        let failing = StarterBlendCatalog.blends[0], other = StarterBlendCatalog.blends[1]
        let offline = OSAllocatedUnfairLock(initialState: true)
        let log = StartLog()
        let playback = StarterBlendPlayback(
            fetch: { ids in
                if offline.withLock({ $0 }) && ids == failing.jamendoTrackIDs { throw JamendoGenreError.transport }
                return ids.map { jt($0) }
            },
            start: { log.requests.append($0) })
        await playback.play(failing)
        guard case .failed = playback.state(for: failing) else { return XCTFail("expected failure") }
        XCTAssertEqual(playback.state(for: other), .idle)
        await playback.play(other)
        XCTAssertEqual(log.requests.count, 1)
        offline.withLock { $0 = false }
        await playback.play(failing)
        XCTAssertEqual(playback.state(for: failing), .idle)
        XCTAssertEqual(log.requests.count, 2)
    }

    func testRepeatedTapWhileInFlightStartsOnce() async {
        let blend = StarterBlendCatalog.blends[0]
        let log = StartLog()
        let playback = StarterBlendPlayback(
            fetch: { ids in try await Task.sleep(nanoseconds: 50_000_000); return ids.map { jt($0) } },
            start: { log.requests.append($0) })
        async let a: Void = playback.play(blend)
        async let b: Void = playback.play(blend)
        _ = await (a, b)
        XCTAssertEqual(log.requests.count, 1)
    }
}
