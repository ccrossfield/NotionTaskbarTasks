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
    /// The active preset. Published so switching it re-renders the list from the
    /// tasks already in hand — no re-fetch (#5). Defaults to Pivotal Priorities.
    @Published public private(set) var preset: Preset = .pivotalPriorities

    private let tokenStore: TokenStore
    private let makeClient: (String) -> NotionClient

    /// Schema-derived facts for the preset filters (ADR-0001). Set from the live
    /// schema on load; the fallbacks apply only if that fetch fails, so the list
    /// never silently empties.
    private var openStatuses: Set<String> = NotionConfig.fallbackOpenStatuses
    private var workCategory: String = NotionConfig.fallbackWorkCategory
    private var personalCategories: Set<String> = NotionConfig.fallbackPersonalCategories

    /// - Parameter makeClient: builds a client for a token. Injected so tests
    ///   can supply a stubbed transport; the app supplies `URLSession`.
    public init(tokenStore: TokenStore, makeClient: @escaping (String) -> NotionClient) {
        self.tokenStore = tokenStore
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
            state = .loaded(tasks.map { task in
                task.id == taskID ? task.withStatus(newStatus) : task
            })
        } catch {
            writeError = "Couldn't update that task in Notion — it's unchanged. Try again."
        }
    }

    /// Re-fetch with the token already stored.
    public func refresh() async {
        writeError = nil
        await start()
    }

    /// Forget the stored token and return to the entry field.
    public func signOut() {
        try? tokenStore.delete()
        state = .needsToken
    }

    /// Switch the visible preset. Changing `preset` republishes, so the view
    /// recomputes `groups()` from the tasks already loaded — no re-fetch (#5).
    public func selectPreset(_ preset: Preset) {
        self.preset = preset
    }

    /// The task list for the active preset: open tasks filtered/sorted/grouped
    /// per the preset (#4/#5). Recomputed from the raw `.loaded` tasks, so both a
    /// status change and a preset switch reflow it for free. `today` is
    /// injectable for tests; the app passes the real date.
    public func groups(today: Date = Date(), calendar: Calendar = .current) -> [TaskGroup] {
        guard case .loaded(let tasks) = state else { return [] }
        return TaskListEngine.groups(
            for: preset, tasks, openStatuses: openStatuses, workCategory: workCategory,
            personalCategories: personalCategories, today: today, calendar: calendar)
    }

    private func load(token: String) async {
        state = .loading
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
            }
            let tasks = try await client.fetchTasks()
            state = .loaded(tasks)
        } catch NotionClientError.unauthorized {
            // The token is bad; drop it so the next launch re-prompts.
            try? tokenStore.delete()
            state = .failed("That token was rejected. Check it and enter it again.")
        } catch let NotionClientError.httpError(code) {
            state = .failed("Notion returned an error (HTTP \(code)). Try again shortly.")
        } catch {
            state = .failed("Couldn't reach Notion. Check your connection and try again.")
        }
    }
}
