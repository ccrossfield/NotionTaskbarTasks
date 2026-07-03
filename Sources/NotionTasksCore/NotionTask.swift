import Foundation

/// A task's priority. Backed by the Notion select-option names "P0"/"P1"/"P2".
/// `rank` gives the sort order the priority views need later (#4/#5): P0 first.
public enum Priority: String, Equatable, CaseIterable {
    case p0 = "P0"
    case p1 = "P1"
    case p2 = "P2"

    /// Lower is more urgent, so this sorts P0 before P1 before P2.
    public var rank: Int {
        switch self {
        case .p0: return 0
        case .p1: return 1
        case .p2: return 2
        }
    }
}

/// A task as the app displays it. Named `NotionTask` deliberately — `Task`
/// collides with Swift concurrency's `Task`.
///
/// The metadata fields (priority, due date, category, start-from) are all
/// optional: a task in Notion need not set any of them.
public struct NotionTask: Identifiable, Equatable {
    public let id: String
    public let title: String
    /// The Status option name (e.g. "To Do", "Blocked"), or `nil` if unset.
    public let status: String?
    public let priority: Priority?
    public let dueDate: Date?
    /// The Category select-option name (carries its emoji, e.g. "👨🏻‍💻 Work").
    public let category: String?
    /// The "Start from" defer date — when a task should surface. Used by the
    /// priority views later; decoded here so it's ready.
    public let startFrom: Date?
    /// The page's Notion `created_time`. Drives the Created sort in the
    /// "All open" and "Late or due today" presets (#5) and the custom sort (#6).
    public let createdTime: Date?
    /// The page's Notion `last_edited_time`. A custom-sort field (#6).
    public let lastEditedTime: Date?
    /// The WorkType select-option name (e.g. "Strategy", "PIVOT"). A custom
    /// filter field (#6); the values come from the schema, not a fixed set.
    public let workType: String?

    public init(
        id: String,
        title: String,
        status: String?,
        priority: Priority? = nil,
        dueDate: Date? = nil,
        category: String? = nil,
        startFrom: Date? = nil,
        createdTime: Date? = nil,
        lastEditedTime: Date? = nil,
        workType: String? = nil
    ) {
        self.id = id
        self.title = title
        self.status = status
        self.priority = priority
        self.dueDate = dueDate
        self.category = category
        self.startFrom = startFrom
        self.createdTime = createdTime
        self.lastEditedTime = lastEditedTime
        self.workType = workType
    }

    /// A copy with a new status, keeping every other field. Used by the write
    /// path so changing status never drops a row's priority/due/category.
    public func withStatus(_ newStatus: String?) -> NotionTask {
        NotionTask(
            id: id, title: title, status: newStatus, priority: priority,
            dueDate: dueDate, category: category, startFrom: startFrom,
            createdTime: createdTime, lastEditedTime: lastEditedTime, workType: workType)
    }

    /// The due date rendered relative to `now`: "Overdue" for a past day,
    /// "Today" for the current day, otherwise a short date like "2 Jul".
    /// Returns `nil` when there is no due date.
    ///
    /// Lives here (not in the view) so the day-boundary logic is testable — the
    /// view is a thin caller. `now`/`calendar`/`locale` are injectable for that.
    public func relativeDueText(
        now: Date = Date(),
        calendar: Calendar = .current,
        locale: Locale = .current
    ) -> String? {
        guard let dueDate else { return nil }
        let today = calendar.startOfDay(for: now)
        let dueDay = calendar.startOfDay(for: dueDate)
        if dueDay < today { return "Overdue" }
        if dueDay == today { return "Today" }
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = "d MMM"
        return formatter.string(from: dueDate)
    }
}
