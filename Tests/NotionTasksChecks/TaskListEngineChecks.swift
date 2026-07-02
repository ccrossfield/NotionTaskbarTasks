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

    // ---- Late or due today (#5): flat, open, Due ≤ today, Due asc then Created asc ----
    t.suite("TaskListEngine — Late or due today")
    do {
        let lateTasks = [
            NotionTask(id: "a", title: "due yesterday", status: "To Do",
                       priority: .p2, dueDate: past, createdTime: day(2026, 6, 1, cal)),
            NotionTask(id: "b", title: "due today", status: "In Progress",
                       priority: .p0, dueDate: today, createdTime: day(2026, 5, 1, cal)),
            NotionTask(id: "c", title: "due in the future", status: "To Do",
                       priority: .p1, dueDate: future, createdTime: day(2026, 6, 1, cal)),
            NotionTask(id: "d", title: "no due date", status: "Blocked",
                       priority: .p0, dueDate: nil, createdTime: day(2026, 6, 1, cal)),
            NotionTask(id: "done", title: "done but overdue", status: "Done",
                       priority: .p0, dueDate: past, createdTime: day(2026, 6, 1, cal)),
        ]
        let late = TaskListEngine.lateOrDueToday(
            lateTasks, openStatuses: openStatuses, today: today, calendar: cal)

        await t.test("is a single flat group carrying no priority") {
            t.expectEqual(late.count, 1)
            t.expect(late.first?.priority == nil, "a flat preset has no section priority")
        }

        await t.test("keeps only open tasks due today or earlier, sorted Due ascending") {
            // 'a' (due yesterday) before 'b' (due today); future/no-due/done excluded.
            t.expectEqual(late.first?.tasks.map(\.id), ["a", "b"])
        }
    }

    do {
        // Same Due date → Created ascending breaks the tie. Titles are set to
        // disagree with Created order so this proves Created wins, not title.
        let sameDue = [
            NotionTask(id: "newer", title: "aaa newer", status: "To Do",
                       dueDate: today, createdTime: day(2026, 6, 10, cal)),
            NotionTask(id: "older", title: "zzz older", status: "To Do",
                       dueDate: today, createdTime: day(2026, 6, 5, cal)),
        ]
        let late = TaskListEngine.lateOrDueToday(
            sameDue, openStatuses: openStatuses, today: today, calendar: cal)
        await t.test("same Due date is tie-broken by Created ascending") {
            t.expectEqual(late.first?.tasks.map(\.id), ["older", "newer"])
        }
    }

    // ---- All open (#5): flat, every open task regardless of category, Created descending ----
    t.suite("TaskListEngine — All open")
    do {
        let allTasks = [
            NotionTask(id: "work", title: "work item", status: "To Do",
                       category: work, createdTime: day(2026, 6, 2, cal)),
            NotionTask(id: "home", title: "home item", status: "Blocked",
                       category: "📝 Life admin", createdTime: day(2026, 6, 5, cal)),
            NotionTask(id: "nocat", title: "uncategorised", status: "In Progress",
                       category: nil, createdTime: day(2026, 6, 1, cal)),
            NotionTask(id: "done", title: "finished", status: "Done",
                       category: work, createdTime: day(2026, 6, 9, cal)),
            NotionTask(id: "nostatus", title: "no status", status: nil,
                       createdTime: day(2026, 6, 9, cal)),
        ]
        let all = TaskListEngine.allOpen(allTasks, openStatuses: openStatuses)

        await t.test("is a single flat group of every open task, any category") {
            t.expectEqual(all.count, 1)
            t.expect(all.first?.priority == nil, "a flat preset has no section priority")
            t.expectEqual(Set(all.first?.tasks.map(\.id) ?? []), ["work", "home", "nocat"])
        }

        await t.test("sorts newest-created first (Created descending)") {
            t.expectEqual(all.first?.tasks.map(\.id), ["home", "work", "nocat"])
        }

        await t.test("excludes Done and status-less tasks (not in the open set)") {
            let ids = Set(all.first?.tasks.map(\.id) ?? [])
            t.expect(!ids.contains("done"), "Done is not open")
            t.expect(!ids.contains("nostatus"), "a status-less task is not open")
        }
    }

    // ---- Home priorities (#5): open personal-category tasks, Start-from deferral, grouped ----
    t.suite("TaskListEngine — Home priorities")
    do {
        let personal: Set<String> = ["📝 Life admin", "👥 Friends & Family"]
        let homeTasks = [
            NotionTask(id: "p0", title: "personal P0", status: "To Do",
                       priority: .p0, dueDate: today, category: "📝 Life admin"),
            NotionTask(id: "p1", title: "personal P1", status: "Blocked",
                       priority: .p1, dueDate: past, category: "👥 Friends & Family"),
            NotionTask(id: "work", title: "work P0", status: "To Do",
                       priority: .p0, dueDate: today, category: work),                 // excluded: Work
            NotionTask(id: "defer", title: "deferred personal", status: "To Do",
                       priority: .p0, category: "📝 Life admin", startFrom: future),    // excluded: deferred
            NotionTask(id: "nocat", title: "uncategorised", status: "To Do",
                       priority: .p0, category: nil),                                  // excluded: no category
            NotionTask(id: "done", title: "done personal", status: "Done",
                       priority: .p0, category: "📝 Life admin"),                       // excluded: not open
        ]
        let home = TaskListEngine.homePriorities(
            homeTasks, openStatuses: openStatuses, personalCategories: personal,
            today: today, calendar: cal)

        await t.test("groups open personal tasks by priority") {
            t.expectEqual(home.map(\.priority), [.p0, .p1])
            t.expectEqual(home.first?.tasks.map(\.id), ["p0"])
            t.expect(home.count == 2 && home[1].tasks.map(\.id) == ["p1"],
                     "P1 holds the one open personal P1 task")
        }

        await t.test("excludes Work, deferred, uncategorised and done tasks") {
            let ids = Set(home.flatMap { $0.tasks.map(\.id) })
            t.expect(!ids.contains("work"), "Work category belongs to Pivotal, not Home")
            t.expect(!ids.contains("defer"), "a future Start-from is deferred")
            t.expect(!ids.contains("nocat"), "an uncategorised task is not a personal-category task")
            t.expect(!ids.contains("done"), "Done is not open")
            t.expectEqual(ids.count, 2)
        }
    }
}
