import XCTest
import Combine
import UniApiCore
@testable import UniApiPresentation

@MainActor private final class StatisticsWarmFixture: NativeStatsModelService {
    var revision = 1
    var holdNext: String?
    var failNextOverview = false
    var wrongSource = false
    private(set) var calls: [String] = []
    private(set) var heldOperation: String?
    private var held: [CheckedContinuation<Void, Never>] = []
    var heldCount: Int { held.count }
    func release() { let pending = held; held = []; heldOperation = nil; pending.forEach { $0.resume() } }
    func releaseFirst() { if !held.isEmpty { held.removeFirst().resume() }; if held.isEmpty { heldOperation = nil } }
    func handle(_ operation: String, input: JSONObject) async throws -> JSONValue {
        calls.append(operation)
        let captured = revision
        if holdNext == operation {
            holdNext = nil; heldOperation = operation
            await withCheckedContinuation { held.append($0) }
        }
        if operation == "refresh" || operation == "rescan" { revision += 1; return ["ok": true] }
        if operation == "bench" { return ["revision": .number(Double(revision))] }
        if failNextOverview { failNextOverview = false; throw NativeFailure("Held read failed") }
        var value: JSONValue = ["loaded": true, "source": wrongSource ? "wrong-source" : input["source"] ?? "all", "range": input["range"] ?? 0,
                                "revision": .number(Double(captured)), "derived": ["summary": ["totals": ["input": 987654321, "output": 1234]]]]
        if operation == "model" { value["model"] = input["model"] ?? .null; value["bench"] = ["model": input["model"] ?? .null] }
        return value
    }
}

@MainActor final class StatisticsWarmNavigationTests: XCTestCase {
    private func waitFor(_ predicate: () -> Bool) async throws {
        let deadline = ProcessInfo.processInfo.systemUptime + 2
        while !predicate() {
            guard ProcessInfo.processInfo.systemUptime < deadline else { throw NativeFailure("Statistics fixture did not reach its held boundary") }
            try await Task.sleep(nanoseconds: 1_000_000)
        }
    }
    private func make(_ service: StatisticsWarmFixture) -> NativeStatsModel {
        let model = NativeStatsModel(service: service)
        addTeardownBlock { await MainActor.run { service.release(); model.stop() } }
        return model
    }
    private func begin(_ model: NativeStatsModel, events: NativeEvents = NativeEvents(), source: String = "codex") async {
        await model.begin(events: events) { await model.load(source: source, range: 0, model: nil) }
    }

    func testPrefetchAndVisibleEntryShareOneReadAndWarmReentryKeepsPayload() async throws {
        let service = StatisticsWarmFixture(), model = make(service)
        service.holdNext = "overview"
        let warm = Task { await model.prefetch(source: "codex", range: 0) }
        try await waitFor { service.heldOperation == "overview" }
        let visible = Task { await self.begin(model) }
        try await waitFor { model.pendingReaderCount == 2 }
        XCTAssertEqual(service.calls, ["overview"])
        service.release(); await warm.value; await visible.value
        XCTAssertEqual(model.payload["derived"]["summary"]["totals"]["input"].int, 987654321)
        model.stop()
        XCTAssertNotNil(model.snapshot(source: "codex", range: 0, model: nil))
        await begin(model)
        XCTAssertEqual(service.calls, ["overview"])
        XCTAssertFalse(model.busy)
    }

    func testSnapshotsKeepExactSourceRangeModelAndBenchmarkTogether() async {
        let service = StatisticsWarmFixture(), model = make(service)
        await begin(model, source: "all")
        await model.load(source: "codex", range: 7, model: nil)
        await model.load(source: "codex", range: 30, model: "example")
        XCTAssertEqual(model.snapshot(source: "all", range: 0, model: nil)?.benchmark["revision"], 1)
        XCTAssertEqual(model.snapshot(source: "codex", range: 7, model: nil)?.benchmark, [:])
        XCTAssertEqual(model.snapshot(source: "codex", range: 30, model: "example")?.benchmark["model"], "example")
        XCTAssertNil(model.snapshot(source: "claude", range: 30, model: "example"))
        XCTAssertNil(model.snapshot(source: "codex", range: 7, model: "example"))
        XCTAssertEqual(service.calls.filter { $0 == "bench" }.count, 1)
    }

