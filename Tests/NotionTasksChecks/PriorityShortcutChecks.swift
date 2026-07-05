import Foundation
import NotionTasksCore

/// The quick-capture ⌘0/⌘1/⌘2 priority accelerators (#45). The decision — what a
/// draft's priority becomes when a digit is pressed — is pure and lives in Core;
/// the keyCode routing and menu hint are thin shell wiring on top. Grilled
/// choices captured here: a **hard label map** (⌘N → "PN", not positional) and
/// **toggle-off** when the already-set priority's digit is pressed again.
func priorityShortcutChecks(_ t: CheckRun) async {
    t.suite("PriorityShortcut quick-capture accelerators (#45)")

    let schema = ["P0", "P1", "P2"]

    await t.test("a digit maps to the literal PN label, not a list position") {
        t.expectEqual(PriorityShortcut.label(for: 0), "P0")
        t.expectEqual(PriorityShortcut.label(for: 1), "P1")
        t.expectEqual(PriorityShortcut.label(for: 2), "P2")
    }

    await t.test("pressing a digit from no priority sets that priority") {
        t.expectEqual(PriorityShortcut.nextPriority(current: nil, digit: 1, available: schema), "P1")
    }

    await t.test("pressing a different digit switches straight to it") {
        t.expectEqual(PriorityShortcut.nextPriority(current: "P0", digit: 2, available: schema), "P2")
    }

    await t.test("pressing the already-set priority's digit toggles it off to nil") {
        t.expectEqual(PriorityShortcut.nextPriority(current: "P1", digit: 1, available: schema), nil)
    }

    await t.test("a digit whose label is absent from the schema leaves priority unchanged") {
        // No "P2" option in this workspace: ⌘2 is a clean no-op, not a clear.
        let partial = ["P0", "P1"]
        t.expectEqual(PriorityShortcut.nextPriority(current: "P1", digit: 2, available: partial), "P1")
        t.expectEqual(PriorityShortcut.nextPriority(current: nil, digit: 2, available: partial), nil)
    }

    await t.test("the menu hint is the ⌘-digit for a mapped priority label") {
        t.expectEqual(PriorityShortcut.hint(forLabel: "P0"), "⌘0")
        t.expectEqual(PriorityShortcut.hint(forLabel: "P1"), "⌘1")
        t.expectEqual(PriorityShortcut.hint(forLabel: "P2"), "⌘2")
    }

    await t.test("a label with no accelerator (e.g. a Category) has no hint") {
        t.expectEqual(PriorityShortcut.hint(forLabel: "P3"), nil)
        t.expectEqual(PriorityShortcut.hint(forLabel: "👨🏻‍💻 Work"), nil)
    }

    await t.test("the accelerated digits are 0, 1, 2 in menu order") {
        t.expectEqual(PriorityShortcut.digits, [0, 1, 2])
    }
}
