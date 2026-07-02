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
}
