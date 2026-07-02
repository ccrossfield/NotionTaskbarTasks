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

    await t.test("paging fields decode") {
        let response = try JSONDecoder().decode(
            NotionQueryResponse.self, from: try fixtureData("query_response"))
        t.expectEqual(response.hasMore, false)
        t.expect(response.nextCursor == nil, "expected nil next_cursor")
    }
}
