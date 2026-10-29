import XCTest
import Foundation
@testable import UniApiCore

/// End-to-end comparisons against the same real service with publication reuse
/// disabled. Every store and transcript belongs to a fresh synthetic private home.
final class StatisticsAppendPublicationTests: XCTestCase {
    private struct Fixture {
        let runtime: NativeRuntime, service: NativeStatisticsService
        func source(_ relative: String) -> URL { runtime.paths.home.appendingPathComponent(relative) }
    }
    private struct Pair { let enabled: Fixture, oracle: Fixture }
    private final class ForeignCommitProbe: @unchecked Sendable {
        private let lock = NSLock()
        private var calls = 0, sawChangedOutput = false, sameRevisions = false, changedVersion = false
        func mutate(_ runtime: NativeRuntime) throws {
            let before = try runtime.db.query("SELECT path,record_revision FROM main.stats_files ORDER BY path")
            let version = try runtime.db.query("PRAGMA data_version").first?["data_version"]
            let foreign = try NativeDatabase(url: runtime.paths.database)
            try foreign.execute("UPDATE main.stats_records SET output=999 WHERE msg_id='codex:one'")
            let outputs = try runtime.db.query("SELECT output FROM main.stats_records WHERE msg_id='codex:one'")
            let after = try runtime.db.query("SELECT path,record_revision FROM main.stats_files ORDER BY path")
            let nextVersion = try runtime.db.query("PRAGMA data_version").first?["data_version"]
            lock.withLock {
                calls += 1; sawChangedOutput = outputs.count == 1 && outputs.first?["output"] == 999
                sameRevisions = !before.isEmpty && before == after
                changedVersion = version != nil && nextVersion != nil && version != nextVersion
            }
        }
        var observation: (calls: Int, sawChangedOutput: Bool, sameRevisions: Bool, changedVersion: Bool) {
            lock.withLock { (calls, sawChangedOutput, sameRevisions, changedVersion) }
        }
    }
    private let primary = ".codex/sessions/a.jsonl"
    private let secondary = ".codex/sessions/z.jsonl"
    private let claude = ".claude/projects/fixture/usage.jsonl"
    private let sentinel = "fixture-unrelated-rowid-sentinel"

