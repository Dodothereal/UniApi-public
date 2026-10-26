import Foundation

/// Folds usually visit chronologically ordered events. Reuse only the current
/// calendar day, bounded by calendar arithmetic rather than a fixed 24 hours.
/// Each fold owns its cursor, so scope, time zone and concurrent reads cannot
/// share stale calendar state. Backward or unordered timestamps still resolve.
struct StatisticsCalendarCursor {
    let calendar: Calendar
    private var interval: (start: Date, end: Date, value: Double)?

    init(calendar: Calendar) { self.calendar = calendar }

    mutating func day(_ timestamp: Double) -> Double {
        let date = Date(timeIntervalSince1970: timestamp / 1000)
        if let interval, date >= interval.start, date < interval.end { return interval.value }
        let start = calendar.startOfDay(for: date)
        let value = start.timeIntervalSince1970 * 1000
        // Adding one day to a 01:00 start (a skipped midnight) can end at
        // 01:00 the following day. The calendar's day interval ends at its
        // actual next boundary instead.
        if let bounds = calendar.dateInterval(of: .day, for: date), bounds.start == start, bounds.end > start {
            interval = (start, bounds.end, value)
        } else { interval = nil }
        return value
    }
}
