import XCTest
@testable import UniApiCore

final class HardwareParityReconciliationTests: XCTestCase {
    private func runtime() throws -> NativeRuntime {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("hardware-parity-\(UUID().uuidString)")
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return try NativeRuntime(paths: NativePaths(root: root, home: root.appendingPathComponent("home")))
    }
    private func fanSample(_ date: Double = 10000) -> JSONValue {
        ["date": .number(date), "thermal": 2, "fans": [["id": 0, "actual": 2500, "target": 2400, "minimum": 1200, "maximum": 6000, "mode": 1]], "sensors": [["id": "TCMb", "value": 65], ["id": "TCMz", "value": 100], ["id": "Tg0D", "value": 70]]]
    }
    func testAbsentHelperPreservesExactCurrentlyConfiguredTargetOutsideNativeLevels() {
        let status: JSONValue = ["supported": true, "levels": [80, 85, 90, 95, 100], "limit": 55, "holdMin": 25, "phase": "holding", "hold": ["installed": false, "active": false]]
        XCTAssertEqual(NativeHardwareDisplayPolicies.batteryTarget(status), 55)
        XCTAssertEqual(NativeHardwareDisplayPolicies.batteryLevels(status), [55, 80, 85, 90, 95, 100])
        XCTAssertFalse(NativeHardwareDisplayPolicies.batteryLevels(status).contains(25))
        XCTAssertFalse(NativeHardwareDisplayPolicies.batteryLevels(status).contains(54))
        // The existing native setter still rejects that unsupported target; displaying
        // the current value must not widen charging admission or install a helper.
        XCTAssertThrowsError(try NativeHardwarePolicies.batteryTarget(55, levels: status["levels"].array, hold: false))
    }
    func testInstalledBatteryHelperAddsWholeLowerLevelsAndRetainsHeldTarget() {
        let status: JSONValue = ["levels": [80, 85, 90, 95, 100], "limit": 80, "holdMin": 25, "hold": ["installed": true, "active": true, "target": 55]]
        XCTAssertEqual(NativeHardwareDisplayPolicies.batteryTarget(status), 55)
        XCTAssertEqual(NativeHardwareDisplayPolicies.batteryLevels(status), Array(25...80) + [85, 90, 95, 100])
        XCTAssertEqual(NativeHardwareDisplayPolicies.batteryLevels(.null), [100])
    }
    func testEmptyNativeCatalogUsesTheSameEightyPercentHoldFloorAsAdmission() throws {
        let status: JSONValue = ["supported": true, "levels": [], "limit": 100, "holdMin": 25, "phase": "off", "hold": ["installed": true, "active": false]]
        let offered = NativeHardwareDisplayPolicies.batteryLevels(status)
        XCTAssertEqual(offered, Array(25..<80) + [100])
        for target in offered where target != 100 {
            XCTAssertEqual(try NativeHardwarePolicies.batteryTarget(.number(Double(target)), levels: [], hold: true), target)
        }
        XCTAssertFalse(offered.contains(80)); XCTAssertFalse(offered.contains(85)); XCTAssertFalse(offered.contains(99))
        XCTAssertThrowsError(try NativeHardwarePolicies.batteryTarget(85, levels: [], hold: false))
        XCTAssertThrowsError(try NativeHardwarePolicies.batteryTarget(80, levels: [], hold: true))
        var absent = status; absent["hold"]["installed"] = false
        XCTAssertEqual(NativeHardwareDisplayPolicies.batteryLevels(absent), [100])
    }
    func testEmptyCatalogPreservesExactCurrentlyConfiguredTargetAsDisplayMarker() {
        let status: JSONValue = ["supported": true, "levels": [], "limit": 85, "phase": "above-limit", "holdMin": 25, "hold": ["installed": true, "active": false]]
        XCTAssertEqual(NativeHardwareDisplayPolicies.batteryTarget(status), 85)
        XCTAssertEqual(NativeHardwareDisplayPolicies.batteryLevels(status), Array(25..<80) + [85, 100])
    }
    func testAllNativeBatteryPhasesAndUnverifiedChargingAreDistinct() {
        let base: JSONValue = ["supported": true, "limit": 80, "battery": ["percent": 80, "externalConnected": true, "charging": false]]
        var cases: [(JSONValue, String)] = [(base, "holding")]
        var state = base; state["supported"] = false; cases.append((state, "unsupported"))
        state = base; state["limit"] = 100; cases.append((state, "off"))
        state = base; state["battery"] = .null; cases.append((state, "control-pending"))
        state = base; state["battery"]["externalConnected"] = false; cases.append((state, "on-battery"))
        state = base; state["battery"]["percent"] = 81; cases.append((state, "above-limit"))
        state = base; state["battery"]["percent"] = 79; cases.append((state, "below-limit-idle"))
        state["battery"]["charging"] = true; cases.append((state, "charging-to-limit"))
        state["battery"]["percent"] = 80; cases.append((state, "control-pending"))
        for (state, expected) in cases { XCTAssertEqual(NativeHardwarePolicies.batteryPhase(state), expected) }
    }
    func testHeldBatteryPhasesRequireMatchingFreshReadbackIncludingOffRecovery() {
        let report: JSONValue = ["version": 2, "target": 55, "updatedAt": 10000, "state": "inhibiting", "battery": ["percent": 55, "external": true, "charging": false]]
        var hold = NativeHardwarePolicies.holdReport(report, target: 55, now: 10000)
        hold["installed"] = true; hold["active"] = true; hold["target"] = 55
        var status: JSONValue = ["supported": true, "limit": 80, "hold": hold]
        XCTAssertEqual(NativeHardwarePolicies.batteryPhase(status), "holding-low")
        status["hold"]["reportedBattery"]["charging"] = true
        XCTAssertEqual(NativeHardwarePolicies.batteryPhase(status), "control-pending")
        for phase in ["write-refused", "telemetry-unavailable"] {
            status["hold"]["state"] = .string(phase)
            XCTAssertEqual(NativeHardwarePolicies.batteryPhase(status), "control-error")
        }
        XCTAssertFalse(NativeHardwarePolicies.holdReport(report, target: 50, now: 10000)["healthy"].bool)
        XCTAssertFalse(NativeHardwarePolicies.holdReport(report, target: 55, now: 25001)["healthy"].bool)
        status["hold"] = ["installed": true, "healthy": true, "active": false, "state": "pending"]
        status["limit"] = 100
        XCTAssertEqual(NativeHardwarePolicies.batteryPhase(status), "control-pending")
    }
    func testHeldHistoryQueriesCannotReplaceNewestRangeOrItsCSVOutOfOrder() async {
        let store = HardwareParityHistoryClient(), old = HardwareParityGate(), latest = HardwareParityGate()
        let oldID = await store.begin("30m")
        let oldTask = Task { let value = await old.wait(); await store.resolve(oldID, value) }
        let newID = await store.begin("7d")
        let whileHeld = await store.value("7d")
        XCTAssertTrue(whileHeld.isNull)
        await latest.release(["points": [["mean": ["date": 7000, "sensors": [["id": "selected", "value": 70]]], "end": 7000, "count": 1, "resolutionMs": 10000]]])
        let newTask = Task { let value = await latest.wait(); await store.resolve(newID, value) }
        await newTask.value
        await old.release(["points": [["mean": ["date": 1000, "sensors": [["id": "stale", "value": 1]]]]]])
        await oldTask.value
        let result = await store.value("7d")
        let csv = NativeHardwareDisplayPolicies.fanHistoryCSV(result["points"].array)
        XCTAssertTrue(csv.contains("temperature_c:selected")); XCTAssertFalse(csv.contains("stale"))
        let obsolete = await store.value("30m"); XCTAssertTrue(obsolete.isNull)
    }
    func testHistoryFailureFromSupersededReadCannotClearNewestErrorOrData() {
        var selection = NativeFanHistorySelection()
        let old = selection.begin(scope: "all"), current = selection.begin(scope: "custom:1:2")
        XCTAssertTrue(selection.reject(current, message: "Current query failed"))
        XCTAssertFalse(selection.resolve(old, value: ["points": [1]]))
        XCTAssertEqual(selection.error(for: "custom:1:2"), "Current query failed")
        let retry = selection.begin(scope: "custom:1:2")
        XCTAssertTrue(selection.resolve(retry, value: ["points": [2]]))
        XCTAssertFalse(selection.reject(current, message: "Late failure"))
        XCTAssertEqual(selection.value(for: "custom:1:2")["points"], [2])
        XCTAssertNil(selection.error(for: "custom:1:2"))
        _ = selection.begin(scope: "30m")
        XCTAssertTrue(selection.value(for: "30m").isNull)
    }
    func testManualFanTargetClampsEveryFanWithoutChangingTheirIdentity() {
        var snapshot = fanSample()
        snapshot["fans"] = .array(snapshot["fans"].array + [["id": 1, "actual": 1900, "target": 99999, "minimum": 1300, "maximum": 6500, "mode": 1]])
        let command = NativeHardwareDisplayPolicies.manualFanCommand(snapshot: snapshot, id: 0, rpm: 99999, duration: 0)
        XCTAssertEqual(command?["speeds"], [6000, 6500]); XCTAssertEqual(command?["duration"], 0)
        XCTAssertNil(NativeHardwareDisplayPolicies.manualFanCommand(snapshot: snapshot, id: 2, rpm: 2000, duration: 0))
        XCTAssertNil(NativeHardwareDisplayPolicies.manualFanCommand(snapshot: snapshot, id: 0, rpm: .nan, duration: 60))
    }
    func testTypedFanRPMRejectsOutOfRangeAndAcceptsGroupedActualReading() {
        XCTAssertEqual(NativeHardwareDisplayPolicies.typedFanRPM(" 2,500 ", minimum: 1200, maximum: 6000), 2500)
        for text in ["", "1199", "6001", "NaN", "Infinity", "noise"] { XCTAssertNil(NativeHardwareDisplayPolicies.typedFanRPM(text, minimum: 1200, maximum: 6000), text) }
    }
    func testCurveMarkerInterpolatesTheDisplayedCPUAverageAndGPUNotTheHottestCore() {
        let curve = NativeHardwareDisplayPolicies.defaultFanCurve
        for (temperature, expected) in [(30.0, 0.0), (55, 12.5), (65, 25), (72.5, 45), (90, 100), (110, 100)] {
            XCTAssertEqual(NativeHardwareDisplayPolicies.fanCurvePercent(curve, temperature: temperature), expected, accuracy: 0.0001)
        }
        XCTAssertEqual(NativeHardwareDisplayPolicies.fanCurvePercent([], temperature: 50), 100)
        XCTAssertEqual(NativeHardwareDisplayPolicies.fanCurvePercent(curve, temperature: .nan), 100)
    }
    func testFanLabelsKeepRecoveryAndThermalPressureVisible() {
        XCTAssertEqual(NativeHardwareDisplayPolicies.fanModeName("unknown"), "Recovery pending")
        XCTAssertEqual(NativeHardwareDisplayPolicies.fanModeName("external"), "External control")
        XCTAssertEqual(NativeHardwareDisplayPolicies.fanThermalLabel(fanSample()), "Thermals serious")
        XCTAssertEqual(NativeHardwareDisplayPolicies.fanThermalLabel(.null), "Telemetry unavailable")
        XCTAssertEqual(NativeHardwareDisplayPolicies.temperature(fanSample(), group: "CPU"), 65)
        XCTAssertEqual(NativeHardwareDisplayPolicies.temperature(fanSample(), group: "GPU"), 70)
    }
    func testFanMenuSharesAllDisplayMetricsAndUnitsButKeepsUnknownDistinctFromStopped() {
        var state: JSONValue = ["snapshot": fanSample(), "preferences": ["unit": "c", "menuMetric": "temperature"]]
        XCTAssertEqual(NativeHardwareDisplayPolicies.fanMenuReadings(state).title, " 65°")
        state["preferences"]["unit"] = "f"
        XCTAssertEqual(NativeHardwareDisplayPolicies.fanMenuReadings(state).temperature, "149°")
        for (metric, title) in [("rpm", " 2500"), ("both", " 149°  2500"), ("icon", "")] {
            state["preferences"]["menuMetric"] = .string(metric)
            XCTAssertEqual(NativeHardwareDisplayPolicies.fanMenuReadings(state).title, title)
        }
        XCTAssertTrue(NativeHardwareDisplayPolicies.fanMenuReadings(state).spinning)
        state["snapshot"]["fans"] = [["actual": 0]]
        XCTAssertEqual(NativeHardwareDisplayPolicies.fanMenuReadings(state).rpm, "0")
        XCTAssertFalse(NativeHardwareDisplayPolicies.fanMenuReadings(state).spinning)
        state["snapshot"] = .null
        XCTAssertEqual(NativeHardwareDisplayPolicies.fanMenuReadings(state).rpm, "—")
        XCTAssertEqual(NativeHardwareDisplayPolicies.fanMenuReadings(state).temperature, "—")
        XCTAssertFalse(NativeHardwareDisplayPolicies.fanMenuReadings(state).spinning)
    }
    func testFanReaderCanRecoverAfterEndWithoutAuthorizationOrControlWrites() async throws {
        let runtime = try runtime(), fixture = HardwareParityFanReader()
        let service = NativeFanService(runtime: runtime, io: fixture.io)
        let events = await runtime.events.stream()
        let first = expectation(description: "Initial synthetic reading")
        let stopped = expectation(description: "Ended reader publishes unavailable state")
        let recoveredFrame = expectation(description: "Replacement reader publishes synthetic reading")
        let observer = Task {
            var readings = 0
            for await event in events where event.topic == "fans.state" {
                if !event.data["snapshot"].isNull {
                    readings += 1
                    if readings == 1 { first.fulfill() } else if readings == 2 { recoveredFrame.fulfill() }
                } else if !event.data["error"].isNull { stopped.fulfill() }
            }
        }
        defer { observer.cancel(); fixture.finish() }
        try await service.start()
        fixture.send(fanSample())
        await fulfillment(of: [first], timeout: 2)
        fixture.finish()
        await fulfillment(of: [stopped], timeout: 2)
        let waiting = try await service.handle("status")
        XCTAssertTrue(waiting["snapshot"].isNull)
        XCTAssertEqual(fixture.monitorCount, 2)
        fixture.send(fanSample())
        await fulfillment(of: [recoveredFrame], timeout: 2)
        let recovered = try await service.handle("status")
        XCTAssertEqual(recovered["snapshot"]["date"], 10000); XCTAssertTrue(recovered["error"].isNull)
        XCTAssertFalse(fixture.commands.contains { $0["command"] != "status" })
    }
    func testFanHistoryEveryRangeAndCustomBoundsUsePersistedSyntheticSamples() async throws {
        let fixture = HardwareParityFanController(), service = NativeFanService(runtime: try runtime(), io: fixture.io)
        try await service.accept(fanSample())
        for range in ["30m", "1h", "6h", "24h", "7d", "30d", "90d", "1y", "all", "custom"] {
            var input: JSONObject = ["range": .string(range)]
            if range == "custom" { input["since"] = 0; input["until"] = 10000 }
            let value = try await service.handle("history", input: input)
            XCTAssertEqual(value["points"].array.count, 1, range)
            XCTAssertEqual(value["points"].array[0]["mean"]["sensors"].array.first { $0["id"] == "TCMb" }?["value"], 65, range)
            XCTAssertLessThanOrEqual(value["points"].array.count, 500)
        }
        do { _ = try await service.handle("history", input: ["range": "custom", "since": 10000, "until": 9999]); XCTFail("Reversed history admitted") } catch {}
    }
    func testInitialReaderLaunchFailureStaysRetryableWithoutFailingServiceStartup() async throws {
        let fixture = HardwareParityFanReader(failFirst: true)
        let service = NativeFanService(runtime: try runtime(), io: fixture.io)
        try await service.start()
        let retrying = try await service.handle("status")
        XCTAssertEqual(fixture.monitorCount, 2)
        XCTAssertTrue(retrying["snapshot"].isNull)
        XCTAssertTrue(retrying["error"].string.contains("Synthetic reader launch"))
        fixture.finish()
    }
    func testReadOnlyFanStartPublishesTelemetryWithoutControllerOrPersistenceAndStopCancelsReader() async throws {
        let writable = try runtime(), seed = NativeFanService(runtime: writable, io: HardwareParityFanController().io)
        try await seed.accept(fanSample())
        let original = try writable.db.query("SELECT * FROM fans_history ORDER BY timestamp")
        let readOnly = try NativeRuntime(paths: NativePaths(root: writable.paths.root, home: writable.paths.home, readOnly: true))
        let fixture = HardwareParityFanReader(daemonAvailable: true)
        let service = NativeFanService(runtime: readOnly, io: fixture.io)
        let events = await readOnly.events.stream(), received = expectation(description: "Read-only live sample")
        let observer = Task {
            for await event in events where event.topic == "fans.state" && !event.data["snapshot"].isNull { received.fulfill(); return }
        }
        defer { observer.cancel(); fixture.finish() }
        try await service.start()
        var next = fanSample(); next["sensors"] = [["id": "TCMb", "value": 72]]
        fixture.send(next)
        await fulfillment(of: [received], timeout: 2)
        await service.poll()
        let status = try await service.handle("status")
        XCTAssertEqual(status["snapshot"]["sensors"].array.first?["value"], 72)
        XCTAssertEqual(status["snapshot"]["fans"].array.first?["actual"], 2500)
        XCTAssertFalse(status["enabled"].bool)
        for operation in ["enable", "install", "control", "release", "preferences"] {
            do { _ = try await service.handle(operation, input: operation == "control" ? ["command": "cooler"] : [:]); XCTFail("Read-only mutation admitted: \(operation)") } catch {}
        }
        XCTAssertTrue(fixture.commands.isEmpty)
        XCTAssertEqual(try writable.db.query("SELECT * FROM fans_history ORDER BY timestamp"), original)
        XCTAssertEqual(try readOnly.db.query("SELECT total_changes() AS n").first?["n"], 0)
        await service.stopMonitoring()
        XCTAssertEqual(fixture.cancelledMonitors, 1)
        let stopped = try await service.handle("status")
        XCTAssertTrue(stopped["snapshot"].isNull)
        XCTAssertEqual(fixture.monitorCount, 1, "Stopped status must not relaunch the reader")
        XCTAssertTrue(fixture.commands.isEmpty)
    }
    func testFanStopWaitsForOwnedInjectedTeardownBeforeReturning() async throws {
        let fixture = HardwareParityFanReader(), teardown = HardwareParityTeardownGate()
        var io = fixture.io
        io.stopMonitor = { await teardown.stop() }
        let service = NativeFanService(runtime: try runtime(), io: io)
        try await service.start()
        let stopped = Task { await service.stopMonitoring(); await teardown.didReturn() }
        await teardown.waitUntilEntered()
        let returnedWhileHeld = await teardown.returned
        XCTAssertFalse(returnedWhileHeld)
        XCTAssertEqual(fixture.cancelledMonitors, 1)
        await teardown.release()
        await stopped.value
        let returnedAfterDrain = await teardown.returned
        XCTAssertTrue(returnedAfterDrain)
        XCTAssertTrue(fixture.commands.isEmpty)
    }
    func testKeptFanIntentReappliesFromPersistentStoreAfterServiceRestartAndAutoRetiresIt() async throws {
        let runtime = try runtime(), fixture = HardwareParityFanController()
        let original = NativeFanService(runtime: runtime, io: fixture.io)
        try await original.accept(fanSample()); await original.poll()
        _ = try await original.handle("control", input: ["command": "cooler"])
        fixture.automatic()
        let replacement = NativeFanService(runtime: runtime, io: fixture.io)
        try await replacement.accept(fanSample()); await replacement.poll(); await replacement.poll()
        XCTAssertEqual(fixture.commands.last?["command"], "cooler")
        let restored = try await replacement.handle("status")
        XCTAssertEqual(restored["keep"]["command"], "cooler")
        _ = try await replacement.handle("control", input: ["command": "automatic"])
        let cleared = try await replacement.handle("status"); XCTAssertTrue(cleared["keep"].isNull)
        let third = NativeFanService(runtime: runtime, io: fixture.io)
        try await third.accept(fanSample()); await third.poll(); await third.poll()
        XCTAssertEqual(fixture.commands.last?["command"], "status")
    }
    func testActivityPauseAndMissingCountersBreakBothHistoryPaths() {
        let segments = NativeHardwareDisplayPolicies.activityHistorySegments([(1000, 20), (3000, 30), (16001, 40), (18000, nil), (20000, 45)])
        XCTAssertEqual(segments, [0, 0, 1, 2, 2])
    }
    private func process(_ pid: Int, parent: Int = 1, path: String = "fixture/process", birth: String = "10:0", protected: JSONValue = .null, uid: Int = 501) -> JSONValue {
        ["pid": .number(Double(pid)), "ppid": .number(Double(parent)), "uid": .number(Double(uid)), "started": .string(birth), "name": "Fixture", "path": .string(path), "cpuNs": "1000000000", "memoryBytes": 100, "memoryKind": "footprint", "readBytes": 100, "writeBytes": 100, "protectedReason": protected]
    }
    private func raw(_ processes: [JSONValue], apps: [JSONValue] = [], monotonic: Double = 1) -> JSONValue {
        ["timestamp": .number(monotonic * 1000), "monotonic": .number(monotonic), "logicalCpus": 4, "totalMemory": 1000, "memoryUsed": 400, "cpuTicks": [10, 0, 90, 0], "processes": .array(processes), "apps": .array(apps), "omitted": 0]
    }
    private var app: JSONValue { ["pid": 50, "name": "Fixture app", "bundlePath": "fixture/App.app", "bundleId": "fixture.app"] }
    func testActivityGroupingRequiresUnambiguousSameUserBundleOrAncestry() throws {
        let processes = [process(50), process(51, parent: 50), process(52, path: "fixture/App.app/Contents/Helper"), process(53, path: "fixture/App.app/Contents/Other", uid: 502), process(54, path: "fixture/System/WebKit")]
        let snapshot = try NativeActivityFold.snapshot(raw(processes, apps: [app]))
        XCTAssertEqual(snapshot["groups"].array.first { $0["id"] == "app:50@10:0" }?["processes"].array.map { $0["pid"].int }, [50, 51, 52])
        XCTAssertEqual(snapshot["groups"].array.count, 3)
        var second = app; second["pid"] = 55
        let ambiguous = try NativeActivityFold.snapshot(raw(processes + [process(55)], apps: [app, second]))
        XCTAssertNotNil(ambiguous["groups"].array.first { $0["id"] == "process:52@10:0" })
    }
    func testActivityQuitTargetsAppRootForceTargetsFreshMembersAndIndividualOnlyItself() async throws {
        let fixture = HardwareParityActivityIO(raw([process(50), process(51, parent: 50)], apps: [app]))
        let service = NativeActivityService(io: fixture.io)
        _ = try await service.handle("status")
        _ = try await service.handle("terminate", input: ["id": "app:50@10:0", "mode": "quit", "process": false])
        await fixture.set(raw([process(50), process(52, parent: 50)], apps: [app], monotonic: 2))
        _ = try await service.handle("terminate", input: ["id": "app:50@10:0", "mode": "force", "process": false])
        _ = try await service.handle("terminate", input: ["id": "52@10:0", "mode": "quit", "process": true])
        let requests = await fixture.requests
        XCTAssertEqual(requests.map { $0["targets"].array.map { $0["pid"].int } }, [[50], [50, 52], [52]])
        XCTAssertEqual(requests.map { $0["application"].bool }, [true, true, false])
    }
    func testActivityProtectedMemberAndReusedBirthRefuseBeforeSignalling() async throws {
        let fixture = HardwareParityActivityIO(raw([process(50), process(51, parent: 50, protected: "Essential process")], apps: [app]))
        let service = NativeActivityService(io: fixture.io)
        do { _ = try await service.handle("terminate", input: ["id": "app:50@10:0", "mode": "force", "process": false]); XCTFail("Protected group admitted") } catch {}
        await fixture.set(raw([process(50, birth: "11:0")], apps: [app], monotonic: 2))
        do { _ = try await service.handle("terminate", input: ["id": "app:50@10:0", "mode": "force", "process": false]); XCTFail("Old app birth admitted") } catch {}
        let requests = await fixture.requests; XCTAssertTrue(requests.isEmpty)
    }
}

