import Foundation

public enum NotionClientError: Error, Equatable {
    case unauthorized
    case httpError(Int)
    case invalidResponse
    /// Notion kept returning 429 after we exhausted our backoff retries.
    case rateLimited
}

/// The one place the multi-source assumption lives (ADR docs/adr/0001).
public enum NotionConfig {
    /// The primary "🎯 Tasks" data source. The database is multi-source, so
    /// querying the *database* id is ambiguous — everything targets this id.
    public static let dataSourceID = "e19b11fa-a660-4de2-8482-b840210db08f"
    /// The data-sources API version, pinned per ADR-0001.
    public static let notionVersion = "2025-09-03"

    /// The status states offered when changing a task (issue #3) — the four
    /// real options in the Tasks DB. ADR-0001 requires schema-derivation for
    /// the open-status *filter*; this write menu can stay a known set.
    public static let selectableStatuses = ["Blocked", "To Do", "In Progress", "Done"]

    /// Used only if the schema fetch fails. The happy path derives the open set
    /// and the Work category from the live schema (ADR-0001); these keep the app
    /// showing something sensible if that one request doesn't come back.
    public static let fallbackOpenStatuses: Set<String> = ["To Do", "In Progress", "Blocked"]
    public static let fallbackWorkCategory = "👨🏻‍💻 Work"
    /// Used only if the schema fetch fails: the personal categories for the
    /// "Home priorities" preset (#5) — every real Category except Work.
    public static let fallbackPersonalCategories: Set<String> = [
        "👥 Friends & Family", "📝 Life admin", "💻 Tech & Projects", "🎉 Fun admin"
    ]
}

/// Reads tasks from Notion over the raw REST API.
///
/// This slice (issue #2) fetches a single unfiltered page and lists it. Filter,
/// sort, paging and status write-back are later slices.
public struct NotionClient {
    private let dataSourceID: String
    private let token: String
    private let http: HTTPClient
    private let notionVersion: String
    private let sleep: @Sendable (TimeInterval) async -> Void

    /// How many times we retry a 429 before giving up with `.rateLimited`.
    private static let maxRetries = 3

    public init(dataSourceID: String = NotionConfig.dataSourceID,
                token: String,
                http: HTTPClient,
                notionVersion: String = NotionConfig.notionVersion,
                sleep: @escaping @Sendable (TimeInterval) async -> Void = { seconds in
                    try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                }) {
        self.dataSourceID = dataSourceID
        self.token = token
        self.http = http
        self.notionVersion = notionVersion
        self.sleep = sleep
    }

    /// Fetches every task, following `next_cursor` until `has_more` is false.
    /// Notion caps a query response at 100 pages of results, so a single request
    /// silently drops everything past the first 100 tasks.
    public func fetchTasks() async throws -> [NotionTask] {
        var tasks: [NotionTask] = []
        var cursor: String?
        // Backstop against a paging loop that never terminates (a misbehaving
        // cursor); 100 pages = 10,000 tasks, far beyond this personal DB.
        for _ in 0..<100 {
            var body: [String: Any] = ["page_size": 100]
            if let cursor { body["start_cursor"] = cursor }
            let request = makeRequest(path: "data_sources/\(dataSourceID)/query",
                                      method: "POST",
                                      jsonBody: body)
            let data = try await send(request)
            let page = try JSONDecoder().decode(NotionQueryResponse.self, from: data)
            tasks.append(contentsOf: page.tasks)
            guard page.hasMore, let next = page.nextCursor else { return tasks }
            cursor = next
        }
        return tasks
    }

    /// Reads the data source schema (`GET /v1/data_sources/{id}`). Used to derive
    /// the "open" status set at runtime rather than hardcoding it (ADR-0001).
    public func fetchSchema() async throws -> DataSourceSchema {
        let request = makeRequest(path: "data_sources/\(dataSourceID)", method: "GET")
        let data = try await send(request)
        return try JSONDecoder().decode(DataSourceSchema.self, from: data)
    }

    /// Writes a new status to a task's page. Body shape confirmed by the spike
    /// and ADR-0001: `{"properties":{"Status":{"status":{"name":<state>}}}}`.
    public func updateStatus(pageID: String, to state: String) async throws {
        let request = makeRequest(path: "pages/\(pageID)",
                                  method: "PATCH",
                                  jsonBody: ["properties": ["Status": ["status": ["name": state]]]])
        _ = try await send(request)
    }

    private func makeRequest(path: String, method: String, jsonBody: Any? = nil) -> URLRequest {
        var request = URLRequest(url: URL(string: "https://api.notion.com/v1/\(path)")!)
        request.httpMethod = method
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue(notionVersion, forHTTPHeaderField: "Notion-Version")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let jsonBody {
            request.httpBody = try? JSONSerialization.data(withJSONObject: jsonBody)
        }
        return request
    }

    @discardableResult
    private func send(_ request: URLRequest) async throws -> Data {
        // On a 429 we honour the Retry-After header (integer seconds), sleep,
        // and retry - up to `maxRetries` times. If Notion is still throttling
        // us after that, we surface `.rateLimited` rather than hammering on.
        var attempt = 0
        while true {
            let (data, response) = try await http.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse else {
                throw NotionClientError.invalidResponse
            }
            switch httpResponse.statusCode {
            case 200:
                return data
            case 401:
                throw NotionClientError.unauthorized
            case 429:
                guard attempt < Self.maxRetries else {
                    throw NotionClientError.rateLimited
                }
                attempt += 1
                let retryAfter = TimeInterval(
                    httpResponse.value(forHTTPHeaderField: "Retry-After").flatMap(Int.init) ?? 0)
                await sleep(retryAfter)
            default:
                throw NotionClientError.httpError(httpResponse.statusCode)
            }
        }
    }
}
