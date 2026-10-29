import XCTest
import Foundation
import Darwin
@testable import UniApiCore

/// Synthetic ledgers only. The unchanged full importer is the parser oracle;
/// service cases exercise real discovery, file transactions and revision joins.
final class StatisticsCodexAppendTests: XCTestCase {
    private struct Fixture {
        let runtime: NativeRuntime, service: NativeStatisticsService, source: URL
    }

    private func directory() throws -> URL {
        let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
            .appendingPathComponent("statistics-codex-append-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root
    }

    private func put(_ bytes: Data, at url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if !FileManager.default.fileExists(atPath: url.path) { try Data().write(to: url) }
        let file = try FileHandle(forWritingTo: url)
        defer { try? file.close() }
        try file.truncate(atOffset: 0)
        try file.write(contentsOf: bytes)
    }

    private func append(_ bytes: Data, to url: URL) throws {
        let file = try FileHandle(forWritingTo: url)
        defer { try? file.close() }
        _ = try file.seekToEnd()
        try file.write(contentsOf: bytes)
    }

    private func frame(_ type: String, _ payload: JSONObject, at: String? = nil) -> JSONValue {
        var value: JSONObject = ["type": .string(type), "payload": .object(payload)]
        if let at { value["timestamp"] = .string(at) }
        return .object(value)
    }

    private func context(_ turn: String, model: String = "fixture-model-A", cwd: String = "fixture/東京") -> JSONValue {
        frame("turn_context", ["turn_id": .string(turn), "model": .string(model), "cwd": .string(cwd), "effort": "xhigh"])
    }

    private var header: [JSONValue] {
        [frame("session_meta", ["id": "fixture-session", "cwd": "fixture/meta", "source": ["subagent": [:]]]), context("turn")]
    }

    private func usage(_ id: String, turn: String = "turn", at: String = "2026-10-29T10:00:02.123456+02:00",
                       input: Double = 100.25, output: Double = 20.5) -> JSONValue {
        frame("token_usage_record", ["turn_id": .string(turn), "response_id": .string(id),
              "usage": ["input_tokens": .number(input), "output_tokens": .number(output), "cached_input_tokens": 3.125,
                        "cache_write_input_tokens": 1.75, "reasoning_output_tokens": 2.25]], at: at)
    }

    private func count(_ total: Double, turn: String, second: Int, input: Double = 10, output: Double = 2) -> JSONValue {
        frame("event_msg", ["type": "token_count", "turn_id": .string(turn),
              "info": ["total_token_usage": ["total_tokens": .number(total)],
                       "last_token_usage": ["input_tokens": .number(input), "output_tokens": .number(output)]]],
              at: String(format: "2026-10-29T08:00:%02dZ", second))
    }

    private func lines(_ values: [JSONValue], ending: String = "\n") throws -> Data {
        var result = Data()
        for value in values { result.append(try value.encoded()); result.append(Data(ending.utf8)) }
        return result
    }

    private func assertEqual(_ actual: StatisticsReadResult, _ expected: StatisticsReadResult,
                             file: StaticString = #filePath, line: UInt = #line) throws {
        XCTAssertEqual(actual.excluded, expected.excluded, file: file, line: line)
        // Codable equality covers every stored field, including future additions;
        // compare numeric bits separately so JSON round-tripping cannot hide them.
        XCTAssertEqual(try JSONValue.decode(JSONEncoder().encode(actual.records)),
                       try JSONValue.decode(JSONEncoder().encode(expected.records)), file: file, line: line)
        XCTAssertEqual(actual.records.count, expected.records.count, file: file, line: line)
        for (a, b) in zip(actual.records, expected.records) {
            XCTAssertEqual([a.ts, a.input, a.output, a.thinking, a.cacheWrite, a.cacheRead, a.webSearch, a.webFetch].map(\.bitPattern),
                           [b.ts, b.input, b.output, b.thinking, b.cacheWrite, b.cacheRead, b.webSearch, b.webFetch].map(\.bitPattern), file: file, line: line)
            XCTAssertEqual([a.durationMs, a.streamDurationMs, a.streamOutputTokens].map { $0?.bitPattern },
                           [b.durationMs, b.streamDurationMs, b.streamOutputTokens].map { $0?.bitPattern }, file: file, line: line)
        }
    }

    @discardableResult private func checked(_ url: URL, checkpoint: StatisticsCodexCheckpoint? = nil,
                                            file: StaticString = #filePath, line: UInt = #line) throws -> StatisticsCodexAppendRead {
        let actual = try StatisticsCodexAppend.read(url, checkpoint: checkpoint)
        try assertEqual(actual.result, StatisticsImporter.read(url, source: "codex"), file: file, line: line)
        return actual
    }

    private func fixture(_ bytes: Data) async throws -> Fixture {
        let root = try directory(), home = root.appendingPathComponent("home")
        try NativeFile.writeAtomic(try JSONValue.object(["providers": []]).encoded(), to: root.appendingPathComponent("providers.example.json"))
        let source = home.appendingPathComponent(".codex/sessions/fixture/session.jsonl")
        try put(bytes, at: source)
        let runtime = try NativeRuntime(paths: NativePaths(root: root, home: home))
        await runtime.jobs.suspendForShutdown()
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let service = NativeStatisticsService(runtime: runtime, environment: [:], calendar: calendar,
                                              clock: { Date().timeIntervalSince1970 * 1000 })
        return Fixture(runtime: runtime, service: service, source: source)
    }

    private func assertPersisted(_ fixture: Fixture, ledger: URL? = nil,
                                 file: StaticString = #filePath, line: UInt = #line) throws {
        var expected = try StatisticsImporter.read(ledger ?? fixture.source, source: "codex")
        // Persistence materializes the UTC day; the transcript reader leaves it empty.
        for i in expected.records.indices where expected.records[i].rawDay.isEmpty { expected.records[i].rawDay = statisticsUTC(expected.records[i].ts) }
        var columns = StatisticsCachedRecordColumns([]), records: [StatisticsUsage] = []
        try fixture.runtime.db.forEachValueRow("SELECT * FROM stats_records ORDER BY path,rowid", columns: {
            columns = StatisticsCachedRecordColumns($0)
        }) { records.append(columns.usage(in: $0)) }
        let excluded = try fixture.runtime.db.query("SELECT excluded_usage FROM stats_files").reduce(0) { $0 + ($1["excluded_usage"] ?? 0).int }
        try assertEqual(StatisticsReadResult(records: records, excluded: excluded), expected, file: file, line: line)
    }

    private func metadata(_ url: URL) throws -> stat {
        var info = stat()
        guard lstat(url.path, &info) == 0 else { throw NativeFailure("Synthetic ledger metadata unavailable") }
        return info
    }

    private func restoreTimes(_ info: stat, at url: URL) throws {
        let times = [info.st_atimespec, info.st_mtimespec]
        guard times.withUnsafeBufferPointer({ utimensat(AT_FDCWD, url.path, $0.baseAddress, 0) }) == 0 else {
            throw NativeFailure("Cannot restore synthetic ledger times")
        }
    }

    func testEveryByteAppendMatchesAllFullImporterFieldsAcrossUnicodeCRLFAndMalformedRows() throws {
        let url = try directory().appendingPathComponent("bytes.jsonl")
        var bytes = try lines(header + [usage("first", input: 9_007_199_254_740_992)])
        try put(bytes, at: url)
        let initial = try checked(url), original = try XCTUnwrap(initial.checkpoint)
        XCTAssertEqual(initial.validatedPrefixBytes, 0); XCTAssertEqual(initial.decodedBytes, Int64(bytes.count))
        var checkpoint = original
        var suffix = try lines([context("unicode", model: "fixture-東京-𝄞"), usage("second", turn: "unicode")], ending: "\r\n")
        suffix.append(Data("\ninvalid\n".utf8)); suffix.append(contentsOf: [255, 254, 10])
        suffix.append(try lines([usage("third", turn: "unicode", output: 0.5)]))
        suffix.append(try usage("second", turn: "unicode", output: 7.75).encoded())
        for byte in suffix {
            let pending = bytes.lastIndex(of: 10).map { bytes.distance(from: $0, to: bytes.endIndex) - 1 } ?? bytes.count
            let previousLength = checkpoint.length
            try append(Data([byte]), to: url); bytes.append(byte)
            let actual = try checked(url, checkpoint: checkpoint)
            XCTAssertEqual(actual.validatedPrefixBytes, previousLength)
            XCTAssertEqual(actual.decodedBytes, Int64(pending + 1))
            checkpoint = try XCTUnwrap(actual.checkpoint)
            XCTAssertEqual(checkpoint.length, Int64(bytes.count))
        }
        let replay = try checked(url, checkpoint: original)
        XCTAssertEqual(replay.validatedPrefixBytes, original.length, "Later readers must not mutate an older value snapshot")
        XCTAssertEqual(replay.result.records.map(\.id), ["codex:first", "codex:second", "codex:third", "codex:second"])
        XCTAssertEqual(replay.result.records[1].model, "fixture-東京-𝄞")
        XCTAssertTrue(replay.result.records.allSatisfy(\.sidechain))
    }

    func testValidUnterminatedTailCanBeInvalidatedWithoutKeepingItsPublishedRecord() throws {
        let url = try directory().appendingPathComponent("tail.jsonl")
        var bytes = try lines(header + [usage("stable")]); bytes.append(try usage("provisional").encoded())
        try put(bytes, at: url)
        let first = try checked(url), saved = try XCTUnwrap(first.checkpoint)
        XCTAssertEqual(first.result.records.map(\.id), ["codex:stable", "codex:provisional"])
        try append(Data("x\n".utf8), to: url)
        let invalidated = try checked(url, checkpoint: saved)
        XCTAssertEqual(invalidated.validatedPrefixBytes, saved.length)
        XCTAssertEqual(invalidated.result.records.map(\.id), ["codex:stable"])
        let next = try XCTUnwrap(invalidated.checkpoint)
        try append(try usage("later").encoded(), to: url)
        let later = try checked(url, checkpoint: next)
        XCTAssertEqual(later.result.records.map(\.id), ["codex:stable", "codex:later"])
        try append(Data(" \r\n\n".utf8), to: url)
        let terminated = try checked(url, checkpoint: XCTUnwrap(later.checkpoint))
        XCTAssertEqual(terminated.result.records.map(\.id), ["codex:stable", "codex:later"])
        _ = try checked(url, checkpoint: saved)
    }

    func testModernReplacementKeepsFallbackOrderExclusionMultiplicityAndCumulativeResetState() throws {
        let url = try directory().appendingPathComponent("fallback.jsonl")
        let base = header + [context("old"), count(12, turn: "old", second: 1), count(12, turn: "old", second: 2),
                             count(6, turn: "old", second: 3), context("replace"), count(24, turn: "replace", second: 4),
                             count(25, turn: "replace", second: 5, input: 0, output: 0),
                             count(26, turn: "replace", second: 6, input: 0, output: 0), context("excluded"),
                             count(27, turn: "excluded", second: 7, input: 0, output: 0),
                             count(28, turn: "excluded", second: 8, input: 0, output: 0)]
        try put(try lines(base), at: url)
        let first = try checked(url)
        XCTAssertEqual(first.result.records.count, 3); XCTAssertEqual(first.result.excluded, 4)
        try append(try lines([usage("modern", turn: "replace")]), to: url)
        let modern = try checked(url, checkpoint: XCTUnwrap(first.checkpoint))
        XCTAssertGreaterThan(modern.validatedPrefixBytes, 0)
        XCTAssertEqual(modern.result.excluded, 2)
        XCTAssertEqual(modern.result.records.first?.id, "codex:modern")
        XCTAssertEqual(Array(modern.result.records.dropFirst().map(\.id)), Array(first.result.records.prefix(2).map(\.id)))
        // Ignored modern mirrors still update the global cumulative checkpoint.
        try append(try lines([count(40, turn: "replace", second: 9), context("fresh"),
                              count(40, turn: "fresh", second: 10), count(4, turn: "fresh", second: 11),
                              count(4, turn: "fresh", second: 12)]), to: url)
        let reset = try checked(url, checkpoint: XCTUnwrap(modern.checkpoint))
        XCTAssertEqual(reset.result.records.count, 4); XCTAssertEqual(reset.result.excluded, 2)
        XCTAssertEqual(reset.result.records.last?.ts, statisticsTimestamp(.string("2026-10-29T08:00:11Z")))
    }

    func testOutstandingToolsExplicitTurnsAndClearedResponseStartsSurviveCheckpoints() throws {
        let url = try directory().appendingPathComponent("clocks.jsonl")
        let base = header + [context("A", model: "model-A", cwd: "fixture/A"),
                             frame("event_msg", ["type": "task_started", "turn_id": "A"], at: "2026-10-29T08:00:00Z"),
                             frame("response_item", ["type": "function_call", "call_id": "one", "turn_id": "A"]),
                             frame("response_item", ["type": "custom_tool_call", "call_id": "two", "turn_id": "A"])]
        try put(try lines(base), at: url)
        let first = try checked(url)
        try append(try lines([context("B", model: "model-B", cwd: "fixture/B"),
                              frame("response_item", ["type": "function_call_output", "call_id": "one", "turn_id": "A"], at: "2026-10-29T08:00:02Z"),
                              usage("A-while-tool", turn: "A", at: "2026-10-29T08:00:03Z"),
                              usage("B", turn: "B", at: "2026-10-29T08:00:04Z")]), to: url)
        let partial = try checked(url, checkpoint: XCTUnwrap(first.checkpoint))
        XCTAssertEqual(partial.result.records.first?.durationMs, 3000, "One remaining tool must prevent a premature response-start reset")
        XCTAssertNil(partial.result.records.last?.durationMs)
        try append(try lines([
            frame("response_item", ["type": "custom_tool_call_output", "call_id": "two", "turn_id": "A"], at: "2026-10-29T08:00:10Z"),
            usage("A", turn: "A", at: "2026-10-29T08:00:12Z"),
            frame("event_msg", ["type": "task_aborted", "turn_id": "A"], at: "2026-10-29T08:00:13Z"),
            usage("aborted", turn: "A", at: "2026-10-29T08:00:14Z"),
            frame("response_item", ["type": "message", "role": "user", "turn_id": "A"], at: "2026-10-29T08:00:15Z"),
            usage("user-boundary", turn: "A", at: "2026-10-29T08:00:17Z"),
            usage("no-reused-clock", turn: "A", at: "2026-10-29T08:00:19Z")]), to: url)
        let final = try checked(url, checkpoint: XCTUnwrap(partial.checkpoint))
        XCTAssertEqual(final.result.records.map(\.id), ["codex:A-while-tool", "codex:B", "codex:A", "codex:aborted", "codex:user-boundary", "codex:no-reused-clock"])
        XCTAssertEqual(final.result.records.map(\.durationMs), [3000, nil, 2000, nil, 2000, nil])
        XCTAssertEqual(final.result.records.map(\.model), ["model-A", "model-B", "model-A", "model-A", "model-A", "model-A"])
        XCTAssertEqual(final.result.records[2].project, "fixture/A"); XCTAssertEqual(final.result.records[2].effort, "xhigh")
    }

    func testPrefixRewriteGrowthTruncationReplacementAndRenameFallBackToFullRead() throws {
        let root = try directory(), url = root.appendingPathComponent("identity.jsonl")
        let base = try lines(header + [usage("original")])
        try put(base, at: url)
        let original = try XCTUnwrap(checked(url).checkpoint), inode = try metadata(url).st_ino
        var rewrite = header; rewrite[1] = context("turn", model: "rewritten-model")
        let grown = try lines(rewrite + [usage("original"), usage("growth")])
        try put(grown, at: url)
        XCTAssertEqual(try metadata(url).st_ino, inode)
        let rewritten = try checked(url, checkpoint: original)
        XCTAssertEqual(rewritten.validatedPrefixBytes, 0); XCTAssertEqual(rewritten.decodedBytes, Int64(grown.count))
        XCTAssertEqual(rewritten.result.records.first?.model, "rewritten-model")
        try put(try lines(header), at: url)
        let truncated = try checked(url, checkpoint: XCTUnwrap(rewritten.checkpoint))
        XCTAssertEqual(truncated.validatedPrefixBytes, 0); XCTAssertTrue(truncated.result.records.isEmpty)
        let replacement = root.appendingPathComponent("replacement.jsonl")
        try put(base, at: replacement)
        XCTAssertNotEqual(try metadata(replacement).st_ino, try metadata(url).st_ino)
        XCTAssertEqual(rename(replacement.path, url.path), 0)
        let replaced = try checked(url, checkpoint: XCTUnwrap(truncated.checkpoint))
        XCTAssertEqual(replaced.validatedPrefixBytes, 0); XCTAssertEqual(replaced.decodedBytes, Int64(base.count))
        let renamed = root.appendingPathComponent("renamed.jsonl")
        try FileManager.default.moveItem(at: url, to: renamed)
        try append(try lines([usage("after-rename")]), to: renamed)
        let moved = try checked(renamed, checkpoint: XCTUnwrap(replaced.checkpoint))
        XCTAssertEqual(moved.validatedPrefixBytes, 0)
        XCTAssertThrowsError(try StatisticsCodexAppend.read(url, checkpoint: replaced.checkpoint))
        try FileManager.default.createSymbolicLink(at: url, withDestinationURL: renamed)
        XCTAssertThrowsError(try StatisticsCodexAppend.read(url, checkpoint: replaced.checkpoint))
    }

    func testCacheRequiresExactOpaqueRevisionSourcePathMtimeAndSize() throws {
        let url = try directory().appendingPathComponent("binding.jsonl")
        try put(try lines(header + [usage("one")]), at: url)
        let cp = try XCTUnwrap(checked(url).checkpoint), revision = UUID().uuidString, key = url.path
        func seeded() -> StatisticsCodexAppendCache {
            var cache = StatisticsCodexAppendCache()
            cache.commit(cp, path: key, sourcePath: url.path, revision: revision, mtime: cp.mtime, size: Double(cp.length))
            return cache
        }
        var exact = seeded()
        XCTAssertNotNil(exact.checkpoint(path: key, sourcePath: url.path, revision: revision, mtime: cp.mtime, size: Double(cp.length)))
        let wrong: [(String, String, Double, Double)] = [
            (url.path, "", cp.mtime, Double(cp.length)), (url.path, UUID().uuidString, cp.mtime, Double(cp.length)),
            (url.path + ".zst", revision, cp.mtime, Double(cp.length)),
            (url.path, revision, cp.mtime + 1, Double(cp.length)), (url.path, revision, cp.mtime, Double(cp.length) + 1)]
        for (source, rev, mtime, size) in wrong {
            var cache = seeded()
            XCTAssertNil(cache.checkpoint(path: key, sourcePath: source, revision: rev, mtime: mtime, size: size))
            XCTAssertEqual(cache.count, 0); XCTAssertEqual(cache.estimatedBytes, 0)
        }
        let invalidCommits: [(String, String, Double, Double)] = [
            (url.path, "", cp.mtime, Double(cp.length)), (url.path + ".zst", revision, cp.mtime, Double(cp.length)),
            (url.path, revision, cp.mtime + 1, Double(cp.length)), (url.path, revision, cp.mtime, Double(cp.length) + 1)]
        for (source, rev, mtime, size) in invalidCommits {
            var cache = seeded()
            cache.commit(cp, path: key, sourcePath: source, revision: rev, mtime: mtime, size: size)
            XCTAssertEqual(cache.count, 0); XCTAssertEqual(cache.estimatedBytes, 0)
        }
        exact.commit(nil, path: key, sourcePath: url.path, revision: revision, mtime: cp.mtime, size: Double(cp.length))
        XCTAssertEqual(exact.count, 0); XCTAssertEqual(exact.estimatedBytes, 0)
        var misplaced = StatisticsCodexAppendCache()
        misplaced.commit(cp, path: key, sourcePath: url.path + ".other", revision: revision, mtime: cp.mtime, size: Double(cp.length))
        XCTAssertEqual(misplaced.count, 0)
    }

    func testCacheEvictsWithinByteAndEntryBudgetsAndOversizedTailOnlyDisablesCheckpoint() throws {
        let root = try directory()
        let urls = (0..<3).map { root.appendingPathComponent("budget-\($0).jsonl") }
        var checkpoints: [StatisticsCodexCheckpoint] = []
        for (i, url) in urls.enumerated() {
            try put(try lines(header + [usage("row-\(i)")]), at: url)
            checkpoints.append(try XCTUnwrap(checked(url).checkpoint))
        }
        let revisions = urls.map { _ in UUID().uuidString }
        func commit(_ i: Int, to cache: inout StatisticsCodexAppendCache) {
            let cp = checkpoints[i]
            cache.commit(cp, path: urls[i].path, sourcePath: urls[i].path, revision: revisions[i], mtime: cp.mtime, size: Double(cp.length))
        }
        func lookup(_ i: Int, in cache: inout StatisticsCodexAppendCache) -> StatisticsCodexCheckpoint? {
            let cp = checkpoints[i]
            return cache.checkpoint(path: urls[i].path, sourcePath: urls[i].path, revision: revisions[i], mtime: cp.mtime, size: Double(cp.length))
        }
        var entries = StatisticsCodexAppendCache(maximumBytes: checkpoints.reduce(0) { $0 + $1.estimatedBytes }, maximumEntries: 2)
        commit(0, to: &entries); commit(1, to: &entries); XCTAssertNotNil(lookup(0, in: &entries)); commit(2, to: &entries)
        XCTAssertEqual(entries.count, 2); XCTAssertNil(lookup(1, in: &entries))
        XCTAssertNotNil(lookup(0, in: &entries)); XCTAssertNotNil(lookup(2, in: &entries))
        XCTAssertEqual(entries.estimatedBytes, checkpoints[0].estimatedBytes + checkpoints[2].estimatedBytes)
        entries.retain([urls[0].path]); XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries.estimatedBytes, checkpoints[0].estimatedBytes)
        entries.remove(urls[0].path); XCTAssertEqual(entries.estimatedBytes, 0)
        commit(0, to: &entries); entries.removeAll(); XCTAssertEqual(entries.count, 0); XCTAssertEqual(entries.estimatedBytes, 0)
        var bytes = StatisticsCodexAppendCache(maximumBytes: checkpoints[0].estimatedBytes + checkpoints[1].estimatedBytes - 1, maximumEntries: 3)
        commit(0, to: &bytes); commit(1, to: &bytes)
        XCTAssertEqual(bytes.count, 1); XCTAssertNil(lookup(0, in: &bytes)); XCTAssertNotNil(lookup(1, in: &bytes))
        var tooSmall = StatisticsCodexAppendCache(maximumBytes: checkpoints[0].estimatedBytes - 1)
        commit(0, to: &tooSmall); XCTAssertEqual(tooSmall.count, 0); XCTAssertEqual(tooSmall.estimatedBytes, 0)
        var disabled = StatisticsCodexAppendCache(maximumBytes: -1, maximumEntries: -1)
        commit(0, to: &disabled); XCTAssertEqual(disabled.count, 0)
        var oversized = try lines(header + [usage("kept")])
        oversized.append(try frame("response_item", ["type": "message", "content": .string(String(repeating: "x", count: (1 << 20) + 1))]).encoded())
        try put(oversized, at: urls[0])
        let full = try checked(urls[0])
        XCTAssertNil(full.checkpoint); XCTAssertEqual(full.result.records.map(\.id), ["codex:kept"])
    }

