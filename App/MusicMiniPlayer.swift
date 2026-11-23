import SwiftUI
import Perception
import TVCore

/// A cover, always square with the same rounding for its size, however the image is shaped:
/// rows, the mini player and the Now Playing screen all draw covers through this.
struct MusicArtwork: View {
    let url: URL?
    var size: CGFloat?
    var symbol = "music.note"
    var body: some View {
        WithPerceptionTracking {
            Color.clear
                .aspectRatio(1, contentMode: .fit)
                .overlay { WithPerceptionTracking { PosterImage(url: url, symbol: symbol) } }
                .frame(width: size, height: size)
                .posterClip(RoundedRectangle(cornerRadius: size.map { max(4, $0 * 0.12) } ?? 12, style: .continuous))
        }
    }
}

#if os(iOS)
/// The player as a strip above the tab bar, as in Music: cover, title and artist, play and next.
/// It is always the same height; the lyrics and everything else are on the Now Playing screen,
/// which a tap opens. `inline` is the narrower form beside a minimized tab bar.
struct MusicMiniPlayer: View {
    @Environment(Store.self) private var store
    var inline = false

    var body: some View {
        WithPerceptionTracking {
            let music = store.music
            ZStack {
                MusicMiniPlayerProgress()
                labels(music).allowsHitTesting(false).accessibilityHidden(true)
                // A single native responder owns both the painted empty space
                // and the controls; these visual labels have no second action.
                MusicMiniPlayerTouchSurface(inline: inline,
                    title: [music.track?.title, music.track?.artistLine, music.failure].compactMap { $0 }.joined(separator: ", "),
                    transportLabel: L10n.text(music.failure != nil ? "Retry" : music.busy && !music.isPlaying ? "Now Playing" : music.isPlaying ? "Pause" : "Play"),
                    canAdvance: music.canAdvance,
                    open: { music.presentsPlayer = true },
                    transport: {
                        if music.failure != nil { music.retry() }
                        else if music.busy && !music.isPlaying { music.presentsPlayer = true }
                        else { music.toggle() }
                    },
                    next: { music.next() }, stop: { music.stop() })
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .contentShape(Capsule())
            .accessibilityElement(children: .contain)
        }
    }

    private func labels(_ music: MusicPlaybackSession) -> some View {
        HStack(spacing: 0) {
            HStack(spacing: inline ? 10 : 12) {
                MusicArtwork(url: music.track?.artwork, size: inline ? 28 : 34)
                VStack(alignment: .leading, spacing: 1) {
                    Text(music.track?.title ?? "").font(.subheadline.weight(.semibold)).lineLimit(1)
                    if let failure = music.failure {
                        Text(failure).font(.caption).foregroundStyle(Brand.amber).lineLimit(1)
                    } else if !inline {
                        Text(music.track?.artistLine ?? "").font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.leading, inline ? 6 : 10).padding(.trailing, inline ? 4 : 6)
            .frame(maxWidth: .infinity, minHeight: 44, maxHeight: .infinity, alignment: .leading)
            HStack(spacing: MusicMiniPlayerLayout.spacing(inline: inline)) {
                if music.failure != nil {
                    symbol("arrow.clockwise")
                } else if music.busy && !music.isPlaying {
                    ProgressView().frame(width: MusicMiniPlayerLayout.buttonWidth, height: 44)
                } else {
                    symbol(music.isPlaying ? "pause.fill" : "play.fill")
                        .modifier(MusicPlayPauseTransition())
                }
                if !inline {
                    symbol("forward.fill").opacity(music.canAdvance ? 1 : 0.35)
                    symbol("xmark").font(.body).foregroundStyle(.secondary)
                }
            }
            .font(.title3)
            .fixedSize(horizontal: true, vertical: false)
            .padding(.trailing, MusicMiniPlayerLayout.trailing(inline: inline))
        }
    }

    private func symbol(_ name: String) -> some View {
        Image(systemName: name).frame(width: MusicMiniPlayerLayout.buttonWidth, height: 44)
    }
}

/// Only this leaf reads the 4 Hz music clock. The artwork, controls, dock and
/// retained browsing lists do not rebuild for each progress sample.
private struct MusicMiniPlayerProgress: View {
    @Environment(Store.self) private var store
    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        GeometryReader { geometry in
            WithPerceptionTracking {
                let music = store.music
                let fraction = MusicMiniPlayerLayout.progress(position: music.seekingTo ?? music.position, duration: music.duration)
                let dark = scheme == .dark
                Rectangle()
                    .fill(LinearGradient(colors: dark
                        ? [Color.cyan.opacity(0.13), Color.white.opacity(0.16)]
                        : [Color.blue.opacity(0.10), Color.cyan.opacity(0.20)],
                        startPoint: .topLeading, endPoint: .bottomTrailing))
                    .overlay(alignment: .trailing) {
                        if fraction > 0 && fraction < 1 {
                            Rectangle().fill(Color.white.opacity(dark ? 0.24 : 0.48)).frame(width: 1)
                        }
                    }
                    .frame(width: geometry.size.width * fraction)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
                    // Seeks and item replacement create a new clock identity, so
                    // they reset immediately instead of sweeping across the song.
                    .animation(reduceMotion || !music.isPlaying ? nil : .linear(duration: 0.22), value: fraction)
                    .id(music.timelineRevision)
            }
        }
        .environment(\.layoutDirection, .leftToRight)
        .clipShape(Capsule())
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

private struct MusicPlayPauseTransition: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ViewBuilder func body(content: Content) -> some View {
        if reduceMotion {
            content
        } else if #available(iOS 17.0, *) {
            content.contentTransition(.symbolEffect(.replace))
        } else {
            content.contentTransition(.opacity)
        }
    }
}

/// The tab bar's accessory slot (iOS 26.1): the system floats the mini player above the bar and
/// tucks it in beside the bar when scrolling minimizes it, with its own animation. Before 26.1
/// there is no way to hide the slot, so pages show the strip themselves (`musicPlayerInset`).
extension View {
    @ViewBuilder func musicAccessory(enabled: Bool) -> some View {
        #if TVBOX_SDK26_1 && compiler(>=6.2)
        if #available(iOS 26.1, *) {
            tabViewBottomAccessory(isEnabled: enabled) { WithPerceptionTracking { MusicAccessoryContent() } }
        } else {
            self
        }
        #else
        self
        #endif
    }
}

enum MusicAccessory {
    /// The system's accessory holds the mini player: iOS 26.1 on a phone.
    static func used(compact: Bool) -> Bool {
        #if TVBOX_SDK26_1 && compiler(>=6.2)
        if #available(iOS 26.1, *) { return compact }
        #endif
        return false
    }
}

#if TVBOX_SDK26_1 && compiler(>=6.2)
@available(iOS 26.1, *)
private struct MusicAccessoryContent: View {
    @Environment(\.tabViewBottomAccessoryPlacement) private var placement
    var body: some View { WithPerceptionTracking { MusicMiniPlayer(inline: placement == .inline) } }
}
#endif
#endif
