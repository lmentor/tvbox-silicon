import Foundation

/// Cancellation belongs to the whole finger sequence, not its final position.
/// The same rule applies to a poster tap and a dock tab outside a scroll view.
struct LocalTouchSequence {
    enum Action: Equatable { case none, tap, hold }
    var holdDuration: TimeInterval? = nil
    private enum State { case idle, touching(CGPoint, TimeInterval), held, cancelled }
    private var state = State.idle
    var isTracking: Bool { if case .touching = state { return true }; return false }

    init(holdDuration: TimeInterval? = nil) { self.holdDuration = holdDuration }

    mutating func begin(at point: CGPoint, time: TimeInterval, scrolling: Bool = false, touchCount: Int = 1) {
        state = scrolling || touchCount != 1 || !time.isFinite || !point.x.isFinite || !point.y.isFinite
            ? .cancelled : .touching(point, time)
    }

    mutating func move(to point: CGPoint, scrolling: Bool = false) {
        guard !scrolling, point.x.isFinite, point.y.isFinite else { cancel(); return }
        if case let .touching(origin, _) = state {
            let dx = point.x - origin.x, dy = point.y - origin.y
            if dx * dx + dy * dy > 100 { cancel() }
        }
    }

    mutating func hold(at point: CGPoint, time: TimeInterval, scrolling: Bool = false) -> Action {
        move(to: point, scrolling: scrolling)
        guard case let .touching(_, beganAt) = state, let holdDuration,
              time.isFinite, time - beganAt >= holdDuration else { return .none }
        state = .held
        return .hold
    }

    mutating func end(at point: CGPoint, time: TimeInterval, scrolling: Bool = false) -> Action {
        move(to: point, scrolling: scrolling)
        let action: Action
        if case let .touching(_, beganAt) = state, time.isFinite, time >= beganAt {
            action = holdDuration.map { time - beganAt >= $0 } == true ? .hold : .tap
        } else { action = .none }
        state = .idle
        return action
    }

    mutating func cancel() { state = .cancelled }
}

#if os(iOS)
import SwiftUI
import UIKit

/// A responder without its own gesture recognizer. Both ancestor UIScrollViews
/// receive the original touch and retain ownership of their native pan gestures.
struct LocalTouchSurface: UIViewRepresentable {
    let enabled: Bool
    var holdDuration: TimeInterval? = nil
    let tap: () -> Void
    var hold: (() -> Void)? = nil
    var pressing: ((Bool) -> Void)? = nil

    func makeUIView(context: Context) -> LocalTouchTargetView { LocalTouchTargetView() }
    func updateUIView(_ view: LocalTouchTargetView, context: Context) {
        view.tap = tap; view.hold = hold; view.pressing = pressing
        view.configure(enabled: enabled, holdDuration: holdDuration)
    }
    static func dismantleUIView(_ view: LocalTouchTargetView, coordinator: ()) { view.detach() }
}