    func testServiceRefreshUsesAppendButRebuildAndReadOnlyAlwaysUseFullImporter() async throws {
        let base = try lines(header + [usage("one")]), f = try await fixture(base)
        let initial = try await f.service.handle("overview", input: ["source": "codex"])
        XCTAssertEqual(initial["scan"]["parsedFiles"], 1); try assertPersisted(f)
        let addition = try lines([usage("two")]); try append(addition, to: f.source)
        let refresh = try await f.service.handle("refresh")
        XCTAssertEqual(refresh["scan"]["codexAppendFiles"], 1)
        XCTAssertEqual(refresh["scan"]["codexValidatedPrefixBytes"].double, Double(base.count))
        XCTAssertEqual(refresh["scan"]["codexAppendDecodedBytes"].double, Double(addition.count)); try assertPersisted(f)
        let unchanged = try await f.service.handle("refresh")
        XCTAssertEqual(unchanged["scan"]["parsedFiles"], 0); XCTAssertEqual(unchanged["scan"]["codexAppendFiles"], 0)
        let rebuild = try await f.service.handle("rescan")
        XCTAssertEqual(rebuild["scan"]["parsedFiles"], 1)
        XCTAssertEqual(rebuild["scan"]["codexAppendFiles"], 0); XCTAssertEqual(rebuild["scan"]["codexValidatedPrefixBytes"], 0)
        try append(try lines([usage("three")]), to: f.source)
        let afterRebuild = try await f.service.handle("refresh")
        XCTAssertEqual(afterRebuild["scan"]["codexAppendFiles"], 0); try assertPersisted(f)
        try append(try lines([usage("four")]), to: f.source)
        let warmAgain = try await f.service.handle("refresh")
        XCTAssertEqual(warmAgain["scan"]["codexAppendFiles"], 1); try assertPersisted(f)
        let beforeFiles = try f.runtime.db.query("SELECT * FROM stats_files ORDER BY path")
        let beforeRows = try f.runtime.db.query("SELECT rowid,* FROM stats_records ORDER BY path,rowid")
        let readonly = try NativeRuntime(paths: NativePaths(root: f.runtime.paths.root, home: f.runtime.paths.home, readOnly: true))
        await readonly.jobs.suspendForShutdown()
        let reader = NativeStatisticsService(runtime: readonly)
        _ = try await reader.handle("overview", input: ["source": "codex"])
        try append(try lines([usage("read-only")]), to: f.source)
        let readRefresh = try await reader.handle("refresh")
        XCTAssertEqual(readRefresh["scan"]["parsedFiles"], 1); XCTAssertEqual(readRefresh["scan"]["codexAppendFiles"], 0)
        XCTAssertEqual(try f.runtime.db.query("SELECT * FROM stats_files ORDER BY path"), beforeFiles)
        XCTAssertEqual(try f.runtime.db.query("SELECT rowid,* FROM stats_records ORDER BY path,rowid"), beforeRows)
        let board = try await reader.handle("overview", input: ["source": "codex"])
        XCTAssertEqual(board["derived"]["events"], 5)
    }

