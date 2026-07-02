import Foundation
import NotionTasksCore

/// Records the request it was handed and replays a canned response — the HTTP
/// transport seam. No network.
final class StubHTTPClient: HTTPClient {
    var responseData: Data
    var statusCode: Int
    private(set) var lastRequest: URLRequest?

    init(responseData: Data, statusCode: Int) {
        self.responseData = responseData
        self.statusCode = statusCode
    }

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        lastRequest = request
        let response = HTTPURLResponse(
            url: request.url!, statusCode: statusCode, httpVersion: nil, headerFields: nil)!
        return (responseData, response)
    }
}

func clientChecks(_ t: CheckRun) async {
    t.suite("NotionClient read path")
    let dataSource = "e19b11fa-a660-4de2-8482-b840210db08f"

    await t.test("fetchTasks POSTs to the data source with pinned version and bearer auth") {
        let stub = StubHTTPClient(responseData: try fixtureData("query_response"), statusCode: 200)
        let client = NotionClient(dataSourceID: dataSource, token: "ntn_test", http: stub)

        let tasks = try await client.fetchTasks()

        let request = try require(stub.lastRequest)
        t.expect(request.httpMethod == "POST", "method was \(request.httpMethod ?? "nil")")
        t.expect(request.url?.absoluteString == "https://api.notion.com/v1/data_sources/\(dataSource)/query",
                 "url was \(request.url?.absoluteString ?? "nil")")
        t.expect(request.value(forHTTPHeaderField: "Notion-Version") == "2025-09-03",
                 "version header was \(request.value(forHTTPHeaderField: "Notion-Version") ?? "nil")")
        t.expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer ntn_test",
                 "auth header was \(request.value(forHTTPHeaderField: "Authorization") ?? "nil")")
        t.expect(request.value(forHTTPHeaderField: "Content-Type") == "application/json",
                 "content-type was \(request.value(forHTTPHeaderField: "Content-Type") ?? "nil")")
        t.expectEqual(tasks.count, 5)
    }

    await t.test("a 401 surfaces as .unauthorized") {
        let stub = StubHTTPClient(responseData: Data("{}".utf8), statusCode: 401)
        let client = NotionClient(dataSourceID: dataSource, token: "bad", http: stub)
        do {
            _ = try await client.fetchTasks()
            t.expect(false, "expected fetchTasks to throw")
        } catch NotionClientError.unauthorized {
            // pass
        } catch {
            t.expect(false, "wrong error: \(error)")
        }
    }

    await t.test("other non-200s surface as .httpError with the status code") {
        let stub = StubHTTPClient(responseData: Data(), statusCode: 500)
        let client = NotionClient(dataSourceID: dataSource, token: "t", http: stub)
        do {
            _ = try await client.fetchTasks()
            t.expect(false, "expected fetchTasks to throw")
        } catch NotionClientError.httpError(let code) {
            t.expectEqual(code, 500)
        } catch {
            t.expect(false, "wrong error: \(error)")
        }
    }

    await t.test("updateStatus PATCHes the page with the status-property shape") {
        let stub = StubHTTPClient(responseData: Data(), statusCode: 200)
        let client = NotionClient(dataSourceID: dataSource, token: "ntn_test", http: stub)

        try await client.updateStatus(pageID: "page-123", to: "Done")

        let request = try require(stub.lastRequest)
        t.expect(request.httpMethod == "PATCH", "method was \(request.httpMethod ?? "nil")")
        t.expect(request.url?.absoluteString == "https://api.notion.com/v1/pages/page-123",
                 "url was \(request.url?.absoluteString ?? "nil")")
        t.expect(request.value(forHTTPHeaderField: "Notion-Version") == "2025-09-03", "version header")
        t.expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer ntn_test", "auth header")

        // Exactly {"properties":{"Status":{"status":{"name":"Done"}}}} — no extra keys.
        let body = try require(request.httpBody)
        let json = try JSONSerialization.jsonObject(with: body) as? [String: Any]
        t.expect((json?.keys.sorted() ?? []) == ["properties"],
                 "top-level keys were \(json?.keys.sorted() ?? [])")
        let statusName = ((((json?["properties"] as? [String: Any])?["Status"] as? [String: Any])?["status"]
            as? [String: Any])?["name"]) as? String
        t.expect(statusName == "Done", "status.name was \(statusName ?? "nil")")
    }

    await t.test("a failed status write throws") {
        let stub = StubHTTPClient(responseData: Data(), statusCode: 500)
        let client = NotionClient(dataSourceID: dataSource, token: "t", http: stub)
        do {
            try await client.updateStatus(pageID: "p", to: "Done")
            t.expect(false, "expected updateStatus to throw")
        } catch NotionClientError.httpError(let code) {
            t.expectEqual(code, 500)
        } catch {
            t.expect(false, "wrong error: \(error)")
        }
    }
}
