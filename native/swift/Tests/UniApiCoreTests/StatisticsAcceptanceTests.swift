import XCTest
import Darwin
import CryptoKit
@testable import UniApiCore

final class StatisticsAcceptanceTests: XCTestCase {
    private func fixture() throws -> NativeRuntime {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("statistics-acceptance-" + UUID().uuidString)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return try NativeRuntime(paths: NativePaths(root: root, home: root.appendingPathComponent("home")))
    }
    private func put(_ rows: [JSONValue], _ file: URL) throws {
        try NativeFile.writeAtomic(Data(try rows.map { String(decoding: try $0.encoded(), as: UTF8.self) }.joined(separator: "\n").utf8), to: file)
    }
    private func claude(_ id: String, input: Double, at: String = "2026-10-10T10:00:00Z", model: String = "fixture-model") -> JSONValue {
        ["type": "assistant", "timestamp": .string(at), "message": ["id": .string(id), "model": .string(model), "usage": ["input_tokens": .number(input), "output_tokens": 2]]]
    }
    private func legacyMirrors(_ runtime: NativeRuntime) async throws -> [URL] {
        let first = runtime.paths.home.appendingPathComponent(".codex/sessions/a.jsonl")
        let second = runtime.paths.home.appendingPathComponent(".codex/archived_sessions/b.jsonl")
        let bytes = Data("""
        {"type":"turn_context","payload":{"turn_id":"turn","model":"fixture-model"}}
        {"type":"event_msg","timestamp":"2026-10-10T10:00:00Z","payload":{"type":"token_count","info":{"total_token_usage":{"total_tokens":12,"output_tokens":2,"input_tokens":10},"last_token_usage":{"input_tokens":10,"output_tokens":2}}}}
        """.utf8)
        try NativeFile.writeAtomic(bytes, to: first); try NativeFile.writeAtomic(bytes, to: second)
        _ = try await NativeStatisticsService(runtime: runtime).handle("overview")
        let key = "[\"2026-10-10T10:00:00Z\",{\"total_tokens\":12,\"output_tokens\":2,\"input_tokens\":10},\"turn\"]"
        let id = "codex:" + SHA256.hash(data: Data(key.utf8)).map { String(format: "%02x", $0) }.joined()
        try runtime.db.execute("UPDATE stats_records SET msg_id=? WHERE source='codex'", [.string(id)])
        try runtime.db.execute("DELETE FROM schema_migrations WHERE name=?", ["native-statistics-readers-1"])
        return [first, second]
    }
    private func bootstrapped(_ service: NativeStatisticsService, runtime: NativeRuntime) async -> JSONValue {
        let stream = await runtime.events.stream(), ready = expectation(description: "cached generation ready")
        let listener = Task {
            for await event in stream where event.topic == "stats.cached" { ready.fulfill(); break }
        }
        defer { listener.cancel() }
        _ = service.cachedSummary()
        await fulfillment(of: [ready], timeout: 2)
        return service.cachedSummary()
    }
    func testReadonlyLegacyMirrorsAreFullyReparsedWithoutWritingCache() async throws {
        let runtime = try fixture(), files = try await legacyMirrors(runtime)
        var changed = try Data(contentsOf: files[1]); changed.append(10)
        try NativeFile.writeAtomic(changed, to: files[1])
        let before = try runtime.db.query("SELECT * FROM stats_records ORDER BY path,rowid")
        let signatures = try runtime.db.query("SELECT * FROM stats_files ORDER BY path")
        let readonly = try NativeRuntime(paths: NativePaths(root: runtime.paths.root, home: runtime.paths.home, readOnly: true))
        let service = NativeStatisticsService(runtime: readonly)
        let cached = await bootstrapped(service, runtime: readonly)
        XCTAssertEqual(cached["readerGeneration"], "legacy"); XCTAssertEqual(cached["grand"], 12)
        let value = try await service.handle("overview")
        XCTAssertEqual(value["derived"]["summary"]["totals"]["input"], 10)
        XCTAssertEqual(value["derived"]["events"], 1); XCTAssertEqual(value["scan"]["parsedFiles"], 2)
        XCTAssertEqual(service.cachedSummary()["provenance"], "corpus")
        XCTAssertEqual(try runtime.db.query("SELECT * FROM stats_records ORDER BY path,rowid"), before)
        XCTAssertEqual(try runtime.db.query("SELECT * FROM stats_files ORDER BY path"), signatures)
        let writable = try await NativeStatisticsService(runtime: runtime).handle("overview")
        XCTAssertEqual(value["derived"]["summary"]["totals"], writable["derived"]["summary"]["totals"])
    }
    func testReadonlyIncompleteNativeMigrationAlsoReparsesEveryMirror() async throws {
        let runtime = try fixture(); _ = try await legacyMirrors(runtime)
        try runtime.db.execute("INSERT INTO schema_migrations(name,applied_at) VALUES(?,0)", ["native-statistics-readers-1"])
        try runtime.db.execute("UPDATE stats_files SET mtime=-1,size=-1")
        let readonly = try NativeRuntime(paths: NativePaths(root: runtime.paths.root, home: runtime.paths.home, readOnly: true))
        let value = try await NativeStatisticsService(runtime: readonly).handle("overview")
        XCTAssertEqual(value["derived"]["summary"]["totals"]["input"], 10)
        XCTAssertEqual(value["scan"]["parsedFiles"], 2)
        XCTAssertEqual(try runtime.db.query("SELECT COUNT(*) AS n FROM stats_files WHERE mtime=-1").first?["n"], 2)
    }
    func testReadonlyFailedCompleteUpgradeKeepsLastCoherentCacheAndCanRetry() async throws {
        let runtime = try fixture(), files = try await legacyMirrors(runtime)
        let source = runtime.paths.home.appendingPathComponent(".zcode/cli/db/db.sqlite")
        let writer = try NativeDatabase(url: source)
        try writer.executeScript("CREATE TABLE model_usage(id TEXT,session_id TEXT,query_source TEXT,model_id TEXT,variant TEXT,agent TEXT,status TEXT,started_at REAL,input_tokens REAL,output_tokens REAL,reasoning_tokens REAL,cache_creation_input_tokens REAL,cache_read_input_tokens REAL); INSERT INTO model_usage VALUES('one','s','','fixture','','','completed',1791626400000,5,2,0,0,0);")
        _ = try await NativeStatisticsService(runtime: runtime).handle("overview")
        try runtime.db.execute("DELETE FROM schema_migrations WHERE name=?", ["native-statistics-readers-1"])
        var changed = try Data(contentsOf: files[1]); changed.append(10); try NativeFile.writeAtomic(changed, to: files[1])
        let journal = URL(fileURLWithPath: source.path + "-journal")
        try NativeFile.writeAtomic(Data(repeating: 1, count: 512), to: journal)
        let before = try runtime.db.query("SELECT * FROM stats_records ORDER BY path,rowid")
        let readonly = try NativeRuntime(paths: NativePaths(root: runtime.paths.root, home: runtime.paths.home, readOnly: true))
        let service = NativeStatisticsService(runtime: readonly), cached = await bootstrapped(service, runtime: readonly)
        do { _ = try await service.handle("overview"); XCTFail("Incomplete upgrade was published") }
        catch { XCTAssertTrue(error.localizedDescription.contains("upgrade is incomplete")) }
        XCTAssertEqual(service.cachedSummary()["grand"], cached["grand"])
        XCTAssertEqual(service.cachedSummary()["provenance"], "cache")
        XCTAssertEqual(try runtime.db.query("SELECT * FROM stats_records ORDER BY path,rowid"), before)
        try FileManager.default.removeItem(at: journal)
        let complete = try await service.handle("overview")
        XCTAssertEqual(complete["derived"]["summary"]["totals"]["input"], 15)
        XCTAssertEqual(service.cachedSummary()["provenance"], "corpus")
    }
    func testBootstrapMatchesFullLifetimeReconciliationAndCrossSourceModelUnion() async throws {
        let runtime = try fixture()
        try put([claude("old", input: 100), claude("fresh", input: 10, at: "2026-10-11T10:00:00Z")], runtime.paths.home.appendingPathComponent(".claude/projects/p/a.jsonl"))
        let context: JSONValue = ["type": "turn_context", "payload": ["turn_id": "turn", "model": "fixture-model"]]
        let codex: JSONValue = ["type": "token_usage_record", "timestamp": "2026-10-11T10:00:01Z", "payload": ["turn_id": "turn", "response_id": "codex", "usage": ["input_tokens": 20, "output_tokens": 4, "cached_input_tokens": 4]]]
        try put([context, codex], runtime.paths.home.appendingPathComponent(".codex/sessions/a.jsonl"))
        let cache: JSONValue = ["modelUsage": ["fixture-model": ["inputTokens": 1000, "outputTokens": 200, "cacheReadInputTokens": 50, "cacheCreationInputTokens": 30], "pruned": ["inputTokens": 100]], "totalMessages": 40, "lastComputedDate": "2026-10-10"]
        try NativeFile.writeAtomic(try cache.encoded(), to: runtime.paths.home.appendingPathComponent(".claude/stats-cache.json"))
        let original = try await NativeStatisticsService(runtime: runtime).handle("summary")
        let service = NativeStatisticsService(runtime: runtime), cached = await bootstrapped(service, runtime: runtime)
        XCTAssertEqual(cached["loaded"], true); XCTAssertEqual(cached["loading"], false); XCTAssertEqual(cached["provenance"], "cache")
        for field in ["grand", "responses", "models"] { XCTAssertEqual(cached[field], original[field], field) }
        XCTAssertEqual(cached["responses"], 42); XCTAssertEqual(cached["models"], 2)
        XCTAssertEqual(cached["cachedSources"], ["claude", "codex"])
        XCTAssertEqual(service.cachedSummary(), cached)
    }
    func testBootstrapInvalidWatermarkMatchesFullReconciliation() async throws {
        let runtime = try fixture()
        try put([claude("old", input: 100), claude("tail", input: 10, at: "2026-10-11T10:00:00Z")], runtime.paths.home.appendingPathComponent(".claude/projects/p/a.jsonl"))
        let cache: JSONValue = ["modelUsage": ["fixture-model": ["inputTokens": 1000, "outputTokens": 200]], "totalMessages": 40, "lastComputedDate": "invalid"]
        try NativeFile.writeAtomic(try cache.encoded(), to: runtime.paths.home.appendingPathComponent(".claude/stats-cache.json"))
        let original = try await NativeStatisticsService(runtime: runtime).handle("summary")
        let service = NativeStatisticsService(runtime: runtime), cached = await bootstrapped(service, runtime: runtime)
        for field in ["grand", "responses", "models"] { XCTAssertEqual(cached[field], original[field], field) }
        XCTAssertEqual(cached["grand"], 1200); XCTAssertEqual(cached["responses"], 40)
    }
    func testBootstrapCanUseLifetimeCacheWithoutDiscoveringOrMigratingCorpus() async throws {
        let runtime = try fixture(), file = runtime.paths.home.appendingPathComponent(".claude/stats-cache.json")
        let cache: JSONValue = ["modelUsage": ["fixture-model": ["inputTokens": 1000, "outputTokens": 200]], "totalMessages": 40]
        try NativeFile.writeAtomic(try cache.encoded(), to: file)
        let source = runtime.paths.home.appendingPathComponent(".zcode/cli/db/db.sqlite")
        try FileManager.default.createDirectory(at: source.deletingLastPathComponent(), withIntermediateDirectories: true)
        XCTAssertEqual(mkfifo(source.path, 0o600), 0)
        let service = NativeStatisticsService(runtime: runtime), cached = await bootstrapped(service, runtime: runtime)
        XCTAssertEqual(cached["grand"], 1200); XCTAssertEqual(cached["readerGeneration"], "none")
        XCTAssertEqual(cached["cachedSources"], ["claude"])
        XCTAssertTrue(try runtime.db.query("SELECT name FROM sqlite_master WHERE name='stats_records'").isEmpty)
        XCTAssertEqual(try Data(contentsOf: file), try cache.encoded())
    }
    func testBootstrapRefusesPartialCachedReaderGeneration() async throws {
        let runtime = try fixture()
        try put([claude("a", input: 100)], runtime.paths.home.appendingPathComponent(".claude/projects/p/a.jsonl"))
        _ = try await NativeStatisticsService(runtime: runtime).handle("overview")
        try runtime.db.execute("UPDATE stats_files SET mtime=-1,size=-1")
        let service = NativeStatisticsService(runtime: runtime), cached = await bootstrapped(service, runtime: runtime)
        XCTAssertEqual(cached["loaded"], false); XCTAssertEqual(cached["loading"], false)
        XCTAssertEqual(cached["cacheStatus"], "unavailable"); XCTAssertTrue(cached["grand"].isNull)
        XCTAssertTrue(cached["cacheError"].string.contains("complete reader upgrade"))
    }
    func testBootstrapRefusesLinkedLifetimeCacheAndLeavesItsTargetUnchanged() async throws {
        let runtime = try fixture(), target = runtime.paths.root.appendingPathComponent("external-cache.json")
        let data = Data("{\"modelUsage\":{\"fixture\":{\"inputTokens\":100}}}".utf8)
        try NativeFile.writeAtomic(data, to: target)
        let link = runtime.paths.home.appendingPathComponent(".claude/stats-cache.json")
        try FileManager.default.createDirectory(at: link.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
        let service = NativeStatisticsService(runtime: runtime), cached = await bootstrapped(service, runtime: runtime)
        XCTAssertEqual(cached["loaded"], false); XCTAssertEqual(cached["cacheStatus"], "unavailable")
        XCTAssertEqual(try Data(contentsOf: target), data)
    }
    func testReservedInitialGenerationCoalescesStartupOverviewAndHomeWithoutBootstrap() async throws {
        let runtime = try fixture(), entered = expectation(description: "canonical worker entered")
        try put([claude("a", input: 100)], runtime.paths.home.appendingPathComponent(".claude/projects/p/a.jsonl"))
        let gate = StatisticsInitialScanGate(entered: entered), bootstrap = StatisticsStartupCounter()
        let service = NativeStatisticsService(runtime: runtime, environment: [:], clock: { 1791799200000 }, bootstrapLoad: {
            bootstrap.increment(); return try StatisticsSummaryBootstrap.load(runtime: $0, now: $1)
        }, beforeScan: { try await gate.wait() })
        addTeardownBlock { await gate.open(); await service.shutdownInitialGeneration() }
        let token = try XCTUnwrap(service.reserveInitialGeneration())
        let startup = Task { try await service.startInitialGeneration(token) }
        await fulfillment(of: [entered], timeout: 1)
        let hub = NativeHubSummaries(runtime: runtime, read: { $0 == "stats" ? service.cachedSummary() : ["ready": true] })
        let responsive = expectation(description: "Home returns pending without joining the worker")
        let home = Task { let value = try await hub.snapshot(); responsive.fulfill(); return value }
        await fulfillment(of: [responsive], timeout: 0.5)
        let pending = try await home.value
        XCTAssertEqual(pending["stats"]["loaded"], false); XCTAssertEqual(pending["stats"]["loading"], true)
        XCTAssertTrue(pending["stats"]["grand"].isNull)
        let overview = Task { try await service.handle("overview") }, laterStart = Task { try await service.start() }
        await gate.open()
        try await startup.value; try await laterStart.value
        let actual = try await overview.value, calls = await gate.calls
        XCTAssertEqual(calls, 1); XCTAssertEqual(bootstrap.value, 0)
        XCTAssertEqual(actual["derived"]["summary"]["totals"],
                       ["messages": 1, "input": 100, "output": 2, "thinking": 0,
                        "cacheWrite": 0, "cacheRead": 0, "webSearch": 0, "webFetch": 0])
        XCTAssertEqual(service.cachedSummary()["grand"], 102); XCTAssertEqual(service.cachedSummary()["provenance"], "corpus")
        XCTAssertNil(service.reserveInitialGeneration())
    }
    func testInitialReservationObsoletesQueuedBootstrapBeforeSnapshotIO() async throws {
        let runtime = try fixture(), queue = DispatchQueue(label: "statistics-startup-queued"), bootstrap = StatisticsStartupCounter()
        try put([claude("a", input: 100)], runtime.paths.home.appendingPathComponent(".claude/projects/p/a.jsonl"))
        let service = NativeStatisticsService(runtime: runtime, environment: [:], clock: { 1791799200000 }, bootstrapQueue: queue, bootstrapLoad: {
            bootstrap.increment(); return try StatisticsSummaryBootstrap.load(runtime: $0, now: $1)
        })
        addTeardownBlock { await service.shutdownInitialGeneration() }
        queue.suspend(); var resumed = false
        defer { if !resumed { queue.resume() } }
        XCTAssertEqual(service.cachedSummary()["loading"], true)
        let token = try XCTUnwrap(service.reserveInitialGeneration())
        try await service.startInitialGeneration(token)
        queue.resume(); resumed = true
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in queue.async { continuation.resume() } }
        XCTAssertEqual(bootstrap.value, 0)
        XCTAssertEqual(service.cachedSummary()["grand"], 102)
        await service.shutdownInitialGeneration()
    }
    func testReservedReadOnlyGenerationReconcilesLifetimeAndMirrorsWithoutCacheWrites() async throws {
        let runtime = try fixture(); _ = try await legacyMirrors(runtime)
        let file = runtime.paths.home.appendingPathComponent(".claude/projects/p/a.jsonl")
        try put([claude("old", input: 100), claude("fresh", input: 10, at: "2026-10-11T10:00:00Z")], file)
        let lifetime: JSONValue = ["modelUsage": ["fixture-model": ["inputTokens": 1000, "outputTokens": 200]],
                                   "totalMessages": 40, "lastComputedDate": "2026-10-10"]
        let cacheFile = runtime.paths.home.appendingPathComponent(".claude/stats-cache.json")
        let cacheBytes = try lifetime.encoded(); try NativeFile.writeAtomic(cacheBytes, to: cacheFile)
        let records = try runtime.db.query("SELECT * FROM stats_records ORDER BY path,rowid")
        let signatures = try runtime.db.query("SELECT * FROM stats_files ORDER BY path")
        let readonly = try NativeRuntime(paths: NativePaths(root: runtime.paths.root, home: runtime.paths.home, readOnly: true))
        let bootstrap = StatisticsStartupCounter()
        let service = NativeStatisticsService(runtime: readonly, environment: [:], clock: { 1791799200000 }, bootstrapLoad: {
            bootstrap.increment(); return try StatisticsSummaryBootstrap.load(runtime: $0, now: $1)
        })
        addTeardownBlock { await service.shutdownInitialGeneration() }
        let token = try XCTUnwrap(service.reserveInitialGeneration())
        XCTAssertEqual(service.cachedSummary()["loaded"], false)
        try await service.startInitialGeneration(token)
        let value = try await service.handle("overview"), summary = service.cachedSummary()
        XCTAssertEqual(summary["grand"], 1224); XCTAssertEqual(summary["responses"], 42)
        XCTAssertEqual(summary["provenance"], "corpus"); XCTAssertEqual(bootstrap.value, 0)
        XCTAssertEqual(value["derived"]["events"], 3); XCTAssertEqual(value["scan"]["parsedFiles"], 3)
        XCTAssertEqual(try runtime.db.query("SELECT * FROM stats_records ORDER BY path,rowid"), records)
        XCTAssertEqual(try runtime.db.query("SELECT * FROM stats_files ORDER BY path"), signatures)
        XCTAssertEqual(try Data(contentsOf: cacheFile), cacheBytes)
    }
    func testInitialFailureReleasesOnlyItsTokenAndPreservesExactStandaloneFallback() async throws {
        let runtime = try fixture(), file = runtime.paths.home.appendingPathComponent(".claude/projects/p/a.jsonl")
        try put([claude("a", input: 100)], file)
        try await NativeStatisticsService(runtime: runtime).start()
        try put([claude("a", input: 50000)], file)
        let attempts = StatisticsInitialScanGate(held: false, failFirst: true)
        let service = NativeStatisticsService(runtime: runtime, environment: [:], clock: { 1791799200000 }, beforeScan: { try await attempts.wait() })
        addTeardownBlock { await service.shutdownInitialGeneration() }
        let old = try XCTUnwrap(service.reserveInitialGeneration())
        do { try await service.startInitialGeneration(old); XCTFail("Injected initial failure must propagate") }
        catch { XCTAssertTrue(error is StatisticsInitialScanFailure) }
        let saved = await bootstrapped(service, runtime: runtime)
        XCTAssertEqual(saved["provenance"], "cache"); XCTAssertEqual(saved["grand"], 102)
        XCTAssertFalse(saved["error"].isNull, "Fallback must not hide the failed canonical read")
        let next = try XCTUnwrap(service.reserveInitialGeneration())
        do { try await service.startInitialGeneration(old); XCTFail("Old reservation cannot clear its successor") }
        catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertNil(service.reserveInitialGeneration())
        try await service.startInitialGeneration(next)
        XCTAssertEqual(service.cachedSummary()["grand"], 50002)
        XCTAssertEqual(service.cachedSummary()["provenance"], "corpus")
        await service.shutdownInitialGeneration()
    }
    func testRunningStandaloneBootstrapRemainsSafeWhenCanonicalStartupWins() async throws {
        let runtime = try fixture(), entered = expectation(description: "standalone bootstrap running")
        let clock = StatisticsAcceptanceClock { entered.fulfill() }
        try put([claude("a", input: 100)], runtime.paths.home.appendingPathComponent(".claude/projects/p/a.jsonl"))
        let service = NativeStatisticsService(runtime: runtime, environment: [:], clock: { clock.now() })
        addTeardownBlock { clock.release.signal(); await service.shutdownInitialGeneration() }
        clock.arm(); _ = service.cachedSummary()
        defer { clock.release.signal() }
        await fulfillment(of: [entered], timeout: 1)
        let token = try XCTUnwrap(service.reserveInitialGeneration())
        try await service.startInitialGeneration(token)
        clock.release.signal()
        await service.shutdownInitialGeneration()
        XCTAssertEqual(service.cachedSummary()["grand"], 102)
        XCTAssertEqual(service.cachedSummary()["provenance"], "corpus")
    }
    func testShutdownCancelsAndAwaitsTheActualInitialScanNotOnlyItsWaiter() async throws {
        let runtime = try fixture(), entered = expectation(description: "actual scan suspended")
        let gate = StatisticsInitialScanGate(entered: entered), bootstrap = StatisticsStartupCounter()
        let service = NativeStatisticsService(runtime: runtime, environment: [:], clock: { 1791799200000 }, bootstrapLoad: {
            bootstrap.increment(); return try StatisticsSummaryBootstrap.load(runtime: $0, now: $1)
        }, beforeScan: { try await gate.wait() })
        addTeardownBlock { await gate.open(); await service.shutdownInitialGeneration() }
        let token = try XCTUnwrap(service.reserveInitialGeneration())
        let startup = Task { try await service.startInitialGeneration(token) }
        await fulfillment(of: [entered], timeout: 1)
        let stopped = expectation(description: "shutdown drained actual worker")
        let shutdown = Task { await service.shutdownInitialGeneration(); stopped.fulfill() }
        await fulfillment(of: [stopped], timeout: 1)
        let cancelled = await gate.cancelled
        XCTAssertTrue(cancelled, "Cancelling only the startup waiter leaves this worker suspended")
        await gate.open(); await shutdown.value
        switch await startup.result {
        case .success: XCTFail("Cancelled initial generation cannot report success")
        case .failure(let error): XCTAssertTrue(error is CancellationError)
        }
        XCTAssertEqual(service.cachedSummary()["loaded"], false)
        XCTAssertEqual(service.cachedSummary()["loading"], false)
        XCTAssertEqual(bootstrap.value, 0); XCTAssertNil(service.reserveInitialGeneration())
    }
    func testShutdownDrainsRunningFallbackAndPreventsLateNotificationOrRestart() async throws {
        let runtime = try fixture(), entered = expectation(description: "fallback held before snapshot")
        let clock = StatisticsAcceptanceClock { entered.fulfill() }, completed = StatisticsStartupCounter()
        let service = NativeStatisticsService(runtime: runtime, environment: [:], clock: { clock.now() })
        addTeardownBlock { clock.release.signal(); await service.shutdownInitialGeneration() }
        let events = await runtime.events.stream(), notified = StatisticsStartupCounter()
        let drained = expectation(description: "post-shutdown event marker")
        let observer = Task {
            for await event in events {
                if event.topic == "stats.cached" { notified.increment() }
                if event.topic == "test.startup-drained" { drained.fulfill(); break }
            }
        }
        defer { observer.cancel() }
        clock.arm(); _ = service.cachedSummary()
        defer { clock.release.signal() }
        await fulfillment(of: [entered], timeout: 1)
        let shutdown = Task { await service.shutdownInitialGeneration(); completed.increment() }
        let deadline = ContinuousClock.now.advanced(by: .seconds(1))
        while service.cachedSummary()["loading"] == true, ContinuousClock.now < deadline {
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        XCTAssertEqual(service.cachedSummary()["loading"], false, "Shutdown must retire admission before draining")
        XCTAssertEqual(completed.value, 0, "Synchronous fallback still owns its private snapshot work")
        clock.release.signal(); await shutdown.value
        await runtime.events.publish("test.startup-drained", [:])
        await fulfillment(of: [drained], timeout: 1)
        XCTAssertEqual(notified.value, 0)
        XCTAssertEqual(completed.value, 1); XCTAssertNil(service.reserveInitialGeneration())
        XCTAssertEqual(service.cachedSummary()["loaded"], false)
    }
    func testHomeGetterStaysResponsiveAndLateBootstrapCannotReplaceCorpusSummary() async throws {
        let runtime = try fixture(), file = runtime.paths.home.appendingPathComponent(".claude/projects/p/a.jsonl")
        try put([claude("a", input: 100)], file)
        _ = try await NativeStatisticsService(runtime: runtime).handle("overview")
        let started = expectation(description: "background bootstrap entered")
        let gate = StatisticsAcceptanceClock { started.fulfill() }
        let service = NativeStatisticsService(runtime: runtime, environment: [:], clock: { gate.now() })
        gate.arm(); XCTAssertEqual(service.cachedSummary()["loading"], true)
        defer { gate.release.signal() }
        await fulfillment(of: [started], timeout: 1)
        let hub = NativeHubSummaries(runtime: runtime, read: { $0 == "stats" ? service.cachedSummary() : ["ready": true] })
        let displayed = expectation(description: "Home receives loading state")
        let home = Task { let result = try await hub.snapshot(); displayed.fulfill(); return result }
        await fulfillment(of: [displayed], timeout: 0.5)
        let initial = try await home.value; XCTAssertEqual(initial["stats"]["loading"], true)
        try put([claude("a", input: 200)], file)
        _ = try await service.handle("rescan")
        XCTAssertEqual(service.cachedSummary()["grand"], 202); XCTAssertEqual(service.cachedSummary()["provenance"], "corpus")
        gate.release.signal()
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(service.cachedSummary()["grand"], 202); XCTAssertEqual(service.cachedSummary()["provenance"], "corpus")
    }
}

private final class StatisticsAcceptanceClock: @unchecked Sendable {
    private let lock = NSLock(), entered: @Sendable () -> Void
    private var active = false
    let release = DispatchSemaphore(value: 0)
    init(_ entered: @escaping @Sendable () -> Void) { self.entered = entered }
    func arm() { lock.lock(); active = true; lock.unlock() }
    func now() -> Double {
        lock.lock(); let hold = active; active = false; lock.unlock()
        if hold { entered(); _ = release.wait(timeout: .now() + 3) }
        return 1791799200000
    }
}

private enum StatisticsInitialScanFailure: Error { case injected }

private final class StatisticsStartupCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    func increment() { lock.lock(); count += 1; lock.unlock() }
    var value: Int { lock.lock(); defer { lock.unlock() }; return count }
}

private actor StatisticsInitialScanGate {
    private var entered: XCTestExpectation?
    private var opened: Bool
    private let failFirst: Bool
    private var waiting: CheckedContinuation<Void, Error>?
    private(set) var calls = 0, cancelled = false
    init(entered: XCTestExpectation? = nil, held: Bool = true, failFirst: Bool = false) {
        self.entered = entered; opened = !held; self.failFirst = failFirst
    }
    func wait() async throws {
        calls += 1; entered?.fulfill(); entered = nil
        if failFirst && calls == 1 { throw StatisticsInitialScanFailure.injected }
        try Task.checkCancellation()
        if opened { return }
        try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                if cancelled { continuation.resume(throwing: CancellationError()) }
                else { waiting = continuation }
            }
        }, onCancel: { Task { await self.cancel() } })
    }
    func open() { opened = true; let pending = waiting; waiting = nil; pending?.resume() }
    private func cancel() {
        cancelled = true; let pending = waiting; waiting = nil; pending?.resume(throwing: CancellationError())
    }
}
