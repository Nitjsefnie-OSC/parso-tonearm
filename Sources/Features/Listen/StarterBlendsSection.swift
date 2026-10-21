import SwiftUI
import TonearmCore

/// The first Listen content: curated starter blends rendered synchronously from
/// `StarterBlendCatalog`. It needs no model, index, sign-in or library, and
/// each card's Play/failure/retry state is independent of the others.
struct StarterBlendsSection: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        StarterBlendsList(playback: appState.starterBlends)
    }
}

private struct StarterBlendsList: View {
    @ObservedObject var playback: StarterBlendPlayback

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SectionHeader(title: "Starter Blends")
            VStack(spacing: 10) {
                ForEach(StarterBlendCatalog.blends) { blend in
                    StarterBlendCard(blend: blend, state: playback.state(for: blend),
                                     play: { Task { await playback.play(blend) } },
                                     playSequentially: { playback.playSequentially(blend) })
                }
            }
            HStack(spacing: 6) {
                Text(StarterBlendCatalog.attribution)
                Link("Credits", destination: StarterBlendCatalog.creditsURL)
                    .accessibilityIdentifier("listen.starter.credits")
            }
            .font(Typography.caption)
            .foregroundStyle(Palette.inkSecondary)
            .padding(.top, 8)
            .padding(.bottom, 12)
        }
        .accessibilityIdentifier("listen.starter")
    }
}

private struct StarterBlendCard: View {
    let blend: StarterBlend
    let state: StarterBlendPlayback.CardState
    let play: () -> Void
    let playSequentially: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 10)
                    .fill(Color(hue: blend.artworkHue, saturation: 0.55, brightness: 0.45))
                Image(systemName: blend.artworkSymbol)
                    .foregroundStyle(.white)
                    .font(Typography.title)
            }
            .frame(width: 56, height: 56)
            .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 2) {
                Text(blend.title).font(Typography.headline)
                Text(blend.summary).font(Typography.caption).foregroundStyle(Palette.inkSecondary)
                if case .failed(let message) = state {
                    Text(message).font(Typography.caption).foregroundStyle(Palette.danger)
                }
                if case .preparing(let done, let total) = state {
                    Text("Preparing blend: \(done) of \(total) tracks ready")
                        .font(Typography.caption).foregroundStyle(Palette.inkSecondary)
                }
                if case .unprepared(let reason) = state {
                    Text(reason).font(Typography.caption).foregroundStyle(Palette.danger)
                    Button("Play tracks in order without blends", action: playSequentially)
                        .font(Typography.caption)
                        .accessibilityIdentifier("listen.starter.sequential.\(blend.id)")
                }
            }
            Spacer(minLength: 8)
            Button(action: play) {
                if state == .loading || isPreparing {
                    ProgressView()
                } else if isFailed {
                    Label("Retry", systemImage: "arrow.clockwise")
                } else {
                    Label("Play", systemImage: "play.fill")
                }
            }
            .buttonStyle(.bordered)
            .disabled(state == .loading || isPreparing)
            .accessibilityIdentifier("listen.starter.play.\(blend.id)")
        }
        .padding(12)
        .background(Palette.ink.opacity(0.07), in: RoundedRectangle(cornerRadius: 14))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(blend.title). \(blend.summary)")
        .accessibilityHint(hint)
        .accessibilityAction(named: Text(isFailed ? "Retry" : "Play"), play)
    }

    private var isFailed: Bool {
        switch state {
        case .failed, .unprepared: true
        default: false
        }
    }
    private var isPreparing: Bool { if case .preparing = state { true } else { false } }
    private var hint: LocalizedStringKey {
        isFailed ? "Couldn't load this blend. Double tap to retry." : "Double tap to play this blend."
    }
}