    func testFullReloadKeepsVisibleDataButWaitsForForcedRescanAndNewRead() async throws {
        let service = StatisticsWarmFixture(), model = make(service)
        await begin(model)
        service.holdNext = "rescan"
        let refresh = Task { await model.load(source: "codex", range: 0, model: nil, mode: .rebuild) }
        try await waitFor { service.heldOperation == "rescan" }
        XCTAssertTrue(model.busy)
        XCTAssertEqual(model.snapshot(source: "codex", range: 0, model: nil)?.payload["revision"], 1)
        service.release(); await refresh.value
        XCTAssertEqual(model.payload["revision"], 2)
        XCTAssertEqual(service.calls, ["overview", "rescan", "overview"])
        XCTAssertFalse(model.busy)
    }

    func testIncrementalReloadWaitsForRefreshAndBypassesFreshSnapshot() async throws {
        let service = StatisticsWarmFixture(), model = make(service)
        await begin(model)
        let retained = model.payload
        service.holdNext = "refresh"
        let reload = Task { await model.load(source: "codex", range: 0, model: nil, mode: .refresh) }
        try await waitFor { service.heldOperation == "refresh" }
        XCTAssertTrue(model.busy)
        XCTAssertEqual(model.payload, retained)
        XCTAssertEqual(model.snapshot(source: "codex", range: 0, model: nil)?.payload, retained)
        XCTAssertEqual(service.calls, ["overview", "refresh"])
        service.release(); await reload.value
        XCTAssertEqual(model.payload["revision"], 2)
        XCTAssertEqual(model.snapshot(source: "codex", range: 0, model: nil)?.payload["revision"], 2)
        XCTAssertEqual(service.calls, ["overview", "refresh", "overview"])
        XCTAssertTrue(model.error.isEmpty); XCTAssertFalse(model.busy)
    }

    func testIncrementalReloadRefreshesPayloadAndBenchmarkTogether() async {
        let service = StatisticsWarmFixture(), model = make(service)
        await begin(model, source: "all")
        XCTAssertEqual(model.payload["revision"], 1); XCTAssertEqual(model.benchmark["revision"], 1)
        await model.load(source: "all", range: 0, model: nil, mode: .refresh)
        XCTAssertEqual(model.payload["revision"], 2); XCTAssertEqual(model.benchmark["revision"], 2)
        XCTAssertEqual(model.snapshot(source: "all", range: 0, model: nil)?.benchmark["revision"], 2)
        XCTAssertEqual(service.calls, ["overview", "bench", "refresh", "overview", "bench"])
        XCTAssertTrue(model.error.isEmpty); XCTAssertFalse(model.busy)
    }

    func testIncrementalReloadCannotReusePrefetchStartedBeforeRefreshCompletes() async throws {
        let service = StatisticsWarmFixture(), model = make(service)
        await begin(model)
        service.holdNext = "refresh"
        let reload = Task { await model.load(source: "codex", range: 0, model: nil, mode: .refresh) }
        try await waitFor { service.heldOperation == "refresh" }
        service.holdNext = "overview"
        let warm = Task { await model.prefetch(source: "codex", range: 0) }
        try await waitFor { service.heldCount == 2 }
        XCTAssertEqual(service.calls, ["overview", "refresh", "overview"])
        // Only the refresh returns. Its earlier revision-1 prefetch remains
        // held while the visible request must obtain revision 2 separately.
        service.releaseFirst(); await reload.value
        XCTAssertEqual(service.calls, ["overview", "refresh", "overview", "overview"])
        XCTAssertEqual(model.payload["revision"], 2)
        XCTAssertEqual(model.pendingReaderCount, 1)
        service.release(); await warm.value
        XCTAssertEqual(model.snapshot(source: "codex", range: 0, model: nil)?.payload["revision"], 2)
        XCTAssertEqual(model.payload["revision"], 2)
        XCTAssertEqual(service.calls, ["overview", "refresh", "overview", "overview"])
        XCTAssertEqual(model.pendingReaderCount, 0)
    }

    func testFailedIncrementalReloadRetainsPayloadAndRetriesWithoutRebuild() async {
        let service = StatisticsWarmFixture(), model = make(service)
        await begin(model)
        let retained = model.payload
        service.failNextOverview = true
        await model.load(source: "codex", range: 0, model: nil, mode: .refresh)
        XCTAssertEqual(model.payload, retained)
        XCTAssertFalse(model.error.isEmpty); XCTAssertFalse(model.busy)
        await model.load(source: "codex", range: 0, model: nil, mode: .refresh)
        XCTAssertEqual(model.payload["revision"], 3)
        XCTAssertEqual(service.calls, ["overview", "refresh", "overview", "refresh", "overview"])
        XCTAssertTrue(model.error.isEmpty); XCTAssertFalse(model.busy)
    }

