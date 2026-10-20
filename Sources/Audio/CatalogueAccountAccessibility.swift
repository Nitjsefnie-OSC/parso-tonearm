import Foundation

/// Spoken labels and values for the Add Remote Library (catalogue/account)
/// controls, so selection, errors and busy state never rely on color alone.
public enum CatalogueAccountAccessibility {
    public static let minimumTargetSide: Double = 44

    public static func connectorValue(isSelected: Bool) -> String {
        isSelected ? "Selected" : ""
    }

    public static func connectorLabel(title: String, isAdvanced: Bool) -> String {
        isAdvanced ? "\(title), advanced" : title
    }

    public static func errorAnnouncement(_ message: String) -> String {
        "Error: \(message)"
    }

    public static let connectingLabel = "Connecting"
    public static let connectingAnnouncement = "Connecting to library"
}
