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
    /// Set when the schema fetch fails but the task fetch succeeds (#14): the
    /// list renders with the last-known-good schema facts and this says the
    /// filters/options may be stale. Cleared by the next load whose schema
    /// fetch succeeds. When the task fetch fails too, its error states win and
    /// this stays unset.
    @Published public private(set) var schemaWarning: String?
    /// When the tasks on screen were fetched from Notion. For a cached snapshot
    /// this is the snapshot's fetch time — the honest age of what's shown.
    @Published public private(set) var lastRefreshed: Date?
    /// Whether a fetch is in flight. The list stays visible behind it (#7);
    /// the view shows a small progress indicator instead of a blank flash.
    @Published public private(set) var isRefreshing = false
    /// Seconds between automatic re-fetches (#7). Read from preferences at
    /// launch; changed via `setAutoRefreshInterval`.
    @Published public private(set) var autoRefreshInterval: TimeInterval
    /// Whether the app starts at login (#10) — mirrors the system service's
    /// state, which is the persisted source of truth.
    @Published public private(set) var launchAtLogin: Bool
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
    /// Which priority groups are folded away in grouped presets (#19).
    /// Published so a header toggle reflows the list at once. Empty means
    /// everything expanded — the first-run default.
    @Published private var collapsedGroups: Set<String> = []
    /// Whether the quick-add composer is open (#22). Model-owned rather than
    /// view @State so the app shell's Esc handling can close the composer
    /// first and only fall through to closing the panel when it's shut.
    @Published public private(set) var isComposing = false
    /// Whether a create is in flight (#22): the composer's Add button shows a
    /// spinner and disables, mirroring `isRefreshing`.
    @Published public private(set) var isCreating = false
    /// Set when a create fails, so the composer can say why while keeping the
    /// typed draft. Cleared when a create is attempted or the composer
    /// opens/closes.
    @Published public private(set) var createError: String?
    /// Set when a create succeeded but the new task doesn't match the active
    /// view's filter (#22) — otherwise Add would appear to do nothing while
    /// the task lands invisibly. One-shot: the view clears it after showing
    /// it; the next create or refresh clears it too.
    @Published public private(set) var createNotice: String?
    /// The task whose title is being renamed inline (#28), or nil. Model-owned
    /// like `isComposing`, for two reasons: the app shell can commit or cancel
    /// the edit around panel teardown, and the poll loop can hold off while a
    /// rename is open so a wholesale refresh never clobbers it.
    @Published public private(set) var editingTaskID: String?
    /// The live text of the inline rename (#28). The editor field reads and
    /// writes it through here, so whatever is typed is committable from the
    /// shell even as the panel closes.
    @Published public private(set) var editingDraft = ""
    /// Whether the header's search row is open (#32). Model-owned like
    /// `isComposing`, so the shell's Esc handling and panel teardown can close
    /// it, and so opening the composer can collapse it (the two share the row
    /// below the header and are mutually exclusive).
    @Published public private(set) var isSearching = false
    /// The live search query (#32). Filters the active view by title through
    /// `groups()`. Deliberately *not* persisted: reopening the app to a stale
    /// filter hiding most tasks would read as data loss. It does survive a
    /// preset switch, though, so widening a fruitless search to All open is one
    /// tap rather than a retype.
    @Published public private(set) var searchText = ""

    private let tokenStore: TokenStore
    private let cache: TaskCache?
    private let preferences: PreferencesStore?
    private let loginItem: LoginItemService?
    private let makeClient: (String) -> NotionClient
    /// Injectable clock, so checks can pin the snapshot's `fetchedAt`.
    private let now: () -> Date
    /// The poll-timer seam: waits out one auto-refresh interval. Injected so
    /// checks can drive "the interval elapses" without real waiting; the app
    /// default is a plain `Task.sleep`.
    private let pollSleep: @Sendable (TimeInterval) async -> Void
    private var pollTask: Task<Void, Never>?

    /// Schema-derived facts for the preset filters (ADR-0001). The compile-time
    /// fallbacks are initial values only: they are overwritten by a cached
    /// snapshot or a successful schema fetch and never reverted to. On a schema
    /// fetch failure the last-known-good facts stay in use — which can still
    /// misfilter against renamed statuses, so `schemaWarning` says the schema
    /// didn't load rather than letting that pass silently (#14).
    private var openStatuses: Set<String> = NotionConfig.fallbackOpenStatuses
    private var workCategory: String = NotionConfig.fallbackWorkCategory
    private var personalCategories: Set<String> = NotionConfig.fallbackPersonalCategories
    /// The title property's name, keying the create payload (#22). Resolved
    /// from the live schema on load; the fallback ("Task") applies only until
    /// the first successful schema fetch — and a create needs the network up,
    /// so in practice a fresh resolution has almost always just happened.
    private var titleProperty: String = NotionConfig.fallbackTitleProperty

    /// - Parameters:
    ///   - cache: the last-fetched snapshot, shown instantly while a fresh fetch
    ///     runs. `nil` means every launch starts from the spinner.
    ///   - makeClient: builds a client for a token. Injected so tests can supply
    ///     a stubbed transport; the app supplies `URLSession`.
    public init(tokenStore: TokenStore,
                cache: TaskCache? = nil,
                preferences: PreferencesStore? = nil,
                loginItem: LoginItemService? = nil,
                now: @escaping () -> Date = Date.init,
                pollSleep: @escaping @Sendable (TimeInterval) async -> Void = { seconds in
                    try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                },
                makeClient: @escaping (String) -> NotionClient) {
        self.tokenStore = tokenStore
        self.cache = cache
        self.preferences = preferences
        self.loginItem = loginItem
        self.now = now
        self.pollSleep = pollSleep
        self.makeClient = makeClient
        self.launchAtLogin = loginItem?.isEnabled ?? false
        self.autoRefreshInterval =
            preferences?.autoRefreshInterval ?? Self.defaultAutoRefreshInterval
        // Reopen the way the app was left (#9) — restored here, before any
        // fetch, so the first render is already the remembered view.
        if let config = preferences?.viewConfig {
            self.preset = config.preset
            self.isCustom = config.isCustom
            self.customQuery = config.customQuery
        }
        // Folded groups are remembered too (#19); never-set means all expanded.
        self.collapsedGroups = preferences?.collapsedGroups ?? []
    }

    /// One minute: fresh enough for the menu-bar badge, and 1-2 requests a
    /// minute is far inside Notion's ~3 req/s budget.
    public static let defaultAutoRefreshInterval: TimeInterval = 60

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
        guard case .loaded = state else { return }
        guard let token = tokenStore.read(), !token.isEmpty else { return }
        writeError = nil
        do {
            try await makeClient(token).updateStatus(pageID: taskID, to: newStatus)
            // Re-read the state as it is *now*: the await is a MainActor
            // suspension point, so another write or a refresh may have landed
            // meanwhile — mapping a pre-await snapshot back in would clobber
            // their result (issue #12).
            guard case .loaded(let current) = state else { return }
            let updated = current.map { task in
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
        } catch NotionClientError.unauthorized {
            // The token died between the load and this write. "Try again" can
            // never succeed, so mirror the load path (issue #13): drop the
            // token and route the user back to entering one.
            try? tokenStore.delete()
            state = .failed("Notion rejected the stored token, so that change wasn't saved. Enter a new token to reconnect.")
        } catch {
            writeError = "Couldn't update that task in Notion — it's unchanged. Try again."
        }
    }

    /// Rename a task and persist it to Notion (#28). Optimistic, unlike the
    /// pessimistic status path: the row shows the new title at once and the
    /// PATCH runs behind it, because a half-committed text edit has no sensible
    /// "pending" visual. A failure rolls the title back and surfaces
    /// `writeError`. An empty or unchanged title is a no-op: no blank tasks, no
    /// pointless writes.
    public func setTitle(taskID: String, to newTitle: String) async {
        guard case .loaded(let current) = state else { return }
        guard let token = tokenStore.read(), !token.isEmpty else { return }
        guard let original = current.first(where: { $0.id == taskID }) else { return }
        let trimmed = newTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        // Empty reverts to the original (a blank task is unrecoverable from
        // this UI); an unchanged title isn't worth a round-trip.
        guard !trimmed.isEmpty, trimmed != original.title else { return }
        writeError = nil
        // Show the rename immediately; the write catches up.
        applyTitle(trimmed, to: taskID)
        do {
            try await makeClient(token).updateTitle(
                pageID: taskID, to: trimmed, titleProperty: titleProperty)
            // Re-assert after the await: a refresh may have landed Notion's
            // pre-rename copy while the PATCH was in flight, so re-apply to be
            // sure the confirmed rename sticks (the issue #12 pattern).
            applyTitle(trimmed, to: taskID)
        } catch NotionClientError.unauthorized {
            // The token died between load and write. Roll back the optimistic
            // rename, then route to reconnect like every write path (#13).
            applyTitle(original.title, to: taskID)
            try? tokenStore.delete()
            state = .failed("Notion rejected the stored token, so that rename wasn't saved. Enter a new token to reconnect.")
        } catch {
            // Roll the title back to what Notion still holds and say so.
            applyTitle(original.title, to: taskID)
            writeError = "Couldn't rename that task in Notion; the title is unchanged. Try again."
        }
    }

    /// Set a task's title in the loaded state and keep the cache in step,
    /// re-reading state each call so it is safe across the write's await
    /// suspension point (issue #12). The mirror of `setStatus`'s in-place map.
    private func applyTitle(_ title: String, to taskID: String) {
        guard case .loaded(let current) = state else { return }
        let updated = current.map { $0.id == taskID ? $0.withTitle(title) : $0 }
        state = .loaded(updated)
        cache?.save(CachedSnapshot(
            tasks: updated, openStatuses: openStatuses, workCategory: workCategory,
            personalCategories: personalCategories, schemaOptions: schemaOptions,
            fetchedAt: lastRefreshed ?? now()))
    }

    /// Begin renaming a task inline (#28). Any rename already open on another
    /// row is committed first, so switching rows never silently drops an edit.
    public func beginEditing(taskID: String, title: String) {
        if let open = editingTaskID, open != taskID { commitEditing() }
        writeError = nil
        editingTaskID = taskID
        editingDraft = title
    }

    /// The editor field pushes each keystroke back through here (#28).
    public func setEditingDraft(_ text: String) { editingDraft = text }

    /// Commit the inline rename: leave edit mode at once, then persist the
    /// draft optimistically behind it (#28). A no-op when nothing is being
    /// edited, so the shell can call it unconditionally as the panel closes.
    public func commitEditing() {
        guard let taskID = editingTaskID else { return }
        let draft = editingDraft
        editingTaskID = nil
        editingDraft = ""
        Task { await setTitle(taskID: taskID, to: draft) }
    }

    /// Abandon the inline rename without writing (#28) — the Escape path.
    public func cancelEditing() {
        editingTaskID = nil
        editingDraft = ""
    }

    /// Open the header search row (#32), collapsing the composer if it was open
    /// — both live in the row below the header and only one may occupy it.
    public func openSearch() {
        closeComposer()
        isSearching = true
    }

    /// Close the search row and clear the query (#32). One call for every exit
    /// route — the toggle icon, Escape, and panel teardown — so a reopened
    /// panel always starts unfiltered.
    public func closeSearch() {
        isSearching = false
        searchText = ""
    }

    /// The header icon toggles the search row (#32).
    public func toggleSearch() {
        if isSearching { closeSearch() } else { openSearch() }
    }

    /// The search field pushes each keystroke back through here (#32), so the
    /// filter lives in the model and `groups()` reflows on every change.
    public func setSearch(_ text: String) { searchText = text }

    /// Open the quick-add composer (#22). Messages from the previous
    /// composition die here — they belong to a draft that no longer exists.
    /// Collapses the search row if it was open (#32): the two are mutually
    /// exclusive in the row below the header.
    public func openComposer() {
        closeSearch()
        createError = nil
        createNotice = nil
        isComposing = true
    }

    /// Close the composer, discarding whatever was typed. The error goes with
    /// the draft it described.
    public func closeComposer() {
        isComposing = false
        createError = nil
    }

    /// The view clears the one-shot "added — not visible" notice once shown.
    public func clearCreateNotice() {
        createNotice = nil
    }

    /// The composer's pre-filled draft for the active view (#22): Work on
    /// Pivotal Priorities, due-today on Late or due today, empty elsewhere.
    /// Uses the schema-derived Work category, like the preset filters do.
    public func composerDraft(today: Date = Date(), calendar: Calendar = .current) -> TaskDraft {
        ComposerDefaults.draft(for: preset, isCustom: isCustom,
                               workCategory: workCategory, today: today, calendar: calendar)
    }

    /// Create a task in Notion (#22). Pessimistic like `setStatus`: the row
    /// appears only after the POST succeeds, decoded from the response so the
    /// list shows what Notion actually stored (including the defaulted
    /// status). Returns whether it succeeded; on failure the composer stays
    /// open, so the typed draft is never lost to a network hiccup.
    @discardableResult
    public func createTask(_ draft: TaskDraft,
                           today: Date = Date(),
                           calendar: Calendar = .current) async -> Bool {
        guard case .loaded = state else { return false }
        guard let token = tokenStore.read(), !token.isEmpty else { return false }
        var draft = draft
        draft.title = draft.trimmedTitle
        guard !draft.title.isEmpty else { return false }
        createError = nil
        createNotice = nil
        isCreating = true
        defer { isCreating = false }
        do {
            let created = try await makeClient(token)
                .createTask(draft, titleProperty: titleProperty)
            isComposing = false
            // Re-read the state as it is *now* — the await is a suspension
            // point and a refresh may have landed meanwhile (issue #12).
            guard case .loaded(let current) = state else { return true }
            let updated = current + [created]
            state = .loaded(updated)
            // Keep the cache in step, as setStatus does. A write isn't a
            // fetch, so the snapshot keeps its fetch time.
            cache?.save(CachedSnapshot(
                tasks: updated, openStatuses: openStatuses, workCategory: workCategory,
                personalCategories: personalCategories, schemaOptions: schemaOptions,
                fetchedAt: lastRefreshed ?? now()))
            // The task is real wherever the panel is pointing — but if it
            // doesn't match the active view's filter, say so rather than let
            // Add appear to have done nothing.
            let visible = groups(today: today, calendar: calendar)
                .contains { $0.tasks.contains { $0.id == created.id } }
            createNotice = visible ? nil : "Added to Notion - not visible in \(activeTitle)."
            return true
        } catch NotionClientError.unauthorized {
            // Mirror every other write path (#13): a dead token can't be
            // retried into working, so drop it and route to reconnect.
            try? tokenStore.delete()
            state = .failed("Notion rejected the stored token, so that task wasn't created. Enter a new token to reconnect.")
            return false
        } catch NotionClientError.rateLimited {
            createError = "Notion is rate-limiting the app right now. Wait a minute, then try again."
            return false
        } catch {
            createError = "Couldn't add that task to Notion. Try again."
            return false
        }
    }

    /// Re-fetch with the token already stored.
    public func refresh() async {
        writeError = nil
        createNotice = nil
        await start()
    }

    /// Auto-refresh at the preferred cadence (#7). Call once at launch.
    public func startPolling() {
        startPolling(every: autoRefreshInterval)
    }

    /// Change the auto-refresh cadence: persists it and, if the loop is
    /// running, re-parks it at the new interval.
    public func setAutoRefreshInterval(_ interval: TimeInterval) {
        autoRefreshInterval = interval
        preferences?.autoRefreshInterval = interval
        if pollTask != nil { startPolling(every: interval) }
    }

    /// Auto-refresh: re-fetch every `interval` seconds until `stopPolling` (#7).
    /// Restartable — a repeat call replaces the previous cadence.
    public func startPolling(every interval: TimeInterval) {
        stopPolling()
        pollTask = Task { [weak self, pollSleep] in
            while !Task.isCancelled {
                await pollSleep(interval)
                guard !Task.isCancelled, let self else { return }
                // A wholesale refresh would clobber an inline rename in
                // progress (#28); skip this tick, the next one refreshes.
                if self.editingTaskID != nil { continue }
                await self.refresh()
            }
        }
    }

    public func stopPolling() {
        pollTask?.cancel()
        pollTask = nil
    }

    /// The menu-bar badge count (#10): open tasks due today or late, by the
    /// same schema-derived semantics as the "Late or due today" preset —
    /// independent of whichever view the panel is showing.
    public func lateOrDueTodayCount(today: Date = Date(), calendar: Calendar = .current) -> Int {
        guard case .loaded(let tasks) = state else { return 0 }
        return TaskListEngine.lateOrDueToday(
            tasks, openStatuses: openStatuses, today: today, calendar: calendar)
            .reduce(0) { $0 + $1.tasks.count }
    }

    /// Register or unregister the app as a login item (#10). On failure the
    /// published state re-reads the service, so the toggle stays truthful.
    public func setLaunchAtLogin(_ enabled: Bool) {
        guard let loginItem else { return }
        do {
            try loginItem.setEnabled(enabled)
            launchAtLogin = enabled
        } catch {
            launchAtLogin = loginItem.isEnabled
        }
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
        persistViewConfig()
    }

    /// Switch to the custom filter/sort view, keeping whatever query was last
    /// composed (#6).
    public func enterCustom() {
        isCustom = true
        persistViewConfig()
    }

    /// Replace the custom filter/sort. Republishes so the list reflows at once.
    public func updateCustom(_ query: CustomQuery) {
        customQuery = query
        persistViewConfig()
    }

    /// Whether a priority group's rows are folded away in the active preset
    /// (#19). `priority` is the group's option name; `nil` is the "No priority"
    /// group.
    public func isCollapsed(_ priority: String?) -> Bool {
        collapsedGroups.contains(groupKey(priority))
    }

    /// Fold or unfold a priority group's rows in the active preset (#19).
    /// Remembered at once, like every other view change (#9).
    public func toggleCollapsed(_ priority: String?) {
        collapsedGroups.formSymmetricDifference([groupKey(priority)])
        preferences?.collapsedGroups = collapsedGroups
    }

    /// Keyed by preset as well as priority, so folding P2 in Pivotal leaves
    /// Home's P2 alone. Keys carry the option name, so the ones stored while
    /// priorities were an enum ("pivotalPriorities|P0") keep their meaning.
    private func groupKey(_ priority: String?) -> String {
        "\(preset.rawValue)|\(priority ?? "none")"
    }

    /// Every view change is remembered at once (#9); there is no "save" moment
    /// a menu bar app could reliably hook instead.
    private func persistViewConfig() {
        preferences?.viewConfig = ViewConfig(preset: preset, isCustom: isCustom,
                                             customQuery: customQuery)
    }

    /// Whether what's on screen is over a minute old — the threshold for the
    /// panel's stale-data warning. `reference` is injectable for checks; the
    /// view passes its timeline date so the flag flips while the panel is open.
    public func isStale(asOf reference: Date = Date()) -> Bool {
        guard let lastRefreshed else { return false }
        return reference.timeIntervalSince(lastRefreshed) > 60
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
        // Apply the title search first (#32): filtering before grouping drops
        // empty groups and makes the section counts reflect the matches for
        // free. An empty query passes every task through unchanged. AND-ing a
        // pure title predicate ahead of the preset/custom filters is
        // order-independent, so the shown set is identical to filtering after.
        let searched = TaskListEngine.search(tasks, matching: searchText)
        if isCustom {
            return TaskListEngine.custom(searched, query: customQuery,
                                         priorityOrder: schemaOptions.priorities,
                                         today: today, calendar: calendar)
        }
        return TaskListEngine.groups(
            for: preset, searched, openStatuses: openStatuses, workCategory: workCategory,
            personalCategories: personalCategories, priorityOrder: schemaOptions.priorities,
            today: today, calendar: calendar)
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
        isRefreshing = true
        defer { isRefreshing = false }
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
            // (ADR-0001). A schema hiccup doesn't fail the load — the
            // last-known-good facts keep filtering — but it must not pass
            // silently either (#14). The warning is published only once the
            // task fetch has succeeded: if that fails too, its error states
            // are the whole story.
            var schemaFailed = false
            do {
                let schema = try await client.fetchSchema()
                openStatuses = schema.openStatusNames
                if let work = schema.workCategoryName { workCategory = work }
                let personal = schema.personalCategoryNames
                if !personal.isEmpty { personalCategories = Set(personal) }
                if let title = schema.titlePropertyName { titleProperty = title }
                schemaOptions = schema.filterOptions
            } catch {
                schemaFailed = true
            }
            let tasks = try await client.fetchTasks()
            state = .loaded(tasks)
            schemaWarning = schemaFailed
                ? "Couldn't load the filter options from Notion - filters and grouping may be out of date."
                : nil
            lastRefreshed = now()
            cache?.save(CachedSnapshot(
                tasks: tasks, openStatuses: openStatuses, workCategory: workCategory,
                personalCategories: personalCategories, schemaOptions: schemaOptions,
                fetchedAt: lastRefreshed ?? now()))
        } catch is CancellationError {
            // The fetch was torn down on purpose — a poll restart (#27) or
            // sign-out cancelled its task. No news, not a failure; the next
            // tick refreshes.
            return
        } catch let error as URLError where error.code == .cancelled {
            // URLSession reports mid-flight cancellation as its own error.
            return
        } catch NotionClientError.unauthorized {
            // The token is bad; drop it so the next launch re-prompts. This one
            // interrupts even with a list on screen — showing stale data against
            // a revoked token just defers the failure to the next write.
            try? tokenStore.delete()
            state = .failed("That token was rejected. Check it and enter it again.")
        } catch NotionClientError.rateLimited {
            // The client already backed off and retried; naming the throttle
            // stops it reading as an outage (issue #8).
            fail("Notion is rate-limiting the app right now. Wait a minute, then refresh.")
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