    func testStoppedIncrementalReloadCannotFetchAfterRefreshReturns() async throws {
        let service = StatisticsWarmFixture(), model = make(service)
        await begin(model)
        service.holdNext = "refresh"
        let reload = Task { await model.load(source: "all", range: 0, model: nil, mode: .refresh) }
        try await waitFor { service.heldOperation == "refresh" }
        model.stop(discard: true); service.release(); await reload.value
        XCTAssertEqual(service.calls, ["overview", "refresh"])
        XCTAssertEqual(model.payload["revision"], 1)
        XCTAssertEqual(model.pendingReaderCount, 0)
        XCTAssertTrue(model.error.isEmpty); XCTAssertFalse(model.busy)
    }

    func testOlderIncrementalReloadCannotReplaceLatestScopeOrProgress() async throws {
        let service = StatisticsWarmFixture(), model = make(service), events = NativeEvents()
        await begin(model, events: events)
        service.holdNext = "refresh"
        let old = Task { await model.load(source: "codex", range: 0, model: nil, mode: .refresh) }
        try await waitFor { service.heldOperation == "refresh" }
        service.revision = 20; service.holdNext = "overview"
        let current = Task { await model.load(source: "codex", range: 7, model: nil) }
        try await waitFor { service.heldCount == 2 }
        let progress: JSONValue = ["scanId": "replacement", "phase": "reading", "done": 1, "total": 3]
        await events.publish("stats.progress", progress)
        try await waitFor { model.readProgress.value == progress }
        var progressChanges = 0
        let observed = model.readProgress.objectWillChange.sink { progressChanges += 1 }
        service.releaseFirst(); await old.value
        XCTAssertEqual(progressChanges, 0)
        XCTAssertEqual(model.readProgress.value, progress)
        XCTAssertTrue(model.busy); XCTAssertEqual(model.pendingReaderCount, 1)
        XCTAssertEqual(model.payload["revision"], 1)
        service.release(); await current.value
        XCTAssertEqual(model.payload["revision"], 20)
        XCTAssertEqual(model.payload["range"], 7)
        XCTAssertEqual(model.snapshot(source: "codex", range: 7, model: nil)?.payload["revision"], 20)
        XCTAssertEqual(service.calls, ["overview", "refresh", "overview"])
        XCTAssertTrue(model.error.isEmpty); XCTAssertFalse(model.busy)
        withExtendedLifetime(observed) {}
    }

    func testScannedEventAfterIncrementalReloadUsesOrdinaryReadWithoutRefreshLoop() async throws {
        let service = StatisticsWarmFixture(), model = make(service), events = NativeEvents()
        var callbacks = 0
        await model.begin(events: events) {
            callbacks += 1
            await model.load(source: "codex", range: 0, model: nil)
        }
        await model.load(source: "codex", range: 0, model: nil, mode: .refresh)
        XCTAssertEqual(service.calls, ["overview", "refresh", "overview"])
        service.revision = 3
        await events.publish("stats.scanned", ["scanId": "published-incremental"])
        try await waitFor { callbacks == 2 && !model.busy && model.payload["revision"] == 3 }
        XCTAssertEqual(service.calls, ["overview", "refresh", "overview", "overview"])
        // A subsequent normal page read must use the newly cached scope,
        // rather than scheduling another refresh/scanned cycle.
        await model.load(source: "codex", range: 0, model: nil)
        XCTAssertEqual(callbacks, 2)
        XCTAssertEqual(service.calls.filter { $0 == "refresh" }.count, 1)
        XCTAssertFalse(service.calls.contains("rescan"))
        XCTAssertEqual(service.calls, ["overview", "refresh", "overview", "overview"])
        XCTAssertEqual(model.payload["revision"], 3)
        XCTAssertTrue(model.error.isEmpty); XCTAssertFalse(model.busy)
    }

