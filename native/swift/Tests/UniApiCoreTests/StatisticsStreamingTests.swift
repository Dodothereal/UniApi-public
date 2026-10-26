import Foundation
import XCTest
@testable import UniApiCore

final class StatisticsStreamingTests: XCTestCase {
    private let timestamp: Double = 1791720000000
    private var utc: Calendar {
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = TimeZone(secondsFromGMT: 0)!; return calendar
    }
    private func varint(_ value: UInt64) -> Data {
        var value = value, bytes = Data()
        repeat { let byte = UInt8(value & 127); value >>= 7; bytes.append(byte | (value > 0 ? 128 : 0)) } while value > 0
        return bytes
    }
    private func field(_ number: UInt64, _ value: UInt64) -> Data { varint(number << 3) + varint(value) }
    private func field(_ number: UInt64, bytes: Data) -> Data { varint(number << 3 | 2) + varint(UInt64(bytes.count)) + bytes }
    private func duration(_ seconds: UInt64, nanos: UInt64 = 0) -> Data { field(1, seconds) + field(2, nanos) }
    private func generation(wait: Data?, stream: Data?, output: UInt64 = 100, thinking: UInt64 = 40) -> Data {
        let usage = field(2, 10) + field(3, output) + field(9, thinking) + field(11, bytes: Data("response".utf8))
        var chat = field(4, bytes: usage) + field(19, bytes: Data("fixture-model".utf8))
        chat += field(9, bytes: field(4, bytes: field(1, 1791720000)))
        if let wait { chat += field(11, bytes: wait) }
        if let stream { chat += field(12, bytes: stream) }
        return field(1, bytes: chat)
    }
    private func read(wait: Data?, stream: Data?, output: UInt64 = 100, thinking: UInt64 = 40) throws -> StatisticsUsage {
        try XCTUnwrap(StatisticsImporter.generation(generation(wait: wait, stream: stream, output: output, thinking: thinking), steps: [:], session: "fixture", project: "fixture", sidechain: false))
    }
    private func row(_ id: String, output: Double = 100, response: Double = 12000, stream: Double? = 2000, streamOutput: Double? = 100) -> StatisticsUsage {
        var event = StatisticsUsage(id: id, source: "antigravity", ts: timestamp, model: "fixture-model")
        event.output = output; event.thinking = output / 2; event.durationMs = response; event.timing = "recorded"
        event.streamDurationMs = stream; event.streamOutputTokens = streamOutput; event.streamTiming = "antigravity-stream-duration"
        return event
    }

    func testRecordedStreamExcludesTTFTAndDoesNotDoubleReasoning() throws {
        let event = try read(wait: duration(10), stream: duration(2))
        XCTAssertEqual(event.durationMs, 12000); XCTAssertEqual(event.timing, "recorded")
        XCTAssertEqual(event.streamDurationMs, 2000); XCTAssertEqual(event.streamOutputTokens, 100)
        XCTAssertEqual(event.streamTiming, "antigravity-stream-duration")
        XCTAssertEqual(event.output, 100); XCTAssertEqual(event.thinking, 40)
        let rates = StatisticsFold.throughput([event], calendar: utc)
        XCTAssertEqual(rates["summary"]["avgTps"].double, 100.0 / 12, accuracy: 0.000001)
        XCTAssertEqual(rates["streaming"]["summary"]["avgTps"], 50)
        XCTAssertEqual(rates["streaming"]["summary"]["outputTokens"], 100)
    }

    func testMissingOrInvalidTTFTDoesNotRejectValidRecordedStream() throws {
        for wait in [nil, field(1, bytes: Data("invalid".utf8))] as [Data?] {
            let event = try read(wait: wait, stream: duration(2, nanos: 500000000))
            XCTAssertNil(event.durationMs)
            XCTAssertEqual(event.streamDurationMs, 2500); XCTAssertEqual(event.streamOutputTokens, 100)
            XCTAssertEqual(event.streamTiming, "antigravity-stream-duration")
        }
    }

