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

/// A task carrying only a due date; the other fields are irrelevant here.
private func taskDue(_ date: Date?) -> NotionTask {
    NotionTask(id: "x", title: "t", status: nil, dueDate: date)
}

func taskPresentationChecks(_ t: CheckRun) async {
    t.suite("Relative due-date text")
    let cal = londonCalendar()
    let locale = Locale(identifier: "en_GB")
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
}
