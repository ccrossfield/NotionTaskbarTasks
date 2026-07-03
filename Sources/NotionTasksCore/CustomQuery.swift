import Foundation

/// The filter option lists offered by the custom filter (#6), read wholesale
/// from the live schema so a renamed or newly-added option needs no code change.
/// Falls back to sensible constants only until the schema arrives.
public struct SchemaOptions: Equatable, Codable {
    public let statuses: [String]
    public let categories: [String]
    public let priorities: [String]
    public let workTypes: [String]

    public init(statuses: [String], categories: [String], priorities: [String], workTypes: [String]) {
        self.statuses = statuses
        self.categories = categories
        self.priorities = priorities
        self.workTypes = workTypes
    }

    /// Used until the live schema loads, or if its fetch fails.
    public static let fallback = SchemaOptions(
        statuses: NotionConfig.selectableStatuses,
        categories: [NotionConfig.fallbackWorkCategory] + NotionConfig.fallbackPersonalCategories.sorted(),
        priorities: Priority.allCases.map(\.rawValue),
        workTypes: ["Strategy", "Reporting/Comms", "Team", "HORIZON", "PODIUM", "PI", "PISTON", "PIVOT", "Admin"])
}

/// How a date field is filtered. Relative to today rather than an absolute date,
/// matching how the real Notion views filter (≤ today, empty-or-≤-today) and
/// keeping the menu-bar UI free of a date picker.
public enum DateFilter: String, CaseIterable, Equatable {
    case any
    case onOrBeforeToday
    case afterToday
    case isEmpty
    case isPresent

    public var title: String {
        switch self {
        case .any: return "Any"
        case .onOrBeforeToday: return "Today or earlier"
        case .afterToday: return "After today"
        case .isEmpty: return "Empty"
        case .isPresent: return "Set"
        }
    }
}

/// The field a custom view sorts on (#6).
public enum SortField: String, CaseIterable, Equatable {
    case dueDate
    case priority
    case created
    case lastEdited

    public var title: String {
        switch self {
        case .dueDate: return "Due date"
        case .priority: return "Priority"
        case .created: return "Created"
        case .lastEdited: return "Last edited"
        }
    }
}

/// A user-composed filter + sort (#6). Each select filter is a set of allowed
/// option names; an *empty* set means "any" (no constraint on that field). The
/// filters combine with AND. Sort is a field plus a direction.
public struct CustomQuery: Equatable {
    public var statuses: Set<String>
    public var categories: Set<String>
    public var priorities: Set<String>
    public var workTypes: Set<String>
    public var dueDate: DateFilter
    public var startFrom: DateFilter
    public var sortField: SortField
    public var ascending: Bool

    public init(
        statuses: Set<String> = [],
        categories: Set<String> = [],
        priorities: Set<String> = [],
        workTypes: Set<String> = [],
        dueDate: DateFilter = .any,
        startFrom: DateFilter = .any,
        sortField: SortField = .dueDate,
        ascending: Bool = true
    ) {
        self.statuses = statuses
        self.categories = categories
        self.priorities = priorities
        self.workTypes = workTypes
        self.dueDate = dueDate
        self.startFrom = startFrom
        self.sortField = sortField
        self.ascending = ascending
    }

    /// No constraints, default sort — the custom view before the user narrows it.
    public static let empty = CustomQuery()

    /// Whether any *filter* (as opposed to sort) is currently narrowing the list.
    /// Drives a UI hint; sort alone doesn't count as filtering.
    public var isFiltering: Bool {
        !statuses.isEmpty || !categories.isEmpty || !priorities.isEmpty
            || !workTypes.isEmpty || dueDate != .any || startFrom != .any
    }

    /// A copy with every filter cleared but the sort kept — the "Clear filters"
    /// action.
    public func cleared() -> CustomQuery {
        CustomQuery(sortField: sortField, ascending: ascending)
    }
}
