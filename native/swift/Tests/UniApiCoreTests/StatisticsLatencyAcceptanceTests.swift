import XCTest
import Foundation
import Darwin
@testable import UniApiCore

/// Bounded synthetic accounting/latency oracles. Never opens an operator home,
/// launches a service or copies a historical corpus. Timings are printed for
/// the serialized optimized gate; they do not establish installed UI latency.
final class StatisticsLatencyAcceptanceTests: XCTestCase {
    private let shared = "claude-opus-5", pruned = "fixture-pruned"
    private var utc: Calendar { calendar("UTC") }
    private func calendar(_ zone: String) -> Calendar {
        var result = Calendar(identifier: .gregorian); result.timeZone = TimeZone(identifier: zone)!; return result
    }
    private func date(_ value: String) -> Double { statisticsTimestamp(.string(value))! }
    private var now: Double { date("2026-10-23T23:59:00Z") }
    private func cacheDocument(input: Double = 1000) -> JSONValue {
        ["lastComputedDate": "2026-10-20", "totalSessions": 7, "totalMessages": 100,
         "modelUsage": [shared: ["inputTokens": .number(input), "outputTokens": 100], pruned: ["inputTokens": 500]],
         "dailyActivity": [["date": "2026-10-01"]],
         "dailyModelTokens": [["date": "2026-10-01", "tokensByModel": [shared: 100]]]]
    }
    private func synthetic(_ count: Int) -> [StatisticsUsage] {
        (0..<count).map { i in
            let source = StatisticsSource.allCases[i % StatisticsSource.allCases.count].rawValue
            var e = StatisticsUsage(id: "row-\(i)", source: source, ts: now - Double(i % 41) * 86_400_000, model: i % 3 == 0 ? shared : "fixture-model-\(i % 7)")
            e.input = Double(i + 1) / 10; e.output = Double(i % 17) / 10
            e.cacheRead = 3; e.cacheWrite = 2; e.thinking = 4; e.webSearch = 1; e.webFetch = 2
            e.session = "session-\(i % 9)"; e.project = "fixture/project-\(i % 4)"; e.effort = "high"; e.sidechain = i % 4 == 0
            e.durationMs = i % 2 == 0 ? 1000 : nil; e.timing = "estimated"
            return e
        }.sorted { $0.ts < $1.ts }
    }
    private func originalTotals(_ rows: [StatisticsUsage], range: Int, cache: StatisticsCache?, now: Double, calendar: Calendar) -> JSONValue {
        .object(Dictionary(uniqueKeysWithValues: StatisticsSource.allCases.map {
            ($0.rawValue, StatisticsFold.sources(rows, range: range, cache: cache, source: $0.rawValue, now: now, calendar: calendar).summary.totals.json)
        }))
    }

    func testSourceTotalsMatchOriginalFullBoardsForWatermarksRangesAndLocalDays() throws {
        let rows = synthetic(205)
        var invalid = cacheDocument(); invalid["lastComputedDate"] = "2026-99-99"
        var absent = cacheDocument(); absent["lastComputedDate"] = .null
        let documents: [JSONValue?] = [nil, cacheDocument(), invalid, absent]
        for calendar in [utc, calendar("Europe/Berlin")] {
            for document in documents {
                let cache = document.flatMap(StatisticsCache.parse)
                for range in [0, 7, 30] {
                    let actual = StatisticsSourceTotals.fold(rows, range: range, cache: cache, now: now, calendar: calendar)
                    XCTAssertEqual(actual, originalTotals(rows, range: range, cache: cache, now: now, calendar: calendar))
                    XCTAssertEqual(StatisticsSourceTotals.fold([], range: range, cache: cache, now: now, calendar: calendar), originalTotals([], range: range, cache: cache, now: now, calendar: calendar))
                }
            }
        }
    }

