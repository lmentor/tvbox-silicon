import Perception
#if os(iOS)
import MediaPlayer
import TVCore
import UIKit

extension Store {
    /// The one store, which the Lock Screen controls reach outside any view.
    static let shared = Store()
}

/// The song playing, and its controls, on the Lock Screen, in Control Center, on headphones and
/// in the car's own Now Playing screen. Music holds the system's Now Playing
/// while it has a song and no video plays; the video player uses it otherwise.
@MainActor final class MusicRemoteControl {
    static let shared = MusicRemoteControl(store: .shared)

    private let store: Store
    private var active = false
    private var targets: [(MPRemoteCommand, Any)] = []
    private var commandRevision = UUID()
    private var artworkURL: URL?
    private var artwork: MPMediaItemArtwork?
    private var artworkTask: Task<Void, Never>?

    private init(store: Store) {
        self.store = store
        update()
        observe()
    }

    /// What the Now Playing info depends on. The position is read when it is written, not
    /// watched: the system runs the clock on from the elapsed time and the rate.
    private struct State: Equatable {
        var track: String?
        var phase: MusicPlaybackSession.Phase
        var duration: Double?
        var index: Int?
        var count: Int
        var canAdvance: Bool
        var seeking: Double?
        var timeline: UUID
        var activePlayback: Bool
        var video: Bool
    }

    private var state: State {
        let music = store.music
        return State(track: music.track?.id, phase: music.phase, duration: music.duration, index: music.queue?.index,
                     count: music.queue?.tracks.count ?? 0, canAdvance: music.canAdvance,
                     seeking: music.seekingTo, timeline: music.timelineRevision,
                     activePlayback: music.keepsNowPlayingActive, video: store.playing != nil)
    }

    private func observe() {
        withPerceptionTracking { _ = state } onChange: { [weak self] in
            Task { @MainActor [weak self] in self?.update(); self?.observe() }
        }
    }

    private func update() {
        let music = store.music, center = MPNowPlayingInfoCenter.default()
        guard let track = music.track, store.playing == nil else {
            if active {
                active = false
                commandRevision = UUID()
                for (command, target) in targets { command.removeTarget(target) }
                targets = []
                center.nowPlayingInfo = nil
                center.playbackState = .stopped
            }
            return
        }
        if !active { active = true; addTargets() }
        let commands = MPRemoteCommandCenter.shared()
        commands.nextTrackCommand.isEnabled = music.canAdvance
        commands.previousTrackCommand.isEnabled = true
        commands.changePlaybackPositionCommand.isEnabled = music.canSeek

        var info: [String: Any] = [
            MPMediaItemPropertyTitle: track.title,
            MPMediaItemPropertyArtist: track.artistLine,
            MPNowPlayingInfoPropertyMediaType: MPNowPlayingInfoMediaType.audio.rawValue,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: music.seekingTo ?? music.position,
            MPNowPlayingInfoPropertyPlaybackRate: music.phase == .playing && music.seekingTo == nil ? 1.0 : 0.0,
            MPNowPlayingInfoPropertyDefaultPlaybackRate: 1.0,
        ]
        if let album = track.album ?? music.queue?.source { info[MPMediaItemPropertyAlbumTitle] = album }
        if let duration = music.duration { info[MPMediaItemPropertyPlaybackDuration] = duration }
        if let queue = music.queue, queue.tracks.count > 1 {
            info[MPNowPlayingInfoPropertyPlaybackQueueIndex] = queue.index
            info[MPNowPlayingInfoPropertyPlaybackQueueCount] = queue.tracks.count
        }
        if track.artwork != artworkURL { loadArtwork(track.artwork) }
        if let artwork { info[MPMediaItemPropertyArtwork] = artwork }
        center.nowPlayingInfo = info
        // Resolving a new source is still an active playback request. Publishing
        // it as paused lets the system relinquish ownership during a background gap.
        center.playbackState = music.phase == .idle ? .stopped : music.keepsNowPlayingActive ? .playing : .paused
    }

    private func loadArtwork(_ url: URL?) {
        artworkURL = url; artwork = nil
        artworkTask?.cancel()
        guard let url else { return }
        artworkTask = Task { [weak self] in
            guard let bitmap = await PosterPalette.image(url), !Task.isCancelled, let self, self.artworkURL == url else { return }
            self.artwork = Self.artwork(UIImage(cgImage: bitmap))
            self.update()
        }
    }

    /// MediaPlayer asks for the image on its own queue: a closure made on the main actor would
    /// trap there, checking it runs on the main thread.
    private nonisolated static func artwork(_ image: UIImage) -> MPMediaItemArtwork {
        MPMediaItemArtwork(boundsSize: image.size) { _ in image }
    }

    private func addTargets() {
        let commands = MPRemoteCommandCenter.shared()
        func on(_ command: MPRemoteCommand, _ action: Action) {
            command.isEnabled = true
            let target = command.addTarget(handler: Self.handler(action, owner: self, run: commandRevision))
            targets.append((command, target))
        }
        on(commands.playCommand, .play)
        on(commands.pauseCommand, .pause)
        on(commands.togglePlayPauseCommand, .toggle)
        on(commands.nextTrackCommand, .next)
        on(commands.previousTrackCommand, .previous)
        on(commands.changePlaybackPositionCommand, .position)
    }

    private enum Action: Sendable { case play, pause, toggle, next, previous, position }

    /// MediaPlayer can invoke a command on its own queue. Copy only the command's
    /// value across actors; neither the framework event nor the session leaves its owner.
    private nonisolated static func handler(_ action: Action, owner: MusicRemoteControl, run: UUID) -> (MPRemoteCommandEvent) -> MPRemoteCommandHandlerStatus {
        { [weak owner] event in
            let position = (event as? MPChangePlaybackPositionCommandEvent)?.positionTime
            if action == .position, position?.isFinite != true { return .commandFailed }
            Task { @MainActor [weak owner] in
                guard let owner, owner.commandRevision == run else { return }
                owner.perform(action, position: position)
            }
            return .success
        }
    }

    private func perform(_ action: Action, position: Double?) {
        guard active, store.playing == nil, store.music.track != nil else { return }
        let music = store.music
        switch action {
        case .play:
            if music.phase != .playing && music.phase != .loading { music.toggle() }
        case .pause: music.pause()
        case .toggle: music.toggle()
        case .next: if music.canAdvance { music.next() }
        case .previous: music.previous()
        case .position: if music.canSeek, let position { music.seek(to: position) }
        }
        // Do not depend on a later Perception turn before returning ownership to
        // Control Center, especially while a new source is still resolving.
        update()
    }
}
#endif