    func testServiceRollbackKeepsOldCheckpointAndForeignRevisionAndSameMetadataRebuildInvalidateIt() async throws {
        let base = try lines(header + [usage("one")]), f = try await fixture(base)
        _ = try await f.service.handle("overview")
        let beforeFiles = try f.runtime.db.query("SELECT * FROM stats_files ORDER BY path")
        let beforeRows = try f.runtime.db.query("SELECT rowid,* FROM stats_records ORDER BY path,rowid")
        try append(try lines([usage("two")]), to: f.source)
        try f.runtime.db.executeScript("CREATE TRIGGER fixture_codex_append_reject BEFORE INSERT ON stats_records WHEN NEW.msg_id='codex:two' BEGIN SELECT RAISE(ABORT,'fixture Codex append insert failure'); END;")
        let failed = try await f.service.handle("refresh")
        XCTAssertEqual(failed["scan"]["codexAppendFiles"], 0)
        XCTAssertEqual(try f.runtime.db.query("SELECT * FROM stats_files ORDER BY path"), beforeFiles)
        XCTAssertEqual(try f.runtime.db.query("SELECT rowid,* FROM stats_records ORDER BY path,rowid"), beforeRows)
        let held = try await f.service.handle("overview")
        XCTAssertTrue(held["warnings"].array.contains { $0.string.contains("fixture Codex append insert failure") })
        try append(try lines([usage("three")]), to: f.source)
        try f.runtime.db.executeScript("DROP TRIGGER fixture_codex_append_reject")
        let recovered = try await f.service.handle("refresh")
        XCTAssertEqual(recovered["scan"]["codexAppendFiles"], 1)
        XCTAssertEqual(recovered["scan"]["codexValidatedPrefixBytes"].double, Double(base.count), "Rollback cannot advance the parser past uncommitted rows")
        try assertPersisted(f)

        // Keep every prefix byte identical: only the foreign commit identity
        // can disqualify this actor's otherwise reusable checkpoint.
        let priorRevision = try f.runtime.db.query("SELECT record_revision FROM stats_files").first?["record_revision"]
        let foreign = NativeStatisticsService(runtime: f.runtime)
        _ = try await foreign.handle("rescan")
        XCTAssertNotEqual(try f.runtime.db.query("SELECT record_revision FROM stats_files").first?["record_revision"], priorRevision)
        try append(try lines([usage("four")]), to: f.source)
        let adopted = try await f.service.handle("refresh")
        XCTAssertEqual(adopted["scan"]["codexAppendFiles"], 0); XCTAssertEqual(adopted["scan"]["codexValidatedPrefixBytes"], 0)
        try assertPersisted(f)
        XCTAssertTrue(try f.runtime.db.query("SELECT model FROM stats_records").allSatisfy { $0["model"] == "fixture-model-A" })

        let sameStamp = try metadata(f.source), sameBytes = try Data(contentsOf: f.source)
        let rewritten = Data(String(decoding: sameBytes, as: UTF8.self).replacingOccurrences(of: "fixture-model-A", with: "fixture-model-B").utf8)
        XCTAssertEqual(rewritten.count, sameBytes.count)
        try put(rewritten, at: f.source); try restoreTimes(sameStamp, at: f.source)
        let rebuilt = try await f.service.handle("rescan")
        XCTAssertEqual(rebuilt["scan"]["parsedFiles"], 1); XCTAssertEqual(rebuilt["scan"]["codexAppendFiles"], 0)
        try assertPersisted(f)
        XCTAssertTrue(try f.runtime.db.query("SELECT model FROM stats_records").allSatisfy { $0["model"] == "fixture-model-B" })
    }

