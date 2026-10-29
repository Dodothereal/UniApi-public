import Foundation
import XCTest
@testable import UniApiCore

final class StatisticsFoldMutationTests: XCTestCase {
    private var now: Double { date("2026-10-15T12:00:00Z") }
    private var utc: Calendar { calendar("UTC") }

    func testRepeatedDayModelAndHarnessClocksKeepResponseAndStreamCounters() throws {
        var a = row("a", source: "codex", model: "alpha", output: 10)
        a.thinking = 2; a.durationMs = 1000; a.streamDurationMs = 400
        a.streamOutputTokens = 8; a.streamTiming = "uniapi-host-sse-clock"
        var b = row("b", source: "codex", model: "alpha", output: 20)
        b.durationMs = 2000; b.timing = "estimated"; b.streamDurationMs = 1000
        b.streamOutputTokens = 20; b.streamTiming = "uniapi-host-sse-clock"
        var c = row("c", source: "antigravity", model: "beta", output: 30)
        c.durationMs = 3000; c.streamDurationMs = 1500
        c.streamOutputTokens = 30; c.streamTiming = "antigravity-stream-duration"
        var d = row("d", source: "dsh", model: "alpha", stamp: "2026-10-11T12:00:00Z", output: 40)
        d.durationMs = 4000; d.streamDurationMs = 2000
        d.streamOutputTokens = 40; d.streamTiming = "dsh-host-chunk-clock"
        var mismatched = row("mismatch", source: "codex", model: "alpha", output: 50)
        mismatched.thinking = 5; mismatched.durationMs = 5000; mismatched.streamDurationMs = 1000
        mismatched.streamOutputTokens = 50; mismatched.streamTiming = "uniapi-host-sse-clock"
        let untimed = row("untimed", source: "codex", model: "alpha", output: 60)
        let throughput = StatisticsFold.derive([a, b, c, d, mismatched, untimed], range: 0, now: now, calendar: utc).throughput

        assertExact(throughput["summary"], speed(total: 6, timed: 5, output: 150, milliseconds: 15000, estimated: 1, average: 10))
        assertExact(throughput["streaming"]["summary"], speed(total: 6, timed: 4, output: 98, milliseconds: 4900, average: 20))
        let responseDay = try day(throughput["days"], "2026-10-10T00:00:00Z")
        let streamDay = try day(throughput["streaming"]["days"], "2026-10-10T00:00:00Z")
        let alphaResponse = speed(total: 4, timed: 3, output: 80, milliseconds: 8000, estimated: 1, average: 10)
        let alphaStream = speed(total: 4, timed: 2, output: 28, milliseconds: 1400, average: 20)
        assertExact(responseDay["models"]["alpha"], alphaResponse)
        assertExact(responseDay["harnesses"]["codex"], alphaResponse)
        assertExact(streamDay["models"]["alpha"], alphaStream)
        assertExact(streamDay["harnesses"]["codex"], alphaStream)
        assertExact(responseDay["models"]["beta"], speed(total: 1, timed: 1, output: 30, milliseconds: 3000, average: 10))
        assertExact(streamDay["harnesses"]["antigravity"], speed(total: 1, timed: 1, output: 30, milliseconds: 1500, average: 20))
        let next = try day(throughput["streaming"]["days"], "2026-10-11T00:00:00Z")
        assertExact(next["models"]["alpha"], speed(total: 1, timed: 1, output: 40, milliseconds: 2000, average: 20))
        XCTAssertEqual(throughput["days"].array.count, 2)
        XCTAssertEqual(throughput["streaming"]["days"].array.count, 2)
    }

