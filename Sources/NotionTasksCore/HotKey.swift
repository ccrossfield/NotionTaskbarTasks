import Foundation

/// A global keyboard shortcut (#34): a hardware virtual key code plus a Carbon
/// modifier mask - the two values `RegisterEventHotKey` needs. Stored in Carbon
/// terms (not `NSEvent.ModifierFlags`) so the service can register it directly;
/// the shell converts a recorded `NSEvent` into this at capture time. Lives in
/// Core so its default, display string, validation and persistence are testable
/// without AppKit.
public struct HotKey: Codable, Equatable {
    /// The hardware virtual key code (e.g. 49 = Space). NSEvent and Carbon both
    /// report the same value, so it needs no translation between the two.
    public var keyCode: UInt32
    /// The Carbon modifier mask (`cmdKey`/`optionKey`/…), a different bit layout
    /// from `NSEvent.ModifierFlags` - hence the dedicated constants below.
    public var carbonModifiers: UInt32

    public init(keyCode: UInt32, carbonModifiers: UInt32) {
        self.keyCode = keyCode
        self.carbonModifiers = carbonModifiers
    }

    /// Carbon's `modifierKeys` bit values (HIToolbox `Events.h`), redeclared
    /// here so Core needn't import Carbon just to name them.
    public enum CarbonModifier {
        public static let command: UInt32 = 0x0100 // cmdKey
        public static let shift: UInt32 = 0x0200 // shiftKey
        public static let option: UInt32 = 0x0800 // optionKey
        public static let control: UInt32 = 0x1000 // controlKey
    }

    /// The default combination: ⌥Space (#34). Chosen because Carbon registration
    /// of one fixed combo needs no Input-Monitoring permission, and ⌥Space
    /// rarely clashes with app shortcuts.
    public static let `default` = HotKey(keyCode: 49, carbonModifiers: CarbonModifier.option)

    /// Whether this is a usable global shortcut: it must fire on a real,
    /// non-modifier key. A capture of modifier keys alone (e.g. just ⌥) is
    /// rejected - registering it is meaningless, so the recorder asks again.
    /// Note this deliberately allows a modifier-free combination (a bare F5,
    /// say): those are legitimate global shortcuts and only the user records one.
    public var isValid: Bool {
        !Self.modifierKeyCodes.contains(keyCode)
    }

    /// The keycodes of the modifier keys themselves, which can never be the
    /// activating key of a shortcut.
    private static let modifierKeyCodes: Set<UInt32> = [
        54, 55, // Command (right, left)
        56, 60, // Shift
        58, 61, // Option
        59, 62, // Control
        57, // Caps Lock
        63, // Fn
    ]

    /// The shortcut as it reads in a menu, e.g. "⌥Space" or "⌃⌘K". Modifier
    /// glyphs come first in the macOS-canonical order ⌃⌥⇧⌘, then the key name.
    public var displayString: String {
        var result = ""
        if carbonModifiers & CarbonModifier.control != 0 { result += "⌃" }
        if carbonModifiers & CarbonModifier.option != 0 { result += "⌥" }
        if carbonModifiers & CarbonModifier.shift != 0 { result += "⇧" }
        if carbonModifiers & CarbonModifier.command != 0 { result += "⌘" }
        result += Self.keyName(for: keyCode)
        return result
    }

    /// A human-readable name for a virtual key code on a US layout. Falls back
    /// to "Key N" for codes not in the table - enough for a legible menu label,
    /// and never a crash on some exotic keyboard.
    static func keyName(for keyCode: UInt32) -> String {
        keyNames[keyCode] ?? "Key \(keyCode)"
    }

    private static let keyNames: [UInt32: String] = [
        0: "A", 1: "S", 2: "D", 3: "F", 4: "H", 5: "G", 6: "Z", 7: "X", 8: "C",
        9: "V", 11: "B", 12: "Q", 13: "W", 14: "E", 15: "R", 16: "Y", 17: "T",
        18: "1", 19: "2", 20: "3", 21: "4", 22: "6", 23: "5", 24: "=", 25: "9",
        26: "7", 27: "-", 28: "8", 29: "0", 30: "]", 31: "O", 32: "U", 33: "[",
        34: "I", 35: "P", 37: "L", 38: "J", 39: "'", 40: "K", 41: ";", 42: "\\",
        43: ",", 44: "/", 45: "N", 46: "M", 47: ".", 50: "`",
        36: "Return", 48: "Tab", 49: "Space", 51: "Delete", 53: "Escape",
        76: "Enter", 117: "Forward Delete",
        123: "←", 124: "→", 125: "↓", 126: "↑",
        122: "F1", 120: "F2", 99: "F3", 118: "F4", 96: "F5", 97: "F6",
        98: "F7", 100: "F8", 101: "F9", 109: "F10", 103: "F11", 111: "F12",
    ]
}