    // Independent raw-block Zstandard framing; no external compressor or fixture corpus.
    private func zstd(_ bytes: Data) -> Data {
        var result = Data([0x28, 0xb5, 0x2f, 0xfd, 0xa0])
        let size = UInt32(bytes.count)
        for shift in [0, 8, 16, 24] { result.append(UInt8(truncatingIfNeeded: size >> shift)) }
        var position = 0
        repeat {
            let count = min(128 << 10, bytes.count - position), last = position + count == bytes.count
            let block = UInt32(count << 3) | (last ? 1 : 0)
            for shift in [0, 8, 16] { result.append(UInt8(truncatingIfNeeded: block >> shift)) }
            result.append(bytes[position..<(position + count)]); position += count
        } while position < bytes.count
        return result
    }

    func testArchiveFallbackAndCorruptCompressedReplacementPreserveCommittedRowsThenRecover() async throws {
        let bytes = try lines(header + [usage("archived")]), f = try await fixture(bytes)
        let initial = try await f.service.handle("overview", input: ["source": "codex"])
        let cp = try XCTUnwrap(checked(f.source).checkpoint)
        let archive = URL(fileURLWithPath: f.source.path + ".zst"), compressed = zstd(bytes)
        try put(compressed, at: archive)
        let direct = try checked(archive, checkpoint: cp)
        XCTAssertNil(direct.checkpoint); XCTAssertEqual(direct.validatedPrefixBytes, 0); XCTAssertEqual(direct.decodedBytes, 0)
        try assertEqual(direct.result, StatisticsImporter.read(f.source, source: "codex"))
        let beforeFiles = try f.runtime.db.query("SELECT * FROM stats_files ORDER BY path")
        let capturedKey = try XCTUnwrap(beforeFiles.first?["path"]?.string)
        let beforeRows = try f.runtime.db.query("SELECT rowid,* FROM stats_records ORDER BY path,rowid")
        try FileManager.default.removeItem(at: f.source)
        try put(Data(compressed.dropLast()), at: archive)
        XCTAssertThrowsError(try StatisticsCodexAppend.read(archive, checkpoint: cp))
        _ = try await f.service.handle("refresh")
        let held = try await f.service.handle("overview", input: ["source": "codex"])
        XCTAssertEqual(held["derived"], initial["derived"]); XCTAssertFalse(held["warnings"].array.isEmpty)
        XCTAssertEqual(try f.runtime.db.query("SELECT * FROM stats_files ORDER BY path"), beforeFiles)
        XCTAssertEqual(try f.runtime.db.query("SELECT rowid,* FROM stats_records ORDER BY path,rowid"), beforeRows)
        try put(compressed, at: archive)
        let recovered = try await f.service.handle("refresh")
        XCTAssertEqual(recovered["scan"]["codexAppendFiles"], 0); try assertPersisted(f, ledger: archive)
        let files = try f.runtime.db.query("SELECT path,source_path FROM stats_files")
        XCTAssertEqual(files.count, 1); XCTAssertEqual(files.first?["path"], .string(capturedKey))
        XCTAssertEqual(files.first?["source_path"], .string(capturedKey + ".zst"))
    }

