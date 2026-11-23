#if os(iOS)
import AVFoundation
import Foundation

/// Direct KSMEPlayer users do not instantiate KSPlayerLayer, whose notification
/// observer would otherwise handle interruptions. Keep this observer alive for
/// the engine's lifetime, including input replacement during a phone call.
@MainActor final class PlayerAudioInterruption: NSObject {
    private let changed: (Bool, Bool) -> Void

    init(changed: @escaping (Bool, Bool) -> Void) {
        self.changed = changed
        super.init()
        NotificationCenter.default.addObserver(self, selector: #selector(received(_:)),
            name: AVAudioSession.interruptionNotification, object: nil)
    }

    deinit { NotificationCenter.default.removeObserver(self) }

    @objc nonisolated private func received(_ notification: Notification) {
        guard let value = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: value) else { return }
        let began = type == .began
        let options = (notification.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt) ?? 0
        let shouldResume = AVAudioSession.InterruptionOptions(rawValue: options).contains(.shouldResume)
        // System notifications may arrive off-main. Serialize transport changes
        // with readiness, seek completion and the user/PiP playback commands.
        if Thread.isMainThread {
            MainActor.assumeIsolated { changed(began, shouldResume) }
        } else {
            Task { @MainActor [weak self] in self?.changed(began, shouldResume) }
        }
    }
}
#endif