private actor HardwareParityGate {
    private var held: CheckedContinuation<JSONValue, Never>?
    private var ready: JSONValue?
    func wait() async -> JSONValue { if let ready { return ready }; return await withCheckedContinuation { held = $0 } }
    func release(_ value: JSONValue) { ready = value; held?.resume(returning: value); held = nil }
}
private actor HardwareParityHistoryClient {
    private var selection = NativeFanHistorySelection()
    func begin(_ scope: String) -> UUID { selection.begin(scope: scope) }
    func resolve(_ id: UUID, _ value: JSONValue) { selection.resolve(id, value: value) }
    func value(_ scope: String) -> JSONValue { selection.value(for: scope) }
}
private actor HardwareParityTeardownGate {
    private var continuation: CheckedContinuation<Void, Never>?
    private var enteredContinuation: CheckedContinuation<Void, Never>?
    private var entered = false
    private(set) var returned = false
    func stop() async {
        entered = true; enteredContinuation?.resume(); enteredContinuation = nil
        await withCheckedContinuation { continuation = $0 }
    }
    func waitUntilEntered() async { if !entered { await withCheckedContinuation { enteredContinuation = $0 } } }
    func release() { continuation?.resume(); continuation = nil }
    func didReturn() { returned = true }
}
private final class HardwareParityFanReader: @unchecked Sendable {
    private let lock = NSLock()
    private var stream: AsyncThrowingStream<JSONValue, Error>.Continuation?
    private var monitors = 0
    private var requests: [JSONValue] = []
    private let failFirst: Bool
    private let daemonAvailable: Bool
    private var cancellations = 0
    init(failFirst: Bool = false, daemonAvailable: Bool = false) { self.failFirst = failFirst; self.daemonAvailable = daemonAvailable }
    var cancelledMonitors: Int { lock.lock(); defer { lock.unlock() }; return cancellations }
    var monitorCount: Int { lock.lock(); defer { lock.unlock() }; return monitors }
    var commands: [JSONValue] { lock.lock(); defer { lock.unlock() }; return requests }
    private func monitor() throws -> AsyncThrowingStream<JSONValue, Error> {
        lock.lock(); defer { lock.unlock() }; monitors += 1
        if failFirst && monitors == 1 { throw NativeFailure("Synthetic reader launch refused") }
        return AsyncThrowingStream { continuation in
            stream = continuation
            continuation.onTermination = { [weak self] reason in
                if case .cancelled = reason { self?.cancelled() }
            }
        }
    }
    private func cancelled() { lock.lock(); defer { lock.unlock() }; cancellations += 1 }
    func send(_ value: JSONValue) { lock.lock(); defer { lock.unlock() }; stream?.yield(value) }
    func finish() { lock.lock(); defer { lock.unlock() }; stream?.finish() }
    private func request(_ command: JSONValue) -> JSONValue { lock.lock(); defer { lock.unlock() }; requests.append(command); return ["ok": true, "mode": "automatic", "message": "fixture"] }
    var io: NativeFanIO { .init(metadata: { ["supported": true, "installed": true, "daemonAvailable": .bool(self.daemonAvailable)] }, monitor: { try self.monitor() }, request: { body, _ in self.request(body) }, authorize: { _ in XCTFail("Reader recovery requested authorization") }, now: { 10000 }, sleep: { _ in throw CancellationError() }) }
}
private actor HardwareParityActivityIO {
    private var value: JSONValue
    private(set) var requests: [JSONValue] = []
    init(_ value: JSONValue) { self.value = value }
    func set(_ value: JSONValue) { self.value = value }
    func sample() -> JSONValue { value }
    func terminate(_ input: JSONValue) -> JSONValue { requests.append(input); return ["ok": true, "requested": .number(Double(input["targets"].array.count)), "gone": 0, "failed": []] }
    nonisolated var io: NativeActivityIO { .init(sample: { await self.sample() }, terminate: { await self.terminate($0) }, now: { 10000 }) }
}
private final class HardwareParityFanController: @unchecked Sendable {
    private let lock = NSLock()
    private var mode = "automatic", requests: [JSONValue] = []
    var commands: [JSONValue] { lock.lock(); defer { lock.unlock() }; return requests }
    func automatic() { lock.lock(); defer { lock.unlock() }; mode = "automatic" }
    private func request(_ input: JSONValue) -> JSONValue {
        lock.lock(); defer { lock.unlock() }; requests.append(input)
        if input["command"] != "status" { mode = input["command"].string }
        return ["ok": true, "mode": .string(mode), "message": "Synthetic controller"]
    }
    var io: NativeFanIO { .init(metadata: { ["supported": true, "installed": true, "daemonAvailable": true] }, monitor: { AsyncThrowingStream { $0.finish() } }, request: { input, _ in self.request(input) }, authorize: { _ in XCTFail("Fixture attempted authorization") }, now: { 10000 }, sleep: { _ in }) }
}
