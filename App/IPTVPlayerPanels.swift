#if os(iOS)
import SwiftUI
import UIKit
import TVCore

struct IPTVStationsPanel: View {
    let stations: [IPTVStation]
    let currentID: String
    let favorite: Bool
    let loading: Bool
    let toggleFavorite: () -> Void
    let select: (IPTVStation) -> Void

    var body: some View {
        IPTVPanelScrollView(target: IPTVPanelPosition.stationID(in: stations, currentID: currentID)) {
            VStack(alignment: .leading, spacing: 12) {
                Button(action: toggleFavorite) {
                    Label(favorite ? "取消收藏" : "收藏频道", systemImage: favorite ? "heart.fill" : "heart")
                        .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                }.buttonStyle(.plain)
                LazyVStack(alignment: .leading, spacing: 4) {
                    ForEach(stations) { station in
                        let selected = station.id == currentID
                        Button { select(station) } label: {
                            HStack { Text(station.name); Spacer(); if selected { Image(systemName: "checkmark") } }
                                .font(.system(size: 14)).padding(.horizontal, 10)
                                .frame(maxWidth: .infinity, minHeight: 44).contentShape(Rectangle())
                        }
                        .buttonStyle(CompactPlayerControlStyle(selected: selected, inset: false))
                        .accessibilityAddTraits(selected ? .isSelected : [])
                        .disabled(loading)
                        .id(station.id)
                    }
                }
            }
        }.id(currentID)
    }
}

/// Own the vertical viewport so the reader can reach offscreen lazy station rows.
/// Its native observer only requests an initial reveal; normal scrolling stays native.
struct IPTVPanelScrollView<Target: Hashable, Content: View>: View {
    let target: Target?
    @ViewBuilder let content: () -> Content

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                content()
                    .padding(14)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background {
                        IPTVPanelInitialReveal(target: target) { target in
                            proxy.scrollTo(target, anchor: .center)
                        }
                    }
            }
            .scrollDismissesKeyboard(.interactively)
        }
    }
}

/// Observe the existing pan recognizer rather than introducing another drag
/// gesture over station buttons or the guide's date picker on iOS 16.
private struct IPTVPanelInitialReveal<Target: Hashable>: UIViewRepresentable {
    let target: Target?
    let reveal: (Target) -> Void

    func makeUIView(context: Context) -> ObserverView { ObserverView() }
    func updateUIView(_ view: ObserverView, context: Context) {
        view.target = target
        view.reveal = reveal
        view.attach()
    }
    static func dismantleUIView(_ view: ObserverView, coordinator: ()) { view.detach() }

    final class ObserverView: UIView {
        var target: Target?
        var reveal: ((Target) -> Void)?
        private var position = IPTVPanelPosition()
        private weak var scrollView: UIScrollView?
        private var observations: [NSKeyValueObservation] = []
        private var scheduled = false

        override init(frame: CGRect) {
            super.init(frame: frame)
            backgroundColor = .clear
            isUserInteractionEnabled = false
        }
        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

        override func didMoveToSuperview() { super.didMoveToSuperview(); attach() }
        override func didMoveToWindow() { super.didMoveToWindow(); attach() }
        override func layoutSubviews() { super.layoutSubviews(); attach() }

        func attach() {
            guard position.isPending else { return }
            var ancestor = superview
            while let view = ancestor, !(view is UIScrollView) { ancestor = view.superview }
            let enclosing = ancestor as? UIScrollView
            if enclosing !== scrollView {
                detach()
                scrollView = enclosing
                if let enclosing {
                    enclosing.panGestureRecognizer.addTarget(self, action: #selector(panned(_:)))
                    observations = [
                        enclosing.observe(\.contentSize, options: [.new]) { [weak self] _, _ in
                            MainActor.assumeIsolated { self?.scheduleReveal() }
                        },
                        enclosing.observe(\.bounds, options: [.new]) { [weak self] _, _ in
                            MainActor.assumeIsolated { self?.scheduleReveal() }
                        }
                    ]
                }
            }
            scheduleReveal()
        }

        func detach() {
            scrollView?.panGestureRecognizer.removeTarget(self, action: #selector(panned(_:)))
            observations.removeAll()
            scrollView = nil
        }

        @objc private func panned(_ recognizer: UIPanGestureRecognizer) {
            if recognizer.state == .began || recognizer.state == .changed {
                position.cancel()
                detach()
            }
        }

        private func scheduleReveal() {
            guard position.isPending, !scheduled else { return }
            scheduled = true
            // The target's IDs and the native viewport must finish the same layout
            // before ScrollViewReader can locate an asynchronously inserted row.
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.scheduled = false
                self.revealIfReady()
            }
        }

        private func revealIfReady() {
            guard position.isPending, let scrollView, scrollView.window != nil else { return }
            // Tracking starts before a pan begins. Never move a list under a finger
            // while an EPG response or a late layout callback is being delivered.
            if scrollView.isTracking || scrollView.isDragging || scrollView.isDecelerating {
                position.cancel()
                detach()
                return
            }
            scrollView.layoutIfNeeded()
            guard scrollView.bounds.height > 0, scrollView.contentSize.height > 0,
                  let target = position.take(target) else { return }
            reveal?(target)
            detach()
        }
    }
}
#endif
