import Foundation
import XCTest
@testable import UniApiCore

final class StatisticsPublishedTotalsTests: XCTestCase {
    private let shared = "fixture/shared"
    private let cachedOnly = "fixture/pruned-cache-only"
    private var now: Double { timestamp("2026-10-15T12:00:00Z") }

    func testEveryKnownAndUnknownSourceMatchesUnchangedAllTimeFold() {
        let events = mixedEvents()
        XCTAssertEqual(Set(events.map(\.source)), Set(StatisticsSource.allCases.map(\.rawValue) + ["future-harness"]))
        XCTAssertTrue(events.contains { $0.source == "future-harness" && $0.grand > 0 })
        for (name, rows) in [("forward", events), ("reverse", Array(events.reversed()))] {
            for zone in ["UTC", "America/New_York"] {
                assertEquivalent(rows, cache: nil, zone: zone, label: "\(name)/\(zone)")
            }
        }
    }

    func testLifetimeUnionAndTwentyThousandRowProjectionMatchFullBoard() {
        let events = mixedEvents(), cache = lifetimeCache("2026-10-10")
        XCTAssertTrue(events.contains { $0.model == shared && $0.source == "claude" })
        XCTAssertTrue(events.contains { $0.model == shared && $0.source != "claude" })
        XCTAssertFalse(events.contains { $0.model == cachedOnly })
        let board = oracle(events, cache: cache)
        XCTAssertTrue(board.models.contains { $0.model == cachedOnly && $0.pruned })
        XCTAssertFalse(board.models.first { $0.model == shared }!.pruned)
        XCTAssertNotEqual(board.summary.models, cache.models, "The fixture's cached model-count metadata must not stand in for the union")
        for rows in [events, Array(events.reversed())] {
            assertEquivalent(rows, cache: cache, label: "shared/pruned union")
        }

        let seeds = events.filter { $0.source != "future-harness" }
        let corpus = (0..<20_000).map { index in
            var value = seeds[index % seeds.count]
            value.id = "publication-perf-\(index)"
            value.session = "fixture/session-\(index % 37)"
            value.project = "fixture/project-\(index % 7)"
            return value
        }
        XCTAssertEqual(corpus.count, 20_000)
        XCTAssertEqual(Set(corpus.map(\.source)), Set(StatisticsSource.allCases.map(\.rawValue)))
        let measuredNow = now, measuredCalendar = calendar("UTC")
        var fullBoardMs: [Double] = [], projectionMs: [Double] = []
        // ABBAAB order in this test process; construction and equality checks
        // sit outside the measured closures. This is no installed Reload claim.
        for trial in 0..<3 {
            let old: (value: StatisticsDerived, milliseconds: Double)
            let new: (value: StatisticsPublishedTotals, milliseconds: Double)
            if trial % 2 == 0 {
                old = measured { StatisticsFold.sources(corpus, range: 0, cache: cache, source: "all", now: measuredNow, calendar: measuredCalendar) }
                new = measured { StatisticsPublishedTotals.fold(corpus, cache: cache) }
            } else {
                new = measured { StatisticsPublishedTotals.fold(corpus, cache: cache) }
                old = measured { StatisticsFold.sources(corpus, range: 0, cache: cache, source: "all", now: measuredNow, calendar: measuredCalendar) }
            }
            fullBoardMs.append(old.milliseconds); projectionMs.append(new.milliseconds)
            XCTAssertEqual(new.value.totals.json, old.value.summary.totals.json)
            XCTAssertEqual(totalBits(new.value.totals), totalBits(old.value.summary.totals))
            XCTAssertEqual(new.value.models, old.value.summary.models)
        }
        print("Statistics publication projection: 20000 synthetic rows, six sources plus lifetime cache; single-process median3 elapsed old full board \(fullBoardMs.sorted()[1]) ms, published totals \(projectionMs.sorted()[1]) ms")
    }

    func testValidWatermarkUsesStrictUTCTailAcrossLocalMidnights() {
        var events = [
            row("old", source: "claude", stamp: "2026-10-09T23:59:59Z", input: 11),
            row("edge", source: "claude", stamp: "2026-10-10T23:59:59.999Z", input: 13),
            row("fresh", source: "claude", stamp: "2026-10-11T00:00:00Z", input: 17),
            row("other", source: "codex", stamp: "2026-10-09T23:59:59Z", input: 19)
        ]
        // Raw source day strings and the caller's local calendar cannot move
        // the lifetime watermark, whose existing contract uses UTC timestamps.
        for index in events.indices { events[index].rawDay = index == 2 ? "1999-01-01" : "2099-01-01" }
        let cache = lifetimeCache("2026-10-10")
        for zone in ["UTC", "America/Los_Angeles", "Pacific/Kiritimati"] {
            assertEquivalent(events, cache: cache, zone: zone, label: "UTC tail/\(zone)")
        }
        var boundaryControl = events
        boundaryControl[2].ts = timestamp("2026-10-10T23:59:59.999Z")
        XCTAssertNotEqual(oracle(events, cache: cache).summary.totals.messages.bitPattern,
                          oracle(boundaryControl, cache: cache).summary.totals.messages.bitPattern)
        assertEquivalent(boundaryControl, cache: cache, label: "same UTC day remains covered by cache")
    }

