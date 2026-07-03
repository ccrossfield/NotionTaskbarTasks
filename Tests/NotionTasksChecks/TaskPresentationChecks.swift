import Foundation
import NotionTasksCore

/// A fixed calendar/locale so the relative-date checks don't depend on the
/// machine's timezone or region. The user is UK-based, so en_GB / Europe/London.
private func londonCalendar() -> Calendar {
    var cal = Calendar(identifier: .gregorian)
    cal.timeZone = TimeZone(identifier: "Europe/London")!
    cal.locale = Locale(identifier: "en_GB")
    return cal
}

private func noon(_ year: Int, _ month: Int, _ day: Int, _ cal: Calendar) -> Date {
    cal.date(from: DateComponents(year: year, month: month, day: day, hour: 12))!
}

/// A task carrying only a due date (and optionally a status); the other
/// fields are irrelevant here.
private func taskDue(_ date: Date?, status: String? = nil) -> NotionTask {
    NotionTask(id: "x", title: "t", status: status, dueDate: date)
}

func taskPresentationChecks(_ t: CheckRun) async {
    t.suite("Relative due-date text")
    let cal = londonCalendar()
    let locale = Locale(identifier: "en_GB")
    // 2 Jul 2026 is a Thursday — the weekday-wording checks below rely on it.
    let today = noon(2026, 7, 2, cal)

    await t.test("no due date yields no label") {
        let text = taskDue(nil).relativeDueText(now: today, calendar: cal, locale: locale)
        t.expect(text == nil, "expected nil, got \(text ?? "nil")")
    }

    await t.test("a past due date reads Overdue") {
        let text = taskDue(noon(2026, 7, 1, cal)).relativeDueText(now: today, calendar: cal, locale: locale)
        t.expect(text == "Overdue", "expected Overdue, got \(text ?? "nil")")
    }

    await t.test("due later the same day still reads Today") {
        // Due at 09:00, 'now' is noon — same calendar day, not overdue.
        let due = cal.date(from: DateComponents(year: 2026, month: 7, day: 2, hour: 9))!
        let text = taskDue(due).relativeDueText(now: today, calendar: cal, locale: locale)
        t.expect(text == "Today", "expected Today, got \(text ?? "nil")")
    }

    await t.test("a future due date reads as a short date") {
        let text = taskDue(noon(2026, 12, 25, cal)).relativeDueText(now: today, calendar: cal, locale: locale)
        t.expect(text == "25 Dec", "expected '25 Dec', got \(text ?? "nil")")
    }

    await t.test("due the next day reads Tomorrow") {
        let text = taskDue(noon(2026, 7, 3, cal)).relativeDueText(now: today, calendar: cal, locale: locale)
        t.expect(text == "Tomorrow", "expected Tomorrow, got \(text ?? "nil")")
    }

    await t.test("+2 to +6 days reads as the weekday name") {
        let sat = taskDue(noon(2026, 7, 4, cal)).relativeDueText(now: today, calendar: cal, locale: locale)
        t.expect(sat == "Sat", "expected Sat, got \(sat ?? "nil")")
        let wed = taskDue(noon(2026, 7, 8, cal)).relativeDueText(now: today, calendar: cal, locale: locale)
        t.expect(wed == "Wed", "expected Wed, got \(wed ?? "nil")")
    }

    await t.test("exactly +7 days reads as a short date, not today's weekday name") {
        // 9 Jul 2026 is a Thursday like `today` — the weekday name would read
        // as due today, so the wording falls back to the date.
        let text = taskDue(noon(2026, 7, 9, cal)).relativeDueText(now: today, calendar: cal, locale: locale)
        t.expect(text == "9 Jul", "expected '9 Jul', got \(text ?? "nil")")
    }

    await t.test("a Done task reads as a plain short date, never Overdue or relative wording") {
        let past = taskDue(noon(2026, 7, 1, cal), status: "Done")
            .relativeDueText(now: today, calendar: cal, locale: locale)
        t.expect(past == "1 Jul", "expected '1 Jul', got \(past ?? "nil")")
        let nextDay = taskDue(noon(2026, 7, 3, cal), status: "Done")
            .relativeDueText(now: today, calendar: cal, locale: locale)
        t.expect(nextDay == "3 Jul", "expected '3 Jul', got \(nextDay ?? "nil")")
    }

    t.suite("Due-date urgency buckets (#25)")

    await t.test("a due day before today is overdue") {
        t.expectEqual(taskDue(noon(2026, 7, 1, cal)).dueBucket(now: today, calendar: cal), .overdue)
    }

    await t.test("a due day of today is today") {
        t.expectEqual(taskDue(noon(2026, 7, 2, cal)).dueBucket(now: today, calendar: cal), .today)
    }

    await t.test("no due date is bucket none") {
        t.expectEqual(taskDue(nil).dueBucket(now: today, calendar: cal), DueBucket.none)
    }

    await t.test("tomorrow through +7 days is soon") {
        t.expectEqual(taskDue(noon(2026, 7, 3, cal)).dueBucket(now: today, calendar: cal), .soon)
        t.expectEqual(taskDue(noon(2026, 7, 9, cal)).dueBucket(now: today, calendar: cal), .soon)
    }

    await t.test("+8 days and beyond is later") {
        t.expectEqual(taskDue(noon(2026, 7, 10, cal)).dueBucket(now: today, calendar: cal), .later)
        t.expectEqual(taskDue(noon(2026, 12, 25, cal)).dueBucket(now: today, calendar: cal), .later)
    }

    await t.test("a Done task is bucket none even when its due date has passed") {
        let done = taskDue(noon(2026, 7, 1, cal), status: "Done")
        t.expectEqual(done.dueBucket(now: today, calendar: cal), DueBucket.none)
    }

    t.suite("Opening a task in Notion (#21)")

    await t.test("the desktop-app deep link is the web URL with a notion:// scheme") {
        let task = NotionTask(
            id: "x", title: "t", status: nil,
            url: "https://www.notion.so/Draft-the-Q3-board-update-11111111000000000000000000000002")
        t.expectEqual(
            task.notionAppURL?.absoluteString,
            "notion://www.notion.so/Draft-the-Q3-board-update-11111111000000000000000000000002")
        t.expectEqual(
            task.webURL?.absoluteString,
            "https://www.notion.so/Draft-the-Q3-board-update-11111111000000000000000000000002")
    }

    await t.test("a task without a URL yields no open targets") {
        let task = NotionTask(id: "x", title: "t", status: nil)
        t.expect(task.webURL == nil, "expected nil webURL")
        t.expect(task.notionAppURL == nil, "expected nil notionAppURL")
    }
}