    func testSourceCardProjectionHasMeasurablyLessWorkThanFiveChartBoards() throws {
        let rows = synthetic(1500), cache = StatisticsCache.parse(cacheDocument())
        let expected = originalTotals(rows, range: 0, cache: cache, now: now, calendar: utc)
        XCTAssertEqual(StatisticsSourceTotals.fold(rows, range: 0, cache: cache, now: now, calendar: utc), expected)
        var oldTimes: [Double] = [], newTimes: [Double] = []
        for _ in 0..<5 {
            var begin = ProcessInfo.processInfo.systemUptime
            let old = originalTotals(rows, range: 0, cache: cache, now: now, calendar: utc)
            oldTimes.append(ProcessInfo.processInfo.systemUptime - begin)
            begin = ProcessInfo.processInfo.systemUptime
            let new = StatisticsSourceTotals.fold(rows, range: 0, cache: cache, now: now, calendar: utc)
            newTimes.append(ProcessInfo.processInfo.systemUptime - begin)
            XCTAssertEqual(old, expected); XCTAssertEqual(new, expected)
        }
        let old = oldTimes.sorted()[2], new = newTimes.sorted()[2]
        print("Statistics source cards: 1500 synthetic rows, original median \(old * 1000) ms, projection median \(new * 1000) ms, ratio \(new / old)")
        XCTAssertLessThan(new, old * 0.8, "Source cards must avoid constructing unused chart boards")
    }

    private struct Fixture {
        let root: URL, home: URL, source: URL, lifetime: URL, ledger: URL
        let runtime: NativeRuntime, service: NativeStatisticsService, clock: StatisticsLatencyClock
        let rows: [StatisticsUsage]
    }
    private func write(_ frames: [JSONValue], at url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try Data((try frames.map { String(decoding: try $0.encoded(), as: UTF8.self) }.joined(separator: "\n") + "\n").utf8).write(to: url)
    }
    private func frames(_ count: Int = 71, firstInput: Double = 1) -> (frames: [JSONValue], rows: [StatisticsUsage]) {
        var frames: [JSONValue] = [], rows: [StatisticsUsage] = []
        let formatter = ISO8601DateFormatter()
        for i in 0..<count {
            let ts = statisticsDay(now, calendar: utc) - Double(i % 13) * 86_400_000 + Double(i / 13 + 1) * 2000
            let stamp = formatter.string(from: Date(timeIntervalSince1970: ts / 1000)), id = "row-\(i)"
            let start = formatter.string(from: Date(timeIntervalSince1970: (ts - 1000) / 1000))
            var row = StatisticsUsage(id: id, source: "claude", ts: ts, model: i % 2 == 0 ? shared : "fixture-other")
            row.input = i == 0 ? firstInput : Double(i + 1); row.output = Double(i % 9 + 1)
            row.cacheWrite = 2; row.cacheRead = 3; row.thinking = 4; row.webSearch = 1; row.webFetch = 2
            row.project = "fixture/project"; row.session = "fixture-session"; row.sidechain = i % 4 == 0; row.effort = "high"
            row.durationMs = 1000; row.timing = "estimated"; row.rawDay = String(stamp.prefix(10)); rows.append(row)
            frames.append(["type": "user", "uuid": .string("u-" + id), "timestamp": .string(start)])
            frames.append(["type": "assistant", "uuid": .string("a-" + id), "parentUuid": .string("u-" + id), "timestamp": .string(stamp), "cwd": .string(row.project), "sessionId": .string(row.session), "isSidechain": .bool(row.sidechain), "effort": .string(row.effort),
                           "message": ["id": .string(id), "model": .string(row.model), "usage": ["input_tokens": .number(row.input), "output_tokens": .number(row.output), "cache_creation_input_tokens": 2, "cache_read_input_tokens": 3, "output_tokens_details": ["thinking_tokens": 4], "server_tool_use": ["web_search_requests": 1, "web_fetch_requests": 2]]]])
        }
        return (frames, rows.sorted { $0.ts < $1.ts })
    }
    private func fixture(count: Int = 71) async throws -> Fixture {
        let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent("statistics-latency-" + UUID().uuidString)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let home = root.appendingPathComponent("home"), native = root.appendingPathComponent("native")
        let source = home.appendingPathComponent(".claude/projects/private/usage.jsonl"), lifetime = home.appendingPathComponent(".claude/stats-cache.json")
        let input = frames(count); try write(input.frames, at: source); try cacheDocument().encoded().write(to: lifetime)
        try FileManager.default.createDirectory(at: native, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try JSONValue.object(["providers": []]).encoded().write(to: native.appendingPathComponent("providers.json"))
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: native.appendingPathComponent("providers.json").path)
        let runtime = try NativeRuntime(paths: NativePaths(root: native, home: home)); await runtime.jobs.suspendForShutdown()
        let clock = StatisticsLatencyClock(now), service = NativeStatisticsService(runtime: runtime, environment: [:], calendar: utc, clock: { clock.read() })
        return Fixture(root: root, home: home, source: source, lifetime: lifetime, ledger: runtime.paths.data.appendingPathComponent("results.jsonl"), runtime: runtime, service: service, clock: clock, rows: input.rows)
    }
    private func assertOverview(_ f: Fixture, rows: [StatisticsUsage]? = nil, document: JSONValue? = nil, range: Int = 0, source: String = "all", file: StaticString = #filePath, line: UInt = #line) async throws -> JSONValue {
        let rows = rows ?? f.rows, cache = StatisticsCache.parse(document ?? cacheDocument()), now = f.clock.read()
        let value = try await f.service.handle("overview", input: ["range": .number(Double(range)), "source": .string(source)])
        XCTAssertTrue(value["loaded"].bool, file: file, line: line)
        XCTAssertEqual(value["derived"], StatisticsFold.sources(rows, range: range, cache: cache, source: source, now: now, calendar: utc).json, file: file, line: line)
        XCTAssertEqual(value["sources"], originalTotals(rows, range: range, cache: cache, now: now, calendar: utc), file: file, line: line)
        return value
    }
    private func assertDetail(_ f: Fixture, model: String, range: Int = 0, source: String = "all", rows: [StatisticsUsage]? = nil, document: JSONValue? = nil, file: StaticString = #filePath, line: UInt = #line) async throws -> JSONValue {
        let rows = rows ?? f.rows, cache = StatisticsCache.parse(document ?? cacheDocument()), now = f.clock.read()
        let actual = try await f.service.handle("model", input: ["model": .string(model), "range": .number(Double(range)), "source": .string(source)])
        let expected = try XCTUnwrap(StatisticsFold.detail(rows, range: range, cache: cache, source: source, model: model, now: now, calendar: utc), file: file, line: line)
        for key in ["derived", "coverage", "datedSummary"] { XCTAssertEqual(actual[key], expected[key], key, file: file, line: line) }
        var totals: JSONObject = [:]
        for item in StatisticsSource.allCases {
            let original = StatisticsFold.detail(rows, range: range, cache: cache, source: item.rawValue, model: model, now: now, calendar: utc)
            totals[item.rawValue] = original.flatMap { $0["derived"]["events"].int > 0 || $0["coverage"]["lifetime"].bool ? $0["derived"]["summary"]["totals"] : nil } ?? .null
        }
        XCTAssertEqual(actual["sources"], .object(totals), file: file, line: line)
        return actual
    }

