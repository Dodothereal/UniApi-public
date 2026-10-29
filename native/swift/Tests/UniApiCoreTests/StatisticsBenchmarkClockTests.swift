import Foundation
import XCTest
@testable import UniApiCore

final class StatisticsBenchmarkClockTests: XCTestCase {
    private typealias ClockValues = (timestamp: Double?, latencyMs: Double?)
    private let model = "fixture/benchmark-clock"
    private var now: Double { statisticsTimestamp("2026-10-15T12:00:00Z")! }
    private var utc: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }

    func testAllTimeIneligibleRowsNeverCallProductionParser() {
        for (label, row) in ineligibleRows() {
            var inputs: [JSONValue] = []
            let clock = StatisticsBenchmarkClock(row, range: 0, parse: { inputs.append($0); return 123.125 })
            XCTAssertTrue(inputs.isEmpty, label)
            XCTAssertNil(clock.timestamp, label)
            XCTAssertNil(clock.latencyMs, label)
        }
    }

    func testEligibleLatencyParsesOnceIncludingZeroNegativeAndNumericRunID() {
        for milliseconds in [0.0, -0.0, -12.5, 123.125] {
            var row = benchRow("eligible")
            row["timing_ms"] = ["ttft": .number(milliseconds)]
            row["tokens"] = [:]
            row["run_id"] = 0
            var inputs: [JSONValue] = []
            let clock = StatisticsBenchmarkClock(row, range: 0, parse: { inputs.append($0); return 123.125 })
            XCTAssertEqual(inputs, [row["ts"]])
            XCTAssertEqual(clock.timestamp?.bitPattern, 123.125.bitPattern)
            XCTAssertEqual(clock.latencyMs?.bitPattern, milliseconds.bitPattern)
        }
        var calls = 0
        let invalid = StatisticsBenchmarkClock(benchRow("invalid-date"), range: 0, parse: { _ in calls += 1; return nil })
        XCTAssertEqual(calls, 1)
        XCTAssertNil(invalid.timestamp)
        XCTAssertEqual(invalid.latencyMs, 100)
    }

    func testPositiveRangesParseEveryEligibilityClassOnceEvenWhenDateIsInvalid() {
        let cases = ineligibleRows() + [("eligible", benchRow("eligible"))]
        let parsedValues: [Double?] = [nil, 123.125]
        for range in [1, 7, 30, 90, 365] {
            for (label, row) in cases {
                for parsed in parsedValues {
                    var inputs: [JSONValue] = []
                    let clock = StatisticsBenchmarkClock(row, range: range, parse: { inputs.append($0); return parsed })
                    XCTAssertEqual(inputs, [row["ts"]], "\(label)/\(range)")
                    XCTAssertEqual(clock.timestamp?.bitPattern, parsed?.bitPattern)
                    XCTAssertEqual(clock.latencyMs?.bitPattern, legacyClock(row).latencyMs?.bitPattern)
                }
            }
        }
    }

    func testRealTimestampFormsAndEligibilityMatchLegacyClockBitPatterns() {
        let forms: [JSONValue] = [
            "2026-10-15T12:34:56Z", "2026-10-15T12:34:56.123Z",
            "2026-10-15T12:34:56.123456+02:00", "2026-10-15T12:34:56-07:00",
            "2026-10-15", "2026-02-30T12:00:00Z", "not-a-date", "", .null,
            .number(1792065600000), true, ["nested"], ["nested": "timestamp"]
        ]
        for stamp in forms {
            for eligible in [true, false] {
                var row = benchRow("forms")
                row["ts"] = stamp
                if !eligible { row["ok"] = false }
                let old = legacyClock(row)
                for range in [0, 7] {
                    let current = StatisticsBenchmarkClock(row, range: range)
                    let needed = range > 0 || old.latencyMs != nil
                    XCTAssertEqual(current.timestamp?.bitPattern, needed ? old.timestamp?.bitPattern : nil)
                    XCTAssertEqual(current.latencyMs?.bitPattern, old.latencyMs?.bitPattern)
                }
            }
        }
    }

    func testAllTimeServiceKeepsInvalidDateSpendRawFirstLastAndZeroTokenTrend() async throws {
        let fixture = try await fixture()
        var invalid = benchRow("invalid", stamp: "zzz-invalid")
        invalid["test"] = "throughput"
        var zero = benchRow("zero", stamp: "2026-10-12T12:00:00Z")
        zero["tokens"] = [:]; zero["timing_ms"] = ["ttft": 0]
        var failed = benchRow("failed", stamp: "2026-10-13T12:00:00Z")
        failed["ok"] = false; failed["timing_ms"] = ["ttft": 999]
        var negative = benchRow("negative", stamp: "2026-10-14T12:00:00Z")
        negative["timing_ms"] = ["ttft": -20]
        var badLatencyDate = benchRow("bad-latency-date", stamp: "000-invalid")
        badLatencyDate["timing_ms"] = ["ttft": 500]
        let rows = [invalid, zero, failed, negative, badLatencyDate]
        try write(rows, to: fixture.ledger)
        let actual = try await fixture.service.handle("bench")
        assertExact(actual, legacyFold(ordered(rows)), label: "all-time service")
        XCTAssertEqual(actual["spend"]["calls"], 4)
        XCTAssertEqual(actual["spend"]["first"], "000-invalid")
        XCTAssertEqual(actual["spend"]["last"], "zzz-invalid")
        let point = try XCTUnwrap(actual["trend"].array.first)
        XCTAssertEqual(actual["trend"].array.count, 1)
        XCTAssertEqual(point["samples"], 2)
        XCTAssertEqual(point["ms"], -10)
    }

    func testRangedModelServiceKeepsCutoffBoundaryFailureSpendAndMedian() async throws {
        let fixture = try await fixture()
        let before = benchRow("before", stamp: "2026-10-08T23:59:59.999Z")
        let boundary = benchRow("boundary", stamp: "2026-10-09T00:00:00Z")
        var after = benchRow("after", stamp: "2026-10-10T00:00:00.123456+00:00")
        after["timing_ms"] = ["ttft": 300]
        var failed = benchRow("failed", stamp: "2026-10-11T00:00:00Z")
        failed["ok"] = false; failed["timing_ms"] = ["ttft": 900]
        let invalid = benchRow("invalid", stamp: "zzz-invalid")
        var other = benchRow("other", stamp: "2026-10-12T00:00:00Z")
        other["model"] = "fixture/other-model"
        var noProvider = benchRow("no-provider")
        noProvider["provider"] = ""
        var target = benchRow("target", stamp: "2026-10-12T00:00:00Z")
        target["model"] = ""; target["target"] = .string(model); target["test"] = "throughput"
        let rows = [before, boundary, after, failed, invalid, other, noProvider, target]
        try write(rows, to: fixture.ledger)
        for range in [0, 7, 30] {
            let response = try await fixture.service.handle("model", input: ["model": .string(model), "source": "all", "range": .number(Double(range))])
            assertExact(response["bench"], legacyFold(ordered(rows), model: model, range: range), label: "range \(range)")
            if range == 7 {
                XCTAssertEqual(response["bench"]["spend"]["calls"], 4)
                XCTAssertEqual(response["bench"]["spend"]["first"], boundary["ts"])
                XCTAssertEqual(response["bench"]["trend"].array.first?["ms"], 200)
                XCTAssertEqual(response["bench"]["trend"].array.first?["samples"], 2)
            }
        }
    }

    func testServiceRetainsFullRowAdmissionIDLessHashAndLedgerPrecedence() async throws {
        let fixture = try await fixture()
        var first = benchRow(nil)
        first["arrival"] = [1, 2]
        var second = first; second["arrival"] = [1, 3]
        let identified = benchRow("identified")
        var duplicate = identified; duplicate["tokens"] = ["in": 999, "out": 999]
        let tail = benchRow("tail")
        let overflow = Data("{\"id\":\"overflow\",\"provider\":\"fixture\",\"model\":\"fixture/benchmark-clock\",\"tokens\":{\"in\":999},\"arrival\":[1e999]}".utf8)
        var invalidUTF8 = Data("{\"id\":\"invalid-utf8\",\"provider\":\"fixture\",\"model\":\"fixture/benchmark-clock\",\"tokens\":{\"in\":999},\"headers\":{\"ignored\":\"".utf8)
        invalidUTF8.append(0xff); invalidUTF8.append(contentsOf: Data("\"}}".utf8))
        XCTAssertThrowsError(try JSONValue.decode(overflow))
        XCTAssertThrowsError(try JSONValue.decode(invalidUTF8))
        var bytes = try lines([first, second, identified])
        bytes.append(overflow); bytes.append(10)
        bytes.append(invalidUTF8); bytes.append(10)
        bytes.append(try lines([tail]))
        try NativeFile.writeAtomic(bytes, to: fixture.ledger)
        var mirror = Data(" \t".utf8)
        mirror.append(try first.encoded()); mirror.append(contentsOf: Data(" \r\n".utf8))
        mirror.append(try lines([duplicate]))
        try NativeFile.writeAtomic(mirror, to: fixture.runtime.paths.bench.appendingPathComponent("results/results.jsonl"))
        let actual = try await fixture.service.handle("bench")
        assertExact(actual, legacyFold(ordered([first, second, identified, tail])), label: "full admission and canonical dedup")
        XCTAssertEqual(actual["spend"]["calls"], 4, "Different ID-less ignored fields stay distinct; the mirror and repeated ID do not")
        XCTAssertEqual(actual["spend"]["input"], 40)
    }

    func testThousandRowOffsetClockControlPreservesCompleteFoldFields() {
        let rows = ordered((0..<1000).map { index in
            let stamp = String(format: "2026-10-15T12:%02d:%02d.123456+02:00", index / 60, index % 60)
            var row = benchRow("clock-control-\(index)", stamp: stamp)
            if index % 10 != 0 { row["test"] = "throughput" }
            row["timing_ms"] = ["ttft": .number(Double(index % 13))]
            return row
        })
        XCTAssertEqual(rows.count, 1000)
        XCTAssertNotNil(statisticsTimestamp(rows[0]["ts"]))
        var oldMs: [Double] = [], newMs: [Double] = []
        for trial in 0..<3 {
            let old: (value: [ClockValues], milliseconds: Double)
            let new: (value: [ClockValues], milliseconds: Double)
            if trial % 2 == 0 {
                old = measured { rows.map { legacyClock($0) } }
                new = measured { rows.map { row in let c = StatisticsBenchmarkClock(row, range: 0); return (c.timestamp, c.latencyMs) } }
            } else {
                new = measured { rows.map { row in let c = StatisticsBenchmarkClock(row, range: 0); return (c.timestamp, c.latencyMs) } }
                old = measured { rows.map { legacyClock($0) } }
            }
            oldMs.append(old.milliseconds); newMs.append(new.milliseconds)
            // Only timestamp/eligibility construction is timed. The same full
            // legacy spend/trend fold consumes each result outside the timer.
            assertExact(legacyFold(rows, clocks: new.value), legacyFold(rows, clocks: old.value), label: "1000-row clock trial \(trial)")
        }
        print("Statistics benchmark clock: 1000 synthetic rows, six-digit offset timestamps, single-process ABBAAB median3 elapsed eager \(oldMs.sorted()[1]) ms, eligible-only \(newMs.sorted()[1]) ms; timestamp component only, no CPU/app claim")
    }

    private func legacyClock(_ row: JSONValue) -> ClockValues {
        let at = statisticsTimestamp(row["ts"])
        if row["test"].string == "latency", row["ok"].bool, !row["run_id"].string.isEmpty,
           case .number(let ms) = row["timing_ms"]["ttft"], ms.isFinite { return (at, ms) }
        return (at, nil)
    }

    // Original benchmark accumulation and output construction. Supplying clocks
    // is only for comparing the two measured clock components on identical rows.
    private func legacyFold(_ rows: [JSONValue], model: String? = nil, range: Int = 0,
                            clocks: [ClockValues]? = nil) -> JSONValue {
        let cutoff = statisticsDay(now, calendar: utc) - Double(range - 1) * 86_400_000
        var totals: [String: Double] = ["input": 0, "output": 0, "reasoning": 0, "cached": 0, "calls": 0, "estimated": 0]
        var pairs: [String: JSONValue] = [:], runs = Set<String>(), first: String?, last: String?
        var trend: [String: (ts: Double, label: String, key: String, run: String, ms: [Double])] = [:]
        for (index, r) in rows.enumerated() {
            let clock = clocks?[index] ?? legacyClock(r), at = clock.timestamp
            if range > 0 && (at == nil || at! < cutoff) { continue }
            let provider = r["provider"].string, name = r["model"].string.isEmpty ? r["target"].string : r["model"].string
            if provider.isEmpty || name.isEmpty || (model != nil && model != name) { continue }
            let key = provider + "|" + name, tok = r["tokens"], input = statisticsNumber(tok["in"]), output = statisticsNumber(tok["out"])
            if input > 0 || output > 0 {
                var p = pairs[key] ?? ["key": .string(key), "provider": .string(provider), "providerName": .string(r["provider_name"].string.isEmpty ? provider : r["provider_name"].string), "model": .string(name)]
                let values: [String: Double] = ["input": input, "output": output, "reasoning": statisticsNumber(tok["reasoning"]), "cached": statisticsNumber(tok["cached"]), "calls": 1, "estimated": tok["in_est"].bool || tok["out_est"].bool ? 1 : 0]
                for (field, value) in values { totals[field, default: 0] += value; p[field] = .number(p[field].double + value) }; pairs[key] = p
                if !r["run_id"].string.isEmpty { runs.insert(r["run_id"].string) }
                let stamp = r["ts"].string; if !stamp.isEmpty { first = min(first ?? stamp, stamp); last = max(last ?? stamp, stamp) }
            }
            if let ms = clock.latencyMs, let at {
                let run = r["run_id"].string, group = key + "@" + run
                var bucket = trend[group] ?? (at, "\(name.split(separator: "/").last ?? Substring(name)) · \(r["provider_name"].string.isEmpty ? provider : r["provider_name"].string)", key, run, [])
                bucket.ts = min(bucket.ts, at); bucket.ms.append(ms); trend[group] = bucket
            }
        }
        var spend = JSONValue.object(totals.mapValues(JSONValue.number)); spend["runs"] = .number(Double(runs.count)); spend["first"] = first.map(JSONValue.string) ?? .null; spend["last"] = last.map(JSONValue.string) ?? .null
        spend["pairs"] = .array(pairs.values.sorted { $0["input"].double + $0["output"].double > $1["input"].double + $1["output"].double })
        let points: [JSONValue] = trend.values.map { b in let sorted = b.ms.sorted(), n = sorted.count; let median = n % 2 == 0 ? (sorted[n / 2 - 1] + sorted[n / 2]) / 2 : sorted[n / 2]; return ["runId": .string(b.run), "key": .string(b.key), "label": .string(b.label), "at": .number(b.ts), "ms": .number(median), "samples": .number(Double(n))] }.sorted { $0["at"].double == $1["at"].double ? $0["key"].string < $1["key"].string : $0["at"].double < $1["at"].double }
        return ["spend": spend, "trend": .array(points)]
    }

    private func ineligibleRows() -> [(String, JSONValue)] {
        let fields: [(String, String, JSONValue)] = [
            ("non-latency", "test", "throughput"), ("failed", "ok", false), ("numeric ok", "ok", 1),
            ("empty run", "run_id", ""), ("null run", "run_id", .null), ("missing latency", "timing_ms", [:]),
            ("string latency", "timing_ms", ["ttft": "100"]), ("Boolean latency", "timing_ms", ["ttft": true]),
            ("NaN", "timing_ms", ["ttft": .number(.nan)]), ("infinity", "timing_ms", ["ttft": .number(.infinity)]),
            ("negative infinity", "timing_ms", ["ttft": .number(-.infinity)])
        ]
        return fields.map { label, key, value in var row = benchRow(label); row[key] = value; return (label, row) }
    }

    private func benchRow(_ id: String?, stamp: String = "2026-10-15T12:00:00.123456+02:00") -> JSONValue {
        var value: JSONValue = ["provider": "fixture", "provider_name": "Fixture", "model": .string(model), "run_id": "run",
                               "ts": .string(stamp), "ok": true, "test": "latency", "timing_ms": ["ttft": 100],
                               "tokens": ["in": 10, "out": 20, "reasoning": 3, "cached": 2, "in_est": true]]
        if let id { value["id"] = .string(id) }
        return value
    }

    private func ordered(_ rows: [JSONValue]) -> [JSONValue] { rows.sorted { $0["ts"].string < $1["ts"].string } }

    private func assertExact(_ actual: JSONValue, _ expected: JSONValue, label: String,
                             file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(actual, expected, label, file: file, line: line)
        XCTAssertEqual(numberBits(actual), numberBits(expected), label + " numeric bits", file: file, line: line)
    }

    private func numberBits(_ value: JSONValue) -> [String: UInt64] {
        var result: [String: UInt64] = [:]
        func visit(_ value: JSONValue, path: String) {
            switch value {
            case .number(let number): result[path] = number.bitPattern
            case .array(let values):
                for (index, value) in values.enumerated() { visit(value, path: path + "/\(index)") }
            case .object(let values):
                for (key, value) in values { visit(value, path: path + "/" + key.replacingOccurrences(of: "~", with: "~0").replacingOccurrences(of: "/", with: "~1")) }
            default: break
            }
        }
        visit(value, path: "")
        return result
    }

    private func measured<Value>(_ body: () -> Value) -> (value: Value, milliseconds: Double) {
        let begin = ProcessInfo.processInfo.systemUptime
        let value = body()
        return (value, (ProcessInfo.processInfo.systemUptime - begin) * 1000)
    }

    private struct Fixture { let runtime: NativeRuntime, service: NativeStatisticsService, ledger: URL }
    private func fixture() async throws -> Fixture {
        let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
            .appendingPathComponent("statistics-benchmark-clock-" + UUID().uuidString)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        try NativeFile.writeAtomic(try JSONValue.object(["providers": []]).encoded(), to: root.appendingPathComponent("providers.example.json"))
        let paths = NativePaths(root: root, home: root.appendingPathComponent("home"))
        let source: JSONValue = ["type": "assistant", "timestamp": "2026-10-15T10:00:00Z", "sessionId": "fixture", "cwd": "fixture/project",
                                 "message": ["id": "usage", "model": .string(model), "usage": ["input_tokens": 10, "output_tokens": 2]]]
        try write([source], to: paths.home.appendingPathComponent(".claude/projects/fixture/usage.jsonl"))
        let runtime = try NativeRuntime(paths: paths)
        await runtime.jobs.suspendForShutdown()
        let fixedNow = now
        let service = NativeStatisticsService(runtime: runtime, environment: [:], calendar: utc, clock: { fixedNow })
        return Fixture(runtime: runtime, service: service, ledger: paths.data.appendingPathComponent("results.jsonl"))
    }

    private func lines(_ rows: [JSONValue]) throws -> Data {
        Data(try (rows.map { String(decoding: try $0.encoded(), as: UTF8.self) }.joined(separator: "\n") + "\n").utf8)
    }
    private func write(_ rows: [JSONValue], to url: URL) throws { try NativeFile.writeAtomic(try lines(rows), to: url) }
}