    func testDailyTotalsKeepRepeatedModelsAndIndependentDayBuckets() {
        var a = row("a", model: "alpha", input: 1.25, output: 2.5)
        a.thinking = 0.5; a.cacheWrite = 0.25; a.cacheRead = 0.5; a.webSearch = 0.5; a.webFetch = 0.25
        var b = row("b", model: "alpha", input: 2.75, output: 1.5)
        b.thinking = 0.25; b.cacheWrite = 0.75; b.cacheRead = 1.5; b.webSearch = 0.25; b.webFetch = 0.5
        var c = row("c", model: "beta", input: 4, output: 8)
        c.thinking = 1; c.cacheRead = 2; c.webFetch = 1
        var d = row("d", model: "alpha", stamp: "2026-10-11T12:00:00Z", input: 10, output: 20)
        d.thinking = 2; d.cacheWrite = 1; d.cacheRead = 3; d.webSearch = 1; d.webFetch = 2
        let actual = JSONValue.array(StatisticsFold.derive([c, a, d, b], range: 0, now: now, calendar: utc).days)
        let alpha = totals(messages: 2, input: 4, output: 4, thinking: 0.75, write: 1, read: 2, search: 0.75, fetch: 0.75)
        let beta = totals(messages: 1, input: 4, output: 8, thinking: 1, read: 2, fetch: 1)
        let next = totals(messages: 1, input: 10, output: 20, thinking: 2, write: 1, read: 3, search: 1, fetch: 2)
        let expected: JSONValue = [
            ["day": .number(date("2026-10-10T00:00:00Z")),
             "totals": totals(messages: 3, input: 8, output: 12, thinking: 1.75, write: 1, read: 4, search: 0.75, fetch: 1.75),
             "perModel": ["alpha": alpha, "beta": beta]],
            ["day": .number(date("2026-10-11T00:00:00Z")), "totals": next, "perModel": ["alpha": next]]
        ]
        assertExact(actual, expected)
    }

    func testProjectSessionSetsRemainLocalAcrossRepeatedAndCrossProjectIDs() {
        let rows = [
            row("a1", model: "alpha", project: "fixture/a", session: "shared", input: 1, output: 2),
            row("a2", model: "beta", project: "fixture/a", session: "shared", input: 3, output: 4),
            row("a3", model: "alpha", project: "fixture/a", session: "unique-a", input: 5, output: 6),
            row("b1", model: "alpha", project: "fixture/b", session: "shared", input: 7, output: 8),
            row("b2", model: "beta", project: "fixture/b", session: "unique-b", input: 9, output: 10),
            row("b3", model: "beta", project: "fixture/b", session: "unique-b", input: 11, output: 12),
            row("empty1", model: "alpha", project: "", session: "", input: 13, output: 14),
            row("empty2", model: "beta", project: "", session: "", input: 15, output: 16)
        ]
        let board = StatisticsFold.derive(Array(rows.reversed()), range: 0, now: now, calendar: utc)
        let expected: JSONValue = [
            ["path": "", "name": "", "totals": totals(messages: 2, input: 28, output: 30), "sessions": 1],
            ["path": "fixture/b", "name": "b", "totals": totals(messages: 3, input: 27, output: 30), "sessions": 2],
            ["path": "fixture/a", "name": "a", "totals": totals(messages: 3, input: 9, output: 12), "sessions": 2]
        ]
        assertExact(.array(board.projects), expected)
        XCTAssertEqual(board.summary.sessions, 4, "The shared ID belongs to both project sets but only one global session")
        XCTAssertEqual(board.summary.projects, 3)
    }

    func testFrozenCopyingContainersMatchWholeBoardsAcrossOrderRangeAndLifetime() {
        let events = generatedRows()
        let orders = [events, Array(events.reversed())]
        for zone in ["UTC", "America/New_York"] {
            let selectedCalendar = calendar(zone)
            for rows in orders {
                for range in [0, 7, 30] {
                    for cache in [nil, lifetimeCache("2026-10-10"), lifetimeCache("2026-02-30")] {
                        for source in ["all", "claude", "codex"] {
                            let actual = StatisticsFold.sources(rows, range: range, cache: cache, source: source, now: now, calendar: selectedCalendar).json
                            let old = StatisticsCopyingContainersOracle.sources(rows, range: range, cache: cache, source: source, now: now, calendar: selectedCalendar).json
                            assertExact(actual, old, label: "\(zone)/\(range)/\(source)/\(cache?.computedOn ?? "no cache")")
                        }
                    }
                }
            }
        }
    }

