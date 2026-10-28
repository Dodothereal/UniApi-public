import XCTest
@testable import UniApiCore

final class StatisticsNativeStreamTimingTests: XCTestCase {
    private func observation(id: String = "response-one", model: String = "fixture-model", output: Int = 100,
                             reasoning: Int = 20, duration: Double = 2000) -> NativeCodexStreamTimingObservation {
        NativeCodexStreamTimingObservation(responseID: id, model: model, outputTokens: output,
            reasoningTokens: reasoning, streamOutputTokens: output - reasoning, durationMs: duration,
            completedAt: 1_793_200_000, timingSource: "uniapi-host-sse-clock")
    }
    private func usage() -> StatisticsUsage {
        var row = StatisticsUsage(id: "codex:response-one", source: "codex", ts: 1_793_200_000_000, model: "fixture-model")
        row.input = 90; row.cacheRead = 10; row.output = 100; row.thinking = 20
        row.durationMs = 12000; row.timing = "estimated"
        return row
    }
    func testMatchingResponseExcludesHiddenReasoningAndDoesNotChangeUsageOrResponseTime() throws {
        let before = usage(), measured = try XCTUnwrap(StatisticsNativeStreamTiming.applying(observation(), to: before))
        XCTAssertEqual(measured.input, before.input); XCTAssertEqual(measured.cacheRead, before.cacheRead)
        XCTAssertEqual(measured.output, 100); XCTAssertEqual(measured.thinking, 20)
        XCTAssertEqual(measured.durationMs, 12000); XCTAssertEqual(measured.timing, "estimated")
        var speed = StatisticsSpeed(); speed.add(measured, streaming: true)
        XCTAssertEqual(speed.json["avgTps"], 40)
        XCTAssertEqual(speed.json["outputTokens"], 80)
        XCTAssertEqual(measured.grand, before.grand)
    }
    func testIdentityCounterAndClockMismatchesCannotAttachMeasurements() {
        for invalid in [observation(id: "other-response"), observation(model: "other-model"),
                        observation(output: 101), observation(reasoning: 21), observation(duration: 0),
                        observation(duration: .infinity)] {
            XCTAssertNil(StatisticsNativeStreamTiming.applying(invalid, to: usage()))
        }
        var claude = usage(); claude.source = "claude"
        XCTAssertNil(StatisticsNativeStreamTiming.applying(observation(), to: claude))
    }
    private func fixture() throws -> (URL, NativeRuntime) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("native-clock-" + UUID().uuidString).resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let runtime = try NativeRuntime(paths: NativePaths(root: root, home: root.appendingPathComponent("home")))
        let path = runtime.paths.home.appendingPathComponent(".codex/sessions/one.jsonl")
        let lines: [JSONValue] = [
            ["type": "session_meta", "timestamp": "2026-10-28T10:00:00Z", "payload": ["id": "clock-session", "cwd": "fixture"]],
            ["type": "turn_context", "timestamp": "2026-10-28T10:00:00Z", "payload": ["turn_id": "turn-one", "model": "fixture-model"]],
            ["type": "token_usage_record", "timestamp": "2026-10-28T10:00:12Z", "payload": ["turn_id": "turn-one", "response_id": "response-one", "usage": ["input_tokens": 100, "cached_input_tokens": 10, "output_tokens": 100, "reasoning_output_tokens": 20]]]
        ]
        try FileManager.default.createDirectory(at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
        try lines.map { String(decoding: try $0.encoded(), as: UTF8.self) }.joined(separator: "\n").appending("\n").write(to: path, atomically: false, encoding: .utf8)
        return (root, runtime)
    }
    func testLiveClockEnrichesWarmBoardAndSurvivesJournalRotationWithoutChangingHistoryRows() async throws {
        let (root, runtime) = try fixture()
        let service = NativeStatisticsService(runtime: runtime)
        let first = try await service.handle("overview", input: ["source": "codex"])
        let rows = try runtime.db.query("SELECT * FROM stats_records"), files = try runtime.db.query("SELECT * FROM stats_files")
        XCTAssertEqual(first["derived"]["throughput"]["streaming"]["summary"]["timedResponses"], 0)
        try NativeCodexStreamTimings.append(observation(), paths: runtime.paths)
        let second = try await service.handle("overview", input: ["source": "codex"])
        XCTAssertEqual(second["derived"]["throughput"]["streaming"]["summary"]["avgTps"], 40)
        XCTAssertEqual(second["derived"]["summary"]["totals"], first["derived"]["summary"]["totals"])
        XCTAssertEqual(try runtime.db.query("SELECT * FROM stats_records"), rows)
        XCTAssertEqual(try runtime.db.query("SELECT * FROM stats_files"), files)
        try FileManager.default.removeItem(at: runtime.paths.data.appendingPathComponent("statistics/stream-timings.jsonl"))
        let cold = try await NativeStatisticsService(runtime: runtime).handle("overview", input: ["source": "codex"])
        XCTAssertEqual(cold["derived"]["throughput"]["streaming"]["summary"]["avgTps"], 40)
        let readonly = try NativeRuntime(paths: NativePaths(root: root, home: runtime.paths.home, readOnly: true))
        let readOnlyBoard = try await NativeStatisticsService(runtime: readonly).handle("overview", input: ["source": "codex"])
        XCTAssertEqual(readOnlyBoard["derived"]["throughput"]["streaming"]["summary"]["avgTps"], 40)
        XCTAssertEqual(try runtime.db.query("SELECT * FROM stats_records"), rows)
    }
    func testBackgroundCollectorPersistsClocksWithoutOpeningStatisticsOrRescanningHistory() async throws {
        let (_, runtime) = try fixture()
        let service = NativeStatisticsService(runtime: runtime, environment: [:], clock: { Date().timeIntervalSince1970 * 1000 }, streamTimingPollNanoseconds: 5_000_000)
        try await service.start()
        let records = try runtime.db.query("SELECT * FROM stats_records"), files = try runtime.db.query("SELECT * FROM stats_files")
        try NativeCodexStreamTimings.append(observation(), paths: runtime.paths)
        let deadline = ProcessInfo.processInfo.systemUptime + 2
        var collected = false
        while ProcessInfo.processInfo.systemUptime < deadline {
            if try runtime.db.query("SELECT record_id FROM stats_native_stream_timing").count == 1 { collected = true; break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        await service.shutdownInitialGeneration()
        XCTAssertTrue(collected)
        XCTAssertEqual(try runtime.db.query("SELECT * FROM stats_records"), records)
        XCTAssertEqual(try runtime.db.query("SELECT * FROM stats_files"), files)
    }

    func testNewResponseAfterStartupSurvivesJournalRotationBeforeItsTranscriptIsImported() async throws {
        let (_, runtime) = try fixture()
        let service = NativeStatisticsService(runtime: runtime, environment: [:], clock: { Date().timeIntervalSince1970 * 1000 }, streamTimingPollNanoseconds: 5_000_000)
        try await service.start()
        let path = runtime.paths.home.appendingPathComponent(".codex/sessions/later.jsonl")
        let lines: [JSONValue] = [
            ["type": "turn_context", "timestamp": "2026-10-28T11:00:00Z", "payload": ["turn_id": "turn-later", "model": "fixture-model"]],
            ["type": "token_usage_record", "timestamp": "2026-10-28T11:00:12Z", "payload": ["turn_id": "turn-later", "response_id": "response-later", "usage": ["input_tokens": 100, "cached_input_tokens": 10, "output_tokens": 100, "reasoning_output_tokens": 20]]]
        ]
        try lines.map { String(decoding: try $0.encoded(), as: UTF8.self) }.joined(separator: "\n").appending("\n").write(to: path, atomically: false, encoding: .utf8)
        try NativeCodexStreamTimings.append(observation(id: "response-later"), paths: runtime.paths)
        let deadline = ProcessInfo.processInfo.systemUptime + 2
        var collected = false
        while ProcessInfo.processInfo.systemUptime < deadline {
            if try runtime.db.query("SELECT record_id FROM stats_native_stream_timing WHERE record_id='codex:response-later'").count == 1 { collected = true; break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertTrue(collected)
        // No Statistics read or corpus scan occurred while the monitor saved it.
        XCTAssertEqual(try runtime.db.query("SELECT msg_id FROM stats_records").count, 1)
        try FileManager.default.removeItem(at: runtime.paths.data.appendingPathComponent("statistics/stream-timings.jsonl"))
        _ = try await service.handle("refresh")
        let board = try await service.handle("overview", input: ["source": "codex"])
        XCTAssertEqual(board["derived"]["throughput"]["streaming"]["summary"]["timedResponses"], 1)
        XCTAssertEqual(board["derived"]["throughput"]["streaming"]["summary"]["avgTps"], 40)
        XCTAssertEqual(try runtime.db.query("SELECT msg_id FROM stats_records").count, 2)
        await service.shutdownInitialGeneration()
    }

    func testFailedMetadataSaveDoesNotPublishAnEphemeralMeasurementAndRetries() async throws {
        let (_, runtime) = try fixture()
        let service = NativeStatisticsService(runtime: runtime)
        _ = try await service.handle("overview", input: ["source": "codex"])
        try runtime.db.execute("ALTER TABLE stats_native_stream_timing RENAME TO held_timing")
        try NativeCodexStreamTimings.append(observation(), paths: runtime.paths)
        let failedSave = try await service.handle("overview", input: ["source": "codex"])
        XCTAssertEqual(failedSave["derived"]["throughput"]["streaming"]["summary"]["timedResponses"], 0)
        try runtime.db.execute("ALTER TABLE held_timing RENAME TO stats_native_stream_timing")
        let retried = try await service.handle("overview", input: ["source": "codex"])
        XCTAssertEqual(retried["derived"]["throughput"]["streaming"]["summary"]["avgTps"], 40)
    }

    func testFailedDurableReadDoesNotCacheAnEmptySnapshotForTheServiceLifetime() async throws {
        let (_, runtime) = try fixture()
        let initial = NativeStatisticsService(runtime: runtime)
        _ = try await initial.handle("overview")
        try StatisticsNativeStreamTiming.save(["codex:response-one": observation()], runtime: runtime)
        try runtime.db.execute("ALTER TABLE stats_native_stream_timing RENAME COLUMN observation TO unavailable_observation")
        let service = NativeStatisticsService(runtime: runtime)
        let failedRead = try await service.handle("overview", input: ["source": "codex"])
        XCTAssertEqual(failedRead["derived"]["throughput"]["streaming"]["summary"]["timedResponses"], 0)
        try runtime.db.execute("ALTER TABLE stats_native_stream_timing RENAME COLUMN unavailable_observation TO observation")
        let retried = try await service.handle("overview", input: ["source": "codex"])
        XCTAssertEqual(retried["derived"]["throughput"]["streaming"]["summary"]["avgTps"], 40)
    }

    func testWarmAndColdRetentionChooseTheSameObservationsRegardlessOfInsertionOrder() async throws {
        let (_, runtime) = try fixture()
        _ = try await NativeStatisticsService(runtime: runtime).handle("overview")
        var all: [String: NativeCodexStreamTimingObservation] = [:]
        for id in ["a", "b", "c"] {
            let row = observation(id: id); all["codex:" + id] = row
            try StatisticsNativeStreamTiming.save(["codex:" + id: row], runtime: runtime, limit: 2)
        }
        let warm = StatisticsNativeStreamTiming.bounded(all, limit: 2)
        let cold = try StatisticsNativeStreamTiming.stored(runtime)
        XCTAssertEqual(Set(warm.keys), ["codex:a", "codex:b"])
        XCTAssertEqual(cold, warm)
    }
}
