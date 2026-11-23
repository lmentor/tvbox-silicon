import SwiftUI
import Perception
import TVCore

/// The same player cover stays open from the history tap through URL resolution
/// and actual playback. Close remains usable before the source has responded.
struct HistoryPlaybackPreparationView: View {
    let preparation: HistoryPlaybackPreparation
    let presentationID: UUID
    @Environment(Store.self) private var store

    var body: some View {
        WithPerceptionTracking {
            ZStack {
                Color.black.ignoresSafeArea()
                PlaybackWaitView(artwork: PlaybackArtwork(poster: preparation.entry.context.poster,
                    headers: preparation.entry.context.posterHeaders ?? [:]), starting: true,
                    showsWords: preparation.failure == nil) { _ in
                        PlaybackWait(message: L10n.text("Resolving playback URL…"))
                    }
                if let failure = preparation.failure {
                    VStack(spacing: 18) {
                        Image(systemName: "exclamationmark.triangle").font(.largeTitle)
                        Text(failure).font(.body).multilineTextAlignment(.center)
                        Button { store.resume(preparation.entry, mode: preparation.mode) } label: {
                            Label(L10n.text("Retry"), systemImage: "arrow.clockwise")
                                .font(.headline).padding(.horizontal, 20).frame(minHeight: 44)
                        }
                        .buttonStyle(.plain)
                        .background(.white.opacity(0.16), in: Capsule())
                        .accessibilityIdentifier("player.history.retry")
                    }
                    .padding(28).frame(maxWidth: 540)
                }
            }
            .overlay(alignment: .topLeading) {
                HStack(alignment: .top, spacing: 16) {
                    Button { store.cancelResume() } label: {
                        Image(systemName: "xmark").font(.system(size: 18, weight: .semibold))
                            .frame(width: 44, height: 44)
                            .background(.black.opacity(0.4), in: Circle())
                    }
                    .buttonStyle(.plain).accessibilityLabel(L10n.text("Close"))
                    .accessibilityIdentifier("player.history.close")
                    VStack(alignment: .leading, spacing: 5) {
                        Text(preparation.entry.context.displayTitle).font(.headline).lineLimit(2)
                        Text(preparation.entry.context.episodeName).font(.subheadline).foregroundStyle(.white.opacity(0.7)).lineLimit(2)
                    }.padding(.top, 5)
                    Spacer(minLength: 0)
                }.padding(16)
            }
            .foregroundStyle(.white)
            .preferredColorScheme(.dark)
            .accessibilityIdentifier("player.history.preparing")
            .sheet(item: Binding(get: { PluginSignIn.shared.prompt }, set: {
                if $0 == nil { PluginSignIn.shared.dismiss() }
            })) { prompt in
                WithPerceptionTracking { PluginSignInView(prompt: prompt) }
            }
            .task(id: preparation.id.uuidString + ":" + presentationID.uuidString) {
                store.presentHistoryPlayback(preparation.id, presentationID: presentationID)
            }
            #if os(tvOS)
            .onExitCommand { store.cancelResume() }
            #endif
        }
    }
}
