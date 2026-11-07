import XCTest
import Foundation
@testable import UniApiCore

/// The old Foundation formatter and literal pre-cursor watermark formulas are
/// the oracles. No timestamp tolerances, local stores or performance cutoffs.
final class StatisticsUTCDayKeyTests: XCTestCase {
    private func calendar(_ zone: String = "UTC") -> Calendar {
        var value = Calendar(identifier: .gregorian); value.timeZone = TimeZone(identifier: zone)!
        return value
    }
    private func timestamp(_ year: Int, _ month: Int, _ day: Int) throws -> Double {
        let date = try XCTUnwrap(calendar().date(from: DateComponents(year: year, month: month, day: day)))
        return date.timeIntervalSince1970 * 1000
    }
    private func assertKey(_ value: Double, cursor: inout StatisticsUTCDayKeyCursor,
                           file: StaticString = #filePath, line: UInt = #line) {
        let expected = statisticsUTC(value), actual = cursor.key(value)
        XCTAssertEqual(actual, expected, "timestamp bits \(value.bitPattern)", file: file, line: line)
        XCTAssertEqual(Array(actual.utf8), Array(expected.utf8), file: file, line: line)
    }
    private func numberBits(_ value: JSONValue) -> [UInt64] {
        switch value {
        case .number(let n): return [n.bitPattern]
        case .array(let values): return values.flatMap { numberBits($0) }
        case .object(let values): return values.keys.sorted().flatMap { numberBits(values[$0]!) }
        default: return []
        }
    }
    private func assertJSON(_ actual: JSONValue, _ expected: JSONValue,
                            file: StaticString = #filePath, line: UInt = #line) throws {
        XCTAssertEqual(actual, expected, file: file, line: line)
        XCTAssertEqual(numberBits(actual), numberBits(expected), file: file, line: line)
        XCTAssertEqual(try actual.encoded(), try expected.encoded(), file: file, line: line)
    }

    func testFiveThousandFractionalTimestampsMatchOldUTF8DayKeys() throws {
        let base = try timestamp(2024, 2, 1)
        var cursor = StatisticsUTCDayKeyCursor()
        for i in 0..<5_000 {
            let fraction = Double(i % 1023 + 1) / 1024
            let value = base + Double(i / 80) * 86_400_000 + Double(i % 80) * 1_000_000 + fraction
            XCTAssertNotEqual(value, value.rounded(.towardZero))
            assertKey(value, cursor: &cursor)
        }
    }

    func testUTCMidnightAdjacentDoublesRespectFoundationDateAndExclusiveEnd() throws {
        for (year, month, day) in [(1970, 1, 2), (2001, 1, 1), (2024, 2, 29), (2026, 10, 29)] {
            let boundary = try timestamp(year, month, day), next = boundary + 86_400_000
            var cursor = StatisticsUTCDayKeyCursor()
            for value in [boundary - 1000, boundary.nextDown, boundary, boundary.nextUp,
                          next.nextDown, next, next.nextUp, boundary.nextDown, boundary, next] {
                // Date(timestamp / 1000) can round a neighboring Double onto
                // midnight. The unchanged oracle decides that case exactly.
                assertKey(value, cursor: &cursor)
            }
            XCTAssertEqual(cursor.key(boundary), statisticsUTC(boundary))
            XCTAssertEqual(cursor.key(next), statisticsUTC(next))
            XCTAssertNotEqual(cursor.key(boundary), cursor.key(next))
        }
    }

    func testLeapYearsAndGregorianCenturyRulesRetainLiteralDayStrings() throws {
        let cases: [(Int, [(Int, Int, String)])] = [
            (1900, [(2, 28, "1900-02-28"), (3, 1, "1900-03-01")]),
            (2000, [(2, 28, "2000-02-28"), (2, 29, "2000-02-29"), (3, 1, "2000-03-01")]),
            (2024, [(2, 28, "2024-02-28"), (2, 29, "2024-02-29"), (3, 1, "2024-03-01")]),
            (2100, [(2, 28, "2100-02-28"), (3, 1, "2100-03-01")]),
            (2400, [(2, 28, "2400-02-28"), (2, 29, "2400-02-29"), (3, 1, "2400-03-01")])]
        for (year, days) in cases {
            var cursor = StatisticsUTCDayKeyCursor(), previous: Double?
            for (month, day, key) in days {
                let value = try timestamp(year, month, day)
                if let previous { XCTAssertEqual(value - previous, 86_400_000) }
                assertKey(value, cursor: &cursor)
                XCTAssertEqual(Array(cursor.key(value).utf8), Array(key.utf8))
                assertKey((value + 86_400_000).nextDown, cursor: &cursor)
                previous = value
            }
        }
    }