    func testInvalidWatermarksMatchExistingFallbackWithoutAddingFreshTail() {
        let events = mixedEvents()
        let invalid = ["", "not-a-date", "2026-02-30", "2026-13-01", "2026-10-10T00:00:00Z"]
        let baseline = totalBits(oracle(events, cache: lifetimeCache("")).summary.totals)
        for watermark in invalid {
            let cache = lifetimeCache(watermark)
            XCTAssertEqual(totalBits(oracle(events, cache: cache).summary.totals), baseline)
            assertEquivalent(events, cache: cache, label: "invalid watermark: \(watermark)")
        }
        XCTAssertNotEqual(totalBits(oracle(events, cache: lifetimeCache("2026-10-10")).summary.totals), baseline,
                          "The fixture must distinguish a valid fresh-tail reconciliation")
    }

    func testEmptyAndCacheOnlyInputsPreserveEveryCounterAndModelCount() {
        assertEquivalent([], cache: nil, label: "empty")
        for watermark in ["2026-10-10", "invalid", ""] {
            let cache = lifetimeCache(watermark)
            XCTAssertEqual(oracle([], cache: cache).summary.models, 3)
            assertEquivalent([], cache: cache, label: "cache only/\(watermark)")
        }
        var noModels = lifetimeCache("2026-10-10")
        noModels.perModel = [:]
        XCTAssertGreaterThan(noModels.totals.grand, 0)
        XCTAssertEqual(oracle([], cache: noModels).summary.models, 0)
        assertEquivalent([], cache: noModels, label: "reported totals without cached model rows")
    }

    func testNoCachePreservesEventOrderAndComponentSumBitPatterns() {
        let large = 9_007_199_254_740_992.0
        let events = [
            row("large", source: "claude", input: large),
            row("small-a", source: "codex", input: 1),
            row("small-b", source: "codex", input: 1)
        ]
        let reversed = Array(events.reversed())
        XCTAssertNotEqual(oracle(events, cache: nil).summary.totals.input.bitPattern,
                          oracle(reversed, cache: nil).summary.totals.input.bitPattern,
                          "A source regrouping or permutation must be observable in this fixture")
        assertEquivalent(events, cache: nil, label: "ordered large/small values")
        assertEquivalent(reversed, cache: nil, label: "reversed large/small values")

        let componentControl = [row("components-a", source: "claude", input: large, output: 1),
                                row("components-b", source: "future-harness", output: 1)]
        let expected = oracle(componentControl, cache: nil).summary.totals
        XCTAssertNotEqual(expected.grand.bitPattern, componentControl.reduce(0.0) { $0 + $1.grand }.bitPattern,
                          "Summing per-event grand values would lose the component fold's precision")
        assertEquivalent(componentControl, cache: nil, label: "sum components before grand")
    }

    func testLifetimePreservesFreshAndOtherPartitionAccumulationBitPatterns() {
        let large = 9_007_199_254_740_992.0
        var cache = lifetimeCache("2026-10-10")
        cache.totals.input = large; cache.totals.output = 0
        cache.totals.cacheWrite = 0; cache.totals.cacheRead = 0; cache.messages = large
        let events = [
            row("other-large", source: "codex", output: large),
            row("fresh-a", source: "claude", stamp: "2026-10-11T00:00:00Z", input: 1),
            row("other-small-a", source: "antigravity", output: 1),
            row("fresh-b", source: "claude", stamp: "2026-10-11T00:00:01Z", input: 1),
            row("other-small-b", source: "antigravity", output: 1)
        ]
        let reversed = Array(events.reversed())
        XCTAssertNotEqual(oracle(events, cache: cache).summary.totals.output.bitPattern,
                          oracle(reversed, cache: cache).summary.totals.output.bitPattern,
                          "Other harnesses must retain their joint event order, not grouped-source order")
        assertEquivalent(events, cache: cache, label: "lifetime partitions")
        assertEquivalent(reversed, cache: cache, label: "reversed lifetime partitions")
        cache.computedOn = "invalid"
        assertEquivalent(events, cache: cache, label: "large values without valid tail")
    }

