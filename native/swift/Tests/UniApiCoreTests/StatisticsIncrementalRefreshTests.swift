import XCTest
import Foundation
import Darwin
@testable import UniApiCore

private final class IncrementalRefreshRequestFlag: @unchecked Sendable {
    private let lock = NSLock(); private var requested = false
    func mark() { lock.withLock { requested = true } }
    var value: Bool { lock.withLock { requested } }
}

/// Real metadata discovery, transcript readers and persistence in a private home.
/// No decoder seam or operator corpus is needed to prove which files reparsed.
final class StatisticsIncrementalRefreshTests: XCTestCase {
    private struct Fixture {
        let runtime: NativeRuntime, service: NativeStatisticsService
        let sources: [URL], ledger: URL
    }
    private struct Capture {
        let result: JSONValue, events: [NativeEvent]
    }
    private let modelID = "fixture-incremental"
    private func row(_ id: String, input: Int) -> JSONValue {
        ["type": "assistant", "timestamp": "2026-10-22T10:00:00Z", "sessionId": "fixture-session", "cwd": "fixture/project",
         "message": ["id": .string(id), "model": .string(modelID), "usage": ["input_tokens": .number(Double(input)), "output_tokens": 1]]]
    }
    private func put(_ value: JSONValue, at file: URL) throws {
        var bytes = try value.encoded(); bytes.append(10)
        try NativeFile.writeAtomic(bytes, to: file)
    }
    private func fixture() async throws -> Fixture {
        let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
            .appendingPathComponent("statistics-incremental-" + UUID().uuidString)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        try NativeFile.writeAtomic(try JSONValue.object(["providers": []]).encoded(), to: root.appendingPathComponent("providers.example.json"))
        let paths = NativePaths(root: root, home: root.appendingPathComponent("home"))
        let projects = paths.home.appendingPathComponent(".claude/projects/fixture")
        let sources = ["one", "two", "three"].map { projects.appendingPathComponent($0 + ".jsonl") }
        for (index, source) in sources.enumerated() { try put(row("response-\(index)", input: (index + 1) * 10), at: source) }
        let runtime = try NativeRuntime(paths: paths); await runtime.jobs.suspendForShutdown()
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let service = NativeStatisticsService(runtime: runtime, environment: [:], calendar: calendar, clock: { 1792713600000 })
        return Fixture(runtime: runtime, service: service, sources: sources, ledger: paths.data.appendingPathComponent("results.jsonl"))
    }
    private func capture(_ fixture: Fixture, operation: String) async throws -> Capture {
        let stream = await fixture.runtime.events.stream(), marker = "fixture.incremental." + UUID().uuidString
        let collector = Task { () -> [NativeEvent] in
            var events: [NativeEvent] = []
            for await event in stream {
                if event.topic == marker { break }
                if event.topic.hasPrefix("stats.") { events.append(event) }
            }
            return events
        }
        defer { collector.cancel() }
        let result = try await fixture.service.handle(operation)
        await fixture.runtime.events.publish(marker, .null)
        return Capture(result: result, events: await collector.value)
    }
    private func cacheFiles(_ fixture: Fixture) throws -> [JSONObject] {
        try fixture.runtime.db.query("SELECT path,mtime,size,source_path,record_revision FROM stats_files ORDER BY path")
    }
    private func assertCompleted(_ capture: Capture, parsed: Int, file: StaticString = #filePath, line: UInt = #line) throws {
        XCTAssertEqual(capture.result["ok"], true, file: file, line: line)
        XCTAssertEqual(capture.result["scan"]["parsedFiles"].int, parsed, file: file, line: line)
        let complete = try XCTUnwrap(capture.events.firstIndex { $0.topic == "stats.progress" && $0.data["phase"] == "complete" }, file: file, line: line)
        let scanned = try XCTUnwrap(capture.events.firstIndex { $0.topic == "stats.scanned" }, file: file, line: line)
        XCTAssertLessThan(complete, scanned, file: file, line: line)
        XCTAssertEqual(capture.events.filter { $0.topic == "stats.scanned" }.count, 1, file: file, line: line)
        let id = capture.result["scan"]["scanId"]
        XCTAssertNotNil(UUID(uuidString: id.string), file: file, line: line)
        XCTAssertEqual(capture.events[complete].data["scanId"], id, file: file, line: line)
        XCTAssertEqual(capture.events[scanned].data["scanId"], id, file: file, line: line)
        XCTAssertEqual(capture.events[complete].data["done"].int, parsed, file: file, line: line)
        XCTAssertEqual(capture.events[complete].data["total"].int, parsed, file: file, line: line)
    }

