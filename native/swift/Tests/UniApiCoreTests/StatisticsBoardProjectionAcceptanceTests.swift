import Foundation
import XCTest
@testable import UniApiCore

final class StatisticsBoardProjectionAcceptanceTests: XCTestCase {
    private let shared = "claude-opus-5"
    private let cachedOnly = "fixture/cache-only"
    private let ranges = [0, 7, 30, 90, 365]
    private var sources: [String] { ["all"] + StatisticsSource.allCases.map(\.rawValue) }
    private var now: Double { date("2026-10-19T12:00:00Z") }
    private var utc: Calendar { calendar("UTC") }

    func testAllSourcesAndRangesWithoutCacheMatchInstalled279CompleteBoards() {
        let events = generatedEvents()
        XCTAssertEqual(Set(events.map(\.source)), Set(StatisticsSource.allCases.map(\.rawValue)))
        XCTAssertGreaterThan(Set(events.map(\.model)).count, 8, "Exercise chart stack overflow metadata")
        for zone in ["UTC", "America/New_York"] {
            assertMatrix(events, cache: nil, calendar: calendar(zone), label: "no-cache/\(zone)")
        }
    }

    func testValidWatermarkSharedAndPrunedModelsMatchInstalled279CompleteBoards() {
        let events = watermarkEvents(), cache = lifetimeCache("2026-10-10")
        for zone in ["UTC", "Europe/Berlin", "America/New_York"] {
            assertMatrix(events, cache: cache, calendar: calendar(zone), label: "valid-tail/\(zone)")
        }
        let board = compare(events, cache: cache, range: 0, source: "all", calendar: utc, label: "shared/pruned controls")
        let models = Dictionary(board["models"].array.map { ($0["model"].string, $0) }, uniquingKeysWith: { _, last in last })
        XCTAssertFalse(models[shared]?["pruned"].bool ?? true)
        XCTAssertFalse(models["gpt-6-astra"]?["pruned"].bool ?? true, "A cached Claude model also has actual non-Claude usage")
        XCTAssertTrue(models[cachedOnly]?["pruned"].bool ?? false)
        XCTAssertTrue(models[cachedOnly]?["viaProxy"].bool ?? false)
        XCTAssertGreaterThan(board["cost"]["usd"].double, 0)
        XCTAssertGreaterThan(board["cost"]["unpricedTokens"].double, 0)
    }

    func testInvalidWatermarksPreserveInstalled279FallbackBoards() {
        var events = generatedEvents()
        // One observed cached model exceeds its cached total; another is below
        // it. Invalid-watermark fallback must preserve both original branches.
        events.append(row(100, source: "claude", timestamp: date("2026-10-09T09:00:00Z"),
                          model: "gpt-6-astra", input: 100_000.125))
        for watermark in ["", "2026-02-30", "2026-10-10T00:00:00Z"] {
            assertMatrix(events, cache: lifetimeCache(watermark), label: "invalid-watermark/\(watermark)")
        }
    }

    func testEmptyAndCacheOnlyBoardsMatchInstalled279IncludingMetadataAndCost() {
        let caches: [(String, StatisticsCache?)] = [
            ("empty", nil), ("cache-only-valid", lifetimeCache("2026-10-10")),
            ("cache-only-invalid", lifetimeCache("invalid"))
        ]
        for (label, cache) in caches { assertMatrix([], cache: cache, label: label) }
        let empty = compare([], cache: nil, range: 0, source: "all", calendar: utc, label: "empty controls")
        XCTAssertEqual(empty["events"], 0)
        XCTAssertEqual(empty["heat"].array.count, 7)
        XCTAssertTrue(empty["days"].array.isEmpty)
        XCTAssertTrue(empty["summary"]["first"].isNull)
        XCTAssertEqual(empty["cost"]["usd"], 0)
        let cached = compare([], cache: lifetimeCache("2026-10-10"), range: 0, source: "all",
                             calendar: utc, label: "cache-only controls")
        XCTAssertEqual(cached["models"].array.count, 4)
        XCTAssertTrue(cached["models"].array.allSatisfy { $0["pruned"].bool })
        XCTAssertEqual(cached["events"], 0)
        XCTAssertTrue(cached["isLifetime"].bool)
    }

