import Foundation
import NotionTasksCore

func composerChecks(_ t: CheckRun) async {
    t.suite("Composer defaults (#22)")

    var cal = Calendar(identifier: .gregorian)
    cal.timeZone = TimeZone(identifier: "Europe/London")!
    // 2026-07-15 is a Wednesday.
    let wednesday = cal.date(from: DateComponents(year: 2026, month: 7, day: 15, hour: 12))!
    let work = "👨🏻‍💻 Work"

    await t.test("Pivotal Priorities pre-fills the Work category and nothing else") {
        let draft = ComposerDefaults.draft(for: .pivotalPriorities, isCustom: false,
                                           workCategory: work, today: wednesday, calendar: cal)
        t.expectEqual(draft, TaskDraft(category: work))
    }

    await t.test("Late or due today pre-fills Due = today and nothing else") {
        let draft = ComposerDefaults.draft(for: .lateOrDueToday, isCustom: false,
                                           workCategory: work, today: wednesday, calendar: cal)
        t.expectEqual(draft, TaskDraft(dueDate: cal.startOfDay(for: wednesday)))
    }

    await t.test("Home priorities pre-fills nothing - picking one personal category would be a guess") {
        let draft = ComposerDefaults.draft(for: .homePriorities, isCustom: false,
                                           workCategory: work, today: wednesday, calendar: cal)
        t.expectEqual(draft, TaskDraft())
    }

    await t.test("All open pre-fills nothing") {
        let draft = ComposerDefaults.draft(for: .allOpen, isCustom: false,
                                           workCategory: work, today: wednesday, calendar: cal)
        t.expectEqual(draft, TaskDraft())
    }

    await t.test("the custom view pre-fills nothing, whatever preset it was entered from") {
        let draft = ComposerDefaults.draft(for: .pivotalPriorities, isCustom: true,
                                           workCategory: work, today: wednesday, calendar: cal)
        t.expectEqual(draft, TaskDraft())
    }

    await t.test("the trimmed title strips surrounding whitespace") {
        t.expectEqual(TaskDraft(title: "  Book the venue \n").trimmedTitle, "Book the venue")
        t.expectEqual(TaskDraft(title: "   ").trimmedTitle, "")
    }

    t.suite("Composer quick due dates (#22)")

    await t.test("Tomorrow is the next calendar day at local midnight") {
        t.expectEqual(ComposerDefaults.tomorrow(after: wednesday, calendar: cal),
                      cal.date(from: DateComponents(year: 2026, month: 7, day: 16))!)
    }

    await t.test("Next Monday from a Wednesday is the coming Monday") {
        t.expectEqual(ComposerDefaults.nextMonday(after: wednesday, calendar: cal),
                      cal.date(from: DateComponents(year: 2026, month: 7, day: 20))!)
    }

    await t.test("Next Monday from a Monday is the following week's, not today") {
        let monday = cal.date(from: DateComponents(year: 2026, month: 7, day: 13, hour: 9))!
        t.expectEqual(ComposerDefaults.nextMonday(after: monday, calendar: cal),
                      cal.date(from: DateComponents(year: 2026, month: 7, day: 20))!)
    }

    t.suite("Schema title property (#22)")

    await t.test("the title property's name is resolved from the schema, not assumed") {
        let json = Data("""
        {
          "properties": {
            "Item": { "type": "title" },
            "Status": { "type": "status", "status": { "options": [], "groups": [] } }
          }
        }
        """.utf8)
        let schema = try JSONDecoder().decode(DataSourceSchema.self, from: json)
        t.expectEqual(schema.titlePropertyName, "Item")
    }
}