    func testTruncatedOptionalClocksRetainUsageWithoutRelaxingItsEnvelope() throws {
        for damaged in [Data([0x80]), Data([0x0a, 0x02, 0x01])] {
            let validStream = try read(wait: damaged, stream: duration(2))
            XCTAssertEqual(validStream.output, 100); XCTAssertEqual(validStream.thinking, 40)
            XCTAssertNil(validStream.durationMs)
            XCTAssertEqual(validStream.streamDurationMs, 2000); XCTAssertEqual(validStream.streamOutputTokens, 100)
            XCTAssertEqual(validStream.streamTiming, "antigravity-stream-duration")
            for wait in [nil, duration(10)] as [Data?] {
                let invalidStream = try read(wait: wait, stream: damaged)
                XCTAssertEqual(invalidStream.output, 100); XCTAssertEqual(invalidStream.thinking, 40)
                XCTAssertNil(invalidStream.durationMs)
                XCTAssertNil(invalidStream.streamDurationMs); XCTAssertNil(invalidStream.streamOutputTokens); XCTAssertNil(invalidStream.streamTiming)
            }
        }
        XCTAssertThrowsError(try StatisticsImporter.generation(Data([0x80]), steps: [:], session: "fixture", project: "fixture", sidechain: false))
        let malformedUsage = field(1, bytes: field(4, bytes: Data([0x80])))
        XCTAssertThrowsError(try StatisticsImporter.generation(malformedUsage, steps: [:], session: "fixture", project: "fixture", sidechain: false))
    }

    func testMissingZeroOrMalformedStreamAndZeroOutputHaveNoRawPair() throws {
        let invalid: [Data?] = [nil, Data(), duration(0), duration(1, nanos: 1000000000), field(1, bytes: Data("invalid".utf8)), duration(UInt64.max)]
        for stream in invalid {
            let event = try read(wait: duration(10), stream: stream)
            XCTAssertNil(event.streamDurationMs); XCTAssertNil(event.streamOutputTokens); XCTAssertNil(event.streamTiming)
            XCTAssertTrue(StatisticsFold.throughput([event], calendar: utc)["streaming"]["summary"]["avgTps"].isNull)
        }
        let empty = try read(wait: duration(10), stream: duration(2), output: 0)
        XCTAssertEqual(empty.durationMs, 12000)
        XCTAssertNil(empty.streamDurationMs); XCTAssertNil(empty.streamOutputTokens); XCTAssertNil(empty.streamTiming)
    }

    func testStreamPairsExcludeInterResponseToolWaitAndPopulateEveryProjection() {
        var first = row("first"), second = row("second", output: 300, response: 24000, stream: 4000, streamOutput: 300)
        first.model = "fixture-a"; second.model = "fixture-b"; second.ts += 120000
        let rates = StatisticsFold.throughput([first, second], calendar: utc), streaming = rates["streaming"]
        XCTAssertEqual(streaming["summary"]["avgTps"].double, 400.0 / 6, accuracy: 0.000001)
        XCTAssertEqual(streaming["summary"]["durationMs"], 6000)
        XCTAssertEqual(streaming["summary"]["outputTokens"], 400)
        XCTAssertEqual(rates["summary"]["durationMs"], 36000)
        XCTAssertEqual(streaming["models"].array.count, 2); XCTAssertEqual(streaming["pairs"].array.count, 2)
        XCTAssertEqual(streaming["harnesses"].array.first { $0["source"] == "antigravity" }?["avgTps"].double ?? 0, 400.0 / 6, accuracy: 0.000001)
        let day = streaming["days"].array.first ?? .null
        XCTAssertEqual(day["models"]["fixture-a"]["avgTps"], 50)
        XCTAssertEqual(day["models"]["fixture-b"]["avgTps"], 75)
        XCTAssertEqual(day["harnesses"]["antigravity"]["durationMs"], 6000)
    }

