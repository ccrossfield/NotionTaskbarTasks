import Foundation
import Combine

/// What the panel is currently showing.
public enum TaskListState: Equatable {
    case needsToken
    case loading
    case loaded([NotionTask])
    case failed(String)
}

/// How a quick-capture create resolved (#37), so the shell knows whether to
/// preserve the typed draft for a retry.
public enum CaptureOutcome: Equatable {
    /// Created (optimistically shown, then reconciled to the real task).
    case captured
    /// Nothing was sent - no token, or a blank title.
    case notCaptured
    /// A network / rate-limit / server failure: the provisional row was rolled
    /// back and the full draft should be preserved for retry.
    case transientFailure
    /// The token was rejected: dropped, routed to reconnect (#13).
    case authFailure
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
    /// The global quick-capture shortcut (#34). Restored from preferences at
    /// launch (defaulting to ⌥Space) and changed via `setHotKey`; the gear menu
    /// reads it and the shell registers it.
    @Published public private(set) var hotKey: HotKey
    /// Set when a task created from the quick-capture window (#34) failed to
    /// reach Notion. The window has already closed optimistically, so unlike
    /// the composer's `createError` this waits to be shown on the main panel's
    /// next open. Deliberately NOT cleared by a background refresh (the panel
    /// may be shut for minutes) - only by `clearCaptureError` when the panel
    /// closes, or by the next capture attempt.
    @Published public private(set) var captureError: String?
    /// Tasks currently ticked-and-dwelling after a one-click complete (#36):
    /// the green tick shows for `completionDwell` before the row collapses out.
    /// Lives on the model, not view `@State`, because this is a menu-bar popover
    /// that can close and reopen mid-dwell - the model survives that, view state
    /// wouldn't. While a task is in here its real status is left untouched (the
    /// write is pessimistic), so it stays visible in `groups()` on its own open
    /// status; the tick is driven purely by membership here.
    @Published public private(set) var pendingCompletion: Set<String> = []
    /// Tasks that just bounced back into the list after a failed completion
    /// write (#36): the row is restored at its original position and the view
    /// flashes a brief highlight so the eye catches which one returned. Cleared
    /// after `restoreFlash`.
    @Published public private(set) var restoredCompletions: Set<String> = []
    /// The directory a "Work on in Claude Code" launch cd's into before running
    /// `claude` (#35). Restored from preferences at launch (defaulting to
    /// ~/Documents/workspace) and changed via `setClaudeWorkspaceDirectory`.
    @Published public private(set) var claudeWorkspaceDirectory: String