    func testFreshWindowRefreshImportsChangedFileWithoutReparsingUnchangedHistory() async throws {
        let f = try await fixture(), initial = try await f.service.handle("overview")
        XCTAssertEqual(initial["scan"]["parsedFiles"], 3)
        XCTAssertEqual(initial["derived"]["summary"]["totals"]["input"], 60)
        let before = try cacheFiles(f)
        let originalRecords = try f.runtime.db.query("SELECT * FROM stats_records ORDER BY path,msg_id")
        let changed = try XCTUnwrap(before.first { $0["source_path"]?.string.hasSuffix("/one.jsonl") == true })
        let key = try XCTUnwrap(changed["path"])
        // A different byte length is an unambiguous metadata change, even on
        // filesystems whose timestamps cannot distinguish adjacent writes.
        try put(row("response-0", input: 1000), at: f.sources[0])
        let warm = try await f.service.handle("overview")
        XCTAssertEqual(warm["derived"], initial["derived"], "Ordinary reads must retain the thirty-second freshness window")
        XCTAssertEqual(try cacheFiles(f), before)

        let refreshed = try await capture(f, operation: "refresh")
        try assertCompleted(refreshed, parsed: 1)
        XCTAssertNotEqual(refreshed.result["scan"]["scanId"], initial["scan"]["scanId"])
        let after = try cacheFiles(f), changedAfter = try XCTUnwrap(after.first { $0["path"] == key })
        XCTAssertNotEqual(changedAfter["record_revision"], changed["record_revision"])
        XCTAssertEqual(after.filter { $0["path"] != key }, before.filter { $0["path"] != key })
        let currentRecords = try f.runtime.db.query("SELECT * FROM stats_records ORDER BY path,msg_id")
        XCTAssertEqual(currentRecords.filter { $0["path"] != key }, originalRecords.filter { $0["path"] != key })
        XCTAssertEqual(currentRecords.map { $0["msg_id"] }, originalRecords.map { $0["msg_id"] })
        let current = try await f.service.handle("overview")
        XCTAssertEqual(current["derived"]["summary"]["totals"]["input"], 1050)
        XCTAssertEqual(current["derived"]["summary"]["totals"]["output"], 3)
        XCTAssertEqual(current["derived"]["events"], 3)
    }

    func testFreshWindowUnchangedRefreshParsesZeroAndPreservesAllCachedRows() async throws {
        let f = try await fixture(), initial = try await f.service.handle("overview")
        let files = try cacheFiles(f), records = try f.runtime.db.query("SELECT * FROM stats_records ORDER BY path,msg_id")
        let refreshed = try await capture(f, operation: "refresh")
        try assertCompleted(refreshed, parsed: 0)
        XCTAssertNotEqual(refreshed.result["scan"]["scanId"], initial["scan"]["scanId"])
        XCTAssertEqual(try cacheFiles(f), files)
        XCTAssertEqual(try f.runtime.db.query("SELECT * FROM stats_records ORDER BY path,msg_id"), records)
        let current = try await f.service.handle("overview")
        XCTAssertEqual(current["derived"], initial["derived"])
        XCTAssertEqual(current["progress"]["status"], "complete")
        XCTAssertEqual(current["progress"]["scanId"], refreshed.result["scan"]["scanId"])
    }

    func testFullRescanAfterIncrementalRefreshStillReparsesEveryUnchangedFile() async throws {
        let f = try await fixture(), initial = try await f.service.handle("overview")
        let incremental = try await capture(f, operation: "refresh")
        try assertCompleted(incremental, parsed: 0)
        let before = try cacheFiles(f)
        let rebuilt = try await capture(f, operation: "rescan")
        try assertCompleted(rebuilt, parsed: 3)
        XCTAssertNotEqual(rebuilt.result["scan"]["scanId"], incremental.result["scan"]["scanId"])
        let after = try cacheFiles(f)
        XCTAssertEqual(after.map { $0["path"] }, before.map { $0["path"] })
        for (old, current) in zip(before, after) { XCTAssertNotEqual(current["record_revision"], old["record_revision"]) }
        let current = try await f.service.handle("overview")
        XCTAssertEqual(current["derived"], initial["derived"], "Rebuild changes the read policy, not accounting")
    }

