import Foundation

/// The quick-capture ⌘0/⌘1/⌘2 priority accelerators (#45). Keeping the decision
/// here — pure, no AppKit — is what makes it testable: the shell only maps a
/// keyCode to a digit and applies the result, exactly as the ⌘↵ handler is a
/// thin wrapper over Core.
///
/// Two grilled choices are encoded here, not in the shell:
/// - **Hard label map**: ⌘N sets the literal Priority option `"P\(N)"`, *not*
///   the Nth option in the schema. So the accelerator keeps meaning the same
///   real priority even if the options are reordered in Notion; if a label is
///   ever renamed away, its digit simply goes inert rather than silently
///   pointing at a different priority.
/// - **Toggle off**: pressing the digit of the priority the draft already holds
///   clears it. This is the only keyboard route to "no priority" in the capsule.
public enum PriorityShortcut {
    /// The digits that carry an accelerator, in the order the capture Priority
    /// menu lists them.
    public static let digits = [0, 1, 2]

    /// The literal Priority option label a digit maps to (⌘0→"P0", …). A hard
    /// label map by design (#45), not an index into the schema.
    public static func label(for digit: Int) -> String { "P\(digit)" }

    /// The draft's priority after pressing ⌘<digit>, given the schema's current
    /// options:
    /// - label absent from `available` → unchanged (a clean no-op; the shell
    ///   still swallows the key so there's no system beep),
    /// - digit of the already-set priority → `nil` (toggle off),
    /// - any other present label → that label.
    public static func nextPriority(current: String?, digit: Int,
                                    available: [String]) -> String? {
        let target = label(for: digit)
        guard available.contains(target) else { return current }
        return current == target ? nil : target
    }

    /// The ⌘-symbol shown beside an option in the capture Priority menu, or nil
    /// for labels with no accelerator (any Category option, or a Priority label
    /// outside 0…2). Drawn as plain text, never a live `.keyboardShortcut` — the
    /// shell owns the keys, for the borderless-panel reason the ⌘↵ hint exists.
    public static func hint(forLabel label: String) -> String? {
        for digit in digits where self.label(for: digit) == label {
            return "⌘\(digit)"
        }
        return nil
    }
}
