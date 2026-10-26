import XCTest
import CryptoKit
@testable import UniApiCore

final class BenchmarkClockTests: XCTestCase {
    func testTimestampCacheMatchesOriginalFormatterAcrossOffsetsAndFailures() async {
        let values = ["2026-10-14T06:00:00.125Z", "2026-10-14T08:30:00.125+02:30", "2026-10-14T02:00:00.125-04:00", "2026-10-14T06:00:00Z", "2024-02-29T23:59:59.999Z", "", "invalid", "2026-10-14"]
        let expected = values.map { value -> Double in
            let formatter = ISO8601DateFormatter(); formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let date = formatter.date(from: value) { return date.timeIntervalSince1970 }
            formatter.formatOptions = [.withInternetDateTime]
            return formatter.date(from: value)?.timeIntervalSince1970 ?? -Double.greatestFiniteMagnitude
        }
        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<32 { group.addTask { for (value, result) in zip(values, expected) { XCTAssertEqual(BenchmarkMath.timestamp(value), result) } } }
        }
        let date = Date(timeIntervalSince1970: 1791957600.125)
        let formatter = ISO8601DateFormatter(); formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        XCTAssertEqual(BenchmarkMath.iso(date), formatter.string(from: date))
    }
    func testDigestHexKeepsFullIdentityAndZeroPadding() {
        let bytes = Array(UInt8.min...UInt8.max)
        XCTAssertEqual(NativeHex.encode(bytes), bytes.map { String(format: "%02x", $0) }.joined())
        XCTAssertEqual(NativeHex.encode(SHA256.hash(data: Data("abc".utf8))), "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
    }
}