    func testBatchedPersistencePreservesEveryColumnAndRowOrderAcrossPartialBatch() async throws {
        let f = try await fixture(), initial = try await assertOverview(f)
        XCTAssertEqual(initial["scan"]["records"], 71); XCTAssertEqual(initial["scan"]["parsedFiles"], 1)
        let persisted = try f.runtime.db.query("SELECT * FROM stats_records ORDER BY rowid")
        let canonical = try XCTUnwrap(realpath(f.source.path, nil))
        defer { free(canonical) }
        let sourcePath = String(cString: canonical)
        let ordered = frames().rows.sorted { Int($0.id.dropFirst(4))! < Int($1.id.dropFirst(4))! }
        XCTAssertEqual(persisted.count, ordered.count)
        for (actual, e) in zip(persisted, ordered) {
            let expected: JSONObject = ["path": .string(sourcePath), "msg_id": .string(e.id), "ts": .number(e.ts), "raw_day": .string(e.rawDay), "model": .string(e.model), "project": .string(e.project), "session": .string(e.session), "sidechain": .number(e.sidechain ? 1 : 0), "effort": .string(e.effort), "input": .number(e.input), "output": .number(e.output), "thinking": .number(e.thinking), "cache_write": .number(e.cacheWrite), "cache_read": .number(e.cacheRead), "web_search": .number(e.webSearch), "web_fetch": .number(e.webFetch), "source": .string(e.source), "duration_ms": 1000, "timing": "estimated", "stream_duration_ms": .null, "stream_output_tokens": .null, "stream_timing": .null]
            XCTAssertEqual(actual, expected)
        }
        let reload = try await f.service.handle("rescan")
        XCTAssertEqual(reload["scan"]["parsedFiles"], 1, "Explicit Reload reparses even unchanged input")
        XCTAssertEqual(try f.runtime.db.query("SELECT * FROM stats_records ORDER BY rowid"), persisted)
        _ = try await assertOverview(f)
    }

