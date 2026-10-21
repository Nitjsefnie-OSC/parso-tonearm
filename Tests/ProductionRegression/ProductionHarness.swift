import Foundation

@testable import TonearmCore

/// Hermetic production-flow harness (issue #80). Everything here is injected: no network, no model
/// download, no Docker, no device. Launch configuration comes from `TONEARM_HARNESS_*` environment
/// variables or `-TonearmHarness<Key> <value>` launch arguments, so the same keys can later drive an
/// app-host (Xcode) tier.
struct HarnessConfiguration: Equatable {
    var route = "queue"
    var accessibilityCategory = "large"
    var colorScheme = "light"
    var reduceMotion = false
    var record = false
    var baselineDirectory: URL
    var artifactDirectory: URL

    static let sourceDirectory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()

    static func current(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        arguments: [String] = ProcessInfo.processInfo.arguments
    ) -> HarnessConfiguration {
        func value(_ key: String) -> String? {
            if let v = environment["TONEARM_HARNESS_" + key.uppercased()], !v.isEmpty { return v }
            if let i = arguments.firstIndex(of: "-TonearmHarness" + key), arguments.indices.contains(i + 1) {
                return arguments[i + 1]
            }
            return nil
        }
        return HarnessConfiguration(
            route: value("Route") ?? "queue",
            accessibilityCategory: value("AccessibilityCategory") ?? "large",
            colorScheme: value("ColorScheme") ?? "light",
            reduceMotion: value("ReduceMotion") == "1",
            record: value("Record") == "1",
            baselineDirectory: value("BaselineDir").map { URL(fileURLWithPath: $0) }
                ?? sourceDirectory.appendingPathComponent("Baselines"),
            artifactDirectory: value("ArtifactDir").map { URL(fileURLWithPath: $0) }
                ?? FileManager.default.temporaryDirectory.appendingPathComponent("tonearm-production-regression"))
    }
}

/// Fixed catalog: the only tracks any harness flow can see.
struct FixtureTrack: Equatable {
    let id: Int
    let title: String
    let artist: String
    let duration: Double
}

enum FixtureCatalog {
    static let tracks = [
        FixtureTrack(id: 1, title: "Alpha", artist: "Fixture Band", duration: 185),
        FixtureTrack(id: 2, title: "Bravo", artist: "Fixture Band", duration: 61),
        FixtureTrack(id: 3, title: "Charlie", artist: "", duration: 240),
        FixtureTrack(id: 4, title: "Delta", artist: "Other Act", duration: 3)
    ]
    static func track(_ id: Int) -> FixtureTrack { tracks.first { $0.id == id }! }
}

/// Fixed player clock; never reads wall time.
struct ManualClock {
    private(set) var now: Double = 0
    mutating func advance(_ seconds: Double) { now += seconds }
}

/// The queue-facing calls a screen makes on the player. The recording implementation lets a flow
/// assert that a UI action actually reached the player instead of only mutating local state.
@MainActor
protocol PlayerAdapter {
    func play(trackID: Int)
    func syncQueue(_ ids: [Int], current: Int)
}

@MainActor
final class RecordingPlayerAdapter: PlayerAdapter {
    private(set) var calls: [String] = []
    func play(trackID: Int) { calls.append("play(\(trackID))") }
    func syncQueue(_ ids: [Int], current: Int) { calls.append("syncQueue(\(ids),current:\(current))") }
}

/// Queue screen flow wired to the production `QueueEditor`. `dropAdapterCalls` exists only so the
/// harness can prove it notices a removed adapter call.
@MainActor
struct QueueFlow {
    var state: QueueEditor.State<Int>
    let adapter: any PlayerAdapter
    var dropAdapterCalls = false

    init(queue: [Int], current: Int, adapter: any PlayerAdapter, dropAdapterCalls: Bool = false) {
        state = .init(queue: queue, currentIndex: current)
        self.adapter = adapter
        self.dropAdapterCalls = dropAdapterCalls
    }

    mutating func tapRow(_ index: Int) {
        state = QueueEditor.State(queue: state.queue, currentIndex: index).normalized
        if !dropAdapterCalls { adapter.play(trackID: state.queue[state.currentIndex]) }
    }

