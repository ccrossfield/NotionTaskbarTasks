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
public protocol HotKeyService: AnyObject {
    /// Register `hotKey` as the global shortcut, replacing any previous
    /// registration. Safe to call repeatedly: the real implementation removes
    /// the old registration before installing the new one.
    func register(_ hotKey: HotKey)
    /// Remove the current registration, if any.
    func unregister()
}
