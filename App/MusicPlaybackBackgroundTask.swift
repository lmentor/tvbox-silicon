import Foundation
#if os(iOS)
import UIKit
#endif

/// Audio normally keeps the app running. A source lookup between songs needs a
/// short lease of its own, released as soon as audio starts or the request stops.
@MainActor final class MusicPlaybackBackgroundTask {
    #if os(iOS)
    private var identifier = UIBackgroundTaskIdentifier.invalid
    private var revision = UUID()
    private var deadline: Task<Void, Never>?

    func begin() {
        // Recovery can replace the stream several times. It shares one bounded
        // lease instead of extending background execution with each retry.
        guard identifier == .invalid else { return }
        let run = UUID()
        revision = run
        identifier = UIApplication.shared.beginBackgroundTask(withName: "Music source transition") { [weak self] in
            Task { @MainActor [weak self] in
                guard let self, self.revision == run else { return }
                self.end()
            }
        }
        guard identifier != .invalid else { return }
        deadline = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(25)) } catch { return }
            guard let self, self.revision == run else { return }
            self.end()
        }
    }

    func end() {
        revision = UUID()
        deadline?.cancel(); deadline = nil
        guard identifier != .invalid else { return }
        let finished = identifier
        identifier = .invalid
        UIApplication.shared.endBackgroundTask(finished)
    }
    #else
    func begin() {}
    func end() {}
    #endif
}
