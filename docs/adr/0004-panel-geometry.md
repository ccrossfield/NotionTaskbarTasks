# 4. Panel geometry: a full-height sidebar, not a content-sized dropdown

Date: 2026-09-10

## Status

Accepted. Requested by the user with a screenshot of the old panel (#47).

## Context

Since #20 the panel sized itself to its SwiftUI content: a fixed 340pt width,
a fixed 380pt list region, centred under the status icon and clamped to the
screen edge. With sixty open P0 tasks that showed six rows at a time and
wrapped most titles onto two lines. The user asked for the window to be much
larger: the full height of the screen, with the width running out to the
screen's right edge.

## Decision

The panel is a **sidebar**. Its frame is a pure function of two AppKit inputs,
the status icon's frame and the screen's `visibleFrame`, computed by
`PanelGeometry.frame(iconFrame:visibleFrame:)` in `NotionTasksCore`:

- **Top** 4pt under the menu bar, as before.
- **Bottom** 8pt above the Dock or the screen's bottom edge (`visibleFrame`
  already excludes both the menu bar and the Dock).
- **Left** where it was before: centred under the icon, so the panel still
  reads as belonging to the icon.
- **Right** 8pt in from the screen's right edge.
- **Floor** of 340pt on the width. An icon near the right edge shifts the
  panel left rather than shrinking it below the old width, and the left edge
  never leaves the screen.

**Type goes up a notch to suit the room.** Row titles 15pt (was the 13pt
body default), the metadata line 12pt (was 10pt caption), group headers 12pt
semibold and the view-picker title 15pt semibold, held in one `PanelFont`
scale in `ContentView` rather than scattered text styles. Pinned point sizes
lose nothing on macOS, which doesn't scale text styles.

The SwiftUI content no longer fixes a size. `ContentView` fills whatever the
panel gives it (`maxWidth`/`maxHeight: .infinity`, top-leading), the loaded
state's list region takes the remaining height and scrolls inside it, and the
shorter states (token entry, loading, failure) sit at the top of the sidebar.

## Consequences

- **The content-size feedback loop is gone.** The former `PanelHostingView`
  reported SwiftUI intrinsic-size changes so the window could follow; the
  frame no longer depends on content, so the panel uses a plain
  `NSHostingView` with `sizingOptions = []` and is laid out once per open.
- **Geometry is unit-checked.** The four placement rules above are worked
  examples in `PanelGeometryChecks` (built-in display, icon at the far right,
  Dock showing, offset secondary display). Only the two-line `layoutPanel`
  that gathers the AppKit frames is live-verified.
- **The quick-capture and recorder panels are unchanged.** They keep their
  own centred `layout(_:size:verticalBias:)` (#34); this decision is about
  the main panel only.
- **Row layout was designed for 340pt** (ADR-0002, #19, #28). At two to five
  times that width the two-line rows still work, but long lists now show far
  more rows at once, and the README's mockup screenshots still show the old
  narrow panel until they are re-rendered.
