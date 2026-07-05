import AppKit
import Carbon.HIToolbox
import NotionTasksCore

/// The real global-hotkey registration (#34), over Carbon's
/// `RegisterEventHotKey` (HIToolbox). Chosen over
/// `NSEvent.addGlobalMonitorForEvents` deliberately: it fires only for the one
/// registered combination and needs **no** Input-Monitoring / Accessibility
/// permission prompt, and it works for an `.accessory` app with no Dock icon.
///
/// The shell sets `onFire`/`onPanelFire` once; every re-registration then needs
/// only the new `HotKey`. Fires the actions on the main thread.
///
/// Two fixed slots (#39): the quick-capture combination (id 1, `onFire`) and the
/// show-panel combination (id 2, `onPanelFire`). Both share the one signature and
/// installed handler, which dispatches on the pressed id - deliberately two named
/// slots, not a generic registry, since there are only ever these two purposes.
final class CarbonHotKeyService: HotKeyService {
    /// What to do when the quick-capture combination is pressed (#34). Set once
    /// by the shell.
    var onFire: (() -> Void)?
    /// What to do when the show-panel combination is pressed (#39). Set once by
    /// the shell.
    var onPanelFire: (() -> Void)?

    private var hotKeyRef: EventHotKeyRef?
    private var panelHotKeyRef: EventHotKeyRef?
    private var eventHandler: EventHandlerRef?
    // A four-char signature ('NTKY') plus a per-purpose id identify each of our
    // two hotkeys in the Carbon event, so the handler ignores hotkeys any other
    // code registered and can tell our own two apart.
    private let signature: OSType = 0x4E544B59
    private let hotKeyID: UInt32 = 1       // quick-capture
    private let panelHotKeyID: UInt32 = 2  // show-panel

    init() {
        installHandler()
    }

    deinit {
        unregister()
        if let eventHandler { RemoveEventHandler(eventHandler) }
    }

    /// Install the process-wide handler for hotkey-pressed events once. The
    /// callback is a bare C function (it captures nothing); `self` reaches it
    /// through the opaque `userData` pointer. It routes to the right action by
    /// the pressed id.
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
            guard pressedID.signature == service.signature else { return noErr }
            if pressedID.id == service.hotKeyID {
                DispatchQueue.main.async { service.onFire?() }
            } else if pressedID.id == service.panelHotKeyID {
                DispatchQueue.main.async { service.onPanelFire?() }
            }
            return noErr
        }, 1, &spec, context, &eventHandler)
    }

    /// Register `hotKey` as the quick-capture shortcut, replacing only that slot.
    func register(_ hotKey: HotKey) {
        registerSlot(hotKey, id: hotKeyID, into: &hotKeyRef)
    }

    /// Register `hotKey` as the show-panel shortcut (#39), replacing only that
    /// slot and leaving the quick-capture registration intact.
    func registerPanel(_ hotKey: HotKey) {
        registerSlot(hotKey, id: panelHotKeyID, into: &panelHotKeyRef)
    }

    /// Remove both registrations, if any.
    func unregister() {
        unregisterSlot(&hotKeyRef)
        unregisterSlot(&panelHotKeyRef)
    }

    /// Replace one slot's registration: drop the old ref (if any), then register
    /// `hotKey` under `slotID` and store the new ref. Shared by both public
    /// register methods so the Carbon dance lives in one place - still two named
    /// slots, not a generic registry (#39).
    private func registerSlot(_ hotKey: HotKey, id slotID: UInt32, into ref: inout EventHotKeyRef?) {
        unregisterSlot(&ref)
        let id = EventHotKeyID(signature: signature, id: slotID)
        RegisterEventHotKey(hotKey.keyCode, hotKey.carbonModifiers, id,
                            GetApplicationEventTarget(), 0, &ref)
    }

    private func unregisterSlot(_ ref: inout EventHotKeyRef?) {
        if let ref { UnregisterEventHotKey(ref) }
        ref = nil
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
