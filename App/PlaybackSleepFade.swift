import Foundation

/// Each player owns its fade. A later transport action cancels the pause;
/// restoration only touches the same media instance that supplied the volume.
@MainActor final class PlaybackSleepFade {
    private let duration: TimeInterval
    private let steps: Int
    private var task: Task<Void, Never>?
    private var restore: (() -> Void)?
    private var generation = UUID()
    var isActive: Bool { task != nil }

    init(duration: TimeInterval = 6, steps: Int = 30) {
        self.duration = max(0, duration)
        self.steps = max(1, steps)
    }

    func start(volume: Float, isCurrent: @escaping @MainActor () -> Bool,
               shouldContinue: @escaping @MainActor () -> Bool = { true },
               setVolume: @escaping @MainActor (Float) -> Void,
               pause: @escaping @MainActor () -> Void) {
        cancel()
        let run = generation, steps = steps
        let delay = UInt64(duration / Double(steps) * 1_000_000_000)
        restore = { if isCurrent() { setVolume(volume) } }
        task = Task { @MainActor [weak self] in
            for step in 1...steps {
                do { try await Task.sleep(nanoseconds: delay) } catch { return }
                guard let self, self.generation == run else { return }
                guard isCurrent(), shouldContinue() else { self.cancel(); return }
                setVolume(volume * Float(steps - step) / Float(steps))
            }
            guard let self, self.generation == run else { return }
            let restoration = self.restore
            self.restore = nil; self.task = nil
            pause()
            restoration?()
        }
    }

    func cancel() {
        generation = UUID()
        task?.cancel(); task = nil
        let restoration = restore
        restore = nil
        restoration?()
    }
}