    func testFailedForcedRefreshRetainsLastGoodDataAndCanRetry() async {
        let service = StatisticsWarmFixture(), model = make(service)
        await begin(model)
        service.failNextOverview = true
        await model.load(source: "codex", range: 0, model: nil, mode: .rebuild)
        XCTAssertEqual(model.payload["revision"], 1)
        XCTAssertFalse(model.error.isEmpty)
        XCTAssertFalse(model.busy)
        await model.load(source: "codex", range: 0, model: nil, mode: .rebuild)
        XCTAssertEqual(model.payload["revision"], 3)
        XCTAssertTrue(model.error.isEmpty)
    }

    func testScanInvalidationDuringPrefetchCannotCacheOldGeneration() async throws {
        let service = StatisticsWarmFixture(), model = make(service)
        service.holdNext = "overview"
        let warm = Task { await model.prefetch(source: "codex", range: 0) }
        try await waitFor { service.heldOperation == "overview" }
        model.invalidateSnapshots(); service.revision = 2
        service.release(); await warm.value
        XCTAssertEqual(model.snapshot(source: "codex", range: 0, model: nil)?.payload["revision"], 2)
        XCTAssertEqual(service.calls, ["overview", "overview"])
    }

    func testStoppedLifetimeCannotCommitHeldReply() async throws {
        let service = StatisticsWarmFixture(), model = make(service)
        service.holdNext = "overview"
        let visible = Task { await self.begin(model) }
        try await waitFor { service.heldOperation == "overview" }
        model.stop(); service.release(); await visible.value
        XCTAssertTrue(model.payload.isNull)
        XCTAssertFalse(model.busy)
        await begin(model)
        XCTAssertTrue(model.payload["loaded"].bool)
    }

    func testCancelledPrefetchWaiterDoesNotCancelVisibleSharedRead() async throws {
        let service = StatisticsWarmFixture(), model = make(service)
        service.holdNext = "overview"
        let warm = Task { await model.prefetch(source: "codex", range: 0) }
        try await waitFor { service.heldOperation == "overview" }
        let visible = Task { await self.begin(model) }
        try await waitFor { model.pendingReaderCount == 2 }
        warm.cancel(); service.release(); await warm.value; await visible.value
        XCTAssertEqual(service.calls, ["overview"])
        XCTAssertTrue(model.payload["loaded"].bool)
        XCTAssertTrue(model.error.isEmpty)
    }

    func testSoleCancelledPrefetchCannotStartTheNextBenchmarkRead() async throws {
        let service = StatisticsWarmFixture(), model = make(service)
        service.holdNext = "overview"
        let warm = Task { await model.prefetch(source: "all", range: 0) }
        try await waitFor { service.heldOperation == "overview" }
        warm.cancel(); service.release(); await warm.value
        XCTAssertEqual(service.calls, ["overview"])
        XCTAssertNil(model.snapshot(source: "all", range: 0, model: nil))
        XCTAssertEqual(model.pendingReaderCount, 0)
    }

    func testStoppingLastVisibleOwnerCannotContinueIntoBenchmarkRead() async throws {
        let service = StatisticsWarmFixture(), model = make(service)
        service.holdNext = "overview"
        let visible = Task { await self.begin(model, source: "all") }
        try await waitFor { service.heldOperation == "overview" }
        model.stop(); service.release(); await visible.value
        XCTAssertEqual(service.calls, ["overview"])
        XCTAssertTrue(model.payload.isNull)
        XCTAssertEqual(model.pendingReaderCount, 0)
    }

    func testLateOldPageStopAndScannedSubscriptionGapDoNotRetireNewPage() async {
        let service = StatisticsWarmFixture(), model = make(service), events = NativeEvents()
        let old = UUID(), current = UUID()
        await model.begin(events: events, owner: old) { await model.load(source: "codex", range: 0, model: nil) }
        model.stop(owner: old)
        // Shell invalidation is unconditional, including the gap before begin.
        model.invalidateSnapshots(); service.revision = 2
        await model.begin(events: events, owner: current) { await model.load(source: "codex", range: 0, model: nil) }
        model.stop(owner: old)
        XCTAssertEqual(model.payload["revision"], 2)
        await model.load(source: "codex", range: 0, model: nil, mode: .rebuild)
        XCTAssertEqual(model.payload["revision"], 3)
        XCTAssertFalse(model.busy)
    }

