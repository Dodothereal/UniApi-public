import XCTest
import Foundation
import Darwin
@testable import UniApiCore

final class StatisticsTests: XCTestCase {
    private func temp() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("statistics-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }; return root
    }
    private func put(_ data: Data, at url: URL) throws { try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true); try data.write(to: url) }
    private func jsonLines(_ values: [JSONValue], at url: URL) throws { try put(Data(values.map { String(decoding: try! $0.encoded(), as: UTF8.self) }.joined(separator: "\n").utf8), at: url) }
    private func date(_ value: String) -> Double { statisticsTimestamp(.string(value))! }
    private var utc: Calendar { var c = Calendar(identifier: .gregorian); c.timeZone = TimeZone(secondsFromGMT: 0)!; return c }
    private func assistant(_ id: String, at timestamp: String = "2026-10-10T10:00:02Z", model: String = "claude-sonnet-5", input: Double = 100, output: Double = 20) -> JSONValue {
        ["type": "assistant", "uuid": .string("a-" + id), "parentUuid": "u", "timestamp": .string(timestamp), "cwd": "fixture/project", "sessionId": "session", "message": ["id": .string(id), "model": .string(model), "usage": ["input_tokens": .number(input), "output_tokens": .number(output), "cache_creation_input_tokens": 10, "cache_read_input_tokens": 50, "output_tokens_details": ["thinking_tokens": 5], "server_tool_use": ["web_search_requests": 1, "web_fetch_requests": 2]]]]
    }
    private var user: JSONValue { ["type": "user", "uuid": "u", "timestamp": "2026-10-10T10:00:00Z"] }
    private func event(source: String = "claude", id: String = "one", model: String = "claude-sonnet-5", timestamp: String = "2026-10-10T10:00:00Z", input: Double = 100, output: Double = 20) -> StatisticsUsage {
        var e = StatisticsUsage(id: id, source: source, ts: date(timestamp), model: model); e.input = input; e.output = output; e.session = "fixture"; e.project = "project"; return e
    }
    func testClaudeBlocksRetainRawReconciliationAndLastBlockTiming() throws {
        let reader = StatisticsClaudeReader(); reader.push(user); reader.push(assistant("same")); reader.push(assistant("same", at: "2026-10-10T10:00:05Z")); reader.push(assistant("synthetic", model: "<synthetic>"))
        let result = reader.finish(); XCTAssertEqual(result.records.count, 2)
        XCTAssertEqual(result.records[0].durationMs, 5000); XCTAssertEqual(result.records[1].durationMs, 5000)
        XCTAssertEqual(result.records[0].rawDay, "2026-10-10"); XCTAssertEqual(result.records[0].grand, 180)
        XCTAssertEqual(result.records[0].thinking, 5); XCTAssertEqual(result.records[0].webFetch, 2)
    }
    func testCodexModernMirrorsDoNotConsumeNextResponseClock() throws {
        let reader = StatisticsCodexReader()
        reader.push(["type": "session_meta", "payload": ["id": "session", "cwd": "fixture", "source": ["subagent": false]]])
        reader.push(["type": "turn_context", "payload": ["turn_id": "t", "model": "gpt-5.3-codex", "effort": "xhigh"]])
        reader.push(["type": "event_msg", "timestamp": "2026-10-10T10:00:00Z", "payload": ["type": "task_started", "turn_id": "t"]])
        reader.push(["type": "token_usage_record", "timestamp": "2026-10-10T10:00:02Z", "payload": ["turn_id": "t", "response_id": "r1", "usage": ["input_tokens": 100, "output_tokens": 20, "cached_input_tokens": 30, "cache_write_input_tokens": 10, "reasoning_output_tokens": 5]]])
        reader.push(["type": "response_item", "timestamp": "2026-10-10T10:00:03Z", "payload": ["type": "function_call", "call_id": "c"]])
        reader.push(["type": "response_item", "timestamp": "2026-10-10T10:00:10Z", "payload": ["type": "function_call_output", "call_id": "c"]])
        reader.push(["type": "event_msg", "timestamp": "2026-10-10T10:00:11Z", "payload": ["type": "token_count", "info": ["total_token_usage": ["total_tokens": 120], "last_token_usage": ["input_tokens": 100, "output_tokens": 20]]]])
        reader.push(["type": "token_usage_record", "timestamp": "2026-10-10T10:00:12Z", "payload": ["turn_id": "t", "response_id": "r2", "usage": ["input_tokens": 200, "output_tokens": 40]]])
        let rows = reader.finish().records; XCTAssertEqual(rows.count, 2); XCTAssertEqual(rows[0].input, 60); XCTAssertEqual(rows[0].grand, 120)
        XCTAssertEqual(rows[0].durationMs, 2000); XCTAssertEqual(rows[1].durationMs, 2000); XCTAssertFalse(rows[0].sidechain)
        reader.push(["type": "session_meta", "payload": ["id": "sub", "source": ["subagent": [:]]]])
        reader.push(["type": "token_usage_record", "timestamp": "2026-10-10", "payload": ["response_id": "date-only", "usage": ["input_tokens": 1, "output_tokens": 1]]])
        XCTAssertTrue(reader.finish().records.last!.sidechain); XCTAssertEqual(reader.finish().records.last!.ts, date("2026-10-10T00:00:00Z"))
    }
    func testCodexFallbackCheckpointResetAndTurnLocalModernPreference() throws {
        let reader = StatisticsCodexReader()
        reader.push(["type": "turn_context", "payload": ["turn_id": "old", "model": "model"]])
        func checkpoint(_ total: Int, _ ts: String) -> JSONValue { ["type": "event_msg", "timestamp": .string(ts), "payload": ["type": "token_count", "info": ["total_token_usage": ["total_tokens": .number(Double(total))], "last_token_usage": ["input_tokens": 10, "output_tokens": 2]]]] }
        reader.push(checkpoint(12, "2026-10-10T10:00:00Z")); reader.push(checkpoint(12, "2026-10-10T10:00:01Z")); reader.push(checkpoint(6, "2026-10-10T10:00:02Z"))
        reader.push(["type": "turn_context", "payload": ["turn_id": "modern", "model": "model"]])
        reader.push(checkpoint(24, "2026-10-10T10:00:03Z"))
        reader.push(["type": "token_usage_record", "timestamp": "2026-10-10T10:00:04Z", "payload": ["turn_id": "modern", "response_id": "modern", "usage": ["input_tokens": 10, "output_tokens": 2]]])
        let result = reader.finish(); XCTAssertEqual(result.records.count, 3); XCTAssertEqual(Set(result.records.map(\.id)).count, 3)
    }
    func testZCodeCompletedUsageAndUnavailableSchemaTiming() throws {
        let url = try temp().appendingPathComponent("db.sqlite"), db = try NativeDatabase(url: url)
        try db.executeScript("CREATE TABLE session(id TEXT,directory TEXT); INSERT INTO session VALUES('s','fixture/project'); CREATE TABLE model_usage(id TEXT,session_id TEXT,query_source TEXT,model_id TEXT,variant TEXT,agent TEXT,status TEXT,started_at REAL,input_tokens REAL,output_tokens REAL,reasoning_tokens REAL,cache_creation_input_tokens REAL,cache_read_input_tokens REAL);")
        try db.execute("INSERT INTO model_usage VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?)", ["one", "s", "subagent", "glm-5.3-flash", "high", "zcode-general-purpose", "completed", .number(date("2026-10-10T10:00:00Z")), 100, 20, 30, 50, 80])
        try db.execute("INSERT INTO model_usage VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?)", ["failed", "s", "", "model", "", "", "failed", 1, 100, 10, 0, 0, 0])
        let before = try Data(contentsOf: url); let result = try StatisticsImporter.zcode(url)
        XCTAssertEqual(result.records.count, 1); XCTAssertEqual(result.excluded, 1); XCTAssertEqual(result.records[0].input, 0); XCTAssertEqual(result.records[0].cacheWrite, 20); XCTAssertEqual(result.records[0].thinking, 20); XCTAssertTrue(result.records[0].sidechain); XCTAssertNil(result.records[0].durationMs); XCTAssertEqual(try Data(contentsOf: url), before)
    }
    func testZCodeRecordedAndCompletionFallbackTiming() throws {
        let url = try temp().appendingPathComponent("db.sqlite"), db = try NativeDatabase(url: url)
        try db.executeScript("CREATE TABLE model_usage(id TEXT,session_id TEXT,query_source TEXT,model_id TEXT,variant TEXT,agent TEXT,status TEXT,started_at REAL,duration_ms REAL,completed_at REAL,input_tokens REAL,output_tokens REAL,reasoning_tokens REAL,cache_creation_input_tokens REAL,cache_read_input_tokens REAL);")
        let at = date("2026-10-10T10:00:00Z")
        try db.execute("INSERT INTO model_usage VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)", ["one", "s", "", "model", "", "", "completed", .number(at), 1500, .number(at + 4000), 10, 20, 0, 0, 0])
        try db.execute("INSERT INTO model_usage VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)", ["two", "s", "", "model", "", "", "completed", .number(at), .null, .number(at + 4000), 10, 20, 0, 0, 0])
        XCTAssertEqual(try StatisticsImporter.zcode(url).records.map(\.durationMs), [1500, 4000])
    }
    func testOpenCodeReasoningNormalizationAndToolTimingExclusion() throws {
        let url = try temp().appendingPathComponent("opencode.db"), db = try NativeDatabase(url: url)
        try db.executeScript("CREATE TABLE session(id TEXT,directory TEXT,parent_id TEXT); INSERT INTO session VALUES('s','fixture','parent'); CREATE TABLE message(id TEXT,session_id TEXT,time_created REAL,data TEXT); CREATE TABLE part(message_id TEXT,data TEXT);")
        let data: JSONValue = ["role": "assistant", "modelID": "glm-5.3-flash", "variant": "high", "cost": 99999, "time": ["created": 1000, "completed": 3000], "tokens": ["input": 10, "output": 20, "reasoning": 5, "cache": ["read": 30, "write": 2]]]
        let text = String(decoding: try data.encoded(), as: UTF8.self)
        try db.execute("INSERT INTO message VALUES(?,?,?,?)", ["tool", "s", 1000, .string(text)]); try db.execute("INSERT INTO part VALUES(?,?)", ["tool", "{\"type\":\"tool\"}"])
        try db.execute("INSERT INTO message VALUES(?,?,?,?)", ["text", "s", 1000, .string(text)]); try db.execute("INSERT INTO part VALUES(?,?)", ["text", "{\"type\":\"text\"}"])
        try db.execute("INSERT INTO message VALUES(?,?,?,?)", ["bad", "s", 1000, "not-json"])
        let result = try StatisticsImporter.opencode(url); XCTAssertEqual(result.excluded, 1); XCTAssertEqual(result.records.count, 2)
        XCTAssertEqual(result.records[0].output, 25); XCTAssertEqual(result.records[0].grand, 67); XCTAssertNil(result.records[0].durationMs); XCTAssertEqual(result.records[1].durationMs, 2000); XCTAssertTrue(result.records[0].sidechain)
    }
    private func varint(_ value: UInt64) -> Data { var v = value, out = Data(); repeat { let b = UInt8(v & 127); v >>= 7; out.append(b | (v > 0 ? 128 : 0)) } while v > 0; return out }
    private func field(_ n: UInt64, _ value: UInt64) -> Data { varint(n << 3) + varint(value) }
    private func field(_ n: UInt64, bytes: Data) -> Data { varint((n << 3) | 2) + varint(UInt64(bytes.count)) + bytes }
    private func agGeneration() -> Data {
        let usage = field(2, 100) + field(3, 20) + field(4, 10) + field(5, 30) + field(9, 5) + field(11, bytes: Data("request".utf8))
        let stamp = field(1, 1_791_626_400), nested = field(4, bytes: stamp)
        let chat = field(4, bytes: usage) + field(9, bytes: nested) + field(19, bytes: Data("gemini-3.8-flash".utf8)) + field(11, bytes: field(1, 1)) + field(12, bytes: field(1, 2))
        return field(1, bytes: chat)
    }
    func testAntigravityBoundedProtobufAndGenerationClock() throws {
        let e = try XCTUnwrap(StatisticsImporter.generation(agGeneration(), steps: [:], session: "s", project: "fixture", sidechain: true))
        XCTAssertEqual(e.model, "gemini-3.8-flash"); XCTAssertEqual(e.grand, 160); XCTAssertEqual(e.durationMs, 3000); XCTAssertEqual(e.thinking, 5)
        XCTAssertThrowsError(try StatisticsWire(Data([0x12, 0xff])))
        XCTAssertThrowsError(try StatisticsWire(Data([0])))
    }
    func testAntigravitySQLiteMetadataSnapshot() throws {
        let url = try temp().appendingPathComponent("conversation.db"), db = try NativeDatabase(url: url)
        let meta = field(7, bytes: Data("file:///fixture/project".utf8)) + field(5, bytes: Data("parent".utf8))
        func hex(_ data: Data) -> String { data.map { String(format: "%02x", $0) }.joined() }
        try db.executeScript("CREATE TABLE trajectory_metadata_blob(data BLOB); CREATE TABLE trajectory_meta(trajectory_id TEXT); CREATE TABLE steps(idx INTEGER,metadata BLOB); CREATE TABLE gen_metadata(idx INTEGER,data BLOB); INSERT INTO trajectory_metadata_blob VALUES(X'\(hex(meta))'); INSERT INTO trajectory_meta VALUES('trajectory'); INSERT INTO gen_metadata VALUES(0,X'\(hex(agGeneration()))');")
        let result = try StatisticsImporter.antigravity(url); XCTAssertEqual(result.records.count, 1); XCTAssertEqual(result.records[0].project, "/fixture/project"); XCTAssertEqual(result.records[0].session, "antigravity:trajectory"); XCTAssertTrue(result.records[0].sidechain)
    }
    func testLifetimeUTCTailCombinedSourcesAndExactModelCoverage() throws {
        let cache = try XCTUnwrap(StatisticsCache.parse(["lastComputedDate": "2026-10-10", "totalSessions": 7, "totalMessages": 20, "modelUsage": ["shared": ["inputTokens": 1000, "outputTokens": 100], "pruned": ["inputTokens": 500]], "dailyActivity": [["date": "2026-10-01"]], "dailyModelTokens": [["date": "2026-10-01", "tokensByModel": ["shared": 100]]]]))
        let events = [event(model: "shared", input: 100, output: 10), event(id: "tail", model: "shared", timestamp: "2026-10-11T00:00:01Z", input: 20, output: 2), event(source: "codex", model: "shared", input: 30, output: 3)]
        let now = date("2026-10-13T00:00:00Z"), d = StatisticsFold.sources(events, range: 0, cache: cache, source: "all", now: now, calendar: utc)
        XCTAssertEqual(d.summary.totals.grand, 1655); XCTAssertEqual(d.summary.sessions, 8)
        XCTAssertEqual(d.models.first { $0.model == "shared" }?.totals.grand, 1155); XCTAssertTrue(d.models.first { $0.model == "pruned" }!.pruned)
        let detail = try XCTUnwrap(StatisticsFold.detail(events, range: 0, cache: cache, source: "all", model: "shared", now: now, calendar: utc))
        XCTAssertEqual(nativeGrand(detail["derived"]["summary"]["totals"]), 1155); XCTAssertEqual(detail["coverage"]["datedTotals"]["messages"].int, 3); XCTAssertEqual(detail["derived"]["summary"]["sessions"].int, 2)
        XCTAssertEqual(detail["derived"]["days"].array.count, 2)
    }
    private func nativeGrand(_ t: JSONValue) -> Double { t["input"].double + t["output"].double + t["cacheRead"].double + t["cacheWrite"].double }
    func testInvalidWatermarkConservativeModelFallback() throws {
        let cache = try XCTUnwrap(StatisticsCache.parse(["lastComputedDate": "2026-99-99", "totalMessages": 7, "modelUsage": ["model": ["inputTokens": 1000]]]))
        let d = StatisticsFold.derive([event(model: "model", input: 20)], range: 0, cache: cache, now: date("2026-10-13T00:00:00Z"), calendar: utc)
        XCTAssertEqual(d.summary.totals.input, 1000); XCTAssertEqual(d.models[0].totals.input, 1000); XCTAssertEqual(d.days.count, 1)
    }
    func testPricingCacheDiscountReasoningAndUnknownCoverage() {
        var known = StatisticsModel(model: "claude-opus-5"); known.totals.input = 1_000_000; known.totals.output = 1_000_000; known.totals.thinking = 999_999; known.totals.cacheRead = 1_000_000; known.totals.cacheWrite = 1_000_000
        var missing = StatisticsModel(model: "unknown"); missing.totals.input = 123
        let cost = StatisticsPricing.fold([known, missing]); XCTAssertEqual(cost["usd"].double, 36.75, accuracy: 0.00001); XCTAssertEqual(cost["unpricedTokens"].double, 123)
        XCTAssertEqual(StatisticsPricing.normalize("uniapi/example/%63laude-opus-5"), "claude-opus-5"); XCTAssertTrue(StatisticsPricing.rate("claude-opus-4-5-20251101")!.1); XCTAssertNil(StatisticsPricing.rate("claude-opus-4-5-thinking"))
    }
    func testPricingPartialCacheRatesAndOneDecodedTransportNamespace() {
        var model = StatisticsModel(model: "glm-5.3")
        model.totals.input = 1_000_000; model.totals.output = 1_000_000
        model.totals.cacheRead = 1_000_000; model.totals.cacheWrite = 1_000_000
        let partial = StatisticsPricing.fold([model])
        XCTAssertEqual(partial["usd"].double, 6.06, accuracy: 1e-10)
        XCTAssertEqual(partial["pricedTokens"].double, 3_000_000)
        XCTAssertEqual(partial["unpricedTokens"].double, 1_000_000)
        XCTAssertTrue(partial["rows"].array[0]["components"]["cacheWrite"]["usd"].isNull)
        XCTAssertTrue(partial["rows"].array[0]["reason"].string.contains("partial"))
        XCTAssertEqual(StatisticsPricing.normalize("uniapi/command-code/Qwen%2FQwen3.8-Max-0902"), "qwen3.8-max-0902")
        XCTAssertNil(StatisticsPricing.rate("uniapi/example/qwen%252fqwen3.8-max-0902"))
        XCTAssertNil(StatisticsPricing.rate("uniapi//claude-opus-5"))
    }
    func testPricingRejectsUnknownIdentitiesAndInvalidCountsWithoutInventingBills() {
        var invalid = StatisticsModel(model: "claude-opus-5")
        invalid.totals.input = -1; invalid.totals.output = 19
        var unknown = StatisticsModel(model: "unknown"); unknown.totals.input = 7
        let cost = StatisticsPricing.fold([invalid, unknown])
        XCTAssertEqual(cost["usd"].double, 0); XCTAssertEqual(cost["pricedTokens"].double, 0)
        XCTAssertEqual(cost["unpricedTokens"].double, 26); XCTAssertTrue(cost["billedUsd"].isNull)
        XCTAssertTrue(cost["rows"].array.allSatisfy { $0["usd"].isNull })
        XCTAssertTrue(cost["rows"].array[0]["reason"].string.contains("Invalid"))
        XCTAssertNil(StatisticsPricing.rate("chatgpt-web/pro"))
        XCTAssertNil(StatisticsPricing.rate("deepseek-v4-flash"))
        XCTAssertNil(StatisticsPricing.rate("uniapi/random-x/DeepSeek-V4-Flash"))
        XCTAssertNil(StatisticsPricing.rate("claude-opus-5-5-high"))
        XCTAssertEqual(StatisticsPricing.rate("gpt-5.3-codex")?.0.input, 1.75)
        XCTAssertEqual(StatisticsPricing.rate("gpt-6.1-sol")?.0.read, 0.1)
        XCTAssertEqual(StatisticsPricing.rate("gpt-6-sol")?.0.read, 0.2)
        XCTAssertEqual(StatisticsPricing.normalize("stealth/ox-alpha"), "glm-5.3-flash")
    }
    func testWeightedTimingAndUnavailableOutputs() {
        var one = event(output: 100); one.durationMs = 1000; one.timing = "estimated"
        var two = event(source: "zcode", id: "two", output: 100); two.durationMs = 3000; two.timing = "recorded"
        let missing = event(id: "untimed", output: 9000), data = StatisticsFold.throughput([one, two, missing], calendar: utc)
        XCTAssertEqual(data["summary"]["avgTps"].double, 50); XCTAssertEqual(data["summary"]["outputTokens"].double, 200); XCTAssertEqual(data["summary"]["timedResponses"].int, 2); XCTAssertEqual(data["summary"]["totalResponses"].int, 3); XCTAssertEqual(data["summary"]["estimatedResponses"].int, 1)
        XCTAssertTrue(StatisticsFold.throughput([missing], calendar: utc)["summary"]["avgTps"].isNull)
    }
    func testDSTLocalDayHeatAndSevenDayCutoff() {
        var c = utc; c.timeZone = TimeZone(identifier: "Europe/Berlin")!
        let events = [event(timestamp: "2026-10-25T00:30:00Z"), event(id: "two", timestamp: "2026-10-25T01:30:00Z")]
        let d = StatisticsFold.derive(events, range: 7, now: date("2026-10-26T10:00:00Z"), calendar: c)
        XCTAssertEqual(d.days.count, 1); XCTAssertEqual(d.heat[6][2], 2); XCTAssertEqual(d.summary.activeDays, 1)
    }
    func testServiceIncrementalPersistenceDedupAndCSVWithoutRealStores() async throws {
        let root = try temp(), home = root.appendingPathComponent("home"), file = home.appendingPathComponent(".claude/projects/project/a.jsonl")
        try jsonLines([user, assistant("same"), assistant("same", at: "2026-10-10T10:00:05Z")], at: file)
        let runtime = try NativeRuntime(paths: NativePaths(root: root, home: home)); let clock = StatisticsFixtureClock(date("2026-10-13T00:00:00Z"))
        let service = NativeStatisticsService(runtime: runtime, environment: [:], calendar: utc, clock: { clock.now() })
        try await service.start(); let first = try await service.handle("overview")
        XCTAssertEqual(first["scan"]["duplicates"].int, 1); XCTAssertEqual(first["derived"]["events"].int, 1); XCTAssertEqual(first["scan"]["rawGrand"].double, 360)
        let sourceBefore = try Data(contentsOf: file); let rows = try runtime.db.query("SELECT * FROM stats_records"); XCTAssertEqual(rows.count, 2)
        clock.advance(31_000); try await service.start(); let warm = try await service.handle("overview")
        XCTAssertEqual(warm["scan"]["parsedFiles"].int, 0); XCTAssertEqual(try Data(contentsOf: file), sourceBefore)
        let csv = try await service.handle("exportDailyCSV", input: ["model": "claude-sonnet-5", "source": "all", "range": 0])
        XCTAssertTrue(csv["text"].string.contains("response_avg_tps,timed_responses,timed_output,response_ms,estimated_responses,streaming_tps,stream_timed_responses,stream_output,stream_ms")); XCTAssertTrue(csv["text"].string.contains("\"claude-sonnet-5\"")); XCTAssertTrue(csv["text"].string.contains(",4,1,20,5000,1"))
        try FileManager.default.removeItem(at: file); _ = try await service.handle("rescan")
        let empty = try await service.handle("overview"); XCTAssertEqual(empty["derived"]["events"].int, 0); XCTAssertTrue(try runtime.db.query("SELECT * FROM stats_files").isEmpty)
    }
    func testSourceScopedDedupAndOpenCodeLiveStoreSelection() async throws {
        let root = try temp(), home = root.appendingPathComponent("home"), dir = home.appendingPathComponent(".local/share/opencode")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        for name in ["opencode.db", "opencode-backup.db"] {
            let db = try NativeDatabase(url: dir.appendingPathComponent(name)); try db.executeScript("CREATE TABLE message(id TEXT,session_id TEXT,time_created REAL,data TEXT);")
            let row: JSONValue = ["role": "assistant", "modelID": "model", "time": ["created": 1000], "tokens": ["input": name == "opencode.db" ? 10 : 999]]
            try db.execute("INSERT INTO message VALUES(?,?,?,?)", ["same", "s", 1000, .string(String(decoding: try row.encoded(), as: UTF8.self))])
        }
        try jsonLines([assistant("same", model: "model")], at: home.appendingPathComponent(".claude/projects/p/a.jsonl"))
        let runtime = try NativeRuntime(paths: NativePaths(root: root, home: home)), service = NativeStatisticsService(runtime: runtime)
        let value = try await service.handle("overview"); XCTAssertEqual(value["derived"]["events"].int, 2); XCTAssertEqual(value["sources"]["opencode"]["input"].double, 10)
        let empty = try await service.handle("model", input: ["model": "model", "source": "codex"]); XCTAssertEqual(empty["derived"]["events"].int, 0); XCTAssertTrue(empty["sources"]["codex"].isNull)
    }
    func testOpenCodeFallbackIgnoresNewerDirectoriesAndLinksWithoutChangingBarePrecedence() async throws {
        let root = try temp(), home = root.appendingPathComponent("home")
        let directory = home.appendingPathComponent(".local/share/opencode")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        func seed(_ file: URL, input: Int, modified: TimeInterval) throws {
            do {
                let db = try NativeDatabase(url: file)
                try db.executeScript("CREATE TABLE message(id TEXT,session_id TEXT,time_created REAL,data TEXT);")
                let row: JSONValue = ["role": "assistant", "modelID": "fallback-model", "time": ["created": 1000], "tokens": ["input": .number(Double(input))]]
                try db.execute("INSERT INTO message VALUES(?,?,?,?)", ["same", "session", 1000, .string(String(decoding: try row.encoded(), as: UTF8.self))])
            }
            try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: modified)], ofItemAtPath: file.path)
        }
        try seed(directory.appendingPathComponent("opencode-old.db"), input: 999, modified: 1_700_000_000)
        try seed(directory.appendingPathComponent("opencode-live.db"), input: 19, modified: 1_700_000_100)
        let newerDirectory = directory.appendingPathComponent("opencode-scratch.db")
        try FileManager.default.createDirectory(at: newerDirectory, withIntermediateDirectories: false)
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 1_700_000_200)], ofItemAtPath: newerDirectory.path)
        let runtime = try NativeRuntime(paths: NativePaths(root: root, home: home)), service = NativeStatisticsService(runtime: runtime)
        func assertLiveStore(_ value: JSONValue, file: String, input: Double) throws {
            XCTAssertTrue(value["warnings"].array.isEmpty)
            XCTAssertEqual(value["scan"]["files"].int, 1)
            XCTAssertEqual(value["derived"]["events"].int, 1)
            XCTAssertEqual(value["sources"]["opencode"]["input"].double, input)
            let cached = try runtime.db.query("SELECT path FROM stats_files")
            XCTAssertEqual(cached.count, 1)
            XCTAssertEqual(cached.first.map { URL(fileURLWithPath: ($0["path"] ?? .null).string).lastPathComponent }, file)
        }
        try assertLiveStore(try await service.handle("overview"), file: "opencode-live.db", input: 19)
        let target = root.appendingPathComponent("external-target.db")
        try seed(target, input: 9999, modified: 1_700_000_300)
        try FileManager.default.createSymbolicLink(at: directory.appendingPathComponent("opencode-link.db"), withDestinationURL: target)
        _ = try await service.handle("rescan")
        try assertLiveStore(try await service.handle("overview"), file: "opencode-live.db", input: 19)
        let bare = directory.appendingPathComponent("opencode.db")
        try FileManager.default.createDirectory(at: bare, withIntermediateDirectories: false)
        _ = try await service.handle("rescan")
        let blocked = try await service.handle("overview")
        XCTAssertEqual(blocked["scan"]["files"].int, 0)
        XCTAssertEqual(blocked["derived"]["events"].int, 0)
        XCTAssertTrue(try runtime.db.query("SELECT path FROM stats_files").isEmpty)
        try FileManager.default.removeItem(at: bare)
        try seed(bare, input: 7, modified: 1_699_999_900)
        _ = try await service.handle("rescan")
        try assertLiveStore(try await service.handle("overview"), file: "opencode.db", input: 7)
    }
    func testBenchmarkFailuresDedupMedianAndCSVUnknownSpeed() async throws {
        let root = try temp(), home = root.appendingPathComponent("home")
        try jsonLines([assistant("record", model: "quoted,\"model")], at: home.appendingPathComponent(".claude/projects/p/a.jsonl"))
        let one: JSONValue = ["id": "same", "provider": "p", "model": "quoted,\"model", "run_id": "r", "ts": "2026-10-10T10:00:00Z", "test": "latency", "ok": true, "timing_ms": ["ttft": 100], "tokens": ["in": 10, "out": 20, "reasoning": 3, "in_est": true]]
        var two = one; two["id"] = "two"; two["timing_ms"] = ["ttft": 300]
        var failed = one; failed["id"] = "failed"; failed["ok"] = false
        try jsonLines([one, two, failed], at: root.appendingPathComponent("data/results.jsonl")); try jsonLines([one], at: root.appendingPathComponent("data/bench/results/results.jsonl"))
        let runtime = try NativeRuntime(paths: NativePaths(root: root, home: home)), service = NativeStatisticsService(runtime: runtime)
        let bench = try await service.handle("bench"); XCTAssertEqual(bench["spend"]["calls"].int, 3); XCTAssertEqual(bench["spend"]["input"].double, 30); XCTAssertEqual(bench["trend"].array[0]["ms"].double, 200)
        let csv = try await service.handle("exportDailyCSV", input: ["model": "quoted,\"model"])
        XCTAssertTrue(csv["text"].string.contains("\"quoted,\"\"model\"")); XCTAssertTrue(csv["text"].string.contains(",,0,0,0,0"))
    }
    func testRescanRefreshesBenchmarkSpendWhenLedgerMetadataIsUnchangedAndClaudeHistoryIsAbsent() async throws {
        let root = try temp(), home = root.appendingPathComponent("home"), ledger = root.appendingPathComponent("data/results.jsonl")
        let row: JSONValue = ["id": "restored-ledger", "provider": "fixture", "model": "fixture-model", "run_id": "one", "ts": "2026-10-10T10:00:00Z", "ok": true, "tokens": ["in": 13, "out": 6]]
        try jsonLines([row], at: ledger)
        let runtime = try NativeRuntime(paths: NativePaths(root: root, home: home)), service = NativeStatisticsService(runtime: runtime)
        let first = try await service.handle("bench")
        XCTAssertEqual(first["spend"]["input"].double, 13)
        var original = stat()
        XCTAssertEqual(lstat(ledger.path, &original), 0)
        let before = try URL(fileURLWithPath: ledger.path).resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
        var rewritten = row; rewritten["tokens"] = ["in": 19, "out": 6]
        try jsonLines([rewritten], at: ledger)
        let times = [original.st_atimespec, original.st_mtimespec]
        XCTAssertEqual(times.withUnsafeBufferPointer { utimensat(AT_FDCWD, ledger.path, $0.baseAddress, 0) }, 0)
        let after = try URL(fileURLWithPath: ledger.path).resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
        XCTAssertEqual(before.fileSize, after.fileSize)
        XCTAssertEqual(before.contentModificationDate?.timeIntervalSince1970.bitPattern, after.contentModificationDate?.timeIntervalSince1970.bitPattern)
        let onDisk = try String(contentsOf: ledger, encoding: .utf8).split(separator: "\n").map { try JSONValue.decode(Data($0.utf8)) }
        XCTAssertEqual(onDisk.count, 1); XCTAssertEqual(onDisk.first?["tokens"]["in"].double, 19)
        let cached = try await service.handle("bench")
        XCTAssertEqual(cached["spend"]["input"].double, 13, "The ordinary metadata cache must be warm before testing forced refresh")
        _ = try await service.handle("rescan")
        let refreshed = try await service.handle("bench"), overview = try await service.handle("overview")
        XCTAssertEqual(refreshed["spend"]["input"].double, 19)
        XCTAssertEqual(refreshed["spend"]["output"].double, 6); XCTAssertEqual(refreshed["spend"]["calls"].int, 1)
        XCTAssertTrue(overview["loaded"].bool); XCTAssertEqual(overview["derived"]["events"].int, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: home.appendingPathComponent(".claude").path))
    }
    func testBenchmarkDedupUsesTheEntireRecordWhenIDsAreMissing() async throws {
        let root = try temp(), home = root.appendingPathComponent("home")
        let first: JSONValue = ["aaa": .string(String(repeating: "padding", count: 100)), "provider": "p", "model": "fixture", "run_id": "one", "ts": "2026-10-10T10:00:00Z", "ok": true, "tokens": ["in": 10, "out": 20]]
        var second = first; second["run_id"] = "two"; second["tokens"] = ["in": 30, "out": 40]
        try jsonLines([first, second], at: root.appendingPathComponent("data/results.jsonl"))
        try jsonLines([first], at: root.appendingPathComponent("data/bench/results/results.jsonl"))
        let runtime = try NativeRuntime(paths: NativePaths(root: root, home: home)), service = NativeStatisticsService(runtime: runtime)
        let result = try await service.handle("bench")
        XCTAssertEqual(result["spend"]["calls"], 2)
        XCTAssertEqual(result["spend"]["input"], 40)
        XCTAssertEqual(result["spend"]["output"], 60)
    }
    func testReadOnlyChangedFileKeepsLexicalDedupPrecedenceAndCacheUnchanged() async throws {
        let root = try temp(), home = root.appendingPathComponent("home")
        let a = home.appendingPathComponent(".claude/projects/p/a.jsonl"), b = home.appendingPathComponent(".claude/projects/p/b.jsonl")
        try jsonLines([assistant("shared", input: 100)], at: a)
        try jsonLines([assistant("shared", input: 900)], at: b)
        let initial = try NativeRuntime(paths: NativePaths(root: root, home: home)), builder = NativeStatisticsService(runtime: initial)
        _ = try await builder.handle("overview")
        let before = try initial.db.query("SELECT * FROM stats_records ORDER BY path,rowid")
        try jsonLines([assistant("shared", input: 200), assistant("new", input: 300)], at: a)
        let reader = try NativeRuntime(paths: NativePaths(root: root, home: home, readOnly: true)), service = NativeStatisticsService(runtime: reader)
        let value = try await service.handle("overview")
        XCTAssertEqual(value["derived"]["events"], 2)
        XCTAssertEqual(value["derived"]["summary"]["totals"]["input"], 500)
        XCTAssertEqual(try initial.db.query("SELECT * FROM stats_records ORDER BY path,rowid"), before)
    }
    func testCachedSummaryDoesNotDiscoverOrImportSources() async throws {
        let root = try temp(), runtime = try NativeRuntime(paths: NativePaths(root: root, home: root))
        let service = NativeStatisticsService(runtime: runtime)
        let result = service.cachedSummary(); XCTAssertFalse(result["loaded"].bool)
        XCTAssertTrue(try runtime.db.query("SELECT name FROM sqlite_master WHERE name='stats_records'").isEmpty)
    }
    func testNodeTimestampCacheSurvivesFoundationEpochPrecisionDifferences() async throws {
        let root = try temp(), home = root.appendingPathComponent("home"), file = home.appendingPathComponent(".claude/projects/p/a.jsonl")
        try jsonLines([assistant("precision")], at: file)
        var times = [timespec(tv_sec: 1700000000, tv_nsec: 123456789), timespec(tv_sec: 1700000000, tv_nsec: 123456789)]
        XCTAssertEqual(times.withUnsafeMutableBufferPointer { utimensat(AT_FDCWD, file.path, $0.baseAddress, 0) }, 0)
        let runtime = try NativeRuntime(paths: NativePaths(root: root, home: home)), writer = NativeStatisticsService(runtime: runtime)
        _ = try await writer.handle("overview")
        var info = stat(); XCTAssertEqual(lstat(file.path, &info), 0)
        let nodeMilliseconds = Double(info.st_mtimespec.tv_sec) * 1000 + Double(info.st_mtimespec.tv_nsec) / 1e6
        try runtime.db.execute("UPDATE stats_files SET mtime=? WHERE path=?", [.number(nodeMilliseconds), .string(file.path)])
        let reader = try NativeRuntime(paths: NativePaths(root: root, home: home, readOnly: true)), service = NativeStatisticsService(runtime: reader)
        let value = try await service.handle("overview")
        XCTAssertEqual(value["scan"]["parsedFiles"], 0)
        XCTAssertEqual(value["derived"]["events"], 1)
    }
    func testUsageProjectionPreservesAccountingAndClockEdgesWithoutPromptBodies() throws {
        var first = assistant("projected")
        first["message"]["content"] = [["type": "text", "text": .string(String(repeating: "private unused prompt", count: 10000))]]
        let projected = try JSONDecoder().decode(StatisticsEnvelope.self, from: first.encoded()).value
        XCTAssertTrue(projected["message"]["content"].isNull)
        let full = StatisticsClaudeReader(), lean = StatisticsClaudeReader()
        full.push(user); lean.push(try JSONDecoder().decode(StatisticsEnvelope.self, from: user.encoded()).value)
        full.push(first); lean.push(projected)
        let a = full.finish().records, b = lean.finish().records
        XCTAssertEqual(a.first?.grand, b.first?.grand); XCTAssertEqual(a.first?.durationMs, b.first?.durationMs); XCTAssertEqual(a.first?.thinking, b.first?.thinking)
        let tool: JSONValue = ["type": "response_item", "timestamp": "2026-10-10T10:00:02Z", "payload": ["type": "function_call_output", "call_id": "fixture", "output": .string(String(repeating: "irrelevant", count: 10000))]]
        let edge = try JSONDecoder().decode(StatisticsEnvelope.self, from: tool.encoded()).value
        XCTAssertEqual(edge["payload"]["call_id"], "fixture"); XCTAssertTrue(edge["payload"]["output"].isNull)
        XCTAssertThrowsError(try JSONDecoder().decode(StatisticsEnvelope.self, from: Data("{\"type\":\"event_msg\",\"ignored\": [}".utf8)))
    }
}

private final class StatisticsFixtureClock: @unchecked Sendable {
    private let lock = NSLock(); private var value: Double
    init(_ value: Double) { self.value = value }
    func now() -> Double { lock.lock(); defer { lock.unlock() }; return value }
    func advance(_ ms: Double) { lock.lock(); value += ms; lock.unlock() }
}
