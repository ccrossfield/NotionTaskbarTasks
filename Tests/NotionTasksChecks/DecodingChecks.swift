import Foundation
import NotionTasksCore

func decodingChecks(_ t: CheckRun) async {
    t.suite("Decoding a Notion query response")

    await t.test("decodes every task with title and status") {
        let response = try JSONDecoder().decode(
            NotionQueryResponse.self, from: try fixtureData("query_response"))
        let tasks = response.tasks

        // Expected values read from the fixture (independent source of truth).
        t.expectEqual(tasks.count, 5)
        t.expectEqual(tasks[0].id, "11111111-0000-0000-0000-000000000001")
        t.expectEqual(tasks[0].title, "Wire up the menu bar read path")
        t.expect(tasks[0].status == "In Progress", "tasks[0].status was \(tasks[0].status ?? "nil")")
        t.expect(tasks[1].status == "To Do", "tasks[1].status was \(tasks[1].status ?? "nil")")
        t.expect(tasks[2].status == "Blocked", "tasks[2].status was \(tasks[2].status ?? "nil")")
        t.expect(tasks[3].status == "Done", "tasks[3].status was \(tasks[3].status ?? "nil")")
    }

    await t.test("a task with unset status decodes to nil") {
        let tasks = try JSONDecoder().decode(
            NotionQueryResponse.self, from: try fixtureData("query_response")).tasks
        let inbox = try require(tasks.first { $0.title == "Inbox zero sweep" })
        t.expect(inbox.status == nil, "expected nil status, got \(inbox.status ?? "nil")")
    }

    await t.test("each task carries its page's Notion URL (#21)") {
        let tasks = try JSONDecoder().decode(
            NotionQueryResponse.self, from: try fixtureData("query_response")).tasks
        t.expectEqual(
            tasks[0].url,
            "https://www.notion.so/Wire-up-the-menu-bar-read-path-11111111000000000000000000000001")
        t.expectEqual(
            tasks[4].url,
            "https://www.notion.so/Inbox-zero-sweep-11111111000000000000000000000005")
    }

    await t.test("a page without url decodes with url nil (#21)") {
        // Real page objects always carry `url`; this guards the decoder against
        // its absence anyway, since a nil url just disables open-in-Notion.
        let json = """
        {
          "object": "list",
          "results": [{
            "id": "no-url-task",
            "properties": {
              "Task": { "type": "title", "title": [{ "plain_text": "No URL" }] }
            }
          }],
          "next_cursor": null,
          "has_more": false
        }
        """
        let tasks = try JSONDecoder().decode(
            NotionQueryResponse.self, from: Data(json.utf8)).tasks
        t.expect(tasks[0].url == nil, "expected nil url, got \(tasks[0].url ?? "nil")")
    }

    await t.test("paging fields decode") {
        let response = try JSONDecoder().decode(
            NotionQueryResponse.self, from: try fixtureData("query_response"))
        t.expectEqual(response.hasMore, false)
        t.expect(response.nextCursor == nil, "expected nil next_cursor")
    }

    await t.test("priority decodes to P0/P1/P2, or nil when unset") {
        let tasks = try JSONDecoder().decode(
            NotionQueryResponse.self, from: try fixtureData("query_response")).tasks
        t.expect(tasks[0].priority == "P1", "tasks[0].priority was \(String(describing: tasks[0].priority))")
        t.expect(tasks[1].priority == "P0", "tasks[1].priority was \(String(describing: tasks[1].priority))")
        t.expect(tasks[2].priority == "P2", "tasks[2].priority was \(String(describing: tasks[2].priority))")
        t.expect(tasks[3].priority == nil, "tasks[3].priority (select null) should be nil")
        t.expect(tasks[4].priority == nil, "tasks[4].priority (unset) should be nil")
    }

    await t.test("a priority option outside P0/P1/P2 decodes carrying its raw name (#15)") {
        // Same shape as the fixture, but with a Priority option our code never
        // names. The raw name must survive decoding — the schema, not a closed
        // enum, is the source of truth for priorities.
        let json = """
        {
          "object": "list",
          "results": [{
            "id": "p3-task",
            "properties": {
              "Task": { "type": "title", "title": [{ "plain_text": "A P3 task" }] },
              "Priority": { "id": "prio", "type": "select",
                            "select": { "id": "opt-p3", "name": "P3", "color": "purple" } }
            }
          }],
          "has_more": false,
          "next_cursor": null
        }
        """
        let tasks = try JSONDecoder().decode(NotionQueryResponse.self, from: Data(json.utf8)).tasks
        t.expectEqual(tasks.first?.priority, "P3")
    }

    await t.test("category decodes to the select name, or nil when unset") {
        let tasks = try JSONDecoder().decode(
            NotionQueryResponse.self, from: try fixtureData("query_response")).tasks
        t.expect(tasks[0].category == "👨🏻‍💻 Work", "tasks[0].category was \(tasks[0].category ?? "nil")")
        t.expect(tasks[2].category == "📝 Life admin", "tasks[2].category was \(tasks[2].category ?? "nil")")
        t.expect(tasks[4].category == nil, "tasks[4].category (unset) should be nil")
    }

    await t.test("due date decodes to the right calendar day, or nil when absent") {
        let tasks = try JSONDecoder().decode(
            NotionQueryResponse.self, from: try fixtureData("query_response")).tasks
        // tasks[1] is due 2026-07-02 in the fixture.
        let due = try require(tasks[1].dueDate)
        let parts = Calendar.current.dateComponents([.year, .month, .day], from: due)
        t.expectEqual(parts.year, 2026)
        t.expectEqual(parts.month, 7)
        t.expectEqual(parts.day, 2)
        t.expect(tasks[2].dueDate == nil, "tasks[2] has date:null, dueDate should be nil")
        t.expect(tasks[4].dueDate == nil, "tasks[4] has no due date, dueDate should be nil")
    }

    await t.test("start-from decodes when present and is nil when the property is absent") {
        let tasks = try JSONDecoder().decode(
            NotionQueryResponse.self, from: try fixtureData("query_response")).tasks
        // tasks[0] carries "Start from": 2026-06-15; tasks[2] has no such property.
        let start = try require(tasks[0].startFrom)
        let parts = Calendar.current.dateComponents([.year, .month, .day], from: start)
        t.expectEqual(parts.year, 2026)
        t.expectEqual(parts.month, 6)
        t.expectEqual(parts.day, 15)
        t.expect(tasks[2].startFrom == nil, "tasks[2] has no Start from, should be nil")
    }

    await t.test("created time decodes from the page's created_time") {
        let tasks = try JSONDecoder().decode(
            NotionQueryResponse.self, from: try fixtureData("query_response")).tasks
        // tasks[0] was created 2026-06-01T09:00:00Z, tasks[1] 2026-06-02.
        let created = try require(tasks[0].createdTime)
        let parts = Calendar.current.dateComponents([.year, .month, .day], from: created)
        t.expectEqual(parts.year, 2026)
        t.expectEqual(parts.month, 6)
        t.expectEqual(parts.day, 1)
        // Ordering is what the Created-sorted presets (#5) rely on.
        let created1 = try require(tasks[1].createdTime)
        t.expect(created < created1, "task[0] should be created before task[1]")
    }

    await t.test("last edited time decodes from the page's last_edited_time") {
        let tasks = try JSONDecoder().decode(
            NotionQueryResponse.self, from: try fixtureData("query_response")).tasks
        // tasks[0] last edited 2026-06-20; tasks[1] 2026-06-18 → [0] is newer.
        let edited0 = try require(tasks[0].lastEditedTime)
        let edited1 = try require(tasks[1].lastEditedTime)
        t.expect(edited0 > edited1, "task[0] should be edited more recently than task[1]")
    }

    await t.test("WorkType decodes to the select name, or nil when absent") {
        let tasks = try JSONDecoder().decode(
            NotionQueryResponse.self, from: try fixtureData("query_response")).tasks
        t.expect(tasks[0].workType == "Strategy", "tasks[0].workType was \(tasks[0].workType ?? "nil")")
        t.expect(tasks[1].workType == "Reporting/Comms", "tasks[1].workType was \(tasks[1].workType ?? "nil")")
        t.expect(tasks[3].workType == nil, "tasks[3] has no WorkType, should be nil")
    }
}