    func testFreshnessExpiryAndBoundedScopeRetention() async {
        let service = StatisticsWarmFixture(); var now: TimeInterval = 10
        let model = NativeStatsModel(service: service, clock: { now })
        await begin(model)
        now = 39; await model.load(source: "codex", range: 0, model: nil)
        XCTAssertEqual(service.calls.count, 1)
        now = 40; service.revision = 2
        await model.load(source: "codex", range: 0, model: nil)
        XCTAssertEqual(service.calls.count, 2)
        XCTAssertEqual(model.payload["revision"], 2)
        for i in 0..<13 { await model.load(source: "codex", range: 7, model: "model-\(i)") }
        XCTAssertNil(model.snapshot(source: "codex", range: 0, model: nil))
        XCTAssertNil(model.snapshot(source: "codex", range: 7, model: "model-0"))
        XCTAssertNotNil(model.snapshot(source: "codex", range: 7, model: "model-12"))
        model.stop()
    }

    func testMidnightExpiresThePriorDayEvenWithinTheFreshnessWindow() async {
        let service = StatisticsWarmFixture()
        var day = Date(timeIntervalSince1970: 1_000_000)
        let model = NativeStatsModel(service: service, clock: { 10 }, day: { day })
        await begin(model)
        day = day.addingTimeInterval(86_400); service.revision = 2
        await model.load(source: "codex", range: 0, model: nil)
        XCTAssertEqual(service.calls, ["overview", "overview"])
        XCTAssertEqual(model.payload["revision"], 2)
        model.stop()
    }

    func testMismatchedSourceResponseCannotEnterTheScopeCache() async {
        let service = StatisticsWarmFixture(), model = make(service)
        service.wrongSource = true
        await begin(model)
        XCTAssertTrue(model.payload.isNull)
        XCTAssertNil(model.snapshot(source: "codex", range: 0, model: nil))
        XCTAssertFalse(model.error.isEmpty)
        service.wrongSource = false
        await model.load(source: "codex", range: 0, model: nil)
        XCTAssertTrue(model.payload["loaded"].bool)
    }

    func testDiscardReachesSupersededPrefetchFlights() async throws {
        let service = StatisticsWarmFixture(), model = make(service)
        service.holdNext = "overview"
        let old = Task { await model.prefetch(source: "all", range: 0) }
        try await waitFor { service.heldCount == 1 }
        model.invalidateSnapshots(); service.holdNext = "overview"
        let current = Task { await model.prefetch(source: "all", range: 0) }
        try await waitFor { service.heldCount == 2 }
        XCTAssertEqual(model.pendingReaderCount, 2)
        model.stop(discard: true); service.release()
        await old.value; await current.value
        XCTAssertEqual(service.calls, ["overview", "overview"])
        XCTAssertNil(model.snapshot(source: "all", range: 0, model: nil))
        XCTAssertEqual(model.pendingReaderCount, 0)
    }

    func testStoppedForcedReloadCannotAdmitAHiddenFetchAfterScanReturns() async throws {
        let service = StatisticsWarmFixture(), model = make(service)
        await begin(model)
        service.holdNext = "rescan"
        let refresh = Task { await model.load(source: "all", range: 0, model: nil, mode: .rebuild) }
        try await waitFor { service.heldOperation == "rescan" }
        model.stop(discard: true); service.release(); await refresh.value
        XCTAssertEqual(service.calls, ["overview", "rescan"])
        XCTAssertEqual(model.payload["revision"], 1)
        XCTAssertFalse(model.busy)
        XCTAssertEqual(model.pendingReaderCount, 0)
    }

    func testFlightAcrossMidnightCannotSatisfyTheNewDayRead() async throws {
        let service = StatisticsWarmFixture()
        var day = Date(timeIntervalSince1970: 1_000_000)
        let model = NativeStatsModel(service: service, day: { day })
        service.holdNext = "overview"
        let warm = Task { await model.prefetch(source: "codex", range: 0) }
        try await waitFor { service.heldCount == 1 }
        day = day.addingTimeInterval(86_400); service.revision = 2
        await begin(model)
        XCTAssertEqual(service.calls, ["overview", "overview"])
        XCTAssertEqual(model.payload["revision"], 2)
        service.release(); await warm.value
        XCTAssertEqual(service.calls, ["overview", "overview"])
        XCTAssertEqual(model.snapshot(source: "codex", range: 0, model: nil)?.payload["revision"], 2)
        model.stop(discard: true)
    }

