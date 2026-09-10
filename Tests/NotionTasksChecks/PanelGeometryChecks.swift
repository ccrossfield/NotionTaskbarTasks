import CoreGraphics
import Foundation
import NotionTasksCore

/// Where the main panel sits (#47). The shell used to size the panel to its
/// SwiftUI content (340pt wide, list region 380pt) and centre it under the
/// status icon. Now it is a sidebar: full visible height, from beneath the icon
/// out to the screen's right edge. The placement is pure rect arithmetic, so it
/// lives in Core and is checked with hand-worked examples; the AppKit call
/// that applies it is live-verified.
///
/// macOS screen coordinates: origin bottom-left, y grows upward. A screen's
/// `visibleFrame` excludes the menu bar and the Dock.
func panelGeometryChecks(_ t: CheckRun) async {
    t.suite("PanelGeometry (#47)")

    // A 1512×982 built-in display with a 37pt menu bar and the Dock hidden, so
    // the visible area is the full width and everything under the menu bar.
    let visible = CGRect(x: 0, y: 0, width: 1512, height: 945)
    // The status item sits in the menu bar; its bottom edge is the top of the
    // visible area.
    let icon = CGRect(x: 1100, y: 945, width: 30, height: 37)

    await t.test("the panel runs from just under the menu bar to the bottom of the screen, and from beneath the icon to the right edge") {
        // Left: today's centring, midX 1115 minus half of 340 = 945.
        // Right: 8pt in from 1512 = 1504, so width 559.
        // Top: 4pt under the menu bar = 941. Bottom: 8pt up from 0, so height 933.
        t.expectEqual(PanelGeometry.frame(iconFrame: icon, visibleFrame: visible),
                      CGRect(x: 945, y: 8, width: 559, height: 933))
    }

    await t.test("an icon near the right edge shifts the panel left rather than making it narrower than 340") {
        // Centring under midX 1495 would leave 1325...1504 = 179pt. Instead the
        // left edge moves to 1504 - 340 = 1164 and the width stays 340.
        let farRight = CGRect(x: 1480, y: 945, width: 30, height: 37)
        t.expectEqual(PanelGeometry.frame(iconFrame: farRight, visibleFrame: visible),
                      CGRect(x: 1164, y: 8, width: 340, height: 933))
    }

    await t.test("with the Dock showing, the panel stops above it instead of running behind it") {
        // A 70pt Dock lifts the visible area's bottom to 70; the panel's bottom
        // is 8pt above that and the height shrinks to match (941 - 78 = 863).
        let withDock = CGRect(x: 0, y: 70, width: 1512, height: 875)
        t.expectEqual(PanelGeometry.frame(iconFrame: icon, visibleFrame: withDock),
                      CGRect(x: 945, y: 78, width: 559, height: 863))
    }

    await t.test("on a secondary display the panel stays inside that screen, clamped to its left edge when the icon is far left") {
        // A 1920×1080 display to the right of the built-in one, its origin at
        // (1512, 200), a 37pt menu bar, so visible is (1512, 200, 1920, 1043).
        let secondary = CGRect(x: 1512, y: 200, width: 1920, height: 1043)
        // An icon hard against that screen's left edge: centring would put the
        // panel's left at 1365, off the screen. It clamps to 1512 + 8 = 1520
        // and runs to 3432 - 8 = 3424 (width 1904); vertically 208...1239.
        let farLeft = CGRect(x: 1520, y: 1243, width: 30, height: 37)
        t.expectEqual(PanelGeometry.frame(iconFrame: farLeft, visibleFrame: secondary),
                      CGRect(x: 1520, y: 208, width: 1904, height: 1031))
    }
}
