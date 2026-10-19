import Foundation

/// Spoken labels, values and hints for Up Next rows and header controls, so
/// VoiceOver and Switch Control get the same information sighted users see.
public enum QueueAccessibility {
    public static let minimumTargetSide: Double = 44

    public static func rowLabel(position: Int, title: String, artist: String) -> String {
        let name = artist.isEmpty ? title : "\(title), \(artist)"
        return "\(position), \(name)"
    }

    public static func rowValue(isCurrent: Bool) -> String {
        isCurrent ? "Now playing" : ""
    }

    public static func rowHint(isCurrent: Bool) -> String {
        isCurrent ? "Currently playing" : "Plays this track now"
    }

    public static func reorderLabel(isReordering: Bool) -> String {
        isReordering ? "Done Reordering" : "Reorder Up Next"
    }

    public static func keepPlayingValue(isOn: Bool) -> String {
        isOn ? "on" : "off"
    }

    public static let keepPlayingHint = "Toggles adding similar tracks when the queue ends"
    public static let removeActionName = "Remove from queue"
}
