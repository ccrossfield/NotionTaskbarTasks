import Foundation

/// What the quick-add composer creates (#22): a title plus the three optional
/// quick fields. Everything else (Status, WorkType, Start from, Notes) is
/// deliberately absent — Status so Notion applies the DB default, the rest
/// because refinement happens in Notion; the composer's job is fast capture
/// that lands in the right view.
public struct TaskDraft: Equatable {
    public var title: String
    /// A Priority select-option name ("P0"), or nil to leave it unset. An
    /// unset priority stays visible — the grouped presets have a real
    /// "No priority" group — so it never needs a default.
    public var priority: String?
    /// A Category select-option name (with its emoji), or nil. A task with no
    /// category matches neither Pivotal nor Home priorities, which is why the
    /// composer pre-fills this where the active view makes it unambiguous.
    public var category: String?
    public var dueDate: Date?

    public init(title: String = "", priority: String? = nil,
                category: String? = nil, dueDate: Date? = nil) {
        self.title = title
        self.priority = priority
        self.category = category
        self.dueDate = dueDate
    }

    /// The title as it would be created. Add stays disabled while this is empty.
    public var trimmedTitle: String {
        title.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// The composer's view-aware pre-fill (#22): defaults only where the active
/// view makes them unambiguous, so a quick capture lands visible in the view
/// it was captured from. Home priorities deliberately defaults nothing — it
/// spans several personal categories, and a wrong pre-filled value is harder
/// to spot than an empty one.
public enum ComposerDefaults {
    public static func draft(
        for preset: Preset,
        isCustom: Bool,
        workCategory: String,
        today: Date,
        calendar: Calendar = .current
    ) -> TaskDraft {
        guard !isCustom else { return TaskDraft() }
        switch preset {
        case .pivotalPriorities:
            return TaskDraft(category: workCategory)
        case .lateOrDueToday:
            return TaskDraft(dueDate: calendar.startOfDay(for: today))
        case .homePriorities, .allOpen:
            return TaskDraft()
        }
    }

    /// The next calendar day at local midnight — the composer's "Tomorrow".
    /// Lives here (not in the view) so the day-boundary maths is testable.
    public static func tomorrow(after today: Date, calendar: Calendar = .current) -> Date {
        calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: today)) ?? today
    }

    /// The next Monday strictly after today — on a Monday that is next
    /// week's, matching what "next Monday" means when you're planning.
    public static func nextMonday(after today: Date, calendar: Calendar = .current) -> Date {
        calendar.nextDate(after: calendar.startOfDay(for: today),
                          matching: DateComponents(weekday: 2),
                          matchingPolicy: .nextTime) ?? today
    }
}
