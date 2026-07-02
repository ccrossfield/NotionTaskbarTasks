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
        let url = URL(string: "https://api.notion.com/v1/data_sources/\(dataSourceID)/query")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue(notionVersion, forHTTPHeaderField: "Notion-Version")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["page_size": 100])

        let (data, response) = try await http.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw NotionClientError.invalidResponse
        }
        switch httpResponse.statusCode {
        case 200: break
        case 401: throw NotionClientError.unauthorized
        default: throw NotionClientError.httpError(httpResponse.statusCode)
        }
        return try JSONDecoder().decode(NotionQueryResponse.self, from: data).tasks
    }
}
