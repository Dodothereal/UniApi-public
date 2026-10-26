import Foundation
import XCTest
@testable import UniApiCore

final class StatisticsTimestampFastPathTests: XCTestCase {
    // A fresh copy of the original formatter sequence is the oracle. Neither
    // expected calendar arithmetic nor expected rounding uses the fast path.
    private func reference(_ value: String) -> Double? {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: value) { return date.timeIntervalSince1970 * 1000 }
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        if let date = plain.date(from: value) { return date.timeIntervalSince1970 * 1000 }
        let day = DateFormatter()
        day.calendar = Calendar(identifier: .gregorian)
        day.locale = Locale(identifier: "en_US_POSIX")
        day.timeZone = TimeZone(secondsFromGMT: 0)
        day.dateFormat = "yyyy-MM-dd"; day.isLenient = false
        if value.count == 10, let date = day.date(from: value), day.string(from: date) == value {
            return date.timeIntervalSince1970 * 1000
        }
        return nil
    }

    private func assertParity(_ value: String, fast: Bool, file: StaticString = #filePath, line: UInt = #line) {
        let expected = reference(value)
        let direct = StatisticsTimestampFastPath.timestamp(value)
        let actual = statisticsTimestamp(.string(value))
        if fast { XCTAssertNotNil(direct, value, file: file, line: line) }
        else { XCTAssertNil(direct, value, file: file, line: line) }
        XCTAssertEqual(actual, expected, value, file: file, line: line)
        if let actual, let expected {
            XCTAssertEqual(actual.bitPattern, expected.bitPattern, value, file: file, line: line)
        }
        if let direct {
            guard let expected else { XCTFail(value, file: file, line: line); return }
            XCTAssertEqual(direct.bitPattern, expected.bitPattern, value, file: file, line: line)
        }
    }

    func testCanonicalUTCRepresentativesMatchFreshFoundationExactly() {
        for value in [
            "1900-01-01T00:00:00Z", "1904-02-29T23:59:59.999Z",
            "1969-12-31T23:59:59.001Z", "1970-01-01T00:00:00Z",
            "1970-01-01T00:00:00.001Z", "1999-12-31T23:59:59.999Z",
            "2000-02-29T12:34:56.123Z", "2001-01-01T00:00:00.000Z",
            "2024-02-29T23:59:59.999Z", "2026-10-14T12:34:56Z",
            "2026-10-14T12:34:56.123Z", "2099-12-31T23:59:59.999Z"
        ] { assertParity(value, fast: true) }
        assertParity(NSString(string: "2026-10-14T12:34:56.123Z") as String, fast: true)
        assertParity(NSString(string: "1969-12-31T23:59:59Z") as String, fast: true)
    }

    func testEveryMillisecondAcrossEpochReferenceAndModernDatesMatchesExactly() {
        for prefix in ["1969-12-31T23:59:59", "1970-01-01T00:00:00",
                       "2000-12-31T23:59:59", "2026-10-14T12:34:56", "2099-12-31T23:59:59"] {
            for millisecond in 0...999 {
                assertParity(prefix + String(format: ".%03dZ", millisecond), fast: true)
            }
        }
    }

    func testGregorianMonthEdgesLeapYearsAndClockFieldsUseIndependentCalendarOracle() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(secondsFromGMT: 0))
        for year in [1900, 1969, 1970, 2000, 2001, 2024, 2026, 2099] {
            for month in 1...12 {
                let first = try XCTUnwrap(calendar.date(from: DateComponents(year: year, month: month, day: 1)))
                let days = try XCTUnwrap(calendar.range(of: .day, in: .month, for: first))
                for day in [days.lowerBound, 15, days.upperBound - 1] {
                    let prefix = String(format: "%04d-%02d-%02dT%02d:%02d:%02d", year, month, day,
                                        day % 24, (day * 7) % 60, (day * 13) % 60)
                    assertParity(prefix + "Z", fast: true)
                    assertParity(prefix + ".731Z", fast: true)
                }
            }
        }
    }

    func testUnrecognizedFractionsOffsetsDatesAndTextKeepOriginalFallbackSemantics() {
        let values = [
            "2026-10-14", "2000-02-29", "1900-02-29", "2026-02-30",
            "0001-01-01T00:00:00Z", "1582-10-15T00:00:00Z",
            "1899-12-31T23:59:59.999Z", "2100-01-01T00:00:00Z", "9999-12-31T23:59:59Z",
            "2026-10-14T12:34:56.1Z", "2026-10-14T12:34:56.12Z",
            "2026-10-14T12:34:56.1234Z", "2026-10-14T12:34:56.123456Z",
            "2026-10-14T12:34:56.123456789Z", "2026-10-14T12:34:56,123Z",
            "2026-10-14T12:34:56+00:00", "2026-10-14T12:34:56-00:00",
            "2026-10-14T12:34:56.123+05:30", "2026-10-14T12:34:56.123-07:00",
            "2026-10-14T12:34:56+0000", "2026-10-14T12:34:56+14:00",
            "2026-10-14t12:34:56z", "2026-10-14 12:34:56Z",
            " 2026-10-14T12:34:56Z", "2026-10-14T12:34:56Z ",
            "2026-10-14T12:34:56Z\n", "2026-10-14T12:34:56.123Zignored",
            "2026-10-14T12:34:56.Z", "2026-10-14T12:34:56Z\0",
            "20261014T123456Z", "2026-W42-3T12:34:56Z",
            "２０２６-10-14T12:34:56Z", "2026-10-14T12:34:５６Z", "", "not-a-date"
        ]
        for value in values { assertParity(value, fast: false) }
    }

    func testInvalidCanonicalCalendarAndClockInputsAreFallbackNotNewRejectionPolicy() {
        for value in [
            "1900-02-29T12:34:56Z", "2000-02-30T12:34:56.123Z",
            "2026-02-29T12:34:56Z", "2024-02-30T12:34:56Z",
            "2026-04-31T12:34:56.123Z", "2026-00-01T12:34:56Z",
            "2026-13-01T12:34:56Z", "2026-10-00T12:34:56Z",
            "2026-10-32T12:34:56Z", "2026-10-14T24:00:00Z",
            "2026-10-14T25:34:56.123Z", "2026-10-14T12:60:56Z",
            "2026-10-14T12:34:60Z", "2016-12-31T23:59:60.000Z",
            "2026-10-14T12:34:99Z", "2026-10-14T-1:34:56Z"
        ] { assertParity(value, fast: false) }

        let canonical = Array("2026-10-14T12:34:56.123Z")
        let replacements: [Character] = ["X", " ", "/", "٠"]
        for index in canonical.indices {
            for replacement in replacements {
                var malformed = canonical; malformed[index] = replacement
                assertParity(String(malformed), fast: false)
            }
        }
    }

    func testConcurrentFastAndFallbackReadsRetainExactIndependentOracleResults() async {
        let texts = ["2026-10-14T12:34:56.123Z", "1969-12-31T23:59:59.999Z",
                     "2026-10-14T12:34:56.123456Z", "2026-10-14T12:34:56+05:30",
                     "2026-10-14", "not-a-date"]
        let expected = texts.map { reference($0) }
        await withTaskGroup(of: (Int, Double?).self) { group in
            for index in 0..<240 {
                let slot = index % texts.count, text = texts[index % texts.count]
                group.addTask { (slot, statisticsTimestamp(.string(text))) }
            }
            for await (slot, actual) in group {
                XCTAssertEqual(actual, expected[slot], texts[slot])
                if let actual, let expected = expected[slot] {
                    XCTAssertEqual(actual.bitPattern, expected.bitPattern, texts[slot])
                }
            }
        }
    }
}