    mutating func remove(at index: Int) {
        state = QueueEditor.remove(at: index, in: state)
        if !dropAdapterCalls { adapter.syncQueue(state.queue, current: state.currentIndex) }
    }

    mutating func move(from: Int, to: Int) {
        state = QueueEditor.move(from: from, to: to, in: state)
        if !dropAdapterCalls { adapter.syncQueue(state.queue, current: state.currentIndex) }
    }
}

/// Deterministic text render of a screen: the accessibility surface the user (and VoiceOver) gets.
enum ScreenRenderer {
    static func queue(_ state: QueueEditor.State<Int>, config: HarnessConfiguration) -> String {
        var lines = [
            "screen: \(config.route)",
            "scheme: \(config.colorScheme) category: \(config.accessibilityCategory) reduceMotion: \(config.reduceMotion)",
            "control: \(QueueAccessibility.reorderLabel(isReordering: false)) (min \(Int(QueueAccessibility.minimumTargetSide))pt)"
        ]
        for (i, id) in state.queue.enumerated() {
            let t = FixtureCatalog.track(id)
            let isCurrent = i == state.currentIndex
            let value = QueueAccessibility.rowValue(isCurrent: isCurrent, isUpNext: i == state.currentIndex + 1, duration: t.duration)
            lines.append("row \(i + 1): label=\"\(QueueAccessibility.rowLabel(position: i + 1, title: t.title, artist: t.artist))\" value=\"\(value)\" hint=\"\(QueueAccessibility.rowHint(isCurrent: isCurrent))\"")
        }
        return lines.joined(separator: "\n") + "\n"
    }
}

enum BaselineOutcome: Equatable {
    case match
    case recorded(URL)
    case mismatch(message: String, actual: URL, diff: URL)
    case missing(message: String)
}

/// Compares a render with its stored baseline; on mismatch it writes the actual render and a line
/// diff to the artifact directory and names the screen, state and assertion in the message.
enum BaselineComparator {
    static func compare(screen: String, state: String, rendered: String, config: HarnessConfiguration) -> BaselineOutcome {
        let fm = FileManager.default
        let baseline = config.baselineDirectory.appendingPathComponent("\(screen)-\(state).txt")
        if config.record {
            try? fm.createDirectory(at: config.baselineDirectory, withIntermediateDirectories: true)
            try? rendered.write(to: baseline, atomically: true, encoding: .utf8)
            return .recorded(baseline)
        }
        guard let expected = try? String(contentsOf: baseline, encoding: .utf8) else {
            return .missing(message: "[\(screen)/\(state)] visual baseline missing at \(baseline.path); record with TONEARM_HARNESS_RECORD=1")
        }
        if expected == rendered { return .match }
        try? fm.createDirectory(at: config.artifactDirectory, withIntermediateDirectories: true)
        let actual = config.artifactDirectory.appendingPathComponent("\(screen)-\(state).actual.txt")
        let diff = config.artifactDirectory.appendingPathComponent("\(screen)-\(state).diff.txt")
        let diffText = lineDiff(expected: expected, actual: rendered)
        try? rendered.write(to: actual, atomically: true, encoding: .utf8)
        try? diffText.write(to: diff, atomically: true, encoding: .utf8)
        return .mismatch(
            message: "[\(screen)/\(state)] render differs from baseline \(baseline.lastPathComponent):\n\(diffText)\nartifacts: \(actual.path), \(diff.path)",
            actual: actual, diff: diff)
    }

    static func lineDiff(expected: String, actual: String) -> String {
        let e = expected.components(separatedBy: "\n"), a = actual.components(separatedBy: "\n")
        var out: [String] = []
        for i in 0..<max(e.count, a.count) {
            let l = i < e.count ? e[i] : nil, r = i < a.count ? a[i] : nil
            if l != r {
                if let l { out.append("- line \(i + 1): \(l)") }
                if let r { out.append("+ line \(i + 1): \(r)") }
            }
        }
        return out.joined(separator: "\n")
    }
}
