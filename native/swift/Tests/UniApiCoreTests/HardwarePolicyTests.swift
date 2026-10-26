import XCTest
@testable import UniApiCore

final class HardwarePolicyTests: XCTestCase {
    func testFanKeptIntentDurationsAndMonotoneCurve() throws {
        let manual: JSONValue = ["command": "manual", "duration": 0, "speeds": [2000, 2100]]
        XCTAssertEqual(NativeHardwarePolicies.keptFanCommand(manual), manual)
        XCTAssertTrue(NativeHardwarePolicies.keptFanCommand(["command": "manual", "duration": 60, "speeds": [2000]]).isNull)
        XCTAssertTrue(NativeHardwarePolicies.keptFanCommand(["command": "cooler", "duration": 60]).isNull)
        XCTAssertEqual(NativeHardwarePolicies.keptFanCommand(["command": "cooler"]), ["command": "cooler"])
        XCTAssertThrowsError(try NativeHardwarePolicies.fanCommand(["command": "boost"]))
        XCTAssertThrowsError(try NativeHardwarePolicies.fanCommand(["command": "manual", "duration": 0, "speeds": [1199]]))
        let curve: JSONValue = ["command": "curve", "curve": [["temperature": 40, "percent": 0], ["temperature": 60, "percent": 30], ["temperature": 75, "percent": 60], ["temperature": 90, "percent": 100]]]
        XCTAssertEqual(try NativeHardwarePolicies.fanCommand(curve), curve)
        var bad = curve; bad["curve"] = [["temperature": 40, "percent": 0], ["temperature": 43, "percent": 30], ["temperature": 75, "percent": 60], ["temperature": 90, "percent": 100]]
        XCTAssertThrowsError(try NativeHardwarePolicies.fanCommand(bad))
    }
    func testFanLeaseStalenessAndFaultBackoff() {
        XCTAssertEqual(NativeHardwarePolicies.fanPoll(mode: "manual", ok: true, kept: true, releaseRequested: false, snapshotAge: 6001, clientAge: 0, reassertIn: 0), "automatic")
        XCTAssertEqual(NativeHardwarePolicies.fanPoll(mode: "automatic", ok: true, kept: true, releaseRequested: false, snapshotAge: 0, clientAge: 20000, reassertIn: 0), "reassert")
        XCTAssertEqual(NativeHardwarePolicies.fanPoll(mode: "manual", ok: true, kept: false, releaseRequested: false, snapshotAge: 0, clientAge: 10001, reassertIn: 0), "automatic")
        XCTAssertEqual(NativeHardwarePolicies.fanBackoff(heldMs: 20000, previous: 15000), 30000)
        XCTAssertEqual(NativeHardwarePolicies.fanBackoff(heldMs: 120000, previous: 300000), 15000)
        XCTAssertEqual(NativeHardwarePolicies.fanBackoff(heldMs: 0, previous: 300000), 300000)
    }
    func testFanMalformedReadingsAreRejected() {
        var value: JSONValue = ["date": 1, "thermal": 0, "fans": [], "sensors": [["id": "CPU", "value": 40]]]
        XCTAssertTrue(NativeHardwarePolicies.fanSnapshot(value))
        value["sensors"] = [["id": "CPU", "value": 130]]; XCTAssertFalse(NativeHardwarePolicies.fanSnapshot(value))
        value["sensors"] = []; value["thermal"] = 0.5; XCTAssertFalse(NativeHardwarePolicies.fanSnapshot(value))
    }
    func testBatteryLevelsAndFreshAcknowledgment() throws {
        let levels: [JSONValue] = [80, 85, 90, 95, 100]
        XCTAssertEqual(try NativeHardwarePolicies.batteryTarget(55, levels: levels, hold: true), 55)
        XCTAssertThrowsError(try NativeHardwarePolicies.batteryTarget(55, levels: levels, hold: false))
        XCTAssertThrowsError(try NativeHardwarePolicies.batteryTarget(80, levels: levels, hold: true))
        XCTAssertThrowsError(try NativeHardwarePolicies.batteryTarget("55", levels: levels, hold: true))
        let report: JSONValue = ["version": 2, "target": 55, "updatedAt": 10000, "state": "inhibiting", "battery": ["percent": 55, "external": true, "charging": false]]
        XCTAssertTrue(NativeHardwarePolicies.holdReport(report, target: 55, now: 10000)["healthy"].bool)
        XCTAssertFalse(NativeHardwarePolicies.holdReport(report, target: 55, now: 25001)["healthy"].bool)
        var bad = report; bad["target"] = "55"; XCTAssertFalse(NativeHardwarePolicies.holdReport(bad, target: 55, now: 10000)["healthy"].bool)
    }
    func testBatteryIdleIsNotMisrepresentedAsCharging() {
        var status: JSONValue = ["supported": true, "limit": 80, "battery": ["percent": 65, "externalConnected": true, "charging": false]]
        XCTAssertEqual(NativeHardwarePolicies.batteryPhase(status), "below-limit-idle")
        status["battery"]["charging"] = true; XCTAssertEqual(NativeHardwarePolicies.batteryPhase(status), "charging-to-limit")
        status["hold"] = ["installed": true, "active": true, "healthy": false, "target": 55]
        XCTAssertEqual(NativeHardwarePolicies.batteryPhase(status), "control-pending")
        status["hold"] = ["installed": true, "active": true, "healthy": true, "state": "inhibiting", "target": 55, "reportedBattery": ["percent": 60, "externalConnected": true, "charging": false]]
        XCTAssertEqual(NativeHardwarePolicies.batteryPhase(status), "above-limit")
    }
}

