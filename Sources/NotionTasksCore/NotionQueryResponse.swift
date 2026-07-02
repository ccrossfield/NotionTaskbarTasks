import Foundation

/// Decodes the response of `POST /v1/data_sources/{id}/query`.
///
/// Notion keys each page's properties by their (user-chosen) property name and
/// types them, so we can't use a flat `Decodable`. We decode only the property
/// kinds this slice reads — the title and the status — and find them by their
/// Notion `type` rather than a hard-coded property name, so renaming the "Task"
/// or "Status" column in Notion doesn't break decoding.
public struct NotionQueryResponse: Decodable {
    public let results: [Page]
    public let hasMore: Bool
    public let nextCursor: String?

    enum CodingKeys: String, CodingKey {
        case results
        case hasMore = "has_more"
        case nextCursor = "next_cursor"
    }

    /// The pages mapped to the app's task model.
    public var tasks: [NotionTask] { results.map(\.asTask) }

    public struct Page: Decodable {
        public let id: String
        public let properties: [String: Property]

        var asTask: NotionTask {
            let titleProperty = properties.values.first { $0.type == "title" }
            let title = titleProperty?.title?.map(\.plainText).joined() ?? ""
            let statusProperty = properties.values.first { $0.type == "status" }
            return NotionTask(
                id: id,
                title: title.isEmpty ? "(untitled)" : title,
                status: statusProperty?.status?.name
            )
        }
    }

    /// One typed property value. Only the fields this slice reads are declared;
    /// unknown keys (select, date, …) are ignored by the synthesised decoder.
    public struct Property: Decodable {
        public let type: String
        let title: [RichText]?
        let status: StatusValue?
    }

    struct RichText: Decodable {
        let plainText: String
        enum CodingKeys: String, CodingKey { case plainText = "plain_text" }
    }

    struct StatusValue: Decodable {
        let name: String
    }
}