    func testModelCacheKeepsExactScopesAndDayRollover() async throws {
        let f = try await fixture()
        for range in [0, 7, 30, 90, 365] {
            for source in ["all"] + StatisticsSource.allCases.map(\.rawValue) {
                _ = try await assertDetail(f, model: shared, range: range, source: source)
                let first = try await assertDetail(f, model: pruned, range: range, source: source)
                let again = try await assertDetail(f, model: pruned, range: range, source: source)
                XCTAssertEqual(first, again)
            }
        }
        let before = try await assertDetail(f, model: shared, range: 7)
        let old = before["derived"]["events"].int
        f.clock.advance(120_000); try await f.service.start()
        let nextDay = try await assertDetail(f, model: shared, range: 7)
        XCTAssertLessThan(nextDay["derived"]["events"].int, old)
        _ = try await assertOverview(f, range: 7)
    }

    func testUnchangedChecksReuseGenerationAndCacheOnlyChangesRefold() async throws {
        let f = try await fixture(count: 257)
        let initial = try await assertOverview(f), records = try f.runtime.db.query("SELECT * FROM stats_records ORDER BY path,rowid")
        let first = try await assertDetail(f, model: shared)
        f.clock.advance(31_000)
        let begin = ProcessInfo.processInfo.systemUptime; try await f.service.start()
        let elapsed = (ProcessInfo.processInfo.systemUptime - begin) * 1000
        let unchanged = try await assertOverview(f)
        XCTAssertEqual(unchanged["scan"]["parsedFiles"], 0)
        XCTAssertEqual(unchanged["derived"], initial["derived"])
        let repeated = try await f.service.handle("model", input: ["model": .string(shared)])
        XCTAssertEqual(repeated, first)
        XCTAssertEqual(try f.runtime.db.query("SELECT * FROM stats_records ORDER BY path,rowid"), records)
        print("Statistics unchanged metadata check: 257 synthetic responses, \(elapsed) ms")

        let changed = cacheDocument(input: 9000)
        try changed.encoded().write(to: f.lifetime)
        f.clock.advance(31_000); try await f.service.start()
        let refreshed = try await assertOverview(f, document: changed)
        XCTAssertEqual(refreshed["scan"]["parsedFiles"], 0)
        XCTAssertEqual(refreshed["derived"]["summary"]["totals"]["input"].double - initial["derived"]["summary"]["totals"]["input"].double, 8000)
        _ = try await assertDetail(f, model: shared, document: changed)
        XCTAssertEqual(try f.runtime.db.query("SELECT * FROM stats_records ORDER BY path,rowid"), records)
    }

    func testBatchFailureRollsBackEarlierBatchesAndKeepsCompleteQueryGeneration() async throws {
        let f = try await fixture()
        let initial = try await assertOverview(f), old = try await assertDetail(f, model: shared)
        let persisted = try f.runtime.db.query("SELECT * FROM stats_records ORDER BY rowid")
        try write(frames(firstInput: 9).frames, at: f.source)
        // Row 35 is in the second 32-row INSERT. Its failure must also roll
        // back the earlier successful batch and the file's initial DELETE.
        try f.runtime.db.executeScript("CREATE TRIGGER fixture_reject_stats BEFORE INSERT ON stats_records WHEN NEW.msg_id='row-35' BEGIN SELECT RAISE(ABORT,'fixture second batch failure'); END;")
        _ = try await f.service.handle("rescan")
        let held = try await f.service.handle("overview")
        XCTAssertEqual(held["derived"], initial["derived"])
        XCTAssertTrue(held["warnings"].array.contains { $0.string.contains("fixture second batch failure") })
        let detail = try await f.service.handle("model", input: ["model": .string(shared)])
        XCTAssertEqual(detail, old)
        XCTAssertEqual(try f.runtime.db.query("SELECT * FROM stats_records ORDER BY rowid"), persisted)
        try f.runtime.db.executeScript("DROP TRIGGER fixture_reject_stats")
        _ = try await f.service.handle("rescan")
        _ = try await assertOverview(f, rows: frames(firstInput: 9).rows)
        _ = try await assertDetail(f, model: shared, rows: frames(firstInput: 9).rows)
    }

