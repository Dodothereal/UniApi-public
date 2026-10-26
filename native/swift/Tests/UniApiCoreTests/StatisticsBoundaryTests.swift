import XCTest
import Darwin
@testable import UniApiCore

final class StatisticsBoundaryTests: XCTestCase {
    private func fixture() throws -> NativeRuntime {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("statistics-boundaries-" + UUID().uuidString)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return try NativeRuntime(paths: NativePaths(root: root, home: root.appendingPathComponent("home")))
    }
    private func line(_ input: Double) -> JSONValue {
        ["type": "assistant", "timestamp": "2026-10-10T10:00:00Z", "message": ["id": "shared", "model": "fixture-model", "usage": ["input_tokens": .number(input), "output_tokens": 0]]]
    }
    private func put(_ rows: [JSONValue], _ file: URL) throws {
        try NativeFile.writeAtomic(Data(try rows.map { String(decoding: try $0.encoded(), as: UTF8.self) }.joined(separator: "\n").utf8), to: file)
    }
    func testReadonlyUnicodeReplacementUsesSQLiteBinaryDedupWinner() async throws {
        let runtime = try fixture(), directory = runtime.paths.home.appendingPathComponent(".claude/projects/p")
        let primary = directory.appendingPathComponent("e\u{301}.jsonl"), secondary = directory.appendingPathComponent("z.jsonl")
        try put([line(100)], primary); try put([line(900)], secondary)
        let builder = NativeStatisticsService(runtime: runtime), first = try await builder.handle("overview")
        XCTAssertEqual(first["derived"]["summary"]["totals"]["input"], 100)
        let before = try runtime.db.query("SELECT * FROM stats_records ORDER BY path,rowid")
        try put([line(200)], secondary)
        let readonly = try NativeRuntime(paths: NativePaths(root: runtime.paths.root, home: runtime.paths.home, readOnly: true))
        let next = try await NativeStatisticsService(runtime: readonly).handle("overview")
        XCTAssertEqual(next["derived"]["summary"]["totals"]["input"], 100)
        XCTAssertEqual(try runtime.db.query("SELECT * FROM stats_records ORDER BY path,rowid"), before)
        let writable = try await NativeStatisticsService(runtime: runtime).handle("overview")
        XCTAssertEqual(next["derived"]["summary"]["totals"], writable["derived"]["summary"]["totals"])
        // Replacing the actual first path must still win rather than being ignored.
        try put([line(300)], primary)
        let changed = try await NativeStatisticsService(runtime: readonly).handle("overview")
        XCTAssertEqual(changed["derived"]["summary"]["totals"]["input"], 300)
    }
    func testReadonlyReplacementsOverlayExclusionsWithoutUpdatingCache() async throws {
        let runtime = try fixture(), file = runtime.paths.home.appendingPathComponent(".codex/sessions/one.jsonl")
        let good: JSONValue = ["type": "token_usage_record", "timestamp": "2026-10-10T10:00:00Z", "payload": ["turn_id": "good", "response_id": "good", "usage": ["input_tokens": 10, "output_tokens": 2]]]
        try put([good], file)
        _ = try await NativeStatisticsService(runtime: runtime).handle("overview")
        let context: JSONValue = ["type": "turn_context", "payload": ["turn_id": "missing", "model": "fixture-model"]]
        let missing: JSONValue = ["type": "event_msg", "timestamp": "2026-10-10T10:00:01Z", "payload": ["type": "token_count", "info": ["total_token_usage": ["total_tokens": 100], "last_token_usage": [:]]]]
        try put([good, context, missing], file)
        let readonly = try NativeRuntime(paths: NativePaths(root: runtime.paths.root, home: runtime.paths.home, readOnly: true))
        let next = try await NativeStatisticsService(runtime: readonly).handle("overview")
        XCTAssertEqual(next["scan"]["codexExcluded"], 1)
        XCTAssertEqual(try runtime.db.query("SELECT excluded_usage FROM stats_files").first?["excluded_usage"], 0)
    }
    func testPublishedSummaryAndHomeDoNotJoinBusyScanActor() async throws {
        let runtime = try fixture(), entered = expectation(description: "refresh entered")
        let gate = StatisticsBoundaryClock { entered.fulfill() }
        let file = runtime.paths.home.appendingPathComponent(".claude/projects/p/a.jsonl")
        try put([line(100)], file)
        let service = NativeStatisticsService(runtime: runtime, environment: [:], clock: { gate.now() })
        try await service.start(); XCTAssertEqual(service.cachedSummary()["grand"], 100)
        try put([line(200)], file); gate.arm()
        let refresh = Task { try await service.handle("rescan") }
        defer { gate.release.signal() }
        await fulfillment(of: [entered], timeout: 1)
        let summary = service.cachedSummary()
        XCTAssertEqual(summary["grand"], 100); XCTAssertEqual(summary["scanning"], true)
        let hub = NativeHubSummaries(runtime: runtime, read: { domain in domain == "stats" ? service.cachedSummary() : ["ready": true] })
        let homeReady = expectation(description: "Home remains responsive")
        let home = Task { let value = try await hub.snapshot(); homeReady.fulfill(); return value }
        await fulfillment(of: [homeReady], timeout: 0.5)
        let value = try await home.value; XCTAssertEqual(value["stats"]["grand"], 100)
        gate.release.signal(); _ = try await refresh.value
        XCTAssertEqual(service.cachedSummary()["grand"], 200); XCTAssertEqual(service.cachedSummary()["scanning"], false)
        // Previously returned values remain immutable when another generation publishes.
        XCTAssertEqual(summary["grand"], 100)
    }
    func testPublishedSummaryMatchesLifetimeReconciliationWithoutOpeningForeignStores() async throws {
        let runtime = try fixture(), service = NativeStatisticsService(runtime: runtime)
        XCTAssertEqual(service.cachedSummary()["loaded"], false)
        XCTAssertTrue(try runtime.db.query("SELECT name FROM sqlite_master WHERE name='stats_records'").isEmpty)
        try put([line(100)], runtime.paths.home.appendingPathComponent(".claude/projects/p/a.jsonl"))
        let cache: JSONValue = ["modelUsage": ["fixture-model": ["inputTokens": 1000, "outputTokens": 200]], "totalMessages": 40, "lastComputedDate": "2026-10-10"]
        try NativeFile.writeAtomic(try cache.encoded(), to: runtime.paths.home.appendingPathComponent(".claude/stats-cache.json"))
        let value = try await service.handle("summary"), published = service.cachedSummary()
        XCTAssertEqual(published["grand"], value["grand"]); XCTAssertEqual(published["responses"], value["responses"])
        XCTAssertEqual(published["models"], value["models"]); XCTAssertEqual(published["grand"], 1200)
    }
    func testFailedReaderMigrationPublishesNoMixedGenerationAndCanRetry() async throws {
        let runtime = try fixture(), source = runtime.paths.home.appendingPathComponent(".zcode/cli/db/db.sqlite")
        let writer = try NativeDatabase(url: source)
        try writer.executeScript("CREATE TABLE model_usage(id TEXT,session_id TEXT,query_source TEXT,model_id TEXT,variant TEXT,agent TEXT,status TEXT,started_at REAL,input_tokens REAL,output_tokens REAL,reasoning_tokens REAL,cache_creation_input_tokens REAL,cache_read_input_tokens REAL); INSERT INTO model_usage VALUES('one','s','','fixture','','','completed',1791626400000,10,2,0,0,0);")
        _ = try await NativeStatisticsService(runtime: runtime).handle("overview")
        let original = try runtime.db.query("SELECT * FROM stats_records")
        try runtime.db.execute("DELETE FROM schema_migrations WHERE name=?", ["native-statistics-readers-1"])
        let journal = URL(fileURLWithPath: source.path + "-journal")
        try NativeFile.writeAtomic(Data("pending rollback".utf8), to: journal)
        let service = NativeStatisticsService(runtime: runtime)
        do { _ = try await service.handle("overview"); XCTFail("Mixed reader generation published") } catch { XCTAssertTrue(error.localizedDescription.contains("upgrade is incomplete")) }
        XCTAssertEqual(service.cachedSummary()["loaded"], false)
        XCTAssertEqual(try runtime.db.query("SELECT * FROM stats_records"), original)
        XCTAssertEqual(try runtime.db.query("SELECT mtime FROM stats_files").first?["mtime"], -1)
        try FileManager.default.removeItem(at: journal)
        let complete = try await service.handle("overview")
        XCTAssertEqual(complete["derived"]["summary"]["totals"]["input"], 10)
        XCTAssertEqual(service.cachedSummary()["loaded"], true)
        XCTAssertGreaterThan((try runtime.db.query("SELECT mtime FROM stats_files").first?["mtime"])!.double, 0)
        XCTAssertEqual(try writer.query("SELECT COUNT(*) AS n FROM model_usage").first?["n"], 1)
    }
}
private final class StatisticsBoundaryClock: @unchecked Sendable {
    private let lock = NSLock(), entered: @Sendable () -> Void
    let release = DispatchSemaphore(value: 0)
    private var active = false
    init(_ entered: @escaping @Sendable () -> Void) { self.entered = entered }
    func arm() { lock.lock(); active = true; lock.unlock() }
    func now() -> Double {
        lock.lock(); let hold = active; active = false; lock.unlock()
        if hold { entered(); _ = release.wait(timeout: .now() + 3) }
        return 1791626400000
    }
}