    func testServicePublishedAndRequestedSummaryMatchOverviewAfterRefresh() async throws {
        let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
            .appendingPathComponent("statistics-published-totals-" + UUID().uuidString)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        try NativeFile.writeAtomic(try JSONValue.object(["providers": []]).encoded(),
                                   to: root.appendingPathComponent("providers.example.json"))
        let paths = NativePaths(root: root, home: root.appendingPathComponent("home"))
        let source = paths.home.appendingPathComponent(".claude/projects/fixture/usage.jsonl")
        let lifetime = paths.home.appendingPathComponent(".claude/stats-cache.json")
        let initialRow = transcript("first", model: shared, input: 10, stamp: "2026-10-11T00:00:00Z")
        try writeLines([initialRow], to: source)
        let initialCache: JSONValue = ["modelUsage": [shared: ["inputTokens": 1000, "outputTokens": 200]],
                                       "totalMessages": 40, "lastComputedDate": "2026-10-10"]
        try NativeFile.writeAtomic(try initialCache.encoded(), to: lifetime)
        let runtime = try NativeRuntime(paths: paths)
        await runtime.jobs.suspendForShutdown()
        let fixedNow = now
        let service = NativeStatisticsService(runtime: runtime, environment: [:], calendar: calendar("UTC"), clock: { fixedNow })
        let first = try await assertServiceCounters(service, label: "initial publication")

        try writeLines([initialRow, transcript("second", model: "fixture/new-observed", input: 2000,
                                              stamp: "2026-10-12T00:00:00Z")], to: source)
        let changedCache: JSONValue = ["modelUsage": [shared: ["inputTokens": 5000, "outputTokens": 200],
                                                    "fixture/new-cache-only": ["inputTokens": 300]],
                                       "totalMessages": 60, "lastComputedDate": "2026-10-10"]
        try NativeFile.writeAtomic(try changedCache.encoded(), to: lifetime)
        let refresh = try await service.handle("refresh")
        XCTAssertEqual(refresh["ok"], true)
        XCTAssertEqual(refresh["scan"]["parsedFiles"], 1)
        let changed = try await assertServiceCounters(service, label: "changed generation")
        for key in ["grand", "models", "responses"] { XCTAssertNotEqual(changed[key], first[key], key) }

        let unchanged = try await service.handle("refresh")
        XCTAssertEqual(unchanged["scan"]["parsedFiles"], 0)
        XCTAssertNotEqual(unchanged["scan"]["scanId"], refresh["scan"]["scanId"])
        let retained = try await assertServiceCounters(service, label: "unchanged refresh")
        XCTAssertEqual(retained, changed)
        XCTAssertEqual(numberBits(retained), numberBits(changed))
    }

    private func assertEquivalent(_ events: [StatisticsUsage], cache: StatisticsCache?, zone: String = "UTC",
                                  label: String, file: StaticString = #filePath, line: UInt = #line) {
        let expected = oracle(events, cache: cache, zone: zone).summary
        let actual = StatisticsPublishedTotals.fold(events, cache: cache)
        XCTAssertEqual(actual.totals.json, expected.totals.json, label + ": every totals field", file: file, line: line)
        XCTAssertEqual(totalBits(actual.totals), totalBits(expected.totals), label + ": every Double bit pattern", file: file, line: line)
        XCTAssertEqual(actual.models, expected.models, label + ": model union", file: file, line: line)
    }

    private func oracle(_ events: [StatisticsUsage], cache: StatisticsCache?, zone: String = "UTC") -> StatisticsDerived {
        StatisticsFold.sources(events, range: 0, cache: cache, source: "all", now: now, calendar: calendar(zone))
    }

    private func totalBits(_ totals: StatisticsTotals) -> [String: UInt64] {
        var value = totals.json
        value["grand"] = .number(totals.grand)
        return numberBits(value)
    }

    private func numberBits(_ value: JSONValue) -> [String: UInt64] {
        value.object.reduce(into: [:]) { result, entry in
            if case .number(let number) = entry.value { result[entry.key] = number.bitPattern }
        }
    }

    private func measured<Value>(_ body: () -> Value) -> (value: Value, milliseconds: Double) {
        let begin = ProcessInfo.processInfo.systemUptime
        let value = body()
        return (value, (ProcessInfo.processInfo.systemUptime - begin) * 1000)
    }

