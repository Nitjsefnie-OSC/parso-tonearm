import XCTest
@testable import TonearmCore

final class CatalogueAccountAccessibilityTests: XCTestCase {
    func testSelectedConnectorIsAnnouncedWithoutColor() {
        XCTAssertEqual(CatalogueAccountAccessibility.connectorValue(isSelected: true), "Selected")
        XCTAssertEqual(CatalogueAccountAccessibility.connectorValue(isSelected: false), "")
    }

    func testAdvancedConnectorLabelNamesTier() {
        XCTAssertEqual(CatalogueAccountAccessibility.connectorLabel(title: "Plex", isAdvanced: true), "Plex, advanced")
        XCTAssertEqual(CatalogueAccountAccessibility.connectorLabel(title: "Plex", isAdvanced: false), "Plex")
    }

    func testErrorAndBusyStateAreSpoken() {
        XCTAssertEqual(CatalogueAccountAccessibility.errorAnnouncement("Bad password"), "Error: Bad password")
        XCTAssertFalse(CatalogueAccountAccessibility.connectingLabel.isEmpty)
        XCTAssertGreaterThanOrEqual(CatalogueAccountAccessibility.minimumTargetSide, 44)
    }
}
