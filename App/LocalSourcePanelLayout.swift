import Foundation
import CoreGraphics

/// The keyboard changes the list's height, never the top of the source controls.
enum LocalSourcePanelLayout {
    static func compactControls(height: CGFloat) -> Bool { height < 200 }

    static func frame(viewport: CGSize, keyboardOverlap: CGFloat, maximumWidth: CGFloat,
                      maximumHeight: CGFloat) -> CGRect {
        let width = viewport.width.isFinite ? max(0, viewport.width) : 0
        let height = viewport.height.isFinite ? max(0, viewport.height) : 0
        let overlap = keyboardOverlap.isFinite ? min(height, max(0, keyboardOverlap)) : height
        let available = max(0, height - overlap)
        let inset = min(12, available / 2)
        let cardWidth = min(max(0, maximumWidth), max(0, width - 28))
        let cardHeight = min(max(0, maximumHeight), max(0, available - inset * 2))
        return CGRect(x: (width - cardWidth) / 2,
                      y: overlap > 0 ? inset : (height - cardHeight) / 2,
                      width: cardWidth, height: cardHeight)
    }
}