    func testFileProgressDoesNotPublishWholeModelChanges() async throws {
        let service = StatisticsWarmFixture(), model = make(service), events = NativeEvents()
        await begin(model, events: events)
        var wholeChanges = 0, progressChanges = 0
        let whole = model.objectWillChange.sink { wholeChanges += 1 }
        let progress = model.readProgress.objectWillChange.sink { progressChanges += 1 }
        for i in 1...100 { await events.publish("stats.progress", ["done": .number(Double(i)), "total": 100]) }
        try await waitFor { model.readProgress.value["done"].int == 100 }
        XCTAssertEqual(progressChanges, 100)
        XCTAssertEqual(wholeChanges, 0)
        withExtendedLifetime((whole, progress)) {}
    }

    func testStoppedVisibleWaiterCannotRejoinSurvivingPrefetchAfterInvalidation() async throws {
        let service = StatisticsWarmFixture(), model = make(service)
        service.holdNext = "overview"
        let warm = Task { await model.prefetch(source: "codex", range: 0) }
        try await waitFor { service.heldCount == 1 }
        var visibleFinished = false
        let visible = Task { await self.begin(model); visibleFinished = true }
        try await waitFor { model.pendingReaderCount == 2 }
        model.stop(); model.invalidateSnapshots(); service.revision = 2
        service.holdNext = "overview"; service.releaseFirst()
        try await waitFor { visibleFinished && service.heldCount == 1 }
        XCTAssertEqual(model.pendingReaderCount, 1, "Only the surviving prefetch may own the replacement")
        XCTAssertEqual(service.calls, ["overview", "overview"])
        XCTAssertTrue(model.payload.isNull)
        service.release(); await warm.value; await visible.value
        XCTAssertEqual(model.snapshot(source: "codex", range: 0, model: nil)?.payload["revision"], 2)
    }

    func testReplacementBeginRevokesHeldReloadBeforeItsInitialLoad() async throws {
        let service = StatisticsWarmFixture(), model = make(service)
        await begin(model); service.holdNext = "rescan"
        let refresh = Task { await model.load(source: "all", range: 0, model: nil, mode: .rebuild) }
        try await waitFor { service.heldOperation == "rescan" }
        var entered = false
        var initial: CheckedContinuation<Void, Never>?
        defer { initial?.resume() }
        let replacement = Task {
            await model.begin(events: NativeEvents(), owner: UUID()) {
                entered = true
                await withCheckedContinuation { initial = $0 }
            }
        }
        try await waitFor { entered }
        service.release(); await refresh.value
        XCTAssertEqual(service.calls, ["overview", "rescan"])
        initial?.resume(); initial = nil; await replacement.value
        XCTAssertEqual(model.payload["revision"], 1)
    }

    func testIndependentVisibleReadResetsPriorScanCounterWhileRetainingContent() async throws {
        let service = StatisticsWarmFixture(), model = make(service), events = NativeEvents()
        await begin(model, events: events)
        let previous: JSONValue = ["scanId": "previous", "phase": "reading", "done": 2545, "total": 2547, "file": "previous.json"]
        await events.publish("stats.progress", previous)
        try await waitFor { model.readProgress.value == previous }
        let retained = model.payload
        model.invalidateSnapshots(); service.revision = 2; service.holdNext = "overview"
        let read = Task { await model.load(source: "codex", range: 0, model: nil) }
        try await waitFor { service.heldOperation == "overview" }
        XCTAssertTrue(model.busy)
        XCTAssertEqual(model.readProgress.value, ["phase": "loading"])
        XCTAssertEqual(model.payload, retained)
        XCTAssertEqual(model.snapshot(source: "codex", range: 0, model: nil)?.payload, retained)
        service.release(); await read.value
        XCTAssertEqual(model.payload["revision"], 2)
        XCTAssertEqual(model.payload["derived"]["summary"]["totals"]["input"].int, 987654321)
        XCTAssertEqual(service.calls, ["overview", "overview"])
        XCTAssertTrue(model.error.isEmpty)
        XCTAssertFalse(model.busy)
    }