    private func frame(_ type: String, _ payload: JSONObject, at: String? = nil) -> JSONValue {
        var result: JSONObject = ["type": .string(type), "payload": .object(payload)]
        if let at { result["timestamp"] = .string(at) }
        return .object(result)
    }
    private var header: [JSONValue] {
        [frame("session_meta", ["id": "fixture-publication-session", "cwd": "fixture/project", "source": ["subagent": [:]]])]
    }
    private func modern(_ id: String, second: Int, model: String = "fixture-model") -> [JSONValue] {
        let turn = "turn-" + id
        return [
            frame("turn_context", ["turn_id": .string(turn), "model": .string(model), "cwd": "fixture/project", "effort": "xhigh"]),
            frame("event_msg", ["type": "task_started", "turn_id": .string(turn)],
                  at: String(format: "2026-10-29T10:00:%02dZ", second - 1)),
            frame("token_usage_record", ["turn_id": .string(turn), "response_id": .string(id),
                  "usage": ["input_tokens": 100.25, "output_tokens": 20.5, "reasoning_output_tokens": 2.25,
                            "cached_input_tokens": 3.125, "cache_write_input_tokens": 1.75]],
                  at: String(format: "2026-10-29T10:00:%02dZ", second))]
    }
    private func lines(_ rows: [JSONValue]) throws -> Data {
        var result = Data()
        for row in rows { result.append(try row.encoded()); result.append(10) }
        return result
    }
    private func initial(_ ids: [String] = ["one", "two", "three", "four"]) throws -> Data {
        try lines(header + ids.enumerated().flatMap { modern($0.element, second: $0.offset + 1) })
    }
    private func put(_ bytes: Data, at url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if !FileManager.default.fileExists(atPath: url.path) { try Data().write(to: url) }
        let file = try FileHandle(forWritingTo: url)
        defer { try? file.close() }
        try file.truncate(atOffset: 0); try file.write(contentsOf: bytes)
    }
    private func append(_ bytes: Data, to url: URL) throws {
        let file = try FileHandle(forWritingTo: url)
        defer { try? file.close() }
        _ = try file.seekToEnd(); try file.write(contentsOf: bytes)
    }
    private func fixture(enabled: Bool, sources: [String: Data],
                         beforeCodexCommit: @escaping @Sendable (NativeRuntime) throws -> Void = { _ in }) async throws -> Fixture {
        let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
            .appendingPathComponent("statistics-publication-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        try NativeFile.writeAtomic(try JSONValue.object(["providers": []]).encoded(), to: root.appendingPathComponent("providers.example.json"))
        let paths = NativePaths(root: root, home: root.appendingPathComponent("home"))
        for (name, bytes) in sources { try put(bytes, at: paths.home.appendingPathComponent(name)) }
        let runtime = try NativeRuntime(paths: paths)
        await runtime.jobs.suspendForShutdown()
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let now = try XCTUnwrap(statisticsTimestamp(.string("2026-10-29T12:00:00Z")))
        let service = NativeStatisticsService(runtime: runtime, environment: [:], calendar: calendar, clock: { now },
                                              codexPublicationEnabled: enabled, beforeCodexCommit: beforeCodexCommit)
        addTeardownBlock { await service.shutdownInitialGeneration() }
        try await service.start()
        return Fixture(runtime: runtime, service: service)
    }
    private func pair(_ sources: [String: Data]) async throws -> Pair {
        let enabled = try await fixture(enabled: true, sources: sources)
        let oracle = try await fixture(enabled: false, sources: sources)
        return Pair(enabled: enabled, oracle: oracle)
    }
    private func normalized(_ value: JSONValue) -> JSONValue {
        guard case .object(var root) = value else { return value }
        if let value = root["scan"], case .object(var scan) = value {
            // These are diagnostic identities/work counts, not accounting or clocks.
            for key in ["scanId", "elapsedMs", "scannedAt", "assemblyMode", "reusedRecords", "assembledRecords", "codexSQLAppendFiles",
                        "codexAppendFiles", "codexValidatedPrefixBytes", "codexAppendDecodedBytes"] { scan.removeValue(forKey: key) }
            root["scan"] = .object(scan)
        }
        if let value = root["progress"], case .object(var progress) = value {
            progress.removeValue(forKey: "scanId"); progress.removeValue(forKey: "generation")
            root["progress"] = .object(progress)
        }
        return .object(root)
    }
    private func bits(_ value: JSONValue) -> [UInt64] {
        switch value {
        case .number(let number): return [number.bitPattern]
        case .array(let rows): return rows.flatMap { bits($0) }
        case .object(let fields): return fields.keys.sorted().flatMap { bits(fields[$0]!) }
        default: return []
        }
    }
    private func assertPayload(_ actual: JSONValue, _ expected: JSONValue,
                               file: StaticString = #filePath, line: UInt = #line) throws {
        let a = normalized(actual), b = normalized(expected)
        XCTAssertEqual(a, b, file: file, line: line)
        XCTAssertEqual(bits(a), bits(b), file: file, line: line)
        // String equality alone would hide canonically equivalent Unicode spellings.
        XCTAssertEqual(try a.encoded(), try b.encoded(), file: file, line: line)
    }
    private func rows(_ fixture: Fixture) throws -> [JSONObject] {
        try fixture.runtime.db.query("SELECT CAST(rowid AS TEXT) AS fixture_rowid,* FROM stats_records ORDER BY path,rowid")
    }
    private func persisted(_ fixture: Fixture) throws -> [JSONValue] {
        let values = try rows(fixture).map { row -> (JSONValue, Data) in
            var copy = row; copy.removeValue(forKey: "fixture_rowid")
            let path = (copy["path"] ?? .null).string
            for marker in ["/.codex/", "/.claude/"] {
                if let range = path.range(of: marker) { copy["path"] = .string(String(path[range.lowerBound...])); break }
            }
            let value = JSONValue.object(copy)
            return (value, try value.encoded())
        }
        // Rowids are checked independently in the admitted case. Comparing the
        // full field multiset also handles SQLite's MAXROWID random allocation.
        return values.sorted { $0.1.lexicographicallyPrecedes($1.1) }.map(\.0)
    }
    private func assertServices(_ pair: Pair, models: [String] = ["fixture-model"],
                                file: StaticString = #filePath, line: UInt = #line) async throws {
        for source in ["all", "codex"] {
            for range in [0, 7, 30] {
                let input: JSONObject = ["source": .string(source), "range": .number(Double(range))]
                let actual = try await pair.enabled.service.handle("overview", input: input)
                let expected = try await pair.oracle.service.handle("overview", input: input)
                try assertPayload(actual, expected, file: file, line: line)
                XCTAssertTrue(actual["warnings"].array.isEmpty, file: file, line: line)
            }
        }
        for model in models {
            for source in ["all", "codex"] {
                let input: JSONObject = ["model": .string(model), "source": .string(source), "range": 0]
                for operation in ["model", "exportDailyCSV"] {
                    let actual = try await pair.enabled.service.handle(operation, input: input)
                    let expected = try await pair.oracle.service.handle(operation, input: input)
                    try assertPayload(actual, expected, file: file, line: line)
                }
            }
        }
        let actualSummary = try await pair.enabled.service.handle("summary")
        let expectedSummary = try await pair.oracle.service.handle("summary")
        try assertPayload(actualSummary, expectedSummary, file: file, line: line)
        try assertPayload(.array(persisted(pair.enabled)), .array(persisted(pair.oracle)), file: file, line: line)
    }
    private func refresh(_ pair: Pair, mode: String, file: StaticString = #filePath, line: UInt = #line) async throws -> JSONValue {
        let actual = try await pair.enabled.service.handle("refresh")
        let expected = try await pair.oracle.service.handle("refresh")
        XCTAssertEqual(actual["scan"]["assemblyMode"], .string(mode), file: file, line: line)
        XCTAssertEqual(expected["scan"]["assemblyMode"], "full", file: file, line: line)
        try assertPayload(actual, expected, file: file, line: line)
        if mode == "full" {
            XCTAssertEqual(actual["scan"]["reusedRecords"], 0, file: file, line: line)
            XCTAssertEqual(actual["scan"]["assembledRecords"], actual["scan"]["records"], file: file, line: line)
        }
        return actual
    }
    private func insertSentinel(_ fixture: Fixture, maximum: Bool = false) throws {
        // SQL literals are necessary: passing MAXROWID through JSON Double would round it.
        let rowid = maximum ? "9223372036854775807" : "1000000"
        try fixture.runtime.db.executeScript("""
        INSERT INTO stats_records(rowid,path,msg_id,ts,raw_day,model,project,session,sidechain,effort,input,output,thinking,cache_write,cache_read,web_search,web_fetch,source)
        VALUES(\(rowid),'fixture-unrelated-rowid-sentinel','sentinel',1,'1970-01-01','sentinel','sentinel','sentinel',0,'',1,1,0,0,0,0,0,'codex');
        """)
    }

    func testStrictlyLaterModernAppendReusesPublishedRowsAndPreservesSQLPrefix() async throws {
        let p = try await pair([primary: initial()])
        try await assertServices(p)
        for fixture in [p.enabled, p.oracle] { try insertSentinel(fixture) }
        let before = try rows(p.enabled).filter { $0["path"] != .string(sentinel) }
        XCTAssertEqual(before.count, 4)
        let suffix = try lines(modern("five", second: 5) + modern("six", second: 6))
        for fixture in [p.enabled, p.oracle] { try append(suffix, to: fixture.source(primary)) }
        let result = try await refresh(p, mode: "append")
        XCTAssertEqual(result["scan"]["reusedRecords"], 4); XCTAssertEqual(result["scan"]["assembledRecords"], 2)
        XCTAssertEqual(result["scan"]["codexSQLAppendFiles"], 1)
        let after = try rows(p.enabled).filter { $0["path"] != .string(sentinel) }
        XCTAssertEqual(after.count, 6); XCTAssertEqual(Array(after.prefix(4)), before)
        XCTAssertEqual(after.suffix(2).map { ($0["fixture_rowid"] ?? .null).string }, ["1000001", "1000002"])
        try await assertServices(p)
    }

    func testEqualAndOlderTimestampsFallBackToFullPublication() async throws {
        for second in [4, 2] {
            let p = try await pair([primary: initial()])
            for fixture in [p.enabled, p.oracle] { try append(try lines(modern("late-arrival", second: second)), to: fixture.source(primary)) }
            _ = try await refresh(p, mode: "full")
            try await assertServices(p)
        }
    }

    func testDuplicateAndCanonicalUnicodeResponseIDsFallBackWithoutDoubleCounting() async throws {
        for (old, new) in [("one", "one"), ("caf\u{00e9}", "cafe\u{0301}")] {
            let p = try await pair([primary: initial([old, "two", "three", "four"])])
            for fixture in [p.enabled, p.oracle] { try append(try lines(modern(new, second: 5)), to: fixture.source(primary)) }
            let result = try await refresh(p, mode: "full")
            XCTAssertEqual(result["scan"]["records"], 5)
            let overview = try await p.enabled.service.handle("overview", input: ["source": "codex"])
            XCTAssertEqual(overview["derived"]["events"], 4)
            try await assertServices(p)
        }
    }

    func testInvalidationRewritesInventoryChangesAndOtherSourceChangesFallBack() async throws {
        let claudeRow: JSONValue = ["type": "assistant", "timestamp": "2026-10-29T10:00:01Z", "cwd": "fixture/project", "sessionId": "fixture-claude-session",
                                    "message": ["id": "claude-one", "model": "fixture-model", "usage": ["input_tokens": 10, "output_tokens": 2]]]
        for change in ["invalidated", "foreign-revision", "prefix", "new-file", "prune", "multi-source"] {
            var sources = [primary: try initial()]
            if change == "prune" { sources[secondary] = try lines(header + modern("pruned", second: 3)) }
            if change == "multi-source" { sources[claude] = try lines([claudeRow]) }
            let p = try await pair(sources)
            for fixture in [p.enabled, p.oracle] {
                switch change {
                case "invalidated": try fixture.runtime.db.execute("UPDATE stats_files SET mtime=-1,size=-1")
                case "foreign-revision": try fixture.runtime.db.execute("UPDATE stats_files SET record_revision=?", [.string(UUID().uuidString)])
                case "prefix":
                    let old = try Data(contentsOf: fixture.source(primary))
                    let changed = Data(String(decoding: old, as: UTF8.self).replacingOccurrences(of: "fixture/project", with: "fixture/changed-project").utf8)
                    try put(changed, at: fixture.source(primary))
                case "new-file": try put(try lines(header + modern("new-file", second: 6)), at: fixture.source(secondary))
                case "prune": try FileManager.default.removeItem(at: fixture.source(secondary))
                default:
                    var changed = claudeRow; changed["message"]["usage"] = ["input_tokens": 1000, "output_tokens": 3]
                    try put(try lines([changed]), at: fixture.source(claude))
                }
                try append(try lines(modern("after-change", second: 5)), to: fixture.source(primary))
            }
            _ = try await refresh(p, mode: "full")
            try await assertServices(p)
        }
    }

    func testInvalidatedValidEOFTailFallsBackAndRemovesItsOldPublishedUsage() async throws {
        let complete = try initial(), p = try await pair([primary: Data(complete.dropLast())])
        for fixture in [p.enabled, p.oracle] {
            var suffix = Data("x\n".utf8); suffix.append(try lines(modern("after-tail", second: 5)))
            try append(suffix, to: fixture.source(primary))
        }
        let result = try await refresh(p, mode: "full")
        XCTAssertEqual(result["scan"]["codexSQLAppendFiles"], 0)
        let overview = try await p.enabled.service.handle("overview", input: ["source": "codex"])
        XCTAssertEqual(overview["derived"]["events"], 4)
        XCTAssertFalse(try rows(p.enabled).contains { $0["msg_id"] == "codex:four" })
        try await assertServices(p)
    }

    func testNewModernUsageSuppressingOldFallbackForcesFullReplacement() async throws {
        let fallback = frame("event_msg", ["type": "token_count", "turn_id": "replace-turn",
                              "info": ["total_token_usage": ["total_tokens": 12], "last_token_usage": ["input_tokens": 10, "output_tokens": 2]]],
                             at: "2026-10-29T10:00:04Z")
        let context = frame("turn_context", ["turn_id": "replace-turn", "model": "fixture-model", "cwd": "fixture/project", "effort": "xhigh"])
        let base = try lines(header + modern("one", second: 1) + modern("two", second: 2) + modern("three", second: 3) + [context, fallback])
        let p = try await pair([primary: base])
        let before = try rows(p.enabled).map { ($0["msg_id"] ?? .null).string }
        let new = frame("token_usage_record", ["turn_id": "replace-turn", "response_id": "replacement",
                        "usage": ["input_tokens": 120, "output_tokens": 30, "reasoning_output_tokens": 5]], at: "2026-10-29T10:00:05Z")
        for fixture in [p.enabled, p.oracle] { try append(try lines([new]), to: fixture.source(primary)) }
        let result = try await refresh(p, mode: "full")
        XCTAssertEqual(result["scan"]["codexSQLAppendFiles"], 0)
        let after = try rows(p.enabled).map { ($0["msg_id"] ?? .null).string }
        XCTAssertEqual(after.count, 4); XCTAssertTrue(after.contains("codex:replacement"))
        XCTAssertEqual(Set(before).subtracting(after).count, 1)
        try await assertServices(p)
    }

    func testEarlierPathUnicodeInternerRepresentativeChangeForcesFullPublication() async throws {
        let composed = "fixture-shared-model-caf\u{00e9}", decomposed = "fixture-shared-model-cafe\u{0301}"
        XCTAssertEqual(composed, decomposed); XCTAssertNotEqual(Data(composed.utf8), Data(decomposed.utf8))
        let p = try await pair([primary: lines(header + modern("early", second: 1, model: "fixture-first")),
                                secondary: lines(header + modern("old-representative", second: 2, model: decomposed))])
        let before = try await p.enabled.service.handle("overview", input: ["source": "codex"])
        XCTAssertTrue(try before.encoded().range(of: Data(decomposed.utf8)) != nil)
        for fixture in [p.enabled, p.oracle] {
            try append(try lines(modern("new-representative", second: 3, model: composed)), to: fixture.source(primary))
        }
        _ = try await refresh(p, mode: "full")
        try await assertServices(p, models: ["fixture-first", composed])
        let after = try await p.enabled.service.handle("overview", input: ["source": "codex"])
        let encoded = try after["derived"].encoded()
        XCTAssertNotNil(encoded.range(of: Data(composed.utf8)))
        XCTAssertNil(encoded.range(of: Data(decomposed.utf8)))
    }

    func testMaximumRowIDDisablesSQLAppendAndStillMatchesFullServiceOracle() async throws {
        let p = try await pair([primary: initial()])
        for fixture in [p.enabled, p.oracle] {
            try insertSentinel(fixture, maximum: true)
            try append(try lines(modern("five", second: 5) + modern("six", second: 6)), to: fixture.source(primary))
        }
        let result = try await refresh(p, mode: "full")
        XCTAssertEqual(result["scan"]["codexSQLAppendFiles"], 0); XCTAssertEqual(result["scan"]["records"], 6)
        try await assertServices(p)
        for fixture in [p.enabled, p.oracle] {
            let maximum = try rows(fixture).first { $0["path"] == .string(sentinel) }
            XCTAssertEqual(maximum?["fixture_rowid"], "9223372036854775807")
            XCTAssertEqual(try rows(fixture).count, 7)
        }
    }

    func testForeignCommitAfterParsingForcesFullRewriteWithoutTrustingUnchangedRevision() async throws {
        let probe = ForeignCommitProbe(), sources = [primary: try initial()]
        let enabled = try await fixture(enabled: true, sources: sources, beforeCodexCommit: { runtime in try probe.mutate(runtime) })
        let oracle = try await fixture(enabled: false, sources: sources)
        let p = Pair(enabled: enabled, oracle: oracle)
        XCTAssertEqual(probe.observation.calls, 0, "Cold publication must not invoke the would-reuse seam")
        let before = try rows(enabled)
        XCTAssertEqual(before.first { $0["msg_id"] == "codex:one" }?["output"], 20.5)
        for fixture in [enabled, oracle] { try append(try lines(modern("five", second: 5)), to: fixture.source(primary)) }
        let result = try await refresh(p, mode: "full")
        let observed = probe.observation
        XCTAssertEqual(observed.calls, 1)
        XCTAssertTrue(observed.sawChangedOutput, "The real second connection must have committed 999 before BEGIN")
        XCTAssertTrue(observed.sameRevisions, "This case deliberately changes no file revision")
        XCTAssertTrue(observed.changedVersion, "The owning connection must observe the foreign commit")
        XCTAssertEqual(result["scan"]["codexSQLAppendFiles"], 0)
        XCTAssertEqual(result["scan"]["assembledRecords"], 5)
        let committed = try rows(enabled)
        XCTAssertEqual(committed.count, 5)
        XCTAssertEqual(committed.first { $0["msg_id"] == "codex:one" }?["output"], 20.5)
        XCTAssertEqual(committed.first { $0["msg_id"] == "codex:five" }?["output"], 20.5)
        XCTAssertFalse(committed.contains { $0["output"] == 999 })
        try await assertServices(p)
    }

    func testTemporaryRecordsShadowDisablesReuseAndPreservesOrdinaryMainAndTempSemantics() async throws {
        let p = try await pair([primary: initial()]), fixtures = [p.enabled, p.oracle]
        var mainBefore: [[JSONObject]] = []
        for fixture in fixtures {
            let rows = try fixture.runtime.db.query("SELECT CAST(rowid AS TEXT) AS fixture_rowid,* FROM main.stats_records ORDER BY path,rowid")
            XCTAssertEqual(rows.count, 4); mainBefore.append(rows)
            // The existing main table supplies the actual layout and rows.
            // Create the shadow before the next scan's capability inspection.
            try fixture.runtime.db.executeScript("CREATE TEMP TABLE stats_records AS SELECT * FROM main.stats_records ORDER BY path,rowid;")
            XCTAssertEqual(try fixture.runtime.db.query("SELECT COUNT(*) AS n FROM temp.stats_records").first?["n"], 4)
            try append(try lines(modern("five", second: 5)), to: fixture.source(primary))
        }
        let result = try await refresh(p, mode: "full")
        XCTAssertEqual(result["scan"]["codexSQLAppendFiles"], 0)
        XCTAssertEqual(result["scan"]["assembledRecords"], 5)
        try await assertServices(p)
        for (index, fixture) in fixtures.enumerated() {
            let main = try fixture.runtime.db.query("SELECT CAST(rowid AS TEXT) AS fixture_rowid,* FROM main.stats_records ORDER BY path,rowid")
            let temporary = try fixture.runtime.db.query("SELECT CAST(rowid AS TEXT) AS fixture_rowid,* FROM temp.stats_records ORDER BY path,rowid")
            XCTAssertEqual(main, mainBefore[index], "Ordinary unqualified writes must remain confined to the shadow")
            XCTAssertEqual(temporary.count, 5)
            XCTAssertEqual(temporary.first { $0["msg_id"] == "codex:five" }?["output"], 20.5)
            XCTAssertFalse(main.contains { $0["msg_id"] == "codex:five" })
            XCTAssertEqual(try rows(fixture), temporary)
        }
        // No further DDL: the first shadow-backed publication has already
        // adopted temp.schema_version. A second append must still decline
        // reuse because of the shadow itself, rather than a version mismatch.
        for fixture in fixtures { try append(try lines(modern("six", second: 6)), to: fixture.source(primary)) }
        let second = try await refresh(p, mode: "full")
        XCTAssertEqual(second["scan"]["codexSQLAppendFiles"], 0)
        XCTAssertEqual(second["scan"]["assembledRecords"], 6)
        try await assertServices(p)
        for (index, fixture) in fixtures.enumerated() {
            XCTAssertEqual(try fixture.runtime.db.query("SELECT CAST(rowid AS TEXT) AS fixture_rowid,* FROM main.stats_records ORDER BY path,rowid"), mainBefore[index])
            XCTAssertEqual(try fixture.runtime.db.query("SELECT COUNT(*) AS n FROM temp.stats_records").first?["n"], 6)
        }
    }
}
