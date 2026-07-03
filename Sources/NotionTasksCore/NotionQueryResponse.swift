import Foundation

/// Decodes the response of `POST /v1/data_sources/{id}/query`.
///
/// Notion keys each page's properties by their (user-chosen) property name and
/// types them, so we can't use a flat `Decodable`. Title and Status are found by
/// their Notion `type`, so renaming those columns doesn't break decoding.
///
/// Priority and Category are *both* `select`, and Due Date and Start from are
/// *both* `date` — `type` can't tell two properties of the same kind apart, so
/// those four are looked up by property *name*. Notion names are user-editable,
/// so renaming one of them in Notion would silently drop that field. Acceptable
/// for a personal tool; revisit (e.g. pin by property id) if it ever bites.
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
        /// Notion's page-level `created_time`/`last_edited_time` (ISO datetimes),
        /// not properties.
        let createdTime: String?
        let lastEditedTime: String?
        /// The page's own Notion URL, a page-level field like the timestamps.
        let url: String?
        public let properties: [String: Property]

        enum CodingKeys: String, CodingKey {
            case id
            case createdTime = "created_time"
            case lastEditedTime = "last_edited_time"
            case url
            case properties
        }

        var asTask: NotionTask {
            let titleProperty = properties.values.first { $0.type == "title" }
            let title = titleProperty?.title?.map(\.plainText).joined() ?? ""
            let statusProperty = properties.values.first { $0.type == "status" }
            return NotionTask(
                id: id,
                title: title.isEmpty ? "(untitled)" : title,
                status: statusProperty?.status?.name,
                priority: properties["Priority"]?.select?.name,
                dueDate: NotionQueryResponse.date(from: properties["Due Date"]?.date?.start),
                category: properties["Category"]?.select?.name,
                startFrom: NotionQueryResponse.date(from: properties["Start from"]?.date?.start),
                createdTime: NotionQueryResponse.date(from: createdTime),
                lastEditedTime: NotionQueryResponse.date(from: lastEditedTime),
                workType: properties["WorkType"]?.select?.name,
                url: url
            )
        }
    }

    /// One typed property value. Only the fields the app reads are declared;
    /// unknown keys are ignored by the synthesised decoder.
    public struct Property: Decodable {
        public let type: String
        let title: [RichText]?
        let status: StatusValue?
        let select: SelectValue?
        let date: DateValue?
    }

    struct RichText: Decodable {
        let plainText: String
        enum CodingKeys: String, CodingKey { case plainText = "plain_text" }
    }

    struct StatusValue: Decodable {
        let name: String
    }

    struct SelectValue: Decodable {
        let name: String
    }

    struct DateValue: Decodable {
        /// Notion date-only ("2026-07-02") or full ISO datetime. `end`/`time_zone`
        /// are ignored — the app only needs the start.
        let start: String?
    }

    /// Parses a Notion date string. Handles both a full ISO-8601 datetime and a
    /// date-only value; date-only is anchored to local midnight so day-relative
    /// comparisons land on the right calendar day.
    static func date(from string: String?) -> Date? {
        guard let string, !string.isEmpty else { return nil }

        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = iso.date(from: string) { return date }
        iso.formatOptions = [.withInternetDateTime]
        if let date = iso.date(from: string) { return date }

        let dateOnly = DateFormatter()
        dateOnly.locale = Locale(identifier: "en_US_POSIX")
        dateOnly.timeZone = .current
        dateOnly.dateFormat = "yyyy-MM-dd"
        return dateOnly.date(from: string)
    }
}
