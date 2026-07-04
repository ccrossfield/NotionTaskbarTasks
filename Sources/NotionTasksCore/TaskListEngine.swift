import Foundation

/// A run of tasks sharing a priority, ready to render under one section header.
/// `priority` is the option name as Notion returns it ("P0", "P3", …);
/// `nil` is the trailing "no priority" group.
public struct TaskGroup: Equatable {
    public let priority: String?
    public let tasks: [NotionTask]

    public init(priority: String?, tasks: [NotionTask]) {
        self.priority = priority
        self.tasks = tasks
    }
}

/// The filter/sort/group *semantics*, kept out of the view so they're testable
/// (ADR-0002). Given a set of tasks plus the runtime facts (the schema-derived
/// open statuses, the Work category name, today's date), it returns the tasks
/// the view should show, grouped and ordered. Empty groups are omitted.
public enum TaskListEngine {
    /// The grouped-and-ordered task list for a given preset (#5). The one entry
    /// point the app calls; it dispatches to the per-preset function below.
    /// `workCategory`/`personalCategories`/`priorityOrder`/`today` are used only
    /// by the presets that need them.
    public static func groups(
        for preset: Preset,
        _ tasks: [NotionTask],
        openStatuses: Set<String>,
        workCategory: String,
        personalCategories: Set<String>,
        priorityOrder: [String],
        today: Date,
        calendar: Calendar = .current
    ) -> [TaskGroup] {
        switch preset {
        case .pivotalPriorities:
            return pivotalPriorities(tasks, openStatuses: openStatuses,
                                     workCategory: workCategory, priorityOrder: priorityOrder,
                                     today: today, calendar: calendar)
        case .homePriorities:
            return homePriorities(tasks, openStatuses: openStatuses,
                                  personalCategories: personalCategories,
                                  priorityOrder: priorityOrder, today: today, calendar: calendar)
        case .lateOrDueToday:
            return lateOrDueToday(tasks, openStatuses: openStatuses, today: today, calendar: calendar)
        case .allOpen:
            return allOpen(tasks, openStatuses: openStatuses)
        }
    }

    /// The Pivotal Priorities view (#4, the launch default): open, Work-category
    /// tasks whose Start from is today-or-earlier or unset, grouped by priority
    /// in the schema's option order (`priorityOrder`) with no-priority last,
    /// each group sorted by Due date ascending (no due date last), with the
    /// title as a stable tie-breaker.
    public static func pivotalPriorities(
        _ tasks: [NotionTask],
        openStatuses: Set<String>,
        workCategory: String,
        priorityOrder: [String],
        today: Date,
        calendar: Calendar = .current
    ) -> [TaskGroup] {
        groupedByPriority(tasks, openStatuses: openStatuses, priorityOrder: priorityOrder,
                          today: today, calendar: calendar) {
            $0 == workCategory
        }
    }

    /// Home priorities (#5): the personal-category mirror of Pivotal Priorities.
    /// Open tasks in any *personal* category (every category except Work), same
    /// Start-from deferral, same schema-ordered priority grouping. An
    /// uncategorised task is excluded — "personal-category" means it carries a
    /// personal one.
    public static func homePriorities(
        _ tasks: [NotionTask],
        openStatuses: Set<String>,
        personalCategories: Set<String>,
        priorityOrder: [String],
        today: Date,
        calendar: Calendar = .current
    ) -> [TaskGroup] {
        groupedByPriority(tasks, openStatuses: openStatuses, priorityOrder: priorityOrder,
                          today: today, calendar: calendar) { category in
            guard let category else { return false }
            return personalCategories.contains(category)
        }
    }

    /// Late or due today (#5): open tasks with a Due date today-or-earlier, as a
    /// single flat list sorted Due ascending then Created ascending. No category
    /// filter and no Start-from deferral — this is the "what's actually due" view.
    public static func lateOrDueToday(
        _ tasks: [NotionTask],
        openStatuses: Set<String>,
        today: Date,
        calendar: Calendar = .current
    ) -> [TaskGroup] {
        let startOfToday = calendar.startOfDay(for: today)
        let visible = tasks.filter { task in
            guard let status = task.status, openStatuses.contains(status) else { return false }
            guard let due = task.dueDate else { return false }
            return calendar.startOfDay(for: due) <= startOfToday
        }
        return flatGroup(visible.sorted(by: byDueThenCreated))
    }

