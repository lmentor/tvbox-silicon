#if os(iOS)
import SwiftUI
import UIKit
import TVCore

struct LocalDockControl {
    let identifier: String
    let label: String
    let selected: Bool
    let action: () -> Void
}

/// The material and the touch owner use the same continuous rounded outline.
/// Inner spacing and padding belong to the closest control; outer clear space
/// and the gap between the two capsules belong to the underlying page.
enum LocalDockGroupGeometry {
    static func contains(_ point: CGPoint, size: CGSize) -> Bool {
        guard size.width > 0, size.height > 0 else { return false }
        return RoundedRectangle(cornerRadius: 29, style: .continuous)
            .path(in: CGRect(origin: .zero, size: size)).contains(point)
    }

    static func frames(size: CGSize, count: Int, spacing: CGFloat, horizontalPadding: CGFloat, rightToLeft: Bool) -> [CGRect] {
        guard count > 0, size.width > 0, size.height > 0 else { return [] }
        let padding = horizontalPadding
        let width = max(0, (size.width - 2 * padding - CGFloat(count - 1) * spacing) / CGFloat(count))
        return (0..<count).map { logical in
            let index = rightToLeft ? count - 1 - logical : logical
            let left = index == 0 ? 0 : padding + CGFloat(index) * (width + spacing) - spacing / 2
            let right = index == count - 1 ? size.width : padding + CGFloat(index + 1) * (width + spacing) - spacing / 2
            return CGRect(x: left, y: 0, width: max(0, right - left), height: size.height)
        }
    }
}

struct LocalDockGroupTouchSurface: UIViewRepresentable {
    @Environment(\.isEnabled) private var enabled
    @Environment(\.layoutDirection) private var direction
    let controls: [LocalDockControl]
    let spacing: CGFloat
    let horizontalPadding: CGFloat
    func makeUIView(context: Context) -> LocalDockGroupTouchView { LocalDockGroupTouchView() }
    func updateUIView(_ view: LocalDockGroupTouchView, context: Context) {
        view.configure(controls: controls, spacing: spacing, horizontalPadding: horizontalPadding, rightToLeft: direction == .rightToLeft, enabled: enabled)
    }
    static func dismantleUIView(_ view: LocalDockGroupTouchView, coordinator: ()) { view.detach() }
}

/// One UIKit responder owns the complete capsule. SwiftUI's painted labels have
/// no second set of Button gestures that can trigger a poster behind the dock.
final class LocalDockGroupTouchView: LocalTouchTargetView {
    private var controls: [LocalDockControl] = []
    private var spacing: CGFloat = 0
    private var horizontalPadding: CGFloat = LocalDockLayout.groupPadding
    private var rightToLeft = false
    private var pendingControl: Int?
    private var previousSize = CGSize.zero
    private var elements: [ControlAccessibilityElement] = []

    func configure(controls: [LocalDockControl], spacing: CGFloat, horizontalPadding: CGFloat = LocalDockLayout.groupPadding, rightToLeft: Bool, enabled: Bool) {
        if self.controls.map(\.identifier) != controls.map(\.identifier)
            || self.spacing != spacing || self.horizontalPadding != horizontalPadding || self.rightToLeft != rightToLeft { cancelTouch(); pendingControl = nil }
        self.horizontalPadding = horizontalPadding
        self.controls = controls; self.spacing = spacing; self.rightToLeft = rightToLeft
        tap = { [weak self] in
            guard let self, let index = self.pendingControl else { return }
            self.pendingControl = nil
            self.activate(index)
        }
        configure(enabled: enabled)
        if !enabled { pendingControl = nil }
        updateAccessibility()
        setNeedsLayout()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        if previousSize != bounds.size { cancelTouch(); pendingControl = nil; previousSize = bounds.size }
        updateAccessibilityFrames()
    }

