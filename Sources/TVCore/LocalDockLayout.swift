import Foundation

/// Layout values shared by the dock and accessories whose container may extend
/// beyond the dock's safe area (HTML) or start inside a navigation stack (actors).
public enum LocalDockLayout {
    public static let horizontalPadding: CGFloat = 12
    public static let topPadding: CGFloat = 8
    public static let bottomPadding: CGFloat = 6
    public static let musicHeight: CGFloat = 56
    public static let musicSpacing: CGFloat = 8
    public static let controlHeight: CGFloat = 46
    public static let groupPadding: CGFloat = 4
    public static var dockHeight: CGFloat { controlHeight + 2 * groupPadding }

    public struct Metrics: Equatable, Sendable {
        public let containerWidth: CGFloat
        public let mainCount: Int
        public let accessoryCount: Int
        public let buttonWidth: CGFloat
        public let buttonSpacing: CGFloat
        public let groupSpacing: CGFloat
        public let horizontalPadding: CGFloat
        public let groupHorizontalPadding: CGFloat
        public let stacked: Bool

        public var height: CGFloat { stacked ? 2 * dockHeight + groupSpacing : dockHeight }

        public func inset(showsMusic: Bool) -> CGFloat {
            topPadding + height + bottomPadding + (showsMusic ? musicHeight + musicSpacing : 0)
        }

        /// First-frame hit ownership uses the same dimensions as the two rendered groups.
        public func touchFrames(showsMusic: Bool, rightToLeft: Bool = false) -> [CGRect] {
            let availableWidth = max(0, containerWidth - 2 * horizontalPadding)
            func width(_ count: Int) -> CGFloat {
                CGFloat(count) * buttonWidth + CGFloat(count - 1) * buttonSpacing + 2 * groupHorizontalPadding
            }
            let main = width(mainCount), accessory = width(accessoryCount)
            let top = topPadding + (showsMusic ? musicHeight + musicSpacing : 0)
            let start = (containerWidth - main - groupSpacing - accessory) / 2
            let mainX = stacked ? (containerWidth - main) / 2 : (rightToLeft ? start + accessory + groupSpacing : start)
            let accessoryX = stacked ? (containerWidth - accessory) / 2 : (rightToLeft ? start : start + main + groupSpacing)
            var frames = [CGRect]()
            if showsMusic {
                frames.append(CGRect(x: horizontalPadding, y: topPadding, width: availableWidth, height: musicHeight))
            }
            frames.append(CGRect(x: mainX, y: top, width: main, height: dockHeight))
            frames.append(CGRect(x: accessoryX, y: stacked ? top + dockHeight + groupSpacing : top, width: accessory, height: dockHeight))
            return frames
        }
    }

    public static func metrics(containerWidth: CGFloat, mainCount: Int, accessoryCount: Int) -> Metrics {
        let count = mainCount + accessoryCount
        let minimumButtons = CGFloat(count) * 44
        let gaps = CGFloat(count - 2)
        let stacked = containerWidth < minimumButtons + 12
        let regular = stacked || containerWidth >= minimumButtons + 2 * horizontalPadding + 4 * groupPadding + gaps * 4 + 12
        let compact = !regular && containerWidth >= minimumButtons + 12 + 4 * groupPadding + gaps + 4
        let outer: CGFloat = regular ? horizontalPadding : compact ? 6 : 2
        let inner: CGFloat = regular || compact ? groupPadding : 1
        let buttonSpacing: CGFloat = regular ? 4 : compact ? 1 : 0
        let groupSpacing: CGFloat = regular ? 12 : 4
        let rowCount = stacked ? max(mainCount, accessoryCount) : count
        let overhead = 2 * outer + (stacked ? 2 * inner : 4 * inner + groupSpacing)
        let rowGaps = stacked ? CGFloat(rowCount - 1) : gaps
        let buttonWidth = max(0, min(50, (containerWidth - overhead - rowGaps * buttonSpacing) / CGFloat(rowCount)))
        return Metrics(containerWidth: containerWidth, mainCount: mainCount, accessoryCount: accessoryCount,
                       buttonWidth: buttonWidth, buttonSpacing: buttonSpacing, groupSpacing: groupSpacing,
                       horizontalPadding: outer, groupHorizontalPadding: inner, stacked: stacked)
    }

    public static func accessoryBottom(containerBottom: CGFloat, safeAreaBottom: CGFloat,
                                       dockTop: CGFloat?, fallbackInset: CGFloat, gap: CGFloat = 12) -> CGFloat {
        if let dockTop, dockTop.isFinite, containerBottom.isFinite {
            return max(gap, containerBottom - dockTop + gap)
        }
        return max(0, safeAreaBottom) + max(0, fallbackInset) + gap
    }
}
