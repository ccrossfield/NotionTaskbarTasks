import Foundation
import NotionTasksCore

/// The token-store seam's test double. The app uses `KeychainTokenStore`.
final class InMemoryTokenStore: TokenStore {
    private var token: String?
    init(seed: String? = nil) { self.token = seed }
    func read() -> String? { token }
    func save(_ token: String) throws { self.token = token }
    func delete() throws { token = nil }
}

/// The cache seam's test double: an in-memory snapshot plus a record of every
/// save, so checks can assert what got cached and when.
final class InMemoryTaskCache: TaskCache {
    private(set) var snapshot: CachedSnapshot?
    private(set) var saved: [CachedSnapshot] = []
    private(set) var clearCount = 0

    init(seed: CachedSnapshot? = nil) { self.snapshot = seed }
    func load() -> CachedSnapshot? { snapshot }
    func save(_ snapshot: CachedSnapshot) {
        self.snapshot = snapshot
        saved.append(snapshot)
    }
    func clear() {
        snapshot = nil
        clearCount += 1
    }
}

/// Wraps another stub and holds every request at a gate until `open()` — lets a
/// check observe the model's published state while a fetch is genuinely in
/// flight, not just before and after it.
actor GateHTTPClient: HTTPClient {
    private let inner: HTTPClient
    private var isOpen: Bool
    private var waiters: [CheckedContinuation<Void, Never>] = []

    init(wrapping inner: HTTPClient, open: Bool = false) {
        self.inner = inner
        self.isOpen = open
    }

    func open() {
        isOpen = true
        waiters.forEach { $0.resume() }
        waiters.removeAll()
    }

    func close() { isOpen = false }

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        if !isOpen {
            await withCheckedContinuation { waiters.append($0) }
        }
        return try await inner.data(for: request)
    }
}

/// The preferences seam's test double. The app uses `UserDefaultsPreferences`.
final class InMemoryPreferences: PreferencesStore {
    var autoRefreshInterval: TimeInterval?
    var viewConfig: ViewConfig?
    var collapsedGroups: Set<String>?
    var hotKey: HotKey?
    var panelHotKey: HotKey?
    var claudeWorkspaceDirectory: String?
    init(autoRefreshInterval: TimeInterval? = nil) {
        self.autoRefreshInterval = autoRefreshInterval
    }
}

/// The hotkey seam's test double (#34, #39). The app uses `CarbonHotKeyService`;
/// this records the last combination registered into each of the two fixed slots
/// (quick-capture and show-panel) so a check can assert the model drove them.
final class FakeHotKeyService: HotKeyService {
    private(set) var registered: HotKey?
    private(set) var registeredPanel: HotKey?
    private(set) var registerCount = 0
    private(set) var registerPanelCount = 0
    init() {}
    func register(_ hotKey: HotKey) {
        registered = hotKey
        registerCount += 1
    }
    func registerPanel(_ hotKey: HotKey) {
        registeredPanel = hotKey
        registerPanelCount += 1
    }
    func unregister() { registered = nil; registeredPanel = nil }
}

/// The login-item seam's test double. The app uses `SMAppService` behind
/// `MainAppLoginItem`; this fake stands in for the system registry.
final class FakeLoginItem: LoginItemService {
    var isEnabled: Bool
    var failWith: Error?
    init(isEnabled: Bool = false) { self.isEnabled = isEnabled }
    func setEnabled(_ enabled: Bool) throws {
        if let failWith { throw failWith }
        isEnabled = enabled
    }
}

/// The poll-sleep seam's test double: each call parks until the check releases
/// it with `tick()`, and records the interval it was asked to wait — so a check
/// drives "the interval elapses" explicitly, with no real waiting.
actor PollTicker {
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private(set) var intervals: [TimeInterval] = []

    @Sendable func sleep(_ interval: TimeInterval) async {
        intervals.append(interval)
        await withCheckedContinuation { waiters.append($0) }
    }

    func tick() {
        waiters.forEach { $0.resume() }
        waiters.removeAll()
    }
}

/// The UI-timing seam's test double (#36): like `PollTicker`, each `sleep`
/// parks until released with `tick()`, so a check can hold the completion tick
/// mid-dwell and observe the ticked-but-not-yet-collapsed row before it exits.
actor UITicker {
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private(set) var sleepCount = 0

    @Sendable func sleep(_ interval: TimeInterval) async {
        sleepCount += 1
        await withCheckedContinuation { waiters.append($0) }
    }

    func tick() {
        waiters.forEach { $0.resume() }
        waiters.removeAll()
    }
}

/// A transport that always throws — the "no network" case, which URLSession
/// reports as a thrown error, never as an HTTP status.
struct ThrowingHTTPClient: HTTPClient {
    let error: Error
    func data(for request: URLRequest) async throws -> (Data, URLResponse) { throw error }
}

/// Delegates to a stub until `error` is set, then throws it — lets a check load
/// normally and only then pull the network out.
final class SwitchableHTTPClient: HTTPClient {
    var error: Error?
    private let inner: HTTPClient
    init(wrapping inner: HTTPClient) { self.inner = inner }
    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        if let error { throw error }
        return try await inner.data(for: request)
    }
}

/// Delegates to a stub until `parkRequests` is set; then a request hangs like
/// a slow network call and, when its surrounding task is cancelled, throws
/// `URLError(.cancelled)` — mirroring what `URLSession.data(for:)` does to an
/// in-flight request (#27).
final class CancellableParkingHTTPClient: HTTPClient {
    var parkRequests = false
    private(set) var parkedCount = 0
    private let inner: HTTPClient
    init(wrapping inner: HTTPClient) { self.inner = inner }
    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        if parkRequests {
            parkedCount += 1
            do {
                while true { try await Task.sleep(nanoseconds: 1_000_000) }
            } catch {
                throw URLError(.cancelled)
            }
        }
        return try await inner.data(for: request)
    }
}

/// Wraps another stub and holds only PATCH requests at a gate, letting reads
/// straight through — so a check can land a full refresh (or a second write's
/// read of the state) while a status write is still in flight.
actor PatchGateHTTPClient: HTTPClient {
    private let inner: HTTPClient
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    init(wrapping inner: HTTPClient) { self.inner = inner }

    func open() {
        isOpen = true
        waiters.forEach { $0.resume() }
        waiters.removeAll()
    }

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        if request.httpMethod == "PATCH", !isOpen {
            await withCheckedContinuation { waiters.append($0) }
        }
        return try await inner.data(for: request)
    }
}

/// Holds only the create (POST /v1/pages) at a gate, letting reads and other
/// writes straight through (#37) - so a check can observe the provisional row
/// while its create is in flight, and land a full refresh across it.
actor CreateGateHTTPClient: HTTPClient {
    private let inner: HTTPClient
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    init(wrapping inner: HTTPClient) { self.inner = inner }

    func open() {
        isOpen = true
        waiters.forEach { $0.resume() }
        waiters.removeAll()
    }

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        if request.httpMethod == "POST",
           request.url?.absoluteString.hasSuffix("/pages") == true, !isOpen {
            await withCheckedContinuation { waiters.append($0) }
        }
        return try await inner.data(for: request)
    }
}

/// Routes the schema GET vs the query POST to different canned bodies, so a full
/// `AppModel.load` (which fetches both) can be exercised through the seam.
/// `schemaStatusCode` lets a check fail the schema route while queries succeed (#14).
/// The create route (POST /v1/pages, #22) replays `create`/`createStatusCode`;
/// `requests` records everything received so a check can assert what was
/// (or was not) sent.
final class RoutingStubHTTPClient: HTTPClient {
    let schema: Data
    var query: Data
    var schemaStatusCode = 200
    var create = Data()
    var createStatusCode = 200
    private(set) var requests: [URLRequest] = []
    init(schema: Data, query: Data) { self.schema = schema; self.query = query }

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        requests.append(request)
        let url = request.url?.absoluteString ?? ""
        let body: Data
        let status: Int
        if url.hasSuffix("/query") {
            (body, status) = (query, 200)
        } else if url.hasSuffix("/pages"), request.httpMethod == "POST" {
            (body, status) = (create, createStatusCode)
        } else {
            (body, status) = (schema, schemaStatusCode)
        }
        let response = HTTPURLResponse(
            url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
        return (body, response)
    }
}

