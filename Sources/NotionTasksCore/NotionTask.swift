import Foundation

/// How urgently a due date needs attention (#25): discrete buckets over a
/// week horizon, not a continuous gradient. The view maps these to colour;
/// the boundary semantics live here so they are testable (ADR-0003).
public enum DueBucket {
    /// Due before today.
    case overdue
    /// Due today.
    case today
    /// Due within the next 7 days.
    case soon
    /// Due 8+ days out.
    case later
    /// No due date.
    case none
}

/// A task as the app displays it. Named `NotionTask` deliberately — `Task`
/// collides with Swift concurrency's `Task`.
///
/// The metadata fields (priority, due date, category, start-from) are all
/// optional: a task in Notion need not set any of them.
public struct NotionTask: Identifiable, Equatable, Codable {
    public let id: String
    public let title: String
    /// The Status option name (e.g. "To Do", "Blocked"), or `nil` if unset.
    public let status: String?
    /// The Priority select-option name exactly as Notion returns it (e.g.
    /// "P0", "P3"), or `nil` if unset. Any option name is carried; ordering
    /// and grouping come from the schema's option order, not a closed set (#15).
    public let priority: String?
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
    /// The page's own Notion URL ("https://www.notion.so/<slug>-<id>"), for
    /// opening the task in Notion (#21). Optional so snapshots cached before
    /// this field existed still decode; it refills on the next refresh.
    public let url: String?

    public init(
        id: String,
        title: String,
        status: String?,
        priority: String? = nil,
        dueDate: Date? = nil,
        category: String? = nil,
        startFrom: Date? = nil,
        createdTime: Date? = nil,
        lastEditedTime: Date? = nil,
        workType: String? = nil,
        url: String? = nil
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
        self.url = url
    }

    /// A copy with a new status, keeping every other field. Used by the write
    /// path so changing status never drops a row's priority/due/category.
    public func withStatus(_ newStatus: String?) -> NotionTask {
        NotionTask(
            id: id, title: title, status: newStatus, priority: priority,
            dueDate: dueDate, category: category, startFrom: startFrom,
            createdTime: createdTime, lastEditedTime: lastEditedTime, workType: workType,
            url: url)
    }

    /// A copy with a new title, keeping every other field. Used by the inline
    /// rename write path (#28), the mirror of `withStatus`.
    public func withTitle(_ newTitle: String) -> NotionTask {
        NotionTask(
            id: id, title: newTitle, status: status, priority: priority,
            dueDate: dueDate, category: category, startFrom: startFrom,
            createdTime: createdTime, lastEditedTime: lastEditedTime, workType: workType,
            url: url)
    }

    /// A copy with a new priority (`nil` clears it), keeping every other field.
    /// Used by the re-prioritise write path (#33), the mirror of `withStatus`.
    public func withPriority(_ newPriority: String?) -> NotionTask {
        NotionTask(
            id: id, title: title, status: status, priority: newPriority,
            dueDate: dueDate, category: category, startFrom: startFrom,
            createdTime: createdTime, lastEditedTime: lastEditedTime, workType: workType,
            url: url)
    }

    /// A copy with a new due date (`nil` clears it), keeping every other field.
    /// Used by the reschedule write path (#33), the mirror of `withStatus`.
    public func withDueDate(_ newDueDate: Date?) -> NotionTask {
        NotionTask(
            id: id, title: title, status: status, priority: priority,
            dueDate: newDueDate, category: category, startFrom: startFrom,
            createdTime: createdTime, lastEditedTime: lastEditedTime, workType: workType,
            url: url)
    }

    /// A locally-inserted quick-capture row awaiting its Notion create (#37).
    /// Its `id` is a `temp-<UUID>` placeholder, not a real Notion page id, so
    /// writes must never target it and it must never be cached. Notion page ids
    /// are bare UUIDs, so the `temp-` prefix can't collide with a real one.
    public var isProvisional: Bool { id.hasPrefix("temp-") }

    /// The task's page URL as a value the view can hand to `NSWorkspace` (#21).
    /// `nil` when the page URL is absent or malformed.
    public var webURL: URL? {
        url.flatMap(URL.init(string:))
    }

    /// The Notion desktop app deep link: the web URL with its scheme swapped
    /// to `notion://`, which the desktop app registers. The view prefers this
    /// when an app is installed to handle it, falling back to `webURL` (#21).
    public var notionAppURL: URL? {
        guard let webURL,
              var components = URLComponents(url: webURL, resolvingAgainstBaseURL: false)
        else { return nil }
        components.scheme = "notion"
        return components.url
    }

    /// The urgency of this task's due date, relative to `now` (#25). Drives
    /// the due-text tint in the view; the wording comes from
    /// `relativeDueText()`.
    ///
    /// Lives here (not in the view) for the same reason as `relativeDueText()`:
    /// the day-boundary logic is testable with an injected `now`/`calendar`.
    public func dueBucket(
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> DueBucket {
        // A Done task carries no urgency — a red "Overdue" on a finished task
        // is an alarm about nothing. "Done" matches the one-click complete
        // status, as in the view's completeButton.
        guard let dueDate, status != "Done" else { return .none }
        let today = calendar.startOfDay(for: now)
        let dueDay = calendar.startOfDay(for: dueDate)
        guard let days = calendar.dateComponents([.day], from: today, to: dueDay).day
        else { return .none }
        if days < 0 { return .overdue }
        if days == 0 { return .today }
        return days <= 7 ? .soon : .later
    }

    /// The due date rendered relative to `now`: "Overdue" for a past day,
    /// "Today" / "Tomorrow" for the next two days, a weekday name ("Wed") out
    /// to +6 days, otherwise a short date like "2 Jul" (#25). Done tasks
    /// always get the short date. Returns `nil` when there is no due date.
    ///
    /// Lives here (not in the view) so the day-boundary logic is testable — the
    /// view is a thin caller. `now`/`calendar`/`locale` are injectable for that.
    public func relativeDueText(
        now: Date = Date(),
        calendar: Calendar = .current,
        locale: Locale = .current
    ) -> String? {
        guard let dueDate else { return nil }
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = "d MMM"
        // A Done task gets the plain date: "Overdue" (or any relative wording)
        // on a finished task is an alarm about nothing.
        if status == "Done" { return formatter.string(from: dueDate) }
        let today = calendar.startOfDay(for: now)
        let dueDay = calendar.startOfDay(for: dueDate)
        if dueDay < today { return "Overdue" }
        if dueDay == today { return "Today" }
        let days = calendar.dateComponents([.day], from: today, to: dueDay).day
        if days == 1 { return "Tomorrow" }
        // Weekday names stop at +6: a task exactly +7 out shares today's
        // weekday name and would read as due today, so it gets the date.
        if let days, (2...6).contains(days) {
            formatter.dateFormat = "EEE"
        }
        return formatter.string(from: dueDate)
    }
}
