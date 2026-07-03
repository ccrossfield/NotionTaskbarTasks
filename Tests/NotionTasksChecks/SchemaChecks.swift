import Foundation
import NotionTasksCore

func schemaChecks(_ t: CheckRun) async {
    t.suite("Decoding the data source schema")

    await t.test("open statuses are every option not in the Complete group") {
        let schema = try JSONDecoder().decode(
            DataSourceSchema.self, from: try fixtureData("data_source_schema"))
        // Complete = {Done}; everything else is open, including Blocked.
        t.expectEqual(schema.openStatusNames, ["To Do", "In Progress", "Blocked"])
        t.expect(!schema.openStatusNames.contains("Done"), "Done must not be open")
    }

    await t.test("category options decode and Work is resolved past its emoji") {
        let schema = try JSONDecoder().decode(
            DataSourceSchema.self, from: try fixtureData("data_source_schema"))
        t.expectEqual(schema.categoryOptionNames.count, 5)
        t.expect(schema.categoryOptionNames.contains("👨🏻‍💻 Work"), "Work category should be present")
        t.expect(schema.workCategoryName == "👨🏻‍💻 Work",
                 "workCategoryName was \(schema.workCategoryName ?? "nil")")
    }

    await t.test("filter option lists (status, priority, WorkType) decode from the schema") {
        let schema = try JSONDecoder().decode(
            DataSourceSchema.self, from: try fixtureData("data_source_schema"))
        t.expectEqual(schema.statusOptionNames, ["To Do", "Blocked", "In Progress", "Done"])
        t.expectEqual(schema.priorityOptionNames, ["P0", "P1", "P2"])
        t.expectEqual(schema.workTypeOptionNames.count, 9)
        t.expect(schema.workTypeOptionNames.contains("PIVOT"), "WorkType options should include PIVOT")
    }

    await t.test("a newly added schema option appears with no code change (#6 criterion)") {
        // Same shape as the fixture, but with a WorkType option that doesn't
        // exist anywhere in our code. It must still surface in the option list.
        let json = """
        {
          "object": "data_source",
          "id": "ds",
          "properties": {
            "WorkType": {
              "id": "wtyp", "name": "WorkType", "type": "select",
              "select": { "options": [
                { "id": "w-strat", "name": "Strategy", "color": "blue" },
                { "id": "w-new", "name": "Brand New Stream", "color": "red" }
              ] }
            }
          }
        }
        """
        let schema = try JSONDecoder().decode(DataSourceSchema.self, from: Data(json.utf8))
        t.expect(schema.workTypeOptionNames.contains("Brand New Stream"),
                 "an option added in Notion must appear without code changes")
    }
}