    func testPostValidationMutationsUseFullPinnedDescriptorAndOnlyStableCandidates() throws {
        for mutation in ["rewrite", "append", "replace", "unlink"] {
            let root = try directory(), url = root.appendingPathComponent("mutation.jsonl")
            let base = try lines(header + [usage("one")])
            try put(base, at: url)
            let checkpoint = try XCTUnwrap(checked(url).checkpoint)
            var complete = base; complete.append(try lines([usage("two")]))
            try append(try lines([usage("two")]), to: url)
            let before = try metadata(url), beforeResult = try StatisticsImporter.read(url, source: "codex")
            let pinned = root.appendingPathComponent("pinned.jsonl")
            var calls = 0
            let actual = try StatisticsCodexAppend.read(url, checkpoint: checkpoint, afterPrefixValidation: {
                calls += 1
                switch mutation {
                case "rewrite":
                    complete = Data(String(decoding: complete, as: UTF8.self)
                        .replacingOccurrences(of: "fixture-model-A", with: "fixture-model-B").utf8)
                    try self.put(complete, at: url)
                    XCTAssertEqual(try self.metadata(url).st_ino, before.st_ino)
                case "append":
                    let extra = try self.lines([self.usage("during-read")])
                    try self.append(extra, to: url); complete.append(extra)
                case "replace":
                    try FileManager.default.moveItem(at: url, to: pinned)
                    try self.put(try self.lines(self.header + [self.usage("replacement")]), at: url)
                    XCTAssertEqual(try self.metadata(pinned).st_ino, before.st_ino)
                    XCTAssertNotEqual(try self.metadata(url).st_ino, before.st_ino)
                default:
                    try FileManager.default.removeItem(at: url)
                }
            })
            XCTAssertEqual(calls, 1, mutation)
            XCTAssertEqual(actual.validatedPrefixBytes, 0, mutation)
            XCTAssertEqual(actual.decodedBytes, Int64(complete.count), mutation)
            switch mutation {
            case "rewrite", "append":
                try assertEqual(actual.result, StatisticsImporter.read(url, source: "codex"))
                let candidate = try XCTUnwrap(actual.checkpoint), signature = try XCTUnwrap(NativeStatisticsService.checkedDiscoverySignature(url))
                XCTAssertEqual(candidate.length, Int64(complete.count)); XCTAssertEqual(candidate.mtime, signature.mtime)
                if mutation == "rewrite" {
                    XCTAssertTrue(actual.result.records.allSatisfy { $0.model == "fixture-model-B" })
                } else {
                    XCTAssertEqual(actual.result.records.map(\.id), ["codex:one", "codex:two", "codex:during-read"])
                }
            case "replace":
                try assertEqual(actual.result, StatisticsImporter.read(pinned, source: "codex"))
                XCTAssertEqual(actual.result.records.map(\.id), ["codex:one", "codex:two"])
                XCTAssertEqual(try StatisticsImporter.read(url, source: "codex").records.map(\.id), ["codex:replacement"])
                XCTAssertNil(actual.checkpoint, "A replacement pathname cannot own the old descriptor's parser state")
            default:
                // Unlink changes no content. The full importer captured the
                // same bytes immediately before this descriptor-only mutation.
                try assertEqual(actual.result, beforeResult)
                XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
                XCTAssertNil(actual.checkpoint, "An unnamed descriptor cannot produce a reusable pathname checkpoint")
            }
        }
    }

