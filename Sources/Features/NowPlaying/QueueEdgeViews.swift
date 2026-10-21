import SwiftUI
import TonearmCore

/// Connector between two queue cards: one directed outgoing→incoming edge, drawn on the spine.
/// A semantic Button at least 44 pt tall; state is carried by text and shape, not colour alone.
struct QueueTransitionConnector: View {
    let edge: QueueEdgeRow
    let isSelected: Bool
    /// 1-based queue position of the incoming track (1 when the edge loops back).
    let incomingPosition: Int
    let onSelect: () -> Void

    private var timeline: QueueEdgeTimeline { edge.timeline }
    private var presentation: TransitionPresentation { edge.presentation }

    private var glyph: String {
        if edge.playsWithoutBlend { return "equal" }
        switch presentation.phase {
        case .fallback: return "arrow.right"
        case .preparing: return "hourglass"
        case .notPlanned, .noEdge: return "ellipsis"
        default: return presentation.actualStyle == .gapless ? "equal" : "waveform.path"
        }
    }

    /// Overlap progress from the live presentation only; nil when it is not known.
    private var progress: Double? {
        guard edge.isActive, let range = presentation.overlapRange, let left = presentation.secondsRemaining,
              range.upperBound > range.lowerBound else { return nil }
        return min(max(1 - left / (range.upperBound - range.lowerBound), 0), 1)
    }

    var body: some View {
        Button(action: onSelect) {
            HStack(alignment: .center, spacing: 10) {
                spineSegment
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        chip(edge.reason == nil ? timeline.kindLabel : String(localized: "Transition"), systemImage: glyph)
                        if edge.reason == nil, timeline.kind != .unplanned {
                            chip(timeline.availabilityLabel, systemImage: nil)
                        }
                        if edge.isActive { chip(String(localized: "Now blending"), systemImage: "waveform", strong: true) }
                    }
                    Text(edge.reason ?? detailLine)
                        .font(Typography.caption)
                        .foregroundStyle(Palette.inkSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                    if edge.isActive, let progress {
                        ProgressView(value: progress).tint(Palette.accent)
                            .motion(value: progress)
                    }
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right").font(Typography.caption).foregroundStyle(Palette.inkTertiary)
            }
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
            .background(edge.isActive ? Palette.accent.opacity(0.12) : (isSelected ? Palette.ink.opacity(0.06) : .clear),
                        in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10)
                .strokeBorder(edge.isActive ? Palette.accent : (isSelected ? Palette.inkSecondary : .clear),
                              lineWidth: edge.isActive ? 2 : 1))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(edge.accessibilityLabel)
        .accessibilityValue(QueueAccessibility.edgeValue(isActive: edge.isActive, isSelected: isSelected,
                                                         incomingPosition: incomingPosition))
        .accessibilityHint(QueueAccessibility.edgeHint)
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
        .accessibilityIdentifier("queue.edge.\(edge.key.position)")
    }

    private var detailLine: String { timeline.summary }

    /// Vertical connector with a node; filled while the edge is audible.
    private var spineSegment: some View {
        VStack(spacing: 0) {
            Rectangle().fill(Palette.hairline).frame(width: 2)
            Circle()
                .fill(edge.isActive ? Palette.accent : Palette.surfaceRaised)
                .overlay(Circle().strokeBorder(edge.isActive ? Palette.accent : Palette.inkTertiary, lineWidth: 2))
                .frame(width: 10, height: 10)
            Rectangle().fill(Palette.hairline).frame(width: 2)
        }
        .frame(width: 20)
        .accessibilityHidden(true)
    }

    private func chip(_ text: String, systemImage: String?, strong: Bool = false) -> some View {
        HStack(spacing: 3) {
            if let systemImage { Image(systemName: systemImage) }
            Text(text).lineLimit(1)
        }
        .font(Typography.caption.weight(strong ? .bold : .regular))
        .foregroundStyle(strong ? Palette.accentOnFill : Palette.ink)
        .padding(.horizontal, 8).padding(.vertical, 3)
        .background(strong ? Palette.accent : Palette.ink.opacity(0.08), in: Capsule())
    }
}

/// Detail for exactly one occurrence pair. Every action carries that pair's key, so a duplicate
/// or reordered edge with the same track IDs is never touched.
struct QueueEdgeDetailSheet: View {
    @EnvironmentObject private var player: AudioPlayer
    let edge: QueueEdgeRow
    let outgoing: TrackRow?
    let incoming: TrackRow?
    let incomingPosition: Int
    @Environment(\.dismiss) private var dismiss

    private var presentation: TransitionPresentation { edge.presentation }

    var body: some View {
        NavigationStack {
            List {
                Section("Edge") {
                    LabeledContent("From", value: "\(edge.key.position + 1). \(outgoing?.track.title ?? "—")")
                    LabeledContent("To", value: "\(incomingPosition). \(incoming?.track.title ?? "—")")
                }
                Section("Transition") {
                    LabeledContent("Requested", value: edge.snapshot?.requestedStyle?.label ?? presentation.plannedStyle?.label ?? "—")
                    LabeledContent("Executed", value: edge.snapshot?.executedStyle?.label ?? presentation.actualStyle?.label
                                   ?? String(localized: "Not decided yet"))
                    LabeledContent("Status", value: edge.reason ?? edge.timeline.summary)
                    if let detail = presentation.fallbackDetail {
                        Text(detail).foregroundStyle(Palette.inkSecondary)
                    }
                }
                Section("Actions") {
                    if edge.canPlayWithoutBlend, let key = edge.key.executionKey {
                        Button("Play without blend") {
                            if player.playWithoutBlend(key) { dismiss() }
                        }
                        .frame(minHeight: 44)
                        .accessibilityIdentifier("queue.edge.playWithoutBlend")
                    }
                    if edge.canRetry, let key = edge.key.executionKey {
                        Button("Retry transition") {
                            if player.retryTransition(key) { dismiss() }
                        }
                        .frame(minHeight: 44)
                        .accessibilityIdentifier("queue.edge.retry")
                    }
                    if !edge.canPlayWithoutBlend && !edge.canRetry {
                        Text("No actions are available for this transition right now.")
                            .font(Typography.caption).foregroundStyle(Palette.inkSecondary)
                    }
                }
            }
            .navigationTitle("Transition")
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
    }
}
