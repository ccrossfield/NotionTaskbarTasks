import AppKit
import Carbon.HIToolbox
import NotionTasksCore

/// The real global-hotkey registration (#34), over Carbon's
/// `RegisterEventHotKey` (HIToolbox). Chosen over
/// `NSEvent.addGlobalMonitorForEvents` deliberately: it fires only for the one
/// registered combination and needs **no** Input-Monitoring / Accessibility
/// permission prompt, and it works for an `.accessory` app with no Dock icon.
///
/// The shell sets `onFire` once; every re-registration then needs only the new
/// `HotKey`. Fires `onFire` on the main thread.
final class CarbonHotKeyService: HotKeyService {
    /// What to do when the combination is pressed. Set once by the shell.
    var onFire: (() -> Void)?

    private var hotKeyRef: EventHotKeyRef?
    private var eventHandler: EventHandlerRef?
    // A four-char signature ('NTKY') and id identify our one hotkey in the
    // Carbon event, so the handler ignores hotkeys any other code registered.
    private let signature: OSType = 0x4E544B59
    private let hotKeyID: UInt32 = 1

    init() {
        installHandler()
    }

    deinit {
        unregister()
        if let eventHandler { RemoveEventHandler(eventHandler) }
    }

    /// Install the process-wide handler for hotkey-pressed events once. The
    /// callback is a bare C function (it captures nothing); `self` reaches it
    /// through the opaque `userData` pointer.
    private func installHandler() {
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                 eventKind: UInt32(kEventHotKeyPressed))
        let context = Unmanaged.passUnretained(self).toOpaque()
        InstallEventHandler(GetApplicationEventTarget(), { _, event, userData in
            guard let userData, let event else { return noErr }
            let service = Unmanaged<CarbonHotKeyService>.fromOpaque(userData).takeUnretainedValue()
            var pressedID = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject),
                              EventParamType(typeEventHotKeyID), nil,
                              MemoryLayout<EventHotKeyID>.size, nil, &pressedID)
            if pressedID.signature == service.signature, pressedID.id == service.hotKeyID {
                DispatchQueue.main.async { service.onFire?() }
            }
            return noErr
        }, 1, &spec, context, &eventHandler)
    }

    /// Register `hotKey`, replacing any previous registration.
    func register(_ hotKey: HotKey) {
        unregister()
        let id = EventHotKeyID(signature: signature, id: hotKeyID)
        RegisterEventHotKey(hotKey.keyCode, hotKey.carbonModifiers, id,
                            GetApplicationEventTarget(), 0, &hotKeyRef)
    }

    func unregister() {
        if let hotKeyRef {
            UnregisterEventHotKey(hotKeyRef)
            self.hotKeyRef = nil
        }
    }
}

extension HotKey {
    /// Build a `HotKey` from a recorded key-down (#34). The virtual key code is
    /// identical in the NSEvent and Carbon worlds; only the modifier mask needs
    /// translating from `NSEvent.ModifierFlags` to Carbon's layout. Returns nil
    /// for a press that isn't a usable shortcut (a modifier key on its own).
    init?(recording event: NSEvent) {
        var carbon: UInt32 = 0
        let flags = event.modifierFlags
        if flags.contains(.command) { carbon |= HotKey.CarbonModifier.command }
        if flags.contains(.shift) { carbon |= HotKey.CarbonModifier.shift }
        if flags.contains(.option) { carbon |= HotKey.CarbonModifier.option }
        if flags.contains(.control) { carbon |= HotKey.CarbonModifier.control }
        let candidate = HotKey(keyCode: UInt32(event.keyCode), carbonModifiers: carbon)
        guard candidate.isValid else { return nil }
        self = candidate
    }
}
