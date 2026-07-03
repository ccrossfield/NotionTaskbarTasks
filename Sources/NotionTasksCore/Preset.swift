import Foundation

/// The built-in task views the user can switch between (#5). Each mirrors an
/// existing Notion view. Pivotal Priorities is the launch default (#4).
///
/// `CaseIterable` order is the picker order.
public enum Preset: String, CaseIterable, Identifiable, Equatable, Codable {
    case pivotalPriorities
    case lateOrDueToday
    case homePriorities
    case allOpen

    public var id: String { rawValue }

    /// The picker label and the panel's title.
    public var title: String {
        switch self {
        case .pivotalPriorities: return "Pivotal Priorities"
        case .lateOrDueToday: return "Late or due today"
        case .homePriorities: return "Home priorities"
        case .allOpen: return "All open"
        }
    }

    /// Priority views show P0/P1/P2 section headers; flat views are one ordered
    /// list with no headers. The view keys off this to decide whether to render
    /// section headers (a flat preset's single group carries `priority == nil`,
    /// which would otherwise be indistinguishable from a "no priority" section).
    public var isGrouped: Bool {
        switch self {
        case .pivotalPriorities, .homePriorities: return true
        case .lateOrDueToday, .allOpen: return false
        }
    }
}
