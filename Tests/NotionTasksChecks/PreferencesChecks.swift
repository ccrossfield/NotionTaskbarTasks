import Foundation
import NotionTasksCore

/// Persistence round-trips for the real `UserDefaultsPreferences`, against a
/// scratch defaults suite (no app state touched). What a launch writes, the
/// next launch must read back identically (#9).
func preferencesChecks(_ t: CheckRun) async {
    t.suite("Preferences round-trips")
    let suiteName = "uk.co.pivotal.notiontasks.checks"

    func scratchDefaults() throws -> UserDefaults {
        let defaults = try require(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        return defaults
    }

    await t.test("a view configuration round-trips: encode then decode yields the same configuration") {
        let defaults = try scratchDefaults()
        let config = ViewConfig(
            preset: .homePriorities,
            isCustom: true,
            customQuery: CustomQuery(
                statuses: ["To Do", "Blocked"], categories: ["👨🏻‍💻 Work"],
                priorities: ["P1"], workTypes: ["Strategy"],
                dueDate: .onOrBeforeToday, startFrom: .isEmpty,
                sortField: .priority, ascending: false))

        UserDefaultsPreferences(defaults: defaults).viewConfig = config

        // Read through a fresh instance, as the next launch would.
        let reloaded = UserDefaultsPreferences(defaults: try require(UserDefaults(suiteName: suiteName)))
        t.expectEqual(reloaded.viewConfig, config)
        defaults.removePersistentDomain(forName: suiteName)
    }

    await t.test("the auto-refresh interval round-trips") {
        let defaults = try scratchDefaults()

        UserDefaultsPreferences(defaults: defaults).autoRefreshInterval = 300

        let reloaded = UserDefaultsPreferences(defaults: try require(UserDefaults(suiteName: suiteName)))
        t.expectEqual(reloaded.autoRefreshInterval, 300)
        defaults.removePersistentDomain(forName: suiteName)
    }

    await t.test("the folded priority groups round-trip") {
        let defaults = try scratchDefaults()
        let folded: Set<String> = ["pivotalPriorities|P2", "homePriorities|none"]

        UserDefaultsPreferences(defaults: defaults).collapsedGroups = folded

        let reloaded = UserDefaultsPreferences(defaults: try require(UserDefaults(suiteName: suiteName)))
        t.expectEqual(reloaded.collapsedGroups, folded)
        defaults.removePersistentDomain(forName: suiteName)
    }

    await t.test("an empty store yields nil, not a phantom configuration") {
        let defaults = try scratchDefaults()
        let prefs = UserDefaultsPreferences(defaults: defaults)

        t.expect(prefs.viewConfig == nil, "nothing was ever saved")
        t.expect(prefs.autoRefreshInterval == nil, "nothing was ever saved")
        t.expect(prefs.collapsedGroups == nil, "nothing was ever saved")
        defaults.removePersistentDomain(forName: suiteName)
    }
}