    func testAnotherReaderCannotMakeAnOlderGenerationLookUnchanged() async throws {
        let f = try await fixture()
        _ = try await assertOverview(f)
        var original = stat(); XCTAssertEqual(lstat(f.source.path, &original), 0)
        try write(frames(firstInput: 9).frames, at: f.source)
        let times = [original.st_atimespec, timespec(tv_sec: original.st_mtimespec.tv_sec + 1, tv_nsec: original.st_mtimespec.tv_nsec)]
        XCTAssertEqual(times.withUnsafeBufferPointer { utimensat(AT_FDCWD, f.source.path, $0.baseAddress, 0) }, 0)
        let other = NativeStatisticsService(runtime: f.runtime, environment: [:], calendar: utc, clock: { f.clock.read() })
        let refreshed = try await other.handle("overview")
        XCTAssertEqual(refreshed["scan"]["parsedFiles"], 1)
        f.clock.advance(31_000); try await f.service.start()
        let current = try await assertOverview(f, rows: frames(firstInput: 9).rows)
        XCTAssertEqual(current["scan"]["parsedFiles"], 0, "The second reader already persisted this input")
        XCTAssertEqual(current["derived"], refreshed["derived"])
    }

    func testOneOverviewPinsItsDayWhenClockCrossesMidnightInsideTheQuery() async throws {
        let f = try await fixture()
        try await f.service.start()
        f.clock.armAdvance(afterReads: 2, delta: 120_000)
        let response = try await f.service.handle("overview", input: ["range": 7])
        XCTAssertEqual(f.clock.readCount, 2, "One staleness check and one pinned query time; nested projections must not read a new day")
        let expected = StatisticsFold.sources(f.rows, range: 7, cache: StatisticsCache.parse(cacheDocument()), source: "all", now: now, calendar: utc)
        XCTAssertEqual(response["derived"], expected.json)
        XCTAssertEqual(response["sources"], originalTotals(f.rows, range: 7, cache: StatisticsCache.parse(cacheDocument()), now: now, calendar: utc))
    }

    func testAnotherFullReaderRevisionInvalidatesIdenticalPhysicalMetadata() async throws {
        let f = try await fixture()
        _ = try await assertOverview(f)
        _ = try await assertDetail(f, model: shared)
        let originalCSV = try await f.service.handle("exportDailyCSV", input: ["model": .string(shared)])
        let oldSize = try Data(contentsOf: f.source).count
        var original = stat(); XCTAssertEqual(lstat(f.source.path, &original), 0)
        let before = try f.runtime.db.query("SELECT * FROM stats_files ORDER BY path")
        try write(frames(firstInput: 9).frames, at: f.source)
        let times = [original.st_atimespec, original.st_mtimespec]
        XCTAssertEqual(times.withUnsafeBufferPointer { utimensat(AT_FDCWD, f.source.path, $0.baseAddress, 0) }, 0)
        XCTAssertEqual(try Data(contentsOf: f.source).count, oldSize)
        var replaced = stat(); XCTAssertEqual(lstat(f.source.path, &replaced), 0)
        XCTAssertEqual(replaced.st_mtimespec.tv_sec, original.st_mtimespec.tv_sec)
        XCTAssertEqual(replaced.st_mtimespec.tv_nsec, original.st_mtimespec.tv_nsec)
        let other = NativeStatisticsService(runtime: f.runtime, environment: [:], calendar: utc, clock: { f.clock.read() })
        _ = try await other.handle("rescan")
        let after = try f.runtime.db.query("SELECT * FROM stats_files ORDER BY path")
        XCTAssertEqual(after[0]["mtime"], before[0]["mtime"])
        XCTAssertEqual(after[0]["size"], before[0]["size"])
        XCTAssertNotEqual(after[0]["record_revision"], before[0]["record_revision"])
        f.clock.advance(31_000); try await f.service.start()
        let adopted = try await assertOverview(f, rows: frames(firstInput: 9).rows)
        XCTAssertEqual(adopted["scan"]["parsedFiles"], 0, "Adopt the new persisted rows without parsing unchanged source bytes again")
        _ = try await assertDetail(f, model: shared, rows: frames(firstInput: 9).rows)
        let adoptedCSV = try await f.service.handle("exportDailyCSV", input: ["model": .string(shared)])
        XCTAssertNotEqual(adoptedCSV, originalCSV)
    }