    override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
        LocalDockGroupGeometry.contains(point, size: bounds.size)
    }

    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        guard !isHidden, alpha > 0.01, isUserInteractionEnabled,
              self.point(inside: point, with: event) else { return nil }
        return self
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        if touches.count == 1, (event?.allTouches?.count ?? 1) == 1, let touch = touches.first {
            let point = touch.location(in: self)
            pendingControl = LocalDockGroupGeometry.frames(size: bounds.size, count: controls.count,
                                                           spacing: spacing, horizontalPadding: horizontalPadding, rightToLeft: rightToLeft)
                .firstIndex { $0.contains(point) }
        } else { pendingControl = nil }
        super.touchesBegan(touches, with: event)
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        super.touchesEnded(touches, with: event)
        pendingControl = nil
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        super.touchesCancelled(touches, with: event)
        pendingControl = nil
    }

    private func activate(_ index: Int) {
        guard acceptsTouches, controls.indices.contains(index) else { return }
        controls[index].action()
    }

    private func updateAccessibility() {
        if elements.count != controls.count {
            elements = controls.indices.map { ControlAccessibilityElement(owner: self, index: $0) }
        }
        for (index, element) in elements.enumerated() {
            let control = controls[index]
            element.accessibilityIdentifier = control.identifier
            element.accessibilityLabel = control.label
            element.accessibilityTraits = .button
            if control.selected { element.accessibilityTraits.insert(.selected) }
            if !acceptsTouches { element.accessibilityTraits.insert(.notEnabled) }
        }
        accessibilityElements = elements
        updateAccessibilityFrames()
    }

    private func updateAccessibilityFrames() {
        let frames = LocalDockGroupGeometry.frames(size: bounds.size, count: controls.count, spacing: spacing, horizontalPadding: horizontalPadding, rightToLeft: rightToLeft)
        for (element, frame) in zip(elements, frames) { element.accessibilityFrameInContainerSpace = frame }
    }

    private final class ControlAccessibilityElement: UIAccessibilityElement {
        private weak var owner: LocalDockGroupTouchView?
        private let index: Int
        init(owner: LocalDockGroupTouchView, index: Int) {
            self.owner = owner; self.index = index
            super.init(accessibilityContainer: owner)
        }
        override func accessibilityActivate() -> Bool {
            guard let owner, owner.acceptsTouches else { return false }
            owner.activate(index)
            return true
        }
    }
}

private struct LocalDockBounds: PreferenceKey {
    static let defaultValue: [Anchor<CGRect>] = []
    static func reduce(value: inout [Anchor<CGRect>], nextValue: () -> [Anchor<CGRect>]) { value += nextValue() }
}

private struct LocalDockFrames: PreferenceKey {
    static let defaultValue: [CGRect] = []
    static func reduce(value: inout [CGRect], nextValue: () -> [CGRect]) { value += nextValue() }
}

private struct LocalDockTouchShape: Shape {
    let frames: [CGRect]
    func path(in rect: CGRect) -> Path {
        var path = Path()
        // Individual buttons define their own visual shape. The shared overlay only
        // removes spacers and padding, so it must retain each marked control's full hit area.
        for frame in frames { path.addRect(frame) }
        return path
    }
}

private struct LocalDockTouchRegions: ViewModifier {
    @State private var frames: [CGRect] = []
    func body(content: Content) -> some View {
        content
            .backgroundPreferenceValue(LocalDockBounds.self) { anchors in
                GeometryReader { geometry in
                    Color.clear.preference(key: LocalDockFrames.self, value: anchors.map { geometry[$0] })
                        .allowsHitTesting(false)
                }
            }
            .onPreferenceChange(LocalDockFrames.self) { if frames != $0 { frames = $0 } }
            .contentShape(.interaction, LocalDockTouchShape(frames: frames))
    }
}

private struct LocalDockAccessory<Controls: View>: ViewModifier {
    @Environment(\.usesLocalDock) private var usesDock
    @Environment(\.localDockInset) private var inset
    @Environment(\.localDockTop) private var dockTop
    @ViewBuilder var controls: () -> Controls

    func body(content: Content) -> some View {
        content.overlay {
            GeometryReader { geometry in
                controls()
                    .localDockHitRegion()
                    .padding(.trailing, max(12, geometry.safeAreaInsets.trailing))
                    .padding(.bottom, LocalDockLayout.accessoryBottom(
                        containerBottom: geometry.frame(in: .global).maxY,
                        safeAreaBottom: geometry.safeAreaInsets.bottom,
                        dockTop: usesDock ? dockTop : nil, fallbackInset: usesDock ? inset : 0))
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
                    .localDockHitRegions()
            }
        }
    }
}

extension View {
    /// Fixed-layout docks use current frames directly, with no delayed preference
    /// publication or state animation between a visible control and its hit shape.
    func localDockHitRegions(frames: [CGRect]) -> some View {
        contentShape(.interaction, LocalDockTouchShape(frames: frames))
    }

    /// Mark only painted controls; inter-capsule spacers and outer shadows pass touches through.
    func localDockHitRegion() -> some View {
        anchorPreference(key: LocalDockBounds.self, value: .bounds) { [$0] }
    }
    func localDockHitRegions() -> some View { modifier(LocalDockTouchRegions()) }

    /// Match the dock's real position rather than adding a fixed inset in a
    /// potentially different safe-area coordinate system.
    func localDockAccessory<Controls: View>(@ViewBuilder controls: @escaping () -> Controls) -> some View {
        modifier(LocalDockAccessory(controls: controls))
    }
}
#endif
