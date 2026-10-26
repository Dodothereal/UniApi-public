import XCTest
import Darwin
@testable import UniApiCore

final class StatisticsStreamingCacheTests: XCTestCase {
    private func fixture() throws -> (URL, NativeRuntime) {
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("stream-cache-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
        let root = temporary.resolvingSymlinksInPath()
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return (root, try NativeRuntime(paths: NativePaths(root: root, home: root.appendingPathComponent("home"))))
    }
    private func integer(_ value: UInt64) -> Data {
        var value = value, data = Data()
        repeat { let byte = UInt8(value & 127); value >>= 7; data.append(byte | (value > 0 ? 128 : 0)) } while value > 0
        return data
    }
    private func wire(_ field: UInt64, _ value: UInt64) -> Data { integer(field << 3) + integer(value) }
    private func wire(_ field: UInt64, bytes: Data) -> Data { integer(field << 3 | 2) + integer(UInt64(bytes.count)) + bytes }
    private func seed(_ runtime: NativeRuntime) throws {
        let file = runtime.paths.home.appendingPathComponent(".gemini/antigravity/conversations/one.db")
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        let db = try NativeDatabase(url: file)
        let usage = wire(2, 10) + wire(3, 100) + wire(9, 40) + wire(11, bytes: Data("one".utf8))
        let chat = wire(4, bytes: usage) + wire(19, bytes: Data("fixture-model".utf8))
            + wire(9, bytes: wire(4, bytes: wire(1, 1791720000)))
            + wire(11, bytes: wire(1, 10)) + wire(12, bytes: wire(1, 2))
        let bytes = wire(1, bytes: chat).map { String(format: "%02x", $0) }.joined()
        try db.executeScript("CREATE TABLE trajectory_metadata_blob(data BLOB); CREATE TABLE trajectory_meta(trajectory_id TEXT); CREATE TABLE steps(idx INTEGER,metadata BLOB); CREATE TABLE gen_metadata(idx INTEGER,data BLOB); INSERT INTO gen_metadata VALUES(0,X'\(bytes)');")
    }
    func testStreamingPairSurvivesWritableCacheAndColdReadWithoutReparse() async throws {
        let (_, runtime) = try fixture(); try seed(runtime)
        let first = try await NativeStatisticsService(runtime: runtime).handle("overview", input: ["source": "antigravity"])
        let cached = try XCTUnwrap(runtime.db.query("SELECT stream_duration_ms,stream_output_tokens,stream_timing,duration_ms FROM stats_records").first)
        XCTAssertEqual(cached["stream_duration_ms"], 2000); XCTAssertEqual(cached["stream_output_tokens"], 100)
        XCTAssertEqual(cached["stream_timing"], "antigravity-stream-duration"); XCTAssertEqual(cached["duration_ms"], 12000)
        let second = try await NativeStatisticsService(runtime: runtime).handle("overview", input: ["source": "antigravity"])
        XCTAssertEqual(second["scan"]["parsedFiles"], 0)
        XCTAssertEqual(first["derived"], second["derived"])
        XCTAssertEqual(second["derived"]["throughput"]["streaming"]["summary"]["avgTps"], 50)
    }
    func testReadOnlyOldSchemaGetsStreamFromSourceWithoutChangingCacheOrMigration() async throws {
        let (root, runtime) = try fixture(); try seed(runtime)
        _ = try await NativeStatisticsService(runtime: runtime).handle("overview")
        try runtime.db.executeScript("ALTER TABLE stats_records DROP COLUMN stream_duration_ms; ALTER TABLE stats_records DROP COLUMN stream_output_tokens; ALTER TABLE stats_records DROP COLUMN stream_timing; DELETE FROM schema_migrations WHERE name='stats-streaming-1';")
        let columns = try runtime.db.query("PRAGMA table_info(stats_records)"), rows = try runtime.db.query("SELECT * FROM stats_records"), files = try runtime.db.query("SELECT * FROM stats_files"), migrations = try runtime.db.query("SELECT * FROM schema_migrations ORDER BY name")
        let readonly = try NativeRuntime(paths: NativePaths(root: root, home: runtime.paths.home, readOnly: true))
        let value = try await NativeStatisticsService(runtime: readonly).handle("overview", input: ["source": "antigravity"])
        XCTAssertEqual(value["scan"]["parsedFiles"], 1)
        XCTAssertEqual(value["derived"]["throughput"]["streaming"]["summary"]["avgTps"], 50)
        XCTAssertEqual(try runtime.db.query("PRAGMA table_info(stats_records)"), columns)
        XCTAssertEqual(try runtime.db.query("SELECT * FROM stats_records"), rows)
        XCTAssertEqual(try runtime.db.query("SELECT * FROM stats_files"), files)
        XCTAssertEqual(try runtime.db.query("SELECT * FROM schema_migrations ORDER BY name"), migrations)
    }
    func testDeepSeekHomeUsesPrivateHomeAndMatchesBlankAndTildeOverrides() throws {
        let (_, runtime) = try fixture(), paths = runtime.paths
        for value in ["", "  ", "\n"] { XCTAssertEqual(paths.statisticsDeepSeekHome(environment: ["DSH_HOME": value]), paths.home.appendingPathComponent(".dsh", isDirectory: true)) }
        XCTAssertEqual(paths.statisticsDeepSeekHome(environment: ["DSH_HOME": "~"]), paths.home)
        XCTAssertEqual(paths.statisticsDeepSeekHome(environment: ["DSH_HOME": "~/alternate"]), paths.home.appendingPathComponent("alternate", isDirectory: true))
        XCTAssertEqual(paths.statisticsDeepSeekHome(environment: ["DSH_HOME": "~\\alternate"]), paths.home.appendingPathComponent("alternate", isDirectory: true))
    }
    func testLegacyCachedColumnProjectionLeavesStreamingUnknown() {
        let columns = StatisticsCachedRecordColumns(["msg_id", "source", "ts", "model", "output", "duration_ms", "timing"])
        let row = columns.usage(in: ["one", "codex", 1791720000000, "fixture-model", 100, 2000, "estimated"])
        XCTAssertEqual(row.durationMs, 2000); XCTAssertNil(row.streamDurationMs)
        XCTAssertNil(row.streamOutputTokens); XCTAssertNil(row.streamTiming)
        let value = StatisticsFold.throughput([row], calendar: .current)
        XCTAssertEqual(value["summary"]["avgTps"], 50)
        XCTAssertTrue(value["streaming"]["summary"]["avgTps"].isNull)
    }

    private func dshLedger(output: Double) throws -> Data {
        let time: Double = 1791720000000
        let usage: JSONValue = ["inputTokens": 10, "outputTokens": .number(output), "cacheReadTokens": 30, "cacheWriteTokens": 4, "reasoningTokens": 7]
        func chunk(_ seq: Int, _ offset: Double, _ value: JSONValue) -> JSONValue {
            ["type": "assistant/chunk", "seq": .number(Double(seq)), "time": .number(time + offset), "data": ["turn": 1, "step": 1, "chunk": value]]
        }
        let rows: [JSONValue] = [
            ["type": "session", "version": 0, "id": "session", "createdAt": .number(time), "delegationDepth": 0],
            ["type": "request/header", "seq": 0, "time": .number(time), "data": ["header": ["config": ["model": "fixture-dsh"]]]],
            chunk(1, 100, ["type": "reasoning-delta", "index": 0, "text": "r"]),
            chunk(2, 2100, ["type": "text-delta", "index": 1, "text": "a"]),
            chunk(3, 8000, ["type": "usage", "usage": usage]),
            chunk(4, 8100, ["type": "finish", "reason": ["kind": "stop"]]),
            ["type": "assistant/message", "seq": 5, "time": .number(time + 9000), "sourceEventSeqs": [1, 2, 3, 4], "data": ["turn": 1, "step": 1, "usage": usage, "message": ["id": "message", "source": ["model": "fixture-dsh"]]]]
        ]
        return try Data((rows.map { String(decoding: try $0.encoded(), as: UTF8.self) }.joined(separator: "\n") + "\n").utf8)
    }
    private func frame(_ bytes: Data) -> Data {
        // One standard single-segment raw block, without a compressor dependency.
        precondition(bytes.count < 128 << 10)
        var result = Data([0x28, 0xb5, 0x2f, 0xfd, 0xa0])
        for shift in [0, 8, 16, 24] { result.append(UInt8(truncatingIfNeeded: UInt32(bytes.count) >> shift)) }
        let block = UInt32(bytes.count << 3) | 1
        for shift in [0, 8, 16] { result.append(UInt8(truncatingIfNeeded: block >> shift)) }
        result.append(bytes); return result
    }
    func testDeepSeekServiceCanonicalCompressionAndMirrorDoNotDoubleTokensOrStreamClock() async throws {
        let (_, runtime) = try fixture(), service = NativeStatisticsService(runtime: runtime)
        let plain = runtime.paths.home.appendingPathComponent(".dsh/sessions/project/one/session.jsonl"), compressed = URL(fileURLWithPath: plain.path + ".zstd")
        try FileManager.default.createDirectory(at: plain.deletingLastPathComponent(), withIntermediateDirectories: true)
        try dshLedger(output: 100).write(to: plain); try frame(dshLedger(output: 200)).write(to: compressed)
        try Data("not a session".utf8).write(to: plain.deletingLastPathComponent().appendingPathComponent("tool-output.jsonl"))
        let first = try await service.handle("overview", input: ["source": "dsh"])
        XCTAssertEqual(first["scan"]["files"], 1); XCTAssertEqual(first["derived"]["summary"]["totals"]["output"], 100)
        XCTAssertEqual(first["derived"]["throughput"]["streaming"]["summary"]["avgTps"], 50)
        try FileManager.default.removeItem(at: plain); _ = try await service.handle("rescan")
        let second = try await service.handle("overview", input: ["source": "dsh"])
        XCTAssertEqual(second["derived"]["summary"]["totals"]["output"], 200)
        XCTAssertEqual(second["derived"]["throughput"]["streaming"]["summary"]["avgTps"], 100)
        let stored = try XCTUnwrap(runtime.db.query("SELECT path,source_path FROM stats_files").first)
        let resolved = try XCTUnwrap(realpath(compressed.path, nil))
        defer { free(resolved) }
        let physicalSource = String(cString: resolved)
        XCTAssertEqual(stored["source_path"]?.string, physicalSource)
        XCTAssertEqual(stored["path"]?.string, String(physicalSource.dropLast(5)))
        let mirror = runtime.paths.home.appendingPathComponent(".dsh/sessions/project/two/session.jsonl.zstd")
        try FileManager.default.createDirectory(at: mirror.deletingLastPathComponent(), withIntermediateDirectories: true)
        try frame(dshLedger(output: 200)).write(to: mirror); _ = try await service.handle("rescan")
        let deduped = try await service.handle("overview", input: ["source": "dsh"])
        XCTAssertEqual(deduped["scan"]["files"], 2); XCTAssertEqual(deduped["scan"]["records"], 2)
        XCTAssertEqual(deduped["derived"]["events"], 1)
        XCTAssertEqual(deduped["derived"], second["derived"])
    }
    func testMalformedDeepSeekReplacementPreservesCachedUsageAndClock() async throws {
        let (_, runtime) = try fixture(), service = NativeStatisticsService(runtime: runtime)
        let source = runtime.paths.home.appendingPathComponent(".dsh/sessions/project/session/session.jsonl.zstd")
        try FileManager.default.createDirectory(at: source.deletingLastPathComponent(), withIntermediateDirectories: true)
        try frame(dshLedger(output: 100)).write(to: source)
        let first = try await service.handle("overview", input: ["source": "dsh"])
        let records = try runtime.db.query("SELECT * FROM stats_records"), files = try runtime.db.query("SELECT * FROM stats_files")
        try Data([0x28, 0xb5]).write(to: source); _ = try await service.handle("rescan")
        let failed = try await service.handle("overview", input: ["source": "dsh"])
        XCTAssertEqual(failed["derived"], first["derived"]); XCTAssertFalse(failed["warnings"].array.isEmpty)
        XCTAssertEqual(try runtime.db.query("SELECT * FROM stats_records"), records)
        XCTAssertEqual(try runtime.db.query("SELECT * FROM stats_files"), files)
    }
}
