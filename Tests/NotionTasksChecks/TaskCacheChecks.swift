import Foundation
import NotionTasksCore

/// A known-good snapshot with every NotionTask field exercised, so the
/// round-trip check fails if any field is dropped by the Codable mapping.
func sampleSnapshot() -> CachedSnapshot {
    CachedSnapshot(
        tasks: [
            NotionTask(id: "c1", title: "Cached task", status: "To Do", priority: .p1,
                       dueDate: Date(timeIntervalSince1970: 1_800_000_000),
                       category: "📝 Life admin",
                       startFrom: Date(timeIntervalSince1970: 1_750_000_000),
                       createdTime: Date(timeIntervalSince1970: 1_700_000_000),
                       lastEditedTime: Date(timeIntervalSince1970: 1_750_100_000),
                       workType: "Strategy"),
            NotionTask(id: "c2", title: "Bare task", status: nil),
        ],
        openStatuses: ["To Do", "In Progress", "Blocked"],
        workCategory: "👨🏻‍💻 Work",
        personalCategories: ["📝 Life admin", "🎉 Fun admin"],
        schemaOptions: SchemaOptions(statuses: ["To Do", "Done"],
                                     categories: ["👨🏻‍💻 Work", "📝 Life admin"],
                                     priorities: ["P0", "P1", "P2"],
                                     workTypes: ["Strategy", "PIVOT"]),
        fetchedAt: Date(timeIntervalSince1970: 1_751_500_000))
}

func taskCacheChecks(_ t: CheckRun) async {
    t.suite("Task cache persistence")

    func tempFileURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("notiontasks-checks-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent("tasks-cache.json")
    }

    await t.test("a saved snapshot round-trips through the disk cache") {
        let url = tempFileURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let snapshot = sampleSnapshot()

        FileTaskCache(fileURL: url).save(snapshot)
        // A fresh instance, so the snapshot must have come from disk.
        let loaded = FileTaskCache(fileURL: url).load()

        t.expectEqual(loaded, snapshot)
    }

    await t.test("no cache file yet means no snapshot, not an error") {
        t.expect(FileTaskCache(fileURL: tempFileURL()).load() == nil,
                 "expected nil from a missing file")
    }

    await t.test("a corrupt cache file is treated as no cache") {
        let url = tempFileURL()
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try Data("not json{{".utf8).write(to: url)
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        t.expect(FileTaskCache(fileURL: url).load() == nil, "expected nil from corrupt data")
    }

    await t.test("clear removes the stored snapshot") {
        let url = tempFileURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let cache = FileTaskCache(fileURL: url)
        cache.save(sampleSnapshot())

        cache.clear()

        t.expect(cache.load() == nil, "expected nil after clear")
    }
}
