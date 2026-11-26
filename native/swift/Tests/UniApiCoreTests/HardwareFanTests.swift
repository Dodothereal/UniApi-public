import XCTest
@testable import UniApiCore

final class HardwareFanTests: XCTestCase {
    private func runtime() throws -> NativeRuntime {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("fan-fixture-\(UUID().uuidString)")
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return try NativeRuntime(paths: NativePaths(root: root, home: root.appendingPathComponent("home")))
    }
    private func sample(_ time: Double, temperature: Double = 40, fan: Double = 2000, include: Bool = true) -> JSONValue {
        ["date": .number(time), "thermal": 0, "fans": [["id": 0, "actual": .number(fan), "target": 2000, "minimum": 1200, "maximum": 6000, "mode": 0]], "sensors": include ? [["id": "CPU", "value": .number(temperature)]] : []]
    }
    func testHistoryMetricCountsKeepMissingSensorsOutOfTheMean() {
        let a = NativeFanHistory.aggregate(sample(10000, temperature: 40)), b = NativeFanHistory.aggregate(sample(20000, include: false)), c = NativeFanHistory.aggregate(sample(30000, temperature: 60))
        let result = NativeFanHistory.merge(NativeFanHistory.merge(a, b), c)
        XCTAssertEqual(result["count"], 3)
        XCTAssertEqual(result["sensors"]["CPU"].array, [2, 100, 40, 60])
        XCTAssertEqual(result["fans"]["0"]["actual"].array.first, 3)
    }
    func testHistoryBackfillAndCompactionRetainSummaries() throws {
        let runtime = try runtime(), history = try NativeFanHistory(db: runtime.db, clock: { 200000000 })
        let a = sample(10000), b = sample(20000, temperature: 60)
        try runtime.db.execute("INSERT INTO fans_history(timestamp,snapshot,aggregated) VALUES (?,?,0)", [10000, .string(String(decoding: try a.encoded(), as: UTF8.self))])
        XCTAssertEqual(try history.backfill(), 1); XCTAssertEqual(try history.backfill(), 0)
        XCTAssertTrue(try history.persist(b)); XCTAssertFalse(try history.persist(b))
        let range = try history.read(since: 0, until: 200000000)
        XCTAssertFalse(range["points"].array.isEmpty)
        let metric = range["points"].array[0]
        XCTAssertEqual(metric["mean"]["sensors"].array.first?["value"], 50)
        XCTAssertEqual(metric["min"]["sensors"].array.first?["value"], 40)
        XCTAssertEqual(metric["max"]["sensors"].array.first?["value"], 60)
    }
    func testControllerKeepsOnlyUntimedIntentAndReleaseRetiresIt() async throws {
        let runtime = try runtime(), fixture = FanFixtureIO()
        let service = NativeFanService(runtime: runtime, io: fixture.io)
        try await service.accept(sample(10000)); await service.poll()
        _ = try await service.handle("control", input: ["command": "manual", "duration": 0, "speeds": [2300]])
        let manual = try await service.handle("status")
        XCTAssertEqual(manual["keep"]["command"], "manual")
        _ = try await service.handle("control", input: ["command": "boost", "duration": 300])
        let boost = try await service.handle("status"); XCTAssertTrue(boost["keep"].isNull)
        _ = try await service.handle("control", input: ["command": "cooler"])
        _ = try await service.handle("release")
        let auto = try await service.handle("status"); XCTAssertTrue(auto["keep"].isNull)
        XCTAssertEqual(auto["control"]["mode"], "automatic")
        XCTAssertEqual(fixture.commands.last?["command"], "automatic")
    }
    func testStaleReadingsReleaseWithoutTestingRealFans() async throws {
        let runtime = try runtime(), fixture = FanFixtureIO()
        let service = NativeFanService(runtime: runtime, io: fixture.io)
        try await service.accept(sample(10000)); await service.poll()
        _ = try await service.handle("control", input: ["command": "cooler"])
        fixture.now = 17000; await service.poll()
        XCTAssertEqual(fixture.commands.last?["command"], "automatic")
        let stale = try await service.handle("status"); XCTAssertTrue(stale["snapshot"].isNull)
    }
    func testTimeoutReconcilesAcceptedControlBeforeReportingFailure() async throws {
        let runtime = try runtime(), fixture = FanFixtureIO()
        fixture.failAfterAccept = true
        let service = NativeFanService(runtime: runtime, io: fixture.io)
        try await service.accept(sample(10000)); await service.poll()
        _ = try await service.handle("control", input: ["command": "cooler"])
        let status = try await service.handle("status")
        XCTAssertEqual(status["control"]["mode"], "cooler")
        XCTAssertEqual(status["keep"]["command"], "cooler")
        XCTAssertFalse(status["busy"].bool)
    }
    func testHistoryRangeAcceptsFractionalWallClockAndLeavesLongGaps() async throws {
        let runtime = try runtime(), fixture = FanFixtureIO()
        fixture.now = 90000.25
        let service = NativeFanService(runtime: runtime, io: fixture.io)
        try await service.accept(sample(10000)); try await service.accept(sample(80000))
        let value = try await service.handle("history")
        XCTAssertEqual(value["until"], 90000)
        let samples = NativeFanHistory.discontinuousSamples(value["points"].array, kind: "mean")
        XCTAssertEqual(samples.count, 3)
        XCTAssertTrue(samples[1]["sensors"].array.isEmpty)
    }
    func testVisualClockPreservesPhaseAcrossRateChangesAndPauses() {
        var clock = NativeVisualClock()
        clock.update(at: 100, rate: 1)
        XCTAssertEqual(clock.value(at: 101.25), 1.25)
        clock.update(at: 101.25, rate: 2)
        XCTAssertEqual(clock.value(at: 101.25), 1.25)
        clock.update(at: 102, rate: 0)
        XCTAssertEqual(clock.value(at: 900), 2.75)
        clock.update(at: 900, rate: 1)
        XCTAssertEqual(clock.value(at: 901), 3.75)
        XCTAssertEqual(NativeVisualClock.fanRate(2500), 1)
        XCTAssertEqual(NativeVisualClock.fanRate(9000), 3.2)
    }
    func testStorageMetadataReusesOneMinuteSnapshotThenRefreshes() throws {
        let runtime = try runtime(), clock = HistoryFixtureClock()
        let history = try NativeFanHistory(db: runtime.db, clock: { clock.now() })
        XCTAssertTrue(try history.persist(sample(10000)))
        let first = try history.storage()
        var extra = sample(20000); extra["unused"] = .string(String(repeating: "x", count: 6000))
        try runtime.db.execute("INSERT INTO fans_history(timestamp,snapshot,aggregated) VALUES (?,?,1)", [20000, .string(String(decoding: try extra.encoded(), as: UTF8.self))])
        XCTAssertEqual(try history.storage()["bytes"], first["bytes"])
        clock.advance(60001)
        XCTAssertGreaterThan(try history.storage()["bytes"].double, first["bytes"].double + 6000)
    }
    func testAttachPublishesStateAndReattachesLiveSessionWithoutReauthorizing() async throws {
        let runtime = try runtime(), fixture = FanFixtureIO()
        fixture.daemonInstalled = false
        fixture.daemonAvailable = false
        fixture.sessionAvailable = true
        let service = NativeFanService(runtime: runtime, io: fixture.io)
        let events = await runtime.events.stream()
        let attachedEvent = expectation(description: "Attach publishes fans.state")
        let observer = Task {
            for await event in events where event.topic == "fans.state" && event.data["enabled"].bool {
                attachedEvent.fulfill(); return
            }
        }
        defer { observer.cancel() }
        try await service.accept(sample(10000))
        await service.poll()
        await fulfillment(of: [attachedEvent], timeout: 2)
        let enabled = try await service.handle("enable")
        XCTAssertTrue(enabled["enabled"].bool)
        XCTAssertEqual(fixture.authorizations, [])
    }
    func testTransientPollFailureRecoversAndKeepAwakeTracksActiveControl() async throws {
        let runtime = try runtime(), fixture = FanFixtureIO()
        let service = NativeFanService(runtime: runtime, io: fixture.io)
        try await service.accept(sample(10000)); await service.poll()
        XCTAssertEqual(fixture.keepAwakeHistory.last, false)
        _ = try await service.handle("control", input: ["command": "cooler"])
        XCTAssertEqual(fixture.keepAwakeHistory.last, true)
        fixture.failNextRequests = 2
        await service.poll()
        let afterTransient = try await service.handle("status")
        XCTAssertTrue(afterTransient["enabled"].bool, "One transient poll error must not drop the session")
        await service.poll()
        fixture.failNextRequests = 4
        await service.poll()
        await service.poll()
        let dropped = try await service.handle("status")
        XCTAssertFalse(dropped["enabled"].bool, "Consecutive unrecoverable poll failures must drop the session")
        XCTAssertEqual(fixture.keepAwakeHistory.last, false)
        await service.poll()
        let reattached = try await service.handle("status")
        XCTAssertTrue(reattached["enabled"].bool, "A returning helper socket must re-attach automatically")
        XCTAssertEqual(fixture.keepAwakeHistory.last, true)
        _ = try await service.handle("release")
        XCTAssertEqual(fixture.keepAwakeHistory.last, false)
    }
    func testInstallReattachesRunningCurrentDaemonWithoutPasswordPrompt() async throws {
        let runtime = try runtime(), fixture = FanFixtureIO()
        let service = NativeFanService(runtime: runtime, io: fixture.io)
        try await service.accept(sample(10000))
        let state = try await service.handle("install")
        XCTAssertTrue(state["enabled"].bool)
        XCTAssertEqual(fixture.authorizations, [])
    }
}

