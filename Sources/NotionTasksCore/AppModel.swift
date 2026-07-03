import Foundation
import Combine

/// What the panel is currently showing.
public enum TaskListState: Equatable {
    case needsToken
    case loading
    case loaded([NotionTask])
    case failed(String)
}

/// Drives the panel: reads the stored token, fetches tasks, and maps outcomes
/// to `TaskListState`. This is where "prompt on first run, reuse a stored
/// token, clear a rejected token" lives — the SwiftUI views just render `state`.
@MainActor
public final class AppModel: ObservableObject {
    @Published public private(set) var state: TaskListState = .needsToken
    /// Set when a status write fails, so the UI can tell the user the change
    /// didn't take. Cleared when a write is attempted or succeeds.
    @Published public private(set) var writeError: String?
    /// Set when a background refresh fails while a list is already on screen:
    /// the list stays visible (stale beats blank) and this says why it's stale.
    /// Cleared when the next refresh starts.
    @Published public private(set) var refreshError: String?
    /// When the tasks on screen were fetched from Notion. For a cached snapshot
    /// this is the snapshot's fetch time — the honest age of what's shown.
    @Published public private(set) var lastRefreshed: Date?
    /// The active preset. Published so switching it re-renders the list from the
    /// tasks already in hand — no re-fetch (#5). Defaults to Pivotal Priorities.
    @Published public private(set) var preset: Preset = .pivotalPriorities
    /// Whether a custom filter/sort view is active instead of a preset (#6).
    @Published public private(set) var isCustom = false
    /// The user-composed filter/sort shown while `isCustom` (#6).
    @Published public private(set) var customQuery: CustomQuery = .empty
    /// The filter option lists offered by the custom view, derived from the
    /// fetched schema (#6). Falls back to constants until the schema loads.
    @Published public private(set) var schemaOptions: SchemaOptions = .fallback

    private let tokenStore: TokenStore
    private let cache: TaskCache?
    private let makeClient: (String) -> NotionClient
    /// Injectable clock, so checks can pin the snapshot's `fetchedAt`.
    private let now: () -> Date

    /// Schema-derived facts for the preset filters (ADR-0001). Set from the live
    /// schema on load; the fallbacks apply only if that fetch fails, so the list
    /// never silently empties.
    private var openStatuses: Set<String> = NotionConfig.fallbackOpenStatuses
    private var workCategory: String = NotionConfig.fallbackWorkCategory
    private var personalCategories: Set<String> = NotionConfig.fallbackPersonalCategories

    /// - Parameters:
    ///   - cache: the last-fetched snapshot, shown instantly while a fresh fetch
    ///     runs. `nil` means every launch starts from the spinner.
    ///   - makeClient: builds a client for a token. Injected so tests can supply
    ///     a stubbed transport; the app supplies `URLSession`.
    public init(tokenStore: TokenStore,
                cache: TaskCache? = nil,
                now: @escaping () -> Date = Date.init,
                makeClient: @escaping (String) -> NotionClient) {
        self.tokenStore = tokenStore
        self.cache = cache
        self.now = now
        self.makeClient = makeClient
    }

    /// Call on launch. Loads tasks if a token is stored, else prompts for one.
    public func start() async {
        guard let token = tokenStore.read(), !token.isEmpty else {
            state = .needsToken
            return
        }
        await load(token: token)
    }

