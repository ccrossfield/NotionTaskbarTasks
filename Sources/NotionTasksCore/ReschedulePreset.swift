import Foundation

/// The quick relative options offered by the row's Reschedule submenu (#33).
/// The date maths lives here, not in the view, so the boundary cases (a Monday
/// must roll to *next* Monday, not stay put) are testable with an injected
/// `today`/`calendar` — the same reason `NotionTask.relativeDueText()` lives in
/// Core (ADR-0002). Due dates are date-only, so every result is a local
/// midnight, matching the composer and the decoder.
///
/// `allCases` order is the menu order: Today, Tomorrow, Next Monday.
public enum ReschedulePreset: CaseIterable {
    case today
    case tomorrow
    case nextMonday

    /// The menu label for this option.
    public var label: String {
        switch self {
        case .today: return "Today"
        case .tomorrow: return "Tomorrow"
        case .nextMonday: return "Next Monday"
        }
    }

    /// The due date this option resolves to, as a local midnight relative to
    /// `today`. "Next Monday" is the Monday *strictly after* today, so choosing
    /// it on a Monday moves the task a week out rather than leaving it put.
    public func date(from today: Date = Date(), calendar: Calendar = .current) -> Date {
        let start = calendar.startOfDay(for: today)
        switch self {
        case .today:
            return start
        case .tomorrow:
            return calendar.date(byAdding: .day, value: 1, to: start) ?? start
        case .nextMonday:
            // Gregorian weekday: 1 = Sunday … 2 = Monday … 7 = Saturday.
            let weekday = calendar.component(.weekday, from: start)
            let daysUntilMonday = ((2 - weekday) + 7) % 7
            // 0 means today is Monday; roll to next week rather than staying put.
            let offset = daysUntilMonday == 0 ? 7 : daysUntilMonday
            return calendar.date(byAdding: .day, value: offset, to: start) ?? start
        }
    }
}
