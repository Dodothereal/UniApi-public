import Foundation

/// Recognize only the common, unambiguous UTC transcript forms. A miss is not
/// an invalid-date verdict: the original Foundation parser still owns it.
enum StatisticsTimestampFastPath {
    private static let monthStarts = [0, 31, 59, 90, 120, 151, 181, 212, 243, 273, 304, 334]
    private static let monthLengths = [31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31]

    static func timestamp(_ value: String) -> Double? {
        if let result = value.utf8.withContiguousStorageIfAvailable(parse) { return result }
        // A bridged string need not expose contiguous UTF-8. Keep that copy
        // bounded to the recognized lengths instead of copying arbitrary text.
        let count = value.utf8.count
        guard count == 20 || count == 24 else { return nil }
        return Array(value.utf8).withUnsafeBufferPointer(parse)
    }

    private static func parse(_ bytes: UnsafeBufferPointer<UInt8>) -> Double? {
        guard bytes.count == 20 || bytes.count == 24,
              bytes[4] == 45, bytes[7] == 45, bytes[10] == 84,
              bytes[13] == 58, bytes[16] == 58, bytes[bytes.count - 1] == 90 else { return nil }
        if bytes.count == 24 && bytes[19] != 46 { return nil }

        func digits(_ start: Int, _ count: Int) -> Int? {
            var result = 0
            for index in start..<(start + count) {
                let byte = bytes[index]
                guard byte >= 48 && byte <= 57 else { return nil }
                result = result * 10 + Int(byte - 48)
            }
            return result
        }
        guard let year = digits(0, 4), (1900...2099).contains(year),
              let month = digits(5, 2), (1...12).contains(month),
              let day = digits(8, 2), day > 0,
              let hour = digits(11, 2), hour < 24,
              let minute = digits(14, 2), minute < 60,
              let second = digits(17, 2), second < 60 else { return nil }
        let leap = year % 4 == 0 && (year % 100 != 0 || year % 400 == 0)
        let length = monthLengths[month - 1] + (month == 2 && leap ? 1 : 0)
        guard day <= length else { return nil }
        let millisecond: Int
        if bytes.count == 24 {
            guard let value = digits(20, 3) else { return nil }
            millisecond = value
        } else { millisecond = 0 }

        // This deliberately bounded Gregorian range avoids cutover/era and
        // extreme-date policies. Those still belong to Foundation's fallback.
        let priorYear = year - 1
        let epochLeapDays = 1969 / 4 - 1969 / 100 + 1969 / 400
        let leapDays = priorYear / 4 - priorYear / 100 + priorYear / 400 - epochLeapDays
        let days = (year - 1970) * 365 + leapDays + monthStarts[month - 1]
            + (month > 2 && leap ? 1 : 0) + day - 1
        let seconds = days * 86_400 + hour * 3600 + minute * 60 + second
        let milliseconds = seconds * 1000 + millisecond

        // Preserve the formatter's Date/Unix-seconds/milliseconds conversion,
        // including reference-date rounding. Returning the integral millisecond
        // count directly can change fractional results at exact boundaries.
        return Date(timeIntervalSince1970: Double(milliseconds) / 1000).timeIntervalSince1970 * 1000
    }
}
