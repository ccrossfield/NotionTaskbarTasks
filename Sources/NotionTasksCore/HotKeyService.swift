import Foundation

/// The global-hotkey registration seam (#34), mirroring `LoginItemService`.
/// The app registers a single combination with Carbon's `RegisterEventHotKey`
/// (which fires without any Input-Monitoring / Accessibility permission prompt,
/// unlike `NSEvent.addGlobalMonitorForEvents`); checks use a fake.
///
/// The service owns the "fire" action itself - the shell sets it once when it
/// builds the real service - so re-registering a new combination needs only the
/// `HotKey`, not the action. That keeps the model's `setHotKey` a pure
/// value-plus-persist call, exactly like `setAutoRefreshInterval`.
///
/// There are exactly two fixed slots (#39): the quick-capture shortcut, driven
/// by `register`, and the show-panel shortcut, driven by `registerPanel`. They
/// are independent - registering one leaves the other's registration intact -
/// deliberately two named methods rather than a keyed collection, because there
/// are only ever these two purposes.
public protocol HotKeyService: AnyObject {
    /// Register `hotKey` as the quick-capture shortcut, replacing any previous
    /// quick-capture registration. Safe to call repeatedly: the real
    /// implementation removes the old registration before installing the new one.
    func register(_ hotKey: HotKey)
    /// Register `hotKey` as the show-panel shortcut (#39), replacing any previous
    /// show-panel registration and leaving the quick-capture slot untouched.
    func registerPanel(_ hotKey: HotKey)
    /// Remove both registrations, if any.
    func unregister()
}