    private func assertServiceCounters(_ service: NativeStatisticsService, label: String,
                                       file: StaticString = #filePath, line: UInt = #line) async throws -> JSONValue {
        // Capture both lightweight publications before asking for the chart
        // board; warming that board first could hide a stale projection cache.
        let requested = try await service.handle("summary"), published = service.cachedSummary()
        let overview = try await service.handle("overview", input: ["source": "all", "range": 0])
        let board = overview["derived"]["summary"]
        let fields = board["totals"]
        let expected: JSONValue = ["grand": .number(fields["input"].double + fields["output"].double + fields["cacheWrite"].double + fields["cacheRead"].double),
                                   "models": board["models"], "responses": fields["messages"]]
        for (name, value) in [("requested", requested), ("published", published)] {
            XCTAssertEqual(value["loaded"], true, label + "/" + name, file: file, line: line)
            let counters = JSONValue.object(Dictionary(uniqueKeysWithValues: ["grand", "models", "responses"].map { ($0, value[$0]) }))
            XCTAssertEqual(counters, expected, label + "/" + name, file: file, line: line)
            XCTAssertEqual(numberBits(counters), numberBits(expected), label + "/" + name + " bits", file: file, line: line)
        }
        return expected
    }

    private func calendar(_ zone: String) -> Calendar {
        var value = Calendar(identifier: .gregorian)
        value.locale = Locale(identifier: "en_US_POSIX"); value.timeZone = TimeZone(identifier: zone)!
        return value
    }

    private func timestamp(_ value: String) -> Double { statisticsTimestamp(.string(value))! }

    private func row(_ id: String, source: String, stamp: String = "2026-10-12T12:00:00Z",
                     input: Double = 0, output: Double = 0) -> StatisticsUsage {
        var value = StatisticsUsage(id: id, source: source, ts: timestamp(stamp), model: shared)
        value.session = "fixture/session/" + id; value.project = "fixture/project"
        value.input = input; value.output = output
        return value
    }

    private func mixedEvents() -> [StatisticsUsage] {
        let sources = StatisticsSource.allCases.map(\.rawValue) + ["future-harness"]
        return (0..<21).map { index in
            var value = row("mixed-\(index)", source: sources[index % sources.count],
                            stamp: index % 2 == 0 ? "2026-10-09T23:59:59Z" : "2026-10-11T00:00:00Z",
                            input: Double(index + 1) * 17.125, output: Double(index + 1) / 4)
            value.model = index % 3 == 0 ? shared : "fixture/model-\(index % 5)"
            value.thinking = value.output / 8; value.cacheWrite = Double(index % 4) / 16
            value.cacheRead = Double(index % 3) / 8; value.webSearch = Double(index % 3) / 4
            value.webFetch = Double(index % 2) / 2; value.sidechain = index % 2 == 0
            value.durationMs = 125.25; value.timing = "estimated"
            value.streamDurationMs = index % 2 == 0 ? 50.125 : nil
            value.streamOutputTokens = value.streamDurationMs == nil ? nil : value.output
            value.streamTiming = value.streamDurationMs == nil ? nil : "fixture-clock"
            return value
        }
    }

    private func lifetimeCache(_ watermark: String) -> StatisticsCache {
        var cache = StatisticsCache()
        cache.computedOn = watermark; cache.messages = 40.25; cache.models = 9999
        cache.totals.input = 1000.25; cache.totals.output = 200.5
        cache.totals.cacheWrite = 30.125; cache.totals.cacheRead = 50.0625
        cache.totals.webSearch = 7.25
        // These stale fields are deliberately inconsistent with source usage.
        // The full lifetime fold owns which reported counters can replace it.
        cache.totals.messages = 888; cache.totals.thinking = 777; cache.totals.webFetch = 666
        var sharedTotals = StatisticsTotals(); sharedTotals.input = 700.5
        var prunedTotals = StatisticsTotals(); prunedTotals.input = 300.25
        cache.perModel = [shared: sharedTotals, cachedOnly: prunedTotals, "fixture/another-cache-only": prunedTotals]
        return cache
    }

    private func transcript(_ id: String, model: String, input: Int, stamp: String) -> JSONValue {
        ["type": "assistant", "timestamp": .string(stamp), "sessionId": "fixture/session", "cwd": "fixture/project",
         "message": ["id": .string(id), "model": .string(model), "usage": ["input_tokens": .number(Double(input)), "output_tokens": 1]]]
    }

    private func writeLines(_ rows: [JSONValue], to url: URL) throws {
        let body = try rows.map { String(decoding: try $0.encoded(), as: UTF8.self) }.joined(separator: "\n") + "\n"
        try NativeFile.writeAtomic(Data(body.utf8), to: url)
    }
}
