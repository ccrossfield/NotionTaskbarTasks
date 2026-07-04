import SwiftUI
import NotionTasksCore

/// The urgency tints for due-date text (#25, ADR-0003), shared by the panel's
/// task rows and the quick-capture capsule (#34) so a retune lands in one place.
///
/// Custom adaptive colours: the system red, orange and yellow are all too bright
/// to read at caption size on a light background (yellow by inspection, orange
/// and red by live test), so light mode gets deeper crimson/burnt-orange/ochre
/// and dark mode brighter tones. The three stay a hue apart so overdue reads
/// hottest. The dot stays the priority channel, so the tint is confined to text.
enum DueColor {
    /// The tint for a due bucket, or `nil` for the buckets that keep the
    /// metadata line's secondary grey (later / none).
    static func tint(for bucket: DueBucket) -> Color? {
        switch bucket {
        case .overdue: return overdueRed
        case .today: return todayOrange
        case .soon: return soonAmber
        case .later, .none: return nil
        }
    }

    static let overdueRed = Color(nsColor: NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(red: 1.00, green: 0.45, blue: 0.38, alpha: 1)
            : NSColor(red: 0.72, green: 0.12, blue: 0.10, alpha: 1)
    })

    static let todayOrange = Color(nsColor: NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(red: 1.00, green: 0.62, blue: 0.24, alpha: 1)
            : NSColor(red: 0.80, green: 0.35, blue: 0.02, alpha: 1)
    })

    static let soonAmber = Color(nsColor: NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(red: 1.00, green: 0.75, blue: 0.28, alpha: 1)
            : NSColor(red: 0.70, green: 0.46, blue: 0.02, alpha: 1)
    })
}