    func testSortedBackwardAlternatingDatesAndIndependentCursorsDoNotLeakState() throws {
        let first = try timestamp(2024, 2, 28), last = try timestamp(2026, 10, 29)
        let sorted = [first, first + 0.5, first + 86_400_000, first + 172_800_000, last, last + 43_200_000]
        for values in [sorted, Array(sorted.reversed()), [first, last, first + 1, last + 1, first, last]] {
            var a = StatisticsUTCDayKeyCursor(), b = StatisticsUTCDayKeyCursor()
            for (i, value) in values.enumerated() {
                let other = values[values.count - i - 1]
                assertKey(value, cursor: &a); assertKey(other, cursor: &b)
                assertKey(value, cursor: &a)
                if statisticsUTC(value) != statisticsUTC(other) { XCTAssertNotEqual(a.key(value), b.key(other)) }
            }
        }
    }

    func testFiniteFallbackOutliersKeepOldStringsAndLexicalWatermarkBehavior() throws {
        let modern = try timestamp(2026, 10, 29), future = try timestamp(10000, 1, 1)
        // These finite bounds are also the existing Statistics date admission
        // limits. Do not call Foundation's oracle with NaN or infinity.
        let values: [Double] = [0, -0.0, -0.000001, -1, -86_400_000, try timestamp(1900, 1, 1),
                                future, 1_000_000_000_000_000, -1_000_000_000_000_000,
                                8_640_000_000_000_000, -8_640_000_000_000_000,
                                (8_640_000_000_000_000.0).nextUp, (-8_640_000_000_000_000.0).nextDown]
        var cursor = StatisticsUTCDayKeyCursor()
        for value in values {
            assertKey(modern, cursor: &cursor); assertKey(value, cursor: &cursor); assertKey(modern, cursor: &cursor)
        }
        let watermark = "9999-12-31"
        XCTAssertNotNil(statisticsDate(watermark, utc: true))
        XCTAssertEqual(cursor.key(future), "10000-01-01")
        XCTAssertGreaterThan(future, try timestamp(9999, 12, 31))
        XCTAssertFalse(cursor.key(future) > watermark, "Preserve string comparison, including its expanded-year ordering")
        var cache = makeCache(watermark)
        cache.totals.input = 77; cache.messages = 9
        var event = StatisticsUsage(id: "future", source: "claude", ts: future, model: "shared")
        event.input = 31
        let actual = StatisticsPublishedTotals.fold([event], cache: cache)
        XCTAssertEqual(actual.totals.input.bitPattern, 77.0.bitPattern)
        XCTAssertEqual(actual.totals.messages.bitPattern, 9.0.bitPattern)
        let sources = StatisticsSourceTotals.fold([event], range: 0, cache: cache, now: modern, calendar: calendar())
        XCTAssertEqual(sources["claude"]["input"].double.bitPattern, 77.0.bitPattern)
    }