    /// Call when the user submits a token from the entry field.
    public func submit(token: String) async {
        let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            state = .needsToken
            return
        }
        try? tokenStore.save(trimmed)
        await load(token: trimmed)
    }

    /// Change a task's status and persist it to Notion. Pessimistic: the row
    /// updates only after the write succeeds, so a failed write causes no
    /// optimistic drift.
    public func setStatus(taskID: String, to newStatus: String) async {
        guard case .loaded(let tasks) = state else { return }
        guard let token = tokenStore.read(), !token.isEmpty else { return }
        writeError = nil
        do {
            try await makeClient(token).updateStatus(pageID: taskID, to: newStatus)
            let updated = tasks.map { task in
                task.id == taskID ? task.withStatus(newStatus) : task
            }
            state = .loaded(updated)
            // Keep the cache in step, or a relaunch resurrects the old status
            // from the stale snapshot. A write isn't a fetch, so the snapshot
            // keeps its fetch time.
            cache?.save(CachedSnapshot(
                tasks: updated, openStatuses: openStatuses, workCategory: workCategory,
                personalCategories: personalCategories, schemaOptions: schemaOptions,
                fetchedAt: lastRefreshed ?? now()))
        } catch {
            writeError = "Couldn't update that task in Notion — it's unchanged. Try again."
        }
    }

    /// Re-fetch with the token already stored.
    public func refresh() async {
        writeError = nil
        await start()
    }

    /// Forget the stored token and return to the entry field. The cached tasks
    /// go with it — they belong to the account being disconnected.
    public func signOut() {
        try? tokenStore.delete()
        cache?.clear()
        state = .needsToken
    }

    /// Switch to a built-in preset. Leaves the custom view if it was active.
    /// Changing this republishes, so the view recomputes `groups()` from the
    /// tasks already loaded — no re-fetch (#5).
    public func selectPreset(_ preset: Preset) {
        self.preset = preset
        isCustom = false
    }

    /// Switch to the custom filter/sort view, keeping whatever query was last
    /// composed (#6).
    public func enterCustom() {
        isCustom = true
    }

    /// Replace the custom filter/sort. Republishes so the list reflows at once.
    public func updateCustom(_ query: CustomQuery) {
        customQuery = query
    }

    /// The label for the active view: the preset's title, or "Custom" (#6).
    public var activeTitle: String { isCustom ? "Custom" : preset.title }

    /// Whether the active view groups by priority. Custom views are always flat.
    public var isGrouped: Bool { isCustom ? false : preset.isGrouped }

    /// The task list for the active view: a preset (#4/#5) or the custom
    /// filter/sort (#6). Recomputed from the raw `.loaded` tasks, so a status
    /// change, a preset switch, or a query edit all reflow it for free. `today`
    /// is injectable for tests; the app passes the real date.
    public func groups(today: Date = Date(), calendar: Calendar = .current) -> [TaskGroup] {
        guard case .loaded(let tasks) = state else { return [] }
        if isCustom {
            return TaskListEngine.custom(tasks, query: customQuery, today: today, calendar: calendar)
        }
        return TaskListEngine.groups(
            for: preset, tasks, openStatuses: openStatuses, workCategory: workCategory,
            personalCategories: personalCategories, today: today, calendar: calendar)
    }

    /// Show a snapshot: the tasks AND the schema facts they were filtered with,
    /// so a cached list groups and filters exactly as it did when fetched.
    private func apply(_ snapshot: CachedSnapshot) {
        openStatuses = snapshot.openStatuses
        workCategory = snapshot.workCategory
        personalCategories = snapshot.personalCategories
        schemaOptions = snapshot.schemaOptions
        state = .loaded(snapshot.tasks)
        lastRefreshed = snapshot.fetchedAt
    }

    private func load(token: String) async {
        refreshError = nil
        // Something to show at once: the last-fetched snapshot beats a spinner.
        if case .loaded = state {
            // keep the current list visible
        } else if let snapshot = cache?.load() {
            apply(snapshot)
        } else {
            state = .loading
        }
        let client = makeClient(token)
        do {
            // Schema first, so the open set is derived from the live schema
            // (ADR-0001). Best-effort: a schema hiccup falls back to the
            // defaults rather than failing the whole load.
            if let schema = try? await client.fetchSchema() {
                openStatuses = schema.openStatusNames
                if let work = schema.workCategoryName { workCategory = work }
                let personal = schema.personalCategoryNames
                if !personal.isEmpty { personalCategories = Set(personal) }
                schemaOptions = schema.filterOptions
            }
            let tasks = try await client.fetchTasks()
            state = .loaded(tasks)
            lastRefreshed = now()
            cache?.save(CachedSnapshot(
                tasks: tasks, openStatuses: openStatuses, workCategory: workCategory,
                personalCategories: personalCategories, schemaOptions: schemaOptions,
                fetchedAt: lastRefreshed ?? now()))
        } catch NotionClientError.unauthorized {
            // The token is bad; drop it so the next launch re-prompts. This one
            // interrupts even with a list on screen — showing stale data against
            // a revoked token just defers the failure to the next write.
            try? tokenStore.delete()
            state = .failed("That token was rejected. Check it and enter it again.")
        } catch let NotionClientError.httpError(code) {
            fail("Notion returned an error (HTTP \(code)). Try again shortly.")
        } catch {
            fail("Couldn't reach Notion. Check your connection and try again.")
        }
    }

    /// A fetch failed. With a list already on screen, keep it (stale beats
    /// blank) and surface why; with nothing to show, fail properly.
    private func fail(_ message: String) {
        if case .loaded = state {
            refreshError = message
        } else {
            state = .failed(message)
        }
    }
}