    /// All open (#5): every open task, any category, as a single flat list newest
    /// first (Created descending). No Start-from deferral — the catch-all view.
    public static func allOpen(
        _ tasks: [NotionTask],
        openStatuses: Set<String>
    ) -> [TaskGroup] {
        let visible = tasks.filter { task in
            guard let status = task.status else { return false }
            return openStatuses.contains(status)
        }
        return flatGroup(visible.sorted(by: byCreatedDescending))
    }

    /// A custom, user-composed view (#6): the tasks matching every active filter
    /// (filters combine with AND; an empty option set means "any"), as a single
    /// flat group sorted by the chosen field and direction. `priorityOrder` (the
    /// schema's option order) ranks the priority sort. Missing sort values sort
    /// last in both directions; the title is the stable final tie-break.
    public static func custom(
        _ tasks: [NotionTask],
        query: CustomQuery,
        priorityOrder: [String],
        today: Date,
        calendar: Calendar = .current
    ) -> [TaskGroup] {
        let startOfToday = calendar.startOfDay(for: today)
        let filtered = tasks.filter { task in
            matches(query.statuses, task.status)
                && matches(query.categories, task.category)
                && matches(query.priorities, task.priority)
                && matches(query.workTypes, task.workType)
                && matches(query.dueDate, task.dueDate, startOfToday, calendar)
                && matches(query.startFrom, task.startFrom, startOfToday, calendar)
        }
        let rank = priorityRank(filtered, order: priorityOrder)
        return flatGroup(filtered.sorted(by: comparator(for: query, priorityRank: rank)))
    }

    /// Filter tasks by the header's free-text title search (#32). Case- and
    /// diacritic-insensitive; the query is split on whitespace and a task
    /// matches only when *every* term appears somewhere in its folded title
    /// (AND, any order) — so word order and the words between don't matter. An
    /// empty or whitespace-only query matches everything, letting the unfiltered
    /// view show through. Input order is preserved. Applied before grouping (in
    /// `AppModel.groups`), so empty groups drop out and section counts reflect
    /// the matches for free.
    public static func search(_ tasks: [NotionTask], matching query: String) -> [NotionTask] {
        let terms = query.folding(options: searchFolding, locale: .current)
            .split(whereSeparator: \.isWhitespace)
        guard !terms.isEmpty else { return tasks }
        return tasks.filter { task in
            let title = task.title.folding(options: searchFolding, locale: .current)
            return terms.allSatisfy { title.contains($0) }
        }
    }

    /// Fold away case and accents on both the query and the title, so "cafe"
    /// finds "Café" and "PIVOT" finds "pivot".
    private static let searchFolding: String.CompareOptions = [.caseInsensitive, .diacriticInsensitive]

    /// A select filter matches when it's empty ("any") or the task's value is in
    /// the allowed set. A task with no value matches only the "any" case.
    private static func matches(_ allowed: Set<String>, _ value: String?) -> Bool {
        guard !allowed.isEmpty else { return true }
        guard let value else { return false }
        return allowed.contains(value)
    }

    /// A date filter evaluated relative to the start of today.
    private static func matches(
        _ filter: DateFilter, _ date: Date?, _ startOfToday: Date, _ calendar: Calendar
    ) -> Bool {
        switch filter {
        case .any: return true
        case .isEmpty: return date == nil
        case .isPresent: return date != nil
        case .onOrBeforeToday:
            guard let date else { return false }
            return calendar.startOfDay(for: date) <= startOfToday
        case .afterToday:
            guard let date else { return false }
            return calendar.startOfDay(for: date) > startOfToday
        }
    }

    /// The sort rank per priority name: schema position for known names (first
    /// most urgent); a name the schema doesn't list ranks after every known one,
    /// alphabetically among the unknowns present. A missing priority has no rank
    /// and sorts last via the comparator's nil handling.
    private static func priorityRank(_ tasks: [NotionTask], order: [String]) -> [String: Int] {
        var rank: [String: Int] = [:]
        for (index, name) in order.enumerated() where rank[name] == nil {
            rank[name] = index
        }
        let unknown = Set(tasks.compactMap(\.priority)).subtracting(order).sorted()
        for (offset, name) in unknown.enumerated() {
            rank[name] = order.count + offset
        }
        return rank
    }