    func testInvalidOrMissingStreamPairsNeverBorrowLegacyResponseTimingOrOutput() {
        var invalid: [StatisticsUsage] = []
        for (index, duration) in ([nil, 0, -1, Double.infinity, Double.nan] as [Double?]).enumerated() {
            invalid.append(row("duration-\(index)", response: 1000, stream: duration))
        }
        for (index, output) in ([nil, 0, -1, Double.infinity, Double.nan] as [Double?]).enumerated() {
            invalid.append(row("output-\(index)", output: output ?? 10000, response: 1000, streamOutput: output))
        }
        invalid.append(row("mismatched", output: 9999))
        let missing = StatisticsFold.throughput(invalid, calendar: utc)["streaming"]["summary"]
        XCTAssertTrue(missing["avgTps"].isNull); XCTAssertEqual(missing["outputTokens"], 0); XCTAssertEqual(missing["durationMs"], 0)
        // A different numerator scope is not a matched generation. Only the
        // valid pair contributes; ineligible rows add neither side.
        let valid = row("valid")
        let summary = StatisticsFold.throughput([valid] + invalid, calendar: utc)["streaming"]["summary"]
        XCTAssertEqual(summary["avgTps"], 50); XCTAssertEqual(summary["outputTokens"], 100)
        XCTAssertEqual(summary["durationMs"], 2000); XCTAssertEqual(summary["timedResponses"], 1)
    }

    func testMissingOrWrongStreamingProvenanceIsIneligible() {
        var missing = row("missing-provenance"), wrong = row("wrong-provenance")
        missing.streamTiming = nil; wrong.streamTiming = "recorded"
        let rates = StatisticsFold.throughput([missing, wrong], calendar: utc)
        XCTAssertEqual(rates["summary"]["timedResponses"], 2)
        XCTAssertEqual(rates["summary"]["avgTps"].double, 100.0 / 12, accuracy: 0.000001)
        let streaming = rates["streaming"]["summary"]
        XCTAssertTrue(streaming["avgTps"].isNull); XCTAssertEqual(streaming["timedResponses"], 0)
        XCTAssertEqual(streaming["outputTokens"], 0); XCTAssertEqual(streaming["durationMs"], 0)
    }

    func testStreamingProvenanceMustBelongToItsSource() {
        var wrongSource = row("wrong-source"), wrongClock = row("wrong-clock")
        wrongSource.source = "codex"; wrongClock.streamTiming = "dsh-host-chunk-clock"
        let rates = StatisticsFold.throughput([wrongSource, wrongClock], calendar: utc)
        XCTAssertEqual(rates["summary"]["timedResponses"], 2)
        XCTAssertEqual(rates["summary"]["avgTps"].double, 100.0 / 12, accuracy: 0.000001)
        let streaming = rates["streaming"]["summary"]
        XCTAssertTrue(streaming["avgTps"].isNull); XCTAssertEqual(streaming["timedResponses"], 0)
        XCTAssertEqual(streaming["outputTokens"], 0); XCTAssertEqual(streaming["durationMs"], 0)
    }

    func testPositiveStreamingDurationWhoseRateOverflowsIsIneligible() {
        let tiny = Double.leastNonzeroMagnitude
        XCTAssertGreaterThan(tiny, 0); XCTAssertFalse((100 * 1000 / tiny).isFinite)
        let overflow = row("overflow", stream: tiny), valid = row("valid")
        let rates = StatisticsFold.throughput([overflow], calendar: utc)
        XCTAssertEqual(rates["summary"]["avgTps"].double, 100.0 / 12, accuracy: 0.000001)
        let rejected = rates["streaming"]["summary"]
        XCTAssertTrue(rejected["avgTps"].isNull); XCTAssertEqual(rejected["timedResponses"], 0)
        XCTAssertEqual(rejected["outputTokens"], 0); XCTAssertEqual(rejected["durationMs"], 0)
        for events in [[overflow, valid], [valid, overflow]] {
            let streaming = StatisticsFold.throughput(events, calendar: utc)["streaming"]["summary"]
            XCTAssertEqual(streaming["avgTps"], 50); XCTAssertEqual(streaming["timedResponses"], 1)
            XCTAssertEqual(streaming["outputTokens"], 100); XCTAssertEqual(streaming["durationMs"], 2000)
        }
    }
}
