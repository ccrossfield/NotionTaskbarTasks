import Foundation
import NotionTasksCore

private func londonCal() -> Calendar {
    var cal = Calendar(identifier: .gregorian)
    cal.timeZone = TimeZone(identifier: "Europe/London")!
    return cal
}

private func day(_ y: Int, _ m: Int, _ d: Int, _ cal: Calendar) -> Date {
    cal.date(from: DateComponents(year: y, month: m, day: d, hour: 12))!
}

func taskListEngineChecks(_ t: CheckRun) async {
    t.suite("TaskListEngine — Pivotal Priorities")
    let cal = londonCal()
    let work = "👨🏻‍💻 Work"
    let openStatuses: Set<String> = ["To Do", "In Progress", "Blocked"]
    let today = day(2026, 7, 2, cal)
    let past = day(2026, 6, 20, cal)
    let future = day(2026, 8, 1, cal)

    // A deliberately mixed set: some included, some excluded for each reason.
    let tasks = [
        NotionTask(id: "a", title: "P0 work due today", status: "To Do",
                   priority: .p0, dueDate: today, category: work),
        NotionTask(id: "b", title: "P1 work overdue", status: "In Progress",
                   priority: .p1, dueDate: past, category: work),
        NotionTask(id: "c", title: "P0 work no due", status: "Blocked",
                   priority: .p0, dueDate: nil, category: work),
        NotionTask(id: "h", title: "P2 work starts today", status: "To Do",
                   priority: .p2, dueDate: nil, category: work, startFrom: today),
        NotionTask(id: "g", title: "work no priority", status: "To Do",
                   priority: nil, dueDate: today, category: work),
        // Excluded:
        NotionTask(id: "done", title: "done work", status: "Done",
                   priority: .p0, dueDate: today, category: work),               // not open
        NotionTask(id: "home", title: "home P0", status: "To Do",
                   priority: .p0, dueDate: today, category: "📝 Life admin"),     // not Work
        NotionTask(id: "defer", title: "deferred work", status: "To Do",
                   priority: .p1, dueDate: today, category: work, startFrom: future), // not surfaced yet
    ]

    let groups = TaskListEngine.pivotalPriorities(
        tasks, openStatuses: openStatuses, workCategory: work, today: today, calendar: cal)

    await t.test("groups appear in P0, P1, P2, then no-priority order, empties omitted") {
        t.expectEqual(groups.map(\.priority), [.p0, .p1, .p2, nil])
    }

    await t.test("within a group, due-date ascending with no-due last") {
        // P0 has 'a' (due today) and 'c' (no due) → a before c.
        t.expectEqual(groups.first?.tasks.map(\.id), ["a", "c"])
    }

    await t.test("P1 holds the single overdue task; P2 holds the starts-today task") {
        t.expectEqual(groups[1].tasks.map(\.id), ["b"])
        t.expectEqual(groups[2].tasks.map(\.id), ["h"])
        t.expectEqual(groups[3].tasks.map(\.id), ["g"])
    }

    await t.test("done, non-Work and deferred tasks are excluded entirely") {
        let shown = Set(groups.flatMap { $0.tasks.map(\.id) })
        t.expect(!shown.contains("done"), "a Done task must not appear")
        t.expect(!shown.contains("home"), "a non-Work task must not appear")
        t.expect(!shown.contains("defer"), "a task deferred to the future must not appear")
        t.expectEqual(shown.count, 5)
    }

    await t.test("Start from equal to today is surfaced (boundary is inclusive)") {
        let shown = Set(groups.flatMap { $0.tasks.map(\.id) })
        t.expect(shown.contains("h"), "Start from == today should be visible")
    }
}
