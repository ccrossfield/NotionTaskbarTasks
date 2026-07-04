import Foundation
import NotionTasksCore

/// One scripted reply the stub can play: a body, a status code, and any
/// response headers (e.g. `Retry-After`).
struct StubResponse {
    let data: Data
    let statusCode: Int
    let headers: [String: String]

    init(data: Data, statusCode: Int, headers: [String: String] = [:]) {
        self.data = data
        self.statusCode = statusCode
        self.headers = headers
    }
}

/// Records the request it was handed and replays a canned response — the HTTP
/// transport seam. No network.
///
/// It has two modes. The original single-response mode is unchanged: every call
/// returns the same `responseData`/`statusCode`. It can instead be given a
/// *script* of responses to play in order (the last one repeats once the script
/// is exhausted), which lets a suite exercise a 429-then-200 retry sequence. It
/// records how many requests it received via `requestCount`.
final class StubHTTPClient: HTTPClient {
    var responseData: Data
    var statusCode: Int
    private(set) var lastRequest: URLRequest?
    /// Every request received, in order — lets a check assert on an earlier
    /// request in a multi-page sequence, not just the last.
    private(set) var requests: [URLRequest] = []
    private(set) var requestCount = 0

    private let script: [StubResponse]?

    init(responseData: Data, statusCode: Int) {
        self.responseData = responseData
        self.statusCode = statusCode
        self.script = nil
    }

    /// Play `script` in order; once exhausted the final response repeats.
    init(script: [StubResponse]) {
        precondition(!script.isEmpty, "script must not be empty")
        self.script = script
        self.responseData = script[0].data
        self.statusCode = script[0].statusCode
    }

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        lastRequest = request
        requests.append(request)
        defer { requestCount += 1 }

        let data: Data
        let statusCode: Int
        let headers: [String: String]
        if let script {
            let step = script[min(requestCount, script.count - 1)]
            data = step.data
            statusCode = step.statusCode
            headers = step.headers
        } else {
            data = responseData
            statusCode = self.statusCode
            headers = [:]
        }

        let response = HTTPURLResponse(
            url: request.url!, statusCode: statusCode, httpVersion: nil, headerFields: headers)!
        return (data, response)
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