    func testSingleSourceAndNoClaudeBoardsMatchInstalled279AcrossScopes() {
        let events = generatedEvents()
        let corpora = [
            ("only-claude", events.filter { $0.source == "claude" }),
            ("only-codex", events.filter { $0.source == "codex" }),
            ("no-claude", events.filter { $0.source != "claude" })
        ]
        for (label, corpus) in corpora {
            XCTAssertFalse(corpus.isEmpty)
            assertMatrix(corpus, cache: nil, label: label + "/no-cache")
            assertMatrix(corpus, cache: lifetimeCache("2026-10-10"), label: label + "/cache")
        }
    }

    func testFractionalLargeFiniteAndUnsortedCorporaMatchInstalled279BitPatterns() {
        let events = generatedEvents(precision: true)
        XCTAssertTrue(events.contains { $0.input > 9_007_199_254_740_992 })
        XCTAssertTrue(events.contains { $0.input > 0 && $0.input < 1 })
        XCTAssertTrue(events.allSatisfy { $0.grand.isFinite })
        let orders = [
            ("reversed", Array(events.reversed())),
            ("interleaved", events.enumerated().filter { $0.offset % 2 == 0 }.map(\.element)
                + events.enumerated().filter { $0.offset % 2 == 1 }.map(\.element))
        ]
        for (label, corpus) in orders {
            // Each order is compared to the same-order original algorithm.
            // Floating-point sums are not assumed to be permutation invariant.
            assertMatrix(corpus, cache: lifetimeCache("2026-10-10"), label: label + "/valid")
            assertMatrix(corpus, cache: lifetimeCache("2026-02-30"), label: label + "/invalid")
        }
    }

    private func assertMatrix(_ events: [StatisticsUsage], cache: StatisticsCache?,
                              calendar: Calendar? = nil, label: String,
                              file: StaticString = #filePath, line: UInt = #line) {
        for range in ranges {
            for source in sources {
                _ = compare(events, cache: cache, range: range, source: source, calendar: calendar ?? utc,
                            label: "\(label)/\(source)/\(range)", file: file, line: line)
            }
        }
    }

    @discardableResult
    private func compare(_ events: [StatisticsUsage], cache: StatisticsCache?, range: Int,
                         source: String, calendar: Calendar, label: String,
                         file: StaticString = #filePath, line: UInt = #line) -> JSONValue {
        let actual = StatisticsFold.sources(events, range: range, cache: cache, source: source, now: now, calendar: calendar).json
        let original = Installed279BoardOracle.sources(events, range: range, cache: cache, source: source, now: now, calendar: calendar).json
        // Compare the entire value, including order, nulls and all metadata.
        // The numeric map additionally distinguishes signed zero and every
        // other Double representation; JSON encoding would lose that evidence.
        XCTAssertEqual(actual, original, label + ": complete derived JSON", file: file, line: line)
        XCTAssertEqual(numberBits(actual), numberBits(original), label + ": all numeric bit patterns", file: file, line: line)
        return actual
    }

    private func numberBits(_ value: JSONValue) -> [String: UInt64] {
        var result: [String: UInt64] = [:]
        func visit(_ value: JSONValue, path: String) {
            switch value {
            case .number(let number): result[path] = number.bitPattern
            case .array(let values):
                for (index, child) in values.enumerated() { visit(child, path: path + "/\(index)") }
            case .object(let values):
                for key in values.keys.sorted() {
                    let escaped = key.replacingOccurrences(of: "~", with: "~0").replacingOccurrences(of: "/", with: "~1")
                    visit(values[key]!, path: path + "/" + escaped)
                }
            default: break
            }
        }
        visit(value, path: "")
        return result
    }

