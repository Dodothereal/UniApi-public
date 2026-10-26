import XCTest
import Foundation
import Darwin
@testable import UniApiCore

/// Real readers and persistence against seven tiny, wholly synthetic sources.
/// These assert scan telemetry/publication, not installed UI latency.
final class StatisticsProgressTests: XCTestCase {
    private struct Fixture {
        let runtime: NativeRuntime
        let service: NativeStatisticsService
        let projects: URL
        let zcode: URL
    }
    private struct Capture {
        let result: JSONValue?
        let error: String?
        let events: [NativeEvent]
        var progress: [JSONValue] { events.filter { $0.topic == "stats.progress" }.map(\.data) }
    }

    private func seedSource(_ url: URL, _ body: (NativeDatabase) throws -> Void) throws {
        // The writer never escapes this call: source connections are closed
        // before readers run or the failure test manufactures a hot journal.
        let db = try NativeDatabase(url: url)
        try body(db)
    }

    private func fixture() async throws -> Fixture {
        let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
            .appendingPathComponent("statistics-progress-" + UUID().uuidString)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        // Keep even the runtime's empty provider seed inside this private root.
        try NativeFile.writeAtomic(try JSONValue.object(["providers": []]).encoded(), to: root.appendingPathComponent("providers.example.json"))
        let home = root.appendingPathComponent("home"), projects = home.appendingPathComponent(".claude/projects/fixture")
        for index in 1...5 {
            let row: JSONValue = ["type": "assistant", "timestamp": "2026-10-10T10:00:00Z", "sessionId": .string("session-\(index)"), "cwd": "fixture/project",
                "message": ["id": .string("response-\(index)"), "model": "fixture-claude", "usage": ["input_tokens": 100, "output_tokens": 10]]]
            try NativeFile.writeAtomic(try row.encoded(), to: projects.appendingPathComponent("\(index).jsonl"))
        }
        let opencode = home.appendingPathComponent(".local/share/opencode/opencode.db")
        try seedSource(opencode) { openDB in
            try openDB.executeScript("""
            CREATE TABLE session(id TEXT,directory TEXT,parent_id TEXT);
            CREATE TABLE message(id TEXT,session_id TEXT,time_created REAL,data TEXT);
            CREATE TABLE part(message_id TEXT,data TEXT);
            INSERT INTO session VALUES('open-session','fixture/project',NULL);
            INSERT INTO part VALUES('open-response','{"type":"text"}');
            """)
            let openRow: JSONValue = ["role": "assistant", "modelID": "fixture-open", "finish": "stop",
                "time": ["created": 1791626400000, "completed": 1791626402000],
                "tokens": ["input": 30, "output": 20, "reasoning": 5, "cache": ["read": 7, "write": 3]]]
            try openDB.execute("INSERT INTO message VALUES(?,?,?,?)", ["open-response", "open-session", 1791626400000, .string(String(decoding: try openRow.encoded(), as: UTF8.self))])
        }
        let zcode = home.appendingPathComponent(".zcode/cli/db/db.sqlite")
        try seedSource(zcode) { zDB in
            try zDB.executeScript("""
            CREATE TABLE session(id TEXT,directory TEXT);
            INSERT INTO session VALUES('z-session','fixture/project');
            CREATE TABLE model_usage(id TEXT,session_id TEXT,query_source TEXT,model_id TEXT,variant TEXT,agent TEXT,status TEXT,started_at REAL,duration_ms REAL,input_tokens REAL,output_tokens REAL,reasoning_tokens REAL,cache_creation_input_tokens REAL,cache_read_input_tokens REAL);
            INSERT INTO model_usage VALUES('z-response','z-session','','fixture-z','','','completed',1791626400000,1500,100,20,0,10,30);
            """)
        }
        let runtime = try NativeRuntime(paths: NativePaths(root: root, home: home))
        await runtime.jobs.suspendForShutdown()
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let service = NativeStatisticsService(runtime: runtime, environment: [:], calendar: calendar, clock: { 1791849600000 })
        return Fixture(runtime: runtime, service: service, projects: projects.deletingLastPathComponent(), zcode: zcode)
    }

    private func capture(_ fixture: Fixture, operation: String) async -> Capture {
        // Registration precedes the actual service call. A FIFO marker drains
        // the stream deterministically without sleeps or scheduler assumptions.
        let stream = await fixture.runtime.events.stream(), marker = "fixture.statistics-progress." + UUID().uuidString
        let collector = Task { () -> [NativeEvent] in
            var events: [NativeEvent] = []
            for await event in stream {
                if event.topic == marker { break }
                if event.topic.hasPrefix("stats.") { events.append(event) }
            }
            return events
        }
        var result: JSONValue?, failure: String?
        do { result = try await fixture.service.handle(operation) }
        catch { failure = error.localizedDescription }
        await fixture.runtime.events.publish(marker, .null)
        return Capture(result: result, error: failure, events: await collector.value)
    }