    private func assertExact(_ actual: JSONValue, _ expected: JSONValue, label: String = "manual expectation",
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
    private func day(_ days: JSONValue, _ stamp: String) throws -> JSONValue {
        try XCTUnwrap(days.array.first { $0["day"].double == date(stamp) })
    }
    private func totals(messages: Double, input: Double, output: Double, thinking: Double = 0,
                        write: Double = 0, read: Double = 0, search: Double = 0, fetch: Double = 0) -> JSONValue {
        ["messages": .number(messages), "input": .number(input), "output": .number(output), "thinking": .number(thinking),
         "cacheWrite": .number(write), "cacheRead": .number(read), "webSearch": .number(search), "webFetch": .number(fetch)]
    }
    private func speed(total: Int, timed: Int, output: Double, milliseconds: Double,
                       estimated: Int = 0, average: Double) -> JSONValue {
        ["totalResponses": .number(Double(total)), "timedResponses": .number(Double(timed)), "outputTokens": .number(output),
         "durationMs": .number(milliseconds), "estimatedResponses": .number(Double(estimated)), "avgTps": .number(average)]
    }
    private func calendar(_ zone: String) -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: zone)!
        return calendar
    }
    private func date(_ stamp: String) -> Double { statisticsTimestamp(.string(stamp))! }
    private func row(_ id: String, source: String = "claude", model: String, stamp: String = "2026-10-10T12:00:00Z",
                     project: String = "fixture/project", session: String = "fixture/session",
                     input: Double = 0, output: Double = 0) -> StatisticsUsage {
        var row = StatisticsUsage(id: id, source: source, ts: date(stamp), model: model)
        row.project = project; row.session = session; row.input = input; row.output = output
        return row
    }
    private func generatedRows() -> [StatisticsUsage] {
        let sources = StatisticsSource.allCases.map(\.rawValue) + ["future-harness"]
        let offsets = [0, 1, 6, 7, 15, 29, 30, 40]
        let values = [0.1, 0.2, 1.0 / 3.0, 17.125, 9_007_199_254_740_992.0]
        return (0..<35).map { index in
            var event = row("matrix-\(index)", source: sources[index % sources.count], model: "fixture/model-\(index % 11)",
                            project: "fixture/project-\(index % 3)", session: "session-\(index % 5)",
                            input: values[index % values.count], output: Double(index % 9 + 1))
            event.ts = date("2026-10-15T00:00:00Z") - Double(offsets[index % offsets.count]) * 86_400_000 + Double(index % 3) * 43_199_999.5
            event.thinking = event.output / 4; event.cacheWrite = Double(index % 4) / 8; event.cacheRead = Double(index % 3) / 4
            event.webSearch = Double(index % 2) / 2; event.webFetch = Double(index % 3) / 8
            event.durationMs = index % 4 == 0 ? nil : Double(index + 1) * 125.125
            event.timing = index % 2 == 0 ? "estimated" : "recorded"
            event.streamDurationMs = Double(index + 1) * 50.125
            event.streamOutputTokens = event.source == "codex" ? event.output - event.thinking : event.output
            event.streamTiming = ["codex": "uniapi-host-sse-clock", "antigravity": "antigravity-stream-duration", "dsh": "dsh-host-chunk-clock"][event.source]
            if index % 5 == 0 { event.streamOutputTokens = nil }
            return event
        }
    }
    private func lifetimeCache(_ watermark: String) -> StatisticsCache {
        var cache = StatisticsCache()
        cache.computedOn = watermark; cache.messages = 40; cache.sessions = 7; cache.activeDays = 5
        cache.totals.input = 1000.25; cache.totals.output = 200.5; cache.totals.cacheRead = 50.125
        cache.firstDay = "2026-09-01"; cache.lastDay = "2026-10-10"; cache.daily = ["2026-09-01": 1000.25]
        var observed = StatisticsTotals(); observed.input = 600.25
        var pruned = StatisticsTotals(); pruned.input = 400
        cache.perModel = ["fixture/model-0": observed, "fixture/cache-only": pruned]
        return cache
    }
}

