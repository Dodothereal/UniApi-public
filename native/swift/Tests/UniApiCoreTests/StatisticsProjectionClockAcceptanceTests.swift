import XCTest
import Foundation
import Darwin
@testable import UniApiCore

final class StatisticsProjectionClockAcceptanceTests: XCTestCase {
    private let migration = "native-statistics-turn-clocks-1"
    private var utc: Calendar {
        var value = Calendar(identifier: .gregorian)
        value.timeZone = TimeZone(secondsFromGMT: 0)!
        return value
    }
    private var frames: [JSONValue] {
        [
            ["type": "session_meta", "payload": ["id": "fixture"]],
            ["type": "turn_context", "payload": ["turn_id": "A", "model": "model-A"]],
            ["type": "event_msg", "timestamp": "2026-10-10T10:00:00Z", "payload": ["type": "task_started", "turn_id": "A"]],
            ["type": "turn_context", "payload": ["turn_id": "B", "model": "model-B"]],
            ["type": "response_item", "timestamp": "2026-10-10T10:00:02Z", "payload": ["type": "custom_tool_call_output", "turn_id": "A", "call_id": "one", "output": "private fixture body"]],
            ["type": "token_usage_record", "timestamp": "2026-10-10T10:00:05Z", "payload": ["turn_id": "A", "response_id": "rA", "usage": ["input_tokens": 100, "output_tokens": 20]]],
            ["type": "token_usage_record", "timestamp": "2026-10-10T10:00:06Z", "payload": ["turn_id": "B", "response_id": "rB", "usage": ["input_tokens": 200, "output_tokens": 40]]]
        ]
    }
    private func fixture() throws -> (root: URL, home: URL, source: URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("statistics-clock-" + UUID().uuidString)
        let home = root.appendingPathComponent("home"), source = home.appendingPathComponent(".codex/sessions/two-turns.jsonl")
        try FileManager.default.createDirectory(at: source.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = try frames.map { String(decoding: try $0.encoded(), as: UTF8.self) }.joined(separator: "\n")
        try Data(data.utf8).write(to: source)
        let claude = home.appendingPathComponent(".claude/projects/fixture/control.jsonl")
        try FileManager.default.createDirectory(at: claude.deletingLastPathComponent(), withIntermediateDirectories: true)
        let control: JSONValue = ["type": "assistant", "uuid": "c", "timestamp": "2026-10-10T10:00:00Z", "sessionId": "control", "message": ["id": "control", "model": "fixture-claude", "usage": ["input_tokens": 3, "output_tokens": 1]]]
        try control.encoded().write(to: claude)
        addTeardownBlock { try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: source.path); try? FileManager.default.removeItem(at: root) }
        return (root, home, source)
    }
    private func service(_ runtime: NativeRuntime, _ clock: ProjectionClock) -> NativeStatisticsService {
        NativeStatisticsService(runtime: runtime, environment: [:], calendar: utc, clock: { clock.now() })
    }
    private func seedOldCache(_ paths: NativePaths, _ clock: ProjectionClock) async throws -> NativeRuntime {
        let runtime = try NativeRuntime(paths: paths)
        let initial = try await service(runtime, clock).handle("overview")
        XCTAssertEqual(initial["scan"]["parsedFiles"], 2)
        try runtime.db.execute("UPDATE stats_records SET duration_ms=5000 WHERE msg_id='codex:rA'")
        try runtime.db.execute("UPDATE stats_records SET duration_ms=4000 WHERE msg_id='codex:rB'")
        try runtime.db.execute("DELETE FROM schema_migrations WHERE name=?", [.string(migration)])
        return runtime
    }
    private func snapshot(_ db: NativeDatabase) throws -> [[JSONObject]] {
        let hasMigrations = !(try db.query("SELECT name FROM sqlite_master WHERE type='table' AND name='schema_migrations'")).isEmpty
        return try [db.query("SELECT * FROM stats_files ORDER BY path"), db.query("SELECT * FROM stats_records ORDER BY path,rowid"), hasMigrations ? db.query("SELECT * FROM schema_migrations ORDER BY name") : [], db.query("SELECT name,type,sql FROM sqlite_master ORDER BY type,name")]
    }
    private func waitForSettledScan(_ value: NativeStatisticsService) async throws {
        let deadline = ProcessInfo.processInfo.systemUptime + 2
        while ProcessInfo.processInfo.systemUptime < deadline {
            let overview = try await value.handle("overview")
            if !overview["scanning"].bool { return }
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        throw NativeFailure("Private Statistics scan did not settle")
    }
    private func assertClocks(_ value: NativeStatisticsService, file: StaticString = #filePath, line: UInt = #line) async throws {
        let a = try await value.handle("model", input: ["model": "model-A", "source": "codex", "range": 0])
        let b = try await value.handle("model", input: ["model": "model-B", "source": "codex", "range": 0])
        XCTAssertEqual(a["derived"]["throughput"]["summary"]["durationMs"], 3000, file: file, line: line)
        XCTAssertEqual(a["derived"]["summary"]["totals"]["input"], 100, file: file, line: line)
        XCTAssertEqual(a["derived"]["summary"]["totals"]["output"], 20, file: file, line: line)
        XCTAssertTrue(b["derived"]["throughput"]["summary"]["avgTps"].isNull, file: file, line: line)
        XCTAssertEqual(b["derived"]["throughput"]["summary"]["timedResponses"], 0, file: file, line: line)
        XCTAssertEqual(b["derived"]["summary"]["totals"]["input"], 200, file: file, line: line)
        XCTAssertEqual(b["derived"]["summary"]["totals"]["output"], 40, file: file, line: line)
    }

    func testExplicitResponseTurnSurvivesProjectionWithoutToolBodyOrClockLeak() throws {
        let full = StatisticsCodexReader(), projected = StatisticsCodexReader()
        for frame in frames {
            let lean = try JSONDecoder().decode(StatisticsEnvelope.self, from: frame.encoded()).value
            if frame["type"] == "response_item" {
                XCTAssertEqual(lean["payload"]["turn_id"], "A")
                XCTAssertEqual(lean["payload"]["call_id"], "one")
                XCTAssertTrue(lean["payload"]["output"].isNull)
            }
            full.push(frame); projected.push(lean)
        }
        let a = full.finish().records, b = projected.finish().records
        XCTAssertEqual(a.map(\.id), ["codex:rA", "codex:rB"])
        XCTAssertEqual(b.map(\.id), a.map(\.id))
        XCTAssertEqual(b.map(\.model), ["model-A", "model-B"])
        XCTAssertEqual(b.map(\.grand), [120, 240])
        XCTAssertEqual(a[0].durationMs, 3000); XCTAssertNil(a[1].durationMs)
        XCTAssertEqual(b[0].durationMs, 3000); XCTAssertNil(b[1].durationMs)
        XCTAssertEqual(try JSONValue.decode(JSONEncoder().encode(a)), try JSONValue.decode(JSONEncoder().encode(b)))
    }

    func testWritableLegacyTimingCacheUpgradesOnceAndRetainsOtherSourceCache() async throws {
        let f = try fixture(), clock = ProjectionClock()
        let paths = NativePaths(root: f.root, home: f.home)
        let old = try await seedOldCache(paths, clock)
        let claudeBefore = try old.db.query("SELECT * FROM stats_files WHERE path LIKE '%control.jsonl'")
        XCTAssertEqual(claudeBefore.count, 1)
        let runtime = try NativeRuntime(paths: paths), upgraded = service(runtime, clock)
        let overview = try await upgraded.handle("overview")
        XCTAssertEqual(overview["scan"]["parsedFiles"], 1)
        try await assertClocks(upgraded)
        XCTAssertEqual(try runtime.db.query("SELECT * FROM stats_files WHERE path LIKE '%control.jsonl'"), claudeBefore)
        XCTAssertEqual(try runtime.db.query("SELECT name FROM schema_migrations WHERE name=?", [.string(migration)]).count, 1)
        let another = try NativeRuntime(paths: paths)
        let cached = try await service(another, clock).handle("overview")
        XCTAssertEqual(cached["scan"]["parsedFiles"], 0)
        XCTAssertEqual(cached["derived"]["events"], 3)
    }

    func testReadOnlyLegacyClockRepairSurvivesOrdinaryRefreshAndFailedRetryWithoutWrites() async throws {
        let f = try fixture(), clock = ProjectionClock()
        let old = try await seedOldCache(NativePaths(root: f.root, home: f.home), clock)
        let before = try snapshot(old.db)
        let runtime = try NativeRuntime(paths: NativePaths(root: f.root, home: f.home, readOnly: true))
        let readonly = service(runtime, clock)
        let initial = try await readonly.handle("overview")
        XCTAssertEqual(initial["scan"]["parsedFiles"], 1)
        try await assertClocks(readonly)
        XCTAssertEqual(try snapshot(old.db), before)

        let stream = await runtime.events.stream(), refreshed = expectation(description: "ordinary read-only refresh")
        let observer = Task {
            for await event in stream where event.topic == "stats.scanned" { refreshed.fulfill(); return }
        }
        defer { observer.cancel() }
        clock.advance(31_000)
        _ = try await readonly.handle("overview")
        await fulfillment(of: [refreshed], timeout: 2)
        try await waitForSettledScan(readonly)
        try await assertClocks(readonly)
        XCTAssertEqual(try snapshot(old.db), before)

        XCTAssertEqual(chmod(f.source.path, 0), 0)
        let descriptor = open(f.source.path, O_RDONLY)
        if descriptor >= 0 { close(descriptor) }
        XCTAssertEqual(descriptor, -1, "Private unreadable-source control requires an unprivileged test user")
        do { _ = try await readonly.handle("rescan"); XCTFail("Required timing upgrade must not publish stale cached clocks") }
        catch { XCTAssertTrue(String(describing: error).contains("upgrade is incomplete")) }
        XCTAssertEqual(try snapshot(old.db), before)
        XCTAssertEqual(chmod(f.source.path, 0o600), 0)
        _ = try await readonly.handle("rescan")
        try await assertClocks(readonly)
        XCTAssertEqual(try snapshot(old.db), before)
    }

    func testReadOnlyUnversionedCacheReparsesWithoutCreatingMigrationMetadata() async throws {
        let f = try fixture(), clock = ProjectionClock()
        let old = try await seedOldCache(NativePaths(root: f.root, home: f.home), clock)
        try old.db.executeScript("DROP TABLE schema_migrations")
        let before = try snapshot(old.db)
        let runtime = try NativeRuntime(paths: NativePaths(root: f.root, home: f.home, readOnly: true))
        let readonly = service(runtime, clock)
        let overview = try await readonly.handle("overview")
        XCTAssertEqual(overview["scan"]["parsedFiles"], 2)
        try await assertClocks(readonly)
        XCTAssertTrue(try runtime.db.query("SELECT name FROM sqlite_master WHERE name='schema_migrations'").isEmpty)
        XCTAssertEqual(try snapshot(old.db), before)
    }
}

private final class ProjectionClock: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Double = 1_791_676_800_000
    func now() -> Double { lock.lock(); defer { lock.unlock() }; return value }
    func advance(_ delta: Double) { lock.lock(); value += delta; lock.unlock() }
}
