import CoreGraphics

/// Where the main panel sits on screen (#47): a sidebar running the full
/// visible height, from beneath the status icon out to the screen's right
/// edge. Pure rect arithmetic over the icon's frame and the screen's
/// `visibleFrame` (which excludes the menu bar and the Dock), so the shell's
/// `layoutPanel` is a one-line call and the placement rules are checkable
/// without a display. Coordinates are AppKit's: origin bottom-left, y upward.
public enum PanelGeometry {
    /// The panel's width before #47, kept as the floor: when the icon sits
    /// near the right edge the panel shifts left rather than getting narrower.
    public static let minWidth: CGFloat = 340
    /// Breathing room between the panel and the screen's edges.
    public static let edgeMargin: CGFloat = 8
    /// Gap between the menu bar's bottom edge and the panel's top.
    public static let menuBarGap: CGFloat = 4

    public static func frame(iconFrame: CGRect, visibleFrame: CGRect) -> CGRect {
        let right = visibleFrame.maxX - edgeMargin
        // Centred under the icon as before, but never so far right that less
        // than the old width is left before the screen edge, and never off the
        // screen's left edge.
        let left = max(visibleFrame.minX + edgeMargin,
                       min(iconFrame.midX - minWidth / 2, right - minWidth))
        let top = iconFrame.minY - menuBarGap
        let bottom = visibleFrame.minY + edgeMargin
        return CGRect(x: left, y: bottom, width: right - left, height: top - bottom)
    }
}