// The three copying blocks are frozen from fold SHA-256
// fba583686287bd59229724513a345a9cf5dfc57ad2e96da89b1f998b8462009f.
// Unchanged summary/model/lifetime projections use their production helpers;
// none of those helpers enters the three containers compared here.
private enum StatisticsCopyingContainersOracle {
    private static func throughputBoard(_ events: [StatisticsUsage], calendar: Calendar, streaming: Bool) -> JSONValue {
        var all = StatisticsSpeed(), models: [String: StatisticsSpeed] = [:], pairs: [String: (String, String, StatisticsSpeed)] = [:]
        var harnesses = Dictionary(uniqueKeysWithValues: StatisticsSource.allCases.map { ($0.rawValue, StatisticsSpeed()) })
        var days: [Double: (models: [String: StatisticsSpeed], harnesses: [String: StatisticsSpeed])] = [:]
        var dates = StatisticsCalendarCursor(calendar: calendar)
        for e in events {
            all.add(e, streaming: streaming); models[e.model, default: StatisticsSpeed()].add(e, streaming: streaming); harnesses[e.source, default: StatisticsSpeed()].add(e, streaming: streaming)
            let key = e.source + "\u{0}" + e.model; var p = pairs[key] ?? (e.source, e.model, StatisticsSpeed()); p.2.add(e, streaming: streaming); pairs[key] = p
            let day = dates.day(e.ts); var d = days[day] ?? ([:], [:]); d.models[e.model, default: StatisticsSpeed()].add(e, streaming: streaming); d.harnesses[e.source, default: StatisticsSpeed()].add(e, streaming: streaming); days[day] = d
        }
        func decorated(_ s: StatisticsSpeed, _ fields: JSONObject) -> JSONValue { .object(s.json.object.merging(fields) { _, new in new }) }
        return ["basis": .string(streaming ? "streaming" : "response"), "summary": all.json, "models": .array(models.keys.sorted().map { decorated(models[$0]!, ["model": .string($0)]) }), "harnesses": .array(StatisticsSource.allCases.map { decorated(harnesses[$0.rawValue]!, ["source": .string($0.rawValue)]) }), "pairs": .array(pairs.keys.sorted().map { let p = pairs[$0]!; return decorated(p.2, ["source": .string(p.0), "model": .string(p.1)]) }), "days": .array(days.keys.sorted().map { ["day": .number($0), "models": .object(days[$0]!.models.mapValues(\.json)), "harnesses": .object(days[$0]!.harnesses.mapValues(\.json))] })]
    }
    private static func derive(_ events: [StatisticsUsage], range: Int, cache: StatisticsCache? = nil, now: Double, calendar: Calendar) -> StatisticsDerived {
        let evs = StatisticsFold.filtered(events, range: range, now: now, calendar: calendar)
        var d = StatisticsDerived(); d.summary = StatisticsFold.summary(evs, calendar: calendar); d.models = StatisticsFold.models(evs, calendar: calendar); d.events = evs.count; d.onDiskGrand = d.summary.totals.grand
        d.stackModels = Array(d.models.prefix(8).map(\.model)); d.stackDropped = max(0, d.models.count - 8)
        d.throughput = throughputBoard(evs, calendar: calendar, streaming: false)
        d.throughput["streaming"] = throughputBoard(evs, calendar: calendar, streaming: true)
        var daily: [Double: (StatisticsTotals, [String: StatisticsTotals])] = [:]
        var projects: [String: (StatisticsTotals, Set<String>)] = [:]
        var dates = StatisticsCalendarCursor(calendar: calendar)
        for e in evs {
            let day = dates.day(e.ts); var bucket = daily[day] ?? (StatisticsTotals(), [:]); bucket.0.add(e); bucket.1[e.model, default: StatisticsTotals()].add(e); daily[day] = bucket
            var p = projects[e.project] ?? (StatisticsTotals(), []); p.0.add(e); p.1.insert(e.session); projects[e.project] = p
            let c = calendar.dateComponents([.weekday, .hour], from: Date(timeIntervalSince1970: e.ts / 1000)); d.heat[((c.weekday ?? 1) + 5) % 7][min(23, max(0, c.hour ?? 0))] += 1
        }
        d.days = daily.keys.sorted().map { ["day": .number($0), "totals": daily[$0]!.0.json, "perModel": .object(daily[$0]!.1.mapValues(\.json))] }
        d.projects = projects.keys.sorted { projects[$0]!.0.grand == projects[$1]!.0.grand ? $0 < $1 : projects[$0]!.0.grand > projects[$1]!.0.grand }.map { ["path": .string($0), "name": .string($0.split(separator: "/").last.map(String.init) ?? $0), "totals": projects[$0]!.0.json, "sessions": .number(Double(projects[$0]!.1.count))] }
        if range == 0, let cache { StatisticsFold.lifetime(&d, events: evs, cache: cache, calendar: calendar) }
        return d
    }
    private static func summaryAndModels(_ events: [StatisticsUsage], cache: StatisticsCache? = nil, calendar: Calendar) -> (summary: StatisticsSummary, models: [StatisticsModel]) {
        var board = StatisticsDerived()
        board.summary = StatisticsFold.summary(events, calendar: calendar)
        board.models = StatisticsFold.models(events, calendar: calendar)
        if let cache { StatisticsFold.lifetime(&board, events: events, cache: cache, calendar: calendar) }
        return (board.summary, board.models)
    }
    static func sources(_ events: [StatisticsUsage], range: Int, cache: StatisticsCache?, source: String, now: Double, calendar: Calendar) -> StatisticsDerived {
        if source == "claude" { return derive(events.filter { $0.source == "claude" }, range: range, cache: cache, now: now, calendar: calendar) }
        if source != "all" { return derive(events.filter { $0.source == source }, range: range, now: now, calendar: calendar) }
        var d = derive(events, range: range, now: now, calendar: calendar)
        guard range == 0, let cache else { return d }
        let claude = summaryAndModels(events.filter { $0.source == "claude" }, cache: cache, calendar: calendar)
        let others = summaryAndModels(events.filter { $0.source != "claude" }, calendar: calendar)
        d.isLifetime = true; d.summary.totals = claude.summary.totals; d.summary.totals.add(others.summary.totals); d.summary.sessions = claude.summary.sessions + others.summary.sessions
        var days = Set(d.days.map { $0["day"].double }); for key in cache.daily.keys { if let day = statisticsDate(key, calendar: calendar) { days.insert(day) } }; d.summary.activeDays = max(claude.summary.activeDays, days.count)
        d.summary.first = [claude.summary.first, others.summary.first].compactMap { $0 }.min(); d.summary.last = [claude.summary.last, others.summary.last].compactMap { $0 }.max()
        let raw = Dictionary(uniqueKeysWithValues: d.models.map { ($0.model, $0) }); var rows = Dictionary(uniqueKeysWithValues: claude.models.map { ($0.model, $0) })
        for other in others.models {
            if var m = rows[other.model] { m.totals.add(other.totals); m.days = raw[other.model]?.days ?? 0; m.sessions += other.sessions; m.first = raw[other.model]?.first; m.last = raw[other.model]?.last; m.pruned = false; rows[other.model] = m }
            else { rows[other.model] = other }
        }
        d.models = rows.values.sorted { $0.totals.grand == $1.totals.grand ? $0.model < $1.model : $0.totals.grand > $1.totals.grand }; d.summary.models = rows.count; StatisticsFold.addUntimedModels(&d)
        return d
    }
}