    func testStoppedScanAndAbsentCompletionCannotLeakCounterIntoHeldReentry() async throws {
        let service = StatisticsWarmFixture(), model = make(service), events = NativeEvents()
        let old = UUID(), current = UUID()
        await model.begin(events: events, owner: old) { await model.load(source: "codex", range: 0, model: nil) }
        service.holdNext = "rescan"
        let refresh = Task { await model.load(source: "codex", range: 0, model: nil, mode: .rebuild) }
        try await waitFor { service.heldOperation == "rescan" }
        let previous: JSONValue = ["scanId": "departed", "phase": "reading", "done": 2545, "total": 2547, "file": "previous.json"]
        await events.publish("stats.progress", previous)
        try await waitFor { model.readProgress.value == previous }
        model.stop(owner: old)
        XCTAssertFalse(model.busy)
        XCTAssertEqual(model.readProgress.value, ["phase": "loading"])
        service.release(); await refresh.value
        await events.publish("stats.progress", ["scanId": "departed", "phase": "complete", "done": 2547, "total": 2547])
        await events.publish("stats.scanned", ["scanId": "departed"])
        // The shell invalidates snapshots even without a visible page listener.
        model.invalidateSnapshots()
        XCTAssertEqual(service.calls, ["overview", "rescan"])
        service.holdNext = "overview"
        let entry = Task {
            await model.begin(events: events, owner: current) { await model.load(source: "codex", range: 0, model: nil) }
        }
        try await waitFor { service.heldOperation == "overview" }
        XCTAssertTrue(model.busy)
        XCTAssertEqual(model.readProgress.value, ["phase": "loading"])
        XCTAssertEqual(model.payload["revision"], 1)
        XCTAssertEqual(model.snapshot(source: "codex", range: 0, model: nil)?.payload["revision"], 1)
        model.stop(owner: old)
        XCTAssertTrue(model.busy)
        XCTAssertEqual(model.pendingReaderCount, 1)
        service.release(); await entry.value
        XCTAssertEqual(model.payload["revision"], 2)
        XCTAssertEqual(model.readProgress.value, ["phase": "loading"])
        XCTAssertEqual(service.calls, ["overview", "rescan", "overview"])
        XCTAssertTrue(model.error.isEmpty)
        XCTAssertFalse(model.busy)
        XCTAssertEqual(model.pendingReaderCount, 0)
    }

    func testFullReloadResetsProgressBeforeRescanAndAfterItsCompletion() async throws {
        let service = StatisticsWarmFixture(), model = make(service), events = NativeEvents()
        await begin(model, events: events)
        let previous: JSONValue = ["scanId": "previous", "phase": "reading", "done": 2545, "total": 2547]
        await events.publish("stats.progress", previous)
        try await waitFor { model.readProgress.value == previous }
        service.holdNext = "rescan"
        let refresh = Task { await model.load(source: "codex", range: 0, model: nil, mode: .rebuild) }
        try await waitFor { service.heldOperation == "rescan" }
        XCTAssertEqual(model.readProgress.value, ["phase": "loading"])
        let phases: [JSONValue] = [
            ["scanId": "current", "phase": "discovering", "done": 0, "total": 0],
            ["scanId": "current", "phase": "reading", "done": 5, "total": 7, "file": "current.json"],
            ["scanId": "current", "phase": "assembling", "done": 7, "total": 7],
            ["scanId": "current", "phase": "folding", "done": 7, "total": 7],
            ["scanId": "current", "phase": "complete", "done": 7, "total": 7]
        ]
        for phase in phases {
            await events.publish("stats.progress", phase)
            try await waitFor { model.readProgress.value == phase }
            XCTAssertTrue(model.busy)
            XCTAssertEqual(model.payload["revision"], 1)
        }
        service.holdNext = "overview"; service.release()
        try await waitFor { service.heldOperation == "overview" }
        XCTAssertTrue(model.busy)
        XCTAssertEqual(model.readProgress.value, ["phase": "loading"])
        XCTAssertEqual(model.payload["revision"], 1)
        XCTAssertEqual(model.snapshot(source: "codex", range: 0, model: nil)?.payload["revision"], 1)
        service.release(); await refresh.value
        XCTAssertEqual(model.payload["revision"], 2)
        XCTAssertEqual(service.calls, ["overview", "rescan", "overview"])
        XCTAssertTrue(model.error.isEmpty)
        XCTAssertFalse(model.busy)
    }

