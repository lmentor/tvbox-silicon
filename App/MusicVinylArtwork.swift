import Foundation

/// Integrate elapsed playing time, rather than restarting an animation when playback pauses.
struct MusicVinylPhase {
    private var elapsed: TimeInterval = 0
    private var started: TimeInterval?
    mutating func setRunning(_ running: Bool, at time: TimeInterval) {
        if running, started == nil { started = time }
        else if !running, let started { elapsed += max(0, time - started); self.started = nil }
    }
    mutating func reset(running: Bool, at time: TimeInterval) { elapsed = 0; started = running ? time : nil }
    func degrees(at time: TimeInterval) -> Double {
        (elapsed + (started.map { max(0, time - $0) } ?? 0)).truncatingRemainder(dividingBy: 24) * 15
    }
}

enum MusicNowPlayingDismissal {
    static func shouldDismiss(x: Double, y: Double, predictedY: Double) -> Bool {
        y > 28 && y > abs(x) * 1.3 && (y > 84 || predictedY > 180)
    }
}

#if os(iOS)
import QuartzCore
import SwiftUI
import Perception

/// The compositor advances a persistent layer; no frame clock publishes SwiftUI
/// state or reconstructs the record / poster while the finger is moving.
@MainActor
final class MusicVinylRotation {
    private weak var layer: CALayer?
    private var phase = MusicVinylPhase()
    private var trackID: String?
    private var running = false

    init(layer: CALayer) { self.layer = layer }

    func update(trackID: String, running: Bool, at time: TimeInterval) {
        guard self.trackID != trackID || self.running != running, let layer else { return }
        if self.trackID != trackID { phase.reset(running: running, at: time) }
        else { phase.setRunning(running, at: time) }
        self.trackID = trackID
        self.running = running
        let radians = phase.degrees(at: time) * .pi / 180
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.removeAnimation(forKey: "music.vinyl.rotation")
        layer.transform = CATransform3DMakeRotation(CGFloat(radians), 0, 0, 1)
        if running {
            let animation = CABasicAnimation(keyPath: "transform.rotation.z")
            animation.fromValue = radians
            animation.toValue = radians + .pi * 2
            animation.duration = 24
            animation.repeatCount = .infinity
            animation.timingFunction = CAMediaTimingFunction(name: .linear)
            layer.add(animation, forKey: "music.vinyl.rotation")
        }
        CATransaction.commit()
    }
}

struct MusicVinylArtwork: View {
    let url: URL?
    let size: CGFloat
    var body: some View {
        WithPerceptionTracking {
            record.frame(width: size, height: size)
        }
        .ignoresSafeArea().environment(\.colorScheme, .dark)
        .accessibilityHidden(true)
    }
    private var record: some View {
        ZStack {
            Circle().fill(Color(red: 0.07, green: 0.075, blue: 0.075))
            ForEach(0..<7) { ring in
                Circle().strokeBorder(.white.opacity(ring.isMultiple(of: 2) ? 0.055 : 0.025), lineWidth: 1)
                    .padding(CGFloat(ring) * 3 + 6)
            }
            AngularGradient(colors: [.clear, .white.opacity(0.08), .clear, .black.opacity(0.2), .clear], center: .center)
                .clipShape(Circle())
            PosterImage(url: url, symbol: "music.note")
                .frame(width: size * 0.68, height: size * 0.68).clipShape(Circle())
            Circle().fill(Color(red: 0.09, green: 0.09, blue: 0.075))
                .frame(width: 11, height: 11)
                .overlay { Circle().strokeBorder(Color(red: 0.8, green: 0.7, blue: 0.54), lineWidth: 2) }
        }
        .overlay { Circle().strokeBorder(Color(red: 0.25, green: 0.22, blue: 0.18), lineWidth: 1.5) }
        .overlay { Circle().strokeBorder(.black.opacity(0.5), lineWidth: 3).padding(-3) }
    }
}
#endif