    func testDeletedAndRecreatedFileCannotReuseItsOldCacheCommitIdentity() async throws {
        let f = try await fixture()
        _ = try await assertOverview(f)
        _ = try await assertDetail(f, model: shared)
        var original = stat(); XCTAssertEqual(lstat(f.source.path, &original), 0)
        let oldSize = try Data(contentsOf: f.source).count
        let before = try f.runtime.db.query("SELECT * FROM stats_files ORDER BY path")
        let other = NativeStatisticsService(runtime: f.runtime, environment: [:], calendar: utc, clock: { f.clock.read() })
        try FileManager.default.removeItem(at: f.source)
        _ = try await other.handle("rescan")
        XCTAssertTrue(try f.runtime.db.query("SELECT * FROM stats_files").isEmpty)
        try write(frames(firstInput: 9).frames, at: f.source)
        let times = [original.st_atimespec, original.st_mtimespec]
        XCTAssertEqual(times.withUnsafeBufferPointer { utimensat(AT_FDCWD, f.source.path, $0.baseAddress, 0) }, 0)
        XCTAssertEqual(try Data(contentsOf: f.source).count, oldSize)
        _ = try await other.handle("rescan")
        let after = try f.runtime.db.query("SELECT * FROM stats_files ORDER BY path")
        XCTAssertEqual(after[0]["mtime"], before[0]["mtime"])
        XCTAssertEqual(after[0]["size"], before[0]["size"])
        XCTAssertNotEqual(after[0]["record_revision"], before[0]["record_revision"])
        f.clock.advance(31_000); try await f.service.start()
        let adopted = try await assertOverview(f, rows: frames(firstInput: 9).rows)
        XCTAssertEqual(adopted["scan"]["parsedFiles"], 0)
        _ = try await assertDetail(f, model: shared, rows: frames(firstInput: 9).rows)
    }

    func testFailedDiscoveryRetainsCachesAndSourceDeletionPublishesNewCompleteGeneration() async throws {
        let f = try await fixture()
        let initial = try await assertOverview(f), old = try await assertDetail(f, model: shared)
        let changed = cacheDocument(input: 9000)
        try changed.encoded().write(to: f.lifetime)
        let directory = f.source.deletingLastPathComponent()
        guard getuid() != 0, chmod(directory.path, 0) == 0 else { throw NativeFailure("Private EACCES fixture requires an unprivileged test user") }
        do {
            defer { XCTAssertEqual(chmod(directory.path, 0o700), 0) }
            do { _ = try await f.service.handle("rescan"); XCTFail("Incomplete discovery must not publish a partial generation") }
            catch { XCTAssertFalse(error is CancellationError) }
            let held = try await f.service.handle("overview"), detail = try await f.service.handle("model", input: ["model": .string(shared)])
            XCTAssertEqual(held["derived"], initial["derived"]); XCTAssertEqual(detail, old)
        }
        try FileManager.default.removeItem(at: f.source)
        f.clock.advance(31_000); try await f.service.start()
        let empty = try await assertOverview(f, rows: [], document: changed)
        XCTAssertEqual(empty["derived"]["events"], 0)
        _ = try await assertDetail(f, model: shared, rows: [], document: changed)
        XCTAssertTrue(try f.runtime.db.query("SELECT * FROM stats_records").isEmpty)
    }

    func testWarmModelDetailsAvoidRepeatingTheCorpusFold() async throws {
        let f = try await fixture(count: 257)
        _ = try await assertOverview(f)
        let begin = ProcessInfo.processInfo.systemUptime
        let first = try await f.service.handle("model", input: ["model": .string(shared)])
        let cold = ProcessInfo.processInfo.systemUptime - begin
        var samples: [Double] = []
        for _ in 0..<9 {
            let begin = ProcessInfo.processInfo.systemUptime
            let warm = try await f.service.handle("model", input: ["model": .string(shared)])
            samples.append(ProcessInfo.processInfo.systemUptime - begin)
            XCTAssertEqual(warm, first)
        }
        let warm = samples.sorted()[4]
        print("Statistics model detail: 257 synthetic rows, first \(cold * 1000) ms, warm median \(warm * 1000) ms, ratio \(warm / cold)")
        XCTAssertLessThan(warm, cold * 0.8, "Warm model queries must reuse a complete scope snapshot")
    }