    private func assertTotals(_ value: JSONValue, file: StaticString = #filePath, line: UInt = #line) {
        let summary = value["derived"]["summary"], totals = summary["totals"]
        // Five Claude rows: 550; OpenCode: 65; Z Code: 120. Reasoning is
        // already part of OpenCode output, not another charge on top of it.
        XCTAssertEqual(totals["input"], 590, file: file, line: line)
        XCTAssertEqual(totals["output"], 95, file: file, line: line)
        XCTAssertEqual(totals["cacheRead"], 37, file: file, line: line)
        XCTAssertEqual(totals["cacheWrite"], 13, file: file, line: line)
        XCTAssertEqual(totals["messages"], 7, file: file, line: line)
        XCTAssertEqual(summary["models"], 3, file: file, line: line)
    }

    @discardableResult private func assertComplete(_ captured: Capture, file: StaticString = #filePath, line: UInt = #line) throws -> JSONValue {
        XCTAssertNil(captured.error, file: file, line: line)
        let progress = captured.progress, final = try XCTUnwrap(progress.last, file: file, line: line)
        let id = final["scanId"].string
        XCTAssertNotNil(UUID(uuidString: id), file: file, line: line)
        XCTAssertEqual(Set(progress.map { $0["scanId"].string }), [id], file: file, line: line)
        var phases: [String] = []
        for event in progress where phases.last != event["phase"].string { phases.append(event["phase"].string) }
        XCTAssertEqual(phases, ["discovering", "reading", "assembling", "folding", "complete"], file: file, line: line)
        XCTAssertEqual(progress.filter { $0["phase"] == "reading" }.map { $0["done"].int }, [0, 5, 7], file: file, line: line)
        XCTAssertEqual(progress.filter { $0["phase"] == "reading" }.last?["file"], "db.sqlite", file: file, line: line)
        XCTAssertEqual(final["done"], 7, file: file, line: line)
        XCTAssertEqual(final["total"], 7, file: file, line: line)
        XCTAssertEqual(final["status"], "complete", file: file, line: line)
        XCTAssertEqual(final["loaded"], true, file: file, line: line)
        XCTAssertTrue(progress.allSatisfy { !$0["file"].string.contains("/") }, file: file, line: line)
        let terminal = try XCTUnwrap(captured.events.firstIndex { $0.topic == "stats.progress" && $0.data["phase"] == "complete" }, file: file, line: line)
        let scanned = try XCTUnwrap(captured.events.firstIndex { $0.topic == "stats.scanned" }, file: file, line: line)
        XCTAssertLessThan(terminal, scanned, file: file, line: line)
        XCTAssertEqual(captured.events[scanned].data["scanId"], final["scanId"], file: file, line: line)
        return final
    }

    func testSevenRealReadersPublishFinalCountAndForcedReloadHasANewIdentity() async throws {
        let f = try await fixture(), initial = await capture(f, operation: "overview")
        let first = try assertComplete(initial)
        assertTotals(try XCTUnwrap(initial.result))
        let reload = await capture(f, operation: "rescan"), second = try assertComplete(reload)
        XCTAssertNotEqual(first["scanId"], second["scanId"])
        XCTAssertEqual(second["generation"].int, first["generation"].int + 1)
        let result = try XCTUnwrap(reload.result)
        XCTAssertEqual(result["scan"]["parsedFiles"], 7, "Full Reload must still reparse unchanged files")
        let current = try await f.service.handle("overview")
        assertTotals(current)
        XCTAssertEqual(current["progress"], second)
        XCTAssertEqual(current["scanning"], false)
        XCTAssertEqual(f.service.cachedSummary()["grand"], 735)
    }