    private func calendar(_ zone: String) -> Calendar {
        var value = Calendar(identifier: .gregorian)
        value.locale = Locale(identifier: "en_US_POSIX")
        value.timeZone = TimeZone(identifier: zone)!
        return value
    }
    private func date(_ stamp: String) -> Double { statisticsTimestamp(.string(stamp))! }

    private func row(_ id: Int, source: String, timestamp: Double, model: String, input: Double) -> StatisticsUsage {
        var value = StatisticsUsage(id: "board-\(id)", source: source, ts: timestamp, model: model)
        value.project = "/fixture/projects/group-\(id % 4)"
        value.session = "shared-session-\(id % 3)"
        value.sidechain = id % 3 == 0
        value.effort = ["", "high", "none", "ultra"][id % 4]
        value.input = input; value.output = input / 4; value.thinking = value.output / 8
        value.cacheWrite = input / 16; value.cacheRead = input / 8
        value.webSearch = Double(id % 3) / 4; value.webFetch = Double(id % 2) / 2
        let durations: [Double?] = [nil, 0, 125.25, 1_000.5, 5_000.125]
        value.durationMs = durations[id % 5]
        value.timing = id % 2 == 0 ? "estimated" : "measured"
        value.rawDay = statisticsUTC(timestamp)
        return value
    }

    private func generatedEvents(precision: Bool = false) -> [StatisticsUsage] {
        let models = ["claude-opus-5", "gpt-6-astra", "gemini-3.8-flash", "z-ai/glm4.7",
                      "fixture/unpriced-a", "fixture/unpriced-b", "claude-fable-5",
                      "gpt-5.6-sol", "glm-5.3-flash", "gemini-3.7-flash", "fixture/unpriced-c"]
        let offsets = [400, 365, 364, 90, 89, 30, 29, 7, 6, 1, 0]
        let precise: [Double] = [0, -0.0, 0.1, 0.2, 1.0 / 3.0, Double.leastNormalMagnitude,
                                 9_007_199_254_740_992, 9_007_199_254_740_994, 1e100]
        let midnight = statisticsDay(now, calendar: utc)
        return (0..<22).map { index in
            let timestamp = midnight - Double(offsets[index % offsets.count]) * 86_400_000
                + [0, 0.125, 43_200_000, 86_399_999.875][index % 4]
            var value = row(index, source: StatisticsSource.allCases[index % StatisticsSource.allCases.count].rawValue,
                            timestamp: timestamp, model: models[index % models.count],
                            input: precision ? precise[index % precise.count] : Double(index + 1) * 17.125)
            if precision {
                value.output = precise[(index + 2) % precise.count] / 4
                value.thinking = value.output / 8
                value.cacheWrite = precise[(index + 3) % precise.count] / 16
                value.cacheRead = precise[(index + 5) % precise.count] / 8
            }
            return value
        }
    }

    private func watermarkEvents() -> [StatisticsUsage] {
        [
            row(0, source: "claude", timestamp: date("2026-10-09T12:00:00Z"), model: shared, input: 0.1),
            row(1, source: "claude", timestamp: date("2026-10-10T23:59:59.875Z"), model: shared, input: 0.2),
            row(2, source: "claude", timestamp: date("2026-10-11T00:00:00Z"), model: shared, input: 1.0 / 3.0),
            row(3, source: "codex", timestamp: date("2026-10-12T04:00:00Z"), model: shared, input: 13.125),
            row(4, source: "antigravity", timestamp: date("2026-10-14T09:00:00Z"), model: "gemini-3.8-flash", input: 17.25),
            row(5, source: "codex", timestamp: date("2026-10-12T16:00:00Z"), model: "gpt-6-astra", input: 19.5)
        ]
    }

