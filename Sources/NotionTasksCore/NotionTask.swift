import Foundation

/// A task as the app displays it. Named `NotionTask` deliberately — `Task`
/// collides with Swift concurrency's `Task`.
///
/// This slice (issue #2) only needs identity, title and current status. Later
/// slices add priority, due date and category.
public struct NotionTask: Identifiable, Equatable {
    public let id: String
    public let title: String
    /// The Status option name (e.g. "To Do", "Blocked"), or `nil` if unset.
    public let status: String?

    public init(id: String, title: String, status: String?) {
        self.id = id
        self.title = title
        self.status = status
    }
}
