import Foundation
import NotionTasksCore

/// The global quick-capture shortcut value type (#34): what it defaults to, how
/// it reads in a menu, what counts as a usable combination, and that it survives
/// a relaunch. The Carbon/NSEvent translation lives in the shell; everything
/// testable lives on `HotKey` in Core.
func hotKeyChecks(_ t: CheckRun) async {
    t.suite("HotKey defaults and display (#34)")

    await t.test("the default shortcut is ⌥Space") {
        let key = HotKey.default
        t.expectEqual(key.keyCode, 49) // Space
        t.expectEqual(key.carbonModifiers, HotKey.CarbonModifier.option)
        t.expectEqual(key.displayString, "⌥Space")
    }

    await t.test("the default show-panel shortcut is Shift+Option+Space, distinct from quick-capture (#39)") {
        let key = HotKey.defaultPanel
        t.expectEqual(key.keyCode, 49) // Space
        t.expectEqual(key.carbonModifiers,
                      HotKey.CarbonModifier.shift | HotKey.CarbonModifier.option)
        // Rendered in the app's canonical ⌃⌥⇧⌘ order, so Option precedes Shift.
        t.expectEqual(key.displayString, "⌥⇧Space")
        // The two defaults must never coincide, or Carbon would register both
        // against one combination and fire ambiguously.
        t.expect(HotKey.defaultPanel != HotKey.default,
                 "the two default hotkeys must differ")
    }

    await t.test("modifier glyphs render in the canonical ⌃⌥⇧⌘ order, before the key") {
        let all = HotKey(keyCode: 0, carbonModifiers:
            HotKey.CarbonModifier.command | HotKey.CarbonModifier.shift
            | HotKey.CarbonModifier.option | HotKey.CarbonModifier.control)
        // keyCode 0 is "A" on a US layout; the glyph order must not follow the
        // order the bits were OR-ed in.
        t.expectEqual(all.displayString, "⌃⌥⇧⌘A")
    }

    await t.test("a two-modifier combination reads correctly") {
        let key = HotKey(keyCode: 40, carbonModifiers:
            HotKey.CarbonModifier.control | HotKey.CarbonModifier.command)
        t.expectEqual(key.displayString, "⌃⌘K")
    }

    await t.test("an unknown key code degrades to a legible fallback, not a crash") {
        let key = HotKey(keyCode: 250, carbonModifiers: HotKey.CarbonModifier.command)
        t.expectEqual(key.displayString, "⌘Key 250")
    }

    t.suite("HotKey validity (#34)")

    await t.test("⌥Space is a usable shortcut") {
        t.expect(HotKey.default.isValid, "the default must be valid")
    }

    await t.test("a modifier key on its own is rejected - there is nothing to fire on") {
        // 58/61 = Option, 55/54 = Command, 56/60 = Shift, 59/62 = Control,
        // 57 = Caps Lock, 63 = Fn.
        for code: UInt32 in [58, 61, 55, 54, 56, 60, 59, 62, 57, 63] {
            let key = HotKey(keyCode: code, carbonModifiers: HotKey.CarbonModifier.option)
            t.expect(!key.isValid, "modifier keycode \(code) must not count as a shortcut key")
        }
    }

    await t.test("a real key with modifiers is valid") {
        let key = HotKey(keyCode: 40, carbonModifiers: HotKey.CarbonModifier.command)
        t.expect(key.isValid, "⌘K should be valid")
    }

    t.suite("HotKey persistence (#34)")

    await t.test("a hotkey round-trips through Codable unchanged") {
        let key = HotKey(keyCode: 49, carbonModifiers:
            HotKey.CarbonModifier.option | HotKey.CarbonModifier.command)
        let data = try JSONEncoder().encode(key)
        let decoded = try JSONDecoder().decode(HotKey.self, from: data)
        t.expectEqual(decoded, key)
    }
}