class LocalTouchTargetView: UIView {
    var tap: (() -> Void)?
    var hold: (() -> Void)?
    var pressing: ((Bool) -> Void)?
    private(set) var acceptsTouches = false
    private var sequence = LocalTouchSequence()
    private var finger: UITouch?
    private var timer: Timer?
    private var pressed = false
    private struct ScrollAncestor { weak var view: UIScrollView? }
    private var scrolls: [ScrollAncestor] = []

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        isOpaque = false
        isMultipleTouchEnabled = true
        isAccessibilityElement = false
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func configure(enabled: Bool, holdDuration: TimeInterval? = nil) {
        if !enabled || sequence.holdDuration != holdDuration { cancelTouch() }
        acceptsTouches = enabled
        sequence.holdDuration = holdDuration
        // Disabled dock controls still consume the pixels they cover. The parent
        // owns whether the entire surface is available for hit testing.
        if enabled { reconcileScrolls() } else { removeScrollTargets() }
    }
    override func didMoveToSuperview() { super.didMoveToSuperview(); reconcileScrolls() }
    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window == nil { detach() } else { reconcileScrolls() }
    }
    override func layoutSubviews() { super.layoutSubviews(); reconcileScrolls() }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard acceptsTouches, window != nil, finger == nil, touches.count == 1,
              (event?.allTouches?.count ?? 1) == 1, let touch = touches.first,
              point(inside: touch.location(in: self), with: event) else { cancel(); return }
        finger = touch
        sequence.begin(at: touch.location(in: window), time: touch.timestamp, scrolling: scrolling)
        guard sequence.isTracking else { return }
        setPressed(true)
        if let duration = sequence.holdDuration {
            // UIScrollView may delay touchesBegan: use the original event time.
            let elapsed = ProcessInfo.processInfo.systemUptime - touch.timestamp
            let timer = Timer(timeInterval: max(0, duration - elapsed), target: self,
                              selector: #selector(held), userInfo: nil, repeats: false)
            self.timer = timer
            RunLoop.main.add(timer, forMode: .common)
        }
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let touch = finger, touches.contains(touch) else { return }
        recordMovement(touch, event: event)
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let touch = finger, touches.contains(touch) else { return }
        // A quick out-and-back motion can arrive only as coalesced final samples.
        recordMovement(touch, event: event)
        let action = sequence.end(at: touch.location(in: window), time: touch.timestamp, scrolling: scrolling)
        finger = nil; stopTimer(); setPressed(false)
        perform(action)
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) { cancelTouch() }

    private func recordMovement(_ touch: UITouch, event: UIEvent?) {
        guard acceptsTouches, (event?.allTouches?.count ?? 1) == 1 else { cancel(); return }
        for sample in (event?.coalescedTouches(for: touch) ?? []) + [touch] {
            guard point(inside: sample.location(in: self), with: event) else { cancel(); return }
            sequence.move(to: sample.location(in: window), scrolling: scrolling)
        }
        if !sequence.isTracking { stopTimer(); setPressed(false) }
    }

    @objc private func held() {
        timer = nil
        guard acceptsTouches, let touch = finger else { return }
        guard point(inside: touch.location(in: self), with: nil) else { cancel(); return }
        let action = sequence.hold(at: touch.location(in: window), time: ProcessInfo.processInfo.systemUptime, scrolling: scrolling)
        if !sequence.isTracking { setPressed(false) }
        perform(action)
    }

    private func perform(_ action: LocalTouchSequence.Action) {
        guard acceptsTouches else { return }
        switch action { case .tap: tap?(); case .hold: hold?(); case .none: break }
    }
    private func stopTimer() { timer?.invalidate(); timer = nil }
    private func cancel() { sequence.cancel(); stopTimer(); setPressed(false) }
    func cancelTouch() { cancel(); finger = nil }
    private func setPressed(_ value: Bool) {
        guard pressed != value else { return }
        pressed = value
        // configure/detach can run during SwiftUI layout. Avoid publishing an old
        // pressed value after a newer touch has changed it.
        DispatchQueue.main.async { [weak self] in
            guard let self, self.pressed == value else { return }
            self.pressing?(value)
        }
    }
    private var scrolling: Bool {
        scrolls.contains {
            guard let scroll = $0.view else { return false }
            return scroll.isDragging || scroll.isDecelerating || scroll.panGestureRecognizer.state == .began
                || scroll.panGestureRecognizer.state == .changed
        }
    }
    @objc private func panned(_ recognizer: UIPanGestureRecognizer) {
        if recognizer.state == .began || recognizer.state == .changed { cancel() }
    }
    private func reconcileScrolls() {
        guard acceptsTouches else { return }
        var ancestors: [UIScrollView] = []
        var next = superview
        while let view = next {
            if let scroll = view as? UIScrollView { ancestors.append(scroll) }
            next = view.superview
        }
        guard ancestors.count != scrolls.count || zip(ancestors, scrolls).contains(where: { $0.0 !== $0.1.view }) else { return }
        cancelTouch()
        removeScrollTargets()
        scrolls = ancestors.map { ScrollAncestor(view: $0) }
        for scroll in ancestors { scroll.panGestureRecognizer.addTarget(self, action: #selector(panned(_:))) }
    }
    private func removeScrollTargets() {
        for scroll in scrolls { scroll.view?.panGestureRecognizer.removeTarget(self, action: #selector(panned(_:))) }
        scrolls.removeAll()
    }
    func detach() { cancelTouch(); removeScrollTargets() }
}
#endif
