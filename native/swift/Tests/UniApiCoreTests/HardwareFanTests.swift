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
    var failAfterAccept = false
    var io: NativeFanIO {
        .init(metadata: { ["supported": true, "installed": true, "daemonInstalled": true, "daemonAvailable": true, "current": true] }, monitor: { AsyncThrowingStream { $0.finish() } }, request: { command, _ in
            self.lock.lock(); defer { self.lock.unlock() }; self.commands.append(command)
            if command["command"].string != "status" { self.mode = command["command"].string; if self.failAfterAccept { throw NativeFailure("Fixture timeout after acceptance") } }
            return ["ok": true, "mode": .string(self.mode), "message": "fixture"]
        }, authorize: { _ in }, now: { self.now }, sleep: { _ in })
    }
}