    func testWatermarkIntegrationsMatchLiteralOldFormulasAndEveryDoubleBit() throws {
        let boundary = try timestamp(2024, 2, 29), now = try timestamp(2024, 3, 2)
        let times = [boundary.nextDown, boundary, boundary.nextUp, boundary + 0.5,
                     boundary - 86_400_000, boundary + 86_400_000, try timestamp(10000, 1, 1), 0, -1]
        let sources = ["claude", "codex", "claude", "antigravity", "zcode", "opencode", "claude", "dsh", "future-harness", "claude", "claude", "codex"]
        let events = sources.enumerated().map { i, source -> StatisticsUsage in
            var e = StatisticsUsage(id: "utc-\(i)", source: source, ts: times[i % times.count], model: i % 2 == 0 ? "shared" : "observed")
            e.input = i == 0 ? 9_007_199_254_740_992 : 1; e.output = Double(i % 5) + 0.25
            e.thinking = Double(i % 3) / 8; e.cacheRead = 0.5; e.cacheWrite = 0.25
            e.webSearch = Double(i % 2) / 4; e.webFetch = Double(i % 4) / 8
            e.session = "session-\(i % 3)"; e.project = "fixture/\(i % 2)"; e.rawDay = "2099-01-01"
            return e
        }
        XCTAssertNotEqual(oldPublished(events, cache: nil).totals.input.bitPattern,
                          oldPublished(Array(events.reversed()), cache: nil).totals.input.bitPattern)
        let caches: [StatisticsCache?] = [nil] + ["2024-02-28", "2024-02-29", "2024-03-01", "9999-12-31", "", "invalid", "2024-02-30", "2024-02-29T00:00:00Z"].map { Optional(makeCache($0)) }
        for rows in [events, Array(events.reversed())] {
            for cache in caches {
                let actual = StatisticsPublishedTotals.fold(rows, cache: cache), expected = oldPublished(rows, cache: cache)
                try assertJSON(actual.totals.json, expected.totals.json); XCTAssertEqual(actual.models, expected.models)
                for zone in ["UTC", "America/Los_Angeles", "Pacific/Kiritimati"] {
                    let c = calendar(zone)
                    for range in [0, 7, 30] {
                        let a = StatisticsSourceTotals.fold(rows, range: range, cache: cache, now: now, calendar: c)
                        try assertJSON(a, oldSources(rows, range: range, cache: cache, now: now, calendar: c))
                        let unchanged = oldSources(rows.filter { $0.source != "claude" }, range: range, cache: nil, now: now, calendar: c)
                        for source in StatisticsSource.allCases where source != .claude { try assertJSON(a[source.rawValue], unchanged[source.rawValue]) }
                    }
                    if let cache {
                        let claude = rows.filter { $0.source == "claude" }
                        var a = StatisticsFold.derive(claude, range: 0, now: now, calendar: c), b = a
                        StatisticsFold.lifetime(&a, events: claude, cache: cache, calendar: c)
                        oldLifetime(&b, events: claude, cache: cache, calendar: c)
                        try assertJSON(a.json, b.json)
                    }
                }
            }
        }
    }

    private func makeCache(_ watermark: String) -> StatisticsCache {
        var cache = StatisticsCache()
        cache.computedOn = watermark; cache.messages = 40; cache.sessions = 7; cache.activeDays = 2
        cache.firstDay = "2024-02-01"; cache.lastDay = "2024-02-28"; cache.daily = ["2024-02-01": 100, "2024-02-28": 200]
        cache.totals.input = 9_007_199_254_740_992; cache.totals.output = 100.25
        cache.totals.cacheRead = 3.5; cache.totals.cacheWrite = 1.25; cache.totals.webSearch = 0.75
        var shared = StatisticsTotals(); shared.input = 100; shared.output = 25
        var pruned = StatisticsTotals(); pruned.input = 200; pruned.output = 50
        cache.perModel = ["shared": shared, "cache-only": pruned]; cache.models = 2
        return cache
    }

