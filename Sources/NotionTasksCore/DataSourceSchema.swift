import Foundation

/// Decodes the response of `GET /v1/data_sources/{id}` - the data source's
/// schema. The app uses it to derive the set of "open" status names at runtime
/// (per ADR-0001: the options *not* in the `Complete` group), rather than
/// hardcoding `does_not_equal "Done"`, and to read the Category options.
///
/// As in the query decoder, the Status property is found by its Notion `type`,
/// so renaming the "Status" column doesn't break this.
public struct DataSourceSchema: Decodable {
    public let properties: [String: PropertySchema]

    public struct PropertySchema: Decodable {
        public let type: String
        let status: StatusConfig?
        let select: SelectConfig?
    }

    struct StatusConfig: Decodable {
        let options: [Option]
        let groups: [Group]
    }

    struct SelectConfig: Decodable {
        let options: [Option]
    }

    struct Option: Decodable {
        let id: String
        let name: String
    }

    struct Group: Decodable {
        let name: String
        let optionIDs: [String]
        enum CodingKeys: String, CodingKey {
            case name
            case optionIDs = "option_ids"
        }
    }

    /// The status option names that count as "open" - every option not in the
    /// `Complete` group. Notion exposes no semantic "done" flag, so the complete
    /// group is matched by its name ("Complete"), which is Notion's default group
    /// name. If it's ever renamed, this fails open (treats all statuses as open),
    /// which surfaces tasks rather than silently hiding them.
    public var openStatusNames: Set<String> {
        guard let status = properties.values.first(where: { $0.type == "status" })?.status else {
            return []
        }
        let completeGroup = status.groups.first {
            $0.name.caseInsensitiveCompare("Complete") == .orderedSame
        }
        let completeIDs = Set(completeGroup?.optionIDs ?? [])
        return Set(status.options.filter { !completeIDs.contains($0.id) }.map(\.name))
    }

    /// The Category select option names, in schema order. Feeds the "Work"
    /// resolution below and, later, the custom filter UI (#6).
    public var categoryOptionNames: [String] {
        properties["Category"]?.select?.options.map(\.name) ?? []
    }

    /// The Category option that represents work. Matched by containing "work"
    /// case-insensitively, so the emoji prefix ("👨🏻‍💻 Work") doesn't matter.
    /// `nil` if there's no such category.
    public var workCategoryName: String? {
        categoryOptionNames.first { $0.range(of: "work", options: .caseInsensitive) != nil }
    }

    /// The personal categories: every Category option except Work. Feeds the
    /// "Home priorities" preset (#5), which is Pivotal Priorities' mirror.
    public var personalCategoryNames: [String] {
        let work = workCategoryName
        return categoryOptionNames.filter { $0 != work }
    }
}
