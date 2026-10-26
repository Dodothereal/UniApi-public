import XCTest
import Foundation
@testable import UniApiCore

final class StatisticsCalendarCursorTests: XCTestCase {
    private func calendar(_ zone: String, _ identifier: Calendar.Identifier = .gregorian) -> Calendar {
        var value = Calendar(identifier: identifier); value.timeZone = TimeZone(identifier: zone)!; return value
    }
    private func instant(_ value: String) -> Double { ISO8601DateFormatter().date(from: value)!.timeIntervalSince1970 * 1000 }

    func testMatchesCalendarAcrossDSTMidnightTransitionsAndSkippedDates() {
        let cases = [("Europe/Berlin", "2026-03-29T00:00:00Z"), ("Europe/Berlin", "2026-10-25T00:00:00Z"),
                     ("America/Los_Angeles", "2026-11-01T00:00:00Z"), ("America/Sao_Paulo", "2018-11-04T00:00:00Z"),
                     ("Pacific/Apia", "2011-12-30T00:00:00Z"), ("UTC", "2024-02-29T00:00:00Z")]
        for (zone, center) in cases {
            for identifier in [Calendar.Identifier.gregorian, .buddhist, .hebrew] {
                let c = calendar(zone, identifier); var cursor = StatisticsCalendarCursor(calendar: c)
                for step in -192...192 {
                    let ts = instant(center) + Double(step) * 900_000
                    XCTAssertEqual(cursor.day(ts), statisticsDay(ts, calendar: c), "\(zone) \(identifier) \(step)")
                }
            }
        }
    }
    func testEndIsExclusiveAndBackwardJumpsDoNotReuseAnotherDay() {
        let c = calendar("Europe/Berlin"); var cursor = StatisticsCalendarCursor(calendar: c)
        let start = instant("2026-03-28T23:00:00Z"), end = instant("2026-03-29T22:00:00Z")
        let values = [start, end - 0.001, end, start - 0.001, end + 1, start + 1, 0, -0.001, start]
        for ts in values { XCTAssertEqual(cursor.day(ts), statisticsDay(ts, calendar: c)) }
        XCTAssertEqual(end - start, 23 * 3_600_000)
    }
    func testIndependentCursorsRetainTheirOwnCalendarAndTimeZone() {
        let berlin = calendar("Europe/Berlin"), la = calendar("America/Los_Angeles")
        var a = StatisticsCalendarCursor(calendar: berlin), b = StatisticsCalendarCursor(calendar: la)
        for ts in [instant("2026-03-29T01:30:00Z"), instant("2026-03-29T21:00:00Z"), instant("2026-03-29T01:30:00Z")] {
            XCTAssertEqual(a.day(ts), statisticsDay(ts, calendar: berlin)); XCTAssertEqual(b.day(ts), statisticsDay(ts, calendar: la))
            XCTAssertNotEqual(a.day(ts), b.day(ts))
        }
    }
}
