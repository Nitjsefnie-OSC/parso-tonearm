import SwiftUI
import TonearmCore

/// The detail destination shared by the Now Playing card and queue connectors.
struct TransitionDetailSheet: View {
    @EnvironmentObject private var player: AudioPlayer
    @EnvironmentObject private var transitionPrep: TransitionPrepService
    let presentation: TransitionPresentation

    var body: some View {
        NavigationStack {
            if let plan = player.transitionPlan, presentation.phase != .notPlanned {
                WhyThisTransitionView(plan: plan, preparationState: presentation.preparation)
            } else {
                List {
                    Section("Why This Transition?") {
                        Text(presentation.connectorLabel)
                        if let detail = presentation.fallbackDetail {
                            Text(detail).foregroundStyle(Palette.inkSecondary)
                        }
                    }
                }
                .navigationTitle("Why This Transition?")
            }
        }
    }
}

/// Compact tappable card under the progress bar; expands to a two-track card only while blending.
struct TransitionCard: View {
    @EnvironmentObject private var player: AudioPlayer
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dynamicTypeSize) private var typeSize
    @State private var showDetail = false

    private var presentation: TransitionPresentation { player.transitionPresentation }

    private func row(_ id: Int64?) -> TrackRow? {
        guard let id else { return nil }
        return ([player.currentTrack].compactMap { $0 } + player.queue).first { $0.track.id == id }
    }

    var body: some View {
        let p = presentation
        if p.showsConnector, p.phase != .notPlanned {
            Button { showDetail = true } label: {
                VStack(alignment: .leading, spacing: 6) {
                    if p.isBlendingNow {
                        blendingBody(p)
                    } else {
                        Text(p.cardTitle)
                            .font(Typography.caption)
                            .foregroundStyle(Palette.ink)
                            .fixedSize(horizontal: false, vertical: true)
                        if let detail = p.fallbackDetail {
                            Text(detail).font(Typography.caption).foregroundStyle(Palette.inkSecondary)
                        }
                        if !typeSize.isAccessibilitySize, !p.diagramSegments.isEmpty {
                            TransitionDiagram(presentation: p, position: player.currentTime)
                        }
                    }
                }
                .padding(10)
                .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                .background(Palette.surfaceRaised, in: RoundedRectangle(cornerRadius: 12))
                .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Palette.hairline))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(p.accessibilityLabel(outgoingTitle: row(p.outgoingTrackID)?.track.title,
                                                     incomingTitle: row(p.incomingTrackID)?.track.title))
            .accessibilityValue(p.accessibilityValue)
            .accessibilityHint("Shows why this transition was chosen")
            .accessibilityIdentifier("np.transitionCard")
            .sheet(isPresented: $showDetail) { TransitionDetailSheet(presentation: p) }
        }
    }

    @ViewBuilder
    private func blendingBody(_ p: TransitionPresentation) -> some View {
        Text(p.cardTitle).font(Typography.caption).foregroundStyle(Palette.ink)
        ForEach([("OUT", p.outgoingTrackID), ("IN", p.incomingTrackID)], id: \.0) { label, id in
            HStack(spacing: 8) {
                if let r = row(id) {
                    ArtworkView(trackRow: r, seed: r.album?.title ?? r.track.title, cornerRadius: 4)
                        .frame(width: 28, height: 28)
                        .accessibilityHidden(true)
                } else {
                    Image(systemName: "music.note").frame(width: 28, height: 28).accessibilityHidden(true)
                }
                Text("\(label) · \(row(id)?.track.title ?? "")")
                    .font(Typography.caption)
                    .foregroundStyle(Palette.ink)
                    .lineLimit(1)
            }
        }
        if !typeSize.isAccessibilitySize, !p.diagramSegments.isEmpty {
            TransitionDiagram(presentation: p, position: player.currentTime)
        }
    }
}

/// Outgoing-decay / incoming-rise rows with a marked overlap and a playhead. Decorative curves are
/// hidden from accessibility; shapes (dashed outgoing, solid incoming) carry meaning besides color.
struct TransitionDiagram: View {
    let presentation: TransitionPresentation
    let position: Double

    var body: some View {
        Canvas { context, size in
            let third = size.width / 3
            let rowH = size.height / 2 - 2
            var out = Path()
            out.move(to: CGPoint(x: 0, y: 2))
            out.addLine(to: CGPoint(x: third, y: 2))
            out.addLine(to: CGPoint(x: 2 * third, y: rowH - 2))
            context.stroke(out, with: .color(Palette.inkSecondary),
                           style: StrokeStyle(lineWidth: 2, dash: [4, 3]))
            var inc = Path()
            inc.move(to: CGPoint(x: third, y: size.height - 2))
            inc.addLine(to: CGPoint(x: 2 * third, y: rowH + 6))
            inc.addLine(to: CGPoint(x: size.width, y: rowH + 6))
            context.stroke(inc, with: .color(Palette.accent), style: StrokeStyle(lineWidth: 2))
            context.fill(Path(CGRect(x: third, y: 0, width: third, height: size.height)),
                         with: .color(Palette.accent.opacity(0.12)))
            if let head = presentation.playhead(position: position) {
                let x = size.width * head
                context.fill(Path(CGRect(x: x - 1, y: 0, width: 2, height: size.height)),
                             with: .color(Palette.ink))
            }
        }
        .frame(height: 32)
        .accessibilityHidden(true)
    }
}

/// Connector shown between adjacent queue rows. At least 44 pt tall; label plus a shape glyph.
struct QueueTransitionConnector: View {
    let presentation: TransitionPresentation
    @State private var showDetail = false

    private var glyph: String {
        switch presentation.phase {
        case .fallback: "arrow.right"
        case .preparing: "hourglass"
        case .notPlanned: "ellipsis"
        default: presentation.actualStyle == .gapless ? "equal" : "waveform.path"
        }
    }

    var body: some View {
        Button { showDetail = true } label: {
            Label(presentation.connectorLabel, systemImage: glyph)
                .font(Typography.caption)
                .foregroundStyle(Palette.inkSecondary)
                .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(presentation.connectorLabel)
        .accessibilityHint("Shows why this transition was chosen")
        .sheet(isPresented: $showDetail) { TransitionDetailSheet(presentation: presentation) }
    }
}
