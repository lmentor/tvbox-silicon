import Foundation
import Perception
import TVCore

/// Adapted from the upstream sleep timer to the local iOS 16.2 playback stack.
/// Both session owners observe it, including while their views are dismissed.
@MainActor @Perceptible final class SleepTimer {
    static let shared = SleepTimer()
    static let durations = [15, 30, 45, 60, 90]
    static let fadeLength: Double = 6
    static let fired = Notification.Name("SleepTimerFired")
    static let changed = Notification.Name("SleepTimerChanged")
    private(set) var schedule = PlaybackSleepSchedule()
    @PerceptionIgnored private var task: Task<Void, Never>?
    var isOn: Bool { schedule.isOn }
    var endsWithItem: Bool { schedule.endsWithItem }
    var minutes: Int? { schedule.minutes }
    var revision: UUID { schedule.revision }

    func start(minutes: Int) {
        guard schedule.start(minutes: minutes) else { return }
        reschedule()
    }

    func stopAtEndOfItem() { schedule.stopAtEndOfItem(); reschedule() }
    func cancel() { schedule.cancel(); reschedule() }

    @discardableResult func itemEnded() -> Bool {
        guard schedule.itemEnded() else { return false }
        fire()
        return true
    }

    private func reschedule() {
        task?.cancel(); task = nil
        NotificationCenter.default.post(name: Self.changed, object: self)
        guard case .deadline = schedule.mode else { return }
        let run = revision
        task = Task { @MainActor [weak self] in
            while let self, self.revision == run, !Task.isCancelled {
                if self.schedule.expire() { self.fire(); return }
                let seconds = max(0.05, min(30, Double(self.schedule.remaining() ?? 0)))
                do { try await Task.sleep(for: .seconds(seconds)) } catch { return }
            }
        }
    }

    private func fire() {
        task?.cancel(); task = nil
        Diagnostics.shared.record(.info, "sleep", "timer fired")
        // The player first holds its queue. Publishing Off must not allow a
        // queued item to advance at the same instant as an end-of-item expiry.
        NotificationCenter.default.post(name: Self.fired, object: self)
        NotificationCenter.default.post(name: Self.changed, object: self)
    }

    func remaining(at now: Date = Date()) -> String? {
        guard let seconds = schedule.remaining(at: now) else { return nil }
        let hours = seconds / 3600, minutes = seconds / 60 % 60, remainder = seconds % 60
        return hours > 0 ? String(format: "%d:%02d:%02d", hours, minutes, remainder)
            : String(format: "%d:%02d", minutes, remainder)
    }

    func status(item: SleepTimerItem) -> String {
        switch schedule.mode {
        case .off: "未开启"
        case .endOfItem: item.title
        case .deadline(let date): "将在 \(date.formatted(date: .omitted, time: .shortened)) 停止播放"
        }
    }
}

enum SleepTimerItem {
    case song, episode
    var title: String { self == .song ? "播完当前歌曲" : "播完当前剧集" }
}