    func testOlderReloadCompletionCannotResetReplacementReadProgress() async throws {
        let service = StatisticsWarmFixture(), model = make(service), events = NativeEvents()
        await begin(model, events: events)
        service.holdNext = "rescan"
        let old = Task { await model.load(source: "codex", range: 0, model: nil, mode: .rebuild) }
        try await waitFor { service.heldOperation == "rescan" }
        service.revision = 20; service.holdNext = "overview"
        let current = Task { await model.load(source: "codex", range: 7, model: nil) }
        try await waitFor { service.heldCount == 2 }
        let progress: JSONValue = ["scanId": "replacement", "phase": "reading", "done": 5, "total": 7, "file": "current.json"]
        await events.publish("stats.progress", progress)
        try await waitFor { model.readProgress.value == progress }
        var progressChanges = 0
        let observed = model.readProgress.objectWillChange.sink { progressChanges += 1 }
        service.releaseFirst(); await old.value
        XCTAssertEqual(progressChanges, 0, "A superseded rescan must not reset the current read's phase")
        XCTAssertEqual(model.readProgress.value, progress)
        XCTAssertTrue(model.busy)
        XCTAssertEqual(model.payload["revision"], 1)
        XCTAssertEqual(model.pendingReaderCount, 1)
        service.release(); await current.value
        XCTAssertEqual(model.payload["revision"], 20)
        XCTAssertEqual(model.payload["source"], "codex")
        XCTAssertEqual(model.payload["range"], 7)
        XCTAssertEqual(model.snapshot(source: "codex", range: 7, model: nil)?.payload["revision"], 20)
        XCTAssertEqual(service.calls, ["overview", "rescan", "overview"])
        XCTAssertTrue(model.error.isEmpty)
        XCTAssertFalse(model.busy)
        withExtendedLifetime(observed) {}
    }

    func testScannedEventReplacementOwnsHeldReadAfterOlderReloadReturns() async throws {
        let service = StatisticsWarmFixture(), model = make(service), events = NativeEvents()
        await begin(model, events: events)
        service.holdNext = "rescan"
        let old = Task { await model.load(source: "codex", range: 0, model: nil, mode: .rebuild) }
        try await waitFor { service.heldOperation == "rescan" }
        service.revision = 7; service.holdNext = "overview"
        await events.publish("stats.scanned", ["scanId": "published"])
        try await waitFor { service.heldCount == 2 }
        XCTAssertEqual(model.readProgress.value, ["phase": "loading"])
        XCTAssertEqual(model.payload["revision"], 1)
        var progressChanges = 0
        let observed = model.readProgress.objectWillChange.sink { progressChanges += 1 }
        service.releaseFirst(); await old.value
        XCTAssertEqual(progressChanges, 0)
        XCTAssertTrue(model.busy)
        XCTAssertEqual(model.pendingReaderCount, 1)
        XCTAssertEqual(model.payload["revision"], 1)
        service.release()
        try await waitFor { !model.busy && model.payload["revision"] == 7 }
        XCTAssertEqual(model.snapshot(source: "codex", range: 0, model: nil)?.payload["revision"], 7)
        XCTAssertEqual(service.calls, ["overview", "rescan", "overview"])
        XCTAssertTrue(model.error.isEmpty)
        XCTAssertEqual(model.pendingReaderCount, 0)
        withExtendedLifetime(observed) {}
    }

    func testSharedPrefetchDoesNotResetCurrentVisibleScanProgress() async throws {
        let service = StatisticsWarmFixture(), model = make(service), events = NativeEvents()
        await begin(model, events: events)
        model.invalidateSnapshots(); service.revision = 2; service.holdNext = "overview"
        let visible = Task { await model.load(source: "codex", range: 0, model: nil) }
        try await waitFor { service.heldOperation == "overview" }
        let progress: JSONValue = ["scanId": "shared", "phase": "reading", "done": 5, "total": 7]
        await events.publish("stats.progress", progress)
        try await waitFor { model.readProgress.value == progress }
        var progressChanges = 0
        let observed = model.readProgress.objectWillChange.sink { progressChanges += 1 }
        let warm = Task { await model.prefetch(source: "codex", range: 0) }
        try await waitFor { model.pendingReaderCount == 2 }
        XCTAssertEqual(progressChanges, 0)
        XCTAssertEqual(model.readProgress.value, progress)
        XCTAssertEqual(service.calls, ["overview", "overview"])
        warm.cancel()
        try await waitFor { model.pendingReaderCount == 1 }
        XCTAssertTrue(model.busy)
        XCTAssertEqual(model.readProgress.value, progress)
        service.release(); await visible.value; await warm.value
        XCTAssertEqual(model.payload["revision"], 2)
        XCTAssertEqual(service.calls, ["overview", "overview"])
        XCTAssertTrue(model.error.isEmpty)
        XCTAssertFalse(model.busy)
        withExtendedLifetime(observed) {}
    }
}