    func testExplicitFullReloadBypassesSameMetadataReuseAndInvalidatesBenchBeforeEvent() async throws {
        let f = try await fixture()
        let initial = try await assertOverview(f)
        let row: JSONValue = ["id": "bench", "provider": "fixture", "model": .string(shared), "run_id": "one", "ts": "2026-10-23T00:00:00Z", "ok": true, "tokens": ["in": 13, "out": 6]]
        try write([row], at: f.ledger)
        let old = try await assertDetail(f, model: shared)
        XCTAssertEqual(old["bench"]["spend"]["input"], 13)
        var sourceInfo = stat(), benchInfo = stat()
        XCTAssertEqual(lstat(f.source.path, &sourceInfo), 0); XCTAssertEqual(lstat(f.ledger.path, &benchInfo), 0)
        try write(frames(firstInput: 9).frames, at: f.source)
        var changed = row; changed["tokens"] = ["in": 19, "out": 6]; try write([changed], at: f.ledger)
        for (url, info) in [(f.source, sourceInfo), (f.ledger, benchInfo)] {
            let times = [info.st_atimespec, info.st_mtimespec]
            XCTAssertEqual(times.withUnsafeBufferPointer { utimensat(AT_FDCWD, url.path, $0.baseAddress, 0) }, 0)
            XCTAssertEqual(try NativeStatisticsService.checkedDiscoverySignature(url)?.size, Double(info.st_size))
        }
        f.clock.advance(31_000); try await f.service.start()
        let ordinary = try await f.service.handle("overview")
        XCTAssertEqual(ordinary["scan"]["parsedFiles"], 0)
        XCTAssertEqual(ordinary["derived"], initial["derived"])

        // Warm the benchmark metadata cache again, then restore the old bytes
        // at identical metadata so only full-scan invalidation exposes 13.
        let warm = try await f.service.handle("bench"); XCTAssertEqual(warm["spend"]["input"], 19)
        try write([row], at: f.ledger)
        let times = [benchInfo.st_atimespec, benchInfo.st_mtimespec]
        XCTAssertEqual(times.withUnsafeBufferPointer { utimensat(AT_FDCWD, f.ledger.path, $0.baseAddress, 0) }, 0)
        let stale = try await f.service.handle("bench"); XCTAssertEqual(stale["spend"]["input"], 19)
        let stream = await f.runtime.events.stream(), eventRead = expectation(description: "scan observer reads fresh benchmark")
        let observer = Task {
            for await event in stream where event.topic == "stats.scanned" {
                do { let value = try await f.service.handle("bench"); XCTAssertEqual(value["spend"]["input"], 13) }
                catch { XCTFail(String(describing: error)) }
                eventRead.fulfill(); return
            }
        }
        defer { observer.cancel() }
        let reload = try await f.service.handle("rescan")
        XCTAssertEqual(reload["scan"]["parsedFiles"], 1)
        await fulfillment(of: [eventRead], timeout: 2)
        _ = try await assertOverview(f, rows: frames(firstInput: 9).rows)
        _ = try await assertDetail(f, model: shared, rows: frames(firstInput: 9).rows)
    }
}

private final class StatisticsLatencyClock: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Double
    private var reads = 0, stepAfter: Int?
    private var stepDelta: Double = 0
    init(_ value: Double) { self.value = value }
    var readCount: Int { lock.lock(); defer { lock.unlock() }; return reads }
    func armAdvance(afterReads: Int, delta: Double) { lock.lock(); reads = 0; stepAfter = afterReads; stepDelta = delta; lock.unlock() }
    func read() -> Double {
        lock.lock(); defer { lock.unlock() }
        reads += 1; let result = value
        if reads == stepAfter { value += stepDelta; stepAfter = nil }
        return result
    }
    func advance(_ delta: Double) { lock.lock(); value += delta; lock.unlock() }
}
