import SwiftUI

private struct SearchPosterThumbnailsKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    var usesSearchPosterThumbnails: Bool {
        get { self[SearchPosterThumbnailsKey.self] }
        set { self[SearchPosterThumbnailsKey.self] = newValue }
    }
}

extension View {
    @ViewBuilder func searchPosterThumbnails() -> some View {
        #if os(iOS)
        environment(\.usesSearchPosterThumbnails, true)
        #else
        self
        #endif
    }
}

/// All rectangles use window coordinates, including nested horizontal scroll clips.
enum SearchPosterViewport {
    static func isVisible(_ frame: CGRect, clippedTo clips: [CGRect]) -> Bool {
        guard !frame.isEmpty, !frame.isNull, !frame.isInfinite else { return false }
        var visible = frame
        for clip in clips {
            visible = visible.intersection(clip)
            if visible.isNull || visible.isEmpty { return false }
        }
        return true
    }
}

#if os(iOS)
import UIKit

/// SwiftUI may retain a lazy cell after it leaves the scroll viewport. Observe
/// UIKit geometry without feeding frame preferences through the result tree.
/// Only a visibility transition updates that poster's state; visible cards can
/// continue loading during both a finger drag and inertial scrolling.
struct SearchPosterViewportObserver: UIViewRepresentable {
    let enabled: Bool
    let visibility: (Bool) -> Void
    func makeUIView(context: Context) -> ObserverView { ObserverView() }
    func updateUIView(_ view: ObserverView, context: Context) {
        view.visibility = visibility
        view.configure(enabled: enabled)
    }
    static func dismantleUIView(_ view: ObserverView, coordinator: ()) { view.detach() }

    final class ObserverView: UIView {
        var visibility: ((Bool) -> Void)?
        private var enabled = false
        private var visible = false
        private var scrollIDs: [ObjectIdentifier] = []
        private var observations: [NSKeyValueObservation] = []
        private var pending: DispatchWorkItem?

        override init(frame: CGRect) {
            super.init(frame: frame)
            isUserInteractionEnabled = false
            backgroundColor = .clear
        }
        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

        func configure(enabled: Bool) {
            self.enabled = enabled
            if enabled { schedule() } else { detach() }
        }
        override func didMoveToSuperview() { super.didMoveToSuperview(); schedule() }
        override func didMoveToWindow() {
            super.didMoveToWindow()
            if window == nil { detach() } else { schedule() }
        }
        override func layoutSubviews() { super.layoutSubviews(); schedule() }

        private func schedule() {
            guard enabled, pending == nil else { return }
            let work = DispatchWorkItem { [weak self] in
                guard let self else { return }
                self.pending = nil
                self.refresh()
            }
            pending = work
            DispatchQueue.main.async(execute: work)
        }

        private func refresh() {
            guard enabled, let window else { detach(); return }
            var scrolls: [UIScrollView] = []
            var clips = [window.bounds]
            var hidden = isHidden || alpha <= 0.01
            var ancestor = superview
            while let view = ancestor {
                hidden = hidden || view.isHidden || view.alpha <= 0.01
                if let scroll = view as? UIScrollView { scrolls.append(scroll) }
                if view.clipsToBounds || view is UIScrollView {
                    clips.append(view.convert(view.bounds, to: window))
                }
                ancestor = view.superview
            }
            let ids = scrolls.map(ObjectIdentifier.init)
            if ids != scrollIDs {
                observations.removeAll(); scrollIDs = ids
                for scroll in scrolls {
                    observations.append(scroll.observe(\.contentOffset, options: [.new]) { [weak self] _, _ in
                        MainActor.assumeIsolated { self?.schedule() }
                    })
                    observations.append(scroll.observe(\.bounds, options: [.new]) { [weak self] _, _ in
                        MainActor.assumeIsolated { self?.schedule() }
                    })
                }
            }
            publish(!hidden && SearchPosterViewport.isVisible(convert(bounds, to: window), clippedTo: clips))
        }

        private func publish(_ value: Bool) {
            guard value != visible else { return }
            visible = value
            let callback = visibility
            DispatchQueue.main.async { [weak self] in
                guard let self, self.visible == value else { return }
                callback?(value)
            }
        }

        func detach() {
            pending?.cancel(); pending = nil
            observations.removeAll(); scrollIDs.removeAll()
            publish(false)
        }
    }
}
#endif