    private func totals(_ input: Double, _ output: Double, _ write: Double,
                        _ read: Double, searches: Double = 0) -> StatisticsTotals {
        var value = StatisticsTotals()
        value.input = input; value.output = output; value.cacheWrite = write
        value.cacheRead = read; value.webSearch = searches
        return value
    }
    private func lifetimeCache(_ watermark: String) -> StatisticsCache {
        var value = StatisticsCache()
        value.totals = totals(1_674.25, 113.375, 25, 1_795.25, searches: 2)
        value.sessions = 9; value.messages = 23; value.activeDays = 4
        value.computedOn = watermark; value.firstDay = "2025-09-10"; value.lastDay = "2026-10-10"
        value.daily = ["2025-09-10": 16.25, "2026-10-09": 512.5, "2026-10-10": 1_024.125]
        value.perModel = [
            shared: totals(1_024.125, 64.25, 12.5, 512.75, searches: 1.25),
            "gpt-6-astra": totals(128.5, 16.125, 4.25, 256.5, searches: 0.5),
            "z-ai/glm4.7": totals(512.375, 32.5, 8.125, 1_024.25, searches: 0.25),
            cachedOnly: totals(9.25, 0.5, 0.125, 1.75)
        ]
        value.models = value.perModel.count
        return value
    }
}

// This private test oracle retains the original279 sources method literally.
// Frozen source: .cache/home-cold-final-gate-uvr0hcix/Sources/UniApiCore/StatisticsFolds.swift
// Full-file SHA256: de9cc1ce8ad26f563c26b78c647aad49a8fffc6dd4c3e51ea15d479f7970caa8
// The delegates below use unchanged derive (including lifetime) and
// addUntimedModels. They never call the candidate summaryAndModels helper.
private enum Installed279BoardOracle {
    static func sources(_ events: [StatisticsUsage], range: Int, cache: StatisticsCache?, source: String, now: Double, calendar: Calendar) -> StatisticsDerived {
        if source == "claude" { return derive(events.filter { $0.source == "claude" }, range: range, cache: cache, now: now, calendar: calendar) }
        if source != "all" { return derive(events.filter { $0.source == source }, range: range, now: now, calendar: calendar) }
        var d = derive(events, range: range, now: now, calendar: calendar)
        guard range == 0, let cache else { return d }
        let claude = derive(events.filter { $0.source == "claude" }, range: range, cache: cache, now: now, calendar: calendar)
        let others = derive(events.filter { $0.source != "claude" }, range: range, now: now, calendar: calendar)
        d.isLifetime = true; d.summary.totals = claude.summary.totals; d.summary.totals.add(others.summary.totals); d.summary.sessions = claude.summary.sessions + others.summary.sessions
        var days = Set(d.days.map { $0["day"].double }); for key in cache.daily.keys { if let day = statisticsDate(key, calendar: calendar) { days.insert(day) } }; d.summary.activeDays = max(claude.summary.activeDays, days.count)
        d.summary.first = [claude.summary.first, others.summary.first].compactMap { $0 }.min(); d.summary.last = [claude.summary.last, others.summary.last].compactMap { $0 }.max()
        let raw = Dictionary(uniqueKeysWithValues: d.models.map { ($0.model, $0) }); var rows = Dictionary(uniqueKeysWithValues: claude.models.map { ($0.model, $0) })
        for other in others.models {
            if var m = rows[other.model] { m.totals.add(other.totals); m.days = raw[other.model]?.days ?? 0; m.sessions += other.sessions; m.first = raw[other.model]?.first; m.last = raw[other.model]?.last; m.pruned = false; rows[other.model] = m }
            else { rows[other.model] = other }
        }
        d.models = rows.values.sorted { $0.totals.grand == $1.totals.grand ? $0.model < $1.model : $0.totals.grand > $1.totals.grand }; d.summary.models = rows.count; addUntimedModels(&d)
        return d
    }
    private static func derive(_ events: [StatisticsUsage], range: Int, cache: StatisticsCache? = nil,
                               now: Double, calendar: Calendar) -> StatisticsDerived {
        StatisticsFold.derive(events, range: range, cache: cache, now: now, calendar: calendar)
    }
    private static func addUntimedModels(_ value: inout StatisticsDerived) {
        StatisticsFold.addUntimedModels(&value)
    }
}