    func testLateReaderUpgradeFailureRetainsGenerationAndNeverReportsOldCompletion() async throws {
        let f = try await fixture(), initial = await capture(f, operation: "overview")
        let first = try assertComplete(initial), original = try XCTUnwrap(initial.result)
        // Real upgrade rejection after all seven attempts: the last source has
        // a hot rollback journal, while its invalid signature requires repair.
        // Cache strings come from discovery; a constructed URL may spell the
        // same physical file differently. Mutate the actual persisted key.
        let identities = try f.runtime.db.query("SELECT DISTINCT f.path,f.source_path FROM stats_files f JOIN stats_records r ON r.path=f.path WHERE r.source='zcode'")
        XCTAssertEqual(identities.count, 1)
        let identity = try XCTUnwrap(identities.count == 1 ? identities.first : nil)
        let key = try XCTUnwrap(identity["path"]?.string), path = try XCTUnwrap(identity["source_path"]?.string)
        let source = URL(fileURLWithPath: path), physical = source.standardizedFileURL.resolvingSymlinksInPath()
        let privateHome = f.runtime.paths.home.standardizedFileURL.resolvingSymlinksInPath().path + "/"
        let privateSource = path.hasPrefix("/") && physical.path.hasPrefix(privateHome) && physical.lastPathComponent == "db.sqlite"
        XCTAssertTrue(privateSource)
        guard privateSource else { return }
        var actual = stat(), expected = stat()
        let actualResult = lstat(source.path, &actual), expectedResult = lstat(f.zcode.path, &expected)
        XCTAssertEqual(actualResult, 0); XCTAssertEqual(expectedResult, 0)
        guard actualResult == 0, expectedResult == 0 else { return }
        XCTAssertEqual(actual.st_mode & S_IFMT, S_IFREG); XCTAssertEqual(expected.st_mode & S_IFMT, S_IFREG)
        XCTAssertEqual(actual.st_dev, expected.st_dev); XCTAssertEqual(actual.st_ino, expected.st_ino)
        guard actual.st_mode & S_IFMT == S_IFREG, expected.st_mode & S_IFMT == S_IFREG,
              actual.st_dev == expected.st_dev, actual.st_ino == expected.st_ino else { return }
        let invalidated = try f.runtime.db.execute("UPDATE stats_files SET mtime=-1 WHERE path=?", [.string(key)])
        XCTAssertEqual(invalidated, 1)
        let invalid = try f.runtime.db.query("SELECT mtime FROM stats_files WHERE path=?", [.string(key)])
        XCTAssertEqual(invalid.count, 1); XCTAssertEqual(invalid.first?["mtime"], -1)
        guard invalidated == 1, invalid.count == 1, invalid.first?["mtime"] == -1 else { return }
        let journal = URL(fileURLWithPath: source.path + "-journal")
        try NativeFile.writeAtomic(Data("pending rollback".utf8), to: journal)
        let failed = await capture(f, operation: "rescan"), final = try XCTUnwrap(failed.progress.last)
        XCTAssertTrue(failed.error?.contains("upgrade is incomplete") == true)
        XCTAssertNotEqual(final["scanId"], first["scanId"])
        XCTAssertEqual(Set(failed.progress.map { $0["scanId"].string }), [final["scanId"].string])
        XCTAssertEqual(final["phase"], "reading")
        XCTAssertEqual(final["status"], "failed")
        XCTAssertEqual(final["done"], 7); XCTAssertEqual(final["total"], 7)
        XCTAssertEqual(final["generation"], first["generation"]); XCTAssertEqual(final["loaded"], true)
        XCTAssertFalse(failed.progress.contains { $0["phase"] == "complete" })
        XCTAssertFalse(failed.events.contains { $0.topic == "stats.scanned" })
        let retained = try await f.service.handle("overview")
        XCTAssertEqual(retained["derived"], original["derived"])
        XCTAssertEqual(retained["scan"], original["scan"])
        XCTAssertEqual(retained["progress"], final, "Cached content must not hide the failed scan's live status")
        XCTAssertEqual(retained["scanning"], false)
        XCTAssertEqual(f.service.cachedSummary()["grand"], 735)
        try FileManager.default.removeItem(at: journal)
        let retry = await capture(f, operation: "rescan"), recovered = try assertComplete(retry)
        XCTAssertNotEqual(recovered["scanId"], final["scanId"])
        XCTAssertEqual(recovered["generation"].int, first["generation"].int + 1)
        let current = try await f.service.handle("overview"); assertTotals(current)
    }

    func testDiscoveryFailureHasItsOwnIdentityBeforeAnyFileCountIsKnown() async throws {
        let f = try await fixture(), initial = await capture(f, operation: "overview")
        let first = try assertComplete(initial)
        try FileManager.default.removeItem(at: f.projects)
        try Data("not a directory".utf8).write(to: f.projects)
        let failed = await capture(f, operation: "rescan"), final = try XCTUnwrap(failed.progress.last)
        XCTAssertNotNil(failed.error)
        XCTAssertEqual(failed.progress.map { $0["phase"].string }, ["discovering", "discovering"])
        XCTAssertEqual(final["status"], "failed")
        XCTAssertNotEqual(final["scanId"], first["scanId"])
        XCTAssertEqual(final["done"], 0); XCTAssertEqual(final["total"], 0)
        XCTAssertEqual(final["generation"], first["generation"])
        XCTAssertFalse(failed.events.contains { $0.topic == "stats.scanned" })
        let retained = try await f.service.handle("overview"); assertTotals(retained)
        XCTAssertEqual(retained["progress"], final)
    }
}
