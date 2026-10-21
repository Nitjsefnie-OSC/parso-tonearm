import XCTest
@testable import TonearmCore

final class FindBlendSearchTests: XCTestCase {
    func testBlankQueryYieldsNothing() {
        XCTAssertTrue(FindBlendSearch.results(query: "  ", saved: []).isEmpty)
    }

    func testStarterMatchesTitleCaseInsensitively() {
        let results = FindBlendSearch.results(query: "rainy", saved: [])
        XCTAssertEqual(results.map(\.id), ["starter.starter.rainy-day"])
    }

    func testNoMatchIsEmptyAndDeterministic() {
        XCTAssertTrue(FindBlendSearch.results(query: "zzzqqq", saved: []).isEmpty)
    }

    func testSavedBlendsPrecedeStarters() throws {
        var doc = try XCTUnwrap(StarterBlendCatalog.blends.first).document
        doc.title = "Morning Mix"
        let results = FindBlendSearch.results(query: "morning", saved: [doc])
        guard case .saved = results.first else { return XCTFail("saved first") }
        XCTAssertEqual(results.count, 2)
    }
}
