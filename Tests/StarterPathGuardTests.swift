#if !os(watchOS)
import XCTest
@testable import TonearmCore

/// The Starter path may not reconstruct an asset on disk or route through resident whole-file PCM.
/// These guards read the shipping sources, so a future change that reintroduces either fails here.
final class StarterPathGuardTests: XCTestCase {
    private var repo: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
    }

    private let starterFiles = [
        "Sources/Audio/MixDecks/StarterStreamPlayer.swift",
        "Sources/Audio/MixDecks/ReleaseM4ADeckSource.swift",
        "Sources/Audio/MixDecks/ReleaseRangeReader.swift",
        "Sources/Audio/AudioPlayer+StarterStream.swift",
        "Sources/Remote/StarterBlendPlayback.swift"
    ]

    func testStarterSourcesNeverTouchTheWholeFilePaths() throws {
        let forbidden = ["MixTrackLoader", "MixTrackAudio", "PCMBuffer", "AVAudioFile", "FileHandle",
                         "createFile", "temporaryDirectory", "NSTemporaryDirectory", "URLSession.shared.download",
                         ".bytes(for", "MixDeckPlayer", "FileRangeAudioSource", "adoptIntoCache", "Data(contentsOf"]
        for file in starterFiles {
            let text = try String(contentsOf: repo.appendingPathComponent(file), encoding: .utf8)
            for token in forbidden {
                XCTAssertFalse(text.contains(token), "\(file) must not use \(token)")
            }
        }
    }

    func testStarterRequestsNeverReachTheResidentDecks() throws {
        let text = try String(contentsOf: repo.appendingPathComponent("Sources/Audio/AudioPlayer+MixDecks.swift"), encoding: .utf8)
        XCTAssertTrue(text.contains("guard starterSession == nil else { return false }"),
                      "wantsMixDecks must refuse a starter session, sequential fallback included")
    }

    @MainActor
    func testProductionCallSitesConsumeThePlansEndToEnd() throws {
        let loading = try String(contentsOf: repo.appendingPathComponent("Sources/Audio/AudioPlayer+Loading.swift"), encoding: .utf8)
        XCTAssertTrue(loading.contains("loadCurrentOnStarterStream(row: row, autoplay: autoplay)"))
        let state = try String(contentsOf: repo.appendingPathComponent("Sources/App/AppState.swift"), encoding: .utf8)
        XCTAssertTrue(state.contains("AudioPlayer.shared.playStarterBlend(request)"), "the card hands the whole request to the player")
        let player = try String(contentsOf: repo.appendingPathComponent("Sources/Audio/AudioPlayer+StarterStream.swift"), encoding: .utf8)
        XCTAssertTrue(player.contains("plans: session.plans"), "the session's plans configure the renderer")
        XCTAssertTrue(player.contains("plansStorage = request.edgePlans"))
        XCTAssertFalse(state.contains("AudioPlayer.shared.play(tracks: request.rows"))
    }

    func testStarterCardsOfferNoUnavailableBlendLabels() throws {
        // A loaded Starter Blend publishes concrete edges; these strings belong only to edges with none.
        let rows = try String(contentsOf: repo.appendingPathComponent("Sources/Features/Listen/StarterBlendsSection.swift"), encoding: .utf8)
        for label in ["Smart blend unavailable", "Not planned yet"] { XCTAssertFalse(rows.contains(label)) }
    }
}
#endif
