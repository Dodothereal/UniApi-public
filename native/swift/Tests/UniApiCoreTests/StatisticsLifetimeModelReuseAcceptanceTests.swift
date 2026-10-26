import XCTest
import Foundation
import Darwin
@testable import UniApiCore

final class StatisticsLifetimeModelReuseAcceptanceTests: XCTestCase {
    private let shared = "claude-opus-5", cacheOnly = "z-ai/glm4.7"
    private var utc: Calendar {
        var value = Calendar(identifier: .gregorian)
        value.timeZone = TimeZone(secondsFromGMT: 0)!
        return value
    }
    private func date(_ value: String) -> Double { statisticsTimestamp(.string(value))! }
    private var now: Double { date("2026-10-13T00:00:00Z") }
    private struct Fixture {
        let root: URL, home: URL, claude: URL, codex: URL, cache: URL
        let runtime: NativeRuntime, service: NativeStatisticsService
    }
    private func put(_ values: [JSONValue], at url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let text = try values.map { String(decoding: try $0.encoded(), as: UTF8.self) }.joined(separator: "\n") + "\n"
        try Data(text.utf8).write(to: url)
    }
    private func claudeFrames(extra: Bool = false) -> [JSONValue] {
        func response(_ id: String, start: String, end: String, input: Int, output: Int, thinking: Int, sidechain: Bool = false) -> [JSONValue] {
            [
                ["type": "user", "uuid": .string("u-" + id), "timestamp": .string(start)],
                ["type": "assistant", "uuid": .string("a-" + id), "parentUuid": .string("u-" + id),
                 "timestamp": .string(end), "cwd": "fixture/project", "sessionId": "shared-session",
                 "isSidechain": .bool(sidechain), "effort": "high",
                 "message": ["id": .string(id), "model": .string(shared),
                             "usage": ["input_tokens": .number(Double(input)), "output_tokens": .number(Double(output)),
                                       "output_tokens_details": ["thinking_tokens": .number(Double(thinking))]]]]
            ]
        }
        var frames = response("before", start: "2026-10-10T10:00:00Z", end: "2026-10-10T10:00:02Z", input: 100, output: 10, thinking: 2)
        frames += response("tail", start: "2026-10-11T00:00:00Z", end: "2026-10-11T00:00:01Z", input: 20, output: 2, thinking: 1, sidechain: true)
        if extra { frames += response("extra", start: "2026-10-12T00:00:00Z", end: "2026-10-12T00:00:02Z", input: 40, output: 4, thinking: 0) }
        return frames
    }
    private var codexFrames: [JSONValue] {
        [
            ["type": "session_meta", "payload": ["id": "shared-session", "cwd": "fixture/project"]],
            ["type": "turn_context", "payload": ["turn_id": "turn", "model": .string(shared), "effort": "high"]],
            ["type": "event_msg", "timestamp": "2026-10-10T10:00:00Z", "payload": ["type": "task_started", "turn_id": "turn"]],
            ["type": "token_usage_record", "timestamp": "2026-10-10T10:00:03Z",
             "payload": ["turn_id": "turn", "response_id": "codex-response",
                         "usage": ["input_tokens": 30, "output_tokens": 3, "reasoning_output_tokens": 1]]]
        ]
    }
    private func cacheDocument(sharedInput: Int = 1000, cacheOnlyInput: Int = 500) -> JSONValue {
        ["lastComputedDate": "2026-10-10", "totalSessions": 7, "totalMessages": 20,
         "modelUsage": [shared: ["inputTokens": .number(Double(sharedInput)), "outputTokens": 100],
                       cacheOnly: ["inputTokens": .number(Double(cacheOnlyInput))]],
         "dailyActivity": [["date": "2026-10-01"]],
         "dailyModelTokens": [["date": "2026-10-01", "tokensByModel": [shared: 100]]]]
    }
    private func events(extra: Bool = false) -> [StatisticsUsage] {
        // Literal independent event oracle, not hydrated from the service's DB
        // or its reused lifetime row. Input files exercise the actual readers.
        func row(_ id: String, source: String, stamp: String, input: Double, output: Double, thinking: Double, duration: Double, sidechain: Bool = false) -> StatisticsUsage {
            var value = StatisticsUsage(id: id, source: source, ts: date(stamp), model: shared)
            value.project = "fixture/project"; value.session = source == "codex" ? "codex:shared-session" : "shared-session"
            value.effort = "high"; value.input = input; value.output = output; value.thinking = thinking
            value.durationMs = duration; value.timing = "estimated"; value.sidechain = sidechain
            return value
        }
        var values = [
            row("before", source: "claude", stamp: "2026-10-10T10:00:02Z", input: 100, output: 10, thinking: 2, duration: 2000),
            row("codex:codex-response", source: "codex", stamp: "2026-10-10T10:00:03Z", input: 30, output: 3, thinking: 1, duration: 3000),
            row("tail", source: "claude", stamp: "2026-10-11T00:00:01Z", input: 20, output: 2, thinking: 1, duration: 1000, sidechain: true)
        ]
        if extra { values.append(row("extra", source: "claude", stamp: "2026-10-12T00:00:02Z", input: 40, output: 4, thinking: 0, duration: 2000)) }
        return values
    }
    private var benchRow: JSONValue {
        ["id": "bench-one", "provider": "p", "provider_name": "Private", "model": .string(shared), "run_id": "fixture-run",
         "ts": "2026-10-10T10:00:00Z", "test": "latency", "ok": true, "timing_ms": ["ttft": 50],
         "tokens": ["in": 7, "out": 2, "reasoning": 1, "cached": 3, "in_est": true]]
    }
    private func fixture() async throws -> Fixture {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("statistics-lifetime-reuse-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let home = root.appendingPathComponent("home"), native = root.appendingPathComponent("native")
        let claude = home.appendingPathComponent(".claude/projects/private/usage.jsonl")
        let codex = home.appendingPathComponent(".codex/sessions/usage.jsonl"), cache = home.appendingPathComponent(".claude/stats-cache.json")
        try put(claudeFrames(), at: claude); try put(codexFrames, at: codex)
        try cacheDocument().encoded().write(to: cache)
        try FileManager.default.createDirectory(at: native, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try JSONValue.object(["providers": []]).encoded().write(to: native.appendingPathComponent("providers.json"))
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: native.appendingPathComponent("providers.json").path)
        try put([benchRow], at: native.appendingPathComponent("data/results.jsonl"))
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let runtime = try NativeRuntime(paths: NativePaths(root: native, home: home))
        await runtime.jobs.suspendForShutdown()
        let clock = now
        let service = NativeStatisticsService(runtime: runtime, environment: [:], calendar: utc, clock: { clock })
        return Fixture(root: root, home: home, claude: claude, codex: codex, cache: cache, runtime: runtime, service: service)
    }
    private func bench(_ model: String) -> JSONValue {
        guard model == shared else {
            return ["spend": ["input": 0, "output": 0, "reasoning": 0, "cached": 0, "calls": 0, "estimated": 0,
                              "runs": 0, "first": .null, "last": .null, "pairs": []], "trend": []]
        }
        let key = "p|" + shared, stamp = "2026-10-10T10:00:00Z"
        return ["spend": ["input": 7, "output": 2, "reasoning": 1, "cached": 3, "calls": 1, "estimated": 1,
                          "runs": 1, "first": .string(stamp), "last": .string(stamp),
                          "pairs": [["key": .string(key), "provider": "p", "providerName": "Private", "model": .string(shared),
                                     "input": 7, "output": 2, "reasoning": 1, "cached": 3, "calls": 1, "estimated": 1]]],
                "trend": [["runId": "fixture-run", "key": .string(key), "label": .string(shared + " · Private"),
                           "at": .number(date(stamp)), "ms": 50, "samples": 1]]]
    }
    private func fallback(model: String, source: String, range: Int = 0, extra: Bool = false, sharedInput: Int = 1000, cacheOnlyInput: Int = 500) throws -> JSONValue {
        let rows = events(extra: extra), cache = try XCTUnwrap(StatisticsCache.parse(cacheDocument(sharedInput: sharedInput, cacheOnlyInput: cacheOnlyInput)))
        // Deliberately omit the new optional row on every oracle invocation.
        var value = try XCTUnwrap(StatisticsFold.detail(rows, range: range, cache: cache, source: source, model: model, now: now, calendar: utc))
        var totals: JSONObject = [:]
        for item in StatisticsSource.allCases {
            let detail = StatisticsFold.detail(rows, range: range, cache: cache, source: item.rawValue, model: model, now: now, calendar: utc)
            totals[item.rawValue] = detail.flatMap { $0["derived"]["events"].int > 0 || $0["coverage"]["lifetime"].bool ? $0["derived"]["summary"]["totals"] : nil } ?? .null
        }
        value["loaded"] = true; value["scanning"] = false; value["model"] = .string(model); value["source"] = .string(source); value["range"] = .number(Double(range))
        value["colors"] = .object([cacheOnly: "#3b82f6", shared: "#f97316"]); value["sources"] = .object(totals); value["bench"] = bench(model)
        return value
    }
    @discardableResult
    private func assertModel(_ f: Fixture, model: String, source: String, range: Int = 0, extra: Bool = false, sharedInput: Int = 1000, cacheOnlyInput: Int = 500, file: StaticString = #filePath, line: UInt = #line) async throws -> JSONValue {
        let actual = try await f.service.handle("model", input: ["model": .string(model), "source": .string(source), "range": .number(Double(range))])
        XCTAssertEqual(actual, try fallback(model: model, source: source, range: range, extra: extra, sharedInput: sharedInput, cacheOnlyInput: cacheOnlyInput), file: file, line: line)
        return actual
    }
    private func grand(_ value: JSONValue) -> Double {
        ["input", "output", "cacheWrite", "cacheRead"].reduce(0) { $0 + value[$1].double }
    }

    func testActualServiceSharedAndCacheOnlyDetailsMatchFallbackAcrossScopesAndCSV() async throws {
        let f = try await fixture()
        let overview = try await f.service.handle("overview")
        XCTAssertEqual(overview["derived"]["events"], 3)
        for source in ["all"] + StatisticsSource.allCases.map(\.rawValue) {
            let common = try await assertModel(f, model: shared, source: source)
            let pruned = try await assertModel(f, model: cacheOnly, source: source)
            XCTAssertEqual(common["sources"]["claude"]["input"], 1020)
            XCTAssertEqual(common["sources"]["codex"]["input"], 30)
            XCTAssertEqual(pruned["derived"]["events"], 0)
            XCTAssertEqual(pruned["sources"]["claude"]["input"], 500)
            XCTAssertTrue(pruned["sources"]["codex"].isNull)
        }
        let all = try await assertModel(f, model: shared, source: "all")
        XCTAssertEqual(grand(all["derived"]["summary"]["totals"]), 1155)
        XCTAssertEqual(grand(all["coverage"]["datedTotals"]), 165)
        XCTAssertEqual(all["derived"]["summary"]["sessions"], 2)
        XCTAssertEqual(all["derived"]["throughput"]["summary"]["durationMs"], 6000)
        XCTAssertEqual(all["derived"]["throughput"]["summary"]["avgTps"], 2.5)
        XCTAssertEqual(all["derived"]["cost"]["usd"].double, 0.007875, accuracy: 1e-15)
        let pruned = try await assertModel(f, model: cacheOnly, source: "all")
        XCTAssertEqual(grand(pruned["derived"]["summary"]["totals"]), 500)
        XCTAssertEqual(pruned["derived"]["summary"]["sessions"], 0)
        XCTAssertTrue(pruned["coverage"]["lifetime"].bool)
        XCTAssertTrue(pruned["derived"]["models"].array.first?["pruned"].bool == true)
        let csv = try await f.service.handle("exportDailyCSV", input: ["model": .string(shared), "source": "all", "range": 0])
        XCTAssertEqual(csv, ["filename": "UniApi-model-daily-usage.csv", "text": .string([
            "date,model,source,input,output,thinking,cacheWrite,cacheRead,messages,webSearch,webFetch,response_avg_tps,timed_responses,timed_output,response_ms,estimated_responses,streaming_tps,stream_timed_responses,stream_output,stream_ms",
            "2026-10-10,\"claude-opus-5\",all,130,13,3,0,0,2,0,0,2.6,2,13,5000,2,,0,0,0",
            "2026-10-11,\"claude-opus-5\",all,20,2,1,0,0,1,0,0,2,1,2,1000,1,,0,0,0"
        ].joined(separator: "\n"))])
    }

    func testModelBeforeOverviewUsesCoherentBoardAndLeavesNonLifetimeScopesExact() async throws {
        let f = try await fixture()
        // No start/overview is called before these real service model requests.
        let first = try await assertModel(f, model: cacheOnly, source: "claude")
        XCTAssertEqual(grand(first["derived"]["summary"]["totals"]), 500)
        XCTAssertEqual(first["datedSummary"]["totals"]["messages"], 0)
        _ = try await assertModel(f, model: shared, source: "all")
        for range in [7, 30, 90, 365] {
            let ranged = try await assertModel(f, model: shared, source: "all", range: range)
            XCTAssertFalse(ranged["coverage"]["lifetime"].bool)
            XCTAssertEqual(grand(ranged["derived"]["summary"]["totals"]), 165)
        }
        let codex = try await assertModel(f, model: shared, source: "codex")
        XCTAssertEqual(grand(codex["derived"]["summary"]["totals"]), 33)
        var unrelated = StatisticsModel(model: "wrong-model"); unrelated.totals.input = 999_999
        let cache = StatisticsCache.parse(cacheDocument())
        for scope in [(0, "codex"), (7, "all"), (30, "claude")] {
            let ordinary = StatisticsFold.detail(events(), range: scope.0, cache: cache, source: scope.1, model: shared, now: now, calendar: utc)
            XCTAssertEqual(StatisticsFold.detail(events(), range: scope.0, cache: cache, source: scope.1, model: shared, now: now, calendar: utc, lifetimeModel: unrelated), ordinary)
        }
    }

    func testSuccessfulUsageAndCacheOnlyRescansReplaceLifetimeRows() async throws {
        let f = try await fixture()
        _ = try await assertModel(f, model: shared, source: "all")
        _ = try await assertModel(f, model: cacheOnly, source: "claude")
        try put(claudeFrames(extra: true), at: f.claude)
        _ = try await f.service.handle("rescan")
        let changed = try await assertModel(f, model: shared, source: "all", extra: true)
        XCTAssertEqual(grand(changed["derived"]["summary"]["totals"]), 1199)
        XCTAssertEqual(changed["derived"]["events"], 4)
        let bytes = try Data(contentsOf: f.claude)
        let oldRows = try f.runtime.db.query("SELECT * FROM stats_records ORDER BY path,msg_id")
        try cacheDocument(sharedInput: 2000, cacheOnlyInput: 900).encoded().write(to: f.cache)
        _ = try await f.service.handle("rescan")
        let newCache = try await assertModel(f, model: shared, source: "all", extra: true, sharedInput: 2000, cacheOnlyInput: 900)
        let pruned = try await assertModel(f, model: cacheOnly, source: "claude", extra: true, sharedInput: 2000, cacheOnlyInput: 900)
        XCTAssertEqual(grand(newCache["derived"]["summary"]["totals"]), 2199)
        XCTAssertEqual(pruned["derived"]["summary"]["totals"]["input"], 900)
        XCTAssertEqual(pruned["derived"]["events"], 0)
        XCTAssertEqual(try Data(contentsOf: f.claude), bytes)
        XCTAssertEqual(try f.runtime.db.query("SELECT * FROM stats_records ORDER BY path,msg_id"), oldRows)
    }

    func testFailedRescanRetainsLifetimeGenerationAndRecovers() async throws {
        let f = try await fixture()
        let before = try await assertModel(f, model: shared, source: "all")
        let oldPruned = try await assertModel(f, model: cacheOnly, source: "claude")
        let rows = try f.runtime.db.query("SELECT * FROM stats_records ORDER BY path,msg_id")
        let files = try f.runtime.db.query("SELECT * FROM stats_files ORDER BY path")
        try put(claudeFrames(extra: true), at: f.claude)
        try cacheDocument(sharedInput: 2000, cacheOnlyInput: 900).encoded().write(to: f.cache)
        let directory = f.codex.deletingLastPathComponent()
        do {
            guard getuid() != 0, chmod(directory.path, 0) == 0 else { throw NativeFailure("Real owned-directory EACCES fixture requires an unprivileged user") }
            defer { XCTAssertEqual(chmod(directory.path, 0o700), 0) }
            XCTAssertThrowsError(try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil))
            do { _ = try await f.service.handle("rescan"); XCTFail("Incomplete discovery must retain the previous lifetime generation") }
            catch { XCTAssertFalse(error is CancellationError) }
            let held = try await assertModel(f, model: shared, source: "all")
            let heldPruned = try await assertModel(f, model: cacheOnly, source: "claude")
            XCTAssertEqual(held, before); XCTAssertEqual(heldPruned, oldPruned)
            XCTAssertEqual(try f.runtime.db.query("SELECT * FROM stats_records ORDER BY path,msg_id"), rows)
            XCTAssertEqual(try f.runtime.db.query("SELECT * FROM stats_files ORDER BY path"), files)
        }
        _ = try await f.service.handle("rescan")
        let recovered = try await assertModel(f, model: shared, source: "all", extra: true, sharedInput: 2000, cacheOnlyInput: 900)
        let recoveredPruned = try await assertModel(f, model: cacheOnly, source: "claude", extra: true, sharedInput: 2000, cacheOnlyInput: 900)
        XCTAssertEqual(grand(recovered["derived"]["summary"]["totals"]), 2199)
        XCTAssertEqual(recoveredPruned["derived"]["summary"]["totals"]["input"], 900)
        XCTAssertEqual(recovered["sources"]["codex"]["input"], 30)
    }
}