private final class HistoryFixtureClock: @unchecked Sendable {
    private let lock = NSLock(); private var value: Double = 100000
    func now() -> Double { lock.lock(); defer { lock.unlock() }; return value }
    func advance(_ ms: Double) { lock.lock(); value += ms; lock.unlock() }
}

private final class FanFixtureIO: @unchecked Sendable {
    private let lock = NSRecursiveLock()
    var now: Double = 10000
    var mode = "automatic"
    var commands: [JSONValue] = []
    var authorizations: [String] = []
    var keepAwakeHistory: [Bool] = []
    var daemonInstalled = true
    var daemonAvailable = true
    var sessionAvailable = false
    var current = true
    var failAfterAccept = false
    var failNextRequests = 0
    private func readMetadata() -> JSONValue {
        lock.lock(); defer { lock.unlock() }
        return ["supported": true, "installed": true, "daemonInstalled": .bool(daemonInstalled), "daemonAvailable": .bool(daemonAvailable), "sessionAvailable": .bool(sessionAvailable), "current": .bool(current)]
    }
    private func handleRequest(_ command: JSONValue) throws -> JSONValue {
        lock.lock(); defer { lock.unlock() }
        if failNextRequests > 0 { failNextRequests -= 1; throw NativeFailure("Fixture transient IPC failure") }
        commands.append(command)
        if command["command"].string != "status" { mode = command["command"].string; if failAfterAccept { throw NativeFailure("Fixture timeout after acceptance") } }
        return ["ok": true, "mode": .string(mode), "message": "fixture"]
    }
    private func recordAuthorization(_ action: String) {
        lock.lock(); defer { lock.unlock() }; authorizations.append(action)
    }
    private func recordKeepAwake(_ active: Bool) {
        lock.lock(); defer { lock.unlock() }; keepAwakeHistory.append(active)
    }
    var io: NativeFanIO {
        .init(metadata: { self.readMetadata() }, monitor: { AsyncThrowingStream { $0.finish() } }, request: { command, _ in
            try self.handleRequest(command)
        }, authorize: { action in
            self.recordAuthorization(action)
        }, now: { self.now }, sleep: { _ in }, keepAwake: { active in
            self.recordKeepAwake(active)
        })
    }
}