final class HardwareActivityTests: XCTestCase {
    private func process(_ pid: Int, parent: Int = 1, cpu: String = "1000000000", memory: JSONValue = 100, uid: Int = 501, name: String = "Fixture", path: String = "fixture/process", started: String = "10:0") -> JSONValue {
        ["pid": .number(Double(pid)), "ppid": .number(Double(parent)), "uid": .number(Double(uid)), "started": .string(started), "name": .string(name), "path": .string(path), "cpuNs": .string(cpu), "memoryBytes": memory, "memoryKind": memory.isNull ? "unavailable" : "footprint", "threads": 1, "readBytes": 100, "writeBytes": 100, "protectedReason": nil]
    }
    private func raw(_ time: Double, processes: [JSONValue], apps: [JSONValue] = []) -> JSONValue {
        ["timestamp": .number(time * 1000), "monotonic": .number(time), "logicalCpus": 4, "totalMemory": 1000, "cpuTicks": [20, 20, 60, 0], "memoryUsed": 500, "compressedBytes": 100, "swapUsed": 0, "pressure": "normal", "processes": .array(processes), "apps": .array(apps), "omitted": 0]
    }
    func testMachTimebaseUsesWideArithmetic() {
        XCTAssertEqual(NativeActivityFold.ticksToNanoseconds(user: 12, system: 12, numerator: 125, denominator: 3), 1000)
        XCTAssertEqual(NativeActivityFold.ticksToNanoseconds(user: UInt64.max, system: 0, numerator: 3, denominator: 3), UInt64.max)
        XCTAssertNil(NativeActivityFold.ticksToNanoseconds(user: UInt64.max, system: 1, numerator: 1, denominator: 1))
        XCTAssertNil(NativeActivityFold.ticksToNanoseconds(user: 1, system: 1, numerator: 1, denominator: 0))
    }
    func testCPUUsesAllCoresAndRejectsReusedPID() throws {
        let before = raw(1, processes: [process(50)])
        let current = raw(2, processes: [process(50, cpu: "2000000000")])
        let value = try NativeActivityFold.snapshot(current, previous: before)
        XCTAssertEqual(value["groups"].array[0]["cpuPercent"], 25)
        let reused = try NativeActivityFold.snapshot(raw(2, processes: [process(50, cpu: "9999999999", started: "11:0")]), previous: before)
        XCTAssertTrue(reused["groups"].array[0]["cpuPercent"].isNull)
        XCTAssertTrue(try NativeActivityFold.snapshot(current)["cpuPercent"].isNull)
    }
    func testAppGroupingAndPartialMeasurements() throws {
        let app: JSONValue = ["pid": 50, "name": "Fixture app", "bundlePath": "fixture/App.app", "bundleId": "fixture.app"]
        let value = try NativeActivityFold.snapshot(raw(1, processes: [process(50), process(51, parent: 50, memory: .null)], apps: [app]))
        XCTAssertEqual(value["groups"].array.count, 1)
        XCTAssertEqual(value["groups"].array[0]["processes"].array.count, 2)
        XCTAssertTrue(value["groups"].array[0]["partial"].bool)
        XCTAssertEqual(value["groups"].array[0]["memoryBytes"], 100)
    }
    func testProtectionDoesNotSignalAnyActualProcess() {
        XCTAssertNotNil(NativeActivitySystem.protection(pid: 1, uid: 501, path: "fixture", name: "Fixture", system: false, owner: 501, ancestors: []))
        XCTAssertNotNil(NativeActivitySystem.protection(pid: 50, uid: 0, path: "fixture", name: "Fixture", system: false, owner: 501, ancestors: []))
        XCTAssertNotNil(NativeActivitySystem.protection(pid: 50, uid: 501, path: "fixture", name: "Finder", system: false, owner: 501, ancestors: []))
        XCTAssertNil(NativeActivitySystem.protection(pid: 50, uid: 501, path: "fixture", name: "Fixture", system: false, owner: 501, ancestors: []))
    }
    func testServiceRefreshAndTerminationUseInjectedFixturesOnly() async throws {
        let captured = ActivityFixtureCapture(), sample = raw(1, processes: [process(50)])
        let io = NativeActivityIO(sample: { await captured.sample(sample) }, terminate: { await captured.terminate($0) }, now: { 10000 })
        let service = NativeActivityService(io: io)
        _ = try await service.handle("status"); _ = try await service.handle("status")
        let reads = await captured.reads; XCTAssertEqual(reads, 1)
        let result = try await service.handle("terminate", input: ["id": "process:50@10:0", "mode": "force", "process": false])
        XCTAssertTrue(result["ok"].bool)
        let requests = await captured.requests
        XCTAssertEqual(requests.count, 1); XCTAssertEqual(requests.first?["targets"].array.first?["pid"], 50)
        do { _ = try await service.handle("terminate", input: ["id": "process:50@11:0", "mode": "force", "process": false]); XCTFail("Reused identity admitted") } catch {}
    }
    func testReadOnlyServiceRejectsTerminationBeforeAnyDeviceOrProcessCall() async throws {
        let captured = ActivityFixtureCapture()
        let io = NativeActivityIO(sample: { await captured.sample(.null) }, terminate: { await captured.terminate($0) })
        let service = NativeActivityService(io: io, readOnly: true)
        do { _ = try await service.handle("terminate", input: ["id": "process:50@10:0", "mode": "force"]); XCTFail("Read-only termination admitted") } catch {}
        let reads = await captured.reads, requests = await captured.requests
        XCTAssertEqual(reads, 0); XCTAssertTrue(requests.isEmpty)
    }
}
private actor ActivityFixtureCapture {
    var reads = 0
    var requests: [JSONValue] = []
    func sample(_ value: JSONValue) -> JSONValue { reads += 1; return value }
    func terminate(_ value: JSONValue) -> JSONValue { requests.append(value); return ["ok": true, "requested": 1, "gone": 0, "failed": []] }
}
