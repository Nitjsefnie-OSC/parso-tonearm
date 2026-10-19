import XCTest
@testable import TonearmCore

final class QueueAccessibilityTests: XCTestCase {
    func testRowLabelIncludesPositionTitleAndArtist() {
        XCTAssertEqual(QueueAccessibility.rowLabel(position: 2, title: "Song", artist: "Band"), "2, Song, Band")
        XCTAssertEqual(QueueAccessibility.rowLabel(position: 3, title: "Song", artist: ""), "3, Song")
    }

    func testRowStateAndHintDifferForCurrentTrack() {
        XCTAssertEqual(QueueAccessibility.rowValue(isCurrent: true), "Now playing")
        XCTAssertEqual(QueueAccessibility.rowValue(isCurrent: false), "")
        XCTAssertNotEqual(QueueAccessibility.rowHint(isCurrent: true), QueueAccessibility.rowHint(isCurrent: false))
    }

    func testControlLabelsAndTargetSize() {
        XCTAssertEqual(QueueAccessibility.reorderLabel(isReordering: true), "Done Reordering")
        XCTAssertEqual(QueueAccessibility.reorderLabel(isReordering: false), "Reorder Up Next")
        XCTAssertEqual(QueueAccessibility.keepPlayingValue(isOn: true), "on")
        XCTAssertEqual(QueueAccessibility.keepPlayingValue(isOn: false), "off")
        XCTAssertGreaterThanOrEqual(QueueAccessibility.minimumTargetSide, 44)
    }
}
