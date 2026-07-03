import Foundation

/// The preferences seam: small user choices that survive a relaunch. The app
/// persists them in `UserDefaults` (per the PRD); checks use an in-memory fake.
/// `nil` means "never set" — the model applies its default.
public protocol PreferencesStore: AnyObject {
    /// Seconds between automatic re-fetches (#7).
    var autoRefreshInterval: TimeInterval? { get set }
}

/// Stores preferences in `UserDefaults`. `suite` is injectable so a check can
/// use a scratch domain instead of the app's real one.
public final class UserDefaultsPreferences: PreferencesStore {
    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    public var autoRefreshInterval: TimeInterval? {
        get { defaults.object(forKey: Keys.autoRefreshInterval) as? TimeInterval }
        set {
            if let newValue {
                defaults.set(newValue, forKey: Keys.autoRefreshInterval)
            } else {
                defaults.removeObject(forKey: Keys.autoRefreshInterval)
            }
        }
    }

    private enum Keys {
        static let autoRefreshInterval = "autoRefreshInterval"
    }
}
