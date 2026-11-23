#if os(iOS)
import SwiftUI
import UIKit

/// UIKit converts the keyboard's screen rectangle into the popup viewport.
/// SwiftUI global coordinates can differ while the presentation is rotated.
struct PlayerPopupKeyboard: UIViewRepresentable {
    let changed: (CGFloat) -> Void

    func makeUIView(context: Context) -> ObserverView {
        let view = ObserverView()
        view.changed = changed
        return view
    }
    func updateUIView(_ view: ObserverView, context: Context) { view.changed = changed }
    static func dismantleUIView(_ view: ObserverView, coordinator: ()) { view.changed = nil }

    final class ObserverView: UIView {
        var changed: ((CGFloat) -> Void)?
        private var keyboardFrame: CGRect?
        private var overlap: CGFloat = 0

        override init(frame: CGRect) {
            super.init(frame: frame)
            isUserInteractionEnabled = false
            NotificationCenter.default.addObserver(self, selector: #selector(keyboardChanged(_:)),
                name: UIResponder.keyboardWillChangeFrameNotification, object: nil)
            NotificationCenter.default.addObserver(self, selector: #selector(keyboardHidden(_:)),
                name: UIResponder.keyboardWillHideNotification, object: nil)
        }
        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
        deinit { NotificationCenter.default.removeObserver(self) }
        override func layoutSubviews() { super.layoutSubviews(); reportOverlap() }
        override func didMoveToWindow() { super.didMoveToWindow(); reportOverlap() }

        @objc private func keyboardChanged(_ notification: Notification) {
            keyboardFrame = notification.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? CGRect
            reportOverlap()
        }
        @objc private func keyboardHidden(_ notification: Notification) {
            keyboardFrame = nil
            reportOverlap()
        }
        private func reportOverlap() {
            let next: CGFloat
            if let window, let keyboardFrame {
                let localFrame = convert(keyboardFrame, from: window.screen.coordinateSpace)
                let intersection = bounds.intersection(localFrame)
                next = intersection.isNull || intersection.isEmpty ? 0 : max(0, bounds.maxY - intersection.minY)
            } else { next = 0 }
            guard abs(next - overlap) > 0.5 else { return }
            overlap = next
            // Geometry callbacks can run inside a SwiftUI layout pass.
            DispatchQueue.main.async { [weak self] in
                guard let self, self.overlap == next else { return }
                self.changed?(next)
            }
        }
    }
}
#endif
