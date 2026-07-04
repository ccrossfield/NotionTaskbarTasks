import Foundation

/// The view state that survives a relaunch (#9): the active preset, whether the
/// custom view was showing, and the composed custom filter/sort. The app opens
/// the way it was left.
public struct ViewConfig: Codable, Equatable {
    public var preset: Preset
    public var isCustom: Bool
    public var customQuery: CustomQuery

    public init(preset: Preset, isCustom: Bool, customQuery: CustomQuery) {
        self.preset = preset
        self.isCustom = isCustom
        self.customQuery = customQuery
    }
}

/// The preferences seam: small user choices that survive a relaunch. The app
/// persists them in `UserDefaults` (per the PRD); checks use an in-memory fake.
/// `nil` means "never set" — the model applies its default.
public protocol PreferencesStore: AnyObject {
    /// Seconds between automatic re-fetches (#7).
    var autoRefreshInterval: TimeInterval? { get set }
    /// The last-used view configuration (#9).
    var viewConfig: ViewConfig? { get set }
    /// The folded priority groups (#19), as "preset|priority" keys.
    var collapsedGroups: Set<String>? { get set }
    /// The global quick-capture shortcut (#34); `nil` applies the ⌥Space default.
    var hotKey: HotKey? { get set }
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

    /// JSON-encoded; a corrupt or missing value degrades to "never set".
    public var viewConfig: ViewConfig? {
        get {
            guard let data = defaults.data(forKey: Keys.viewConfig) else { return nil }
            return try? JSONDecoder().decode(ViewConfig.self, from: data)
        }
        set {
            if let newValue, let data = try? JSONEncoder().encode(newValue) {
                defaults.set(data, forKey: Keys.viewConfig)
            } else {
                defaults.removeObject(forKey: Keys.viewConfig)
            }
        }
    }

    /// Stored as a plain string array — a `Set` is not a plist type.
    public var collapsedGroups: Set<String>? {
        get { defaults.stringArray(forKey: Keys.collapsedGroups).map(Set.init) }
        set {
            if let newValue {
                defaults.set(Array(newValue), forKey: Keys.collapsedGroups)
            } else {
                defaults.removeObject(forKey: Keys.collapsedGroups)
            }
        }
    }

    /// JSON-encoded like `viewConfig`; a corrupt or missing value degrades to
    /// "never set", so the model applies the ⌥Space default (#34).
    public var hotKey: HotKey? {
        get {
            guard let data = defaults.data(forKey: Keys.hotKey) else { return nil }
            return try? JSONDecoder().decode(HotKey.self, from: data)
        }
        set {
            if let newValue, let data = try? JSONEncoder().encode(newValue) {
                defaults.set(data, forKey: Keys.hotKey)
            } else {
                defaults.removeObject(forKey: Keys.hotKey)
            }
        }
    }

    private enum Keys {
        static let autoRefreshInterval = "autoRefreshInterval"
        static let viewConfig = "viewConfig"
        static let collapsedGroups = "collapsedGroups"
        static let hotKey = "hotKey"
    }
}
