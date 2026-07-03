import Foundation

/// Everything the panel needs to render instantly, captured after the last
/// successful fetch: the tasks plus the schema-derived filter facts, and when
/// they were fetched. Persisted by `FileTaskCache` so a fresh launch shows the
/// last-known list at once instead of a spinner (issue #7's "no blank flash").
public struct CachedSnapshot: Codable, Equatable {
    public let tasks: [NotionTask]
    public let openStatuses: Set<String>
    public let workCategory: String
    public let personalCategories: Set<String>
    public let schemaOptions: SchemaOptions
    public let fetchedAt: Date

    public init(tasks: [NotionTask],
                openStatuses: Set<String>,
                workCategory: String,
                personalCategories: Set<String>,
                schemaOptions: SchemaOptions,
                fetchedAt: Date) {
        self.tasks = tasks
        self.openStatuses = openStatuses
        self.workCategory = workCategory
        self.personalCategories = personalCategories
        self.schemaOptions = schemaOptions
        self.fetchedAt = fetchedAt
    }
}

/// The cache seam. The app persists the last snapshot to disk; tests use an
/// in-memory fake. Deliberately fire-and-forget: the cache is an optimisation,
/// so no call can fail — a broken cache degrades to "no cache", never to a
/// broken app.
public protocol TaskCache {
    func load() -> CachedSnapshot?
    func save(_ snapshot: CachedSnapshot)
    func clear()
}

/// Stores the snapshot as a JSON file. Any read, decode, or write failure is
/// swallowed: an unreadable or corrupt file behaves exactly like no cache.
public struct FileTaskCache: TaskCache {
    private let fileURL: URL

    /// ~/Library/Application Support/NotionTasks/tasks-cache.json
    public static var defaultURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("NotionTasks", isDirectory: true)
            .appendingPathComponent("tasks-cache.json")
    }

    public init(fileURL: URL = FileTaskCache.defaultURL) {
        self.fileURL = fileURL
    }

    public func load() -> CachedSnapshot? {
        guard let data = try? Data(contentsOf: fileURL) else { return nil }
        return try? JSONDecoder().decode(CachedSnapshot.self, from: data)
    }

    public func save(_ snapshot: CachedSnapshot) {
        guard let data = try? JSONEncoder().encode(snapshot) else { return }
        try? FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: fileURL, options: .atomic)
    }

    public func clear() {
        try? FileManager.default.removeItem(at: fileURL)
    }
}
