import XCTest
@testable import TonearmCore

final class GenrePickerAccountToggleTests: XCTestCase {
    private func source() throws -> String {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/Features/Ingest/GenrePickerView.swift")
        return try String(contentsOf: url, encoding: .utf8)
    }

    /// The production catalogue-account checkbox must be a native Toggle with
    /// the stable identifier and no tappable-image gesture.
    func testAccountCheckboxIsSemanticToggleNotTapGesture() throws {
        let src = try source()
        XCTAssertFalse(src.contains(".onTapGesture"))
        XCTAssertTrue(src.contains("Toggle(isOn: $model.showsAccountOption)"))
        XCTAssertTrue(src.contains("accessibilityIdentifier(\"genre.account.optional\")"))
        XCTAssertFalse(src.contains(".frame(width: 22, height: 22)"))
        XCTAssertTrue(src.contains("minHeight: 44"))
    }
}
