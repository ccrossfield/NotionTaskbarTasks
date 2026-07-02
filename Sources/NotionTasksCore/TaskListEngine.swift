import Foundation

/// A run of tasks sharing a priority, ready to render under one section header.
/// `priority == nil` is the trailing "no priority" group.
public struct TaskGroup: Equatable {
    public let priority: Priority?
    public let tasks: [NotionTask]

    public init(priority: Priority?, tasks: [NotionTask]) {
        self.priority = priority
        self.tasks = tasks
    }
}

/// The filter/sort/group *semantics*, kept out of the view so they're testable
/// (ADR-0002). Given a set of tasks plus the runtime facts (the schema-derived
/// open statuses, the Work category name, today's date), it returns the tasks
/// the view should show, grouped and ordered. Empty groups are omitted.
public enum TaskListEngine {
    /// The Pivotal Priorities view (#4, the launch default): open, Work-category
    /// tasks whose Start from is today-or-earlier or unset, grouped P0 → P1 → P2
    /// → no-priority, each sorted by Due date ascending (no due date last), with
    /// the title as a stable tie-breaker.
    public static func pivotalPriorities(
        _ tasks: [NotionTask],
        openStatuses: Set<String>,
        workCategory: String,
        today: Date,
        calendar: Calendar = .current
    ) -> [TaskGroup] {
        let startOfToday = calendar.startOfDay(for: today)

        let visible = tasks.filter { task in
            guard let status = task.status, openStatuses.contains(status) else { return false }
            guard task.category == workCategory else { return false }
            if let start = task.startFrom, calendar.startOfDay(for: start) > startOfToday {
                return false // deferred: not yet surfaced
            }
            return true
        }

        let order: [Priority?] = [.p0, .p1, .p2, nil]
        return order.compactMap { priority in
            let group = visible
                .filter { $0.priority == priority }
                .sorted(by: byDueThenTitle)
            return group.isEmpty ? nil : TaskGroup(priority: priority, tasks: group)
        }
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
}