    private let tokenStore: TokenStore
    private let cache: TaskCache?
    private let preferences: PreferencesStore?
    private let loginItem: LoginItemService?
    private let hotKeyService: HotKeyService?
    private let makeClient: (String) -> NotionClient
    /// Injectable clock, so checks can pin the snapshot's `fetchedAt`.
    private let now: () -> Date
    /// The poll-timer seam: waits out one auto-refresh interval. Injected so
    /// checks can drive "the interval elapses" without real waiting; the app
    /// default is a plain `Task.sleep`.
    private let pollSleep: @Sendable (TimeInterval) async -> Void
    private var pollTask: Task<Void, Never>?
    /// The UI-timing seam (#36): waits out the completion tick's dwell and the
    /// failure-flash. Injected so checks drive "the dwell elapses" without real
    /// waiting and can observe the ticked row mid-dwell; the app default sleeps.
    private let uiSleep: @Sendable (TimeInterval) async -> Void
    /// How many quick-captures are mid-flight (#37): a counter, not a flag, so
    /// concurrent captures each guard the poll independently. A poll tick is
    /// skipped while any capture is in flight, so a mid-capture refresh can't
    /// drop the provisional row before its create returns.
    private var capturesInFlight = 0

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
                hotKeyService: HotKeyService? = nil,
                now: @escaping () -> Date = Date.init,
                pollSleep: @escaping @Sendable (TimeInterval) async -> Void = { seconds in
                    try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                },
                uiSleep: @escaping @Sendable (TimeInterval) async -> Void = { seconds in
                    try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                },
                makeClient: @escaping (String) -> NotionClient) {
        self.tokenStore = tokenStore
        self.cache = cache
        self.preferences = preferences
        self.loginItem = loginItem
        self.hotKeyService = hotKeyService
        self.now = now
        self.pollSleep = pollSleep
        self.uiSleep = uiSleep
        self.makeClient = makeClient
        self.launchAtLogin = loginItem?.isEnabled ?? false
        // The Claude Code workspace directory (#35), or the ~/Documents/workspace
        // default until the user picks another.
        self.claudeWorkspaceDirectory =
            preferences?.claudeWorkspaceDirectory ?? Self.defaultWorkspaceDirectory
        self.autoRefreshInterval =
            preferences?.autoRefreshInterval ?? Self.defaultAutoRefreshInterval
        // Restore the quick-capture shortcut, or fall back to ⌥Space (#34).
        self.hotKey = preferences?.hotKey ?? .default
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

    /// How long a completed row dwells ticked before it collapses out (#36):
    /// long enough to register the tick, short enough to feel instant.
    static let completionDwell: TimeInterval = 0.7
    /// How long a bounced-back row stays highlighted after a failed completion
    /// (#36).
    static let restoreFlash: TimeInterval = 1.5
    /// Where "Work on in Claude Code" launches by default (#35).
    public static let defaultWorkspaceDirectory = "~/Documents/workspace"

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
    /// optimistic drift. A no-op on a provisional quick-capture row (#37) - its
    /// `temp-` id isn't a real page yet, so a write would 404.
    public func setStatus(taskID: String, to newStatus: String) async {
        guard case .loaded(let current) = state else { return }
        guard let token = tokenStore.read(), !token.isEmpty else { return }
        guard let task = current.first(where: { $0.id == taskID }), !task.isProvisional else { return }
        writeError = nil
        switch await performStatusWrite(taskID: taskID, to: newStatus, token: token) {
        case .success:
            applyStatus(newStatus, to: taskID)
        case .failed:
            writeError = "Couldn't update that task in Notion — it's unchanged. Try again."
        case .unauthorized:
            break // performStatusWrite has already routed to reconnect (#13)
        }
    }

    /// The Notion status PATCH, split out so both the pessimistic `setStatus`
    /// and the optimistic-tick `complete` (#36) share one write path. It does
    /// only the network call and the auth-failure routing; the caller decides
    /// what to do with the row on each outcome. Deliberately does *not* mutate
    /// the task's local status - the callers do that at the right moment, so the
    /// tick can dwell before the row's status actually flips.
    private enum StatusWriteOutcome { case success, failed, unauthorized }
    private func performStatusWrite(taskID: String, to newStatus: String, token: String) async -> StatusWriteOutcome {
        do {
            try await makeClient(token).updateStatus(pageID: taskID, to: newStatus)
            return .success
        } catch NotionClientError.unauthorized {
            // The token died between the load and this write. "Try again" can
            // never succeed, so mirror the load path (issue #13): drop the
            // token and route the user back to entering one.
            try? tokenStore.delete()
            state = .failed("Notion rejected the stored token, so that change wasn't saved. Enter a new token to reconnect.")
            return .unauthorized
        } catch {
            return .failed
        }
    }

    /// Set a task's status in the loaded state and keep the cache in step,
    /// re-reading state each call so it is safe across a write's await
    /// suspension point (issue #12). The mirror of `applyTitle`/`applyPriority`.
    private func applyStatus(_ status: String?, to taskID: String) {
        guard case .loaded(let current) = state else { return }
        let updated = current.map { $0.id == taskID ? $0.withStatus(status) : $0 }
        state = .loaded(updated)
        persistCache(updated)
    }

    /// One-click complete with a visible tick (#36): show the tick at once, hold
    /// it for `completionDwell`, then collapse the row out. The write runs in
    /// parallel behind the dwell; the row's status is flipped to Done only once
    /// the write has *confirmed* and the dwell has elapsed, so the row is never
    /// yanked away mid-tick and a slow write simply extends the dwell rather than
    /// flickering. On failure the row bounces back at its original position with
    /// a highlight flash and the standard write-error banner. Re-clicks while a
    /// task is already dwelling are inert. Both the row checkbox and the row
    /// menu's Status → Done route here, so they behave identically.
    public func complete(taskID: String) async {
        guard case .loaded(let current) = state else { return }
        guard let token = tokenStore.read(), !token.isEmpty else { return }
        guard let task = current.first(where: { $0.id == taskID }) else { return }
        // A provisional row has no real page (#37); an already-Done task has
        // nothing to complete; and once a task is dwelling, further clicks are
        // inert (no undo - a real cancel would need a deferred write).
        guard !task.isProvisional, task.status != "Done" else { return }
        guard pendingCompletion.insert(taskID).inserted else { return }
        let originalStatus = task.status
        writeError = nil
        // Fully optimistic: fire the write but don't block the dwell on it. The
        // row holds its tick for exactly `completionDwell`, whether or not the
        // write has returned.
        let write = Task { await performStatusWrite(taskID: taskID, to: "Done", token: token) }
        await uiSleep(Self.completionDwell)
        // The dwell has elapsed: flip to Done and stop dwelling in one
        // synchronous stretch (no await between), so the view sees a single
        // reflow - the row is Done and no longer force-shown, so it collapses
        // out. This happens regardless of whether the write has landed yet.
        applyStatus("Done", to: taskID)
        pendingCompletion.remove(taskID)
        // Reconcile with the write. A transient failure rolls the row back to
        // its original status - bringing it back at its place - with a flash and
        // the standard banner; an auth failure has already routed to reconnect,
        // so the `applyStatus` above was a guarded no-op against `.failed`.
        switch await write.value {
        case .success:
            break
        case .failed:
            applyStatus(originalStatus, to: taskID)
            flashRestored(taskID)
            writeError = "Couldn't update that task in Notion — it's unchanged. Try again."
        case .unauthorized:
            break
        }
    }

    /// Highlight a bounced-back row briefly after a failed completion (#36),
    /// then clear it. The membership drives the view's tint flash.
    private func flashRestored(_ taskID: String) {
        restoredCompletions.insert(taskID)
        Task { [weak self, uiSleep] in
            await uiSleep(Self.restoreFlash)
            self?.restoredCompletions.remove(taskID)
        }
    }

    /// Start working on a task in Claude Code (#35): flip it to In Progress
    /// unless it's already In Progress or Done, reusing the pessimistic write
    /// path. The iTerm2 launch itself is the shell's job (it needs AppKit and
    /// AppleScript); this owns only the status side, so the skip logic is
    /// testable without a terminal. A no-op on a provisional row (#37).
    public func beginWorking(taskID: String) async {
        guard case .loaded(let current) = state else { return }
        guard let task = current.first(where: { $0.id == taskID }), !task.isProvisional else { return }
        guard task.status != "In Progress", task.status != "Done" else { return }
        await setStatus(taskID: taskID, to: "In Progress")
    }

    /// Change the Claude Code workspace directory (#35): trim, persist, publish.
    /// A blank value is ignored - there'd be nowhere to launch. Mirrors
    /// `setAutoRefreshInterval`.
    public func setClaudeWorkspaceDirectory(_ directory: String) {
        let trimmed = directory.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        claudeWorkspaceDirectory = trimmed
        preferences?.claudeWorkspaceDirectory = trimmed
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
        guard let original = current.first(where: { $0.id == taskID }), !original.isProvisional else { return }
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
        persistCache(updated)
    }

    /// Re-prioritise a task and persist it (#33). Optimistic like `setTitle`:
    /// the row shows the new priority at once (and reflows to its new group),
    /// with the PATCH running behind it; a failure rolls it back. `nil` clears
    /// the priority. Selecting the priority the task already has is a no-op -
    /// no pointless write.
    public func setPriority(taskID: String, to newPriority: String?) async {
        guard case .loaded(let current) = state else { return }
        guard let token = tokenStore.read(), !token.isEmpty else { return }
        guard let original = current.first(where: { $0.id == taskID }), !original.isProvisional else { return }
        guard newPriority != original.priority else { return }
        writeError = nil
        // Show the change immediately; the write catches up.
        applyPriority(newPriority, to: taskID)
        do {
            try await makeClient(token).updatePriority(pageID: taskID, to: newPriority)
            // Re-assert after the await: a refresh may have landed Notion's
            // pre-change copy while the PATCH was in flight (the issue #12 pattern).
            applyPriority(newPriority, to: taskID)
        } catch NotionClientError.unauthorized {
            // The token died between load and write. Roll back, then route to
            // reconnect like every write path (#13).
            applyPriority(original.priority, to: taskID)
            try? tokenStore.delete()
            state = .failed("Notion rejected the stored token, so that change wasn't saved. Enter a new token to reconnect.")
        } catch {
            applyPriority(original.priority, to: taskID)
            writeError = "Couldn't update that task's priority in Notion; it's unchanged. Try again."
        }
    }

    /// Reschedule a task and persist it (#33). The mirror of `setPriority`:
    /// optimistic, with the same rollback and reconnect handling. `nil` clears
    /// the due date. A change to the same calendar day is a no-op - due dates
    /// are date-only, so a different time on the same day isn't worth a write.
    public func setDueDate(taskID: String, to newDueDate: Date?, calendar: Calendar = .current) async {
        guard case .loaded(let current) = state else { return }
        guard let token = tokenStore.read(), !token.isEmpty else { return }
        guard let original = current.first(where: { $0.id == taskID }), !original.isProvisional else { return }
        let sameDay: Bool
        switch (newDueDate, original.dueDate) {
        case (nil, nil): sameDay = true
        case let (new?, old?): sameDay = calendar.isDate(new, inSameDayAs: old)
        default: sameDay = false
        }
        guard !sameDay else { return }
        writeError = nil
        applyDueDate(newDueDate, to: taskID)
        do {
            try await makeClient(token).updateDueDate(pageID: taskID, to: newDueDate)
            applyDueDate(newDueDate, to: taskID)
        } catch NotionClientError.unauthorized {
            applyDueDate(original.dueDate, to: taskID)
            try? tokenStore.delete()
            state = .failed("Notion rejected the stored token, so that change wasn't saved. Enter a new token to reconnect.")
        } catch {
            applyDueDate(original.dueDate, to: taskID)
            writeError = "Couldn't reschedule that task in Notion; its due date is unchanged. Try again."
        }
    }

    /// Set a task's priority in the loaded state and keep the cache in step,
    /// re-reading state each call so it is safe across the write's await
    /// suspension point (#12). The mirror of `applyTitle`.
    private func applyPriority(_ priority: String?, to taskID: String) {
        guard case .loaded(let current) = state else { return }
        let updated = current.map { $0.id == taskID ? $0.withPriority(priority) : $0 }
        state = .loaded(updated)
        persistCache(updated)
    }

    /// Set a task's due date in the loaded state and keep the cache in step,
    /// re-reading state each call (#12). The mirror of `applyPriority`.
    private func applyDueDate(_ dueDate: Date?, to taskID: String) {
        guard case .loaded(let current) = state else { return }
        let updated = current.map { $0.id == taskID ? $0.withDueDate(dueDate) : $0 }
        state = .loaded(updated)
        persistCache(updated)
    }

    /// Save the loaded tasks to the cache, minus any provisional quick-capture
    /// rows (#37): the cache holds only Notion-confirmed tasks, so a crash mid-
    /// capture self-heals on the next poll (the task lands for real) rather than
    /// leaving a ghost row with a fake `temp-` id. A write isn't a fetch, so the
    /// snapshot keeps its fetch time. One boundary for every write path.
    private func persistCache(_ tasks: [NotionTask]) {
        cache?.save(CachedSnapshot(
            tasks: tasks.filter { !$0.isProvisional },
            openStatuses: openStatuses, workCategory: workCategory,
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
            // Keep the cache in step, as setStatus does.
            persistCache(updated)
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

    /// Create a task from the global quick-capture window (#34). Optimistic,
    /// unlike the composer's pessimistic `createTask`: the window has already
    /// closed by the time this runs, so there is no composer state to drive
    /// (`isCreating`/`isComposing`) and no inline error to show. It reuses the
    /// same `NotionClient` create path - no duplicate write logic - and, on
    /// success, threads the new row into the loaded list exactly as `createTask`
    /// does so an open (or soon-to-open) panel shows it at once.
    ///
    /// A failure is stashed in `captureError` to surface on the panel's next
    /// open; a 401 drops the token and routes to reconnect like every write
    /// path (#13). No "not visible in this view" notice: that reassures someone
    /// watching the composer, and here there's no composer and no one watching.
    ///
    /// Optimistic (#37): when a list is already on screen, a provisional row is
    /// inserted *before* the create round-trip so the task appears in the menu
    /// instantly, then swapped for the real task on success or rolled back on
    /// failure. The returned `CaptureOutcome` lets the shell preserve the full
    /// draft for retry when a transient failure loses the row.
    @discardableResult
    public func captureTask(_ draft: TaskDraft) async -> CaptureOutcome {
        guard let token = tokenStore.read(), !token.isEmpty else { return .notCaptured }
        var draft = draft
        draft.title = draft.trimmedTitle
        guard !draft.title.isEmpty else { return .notCaptured }
        captureError = nil

        // Insert a provisional row at once when a list is on screen, so the task
        // shows before the create returns. If nothing is loaded (offline launch,
        // say), skip the optimistic insert: the task is safely created regardless
        // and the next fetch surfaces it. Status defaults to "To Do", the DB
        // default Notion applies (createTask omits Status deliberately); the
        // created time is now so it sorts correctly in Created-desc views.
        let tempID: String?
        if case .loaded(let current) = state {
            let id = "temp-\(UUID().uuidString)"
            let provisional = NotionTask(
                id: id, title: draft.title, status: "To Do",
                priority: draft.priority, dueDate: draft.dueDate, category: draft.category,
                startFrom: nil, createdTime: now(), lastEditedTime: nil, workType: nil, url: nil)
            state = .loaded(current + [provisional])
            tempID = id
        } else {
            tempID = nil
        }
        capturesInFlight += 1
        defer { capturesInFlight -= 1 }
        do {
            let created = try await makeClient(token)
                .createTask(draft, titleProperty: titleProperty)
            // Re-read state after the await (issue #12) and swap the provisional
            // row for the real task, matched by the temp id captured above. If
            // the row is gone (a sign-out, say), append the real task instead.
            guard case .loaded(let current) = state else { return .captured }
            var updated = current
            if let tempID, let index = updated.firstIndex(where: { $0.id == tempID }) {
                updated[index] = created
            } else {
                updated.append(created)
            }
            state = .loaded(updated)
            persistCache(updated)
            return .captured
        } catch NotionClientError.unauthorized {
            // A dead token can't be retried into working; drop it and route to
            // reconnect (#13). The panel's next open shows the token screen, not
            // a banner - there's nothing to capture into until it's reconnected.
            removeProvisional(tempID)
            try? tokenStore.delete()
            state = .failed("Notion rejected the stored token, so that task wasn't created. Enter a new token to reconnect.")
            return .authFailure
        } catch NotionClientError.rateLimited {
            removeProvisional(tempID)
            captureError = "A task you captured wasn't saved - Notion was rate-limiting the app. Try adding it again."
            return .transientFailure
        } catch {
            removeProvisional(tempID)
            captureError = "A task you captured wasn't saved to Notion. Try adding it again."
            return .transientFailure
        }
    }

    /// Roll a provisional quick-capture row back out of the loaded list (#37),
    /// re-reading state so it is safe across the create's await suspension point.
    private func removeProvisional(_ tempID: String?) {
        guard let tempID, case .loaded(let current) = state else { return }
        state = .loaded(current.filter { $0.id != tempID })
    }

    /// The main panel clears a shown capture failure when it closes (#34), so a
    /// later open starts clean unless a fresh capture has failed since.
    public func clearCaptureError() { captureError = nil }

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
                // progress (#28), drop a provisional quick-capture row before
                // its create returns (#37), or flip a task to Done mid-tick
                // (#36). Skip this tick in any of those cases; the next one
                // refreshes once they've settled.
                if self.editingTaskID != nil || self.capturesInFlight > 0
                    || !self.pendingCompletion.isEmpty { continue }
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

    /// Register the current quick-capture shortcut with the service (#34). Call
    /// once at launch, after the shell has wired the service's fire action -
    /// the mirror of `startPolling`, kept separate from `init` so the shell
    /// controls the moment registration (and its side effects) happens.
    public func registerHotKey() {
        hotKeyService?.register(hotKey)
    }

    /// Change the global quick-capture shortcut (#34): validate, persist, and
    /// re-register (the service drops the old registration first). Mirrors
    /// `setAutoRefreshInterval`. An invalid combination is ignored - the
    /// recorder shouldn't offer one, and a modifier-only value must never be
    /// persisted or registered.
    public func setHotKey(_ hotKey: HotKey) {
        guard hotKey.isValid else { return }
        self.hotKey = hotKey
        preferences?.hotKey = hotKey
        hotKeyService?.register(hotKey)
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
    ///
    /// A completing task (#36) stays visible here without a special case: its
    /// real status is left open until `complete` flips it to Done and drops it
    /// from `pendingCompletion` in the same synchronous stretch at the end of
    /// the dwell. So a task is either open-and-dwelling (shown, ticked by
    /// `pendingCompletion`) or Done-and-not-dwelling (filtered out) - never
    /// Done-but-still-ticked - and a failed write rolls the status back so it
    /// reappears. A mid-dwell poll can't flip it either: the poll loop skips
    /// while `pendingCompletion` is non-empty.
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

    /// The still-pending provisional quick-capture rows in the loaded state
    /// (#37), carried across a fetch so an in-flight capture's row survives.
    private func pendingProvisionalRows() -> [NotionTask] {
        guard case .loaded(let current) = state else { return [] }
        return current.filter { $0.isProvisional }
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
            // A quick-capture whose create was already in flight when this fetch
            // started won't be in `tasks` yet (#37). Carry any still-pending
            // provisional rows across the load so a mid-flight fetch doesn't make
            // the row flicker out; the create's own success/rollback reconciles
            // them. The cache save below strips them, so the snapshot stays clean.
            let merged = tasks + pendingProvisionalRows()
            state = .loaded(merged)
            schemaWarning = schemaFailed
                ? "Couldn't load the filter options from Notion - filters and grouping may be out of date."
                : nil
            lastRefreshed = now()
            persistCache(merged)
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
