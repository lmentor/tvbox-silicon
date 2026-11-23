#if os(iOS)
import SwiftUI
import UIKit

/// Only this leaf owns the handle / record pan. Finger samples transform native
/// content in window coordinates without invalidating lyrics or playback controls.
struct MusicNowPlayingArtwork: UIViewControllerRepresentable {
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let url: URL?
    let trackID: String
    let size: CGFloat
    let short: Bool
    let playing: Bool
    let dismiss: () -> Void

    func makeUIViewController(context: Context) -> MusicNowPlayingArtworkController {
        MusicNowPlayingArtworkController()
    }
    func updateUIViewController(_ controller: MusicNowPlayingArtworkController, context: Context) {
        controller.configure(url: url, size: size, short: short, trackID: trackID, playing: playing,
                             active: scenePhase == .active, reduceMotion: reduceMotion, dismiss: dismiss)
    }
    static func dismantleUIViewController(_ controller: MusicNowPlayingArtworkController, coordinator: ()) {
        controller.artworkView.detach()
    }
}

final class MusicNowPlayingArtworkController: UIViewController {
    let artworkView = MusicNowPlayingArtworkView(frame: .zero)
    private let host = UIHostingController(rootView: MusicVinylArtwork(url: nil, size: 184))
    private var artworkURL: URL?
    private var artworkSize: CGFloat = 0

    override func loadView() { view = artworkView }
    override func viewDidLoad() {
        super.viewDidLoad()
        addChild(host)
        host.view.backgroundColor = .clear
        host.view.isOpaque = false
        host.view.isUserInteractionEnabled = false
        host.view.accessibilityElementsHidden = true
        host.view.frame = artworkView.record.bounds
        host.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        artworkView.record.addSubview(host.view)
        host.didMove(toParent: self)
    }
    override func viewDidAppear(_ animated: Bool) { super.viewDidAppear(animated); artworkView.setVisible(true) }
    override func viewWillDisappear(_ animated: Bool) { artworkView.setVisible(false); super.viewWillDisappear(animated) }

    func configure(url: URL?, size: CGFloat, short: Bool, trackID: String, playing: Bool,
                   active: Bool, reduceMotion: Bool, dismiss: @escaping () -> Void) {
        loadViewIfNeeded()
        // Playback / interaction updates keep the hosted poster and its loading
        // task alive. Only a changed artwork or layout replaces the static root.
        if artworkURL != url || artworkSize != size {
            artworkURL = url; artworkSize = size
            host.rootView = MusicVinylArtwork(url: url, size: size)
        }
        artworkView.onDismiss = dismiss
        artworkView.configure(size: size, short: short, trackID: trackID, playing: playing,
                              active: active, reduceMotion: reduceMotion)
    }
}

