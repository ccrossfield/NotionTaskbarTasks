import Foundation

/// The launch-at-login seam (#10). The app registers itself with
/// `SMAppService` (which persists the setting in the system registry); checks
/// use a fake. `isEnabled` reads the current system truth rather than a cached
/// preference, so the toggle can never disagree with what login will do.
public protocol LoginItemService {
    var isEnabled: Bool { get }
    func setEnabled(_ enabled: Bool) throws
}
