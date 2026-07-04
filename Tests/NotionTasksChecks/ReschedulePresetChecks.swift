import Foundation
import NotionTasksCore

/// The relative-date maths behind the Reschedule submenu (#33). The boundary
/// cases (a Monday must roll to *next* Monday, not stay put) live in Core so
/// they are testable with an injected `today`/`calendar`, like every other
/// date rule (ADR-0002).
func reschedulePresetChecks(_ t: CheckRun) async {
    t.suite("ReschedulePreset date maths (#33)")

    // A fixed Gregorian calendar in UTC so day arithmetic is deterministic and
    // never depends on the machine's zone.
    var cal = Calendar(identifier: .gregorian)
    cal.timeZone = TimeZone(identifier: "UTC")!

    func day(_ y: Int, _ m: Int, _ d: Int) -> Date {
        cal.date(from: DateComponents(year: y, month: m, day: d))!
    }

    // Anchor weekdays used below (self-checked so a wrong assumption fails loudly).
    // 2026-07-08 Wed, 2026-07-12 Sun, 2026-07-13 Mon, 2026-07-20 Mon.
    await t.test("the anchor dates are the weekdays the cases assume") {
        t.expectEqual(cal.component(.weekday, from: day(2026, 7, 8)), 4)  // Wednesday
        t.expectEqual(cal.component(.weekday, from: day(2026, 7, 12)), 1) // Sunday
        t.expectEqual(cal.component(.weekday, from: day(2026, 7, 13)), 2) // Monday
    }

    await t.test("today returns the start of the given day, dropping the time") {
        let afternoon = cal.date(from: DateComponents(year: 2026, month: 7, day: 8, hour: 15, minute: 30))!
        t.expectEqual(ReschedulePreset.today.date(from: afternoon, calendar: cal), day(2026, 7, 8))
    }

    await t.test("tomorrow returns the next day at midnight") {
        let afternoon = cal.date(from: DateComponents(year: 2026, month: 7, day: 8, hour: 15))!
        t.expectEqual(ReschedulePreset.tomorrow.date(from: afternoon, calendar: cal), day(2026, 7, 9))
    }

    await t.test("next Monday from a Wednesday is the coming Monday") {
        t.expectEqual(ReschedulePreset.nextMonday.date(from: day(2026, 7, 8), calendar: cal), day(2026, 7, 13))
    }

    await t.test("next Monday from a Monday is a week later, not the same day") {
        t.expectEqual(ReschedulePreset.nextMonday.date(from: day(2026, 7, 13), calendar: cal), day(2026, 7, 20))
    }

    await t.test("next Monday from a Sunday is the very next day") {
        t.expectEqual(ReschedulePreset.nextMonday.date(from: day(2026, 7, 12), calendar: cal), day(2026, 7, 13))
    }

    await t.test("the cases are ordered Today, Tomorrow, Next Monday for the menu") {
        t.expectEqual(ReschedulePreset.allCases, [.today, .tomorrow, .nextMonday])
    }
}
