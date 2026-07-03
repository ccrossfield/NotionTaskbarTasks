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

/// Routes the schema GET vs the query POST to different canned bodies, so a full
/// `AppModel.load` (which fetches both) can be exercised through the seam.
final class RoutingStubHTTPClient: HTTPClient {
    let schema: Data
    let query: Data
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
}