    /// The comparator for a custom sort: orders by the chosen field/direction,
    /// missing values last (both directions), title as the stable tie-break.
    private static func comparator(
        for query: CustomQuery, priorityRank: [String: Int]
    ) -> (NotionTask, NotionTask) -> Bool {
        let ascending = query.ascending
        func ordered<T: Comparable>(_ a: T?, _ b: T?) -> Bool? {
            switch (a, b) {
            case let (x?, y?) where x != y: return ascending ? x < y : x > y
            case (_?, nil): return true   // a present, b missing → a first (missing last)
            case (nil, _?): return false
            default: return nil           // equal, or both missing → tie
            }
        }
        return { a, b in
            let decided: Bool?
            switch query.sortField {
            case .dueDate: decided = ordered(a.dueDate, b.dueDate)
            case .priority: decided = ordered(a.priority.flatMap { priorityRank[$0] },
                                              b.priority.flatMap { priorityRank[$0] })
            case .created: decided = ordered(a.createdTime, b.createdTime)
            case .lastEdited: decided = ordered(a.lastEditedTime, b.lastEditedTime)
            }
            return decided ?? (a.title < b.title)
        }
    }

    // MARK: - Shared building blocks

    /// The open + category + Start-from filter that Pivotal and Home share,
    /// grouped by priority in schema order with no-priority last, each group
    /// Due-sorted. The only difference between the two presets is
    /// `categoryMatches`.
    private static func groupedByPriority(
        _ tasks: [NotionTask],
        openStatuses: Set<String>,
        priorityOrder: [String],
        today: Date,
        calendar: Calendar,
        categoryMatches: (String?) -> Bool
    ) -> [TaskGroup] {
        let startOfToday = calendar.startOfDay(for: today)
        let visible = tasks.filter { task in
            guard let status = task.status, openStatuses.contains(status) else { return false }
            guard categoryMatches(task.category) else { return false }
            if let start = task.startFrom, calendar.startOfDay(for: start) > startOfToday {
                return false // deferred: not yet surfaced
            }
            return true
        }

        // A task can carry a priority the schema facts don't list (stale
        // schema, fallback). Those group after every schema-known option,
        // alphabetically among themselves, before the no-priority group.
        let unknown = Set(visible.compactMap(\.priority)).subtracting(priorityOrder).sorted()
        let order: [String?] = priorityOrder + unknown + [nil]
        return order.compactMap { priority in
            let group = visible
                .filter { $0.priority == priority }
                .sorted(by: byDueThenTitle)
            return group.isEmpty ? nil : TaskGroup(priority: priority, tasks: group)
        }
    }

    /// Wraps an already-sorted list as a flat preset's single no-priority group,
    /// or nothing when empty. The view renders it without a section header
    /// (`Preset.isGrouped == false`).
    private static func flatGroup(_ tasks: [NotionTask]) -> [TaskGroup] {
        tasks.isEmpty ? [] : [TaskGroup(priority: nil, tasks: tasks)]
    }

    /// Due date ascending; tasks with no due date sort last; title breaks ties so
    /// the order is stable.
    private static func byDueThenTitle(_ a: NotionTask, _ b: NotionTask) -> Bool {
        switch (a.dueDate, b.dueDate) {
        case let (x?, y?):
            return x == y ? a.title < b.title : x < y
        case (_?, nil):
            return true
        case (nil, _?):
            return false
        case (nil, nil):
            return a.title < b.title
        }
    }

    /// Due ascending, then Created ascending, then title — for "Late or due
    /// today". The filter guarantees a due date, but this stays defensive.
    private static func byDueThenCreated(_ a: NotionTask, _ b: NotionTask) -> Bool {
        switch (a.dueDate, b.dueDate) {
        case let (x?, y?) where x != y: return x < y
        case (_?, nil): return true
        case (nil, _?): return false
        default: break // same (or both-nil) due date → fall through to Created
        }
        return byCreatedAscendingThenTitle(a, b)
    }

    private static func byCreatedAscendingThenTitle(_ a: NotionTask, _ b: NotionTask) -> Bool {
        switch (a.createdTime, b.createdTime) {
        case let (x?, y?) where x != y: return x < y
        case (_?, nil): return true       // a has a Created time, b doesn't → a first
        case (nil, _?): return false
        default: return a.title < b.title
        }
    }

    /// Created descending (newest first); no-Created sorts last; title tie-break.
    private static func byCreatedDescending(_ a: NotionTask, _ b: NotionTask) -> Bool {
        switch (a.createdTime, b.createdTime) {
        case let (x?, y?) where x != y: return x > y
        case (_?, nil): return true
        case (nil, _?): return false
        default: return a.title < b.title
        }
    }
}