    await t.test("a 403 also surfaces as .unauthorized - the token lacks access, so reconnect") {
        let stub = StubHTTPClient(responseData: Data("{}".utf8), statusCode: 403)
        let client = NotionClient(dataSourceID: dataSource, token: "unshared", http: stub)
        do {
            _ = try await client.fetchTasks()
            t.expect(false, "expected fetchTasks to throw")
        } catch NotionClientError.unauthorized {
            // pass — a 403 (integration not shared with the DB) is fixed the
            // same way as a 401: by sorting the token out, not by retrying.
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

    await t.test("updateTitle PATCHes the page with the title shape, keyed by the resolved name (#28)") {
        let stub = StubHTTPClient(responseData: Data(), statusCode: 200)
        let client = NotionClient(dataSourceID: dataSource, token: "ntn_test", http: stub)

        try await client.updateTitle(pageID: "page-123", to: "New name",
                                     titleProperty: "Renamed title")

        let request = try require(stub.lastRequest)
        t.expect(request.httpMethod == "PATCH", "method was \(request.httpMethod ?? "nil")")
        t.expect(request.url?.absoluteString == "https://api.notion.com/v1/pages/page-123",
                 "url was \(request.url?.absoluteString ?? "nil")")
        t.expect(request.value(forHTTPHeaderField: "Notion-Version") == "2025-09-03", "version header")
        t.expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer ntn_test", "auth header")

        // Exactly {"properties":{<name>:{"title":[{"text":{"content":...}}]}}}.
        let body = try require(request.httpBody)
        let json = try JSONSerialization.jsonObject(with: body) as? [String: Any]
        t.expect((json?.keys.sorted() ?? []) == ["properties"],
                 "top-level keys were \(json?.keys.sorted() ?? [])")
        let props = json?["properties"] as? [String: Any]
        // The title is keyed by the resolved property name, so a rename of the
        // property in Notion is carried through like the create path.
        t.expect(props?.keys.sorted() == ["Renamed title"],
                 "title should be keyed by the resolved name, keys were \(props?.keys.sorted() ?? [])")
        let content = (((props?["Renamed title"] as? [String: Any])?["title"]
            as? [[String: Any]])?.first?["text"] as? [String: Any])?["content"] as? String
        t.expect(content == "New name", "title content was \(content ?? "nil")")
    }

    await t.test("a failed title write throws (#28)") {
        let stub = StubHTTPClient(responseData: Data(), statusCode: 500)
        let client = NotionClient(dataSourceID: dataSource, token: "t", http: stub)
        do {
            try await client.updateTitle(pageID: "p", to: "New name", titleProperty: "Task")
            t.expect(false, "expected updateTitle to throw")
        } catch NotionClientError.httpError(let code) {
            t.expectEqual(code, 500)
        } catch {
            t.expect(false, "wrong error: \(error)")
        }
    }

    t.suite("NotionClient pagination")

    // A minimal query-response page: one task, plus the paging fields. The real
    // DB has >100 tasks, so a single page_size:100 request silently drops the
    // rest — fetchTasks must follow next_cursor until has_more is false.
    func pageJSON(taskID: String, title: String, nextCursor: String?) -> Data {
        let cursorFields = nextCursor.map { "\"has_more\": true, \"next_cursor\": \"\($0)\"" }
            ?? "\"has_more\": false, \"next_cursor\": null"
        return Data("""
        {
          "object": "list",
          "results": [{
            "id": "\(taskID)",
            "properties": {
              "Task": { "type": "title", "title": [{ "plain_text": "\(title)" }] }
            }
          }],
          \(cursorFields)
        }
        """.utf8)
    }

    await t.test("fetchTasks follows next_cursor and returns every page's tasks") {
        let stub = StubHTTPClient(script: [
            StubResponse(data: pageJSON(taskID: "t1", title: "First", nextCursor: "cur-2"), statusCode: 200),
            StubResponse(data: pageJSON(taskID: "t2", title: "Second", nextCursor: "cur-3"), statusCode: 200),
            StubResponse(data: pageJSON(taskID: "t3", title: "Third", nextCursor: nil), statusCode: 200),
        ])
        let client = NotionClient(dataSourceID: dataSource, token: "ntn_test", http: stub)

        let tasks = try await client.fetchTasks()

        t.expectEqual(stub.requestCount, 3)
        t.expectEqual(tasks.map(\.title), ["First", "Second", "Third"])
    }

    await t.test("the first request has no start_cursor; follow-ups carry the previous next_cursor") {
        let stub = StubHTTPClient(script: [
            StubResponse(data: pageJSON(taskID: "t1", title: "First", nextCursor: "cur-2"), statusCode: 200),
            StubResponse(data: pageJSON(taskID: "t2", title: "Second", nextCursor: nil), statusCode: 200),
        ])
        let client = NotionClient(dataSourceID: dataSource, token: "ntn_test", http: stub)

        _ = try await client.fetchTasks()

        t.expectEqual(stub.requests.count, 2)
        let firstBody = try JSONSerialization.jsonObject(
            with: try require(stub.requests.first?.httpBody)) as? [String: Any]
        t.expect(firstBody?["start_cursor"] == nil, "first request must not send a cursor")
        let secondBody = try JSONSerialization.jsonObject(
            with: try require(stub.requests.last?.httpBody)) as? [String: Any]
        t.expect(secondBody?["start_cursor"] as? String == "cur-2",
                 "second request cursor was \(secondBody?["start_cursor"] as? String ?? "nil")")
        t.expect(secondBody?["page_size"] as? Int == 100, "page_size must persist across pages")
    }

    await t.test("a single page with has_more false makes exactly one request") {
        let stub = StubHTTPClient(script: [
            StubResponse(data: try fixtureData("query_response"), statusCode: 200),
        ])
        let client = NotionClient(dataSourceID: dataSource, token: "ntn_test", http: stub)

        let tasks = try await client.fetchTasks()

        t.expectEqual(stub.requestCount, 1)
        t.expectEqual(tasks.count, 5)
    }

    t.suite("NotionClient rate-limit backoff")

    await t.test("a 429 then a 200 retries and succeeds, sleeping for Retry-After") {
        let stub = StubHTTPClient(script: [
            StubResponse(data: Data("{}".utf8), statusCode: 429, headers: ["Retry-After": "2"]),
            StubResponse(data: try fixtureData("query_response"), statusCode: 200),
        ])
        let sleeps = SleepRecorder()
        let client = NotionClient(dataSourceID: dataSource, token: "ntn_test", http: stub,
                                  sleep: sleeps.record)

        let tasks = try await client.fetchTasks()

        t.expectEqual(tasks.count, 5)
        t.expectEqual(stub.requestCount, 2)
        t.expectEqual(sleeps.durations, [2])
    }

    await t.test("repeated 429s beyond the retry cap throw .rateLimited") {
        let stub = StubHTTPClient(script: [
            StubResponse(data: Data("{}".utf8), statusCode: 429, headers: ["Retry-After": "1"]),
        ])
        let sleeps = SleepRecorder()
        let client = NotionClient(dataSourceID: dataSource, token: "ntn_test", http: stub,
                                  sleep: sleeps.record)
        do {
            _ = try await client.fetchTasks()
            t.expect(false, "expected fetchTasks to throw")
        } catch NotionClientError.rateLimited {
            // The cap is 3 retries: 4 requests total (initial + 3 retries), 3 sleeps.
            t.expectEqual(stub.requestCount, 4)
            t.expectEqual(sleeps.durations.count, 3)
        } catch {
            t.expect(false, "wrong error: \(error)")
        }
    }

    await t.test("a 429 with no Retry-After header still backs off before retrying") {
        let stub = StubHTTPClient(script: [
            StubResponse(data: Data("{}".utf8), statusCode: 429), // no headers at all
            StubResponse(data: try fixtureData("query_response"), statusCode: 200),
        ])
        let sleeps = SleepRecorder()
        let client = NotionClient(dataSourceID: dataSource, token: "ntn_test", http: stub,
                                  sleep: sleeps.record)

        let tasks = try await client.fetchTasks()

        t.expectEqual(tasks.count, 5)
        t.expectEqual(sleeps.durations.count, 1)
        t.expect(sleeps.durations.allSatisfy { $0 > 0 },
                 "a missing Retry-After must not mean an instant re-send, slept \(sleeps.durations)")
    }

    await t.test("a 429 with an unparseable Retry-After (HTTP-date) uses the non-zero default") {
        let stub = StubHTTPClient(script: [
            StubResponse(data: Data("{}".utf8), statusCode: 429,
                         headers: ["Retry-After": "Wed, 21 Oct 2026 07:28:00 GMT"]),
            StubResponse(data: try fixtureData("query_response"), statusCode: 200),
        ])
        let sleeps = SleepRecorder()
        let client = NotionClient(dataSourceID: dataSource, token: "ntn_test", http: stub,
                                  sleep: sleeps.record)

        _ = try await client.fetchTasks()

        t.expectEqual(sleeps.durations.count, 1)
        t.expect(sleeps.durations.allSatisfy { $0 > 0 },
                 "an unparseable Retry-After must not mean an instant re-send, slept \(sleeps.durations)")
    }

    await t.test("headerless 429s all the way to the cap back off more each attempt") {
        let stub = StubHTTPClient(script: [
            StubResponse(data: Data("{}".utf8), statusCode: 429), // repeats: script's last step replays
        ])
        let sleeps = SleepRecorder()
        let client = NotionClient(dataSourceID: dataSource, token: "ntn_test", http: stub,
                                  sleep: sleeps.record)
        do {
            _ = try await client.fetchTasks()
            t.expect(false, "expected fetchTasks to throw")
        } catch NotionClientError.rateLimited {
            // Exponential 1/2/4: escalating pressure release when Notion gives no guidance.
            t.expectEqual(sleeps.durations, [1, 2, 4])
        } catch {
            t.expect(false, "wrong error: \(error)")
        }
    }

    await t.test("Retry-After is honoured - the sleep duration matches the header") {
        let stub = StubHTTPClient(script: [
            StubResponse(data: Data("{}".utf8), statusCode: 429, headers: ["Retry-After": "7"]),
            StubResponse(data: try fixtureData("query_response"), statusCode: 200),
        ])
        let sleeps = SleepRecorder()
        let client = NotionClient(dataSourceID: dataSource, token: "ntn_test", http: stub,
                                  sleep: sleeps.record)

        _ = try await client.fetchTasks()

        t.expectEqual(sleeps.durations, [7])
    }

    t.suite("NotionClient create path (#22)")

    // What POST /v1/pages returns: a full page object, same shape as a query
    // result row. The Status is what Notion defaulted, never what we sent.
    let createdPage = Data("""
    {
      "id": "page-new-1",
      "created_time": "2026-07-03T10:00:00.000Z",
      "last_edited_time": "2026-07-03T10:00:00.000Z",
      "url": "https://www.notion.so/Book-the-venue-pagenew1",
      "properties": {
        "Task": { "type": "title", "title": [{ "plain_text": "Book the venue" }] },
        "Status": { "type": "status", "status": { "name": "To Do" } },
        "Priority": { "type": "select", "select": { "name": "P1" } }
      }
    }
    """.utf8)

    await t.test("createTask POSTs the data-source parent, the resolved title name, and no Status") {
        let stub = StubHTTPClient(responseData: createdPage, statusCode: 200)
        let client = NotionClient(dataSourceID: dataSource, token: "ntn_test", http: stub)
        let due = Calendar.current.date(
            from: DateComponents(year: 2026, month: 7, day: 14, hour: 12))!
        let draft = TaskDraft(title: "Book the venue", priority: "P1",
                              category: "👨🏻‍💻 Work", dueDate: due)

        _ = try await client.createTask(draft, titleProperty: "Renamed title")

        let request = try require(stub.lastRequest)
        t.expect(request.httpMethod == "POST", "method was \(request.httpMethod ?? "nil")")
        t.expect(request.url?.absoluteString == "https://api.notion.com/v1/pages",
                 "url was \(request.url?.absoluteString ?? "nil")")
        t.expect(request.value(forHTTPHeaderField: "Notion-Version") == "2025-09-03", "version header")

        let body = try JSONSerialization.jsonObject(
            with: try require(request.httpBody)) as? [String: Any]
        // The DB is multi-source: the parent must target the primary data
        // source, exactly like every query does.
        let parent = body?["parent"] as? [String: Any]
        t.expect(parent?["type"] as? String == "data_source_id",
                 "parent type was \(parent?["type"] as? String ?? "nil")")
        t.expect(parent?["data_source_id"] as? String == dataSource,
                 "parent target was \(parent?["data_source_id"] as? String ?? "nil")")

        // Status deliberately absent: Notion applies the DB default, so a
        // renamed default option can never fail the create.
        let properties = body?["properties"] as? [String: Any]
        t.expect(properties?.keys.sorted() == ["Category", "Due Date", "Priority", "Renamed title"],
                 "property keys were \(properties?.keys.sorted() ?? [])")
        let titleContent = (((properties?["Renamed title"] as? [String: Any])?["title"]
            as? [[String: Any]])?.first?["text"] as? [String: Any])?["content"] as? String
        t.expect(titleContent == "Book the venue", "title content was \(titleContent ?? "nil")")
        let priority = ((properties?["Priority"] as? [String: Any])?["select"]
            as? [String: Any])?["name"] as? String
        t.expect(priority == "P1", "priority was \(priority ?? "nil")")
        let category = ((properties?["Category"] as? [String: Any])?["select"]
            as? [String: Any])?["name"] as? String
        t.expect(category == "👨🏻‍💻 Work", "category was \(category ?? "nil")")
        // Date-only, local calendar day - the mirror of the decoder's
        // date-only parse, which anchors to local midnight.
        let start = ((properties?["Due Date"] as? [String: Any])?["date"]
            as? [String: Any])?["start"] as? String
        t.expect(start == "2026-07-14", "due start was \(start ?? "nil")")
    }

    await t.test("a title-only draft sends only the title property") {
        let stub = StubHTTPClient(responseData: createdPage, statusCode: 200)
        let client = NotionClient(dataSourceID: dataSource, token: "ntn_test", http: stub)

        _ = try await client.createTask(TaskDraft(title: "Just a thought"), titleProperty: "Task")

        let body = try JSONSerialization.jsonObject(
            with: try require(stub.lastRequest?.httpBody)) as? [String: Any]
        let properties = body?["properties"] as? [String: Any]
        t.expect(properties?.keys.sorted() == ["Task"],
                 "property keys were \(properties?.keys.sorted() ?? [])")
    }

    await t.test("createTask returns the task decoded from the response - Notion's defaults included") {
        let stub = StubHTTPClient(responseData: createdPage, statusCode: 200)
        let client = NotionClient(dataSourceID: dataSource, token: "ntn_test", http: stub)

        let task = try await client.createTask(TaskDraft(title: "Book the venue"),
                                               titleProperty: "Task")

        t.expectEqual(task.id, "page-new-1")
        t.expectEqual(task.title, "Book the venue")
        // We never sent a Status; the response says what Notion defaulted to.
        t.expect(task.status == "To Do", "status was \(task.status ?? "nil")")
        t.expect(task.priority == "P1", "priority was \(String(describing: task.priority))")
        t.expectEqual(task.url, "https://www.notion.so/Book-the-venue-pagenew1")
    }

    await t.test("a failed create throws") {
        let stub = StubHTTPClient(responseData: Data(), statusCode: 500)
        let client = NotionClient(dataSourceID: dataSource, token: "t", http: stub)
        do {
            _ = try await client.createTask(TaskDraft(title: "Doomed"), titleProperty: "Task")
            t.expect(false, "expected createTask to throw")
        } catch NotionClientError.httpError(let code) {
            t.expectEqual(code, 500)
        } catch {
            t.expect(false, "wrong error: \(error)")
        }
    }
}

/// Captures the durations the injected sleep seam was asked to wait for, so a
/// check can assert on backoff without any real waiting. Locked because the
/// sleep closure is `@Sendable`; each access is a synchronous critical section,
/// so no lock is ever held across a suspension point.
final class SleepRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var _durations: [TimeInterval] = []

    var durations: [TimeInterval] {
        lock.withLock { _durations }
    }

    @Sendable func record(_ seconds: TimeInterval) async {
        lock.withLock { _durations.append(seconds) }
    }
}