    func testRebuildRequestedFromIncrementalProgressStillParsesEveryFile() async throws {
        let f = try await fixture()
        _ = try await f.service.handle("overview")
        let before = try cacheFiles(f)
        try put(row("response-0", input: 1000), at: f.sources[0])
        let stream = await f.runtime.events.stream()
        let requested = expectation(description: "full rebuild requested from incremental reading progress")
        let flag = IncrementalRefreshRequestFlag()
        let rebuild = Task { () async throws -> JSONValue in
            for await event in stream where event.topic == "stats.progress" && event.data["phase"] == "reading" && event.data["total"] == 1 {
                // Event delivery does not suspend the publisher. This proves
                // full-must-win behavior whether the request joins the scan or
                // arrives after completion, not deterministic active coalescing.
                flag.mark(); requested.fulfill()
                return try await f.service.handle("rescan")
            }
            throw CancellationError()
        }
        defer { rebuild.cancel() }
        _ = try await f.service.handle("refresh")
        await fulfillment(of: [requested], timeout: 2)
        guard flag.value else { throw NativeFailure("Incremental reading boundary was not published") }
        let result = try await rebuild.value
        XCTAssertEqual(result["ok"], true)
        XCTAssertEqual(result["scan"]["parsedFiles"], 3, "A full request cannot inherit the one-file incremental result")
        let after = try cacheFiles(f)
        XCTAssertEqual(after.map { $0["path"] }, before.map { $0["path"] })
        for (old, current) in zip(before, after) { XCTAssertNotEqual(current["record_revision"], old["record_revision"]) }
        let current = try await f.service.handle("overview")
        XCTAssertEqual(current["derived"]["summary"]["totals"]["input"], 1050)
        XCTAssertEqual(current["derived"]["events"], 3)
    }

    func testRefreshInvalidatesSameMetadataBenchmarkBeforeScannedEventReadsIt() async throws {
        let f = try await fixture()
        let initial = try await f.service.handle("overview")
        let row: JSONValue = ["id": "bench-fixture", "provider": "fixture", "model": .string(modelID), "run_id": "one", "ts": "2026-10-22T10:00:00Z", "ok": true, "tokens": ["in": 13, "out": 6]]
        try put(row, at: f.ledger)
        let first = try await f.service.handle("bench"); XCTAssertEqual(first["spend"]["input"], 13)
        var before = stat(); XCTAssertEqual(lstat(f.ledger.path, &before), 0)
        var changed = row; changed["tokens"] = ["in": 19, "out": 6]
        try put(changed, at: f.ledger)
        let times = [before.st_atimespec, before.st_mtimespec]
        XCTAssertEqual(times.withUnsafeBufferPointer { utimensat(AT_FDCWD, f.ledger.path, $0.baseAddress, 0) }, 0)
        var after = stat(); XCTAssertEqual(lstat(f.ledger.path, &after), 0)
        XCTAssertEqual(after.st_size, before.st_size)
        XCTAssertEqual(after.st_mtimespec.tv_sec, before.st_mtimespec.tv_sec)
        XCTAssertEqual(after.st_mtimespec.tv_nsec, before.st_mtimespec.tv_nsec)
        let ordinary = try await f.service.handle("bench")
        XCTAssertEqual(ordinary["spend"]["input"], 13, "Ordinary warm reads still reuse matching ledger metadata")

        let stream = await f.runtime.events.stream(), eventRead = expectation(description: "incremental scan observer reads new ledger")
        let observer = Task {
            for await event in stream where event.topic == "stats.scanned" {
                do {
                    let value = try await f.service.handle("bench")
                    XCTAssertEqual(value["spend"]["input"], 19)
                    XCTAssertEqual(value["spend"]["output"], 6)
                } catch { XCTFail(String(describing: error)) }
                eventRead.fulfill(); return
            }
        }
        defer { observer.cancel() }
        let refreshed = try await capture(f, operation: "refresh")
        try assertCompleted(refreshed, parsed: 0)
        await fulfillment(of: [eventRead], timeout: 2)
        let current = try await f.service.handle("overview")
        XCTAssertEqual(current["derived"], initial["derived"])
        XCTAssertEqual(try cacheFiles(f).count, 3)
    }
}
