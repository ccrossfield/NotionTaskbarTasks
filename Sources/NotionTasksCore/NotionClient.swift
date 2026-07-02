import Foundation

public enum NotionClientError: Error, Equatable {
    case unauthorized
    case httpError(Int)
    case invalidResponse
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

    public init(dataSourceID: String = NotionConfig.dataSourceID,
                token: String,
                http: HTTPClient,
                notionVersion: String = NotionConfig.notionVersion) {
        self.dataSourceID = dataSourceID
        self.token = token
        self.http = http
        self.notionVersion = notionVersion
    }

    public func fetchTasks() async throws -> [NotionTask] {
        let request = makeRequest(path: "data_sources/\(dataSourceID)/query",
                                  method: "POST",
                                  jsonBody: ["page_size": 100])
        let data = try await send(request)
        return try JSONDecoder().decode(NotionQueryResponse.self, from: data).tasks
    }

    /// Writes a new status to a task's page. Body shape confirmed by the spike
    /// and ADR-0001: `{"properties":{"Status":{"status":{"name":<state>}}}}`.
    public func updateStatus(pageID: String, to state: String) async throws {
        let request = makeRequest(path: "pages/\(pageID)",
                                  method: "PATCH",
                                  jsonBody: ["properties": ["Status": ["status": ["name": state]]]])
        _ = try await send(request)
    }

    private func makeRequest(path: String, method: String, jsonBody: Any) -> URLRequest {
        var request = URLRequest(url: URL(string: "https://api.notion.com/v1/\(path)")!)
        request.httpMethod = method
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue(notionVersion, forHTTPHeaderField: "Notion-Version")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONSerialization.data(withJSONObject: jsonBody)
        return request
    }

    @discardableResult
    private func send(_ request: URLRequest) async throws -> Data {
        let (data, response) = try await http.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw NotionClientError.invalidResponse
        }
        switch httpResponse.statusCode {
        case 200: return data
        case 401: throw NotionClientError.unauthorized
        default: throw NotionClientError.httpError(httpResponse.statusCode)
        }
    }
}