    // Literal pre-cursor folds: the changed predicate still calls statisticsUTC.
    private func oldSources(_ events: [StatisticsUsage], range: Int, cache: StatisticsCache?, now: Double, calendar: Calendar) -> JSONValue {
        let cutoff = statisticsDay(now, calendar: calendar) - Double(range - 1) * 86_400_000
        let lifetime = range == 0 ? cache : nil
        let watermark = lifetime.flatMap { $0.computedOn.count == 10 && statisticsDate($0.computedOn, utc: true) != nil ? $0.computedOn : nil }
        var totals = Dictionary(uniqueKeysWithValues: StatisticsSource.allCases.map { ($0.rawValue, StatisticsTotals()) })
        var fresh = StatisticsTotals()
        for event in events where range == 0 || event.ts >= cutoff {
            totals[event.source, default: StatisticsTotals()].add(event)
            if event.source == "claude", let watermark, statisticsUTC(event.ts) > watermark { fresh.add(event) }
        }
        if let lifetime {
            let observed = totals["claude"] ?? StatisticsTotals()
            var reported = lifetime.totals
            reported.thinking = observed.thinking; reported.webFetch = observed.webFetch; reported.messages = lifetime.messages
            if watermark != nil { reported.addReported(fresh); reported.messages += fresh.messages }
            totals["claude"] = reported
        }
        return .object(Dictionary(uniqueKeysWithValues: StatisticsSource.allCases.map { ($0.rawValue, totals[$0.rawValue]!.json) }))
    }
    private func oldPublished(_ events: [StatisticsUsage], cache: StatisticsCache?) -> StatisticsPublishedTotals {
        var models = Set<String>()
        guard let cache else {
            var totals = StatisticsTotals()
            for event in events { totals.add(event); models.insert(event.model) }
            return StatisticsPublishedTotals(totals: totals, models: models.count)
        }
        let watermarkValid = cache.computedOn.count == 10 && statisticsDate(cache.computedOn, utc: true) != nil
        var claude = StatisticsTotals(), others = StatisticsTotals(), fresh = StatisticsTotals()
        for event in events {
            models.insert(event.model)
            if event.source == "claude" {
                claude.add(event)
                if watermarkValid, statisticsUTC(event.ts) > cache.computedOn { fresh.add(event) }
            } else { others.add(event) }
        }
        var totals = cache.totals
        totals.thinking = claude.thinking; totals.webFetch = claude.webFetch; totals.messages = cache.messages
        if watermarkValid { totals.addReported(fresh); totals.messages += fresh.messages }
        totals.add(others); models.formUnion(cache.perModel.keys)
        return StatisticsPublishedTotals(totals: totals, models: models.count)
    }
    private func oldLifetime(_ d: inout StatisticsDerived, events: [StatisticsUsage], cache: StatisticsCache, calendar: Calendar) {
        d.isLifetime = true
        let watermarkValid = cache.computedOn.count == 10 && statisticsDate(cache.computedOn, utc: true) != nil
        let fresh = watermarkValid ? events.filter { statisticsUTC($0.ts) > cache.computedOn } : nil
        let observed = d.summary.totals; var t = cache.totals
        t.thinking = observed.thinking; t.webFetch = observed.webFetch; t.messages = cache.messages
        if let fresh { let tail = StatisticsFold.summary(fresh, calendar: calendar).totals; t.addReported(tail); t.messages += tail.messages }
        d.summary.totals = t; d.summary.sessions = Int(cache.sessions)
        var dates = StatisticsCalendarCursor(calendar: calendar)
        var days = Set(events.map { dates.day($0.ts) }); for key in cache.daily.keys { if let day = statisticsDate(key, calendar: calendar) { days.insert(day) } }
        d.summary.activeDays = max(cache.activeDays, days.count)
        if let first = statisticsDate(cache.firstDay, calendar: calendar) { d.summary.first = min(d.summary.first ?? first, first) }
        if let last = statisticsDate(cache.lastDay, calendar: calendar) { d.summary.last = max(d.summary.last ?? last, last) }
        var rows = Dictionary(uniqueKeysWithValues: d.models.map { ($0.model, $0) })
        let freshModels = fresh.map { Dictionary(uniqueKeysWithValues: StatisticsFold.models($0, calendar: calendar).map { ($0.model, $0.totals) }) }
        let observedModels = Set(events.map(\.model))
        for (name, cached) in cache.perModel {
            var m = rows[name] ?? StatisticsModel(model: name); m.pruned = !observedModels.contains(name)
            if m.pruned { m.viaProxy = !name.hasPrefix("claude-") }
            if let freshModels {
                let old = m.totals; m.totals = cached; m.totals.thinking = old.thinking; m.totals.messages = old.messages; m.totals.webFetch = old.webFetch
                if let tail = freshModels[name] { m.totals.addReported(tail) }
            } else if m.totals.grand < cached.grand {
                let old = m.totals; m.totals = cached; m.totals.thinking = old.thinking; m.totals.messages = old.messages; m.totals.webFetch = old.webFetch
            }
            rows[name] = m
        }
        d.models = rows.values.sorted { $0.totals.grand == $1.totals.grand ? $0.model < $1.model : $0.totals.grand > $1.totals.grand }; d.summary.models = d.models.count
        StatisticsFold.addUntimedModels(&d)
    }
}