    func testEligibleUnicodeEOFTailSpansPrefixReadChunksWithoutLosingOrDuplicatingUsage() throws {
        let url = try directory().appendingPathComponent("chunk-tail.jsonl")
        let ignored = frame("response_item", ["type": "message", "content": .string(String(repeating: "x", count: 800_000))])
        var prefix = try lines(header + [usage("stable"), ignored])
        var pending = usage("pending")
        pending["ignoredUnicode"] = .string(String(repeating: "東京𝄞", count: 60_000))
        let tail = try pending.encoded(), tailStart = prefix.count
        prefix.append(tail)
        XCTAssertGreaterThan(prefix.count, 1 << 20)
        XCTAssertLessThan(tailStart, 1 << 20); XCTAssertGreaterThan(tailStart + tail.count, 1 << 20)
        XCTAssertLessThan(tail.count, 1 << 20)
        try put(prefix, at: url)
        let first = try checked(url), checkpoint = try XCTUnwrap(first.checkpoint)
        XCTAssertEqual(first.result.records.map(\.id), ["codex:stable", "codex:pending"])
        XCTAssertEqual(checkpoint.length, Int64(prefix.count))
        var suffix = Data([10]); suffix.append(try lines([usage("after-tail")]))
        try append(suffix, to: url)
        let actual = try checked(url, checkpoint: checkpoint)
        XCTAssertEqual(actual.validatedPrefixBytes, Int64(prefix.count))
        XCTAssertEqual(actual.decodedBytes, Int64(tail.count + suffix.count))
        XCTAssertEqual(actual.result.records.map(\.id), ["codex:stable", "codex:pending", "codex:after-tail"])
        XCTAssertEqual(try XCTUnwrap(actual.checkpoint).length, Int64(prefix.count + suffix.count))
    }

    func testEstimatorRejectionKeepsValidatedAppendResultWithoutUnnecessaryFullRetry() throws {
        let url = try directory().appendingPathComponent("context-budget.jsonl")
        let base = try lines(header + [usage("one")])
        try put(base, at: url)
        let checkpoint = try XCTUnwrap(checked(url).checkpoint)
        var suffix = Data()
        for i in 0..<10_001 {
            suffix.append(try lines([context("budget-\(i)", model: "budget-model-\(i)")]))
        }
        suffix.append(try lines([usage("after-context-cap", turn: "budget-10000")]))
        try append(suffix, to: url)
        let actual = try checked(url, checkpoint: checkpoint)
        XCTAssertEqual(actual.validatedPrefixBytes, Int64(base.count))
        XCTAssertEqual(actual.decodedBytes, Int64(suffix.count))
        XCTAssertNil(actual.checkpoint, "Over-budget state disables future reuse, not the validated result already parsed")
        XCTAssertEqual(actual.result.records.map(\.id), ["codex:one", "codex:after-context-cap"])
        XCTAssertEqual(actual.result.records.last?.model, "budget-model-10000")
    }
}