final class MusicNowPlayingArtworkView: UIView {
    let content = UIView()
    let record = UIView()
    private let artwork = UIView()
    private let dismissButton = UIButton(type: .custom)
    private lazy var pan = UIPanGestureRecognizer(target: self, action: #selector(panned(_:)))
    private lazy var rotation = MusicVinylRotation(layer: record.layer)
    var onDismiss: (() -> Void)?
    private var size: CGFloat = 184
    private var short = false
    private var trackID = ""
    private var playing = false
    private var active = false
    private var reduceMotion = false
    private var visible = false
    private var dragging = false
    private var dismissed = false
    private var lastBounds = CGRect.zero

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        isOpaque = false
        addSubview(content)
        content.addSubview(artwork)
        artwork.addSubview(record)
        content.addSubview(dismissButton)
        artwork.layer.shadowColor = UIColor.black.cgColor
        artwork.layer.shadowOpacity = 0.4
        artwork.layer.shadowRadius = 16
        artwork.layer.shadowOffset = CGSize(width: 0, height: 10)
        dismissButton.setImage(UIImage(systemName: "chevron.down", withConfiguration:
            UIImage.SymbolConfiguration(pointSize: 17, weight: .semibold)), for: .normal)
        dismissButton.tintColor = UIColor.white.withAlphaComponent(0.7)
        dismissButton.addTarget(self, action: #selector(tapped), for: .touchUpInside)
        dismissButton.accessibilityLabel = "收起音乐播放器"
        dismissButton.accessibilityIdentifier = "music.nowPlaying.dismiss"
        record.isAccessibilityElement = true
        record.accessibilityLabel = "黑胶唱片封面"
        accessibilityElements = [dismissButton, record]
        pan.maximumNumberOfTouches = 1
        pan.cancelsTouchesInView = true
        addGestureRecognizer(pan)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func configure(size: CGFloat, short: Bool, trackID: String, playing: Bool, active: Bool, reduceMotion: Bool) {
        if self.size != size || self.short != short || !active { cancelInteraction() }
        self.size = size; self.short = short; self.trackID = trackID
        self.playing = playing; self.active = active; self.reduceMotion = reduceMotion
        record.accessibilityValue = playing ? "正在播放" : "已暂停"
        dismissButton.isEnabled = visible && active && !dismissed && !dragging
        updateRotation()
        setNeedsLayout()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        if lastBounds != bounds { cancelInteraction(); lastBounds = bounds }
        // Bounds / center remain defined even while content and record have
        // transforms. Assigning a transformed view's frame is undefined in UIKit.
        content.bounds = CGRect(origin: .zero, size: bounds.size)
        content.center = CGPoint(x: bounds.midX, y: bounds.midY)
        dismissButton.frame = CGRect(x: (bounds.width - 56) / 2, y: 0, width: 56, height: 44)
        artwork.frame = CGRect(x: (bounds.width - size) / 2, y: short ? 46 : 51, width: size, height: size)
        artwork.layer.shadowPath = CGPath(ellipseIn: artwork.bounds, transform: nil)
        record.bounds = CGRect(origin: .zero, size: artwork.bounds.size)
        record.center = CGPoint(x: artwork.bounds.midX, y: artwork.bounds.midY)
    }
    override func didMoveToWindow() { super.didMoveToWindow(); setVisible(window != nil) }

    func setVisible(_ value: Bool) {
        guard visible != value else { return }
        visible = value
        if value { dismissed = false }
        else { cancelInteraction() }
        dismissButton.isEnabled = visible && active && !dismissed
        updateRotation()
    }
    private func updateRotation() {
        rotation.update(trackID: trackID, running: visible && active && playing && !reduceMotion,
                        at: ProcessInfo.processInfo.systemUptime)
    }

    @objc private func panned(_ recognizer: UIPanGestureRecognizer) {
        guard visible, active, !dismissed, let window else { cancelInteraction(); return }
        switch recognizer.state {
        case .began:
            content.layer.removeAllAnimations()
            dragging = true
            dismissButton.cancelTracking(with: nil)
            dismissButton.isEnabled = false
            move(recognizer.translation(in: window))
        case .changed:
            guard dragging else { return }
            move(recognizer.translation(in: window))
        case .ended:
            guard dragging else { return }
            let translation = recognizer.translation(in: window)
            let velocity = recognizer.velocity(in: window)
            let predictedY = translation.y + max(0, velocity.y) * 0.2
            let shouldDismiss = MusicNowPlayingDismissal.shouldDismiss(x: Double(translation.x), y: Double(translation.y),
                                                                       predictedY: Double(predictedY))
            finishInteraction(animated: !shouldDismiss)
            if shouldDismiss { requestDismiss() }
        case .cancelled, .failed:
            finishInteraction(animated: true)
        default: break
        }
    }
    private func move(_ translation: CGPoint) {
        let follows = translation.y > abs(translation.x) * 1.3
        content.transform = CGAffineTransform(translationX: 0, y: follows ? max(0, translation.y) * 0.2 : 0)
    }
    private func finishInteraction(animated: Bool) {
        dragging = false
        dismissButton.isEnabled = visible && active && !dismissed
        if animated && !reduceMotion {
            UIView.animate(withDuration: 0.18, delay: 0, options: [.beginFromCurrentState, .allowUserInteraction, .curveEaseOut]) {
                self.content.transform = .identity
            }
        } else { content.transform = .identity }
    }
    private func cancelInteraction() {
        dragging = false
        dismissButton.cancelTracking(with: nil)
        content.layer.removeAllAnimations()
        content.transform = .identity
        dismissButton.isEnabled = visible && active && !dismissed
    }
    @objc private func tapped() { requestDismiss() }
    private func requestDismiss() {
        guard visible, active, !dragging, !dismissed else { return }
        dismissed = true
        dismissButton.isEnabled = false
        onDismiss?()
    }
    func detach() {
        setVisible(false)
        cancelInteraction()
        pan.isEnabled = false
        onDismiss = nil
    }
}
#endif
