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

/// Routes the schema GET vs the query POST to different canned bodies, so a full
/// `AppModel.load` (which fetches both) can be exercised through the seam.
final class RoutingStubHTTPClient: HTTPClient {
    let schema: Data
    var query: Data
    init(schema: Data, query: Data) { self.schema = schema; self.query = query }

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        let isQuery = request.url?.absoluteString.hasSuffix("/query") ?? false
        let response = HTTPURLResponse(
            url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
        return (isQuery ? query : schema, response)
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
        t.expect(done.priority == .p0, "priority drifted to \(String(describing: done.priority))")
        t.expect(done.category == "👨🏻‍💻 Work", "category drifted to \(done.category ?? "nil")")
        t.expect(done.dueDate != nil, "due date was dropped on status change")
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
        t.expectEqual(groups.map(\.priority), [.p0, .p1])
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
        t.expectEqual(model.groups(today: today, calendar: cal).map(\.priority), [.p0, .p1])

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
        t.expectEqual(home.map(\.priority), [.p2])
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
        t.expectEqual(model.groups(today: today, calendar: cal).map(\.priority), [.p0, .p1])
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
                                 status: "To Do", priority: .p2, category: "🧪 Lab")
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
}
