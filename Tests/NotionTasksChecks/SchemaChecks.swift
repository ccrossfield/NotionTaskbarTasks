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
}