@MainActor
func appModelChecks(_ t: CheckRun) async {
    t.suite("AppModel wiring")
    let ds = "e19b11fa-a660-4de2-8482-b840210db08f"

    await t.test("with no stored token it needs a token and does not fetch") {
        let store = InMemoryTokenStore()
        var builtClient = false
        let model = AppModel(tokenStore: store) { token in
            builtClient = true
            return NotionClient(dataSourceID: ds, token: token,
                                http: StubHTTPClient(responseData: Data(), statusCode: 200))
        }

        await model.start()

        t.expectEqual(model.state, .needsToken)
        t.expect(!builtClient, "should not build a client when there is no token")
    }

    await t.test("submitting a valid token saves it to the store and loads tasks") {
        let store = InMemoryTokenStore()
        let stub = StubHTTPClient(responseData: try fixtureData("query_response"), statusCode: 200)
        let model = AppModel(tokenStore: store) { NotionClient(dataSourceID: ds, token: $0, http: stub) }

        await model.submit(token: "ntn_good")

        t.expect(store.read() == "ntn_good", "token should be persisted, was \(store.read() ?? "nil")")
        if case .loaded(let tasks) = model.state {
            t.expectEqual(tasks.count, 5)
        } else {
            t.expect(false, "expected .loaded, got \(model.state)")
        }
    }

    await t.test("a stored token loads on launch without prompting") {
        let store = InMemoryTokenStore(seed: "ntn_saved")
        let stub = StubHTTPClient(responseData: try fixtureData("query_response"), statusCode: 200)
        let model = AppModel(tokenStore: store) { NotionClient(dataSourceID: ds, token: $0, http: stub) }

        await model.start()

        if case .loaded = model.state {} else {
            t.expect(false, "expected .loaded, got \(model.state)")
        }
    }

    await t.test("a rejected token is cleared so the user is asked to re-enter") {
        let store = InMemoryTokenStore()
        let stub = StubHTTPClient(responseData: Data("{}".utf8), statusCode: 401)
        let model = AppModel(tokenStore: store) { NotionClient(dataSourceID: ds, token: $0, http: stub) }

        await model.submit(token: "ntn_bad")

        t.expect(store.read() == nil, "a rejected token should be cleared, was \(store.read() ?? "nil")")
        if case .failed = model.state {} else {
            t.expect(false, "expected .failed, got \(model.state)")
        }
    }

    let firstTaskID = "11111111-0000-0000-0000-000000000001" // "Wire up…", status "In Progress"

    await t.test("setStatus reflects the new status on the row after a successful write") {
        let store = InMemoryTokenStore()
        let stub = StubHTTPClient(responseData: try fixtureData("query_response"), statusCode: 200)
        let model = AppModel(tokenStore: store) { NotionClient(dataSourceID: ds, token: $0, http: stub) }
        await model.submit(token: "ntn_good")

        await model.setStatus(taskID: firstTaskID, to: "Done")

        guard case .loaded(let tasks) = model.state else {
            t.expect(false, "expected .loaded, got \(model.state)"); return
        }
        let changed = try require(tasks.first { $0.id == firstTaskID })
        t.expect(changed.status == "Done", "row status was \(changed.status ?? "nil")")
        t.expect(stub.lastRequest?.httpMethod == "PATCH", "a PATCH should have been sent")
        t.expect(model.writeError == nil, "no write error expected")
    }

    await t.test("completing a task sets it to Done and preserves its other fields") {
        let store = InMemoryTokenStore()
        let stub = StubHTTPClient(responseData: try fixtureData("query_response"), statusCode: 200)
        let model = AppModel(tokenStore: store) { NotionClient(dataSourceID: ds, token: $0, http: stub) }
        await model.submit(token: "ntn_good")

        // tasks[1]: "Draft the Q3 board update", To Do, P0, due 2026-07-02, Work.
        let todoID = "11111111-0000-0000-0000-000000000002"
        await model.setStatus(taskID: todoID, to: "Done")

        guard case .loaded(let tasks) = model.state else {
            t.expect(false, "expected .loaded, got \(model.state)"); return
        }
        let done = try require(tasks.first { $0.id == todoID })
        t.expect(done.status == "Done", "status was \(done.status ?? "nil")")
        // The status change must not wipe the row's other fields.
        t.expect(done.priority == "P0", "priority drifted to \(String(describing: done.priority))")
        t.expect(done.category == "👨🏻‍💻 Work", "category drifted to \(done.category ?? "nil")")
        t.expect(done.dueDate != nil, "due date was dropped on status change")
        t.expectEqual(
            done.url,
            "https://www.notion.so/Draft-the-Q3-board-update-11111111000000000000000000000002")
    }

    await t.test("after loading, Pivotal Priorities groups open Work tasks by schema-derived open set") {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "Europe/London")!
        let today = cal.date(from: DateComponents(year: 2026, month: 7, day: 15, hour: 12))!

        let store = InMemoryTokenStore()
        let stub = RoutingStubHTTPClient(
            schema: try fixtureData("data_source_schema"),
            query: try fixtureData("query_response"))
        let model = AppModel(tokenStore: store) { NotionClient(dataSourceID: ds, token: $0, http: stub) }

        await model.submit(token: "ntn_good")
        let groups = model.groups(today: today, calendar: cal)

        // Of the 5 fixture tasks, only the two open Work tasks qualify (both are
        // surfaced by this date). "Draft the Q3 board update" is P0, "Wire up the
        // menu bar read path" is P1. The Blocked/Done/untitled ones are excluded
        // by category or by the schema-derived open set (Done is not open).
        t.expectEqual(groups.map(\.priority), ["P0", "P1"])
        t.expectEqual(groups.first?.tasks.map(\.title), ["Draft the Q3 board update"])
        t.expect(groups.count == 2 && groups[1].tasks.map(\.title) == ["Wire up the menu bar read path"],
                 "P1 group should hold the one open Work P1 task")
    }

    await t.test("switching preset re-filters the loaded tasks immediately, with no re-fetch") {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "Europe/London")!
        let today = cal.date(from: DateComponents(year: 2026, month: 7, day: 15, hour: 12))!

        let store = InMemoryTokenStore()
        let stub = RoutingStubHTTPClient(
            schema: try fixtureData("data_source_schema"),
            query: try fixtureData("query_response"))
        let model = AppModel(tokenStore: store) { NotionClient(dataSourceID: ds, token: $0, http: stub) }
        await model.submit(token: "ntn_good")

        // Default preset is Pivotal Priorities: the two open Work tasks, P0/P1.
        t.expectEqual(model.preset, .pivotalPriorities)
        t.expectEqual(model.groups(today: today, calendar: cal).map(\.priority), ["P0", "P1"])

        // All open brings back the personal Blocked task Pivotal filtered out, as
        // a single flat group in Created-descending order — no re-fetch involved.
        model.selectPreset(.allOpen)
        let all = model.groups(today: today, calendar: cal)
        t.expectEqual(all.count, 1)
        t.expectEqual(all.first?.tasks.map(\.title),
                      ["Draft the Q3 board update",      // created 2026-06-02
                       "Wire up the menu bar read path",  // created 2026-06-01
                       "Chase vendor on renewal quote"])  // created 2026-05-20

        // Home priorities: the personal-category task, grouped by priority.
        model.selectPreset(.homePriorities)
        let home = model.groups(today: today, calendar: cal)
        t.expectEqual(home.map(\.priority), ["P2"])
        t.expectEqual(home.first?.tasks.map(\.title), ["Chase vendor on renewal quote"])
    }

    await t.test("filter option lists are derived from the fetched schema") {
        let store = InMemoryTokenStore()
        let stub = RoutingStubHTTPClient(
            schema: try fixtureData("data_source_schema"),
            query: try fixtureData("query_response"))
        let model = AppModel(tokenStore: store) { NotionClient(dataSourceID: ds, token: $0, http: stub) }
        await model.submit(token: "ntn_good")

        let options = model.schemaOptions
        t.expect(options.statuses.contains("Done"), "custom filter can pick any status, including Done")
        t.expectEqual(options.workTypes.count, 9)
        t.expect(options.workTypes.contains("PIVOT"), "WorkType options come from the schema")
        t.expect(options.categories.contains("👨🏻‍💻 Work"), "categories come from the schema")
    }

    await t.test("entering a custom view filters the loaded tasks, and a preset restores it") {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "Europe/London")!
        let today = cal.date(from: DateComponents(year: 2026, month: 7, day: 15, hour: 12))!

        let store = InMemoryTokenStore()
        let stub = RoutingStubHTTPClient(
            schema: try fixtureData("data_source_schema"),
            query: try fixtureData("query_response"))
        let model = AppModel(tokenStore: store) { NotionClient(dataSourceID: ds, token: $0, http: stub) }
        await model.submit(token: "ntn_good")

        t.expect(!model.isCustom, "loads into a preset, not a custom view")

        // Custom: WorkType == Strategy → only the one Strategy task, flat.
        model.enterCustom()
        model.updateCustom(CustomQuery(workTypes: ["Strategy"]))
        t.expect(model.isCustom, "should be in the custom view")
        let custom = model.groups(today: today, calendar: cal)
        t.expectEqual(custom.count, 1)
        t.expectEqual(custom.first?.tasks.map(\.title), ["Wire up the menu bar read path"])

        // Selecting a preset leaves custom mode and restores the preset grouping.
        model.selectPreset(.pivotalPriorities)
        t.expect(!model.isCustom, "picking a preset should leave the custom view")
        t.expectEqual(model.groups(today: today, calendar: cal).map(\.priority), ["P0", "P1"])
    }

    t.suite("AppModel caching and background refresh")

    await t.test("a cached snapshot renders instantly on launch, then fresh data replaces it") {
        let store = InMemoryTokenStore(seed: "ntn_saved")
        let snapshot = sampleSnapshot() // two cached tasks, ids c1/c2
        let cache = InMemoryTaskCache(seed: snapshot)
        let gate = GateHTTPClient(wrapping: RoutingStubHTTPClient(
            schema: try fixtureData("data_source_schema"),
            query: try fixtureData("query_response")))
        let model = AppModel(tokenStore: store, cache: cache) {
            NotionClient(dataSourceID: ds, token: $0, http: gate)
        }

        let launch = Task { await model.start() }
        var spins = 0
        while model.state != .loaded(snapshot.tasks), spins < 500 {
            await Task.yield(); spins += 1
        }
        // The cached tasks are on screen while the fetch is still held at the gate.
        t.expectEqual(model.state, .loaded(snapshot.tasks))

        await gate.open()
        await launch.value

        // The fetch's five fixture tasks replaced the two cached ones.
        if case .loaded(let tasks) = model.state {
            t.expectEqual(tasks.count, 5)
        } else {
            t.expect(false, "expected fresh .loaded, got \(model.state)")
        }
    }

    await t.test("cached schema facts filter the cached tasks before the fetch returns") {
        // A category that exists only in the snapshot — not in the fallbacks and
        // not in the schema fixture. If the model filtered with fallback facts,
        // this task would vanish from Home priorities until the fetch landed.
        let labTask = NotionTask(id: "lab1", title: "Calibrate the spectrometer",
                                 status: "To Do", priority: "P2", category: "🧪 Lab")
        let snapshot = CachedSnapshot(
            tasks: [labTask],
            openStatuses: ["To Do"],
            workCategory: "👨🏻‍💻 Work",
            personalCategories: ["🧪 Lab"],
            schemaOptions: SchemaOptions(statuses: ["To Do"], categories: ["🧪 Lab"],
                                         priorities: ["P2"], workTypes: []),
            fetchedAt: Date(timeIntervalSince1970: 1_751_500_000))
        let store = InMemoryTokenStore(seed: "ntn_saved")
        let cache = InMemoryTaskCache(seed: snapshot)
        let gate = GateHTTPClient(wrapping: RoutingStubHTTPClient(
            schema: try fixtureData("data_source_schema"),
            query: try fixtureData("query_response")))
        let model = AppModel(tokenStore: store, cache: cache) {
            NotionClient(dataSourceID: ds, token: $0, http: gate)
        }

        let launch = Task { await model.start() }
        var spins = 0
        while model.state != .loaded(snapshot.tasks), spins < 500 {
            await Task.yield(); spins += 1
        }
        model.selectPreset(.homePriorities)

        // Still gated: grouping must use the snapshot's personal categories and
        // open set, and the custom filter lists must come from the snapshot too.
        t.expectEqual(model.groups().flatMap(\.tasks).map(\.id), ["lab1"])
        t.expectEqual(model.schemaOptions.categories, ["🧪 Lab"])

        await gate.open()
        await launch.value
    }

    await t.test("grouped presets order priority sections by the snapshot's schema facts, not the fallback (#15)") {
        // Priorities that exist only in the snapshot's schema facts, in an order
        // alphabetical sorting would get wrong. If the model grouped with the
        // compile-time fallback (P0/P1/P2), the unknown-name rule would render
        // Alpha before Zed; the snapshot's schema order says Zed first.
        let work = "👨🏻‍💻 Work"
        let snapshot = CachedSnapshot(
            tasks: [
                NotionTask(id: "a1", title: "Alpha task", status: "To Do",
                           priority: "Alpha", category: work),
                NotionTask(id: "z1", title: "Zed task", status: "To Do",
                           priority: "Zed", category: work),
            ],
            openStatuses: ["To Do"],
            workCategory: work,
            personalCategories: ["📝 Life admin"],
            schemaOptions: SchemaOptions(statuses: ["To Do"], categories: [work],
                                         priorities: ["Zed", "Alpha"], workTypes: []),
            fetchedAt: Date(timeIntervalSince1970: 1_751_500_000))
        let store = InMemoryTokenStore(seed: "ntn_saved")
        let cache = InMemoryTaskCache(seed: snapshot)
        let gate = GateHTTPClient(wrapping: RoutingStubHTTPClient(
            schema: try fixtureData("data_source_schema"),
            query: try fixtureData("query_response")))
        let model = AppModel(tokenStore: store, cache: cache) {
            NotionClient(dataSourceID: ds, token: $0, http: gate)
        }

        let launch = Task { await model.start() }
        var spins = 0
        while model.state != .loaded(snapshot.tasks), spins < 500 {
            await Task.yield(); spins += 1
        }
        t.expectEqual(model.groups().map(\.priority), ["Zed", "Alpha"])

        await gate.open()
        await launch.value
    }

    await t.test("a successful fetch is saved to the cache for the next launch") {
        let store = InMemoryTokenStore()
        let cache = InMemoryTaskCache()
        let stub = RoutingStubHTTPClient(
            schema: try fixtureData("data_source_schema"),
            query: try fixtureData("query_response"))
        let fixedNow = Date(timeIntervalSince1970: 1_751_600_000)
        let model = AppModel(tokenStore: store, cache: cache, now: { fixedNow }) {
            NotionClient(dataSourceID: ds, token: $0, http: stub)
        }

        await model.submit(token: "ntn_good")

        let saved = try require(cache.saved.last)
        t.expectEqual(saved.tasks.count, 5)
        t.expectEqual(saved.openStatuses, ["To Do", "In Progress", "Blocked"])
        t.expectEqual(saved.workCategory, "👨🏻‍💻 Work")
        t.expectEqual(saved.personalCategories,
                      ["👥 Friends & Family", "📝 Life admin", "💻 Tech & Projects", "🎉 Fun admin"])
        t.expectEqual(saved.fetchedAt, fixedNow)
    }

    // One fresh task, enough for a refresh to return something distinguishable
    // from the five fixture tasks.
    let freshQueryJSON = Data("""
    {
      "object": "list",
      "results": [{
        "id": "fresh1",
        "properties": { "Task": { "type": "title", "title": [{ "plain_text": "Fresh task" }] } }
      }],
      "has_more": false,
      "next_cursor": null
    }
    """.utf8)

    await t.test("a refresh keeps the current list visible - no spinner - until fresh data lands") {
        let store = InMemoryTokenStore(seed: "ntn_saved")
        let routing = RoutingStubHTTPClient(
            schema: try fixtureData("data_source_schema"),
            query: try fixtureData("query_response"))
        let gate = GateHTTPClient(wrapping: routing, open: true)
        let model = AppModel(tokenStore: store) {
            NotionClient(dataSourceID: ds, token: $0, http: gate)
        }
        await model.start()
        guard case .loaded(let original) = model.state else {
            t.expect(false, "expected .loaded, got \(model.state)"); return
        }

        routing.query = freshQueryJSON
        await gate.close()
        let refresh = Task { await model.refresh() }
        var sawBlank = false
        for _ in 0..<50 {
            await Task.yield()
            if model.state != .loaded(original) { sawBlank = true }
        }
        t.expect(!sawBlank, "the old list must stay on screen while the refresh is in flight")

        await gate.open()
        await refresh.value

        if case .loaded(let tasks) = model.state {
            t.expectEqual(tasks.map(\.title), ["Fresh task"])
        } else {
            t.expect(false, "expected fresh .loaded, got \(model.state)")
        }
    }

    await t.test("a failed refresh keeps the list on screen and surfaces a refresh error") {
        let store = InMemoryTokenStore(seed: "ntn_saved")
        let stub = StubHTTPClient(responseData: try fixtureData("query_response"), statusCode: 200)
        let model = AppModel(tokenStore: store) { NotionClient(dataSourceID: ds, token: $0, http: stub) }
        await model.start()
        guard case .loaded(let original) = model.state else {
            t.expect(false, "expected .loaded, got \(model.state)"); return
        }

        stub.statusCode = 500
        await model.refresh()

        t.expectEqual(model.state, .loaded(original))
        t.expect(model.refreshError != nil, "a failed refresh should tell the user the list is stale")

        // The next successful refresh clears the message.
        stub.statusCode = 200
        await model.refresh()
        t.expect(model.refreshError == nil, "a successful refresh should clear the error")
    }

    await t.test("a 401 during refresh still clears the token and interrupts, even with data on screen") {
        let store = InMemoryTokenStore(seed: "ntn_saved")
        let stub = StubHTTPClient(responseData: try fixtureData("query_response"), statusCode: 200)
        let model = AppModel(tokenStore: store) { NotionClient(dataSourceID: ds, token: $0, http: stub) }
        await model.start()

        stub.statusCode = 401
        await model.refresh()

        t.expect(store.read() == nil, "a rejected token must be cleared")
        if case .failed = model.state {} else {
            t.expect(false, "a revoked token must interrupt - stale data can't be written back")
        }
    }

    await t.test("lastRefreshed reports the fetch time, or the snapshot's age when showing cached data") {
        // Cached launch: while the fetch is gated, the timestamp is the
        // snapshot's — the data really is that old.
        let snapshot = sampleSnapshot() // fetchedAt 1_751_500_000
        let store = InMemoryTokenStore(seed: "ntn_saved")
        let gate = GateHTTPClient(wrapping: RoutingStubHTTPClient(
            schema: try fixtureData("data_source_schema"),
            query: try fixtureData("query_response")))
        let fixedNow = Date(timeIntervalSince1970: 1_751_600_000)
        let model = AppModel(tokenStore: store, cache: InMemoryTaskCache(seed: snapshot),
                             now: { fixedNow }) {
            NotionClient(dataSourceID: ds, token: $0, http: gate)
        }

        let launch = Task { await model.start() }
        var spins = 0
        while model.state != .loaded(snapshot.tasks), spins < 500 {
            await Task.yield(); spins += 1
        }
        t.expectEqual(model.lastRefreshed, snapshot.fetchedAt)

        // Once the fetch lands, the timestamp is the fetch's.
        await gate.open()
        await launch.value
        t.expectEqual(model.lastRefreshed, fixedNow)
    }

    await t.test("a status change is written back to the cache so a relaunch doesn't resurrect it") {
        let store = InMemoryTokenStore()
        let cache = InMemoryTaskCache()
        let stub = StubHTTPClient(responseData: try fixtureData("query_response"), statusCode: 200)
        let fetchTime = Date(timeIntervalSince1970: 1_751_600_000)
        var clock = fetchTime
        let model = AppModel(tokenStore: store, cache: cache, now: { clock }) {
            NotionClient(dataSourceID: ds, token: $0, http: stub)
        }
        await model.submit(token: "ntn_good")
        let savesAfterFetch = cache.saved.count

        clock = fetchTime.addingTimeInterval(600) // ten minutes pass
        await model.setStatus(taskID: firstTaskID, to: "Done")

        let saved = try require(cache.saved.last)
        t.expect(cache.saved.count == savesAfterFetch + 1, "the write should update the cache")
        t.expect(saved.tasks.first { $0.id == firstTaskID }?.status == "Done",
                 "the cached copy should carry the new status")
        // A write is not a fetch: the snapshot's age must not be restamped.
        t.expectEqual(saved.fetchedAt, fetchTime)
    }

    await t.test("signing out clears the cached snapshot along with the token") {
        let store = InMemoryTokenStore(seed: "ntn_saved")
        let cache = InMemoryTaskCache(seed: sampleSnapshot())
        let stub = StubHTTPClient(responseData: try fixtureData("query_response"), statusCode: 200)
        let model = AppModel(tokenStore: store, cache: cache) {
            NotionClient(dataSourceID: ds, token: $0, http: stub)
        }

        model.signOut()

        t.expect(store.read() == nil, "the token should be gone")
        t.expect(cache.load() == nil, "the cached tasks should be gone with it")
    }

    await t.test("the list counts as stale only when over a minute old") {
        let store = InMemoryTokenStore()
        let stub = StubHTTPClient(responseData: try fixtureData("query_response"), statusCode: 200)
        let fetchTime = Date(timeIntervalSince1970: 1_751_600_000)
        let model = AppModel(tokenStore: store, now: { fetchTime }) {
            NotionClient(dataSourceID: ds, token: $0, http: stub)
        }

        // Nothing fetched yet: nothing to be stale about.
        t.expect(!model.isStale(asOf: fetchTime), "no data yet should not read as stale")

        await model.submit(token: "ntn_good")

        t.expect(!model.isStale(asOf: fetchTime.addingTimeInterval(59)),
                 "59s old is not over a minute")
        t.expect(!model.isStale(asOf: fetchTime.addingTimeInterval(60)),
                 "exactly a minute is not OVER a minute")
        t.expect(model.isStale(asOf: fetchTime.addingTimeInterval(61)),
                 "61s old is over a minute")
    }

    await t.test("a failed write leaves the row unchanged and surfaces an error") {
        let store = InMemoryTokenStore()
        let stub = StubHTTPClient(responseData: try fixtureData("query_response"), statusCode: 200)
        let model = AppModel(tokenStore: store) { NotionClient(dataSourceID: ds, token: $0, http: stub) }
        await model.submit(token: "ntn_good")
        stub.statusCode = 500 // the write will fail

        await model.setStatus(taskID: firstTaskID, to: "Done")

        guard case .loaded(let tasks) = model.state else {
            t.expect(false, "expected .loaded, got \(model.state)"); return
        }
        let unchanged = try require(tasks.first { $0.id == firstTaskID })
        t.expect(unchanged.status == "In Progress", "status drifted to \(unchanged.status ?? "nil")")
        t.expect(model.writeError != nil, "a failed write should surface an error")
    }

    t.suite("AppModel menu bar niceties")

    await t.test("the menu bar count is the open late-or-due-today tasks, whatever view is active") {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "Europe/London")!
        let today = cal.date(from: DateComponents(year: 2026, month: 7, day: 15, hour: 12))!

        let store = InMemoryTokenStore(seed: "ntn_saved")
        let stub = RoutingStubHTTPClient(
            schema: try fixtureData("data_source_schema"),
            query: try fixtureData("query_response"))
        let model = AppModel(tokenStore: store) { NotionClient(dataSourceID: ds, token: $0, http: stub) }

        t.expectEqual(model.lateOrDueTodayCount(today: today, calendar: cal), 0) // nothing loaded yet

        await model.start()

        // Of the five fixture tasks, exactly two are open with a due date on or
        // before 2026-07-15: "Wire up…" (In Progress, due 28 Jun) and "Draft
        // the Q3 board update" (To Do, due 2 Jul). Blocked-with-no-due, Done,
        // and statusless tasks don't count.
        t.expectEqual(model.lateOrDueTodayCount(today: today, calendar: cal), 2)

        // The badge is about what needs attention, not about what's on screen.
        model.selectPreset(.homePriorities)
        t.expectEqual(model.lateOrDueTodayCount(today: today, calendar: cal), 2)
    }

    await t.test("toggling launch at login drives the service and mirrors its state") {
        let store = InMemoryTokenStore(seed: "ntn_saved")
        let stub = StubHTTPClient(responseData: try fixtureData("query_response"), statusCode: 200)
        let loginItem = FakeLoginItem()
        let model = AppModel(tokenStore: store, loginItem: loginItem) {
            NotionClient(dataSourceID: ds, token: $0, http: stub)
        }
        t.expect(!model.launchAtLogin, "starts reflecting the disabled service")

        model.setLaunchAtLogin(true)
        t.expect(loginItem.isEnabled, "the service should be registered")
        t.expect(model.launchAtLogin, "the toggle should read as on")

        model.setLaunchAtLogin(false)
        t.expect(!loginItem.isEnabled, "the service should be unregistered")
        t.expect(!model.launchAtLogin, "the toggle should read as off")
    }

    await t.test("an already-registered login item reads as enabled on launch") {
        let store = InMemoryTokenStore(seed: "ntn_saved")
        let stub = StubHTTPClient(responseData: try fixtureData("query_response"), statusCode: 200)
        let model = AppModel(tokenStore: store, loginItem: FakeLoginItem(isEnabled: true)) {
            NotionClient(dataSourceID: ds, token: $0, http: stub)
        }
        t.expect(model.launchAtLogin, "the persisted system setting is the source of truth")
    }

    await t.test("a failed registration leaves the toggle truthful, not wishful") {
        let store = InMemoryTokenStore(seed: "ntn_saved")
        let stub = StubHTTPClient(responseData: try fixtureData("query_response"), statusCode: 200)
        let loginItem = FakeLoginItem()
        loginItem.failWith = CheckError(description: "SMAppService says no")
        let model = AppModel(tokenStore: store, loginItem: loginItem) {
            NotionClient(dataSourceID: ds, token: $0, http: stub)
        }

        model.setLaunchAtLogin(true)

        t.expect(!model.launchAtLogin, "the toggle must not claim a registration that failed")
        t.expect(!loginItem.isEnabled, "the service is still disabled")
    }

    t.suite("AppModel remembered setup")

    await t.test("the last-used preset is restored before the first fetch renders") {
        let prefs = InMemoryPreferences()
        prefs.viewConfig = ViewConfig(preset: .lateOrDueToday, isCustom: false,
                                      customQuery: .empty)
        let store = InMemoryTokenStore(seed: "ntn_saved")
        let stub = StubHTTPClient(responseData: try fixtureData("query_response"), statusCode: 200)
        let model = AppModel(tokenStore: store, preferences: prefs) {
            NotionClient(dataSourceID: ds, token: $0, http: stub)
        }

        // No fetch has run yet: the remembered view is already active.
        t.expectEqual(model.preset, .lateOrDueToday)
        t.expect(!model.isCustom, "a preset launch stays a preset launch")
        t.expectEqual(stub.requestCount, 0)
    }

    await t.test("a custom filter and its sort order are restored across restarts") {
        let rememberedQuery = CustomQuery(workTypes: ["PIVOT"], sortField: .created, ascending: false)
        let prefs = InMemoryPreferences()
        prefs.viewConfig = ViewConfig(preset: .pivotalPriorities, isCustom: true,
                                      customQuery: rememberedQuery)
        let store = InMemoryTokenStore(seed: "ntn_saved")
        let stub = StubHTTPClient(responseData: try fixtureData("query_response"), statusCode: 200)
        let model = AppModel(tokenStore: store, preferences: prefs) {
            NotionClient(dataSourceID: ds, token: $0, http: stub)
        }

        t.expect(model.isCustom, "the app should reopen in the custom view it was left in")
        t.expectEqual(model.customQuery, rememberedQuery)
    }

    await t.test("preset, custom mode, and query changes are persisted for the next launch") {
        let prefs = InMemoryPreferences()
        let store = InMemoryTokenStore(seed: "ntn_saved")
        let stub = StubHTTPClient(responseData: try fixtureData("query_response"), statusCode: 200)
        let model = AppModel(tokenStore: store, preferences: prefs) {
            NotionClient(dataSourceID: ds, token: $0, http: stub)
        }
        await model.start()

        model.selectPreset(.homePriorities)
        t.expectEqual(prefs.viewConfig?.preset, .homePriorities)
        t.expectEqual(prefs.viewConfig?.isCustom, false)

        model.enterCustom()
        t.expectEqual(prefs.viewConfig?.isCustom, true)

        let query = CustomQuery(statuses: ["Blocked"], sortField: .lastEdited, ascending: true)
        model.updateCustom(query)
        t.expectEqual(prefs.viewConfig?.customQuery, query)

        model.selectPreset(.allOpen) // leaving custom is remembered too
        t.expectEqual(prefs.viewConfig?.preset, .allOpen)
        t.expectEqual(prefs.viewConfig?.isCustom, false)
    }

    t.suite("AppModel refresh liveness")

    await t.test("isRefreshing is true only while a fetch is in flight, with the list kept visible") {
        let store = InMemoryTokenStore(seed: "ntn_saved")
        let gate = GateHTTPClient(wrapping: RoutingStubHTTPClient(
            schema: try fixtureData("data_source_schema"),
            query: try fixtureData("query_response")), open: true)
        let model = AppModel(tokenStore: store) {
            NotionClient(dataSourceID: ds, token: $0, http: gate)
        }
        await model.start()
        t.expect(!model.isRefreshing, "nothing is in flight after the load completes")
        guard case .loaded(let original) = model.state else {
            t.expect(false, "expected .loaded, got \(model.state)"); return
        }

        await gate.close()
        let refresh = Task { await model.refresh() }
        var spins = 0
        while !model.isRefreshing, spins < 500 { await Task.yield(); spins += 1 }
        t.expect(model.isRefreshing, "an in-flight refresh should be indicated")
        t.expectEqual(model.state, .loaded(original)) // no blank flash behind the indicator

        await gate.open()
        await refresh.value
        t.expect(!model.isRefreshing, "the indicator must clear once the fetch lands")
    }

    await t.test("a failed refresh also clears the in-flight indicator") {
        let store = InMemoryTokenStore(seed: "ntn_saved")
        let stub = StubHTTPClient(responseData: try fixtureData("query_response"), statusCode: 200)
        let model = AppModel(tokenStore: store) { NotionClient(dataSourceID: ds, token: $0, http: stub) }
        await model.start()

        stub.statusCode = 500
        await model.refresh()

        t.expect(!model.isRefreshing, "a failed fetch must not leave the indicator spinning")
    }

    await t.test("auto-refresh re-fetches each time the configured interval elapses") {
        let store = InMemoryTokenStore(seed: "ntn_saved")
        let stub = StubHTTPClient(responseData: try fixtureData("query_response"), statusCode: 200)
        let ticker = PollTicker()
        let model = AppModel(tokenStore: store, pollSleep: ticker.sleep) {
            NotionClient(dataSourceID: ds, token: $0, http: stub)
        }
        await model.start()
        let fetchesAfterLoad = stub.requestCount

        model.startPolling(every: 120)
        var spins = 0
        while await ticker.intervals.isEmpty, spins < 500 { await Task.yield(); spins += 1 }
        t.expectEqual(stub.requestCount, fetchesAfterLoad) // parked: nothing until the interval elapses
        t.expectEqual(await ticker.intervals.first, 120)

        await ticker.tick() // the interval elapses
        spins = 0
        while stub.requestCount == fetchesAfterLoad, spins < 500 { await Task.yield(); spins += 1 }
        t.expect(stub.requestCount > fetchesAfterLoad, "an elapsed interval should re-fetch")

        // The loop parks again for the next cycle at the same cadence.
        spins = 0
        while await ticker.intervals.count < 2, spins < 500 { await Task.yield(); spins += 1 }
        t.expectEqual(await ticker.intervals, [120, 120])
        model.stopPolling()
        await ticker.tick() // release the parked sleep so the cancelled loop can exit
    }

    await t.test("the poll cadence comes from preferences; changing it persists and re-parks the loop") {
        let store = InMemoryTokenStore(seed: "ntn_saved")
        let stub = StubHTTPClient(responseData: try fixtureData("query_response"), statusCode: 200)
        let prefs = InMemoryPreferences(autoRefreshInterval: 300)
        let ticker = PollTicker()
        let model = AppModel(tokenStore: store, preferences: prefs, pollSleep: ticker.sleep) {
            NotionClient(dataSourceID: ds, token: $0, http: stub)
        }
        t.expectEqual(model.autoRefreshInterval, 300)
        await model.start()

        model.startPolling() // no argument: the cadence is the preferred one
        var spins = 0
        while await ticker.intervals.isEmpty, spins < 500 { await Task.yield(); spins += 1 }
        t.expectEqual(await ticker.intervals, [300])

        model.setAutoRefreshInterval(60)
        t.expectEqual(prefs.autoRefreshInterval, 60) // persisted for the next launch
        spins = 0
        while await ticker.intervals.count < 2, spins < 500 { await Task.yield(); spins += 1 }
        t.expectEqual(await ticker.intervals.last, 60) // the running loop re-parked at the new cadence

        model.stopPolling()
        await ticker.tick() // release the parked sleeps so the cancelled loops exit
    }

    await t.test("with no stored preference the poll cadence is the one-minute default") {
        let store = InMemoryTokenStore(seed: "ntn_saved")
        let stub = StubHTTPClient(responseData: try fixtureData("query_response"), statusCode: 200)
        let model = AppModel(tokenStore: store, preferences: InMemoryPreferences()) {
            NotionClient(dataSourceID: ds, token: $0, http: stub)
        }
        t.expectEqual(model.autoRefreshInterval, 60)
    }

    await t.test("stopPolling halts the loop - an elapsing interval no longer fetches") {
        let store = InMemoryTokenStore(seed: "ntn_saved")
        let stub = StubHTTPClient(responseData: try fixtureData("query_response"), statusCode: 200)
        let ticker = PollTicker()
        let model = AppModel(tokenStore: store, pollSleep: ticker.sleep) {
            NotionClient(dataSourceID: ds, token: $0, http: stub)
        }
        await model.start()
        model.startPolling(every: 60)
        var spins = 0
        while await ticker.intervals.isEmpty, spins < 500 { await Task.yield(); spins += 1 }

        model.stopPolling()
        let fetchesBefore = stub.requestCount
        await ticker.tick()
        for _ in 0..<100 { await Task.yield() }

        t.expectEqual(stub.requestCount, fetchesBefore)
    }

    await t.test("changing the poll interval mid-fetch is not reported as a connection failure (#27)") {
        let store = InMemoryTokenStore(seed: "ntn_saved")
        let transport = CancellableParkingHTTPClient(
            wrapping: StubHTTPClient(responseData: try fixtureData("query_response"), statusCode: 200))
        let ticker = PollTicker()
        let model = AppModel(tokenStore: store, pollSleep: ticker.sleep) {
            NotionClient(dataSourceID: ds, token: $0, http: transport)
        }
        await model.start() // loads normally: the list is on screen

        model.startPolling(every: 60)
        var spins = 0
        while await ticker.intervals.isEmpty, spins < 500 { await Task.yield(); spins += 1 }

        transport.parkRequests = true
        await ticker.tick() // the interval elapses; the poll's refresh parks mid-flight
        spins = 0
        while transport.parkedCount == 0, spins < 500 { await Task.yield(); spins += 1 }
        t.expect(transport.parkedCount > 0, "the refresh should be in flight before the interval changes")

        // Restarting the loop cancels the poll task — and with it the fetch
        // running inside it, which throws URLError(.cancelled).
        model.setAutoRefreshInterval(120)
        spins = 0
        while model.isRefreshing, spins < 5000 { await Task.yield(); spins += 1 }

        t.expect(model.refreshError == nil,
                 "a self-cancelled fetch is no news, not a failure: \(model.refreshError ?? "nil")")
        if case .loaded = model.state {} else {
            t.expect(false, "the list should stay loaded through an interval change")
        }

        model.stopPolling()
        await ticker.tick() // release the re-parked sleep so the cancelled loop exits
    }

    t.suite("AppModel failure legibility")

    await t.test("exhausted 429 backoff surfaces a throttled state, not a connection error") {
        let store = InMemoryTokenStore(seed: "ntn_saved")
        let stub = StubHTTPClient(script: [
            StubResponse(data: Data("{}".utf8), statusCode: 429), // last step repeats: throttled forever
        ])
        let model = AppModel(tokenStore: store) {
            NotionClient(dataSourceID: ds, token: $0, http: stub, sleep: { _ in })
        }

        await model.start()

        if case .failed(let message) = model.state {
            t.expect(message.localizedCaseInsensitiveContains("rate"),
                     "throttling must be named, not disguised as an outage: \(message)")
            t.expect(!message.localizedCaseInsensitiveContains("connection"),
                     "throttling is not a connection problem: \(message)")
        } else {
            t.expect(false, "expected .failed for sustained throttling, got \(model.state)")
        }
    }

    await t.test("throttling during a refresh keeps the list and names the throttle") {
        let store = InMemoryTokenStore(seed: "ntn_saved")
        let stub = StubHTTPClient(responseData: try fixtureData("query_response"), statusCode: 200)
        let model = AppModel(tokenStore: store) {
            NotionClient(dataSourceID: ds, token: $0, http: stub, sleep: { _ in })
        }
        await model.start()
        guard case .loaded(let original) = model.state else {
            t.expect(false, "expected .loaded, got \(model.state)"); return
        }

        stub.statusCode = 429
        await model.refresh()

        t.expectEqual(model.state, .loaded(original))
        t.expect(model.refreshError?.localizedCaseInsensitiveContains("rate") == true,
                 "the stale-list explanation should name throttling: \(model.refreshError ?? "nil")")
    }

    await t.test("no network on first load is a distinct offline state, not an empty list") {
        let store = InMemoryTokenStore(seed: "ntn_saved")
        let offline = ThrowingHTTPClient(error: URLError(.notConnectedToInternet))
        let model = AppModel(tokenStore: store) { NotionClient(dataSourceID: ds, token: $0, http: offline) }

        await model.start()

        if case .failed(let message) = model.state {
            t.expect(message.localizedCaseInsensitiveContains("connection"),
                     "an offline failure should point at the connection: \(message)")
        } else {
            t.expect(false, "offline must never read as 'no tasks', got \(model.state)")
        }
    }

    await t.test("no network during a refresh keeps the loaded list visible with an offline note") {
        let store = InMemoryTokenStore(seed: "ntn_saved")
        let inner = StubHTTPClient(responseData: try fixtureData("query_response"), statusCode: 200)
        let flaky = SwitchableHTTPClient(wrapping: inner)
        let model = AppModel(tokenStore: store) { NotionClient(dataSourceID: ds, token: $0, http: flaky) }
        await model.start()
        guard case .loaded(let original) = model.state else {
            t.expect(false, "expected .loaded, got \(model.state)"); return
        }

        flaky.error = URLError(.notConnectedToInternet)
        await model.refresh()

        t.expectEqual(model.state, .loaded(original))
        t.expect(model.refreshError?.localizedCaseInsensitiveContains("connection") == true,
                 "the stale-list explanation should point at the connection: \(model.refreshError ?? "nil")")
    }

    await t.test("a successful fetch with zero tasks is a genuine empty state, free of errors") {
        let emptyQueryJSON = Data("""
        { "object": "list", "results": [], "has_more": false, "next_cursor": null }
        """.utf8)
        let store = InMemoryTokenStore(seed: "ntn_saved")
        let stub = StubHTTPClient(responseData: emptyQueryJSON, statusCode: 200)
        let model = AppModel(tokenStore: store) { NotionClient(dataSourceID: ds, token: $0, http: stub) }

        await model.start()

        t.expectEqual(model.state, .loaded([]))
        t.expect(model.refreshError == nil, "an empty list is not a failure")
        t.expect(model.writeError == nil, "an empty list is not a failure")
    }

    await t.test("a 401 on a status write clears the token and routes to re-entry, not 'try again'") {
        let store = InMemoryTokenStore(seed: "ntn_saved")
        let stub = StubHTTPClient(responseData: try fixtureData("query_response"), statusCode: 200)
        let model = AppModel(tokenStore: store) { NotionClient(dataSourceID: ds, token: $0, http: stub) }
        await model.start()

        stub.statusCode = 401 // the token is revoked between the load and the write
        await model.setStatus(taskID: firstTaskID, to: "Done")

        t.expect(store.read() == nil, "a rejected token must be cleared from the store")
        if case .failed(let message) = model.state {
            t.expect(message.localizedCaseInsensitiveContains("token"),
                     "the failure must route the user to the token, said: \(message)")
        } else {
            t.expect(false, "expected .failed prompting for a token, got \(model.state)")
        }
        t.expect(model.writeError == nil,
                 "'try again' can never succeed against a dead token, said: \(model.writeError ?? "nil")")
    }

    t.suite("AppModel write/refresh interleavings")

    // tasks[1] in the fixture: "Draft the Q3 board update", To Do.
    let secondTaskID = "11111111-0000-0000-0000-000000000002"

    await t.test("two quick completes both stick - the first isn't undone by the second's landing") {
        let store = InMemoryTokenStore(seed: "ntn_saved")
        let gate = PatchGateHTTPClient(wrapping: RoutingStubHTTPClient(
            schema: try fixtureData("data_source_schema"),
            query: try fixtureData("query_response")))
        let model = AppModel(tokenStore: store) {
            NotionClient(dataSourceID: ds, token: $0, http: gate)
        }
        await model.start()

        // Tick task A, then task B before A's PATCH has returned: both writes
        // are now in flight together, held at the gate.
        let writeA = Task { await model.setStatus(taskID: firstTaskID, to: "Done") }
        let writeB = Task { await model.setStatus(taskID: secondTaskID, to: "Done") }
        for _ in 0..<50 { await Task.yield() } // let both reach the gate
        await gate.open()
        await writeA.value
        await writeB.value

        guard case .loaded(let tasks) = model.state else {
            t.expect(false, "expected .loaded, got \(model.state)"); return
        }
        t.expect(tasks.first { $0.id == firstTaskID }?.status == "Done",
                 "task A's completed status was clobbered by task B's write landing")
        t.expect(tasks.first { $0.id == secondTaskID }?.status == "Done",
                 "task B should show Done")
    }

    t.suite("AppModel schema-fetch failure (#14)")

    await t.test("schema route fails, query succeeds: the list loads and a warning is published") {
        let store = InMemoryTokenStore(seed: "ntn_saved")
        let stub = RoutingStubHTTPClient(
            schema: try fixtureData("data_source_schema"),
            query: try fixtureData("query_response"))
        stub.schemaStatusCode = 500
        let model = AppModel(tokenStore: store) { NotionClient(dataSourceID: ds, token: $0, http: stub) }

        await model.start()

        if case .loaded(let tasks) = model.state {
            t.expectEqual(tasks.count, 5)
        } else {
            t.expect(false, "expected .loaded despite the schema failure, got \(model.state)")
        }
        t.expect(model.schemaWarning != nil, "a failed schema fetch must be visible, not silent")
    }

    await t.test("the warning clears when a later load fetches the schema, and returns if it fails again") {
        let store = InMemoryTokenStore(seed: "ntn_saved")
        let stub = RoutingStubHTTPClient(
            schema: try fixtureData("data_source_schema"),
            query: try fixtureData("query_response"))
        stub.schemaStatusCode = 500
        let model = AppModel(tokenStore: store) { NotionClient(dataSourceID: ds, token: $0, http: stub) }

        await model.start()
        t.expect(model.schemaWarning != nil, "precondition: the warning is up after a schema failure")

        stub.schemaStatusCode = 200
        await model.refresh()
        t.expect(model.schemaWarning == nil, "a successful schema fetch should clear the warning")

        stub.schemaStatusCode = 500
        await model.refresh()
        t.expect(model.schemaWarning != nil, "the warning returns when the schema fails again")
    }

    await t.test("schema failure plus task failure shows only the task-fetch error states") {
        let store = InMemoryTokenStore(seed: "ntn_saved")
        let stub = RoutingStubHTTPClient(
            schema: try fixtureData("data_source_schema"),
            query: Data("not json".utf8)) // the task fetch fails too
        stub.schemaStatusCode = 500
        let model = AppModel(tokenStore: store) { NotionClient(dataSourceID: ds, token: $0, http: stub) }

        await model.start()

        if case .failed = model.state {} else {
            t.expect(false, "expected the normal task-fetch failure, got \(model.state)")
        }
        t.expect(model.schemaWarning == nil, "the task-fetch error wins - no second message")
    }

    await t.test("with a snapshot present, a schema failure filters with the snapshot's facts, not the fallbacks") {
        // "Todo" exists only in the snapshot's facts — it is not in
        // NotionConfig.fallbackOpenStatuses. Reverting to the fallbacks on a
        // schema failure would render every preset empty (the issue's original
        // failure scenario: renamed statuses + a schema hiccup); the
        // last-known-good facts keep the task visible.
        let renamedQueryJSON = Data("""
        {
          "object": "list",
          "results": [{
            "id": "todo1",
            "properties": {
              "Task": { "type": "title", "title": [{ "plain_text": "Renamed status task" }] },
              "Status": { "id": "st", "type": "status", "status": { "name": "Todo" } }
            }
          }],
          "has_more": false,
          "next_cursor": null
        }
        """.utf8)
        let snapshot = CachedSnapshot(
            tasks: [NotionTask(id: "old", title: "Old cached task", status: "Todo")],
            openStatuses: ["Todo"],
            workCategory: "👨🏻‍💻 Work",
            personalCategories: ["📝 Life admin"],
            schemaOptions: SchemaOptions(statuses: ["Todo"], categories: [],
                                         priorities: [], workTypes: []),
            fetchedAt: Date(timeIntervalSince1970: 1_751_500_000))
        let store = InMemoryTokenStore(seed: "ntn_saved")
        let cache = InMemoryTaskCache(seed: snapshot)
        let stub = RoutingStubHTTPClient(
            schema: try fixtureData("data_source_schema"), query: renamedQueryJSON)
        stub.schemaStatusCode = 500
        let model = AppModel(tokenStore: store, cache: cache) {
            NotionClient(dataSourceID: ds, token: $0, http: stub)
        }

        await model.start()
        model.selectPreset(.allOpen)

        t.expectEqual(model.groups().flatMap(\.tasks).map(\.id), ["todo1"])
        t.expect(model.schemaWarning != nil, "the staleness is signalled while the list stays visible")
    }

    t.suite("AppModel collapsible groups")

    await t.test("priority groups start expanded; toggling collapses and re-expands only that group") {
        let store = InMemoryTokenStore(seed: "ntn_saved")
        let stub = StubHTTPClient(responseData: try fixtureData("query_response"), statusCode: 200)
        let model = AppModel(tokenStore: store) { NotionClient(dataSourceID: ds, token: $0, http: stub) }

        t.expect(!model.isCollapsed("P0"), "everything starts expanded on first run")
        t.expect(!model.isCollapsed(nil), "the no-priority group starts expanded too")

        model.toggleCollapsed("P0")
        t.expect(model.isCollapsed("P0"), "toggling a header collapses that group")
        t.expect(!model.isCollapsed("P1"), "other groups are untouched")
        t.expect(!model.isCollapsed(nil), "the no-priority group is untouched")

        model.toggleCollapsed("P0")
        t.expect(!model.isCollapsed("P0"), "toggling again re-expands the group")
    }

    await t.test("collapse is per preset: P2 folded in Pivotal leaves Home's P2 expanded") {
        let store = InMemoryTokenStore(seed: "ntn_saved")
        let stub = StubHTTPClient(responseData: try fixtureData("query_response"), statusCode: 200)
        let model = AppModel(tokenStore: store) { NotionClient(dataSourceID: ds, token: $0, http: stub) }

        // Active preset is the Pivotal default.
        model.toggleCollapsed("P2")
        t.expect(model.isCollapsed("P2"), "Pivotal's P2 collapses")

        model.selectPreset(.homePriorities)
        t.expect(!model.isCollapsed("P2"), "Home's P2 keeps its own, expanded state")

        model.selectPreset(.pivotalPriorities)
        t.expect(model.isCollapsed("P2"), "Pivotal's P2 is still collapsed on return")
    }

    await t.test("collapse state survives a relaunch, still independently per preset") {
        let prefs = InMemoryPreferences()
        let store = InMemoryTokenStore(seed: "ntn_saved")
        let stub = StubHTTPClient(responseData: try fixtureData("query_response"), statusCode: 200)
        let firstLaunch = AppModel(tokenStore: store, preferences: prefs) {
            NotionClient(dataSourceID: ds, token: $0, http: stub)
        }
        firstLaunch.toggleCollapsed("P2") // in the Pivotal default
        firstLaunch.toggleCollapsed(nil)

        // The next launch reads the same preferences.
        let relaunch = AppModel(tokenStore: store, preferences: prefs) {
            NotionClient(dataSourceID: ds, token: $0, http: stub)
        }
        t.expect(relaunch.isCollapsed("P2"), "Pivotal's folded P2 is remembered")
        t.expect(relaunch.isCollapsed(nil), "the folded no-priority group is remembered")
        t.expect(!relaunch.isCollapsed("P0"), "P0 was never folded")
        relaunch.selectPreset(.homePriorities)
        t.expect(!relaunch.isCollapsed("P2"), "Home's P2 is still expanded")
    }

    await t.test("a refresh that lands while a write is in flight is not overwritten by stale data") {
        let store = InMemoryTokenStore(seed: "ntn_saved")
        let routing = RoutingStubHTTPClient(
            schema: try fixtureData("data_source_schema"),
            query: try fixtureData("query_response"))
        let gate = PatchGateHTTPClient(wrapping: routing)
        let model = AppModel(tokenStore: store) {
            NotionClient(dataSourceID: ds, token: $0, http: gate)
        }
        await model.start()

        // Hold a write at the gate, then let a full refresh land fresh data.
        let write = Task { await model.setStatus(taskID: firstTaskID, to: "Done") }
        for _ in 0..<50 { await Task.yield() } // let the write reach the gate
        routing.query = freshQueryJSON
        await model.refresh()
        if case .loaded(let tasks) = model.state {
            t.expectEqual(tasks.map(\.title), ["Fresh task"])
        } else {
            t.expect(false, "expected the refreshed list, got \(model.state)"); return
        }

        await gate.open()
        await write.value

        // The write's task isn't in the fresh list; its landing must not
        // resurrect the five-task snapshot it captured before the refresh.
        if case .loaded(let tasks) = model.state {
            t.expectEqual(tasks.map(\.title), ["Fresh task"])
        } else {
            t.expect(false, "expected the refreshed list to survive, got \(model.state)")
        }
    }

    t.suite("AppModel create task (#22)")

    var createCal = Calendar(identifier: .gregorian)
    createCal.timeZone = TimeZone(identifier: "Europe/London")!
    let createToday = createCal.date(
        from: DateComponents(year: 2026, month: 7, day: 15, hour: 12))!

    /// A canned POST /v1/pages response: the created page as Notion returns it,
    /// Status carrying whatever the DB defaulted (we never send one).
    func createdPageJSON(id: String, title: String, status: String = "To Do",
                         category: String? = nil, priority: String? = nil) -> Data {
        var props = [
            "\"Task\": { \"type\": \"title\", \"title\": [{ \"plain_text\": \"\(title)\" }] }",
            "\"Status\": { \"type\": \"status\", \"status\": { \"name\": \"\(status)\" } }",
        ]
        if let category {
            props.append("\"Category\": { \"type\": \"select\", \"select\": { \"name\": \"\(category)\" } }")
        }
        if let priority {
            props.append("\"Priority\": { \"type\": \"select\", \"select\": { \"name\": \"\(priority)\" } }")
        }
        return Data("""
        {
          "id": "\(id)",
          "created_time": "2026-07-15T09:00:00.000Z",
          "last_edited_time": "2026-07-15T09:00:00.000Z",
          "url": "https://www.notion.so/task-\(id)",
          "properties": { \(props.joined(separator: ", ")) }
        }
        """.utf8)
    }

    /// A loaded model on the default Pivotal Priorities preset, with the
    /// routing stub's create route primed by the caller.
    func loadedModel(
        stub: RoutingStubHTTPClient, cache: InMemoryTaskCache? = nil
    ) async -> AppModel {
        let model = AppModel(tokenStore: InMemoryTokenStore(seed: "ntn_saved"), cache: cache) {
            NotionClient(dataSourceID: ds, token: $0, http: stub, sleep: { _ in })
        }
        await model.start()
        return model
    }

    await t.test("a successful create appends the decoded task, caches it, and closes the composer") {
        let stub = RoutingStubHTTPClient(
            schema: try fixtureData("data_source_schema"),
            query: try fixtureData("query_response"))
        stub.create = createdPageJSON(id: "new-1", title: "Book the venue",
                                      category: "👨🏻‍💻 Work", priority: "P1")
        let cache = InMemoryTaskCache()
        let model = await loadedModel(stub: stub, cache: cache)
        model.openComposer()

        let ok = await model.createTask(
            TaskDraft(title: "Book the venue", priority: "P1", category: "👨🏻‍💻 Work"),
            today: createToday, calendar: createCal)

        t.expect(ok, "create should report success")
        guard case .loaded(let tasks) = model.state else {
            t.expect(false, "expected .loaded, got \(model.state)"); return
        }
        t.expectEqual(tasks.count, 6)
        let added = try require(tasks.first { $0.id == "new-1" })
        // The row is the response, not the draft: Notion's defaulted Status
        // and the page URL prove the decode drove it.
        t.expect(added.status == "To Do", "status was \(added.status ?? "nil")")
        t.expectEqual(added.url, "https://www.notion.so/task-new-1")
        t.expect(!model.isComposing, "composer closes on success")
        t.expect(model.createError == nil, "no error expected, got \(model.createError ?? "nil")")
        // Open Work task on Pivotal Priorities: visible, so no notice.
        t.expect(model.createNotice == nil, "visible task needs no notice, got \(model.createNotice ?? "nil")")
        t.expect(cache.saved.last?.tasks.contains { $0.id == "new-1" } == true,
                 "the new task must be cached, or a relaunch loses it")
        t.expectEqual(cache.saved.last?.fetchedAt, model.lastRefreshed)
    }

    await t.test("a create that doesn't match the active view sets the invisibility notice") {
        let stub = RoutingStubHTTPClient(
            schema: try fixtureData("data_source_schema"),
            query: try fixtureData("query_response"))
        // A personal-category task, created while Pivotal Priorities (Work
        // only) is active: real in Notion, invisible in this view.
        stub.create = createdPageJSON(id: "new-2", title: "Fix the bike",
                                      category: "📝 Life admin")
        let model = await loadedModel(stub: stub)
        model.openComposer()

        let ok = await model.createTask(TaskDraft(title: "Fix the bike", category: "📝 Life admin"),
                                        today: createToday, calendar: createCal)

        t.expect(ok, "the create itself succeeded")
        t.expect(!model.isComposing, "composer still closes - the task was created")
        let notice = model.createNotice ?? ""
        t.expect(notice.contains("not visible"), "notice was \(notice)")
        t.expect(notice.contains("Pivotal Priorities"), "notice should name the view, was \(notice)")
        // The task is in the raw list all the same - switching view reveals it.
        if case .loaded(let tasks) = model.state {
            t.expect(tasks.contains { $0.id == "new-2" }, "task must be in the loaded list")
        }
    }

    await t.test("the title is trimmed before it is sent") {
        let stub = RoutingStubHTTPClient(
            schema: try fixtureData("data_source_schema"),
            query: try fixtureData("query_response"))
        stub.create = createdPageJSON(id: "new-3", title: "Book the venue")
        let model = await loadedModel(stub: stub)

        _ = await model.createTask(TaskDraft(title: "  Book the venue \n"),
                                   today: createToday, calendar: createCal)

        let post = try require(stub.requests.first {
            $0.httpMethod == "POST" && $0.url?.absoluteString.hasSuffix("/pages") == true
        }, "expected a create request")
        let body = try JSONSerialization.jsonObject(
            with: try require(post.httpBody)) as? [String: Any]
        let titleContent = ((((body?["properties"] as? [String: Any])?["Task"]
            as? [String: Any])?["title"] as? [[String: Any]])?.first?["text"]
            as? [String: Any])?["content"] as? String
        t.expect(titleContent == "Book the venue", "title sent was \(titleContent ?? "nil")")
    }

    await t.test("a blank title sends nothing and fails quietly - Add should be disabled anyway") {
        let stub = RoutingStubHTTPClient(
            schema: try fixtureData("data_source_schema"),
            query: try fixtureData("query_response"))
        let model = await loadedModel(stub: stub)
        model.openComposer()

        let ok = await model.createTask(TaskDraft(title: "   \n"),
                                        today: createToday, calendar: createCal)

        t.expect(!ok, "a blank title must not create")
        t.expect(!stub.requests.contains { $0.httpMethod == "POST"
            && $0.url?.absoluteString.hasSuffix("/pages") == true },
                 "no create request should be sent")
        t.expect(model.isComposing, "composer stays open")
    }

    await t.test("a failed create keeps the composer open with an error, and the list unchanged") {
        let stub = RoutingStubHTTPClient(
            schema: try fixtureData("data_source_schema"),
            query: try fixtureData("query_response"))
        stub.createStatusCode = 500
        let cache = InMemoryTaskCache()
        let model = await loadedModel(stub: stub, cache: cache)
        model.openComposer()
        let savesAfterLoad = cache.saved.count

        let ok = await model.createTask(TaskDraft(title: "Doomed"),
                                        today: createToday, calendar: createCal)

        t.expect(!ok, "the create failed")
        t.expect(model.isComposing, "composer must stay open so the draft isn't lost")
        t.expect(model.createError != nil, "an error must say why")
        if case .loaded(let tasks) = model.state {
            t.expectEqual(tasks.count, 5)
        } else {
            t.expect(false, "expected .loaded, got \(model.state)")
        }
        t.expectEqual(cache.saved.count, savesAfterLoad)
    }

    await t.test("a 401 on create drops the token and routes to reconnect, like every write (#13)") {
        let stub = RoutingStubHTTPClient(
            schema: try fixtureData("data_source_schema"),
            query: try fixtureData("query_response"))
        stub.createStatusCode = 401
        let store = InMemoryTokenStore(seed: "ntn_saved")
        let model = AppModel(tokenStore: store) {
            NotionClient(dataSourceID: ds, token: $0, http: stub, sleep: { _ in })
        }
        await model.start()

        let ok = await model.createTask(TaskDraft(title: "Never lands"),
                                        today: createToday, calendar: createCal)

        t.expect(!ok, "the create failed")
        t.expect(store.read() == nil, "the dead token must be dropped")
        if case .failed = model.state {} else {
            t.expect(false, "expected .failed (reconnect), got \(model.state)")
        }
    }

    await t.test("a rate-limited create names the throttle rather than a generic failure") {
        let stub = RoutingStubHTTPClient(
            schema: try fixtureData("data_source_schema"),
            query: try fixtureData("query_response"))
        stub.createStatusCode = 429
        let model = await loadedModel(stub: stub)
        model.openComposer()

        let ok = await model.createTask(TaskDraft(title: "Throttled"),
                                        today: createToday, calendar: createCal)

        t.expect(!ok, "the create failed")
        t.expect(model.createError?.contains("rate-limiting") == true,
                 "error was \(model.createError ?? "nil")")
    }

    await t.test("composerDraft pre-fills from the active view with schema-derived facts") {
        let stub = RoutingStubHTTPClient(
            schema: try fixtureData("data_source_schema"),
            query: try fixtureData("query_response"))
        let model = await loadedModel(stub: stub)

        // Default preset is Pivotal Priorities: Category defaults to the
        // schema-resolved Work option.
        t.expectEqual(model.composerDraft(today: createToday, calendar: createCal),
                      TaskDraft(category: "👨🏻‍💻 Work"))

        model.selectPreset(.lateOrDueToday)
        t.expectEqual(model.composerDraft(today: createToday, calendar: createCal),
                      TaskDraft(dueDate: createCal.startOfDay(for: createToday)))

        model.selectPreset(.homePriorities)
        t.expectEqual(model.composerDraft(today: createToday, calendar: createCal), TaskDraft())
    }

    await t.test("opening the composer clears the previous attempt's messages") {
        let stub = RoutingStubHTTPClient(
            schema: try fixtureData("data_source_schema"),
            query: try fixtureData("query_response"))
        stub.createStatusCode = 500
        let model = await loadedModel(stub: stub)
        model.openComposer()
        _ = await model.createTask(TaskDraft(title: "Doomed"),
                                   today: createToday, calendar: createCal)
        t.expect(model.createError != nil, "precondition: the create failed")

        model.closeComposer()
        t.expect(model.createError == nil, "closing discards the error with the draft")
        model.openComposer()
        t.expect(model.isComposing, "composer is open")
        t.expect(model.createError == nil && model.createNotice == nil,
                 "a fresh composition starts clean")
    }

    t.suite("AppModel inline rename (#28)")

    // firstTaskID in the fixture: "Wire up the menu bar read path", In Progress.
    let firstTaskTitle = "Wire up the menu bar read path"

    func rowTitle(_ model: AppModel, _ id: String) -> String? {
        guard case .loaded(let tasks) = model.state else { return nil }
        return tasks.first { $0.id == id }?.title
    }

    await t.test("setTitle renames the row and PATCHes the schema-resolved title property") {
        let store = InMemoryTokenStore()
        let stub = RoutingStubHTTPClient(
            schema: try fixtureData("data_source_schema"),
            query: try fixtureData("query_response"))
        let model = AppModel(tokenStore: store) { NotionClient(dataSourceID: ds, token: $0, http: stub) }
        await model.submit(token: "ntn_good")

        await model.setTitle(taskID: firstTaskID, to: "Renamed task")

        t.expectEqual(rowTitle(model, firstTaskID), "Renamed task")
        t.expect(model.writeError == nil, "no write error expected, got \(model.writeError ?? "nil")")
        // The other fields of the renamed row are preserved.
        guard case .loaded(let tasks) = model.state else {
            t.expect(false, "expected .loaded, got \(model.state)"); return
        }
        let renamed = try require(tasks.first { $0.id == firstTaskID })
        t.expect(renamed.status == "In Progress", "status drifted to \(renamed.status ?? "nil")")

        // A PATCH went to the page, keyed by the schema's title name ("Task").
        let patch = try require(stub.requests.first {
            $0.httpMethod == "PATCH" && $0.url?.absoluteString.hasSuffix("/pages/\(firstTaskID)") == true
        }, "expected a PATCH to the page")
        let body = try JSONSerialization.jsonObject(
            with: try require(patch.httpBody)) as? [String: Any]
        let props = body?["properties"] as? [String: Any]
        t.expect(props?.keys.sorted() == ["Task"], "keyed by the resolved name, was \(props?.keys.sorted() ?? [])")
        let content = (((props?["Task"] as? [String: Any])?["title"]
            as? [[String: Any]])?.first?["text"] as? [String: Any])?["content"] as? String
        t.expect(content == "Renamed task", "title sent was \(content ?? "nil")")
    }

    await t.test("an empty title reverts and sends no PATCH") {
        let store = InMemoryTokenStore()
        let stub = RoutingStubHTTPClient(
            schema: try fixtureData("data_source_schema"),
            query: try fixtureData("query_response"))
        let model = AppModel(tokenStore: store) { NotionClient(dataSourceID: ds, token: $0, http: stub) }
        await model.submit(token: "ntn_good")

        await model.setTitle(taskID: firstTaskID, to: "   \n ")

        t.expectEqual(rowTitle(model, firstTaskID), firstTaskTitle)
        t.expect(!stub.requests.contains { $0.httpMethod == "PATCH" },
                 "a blank rename must not be written")
        t.expect(model.writeError == nil, "reverting a blank rename is not an error")
    }

    await t.test("an unchanged title sends no PATCH") {
        let store = InMemoryTokenStore()
        let stub = RoutingStubHTTPClient(
            schema: try fixtureData("data_source_schema"),
            query: try fixtureData("query_response"))
        let model = AppModel(tokenStore: store) { NotionClient(dataSourceID: ds, token: $0, http: stub) }
        await model.submit(token: "ntn_good")

        // Same text, only surrounded by whitespace: still a no-op after trimming.
        await model.setTitle(taskID: firstTaskID, to: "  \(firstTaskTitle)  ")

        t.expectEqual(rowTitle(model, firstTaskID), firstTaskTitle)
        t.expect(!stub.requests.contains { $0.httpMethod == "PATCH" },
                 "an unchanged title is not worth a round-trip")
    }

    await t.test("a failed rename rolls the title back and surfaces a write error") {
        let store = InMemoryTokenStore()
        let stub = StubHTTPClient(responseData: try fixtureData("query_response"), statusCode: 200)
        let model = AppModel(tokenStore: store) { NotionClient(dataSourceID: ds, token: $0, http: stub) }
        await model.submit(token: "ntn_good")
        stub.statusCode = 500 // the write will fail

        await model.setTitle(taskID: firstTaskID, to: "Doomed rename")

        t.expectEqual(rowTitle(model, firstTaskID), firstTaskTitle) // optimistic change rolled back
        t.expect(model.writeError != nil, "a failed rename should tell the user it didn't take")
    }

    await t.test("a rename is written to the cache so a relaunch keeps it") {
        let store = InMemoryTokenStore()
        let cache = InMemoryTaskCache()
        let stub = RoutingStubHTTPClient(
            schema: try fixtureData("data_source_schema"),
            query: try fixtureData("query_response"))
        let model = AppModel(tokenStore: store, cache: cache) {
            NotionClient(dataSourceID: ds, token: $0, http: stub)
        }
        await model.submit(token: "ntn_good")

        await model.setTitle(taskID: firstTaskID, to: "Cached name")

        t.expect(cache.saved.last?.tasks.first { $0.id == firstTaskID }?.title == "Cached name",
                 "the renamed title must be cached, or a relaunch loses it")
    }

    await t.test("a 401 on rename drops the token and routes to reconnect, like every write (#13)") {
        let store = InMemoryTokenStore(seed: "ntn_saved")
        let stub = StubHTTPClient(responseData: try fixtureData("query_response"), statusCode: 200)
        let model = AppModel(tokenStore: store) { NotionClient(dataSourceID: ds, token: $0, http: stub) }
        await model.start()

        stub.statusCode = 401 // token revoked between load and the rename
        await model.setTitle(taskID: firstTaskID, to: "Never lands")

        t.expect(store.read() == nil, "a rejected token must be cleared")
        if case .failed(let message) = model.state {
            t.expect(message.localizedCaseInsensitiveContains("token"),
                     "the failure must route to the token, said: \(message)")
        } else {
            t.expect(false, "expected .failed (reconnect), got \(model.state)")
        }
    }

    await t.test("beginEditing arms the draft; cancelEditing abandons it with no write") {
        let store = InMemoryTokenStore()
        let stub = RoutingStubHTTPClient(
            schema: try fixtureData("data_source_schema"),
            query: try fixtureData("query_response"))
        let model = AppModel(tokenStore: store) { NotionClient(dataSourceID: ds, token: $0, http: stub) }
        await model.submit(token: "ntn_good")

        model.beginEditing(taskID: firstTaskID, title: firstTaskTitle)
        t.expectEqual(model.editingTaskID, firstTaskID)
        t.expectEqual(model.editingDraft, firstTaskTitle)

        model.setEditingDraft("Half-typed")
        model.cancelEditing()

        t.expect(model.editingTaskID == nil, "cancel leaves edit mode")
        t.expectEqual(rowTitle(model, firstTaskID), firstTaskTitle) // untouched
        t.expect(!stub.requests.contains { $0.httpMethod == "PATCH" }, "cancel writes nothing")
    }

    await t.test("commitEditing leaves edit mode at once and persists the draft") {
        let store = InMemoryTokenStore()
        let stub = RoutingStubHTTPClient(
            schema: try fixtureData("data_source_schema"),
            query: try fixtureData("query_response"))
        let model = AppModel(tokenStore: store) { NotionClient(dataSourceID: ds, token: $0, http: stub) }
        await model.submit(token: "ntn_good")

        model.beginEditing(taskID: firstTaskID, title: firstTaskTitle)
        model.setEditingDraft("Committed name")
        model.commitEditing()

        t.expect(model.editingTaskID == nil, "commit leaves edit mode immediately")
        // The write runs in a detached task; spin until the rename lands.
        var spins = 0
        while rowTitle(model, firstTaskID) != "Committed name", spins < 500 {
            await Task.yield(); spins += 1
        }
        t.expectEqual(rowTitle(model, firstTaskID), "Committed name")
    }

    await t.test("auto-refresh holds off while a row is being renamed (#28)") {
        let store = InMemoryTokenStore(seed: "ntn_saved")
        let stub = StubHTTPClient(responseData: try fixtureData("query_response"), statusCode: 200)
        let ticker = PollTicker()
        let model = AppModel(tokenStore: store, pollSleep: ticker.sleep) {
            NotionClient(dataSourceID: ds, token: $0, http: stub)
        }
        await model.start()
        model.startPolling(every: 60)
        var spins = 0
        while await ticker.intervals.isEmpty, spins < 500 { await Task.yield(); spins += 1 }

        // Editing open: an elapsing interval must not fetch — it re-parks instead.
        model.beginEditing(taskID: firstTaskID, title: firstTaskTitle)
        let fetchesWhileEditing = stub.requestCount
        await ticker.tick()
        spins = 0
        while await ticker.intervals.count < 2, spins < 500 { await Task.yield(); spins += 1 }
        t.expectEqual(stub.requestCount, fetchesWhileEditing) // no refresh landed

        // Editing ended: the next elapsing interval refreshes as normal.
        model.cancelEditing()
        await ticker.tick()
        spins = 0
        while stub.requestCount == fetchesWhileEditing, spins < 500 { await Task.yield(); spins += 1 }
        t.expect(stub.requestCount > fetchesWhileEditing, "the poll resumes once editing ends")

        model.stopPolling()
        await ticker.tick() // release the parked sleep so the cancelled loop exits
    }

    t.suite("AppModel header search (#32)")

    func searchModel() async throws -> AppModel {
        let store = InMemoryTokenStore()
        let stub = RoutingStubHTTPClient(
            schema: try fixtureData("data_source_schema"),
            query: try fixtureData("query_response"))
        let model = AppModel(tokenStore: store) { NotionClient(dataSourceID: ds, token: $0, http: stub) }
        await model.submit(token: "ntn_good")
        return model
    }

    var searchCal = Calendar(identifier: .gregorian)
    searchCal.timeZone = TimeZone(identifier: "Europe/London")!
    let searchToday = searchCal.date(from: DateComponents(year: 2026, month: 7, day: 15, hour: 12))!

    await t.test("search filters the active view by title and drops now-empty groups") {
        let model = try await searchModel()
        // Default Pivotal Priorities: P0 (Draft the Q3 board update), P1 (Wire up…).
        t.expectEqual(model.groups(today: searchToday, calendar: searchCal).map(\.priority), ["P0", "P1"])

        model.setSearch("wire")
        let groups = model.groups(today: searchToday, calendar: searchCal)
        t.expectEqual(groups.map(\.priority), ["P1"]) // the empty P0 group is dropped
        t.expectEqual(groups.first?.tasks.map(\.title), ["Wire up the menu bar read path"])
        // Section count reflects the match, not the total.
        t.expectEqual(groups.first?.tasks.count, 1)
    }

    await t.test("search carries over a preset switch, widening a fruitless query to All open") {
        let model = try await searchModel()
        // "Chase vendor…" is a personal Blocked task — hidden by Pivotal (Work only).
        model.setSearch("chase")
        t.expect(model.groups(today: searchToday, calendar: searchCal).isEmpty,
                 "the Chase task is personal, so Pivotal shows no match")

        // Widen to All open WITHOUT retyping: the query must survive the switch.
        model.selectPreset(.allOpen)
        t.expectEqual(model.searchText, "chase")
        t.expectEqual(model.groups(today: searchToday, calendar: searchCal).flatMap(\.tasks).map(\.title),
                      ["Chase vendor on renewal quote"])
    }

    await t.test("search and the composer are mutually exclusive; closing search clears the query") {
        let model = try await searchModel()
        t.expect(!model.isSearching && model.searchText.isEmpty, "search starts closed and empty")

        model.openSearch()
        model.setSearch("draft")
        t.expect(model.isSearching && !model.isComposing, "search open collapses the composer")

        // Opening the composer collapses search and clears the typed query.
        model.openComposer()
        t.expect(model.isComposing && !model.isSearching, "composer open collapses search")
        t.expect(model.searchText.isEmpty, "closing search clears the query")

        // The icon toggles the row open, then shut again.
        model.toggleSearch()
        t.expect(model.isSearching && !model.isComposing, "toggling opens search and collapses the composer")
        model.toggleSearch()
        t.expect(!model.isSearching && model.searchText.isEmpty, "toggling again closes and clears search")
    }

    t.suite("AppModel reschedule & re-prioritise (#33)")

    // firstTaskID in the fixture: P1, due 2026-06-28, Work, In Progress.
    func loadedTask(_ model: AppModel, _ id: String) -> NotionTask? {
        guard case .loaded(let tasks) = model.state else { return nil }
        return tasks.first { $0.id == id }
    }
    func routingModel(_ store: InMemoryTokenStore = InMemoryTokenStore(),
                      cache: InMemoryTaskCache? = nil) async throws -> (AppModel, RoutingStubHTTPClient) {
        let stub = RoutingStubHTTPClient(
            schema: try fixtureData("data_source_schema"), query: try fixtureData("query_response"))
        let model = AppModel(tokenStore: store, cache: cache) {
            NotionClient(dataSourceID: ds, token: $0, http: stub)
        }
        await model.submit(token: "ntn_good")
        return (model, stub)
    }
    func patchBody(_ stub: RoutingStubHTTPClient, _ id: String) throws -> [String: Any]? {
        let patch = try require(stub.requests.first {
            $0.httpMethod == "PATCH" && $0.url?.absoluteString.hasSuffix("/pages/\(id)") == true
        }, "expected a PATCH to the page")
        return try JSONSerialization.jsonObject(with: try require(patch.httpBody)) as? [String: Any]
    }

    await t.test("setPriority changes the row's priority, keeps other fields, and PATCHes the select") {
        let (model, stub) = try await routingModel()

        await model.setPriority(taskID: firstTaskID, to: "P0")

        let task = try require(loadedTask(model, firstTaskID))
        t.expect(task.priority == "P0", "priority was \(task.priority ?? "nil")")
        t.expect(task.title == firstTaskTitle, "title drifted to \(task.title)")
        t.expect(task.status == "In Progress", "status drifted to \(task.status ?? "nil")")
        t.expect(model.writeError == nil, "no write error expected, got \(model.writeError ?? "nil")")

        let props = try patchBody(stub, firstTaskID)?["properties"] as? [String: Any]
        let name = ((props?["Priority"] as? [String: Any])?["select"] as? [String: Any])?["name"] as? String
        t.expect(name == "P0", "sent priority was \(name ?? "nil")")
    }

    await t.test("re-prioritising reflows the task into its new group") {
        let (model, _) = try await routingModel() // default preset groups by priority

        await model.setPriority(taskID: firstTaskID, to: "P0")

        let p0 = model.groups().first { $0.priority == "P0" }
        t.expect(p0?.tasks.contains { $0.id == firstTaskID } == true,
                 "the re-prioritised task should appear in the P0 group")
    }

    await t.test("setting the priority a task already has sends no PATCH") {
        let (model, stub) = try await routingModel()

        await model.setPriority(taskID: firstTaskID, to: "P1") // already P1

        t.expect(!stub.requests.contains { $0.httpMethod == "PATCH" },
                 "an unchanged priority is not worth a round-trip")
    }

    await t.test("setPriority(nil) clears the priority and PATCHes select: null") {
        let (model, stub) = try await routingModel()

        await model.setPriority(taskID: firstTaskID, to: nil)

        t.expect(loadedTask(model, firstTaskID)?.priority == nil, "priority should clear")
        let props = try patchBody(stub, firstTaskID)?["properties"] as? [String: Any]
        let select = (props?["Priority"] as? [String: Any])?["select"]
        t.expect(select is NSNull, "clear must send select: null, was \(String(describing: select))")
    }

    await t.test("a failed priority write rolls back and surfaces a write error") {
        let store = InMemoryTokenStore()
        let stub = StubHTTPClient(responseData: try fixtureData("query_response"), statusCode: 200)
        let model = AppModel(tokenStore: store) { NotionClient(dataSourceID: ds, token: $0, http: stub) }
        await model.submit(token: "ntn_good")
        stub.statusCode = 500 // the write will fail

        await model.setPriority(taskID: firstTaskID, to: "P0")

        t.expect(loadedTask(model, firstTaskID)?.priority == "P1", "the optimistic change must roll back to P1")
        t.expect(model.writeError != nil, "a failed priority write should tell the user it didn't take")
    }

    await t.test("a 401 on a priority write drops the token and routes to reconnect (#13)") {
        let store = InMemoryTokenStore(seed: "ntn_saved")
        let stub = StubHTTPClient(responseData: try fixtureData("query_response"), statusCode: 200)
        let model = AppModel(tokenStore: store) { NotionClient(dataSourceID: ds, token: $0, http: stub) }
        await model.start()
        stub.statusCode = 401 // token revoked between load and the write

        await model.setPriority(taskID: firstTaskID, to: "P0")

        t.expect(store.read() == nil, "a rejected token must be cleared")
        if case .failed(let message) = model.state {
            t.expect(message.localizedCaseInsensitiveContains("token"),
                     "the failure must route to the token, said: \(message)")
        } else {
            t.expect(false, "expected .failed (reconnect), got \(model.state)")
        }
    }

    await t.test("setDueDate sets the date on the row and PATCHes date.start") {
        let (model, stub) = try await routingModel()
        let newDue = Calendar.current.date(from: DateComponents(year: 2026, month: 7, day: 20))!

        await model.setDueDate(taskID: firstTaskID, to: newDue)

        t.expect(loadedTask(model, firstTaskID)?.dueDate == newDue, "the row's due date should update")
        t.expect(model.writeError == nil, "no write error, got \(model.writeError ?? "nil")")
        let props = try patchBody(stub, firstTaskID)?["properties"] as? [String: Any]
        let start = ((props?["Due Date"] as? [String: Any])?["date"] as? [String: Any])?["start"] as? String
        t.expect(start == "2026-07-20", "sent due date was \(start ?? "nil")")
    }

    await t.test("setDueDate(nil) clears the due date and PATCHes date: null") {
        let (model, stub) = try await routingModel()

        await model.setDueDate(taskID: firstTaskID, to: nil)

        t.expect(loadedTask(model, firstTaskID)?.dueDate == nil, "due date should clear")
        let props = try patchBody(stub, firstTaskID)?["properties"] as? [String: Any]
        let date = (props?["Due Date"] as? [String: Any])?["date"]
        t.expect(date is NSNull, "clear must send date: null, was \(String(describing: date))")
    }

    await t.test("rescheduling to the same calendar day sends no PATCH") {
        let (model, stub) = try await routingModel()
        // The fixture's due is 2026-06-28; a different time on the same day is a no-op.
        let sameDay = Calendar.current.date(from: DateComponents(year: 2026, month: 6, day: 28, hour: 14))!

        await model.setDueDate(taskID: firstTaskID, to: sameDay)

        t.expect(!stub.requests.contains { $0.httpMethod == "PATCH" },
                 "a same-day reschedule is not worth a round-trip")
    }

    await t.test("a failed reschedule rolls the date back and surfaces a write error") {
        let store = InMemoryTokenStore()
        let stub = StubHTTPClient(responseData: try fixtureData("query_response"), statusCode: 200)
        let model = AppModel(tokenStore: store) { NotionClient(dataSourceID: ds, token: $0, http: stub) }
        await model.submit(token: "ntn_good")
        let original = loadedTask(model, firstTaskID)?.dueDate
        stub.statusCode = 500

        await model.setDueDate(taskID: firstTaskID,
                               to: Calendar.current.date(from: DateComponents(year: 2026, month: 8, day: 1))!)

        t.expect(loadedTask(model, firstTaskID)?.dueDate == original, "the optimistic change must roll back")
        t.expect(model.writeError != nil, "a failed reschedule should tell the user it didn't take")
    }

    await t.test("a reschedule is written to the cache so a relaunch keeps it") {
        let cache = InMemoryTaskCache()
        let (model, _) = try await routingModel(cache: cache)
        let newDue = Calendar.current.date(from: DateComponents(year: 2026, month: 7, day: 20))!

        await model.setDueDate(taskID: firstTaskID, to: newDue)

        t.expect(cache.saved.last?.tasks.first { $0.id == firstTaskID }?.dueDate == newDue,
                 "the new due date must be cached, or a relaunch loses it")
    }

    t.suite("AppModel quick-capture hotkey (#34)")

    func hotKeyModel(preferences: InMemoryPreferences? = nil,
                     service: FakeHotKeyService? = nil) -> AppModel {
        let stub = StubHTTPClient(responseData: Data(), statusCode: 200)
        return AppModel(tokenStore: InMemoryTokenStore(seed: "ntn_saved"),
                        preferences: preferences, hotKeyService: service) {
            NotionClient(dataSourceID: ds, token: $0, http: stub)
        }
    }

    await t.test("the hotkey defaults to ⌥Space when none is stored") {
        t.expectEqual(hotKeyModel(preferences: InMemoryPreferences()).hotKey, .default)
    }

    await t.test("a stored hotkey is restored on launch, before any registration") {
        let prefs = InMemoryPreferences()
        prefs.hotKey = HotKey(keyCode: 40, carbonModifiers:
            HotKey.CarbonModifier.command | HotKey.CarbonModifier.control)
        t.expectEqual(hotKeyModel(preferences: prefs).hotKey, prefs.hotKey)
    }

    await t.test("setHotKey persists the new shortcut and re-registers it") {
        let prefs = InMemoryPreferences()
        let service = FakeHotKeyService()
        let model = hotKeyModel(preferences: prefs, service: service)
        let newKey = HotKey(keyCode: 40, carbonModifiers:
            HotKey.CarbonModifier.command | HotKey.CarbonModifier.control)

        model.setHotKey(newKey)

        t.expectEqual(model.hotKey, newKey)
        t.expectEqual(prefs.hotKey, newKey) // persisted for the next launch
        t.expectEqual(service.registered, newKey) // re-registered live
    }

    await t.test("setHotKey ignores a modifier-only combination - a bad shortcut is never persisted") {
        let prefs = InMemoryPreferences()
        let service = FakeHotKeyService()
        let model = hotKeyModel(preferences: prefs, service: service)
        let invalid = HotKey(keyCode: 58, carbonModifiers: HotKey.CarbonModifier.option) // Option alone

        model.setHotKey(invalid)

        t.expectEqual(model.hotKey, .default) // unchanged
        t.expect(prefs.hotKey == nil, "an invalid shortcut must not be persisted")
        t.expect(service.registered == nil, "an invalid shortcut must not be registered")
    }

    await t.test("registerHotKey registers the current shortcut with the service") {
        let service = FakeHotKeyService()
        let model = hotKeyModel(service: service)

        model.registerHotKey()

        t.expectEqual(service.registered, .default)
    }

    t.suite("AppModel show-panel hotkey (#39)")

    await t.test("the show-panel hotkey defaults to ⇧⌥Space when none is stored") {
        t.expectEqual(hotKeyModel(preferences: InMemoryPreferences()).panelHotKey, .defaultPanel)
    }

    await t.test("a stored show-panel hotkey is restored on launch, before any registration") {
        let prefs = InMemoryPreferences()
        prefs.panelHotKey = HotKey(keyCode: 40, carbonModifiers:
            HotKey.CarbonModifier.command | HotKey.CarbonModifier.control)
        t.expectEqual(hotKeyModel(preferences: prefs).panelHotKey, prefs.panelHotKey)
    }

    await t.test("registerHotKey registers both hotkeys, each into its own slot") {
        let service = FakeHotKeyService()
        let model = hotKeyModel(service: service)

        model.registerHotKey()

        t.expectEqual(service.registered, .default)          // quick-capture slot
        t.expectEqual(service.registeredPanel, .defaultPanel) // show-panel slot
    }

    await t.test("registerHotKey skips the panel slot when a restored combo would collide with it") {
        // A pre-#39 user who recorded ⇧⌥Space for quick-capture: the new panel
        // default is also ⇧⌥Space, so the two coincide. registering both would
        // fire ambiguously, so the panel slot is skipped until the user re-picks.
        let prefs = InMemoryPreferences()
        prefs.hotKey = .defaultPanel // = ⇧⌥Space, same as the panel default
        let service = FakeHotKeyService()
        let model = hotKeyModel(preferences: prefs, service: service)
        t.expectEqual(model.hotKey, .defaultPanel)
        t.expectEqual(model.panelHotKey, .defaultPanel) // defaulted, collides

        model.registerHotKey()

        t.expectEqual(service.registered, .defaultPanel)   // quick-capture still registers
        t.expect(service.registeredPanel == nil, "the colliding panel slot must be skipped")
    }

    await t.test("setPanelHotKey persists the new shortcut and registers it into the panel slot") {
        let prefs = InMemoryPreferences()
        let service = FakeHotKeyService()
        let model = hotKeyModel(preferences: prefs, service: service)
        let newKey = HotKey(keyCode: 40, carbonModifiers:
            HotKey.CarbonModifier.command | HotKey.CarbonModifier.control)

        model.setPanelHotKey(newKey)

        t.expectEqual(model.panelHotKey, newKey)
        t.expectEqual(prefs.panelHotKey, newKey)          // persisted for the next launch
        t.expectEqual(service.registeredPanel, newKey)    // re-registered live, into the panel slot
        t.expect(service.registered == nil, "the quick-capture slot must be left alone")
    }

    await t.test("setPanelHotKey ignores a modifier-only combination") {
        let prefs = InMemoryPreferences()
        let service = FakeHotKeyService()
        let model = hotKeyModel(preferences: prefs, service: service)
        let invalid = HotKey(keyCode: 56, carbonModifiers: HotKey.CarbonModifier.shift) // Shift alone

        model.setPanelHotKey(invalid)

        t.expectEqual(model.panelHotKey, .defaultPanel) // unchanged
        t.expect(prefs.panelHotKey == nil, "an invalid shortcut must not be persisted")
        t.expect(service.registeredPanel == nil, "an invalid shortcut must not be registered")
    }

    await t.test("the two hotkeys can never be set identical - each setter rejects the other's combo") {
        let prefs = InMemoryPreferences()
        let service = FakeHotKeyService()
        let model = hotKeyModel(preferences: prefs, service: service)

        // setPanelHotKey ignores a combo equal to the quick-capture hotkey (⌥Space).
        model.setPanelHotKey(.default)
        t.expectEqual(model.panelHotKey, .defaultPanel) // unchanged - collision rejected
        t.expect(service.registeredPanel == nil, "a colliding panel shortcut must not register")

        // setHotKey ignores a combo equal to the show-panel hotkey (⇧⌥Space).
        model.setHotKey(.defaultPanel)
        t.expectEqual(model.hotKey, .default) // unchanged - collision rejected
        t.expect(service.registered == nil, "a colliding quick-capture shortcut must not register")

        // A genuinely distinct combo is still accepted for each.
        let cmdK = HotKey(keyCode: 40, carbonModifiers: HotKey.CarbonModifier.command)
        model.setPanelHotKey(cmdK)
        t.expectEqual(model.panelHotKey, cmdK)
    }

    t.suite("AppModel quick-capture create (#34)")

    await t.test("capturing a task creates it, shows the new row, and leaves the composer untouched") {
        let stub = RoutingStubHTTPClient(
            schema: try fixtureData("data_source_schema"),
            query: try fixtureData("query_response"))
        stub.create = createdPageJSON(id: "cap-1", title: "Call the plumber",
                                      category: "👨🏻‍💻 Work", priority: "P1")
        let cache = InMemoryTaskCache()
        let model = await loadedModel(stub: stub, cache: cache)

        await model.captureTask(
            TaskDraft(title: "Call the plumber", priority: "P1", category: "👨🏻‍💻 Work"))

        guard case .loaded(let tasks) = model.state else {
            t.expect(false, "expected .loaded, got \(model.state)"); return
        }
        t.expect(tasks.contains { $0.id == "cap-1" }, "the captured task should appear in the loaded list")
        t.expect(!model.isComposing, "capture must never open the composer")
        t.expect(model.createError == nil, "capture failures surface via captureError, not the composer's")
        t.expect(model.captureError == nil, "a successful capture leaves no error")
        t.expect(cache.saved.last?.tasks.contains { $0.id == "cap-1" } == true,
                 "the captured task must be cached, or a relaunch loses it")
    }

    await t.test("a failed capture stashes an error for the panel and adds no phantom row") {
        let stub = RoutingStubHTTPClient(
            schema: try fixtureData("data_source_schema"),
            query: try fixtureData("query_response"))
        stub.createStatusCode = 500
        let model = await loadedModel(stub: stub)
        guard case .loaded(let before) = model.state else {
            t.expect(false, "expected .loaded, got \(model.state)"); return
        }

        await model.captureTask(TaskDraft(title: "Doomed capture"))

        t.expect(model.captureError != nil, "a failed capture must stash a reason for the next panel open")
        t.expect(model.createError == nil, "the composer's error must stay clear - capture doesn't use it")
        t.expect(!model.isComposing, "capture never opens the composer")
        guard case .loaded(let after) = model.state else {
            t.expect(false, "expected .loaded, got \(model.state)"); return
        }
        t.expectEqual(after.map(\.id), before.map(\.id)) // nothing was added
    }

    await t.test("a capture failure survives a background refresh so it reaches the next panel open") {
        let stub = RoutingStubHTTPClient(
            schema: try fixtureData("data_source_schema"),
            query: try fixtureData("query_response"))
        stub.createStatusCode = 500
        let model = await loadedModel(stub: stub)
        await model.captureTask(TaskDraft(title: "Doomed"))
        t.expect(model.captureError != nil, "precondition: the capture failed")

        // Unlike writeError, a poll refresh must NOT clear this - the panel may
        // be shut for minutes, and the whole point is to surface it on next open.
        await model.refresh()

        t.expect(model.captureError != nil,
                 "a poll refresh must not swallow the capture failure before it is seen")
    }

    await t.test("the panel clears a shown capture failure on close") {
        let stub = RoutingStubHTTPClient(
            schema: try fixtureData("data_source_schema"),
            query: try fixtureData("query_response"))
        stub.createStatusCode = 500
        let model = await loadedModel(stub: stub)
        await model.captureTask(TaskDraft(title: "Doomed"))
        t.expect(model.captureError != nil, "precondition: the capture failed")

        model.clearCaptureError()

        t.expect(model.captureError == nil, "closing the panel clears the error it just showed")
    }

    await t.test("a 401 while capturing drops the token and routes to reconnect, not a banner") {
        let store = InMemoryTokenStore(seed: "ntn_saved")
        let stub = RoutingStubHTTPClient(
            schema: try fixtureData("data_source_schema"),
            query: try fixtureData("query_response"))
        let model = AppModel(tokenStore: store) {
            NotionClient(dataSourceID: ds, token: $0, http: stub, sleep: { _ in })
        }
        await model.start()
        stub.createStatusCode = 401

        await model.captureTask(TaskDraft(title: "Rejected"))

        t.expect(store.read() == nil, "a rejected token must be cleared")
        if case .failed = model.state {} else {
            t.expect(false, "a dead token must route to reconnect, got \(model.state)")
        }
    }

    await t.test("a rate-limited capture names the throttle") {
        let stub = RoutingStubHTTPClient(
            schema: try fixtureData("data_source_schema"),
            query: try fixtureData("query_response"))
        stub.createStatusCode = 429
        let model = await loadedModel(stub: stub)

        await model.captureTask(TaskDraft(title: "Throttled"))

        t.expect(model.captureError?.localizedCaseInsensitiveContains("rate") == true,
                 "throttling must be named, was \(model.captureError ?? "nil")")
    }

    await t.test("capturing a blank title sends nothing") {
        let stub = RoutingStubHTTPClient(
            schema: try fixtureData("data_source_schema"),
            query: try fixtureData("query_response"))
        let model = await loadedModel(stub: stub)

        await model.captureTask(TaskDraft(title: "   \n"))

        t.expect(!stub.requests.contains {
            $0.httpMethod == "POST" && $0.url?.absoluteString.hasSuffix("/pages") == true
        }, "a blank capture is not worth a write")
    }

    t.suite("AppModel optimistic quick-capture (#37)")

    func routingStub() throws -> RoutingStubHTTPClient {
        RoutingStubHTTPClient(
            schema: try fixtureData("data_source_schema"),
            query: try fixtureData("query_response"))
    }

    /// Spin the cooperative executor until `condition` holds or we give up, so a
    /// check can wait for an async side effect (a provisional insert, a tick)
    /// without a real sleep.
    func spin(until condition: @escaping () -> Bool) async {
        var spins = 0
        while !condition(), spins < 1000 { await Task.yield(); spins += 1 }
    }

    await t.test("a provisional row appears before the create returns, then swaps for the real task") {
        let routing = try routingStub()
        routing.create = createdPageJSON(id: "cap-real", title: "Call the plumber", category: "👨🏻‍💻 Work")
        let gate = CreateGateHTTPClient(wrapping: routing)
        let cache = InMemoryTaskCache()
        let model = AppModel(tokenStore: InMemoryTokenStore(seed: "ntn_saved"), cache: cache) {
            NotionClient(dataSourceID: ds, token: $0, http: gate, sleep: { _ in })
        }
        await model.start()

        let capture = Task { await model.captureTask(TaskDraft(title: "Call the plumber", category: "👨🏻‍💻 Work")) }
        await spin { if case .loaded(let tasks) = model.state { return tasks.contains { $0.isProvisional } }; return false }

        guard case .loaded(let midFlight) = model.state else { t.expect(false, "expected .loaded"); return }
        let temp = midFlight.first { $0.isProvisional }
        t.expect(temp != nil, "a provisional row must show before the create returns")
        t.expectEqual(temp?.title, "Call the plumber")
        t.expect(temp?.status == "To Do", "the provisional row defaults to the DB's To Do status")
        t.expect(cache.saved.last?.tasks.contains { $0.isProvisional } != true, "a temp row must never be cached")

        await gate.open()
        let outcome = await capture.value
        t.expectEqual(outcome, .captured)
        guard case .loaded(let after) = model.state else { t.expect(false, "expected .loaded"); return }
        t.expect(!after.contains { $0.isProvisional }, "the temp row must be gone after reconcile")
        t.expect(after.contains { $0.id == "cap-real" }, "the real task must replace the temp row")
        t.expect(cache.saved.last?.tasks.contains { $0.id == "cap-real" } == true, "the real task must be cached")
        t.expect(cache.saved.last?.tasks.contains { $0.isProvisional } != true, "the cache must never hold a temp row")
    }

    await t.test("a transient capture failure rolls the provisional row back and preserves nothing in the cache") {
        let routing = try routingStub()
        routing.createStatusCode = 500
        let cache = InMemoryTaskCache()
        let model = await loadedModel(stub: routing, cache: cache)
        guard case .loaded(let before) = model.state else { t.expect(false, "expected .loaded"); return }
        let savesBefore = cache.saved.count

        let outcome = await model.captureTask(
            TaskDraft(title: "Doomed", priority: "P1", category: "👨🏻‍💻 Work"))

        t.expectEqual(outcome, .transientFailure)
        guard case .loaded(let after) = model.state else { t.expect(false, "expected .loaded"); return }
        t.expectEqual(after.map(\.id), before.map(\.id)) // the provisional row is gone
        t.expect(!after.contains { $0.isProvisional }, "no provisional row must survive a failure")
        t.expect(model.captureError != nil, "the failure must surface for the next panel open")
        t.expectEqual(cache.saved.count, savesBefore) // a failed create writes nothing to the cache
    }

    await t.test("a 401 while capturing removes the provisional row, drops the token, and reports authFailure") {
        let store = InMemoryTokenStore(seed: "ntn_saved")
        let routing = try routingStub()
        let model = AppModel(tokenStore: store) {
            NotionClient(dataSourceID: ds, token: $0, http: routing, sleep: { _ in })
        }
        await model.start()
        routing.createStatusCode = 401

        let outcome = await model.captureTask(TaskDraft(title: "Rejected"))

        t.expectEqual(outcome, .authFailure)
        t.expect(store.read() == nil, "a rejected token must be dropped")
        if case .failed = model.state {} else { t.expect(false, "a dead token must route to reconnect, got \(model.state)") }
    }

    await t.test("a refresh landing mid-capture keeps the provisional row from flickering out") {
        let routing = try routingStub()
        routing.create = createdPageJSON(id: "cap-late", title: "Later", category: "👨🏻‍💻 Work")
        let gate = CreateGateHTTPClient(wrapping: routing)
        let model = AppModel(tokenStore: InMemoryTokenStore(seed: "ntn_saved")) {
            NotionClient(dataSourceID: ds, token: $0, http: gate, sleep: { _ in })
        }
        await model.start()

        let capture = Task { await model.captureTask(TaskDraft(title: "Later", category: "👨🏻‍💻 Work")) }
        await spin { if case .loaded(let tasks) = model.state { return tasks.contains { $0.isProvisional } }; return false }

        // A full refresh lands while the create is still in flight; the reads
        // succeed (only the create is gated), and the fetch must not drop the row.
        await model.refresh()
        guard case .loaded(let afterRefresh) = model.state else { t.expect(false, "expected .loaded"); return }
        t.expect(afterRefresh.contains { $0.isProvisional },
                 "a mid-capture refresh must carry the provisional row across")

        await gate.open()
        _ = await capture.value
        guard case .loaded(let after) = model.state else { t.expect(false, "expected .loaded"); return }
        t.expect(!after.contains { $0.isProvisional }, "the row reconciles once the create returns")
        t.expect(after.contains { $0.id == "cap-late" }, "the real task lands")
    }

    await t.test("two concurrent captures each show a row and reconcile without cross-talk") {
        let routing = try routingStub()
        routing.create = createdPageJSON(id: "cap-x", title: "X", category: "👨🏻‍💻 Work")
        let gate = CreateGateHTTPClient(wrapping: routing)
        let model = AppModel(tokenStore: InMemoryTokenStore(seed: "ntn_saved")) {
            NotionClient(dataSourceID: ds, token: $0, http: gate, sleep: { _ in })
        }
        await model.start()
        guard case .loaded(let before) = model.state else { t.expect(false, "expected .loaded"); return }

        let a = Task { await model.captureTask(TaskDraft(title: "First", category: "👨🏻‍💻 Work")) }
        let b = Task { await model.captureTask(TaskDraft(title: "Second", category: "👨🏻‍💻 Work")) }
        await spin { if case .loaded(let tasks) = model.state { return tasks.filter { $0.isProvisional }.count == 2 }; return false }
        guard case .loaded(let midFlight) = model.state else { t.expect(false, "expected .loaded"); return }
        t.expectEqual(midFlight.filter { $0.isProvisional }.count, 2)

        await gate.open()
        _ = await a.value
        _ = await b.value
        guard case .loaded(let after) = model.state else { t.expect(false, "expected .loaded"); return }
        t.expect(!after.contains { $0.isProvisional }, "both temp rows must clear - no orphan from cross-talk")
        t.expectEqual(after.count, before.count + 2) // two captures, two rows reconciled
    }

    await t.test("row actions are inert on a provisional quick-capture row") {
        let routing = try routingStub()
        let gate = CreateGateHTTPClient(wrapping: routing)
        let model = AppModel(tokenStore: InMemoryTokenStore(seed: "ntn_saved")) {
            NotionClient(dataSourceID: ds, token: $0, http: gate, sleep: { _ in })
        }
        await model.start()

        let capture = Task { await model.captureTask(TaskDraft(title: "Pending", category: "👨🏻‍💻 Work")) }
        await spin { if case .loaded(let tasks) = model.state { return tasks.contains { $0.isProvisional } }; return false }
        guard case .loaded(let tasks) = model.state, let temp = tasks.first(where: { $0.isProvisional }) else {
            t.expect(false, "expected a provisional row"); return
        }
        let writesBefore = routing.requests.filter { $0.httpMethod == "PATCH" }.count

        await model.setStatus(taskID: temp.id, to: "Done")
        await model.setPriority(taskID: temp.id, to: "P0")
        await model.setDueDate(taskID: temp.id, to: createToday)
        await model.setTitle(taskID: temp.id, to: "Renamed")
        await model.complete(taskID: temp.id)

        t.expectEqual(routing.requests.filter { $0.httpMethod == "PATCH" }.count, writesBefore) // no write fired
        t.expect(!model.pendingCompletion.contains(temp.id), "complete must not tick a temp row")
        guard case .loaded(let after) = model.state, let same = after.first(where: { $0.id == temp.id }) else {
            t.expect(false, "the temp row must be untouched"); return
        }
        t.expectEqual(same.title, "Pending")

        await gate.open()
        _ = await capture.value
    }

    await t.test("capturing before a list is loaded falls back to a plain create") {
        let routing = try routingStub()
        routing.create = createdPageJSON(id: "cap-fallback", title: "Offline capture")
        let model = AppModel(tokenStore: InMemoryTokenStore(seed: "ntn_saved")) {
            NotionClient(dataSourceID: ds, token: $0, http: routing, sleep: { _ in })
        }
        // No start(): state is .needsToken, not .loaded.

        let outcome = await model.captureTask(TaskDraft(title: "Offline capture"))

        t.expectEqual(outcome, .captured)
        t.expect(routing.requests.contains {
            $0.httpMethod == "POST" && $0.url?.absoluteString.hasSuffix("/pages") == true
        }, "the task must still be created even with no list on screen")
        if case .loaded = model.state { t.expect(false, "capturing without a load must not fabricate a loaded state") }
    }

    t.suite("AppModel quick-capture & work in Claude Code (#40)")

    func patchCount(_ stub: RoutingStubHTTPClient) -> Int {
        stub.requests.filter { $0.httpMethod == "PATCH" }.count
    }

    await t.test("captureTask(beginWorking: true) files the task and flips the created row To Do → In Progress") {
        let stub = try routingStub()
        stub.create = createdPageJSON(id: "cap-work", title: "Ship the release",
                                      status: "To Do", category: "👨🏻‍💻 Work")
        let model = await loadedModel(stub: stub)

        let outcome = await model.captureTask(
            TaskDraft(title: "Ship the release", category: "👨🏻‍💻 Work"), beginWorking: true)

        t.expectEqual(outcome, .captured)
        guard case .loaded(let tasks) = model.state else {
            t.expect(false, "expected .loaded, got \(model.state)"); return
        }
        let created = try require(tasks.first { $0.id == "cap-work" })
        t.expect(created.status == "In Progress",
                 "the captured row should flip to In Progress, was \(created.status ?? "nil")")
        // The In Progress flip goes through the pessimistic status PATCH.
        t.expect(stub.requests.contains {
            $0.httpMethod == "PATCH" && $0.url?.absoluteString.hasSuffix("/pages/cap-work") == true
        }, "beginWorking must PATCH the created page to In Progress")
        t.expect(model.captureError == nil, "a successful capture leaves no error")
    }

    await t.test("captureTask(beginWorking: true) attempts no status write when the create fails") {
        let stub = try routingStub()
        stub.createStatusCode = 500 // the create fails before any status flip
        let model = await loadedModel(stub: stub)
        guard case .loaded(let before) = model.state else {
            t.expect(false, "expected .loaded, got \(model.state)"); return
        }

        let outcome = await model.captureTask(TaskDraft(title: "Doomed"), beginWorking: true)

        t.expectEqual(outcome, .transientFailure)
        t.expectEqual(patchCount(stub), 0) // no In Progress write on a rolled-back provisional row
        t.expect(model.captureError != nil, "the create failure still surfaces for the next panel open")
        guard case .loaded(let after) = model.state else {
            t.expect(false, "expected .loaded, got \(model.state)"); return
        }
        t.expectEqual(after.map(\.id), before.map(\.id)) // the provisional row was rolled back
    }

    await t.test("a plain capture (beginWorking defaulted false) never PATCHes a status") {
        let stub = try routingStub()
        stub.create = createdPageJSON(id: "cap-plain", title: "Just file it", category: "👨🏻‍💻 Work")
        let model = await loadedModel(stub: stub)

        await model.captureTask(TaskDraft(title: "Just file it", category: "👨🏻‍💻 Work"))

        t.expectEqual(patchCount(stub), 0) // plain Enter files as To Do, no status change
        guard case .loaded(let tasks) = model.state else {
            t.expect(false, "expected .loaded, got \(model.state)"); return
        }
        t.expect(tasks.first { $0.id == "cap-plain" }?.status == "To Do",
                 "a plain capture stays at the DB-default To Do")
    }

    t.suite("AppModel completion tick (#36)")

    /// A loaded model on All open (every open task visible) with the UI-timing
    /// seam driven by `ticker`, so a check can hold the completion dwell.
    func completionModel(stub: RoutingStubHTTPClient, ticker: UITicker,
                         store: InMemoryTokenStore = InMemoryTokenStore(seed: "ntn_saved"),
                         cache: InMemoryTaskCache? = nil) async -> AppModel {
        let model = AppModel(tokenStore: store, cache: cache, uiSleep: ticker.sleep) {
            NotionClient(dataSourceID: ds, token: $0, http: stub, sleep: { _ in })
        }
        await model.start()
        model.selectPreset(.allOpen)
        return model
    }

    func isVisible(_ id: String, in model: AppModel) -> Bool {
        model.groups().contains { $0.tasks.contains { $0.id == id } }
    }

    await t.test("completing shows the tick at once, holds the row through the dwell, then collapses it on success") {
        let routing = try routingStub()
        let ticker = UITicker()
        let model = await completionModel(stub: routing, ticker: ticker)

        let complete = Task { await model.complete(taskID: firstTaskID) }
        await spin { model.pendingCompletion.contains(firstTaskID) }

        t.expect(model.pendingCompletion.contains(firstTaskID), "the tick must show at once")
        t.expect(isVisible(firstTaskID, in: model), "the row stays visible while it dwells ticked")

        await ticker.tick() // the dwell elapses
        _ = await complete.value

        t.expect(!model.pendingCompletion.contains(firstTaskID), "no longer dwelling after success")
        t.expect(!isVisible(firstTaskID, in: model), "the completed row collapses out")
        if case .loaded(let tasks) = model.state {
            t.expectEqual(tasks.first { $0.id == firstTaskID }?.status, "Done")
        }
    }

    await t.test("a re-click while a task is dwelling is inert - no second write") {
        let routing = try routingStub()
        let ticker = UITicker()
        let model = await completionModel(stub: routing, ticker: ticker)

        let complete = Task { await model.complete(taskID: firstTaskID) }
        await spin { model.pendingCompletion.contains(firstTaskID) }
        await model.complete(taskID: firstTaskID) // re-click mid-dwell: must return at once, inert

        await ticker.tick()
        _ = await complete.value
        t.expect(routing.requests.filter { $0.httpMethod == "PATCH" }.count == 1,
                 "two clicks on a dwelling task must still fire exactly one write")
    }

    await t.test("a failed completion write bounces the row back, flashes it, and surfaces a write error") {
        let routing = try routingStub()
        let ticker = UITicker()
        let model = await completionModel(stub: routing, ticker: ticker)
        // The status PATCH routes to the stub's default branch; fail it now that
        // the load has finished, so only the completion write 500s.
        routing.schemaStatusCode = 500

        let complete = Task { await model.complete(taskID: firstTaskID) }
        await spin { model.pendingCompletion.contains(firstTaskID) }
        await ticker.tick()
        _ = await complete.value

        t.expect(!model.pendingCompletion.contains(firstTaskID), "no longer dwelling")
        t.expect(isVisible(firstTaskID, in: model), "a failed completion leaves the row - it bounced back")
        t.expect(model.restoredCompletions.contains(firstTaskID), "the bounced-back row flashes")
        t.expect(model.writeError != nil, "the failure surfaces the write-error banner")
        if case .loaded(let tasks) = model.state {
            t.expectEqual(tasks.first { $0.id == firstTaskID }?.status, "In Progress") // unchanged
        }
    }

    await t.test("a 401 during completion drops the token and routes to reconnect") {
        let store = InMemoryTokenStore(seed: "ntn_saved")
        let routing = try routingStub()
        let ticker = UITicker()
        let model = await completionModel(stub: routing, ticker: ticker, store: store)
        routing.schemaStatusCode = 401 // the completion PATCH 401s

        let complete = Task { await model.complete(taskID: firstTaskID) }
        await spin { model.pendingCompletion.contains(firstTaskID) }
        await ticker.tick()
        _ = await complete.value

        t.expect(store.read() == nil, "a rejected token must be dropped")
        if case .failed = model.state {} else { t.expect(false, "must route to reconnect, got \(model.state)") }
        t.expect(!model.pendingCompletion.contains(firstTaskID), "the dwell set clears on auth failure")
    }

    t.suite("AppModel work in Claude Code (#35)")

    let doneID = "11111111-0000-0000-0000-000000000004" // "Renew SSL certificate", Done
    let todoID = "11111111-0000-0000-0000-000000000002" // "Draft the Q3 board update", To Do

    await t.test("the Claude seed carries the title and url, degrading to title-only when there's no url") {
        t.expectEqual(ClaudeCodeLaunch.seed(title: "Fix the bike", url: "https://www.notion.so/abc"),
                      "Help with: Fix the bike (https://www.notion.so/abc)")
        t.expectEqual(ClaudeCodeLaunch.seed(title: "Fix the bike", url: nil), "Help with: Fix the bike")
        t.expectEqual(ClaudeCodeLaunch.seed(title: "Fix the bike", url: ""), "Help with: Fix the bike")
    }

    await t.test("the shell command escapes the seed and directory, and expands a leading tilde") {
        let seed = ClaudeCodeLaunch.seed(title: "Fix O'Brien's $PATH `now`", url: nil)
        let cmd = ClaudeCodeLaunch.shellCommand(
            workspaceDirectory: "~/Documents/workspace", seed: seed, home: "/Users/tester")
        // The tilde expands (the shell won't expand it inside single quotes).
        t.expect(cmd.hasPrefix("cd '/Users/tester/Documents/workspace' && claude '"),
                 "tilde must expand and the dir be quoted; was \(cmd)")
        // The apostrophes are broken out with the '\'' idiom, so nothing injects.
        t.expect(cmd.contains("O'\\''Brien'\\''s"), "single quotes must be escaped; was \(cmd)")
        // A `$` and backticks inside single quotes are inert - carried verbatim.
        t.expect(cmd.contains("$PATH `now`"), "shell metacharacters must be carried literally; was \(cmd)")
    }

    await t.test("the iTerm AppleScript embeds the command as an escaped string literal") {
        let script = ClaudeCodeLaunch.iTermScript(command: "echo \"hi\" \\ bye")
        t.expect(script.contains("tell application \"iTerm\""), "the script must target iTerm; was \(script)")
        t.expect(script.contains("write text \"echo \\\"hi\\\" \\\\ bye\""),
                 "the command's quotes and backslashes must be escaped for AppleScript; was \(script)")
    }

    await t.test("beginWorking flips a task to In Progress, but skips one already In Progress or Done") {
        let routing = try routingStub()
        let model = await loadedModel(stub: routing)
        func patchCount() -> Int { routing.requests.filter { $0.httpMethod == "PATCH" }.count }

        let before = patchCount()
        await model.beginWorking(taskID: firstTaskID) // already In Progress → no write
        t.expectEqual(patchCount(), before)
        await model.beginWorking(taskID: doneID) // Done → no write
        t.expectEqual(patchCount(), before)

        await model.beginWorking(taskID: todoID) // To Do → flip to In Progress
        t.expect(patchCount() > before, "a To Do task is moved to In Progress")
        if case .loaded(let tasks) = model.state {
            t.expectEqual(tasks.first { $0.id == todoID }?.status, "In Progress")
        }
    }

    await t.test("the Claude workspace directory defaults, and a change persists and round-trips") {
        let prefs = InMemoryPreferences()
        let routing = try routingStub()
        let model = AppModel(tokenStore: InMemoryTokenStore(seed: "ntn_saved"), preferences: prefs) {
            NotionClient(dataSourceID: ds, token: $0, http: routing, sleep: { _ in })
        }
        t.expectEqual(model.claudeWorkspaceDirectory, "~/Documents/workspace")

        model.setClaudeWorkspaceDirectory("/Users/tester/code")
        t.expectEqual(model.claudeWorkspaceDirectory, "/Users/tester/code")
        t.expectEqual(prefs.claudeWorkspaceDirectory, "/Users/tester/code")

        model.setClaudeWorkspaceDirectory("   ") // blank is ignored - nowhere to launch
        t.expectEqual(model.claudeWorkspaceDirectory, "/Users/tester/code")

        let prefs2 = InMemoryPreferences()
        prefs2.claudeWorkspaceDirectory = "/srv/work"
        let model2 = AppModel(tokenStore: InMemoryTokenStore(seed: "ntn_saved"), preferences: prefs2) {
            NotionClient(dataSourceID: ds, token: $0, http: routing, sleep: { _ in })
        }
        t.expectEqual(model2.claudeWorkspaceDirectory, "/srv/work")
    }
}
