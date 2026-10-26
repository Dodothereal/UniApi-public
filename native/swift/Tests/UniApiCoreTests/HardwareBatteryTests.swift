import XCTest
@testable import UniApiCore

final class HardwareBatteryTests: XCTestCase {
    private func directory() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("battery-fixture-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }; return root
    }
    func testPrivateInterfaceSignaturesFailClosedWithoutLoadingPowerUI() {
        XCTAssertTrue(NativePowerUIClient.supportedEncoding(returnType: "C", arguments: ["^@"], expected: ["C", "^@"]))
        XCTAssertFalse(NativePowerUIClient.supportedEncoding(returnType: "B", arguments: ["^@"], expected: ["Q", "^@"]))
        XCTAssertFalse(NativePowerUIClient.supportedEncoding(returnType: "Q", arguments: ["^B"], expected: ["Q", "^@"]))
    }
    func testBatteryMissingGaugeDoesNotInventCharge() {
        XCTAssertTrue(NativeBatterySystem.snapshot(["IsCharging": false] as NSDictionary).isNull)
        XCTAssertTrue(NativeBatterySystem.snapshot(["CurrentCapacity": 5000, "ExternalConnected": true, "IsCharging": false] as NSDictionary).isNull)
        let value = NativeBatterySystem.snapshot(["CurrentCapacity": 5000, "AppleRawCurrentCapacity": 5000, "AppleRawMaxCapacity": 10000, "ExternalConnected": true, "IsCharging": false] as NSDictionary)
        XCTAssertEqual(value["percent"], 50)
    }
    func testElectricalDiagnosticsAllowlistPreservesSignedDischargeAndExcludesIdentity() {
        let value = NativeBatterySystem.snapshot(["CurrentCapacity": 55, "ExternalConnected": true, "IsCharging": false, "Amperage": NSNumber(value: Int64(-123)), "Serial": "private", "AdapterDetails": ["Watts": 96, "SerialNumber": "private"]] as NSDictionary)
        XCTAssertEqual(value["telemetry"]["Amperage"], -123)
        XCTAssertTrue(value["telemetry"]["Serial"].isNull)
        XCTAssertEqual(value["telemetry"]["AdapterDetails"]["Watts"], 96)
        XCTAssertTrue(value["telemetry"]["AdapterDetails"]["SerialNumber"].isNull)
    }
    func testRollingDiagnosticsBoundArchivesAndRejectLinksBeforeMovingFiles() throws {
        let root = try directory(), log = NativeBatteryLog(directory: root, maximum: 512, files: 3)
        for index in 0..<30 { XCTAssertTrue(log.write("sample", data: ["index": .number(Double(index)), "amperage": -123])) }
        let names = try FileManager.default.contentsOfDirectory(atPath: root.path)
        XCTAssertLessThanOrEqual(names.count, 3)
        for name in names {
            let file = root.appendingPathComponent(name), info = try FileManager.default.attributesOfItem(atPath: file.path)
            XCTAssertEqual((info[.posixPermissions] as? NSNumber)?.intValue, 0o600)
            for row in try Data(contentsOf: file).split(separator: 10) { XCTAssertEqual(try JSONValue.decode(Data(row))["schema"], 1) }
        }
        let archive = root.appendingPathComponent("battery.jsonl.2"), outside = root.appendingPathComponent("outside")
        try? FileManager.default.removeItem(at: archive); try Data("untouched".utf8).write(to: outside)
        try FileManager.default.createSymbolicLink(at: archive, withDestinationURL: outside)
        var rejected = false
        for _ in 0..<5 { if !log.write("sample", data: ["large": .string(String(repeating: "x", count: 500))]) { rejected = true; break } }
        XCTAssertTrue(rejected)
        XCTAssertEqual(try Data(contentsOf: outside), Data("untouched".utf8))
    }
    func testDiagnosticAncestryRejectsRedirectedParentBeforeCreation() throws {
        let root = try directory(), outside = root.appendingPathComponent("outside"), link = root.appendingPathComponent("linked")
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: false)
        try Data("untouched".utf8).write(to: outside.appendingPathComponent("sentinel"))
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outside)
        XCTAssertFalse(NativeBatteryLog(directory: link.appendingPathComponent("battery")).write("sample"))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: outside.path), ["sentinel"])
        let log = NativeBatteryLog(directory: root.appendingPathComponent("owned/battery"))
        XCTAssertTrue(log.write("sample"))
    }
    func testOneLargeRecordCannotExceedAnEmptyDestinationBudget() throws {
        let root = try directory(), log = NativeBatteryLog(directory: root, maximum: 256)
        XCTAssertTrue(log.write("sample", data: ["large": .string(String(repeating: "x", count: 4096))]))
        let data = try Data(contentsOf: root.appendingPathComponent("battery.jsonl"))
        XCTAssertLessThanOrEqual(data.count, 256)
        XCTAssertTrue(try JSONValue.decode(data)["data"]["truncated"].bool)
    }
    func testUnrecognizedCommandFieldsNeverEnterDiagnostics() async throws {
        let root = try directory(), runtime = try NativeRuntime(paths: NativePaths(root: root, home: root))
        let fixture = BatteryServiceFixture(), service = NativeBatteryService(runtime: runtime, io: fixture.io)
        _ = try await service.handle("status")
        do { _ = try await service.handle("limit", input: ["limit": 90, "secret": "private-fixture-value"]); XCTFail("Unknown command field admitted") } catch {}
        let log = try String(contentsOf: runtime.paths.logs.appendingPathComponent("battery/battery.jsonl"), encoding: .utf8)
        XCTAssertFalse(log.contains("private-fixture-value"))
        XCTAssertFalse(fixture.commands.contains("set"))
    }
    func testDelayedPolicyRetainsTheGenerationThatStartedIt() async throws {
        let root = try directory(), runtime = try NativeRuntime(paths: NativePaths(root: root, home: root)), gate = BatteryPolicyGate()
        let fixture = BatteryServiceFixture(); fixture.policy = { await gate.wait(); return ["output": "fixture policy"] }
        let service = NativeBatteryService(runtime: runtime, io: fixture.io)
        _ = try await service.handle("status")
        for _ in 0..<100 { if await gate.entered { break }; try await Task.sleep(nanoseconds: 1_000_000) }
        _ = try await service.handle("limit", input: ["limit": 90])
        await gate.release()
        var policy: JSONValue = .null
        let file = runtime.paths.logs.appendingPathComponent("battery/battery.jsonl")
        for _ in 0..<100 {
            let records = try Data(contentsOf: file).split(separator: 10).compactMap { try? JSONValue.decode(Data($0)) }
            if let row = records.last(where: { $0["event"] == "native.policy" }) { policy = row; break }
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        XCTAssertEqual(policy["data"]["generation"], 0)
        XCTAssertEqual(policy["data"]["details"]["output"], "fixture policy")
    }
    func testPreferencesJournalPrecedesWritesAndRestoresOriginals() throws {
        let root = try directory(), fixture = BatteryPreferenceFixture()
        let journal = root.appendingPathComponent("preferences.plist")
        fixture.beforeWrite = { XCTAssertTrue(FileManager.default.fileExists(atPath: journal.path)) }
        let store = NativeBatteryPreferences(directory: root, io: fixture.io)
        try store.apply(55)
        XCTAssertEqual(fixture.value("mclLimitValue"), 55)
        XCTAssertEqual(fixture.native, 55)
        let attributes = try FileManager.default.attributesOfItem(atPath: journal.path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        try store.apply(0)
        XCTAssertEqual(fixture.value("mclLimitValue"), 80)
        XCTAssertEqual(fixture.value("MCLFeatureState"), 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: journal.path))
    }
    func testCompatibleChargingHandoffPreservesJournalAndNeverMutatesPreferences() throws {
        let root = try directory(), fixture = BatteryPreferenceFixture()
        let store = NativeBatteryPreferences(directory: root, io: fixture.io)
        try store.apply(50)
        let journal = root.appendingPathComponent("preferences.plist")
        let before = try Data(contentsOf: journal)
        fixture.beforeWrite = { XCTFail("Handoff admission attempted a preference write") }
        let report = try store.validateHandoff(target: 50)
        XCTAssertTrue(report["compatible"].bool); XCTAssertEqual(report["target"], 50)
        XCTAssertEqual(try Data(contentsOf: journal), before)
        XCTAssertEqual(fixture.native, 50)
        XCTAssertThrowsError(try store.validateHandoff(target: 0))
        XCTAssertThrowsError(try store.validateHandoff(target: 55))
        fixture.native = 80
        XCTAssertThrowsError(try store.validateHandoff(target: 50))
        fixture.native = 50; fixture.set("mclLimitValue", 60)
        XCTAssertThrowsError(try store.validateHandoff(target: 50))
        XCTAssertEqual(try Data(contentsOf: journal), before)
        XCTAssertEqual(fixture.value("mclLimitValue"), 60)
    }
    func testOffHandoffRequiresNoRecoveryJournalAndStrictTargetGrammar() throws {
        let root = try directory(), fixture = BatteryPreferenceFixture()
        fixture.beforeWrite = { XCTFail("Off handoff attempted a preference write") }
        let store = NativeBatteryPreferences(directory: root, io: fixture.io)
        XCTAssertFalse(try store.validateHandoff(target: 0)["journal"].bool)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("preferences.plist").path))
        for value in ["off", "off\n", "off\r\n"] { XCTAssertEqual(try NativeBatteryUpgrade.target(Data(value.utf8)), 0) }
        XCTAssertEqual(try NativeBatteryUpgrade.target(Data("50\n".utf8)), 50)
        for value in ["", "100", "24", "96", "50\0", "off junk", " off", "50 ", "-1"] {
            XCTAssertThrowsError(try NativeBatteryUpgrade.target(Data(value.utf8)), value)
        }
    }
    func testDaemonHeartbeatIdentifiesItsStartupExecutableForUpgradeConfirmation() throws {
        let fixture = BatteryDaemonFixture()
        fixture.native = 55
        let identity = String(repeating: "a", count: 64)
        let daemon = NativeBatteryDaemon(io: fixture.io, binaryIdentity: identity)
        let report = try daemon.tick()
        XCTAssertEqual(report["runtime"], "swift")
        XCTAssertEqual(report["binarySHA256"], .string(identity))
        XCTAssertEqual(report["target"], 55)
        XCTAssertEqual(report["nativeLimit"], 55)
        XCTAssertEqual(fixture.applied, [55])
    }
    func testExternalEditAndDelayedAcknowledgmentRetainJournal() throws {
        let root = try directory(), fixture = BatteryPreferenceFixture()
        let store = NativeBatteryPreferences(directory: root, io: fixture.io)
        try store.apply(55); fixture.set("mclLimitValue", 60)
        XCTAssertThrowsError(try store.apply(0))
        XCTAssertEqual(fixture.value("mclLimitValue"), 60)
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("preferences.plist").path))
        fixture.set("mclLimitValue", 55); fixture.delay = true
        XCTAssertThrowsError(try store.apply(0)); XCTAssertTrue(store.pending)
        fixture.delay = false; try store.apply(0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("preferences.plist").path))
    }
    func testUnsafeJournalFailsBeforePreferenceMutation() throws {
        let root = try directory(), fixture = BatteryPreferenceFixture()
        try Data("not a plist".utf8).write(to: root.appendingPathComponent("preferences.plist"))
        let store = NativeBatteryPreferences(directory: root, io: fixture.io)
        XCTAssertThrowsError(try store.apply(55))
        XCTAssertEqual(fixture.value("mclLimitValue"), 80)
    }
    func testLinkedJournalCannotRedirectPrivilegedPreferenceRestoration() throws {
        let root = try directory(), fixture = BatteryPreferenceFixture()
        let outside = root.appendingPathComponent("original.plist")
        try Data("untouched".utf8).write(to: outside)
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("preferences.plist"), withDestinationURL: outside)
        let store = NativeBatteryPreferences(directory: root, io: fixture.io)
        XCTAssertThrowsError(try store.apply(55))
        XCTAssertEqual(try Data(contentsOf: outside), Data("untouched".utf8))
        XCTAssertEqual(fixture.value("mclLimitValue"), 80)
    }
    func testTargetGrammarAndDaemonReportsRequireIndependentReadback() throws {
        for value in ["", "24", "96", "55.0", " 55", "55\0", "off\n", "55junk"] { XCTAssertEqual(NativeBatteryDaemonPolicy.target(Data(value.utf8)), 0) }
        XCTAssertEqual(NativeBatteryDaemonPolicy.target(Data("55\r\n".utf8)), 55)
        let fixture = BatteryDaemonFixture()
        let daemon = NativeBatteryDaemon(io: fixture.io)
        let waiting = try daemon.tick(); XCTAssertEqual(waiting["state"], "pending")
        fixture.native = 55; fixture.battery["percent"] = 60
        let inhibiting = try daemon.tick(); XCTAssertEqual(inhibiting["state"], "inhibiting")
        fixture.battery["externalConnected"] = false
        XCTAssertEqual(try daemon.tick()["state"], "on-battery")
        fixture.target = Data("off\n".utf8)
        XCTAssertEqual(try daemon.tick()["state"], "off")
        XCTAssertEqual(fixture.applied.last, 0)
    }
    func testServiceRequestsDoNotClaimHoldingUntilAcknowledged() async throws {
        let root = try directory(), runtime = try NativeRuntime(paths: NativePaths(root: root, home: root.appendingPathComponent("home")))
        let fixture = BatteryServiceFixture()
        let service = NativeBatteryService(runtime: runtime, io: fixture.io)
        _ = try await service.handle("status")
        let requested = try await service.handle("hold", input: ["target": 55])
        XCTAssertEqual(requested["phase"], "control-pending")
        fixture.acknowledge(state: "inhibiting", percent: 55)
        let held = try await service.handle("status")
        XCTAssertEqual(held["phase"], "holding-low")
        fixture.acknowledge(state: "charging", percent: 40, charging: false)
        let idle = try await service.handle("status")
        XCTAssertEqual(idle["phase"], "below-limit-idle")
        _ = try await service.handle("off")
        XCTAssertEqual(fixture.target, 0)
        XCTAssertEqual(fixture.commands.last, "state")
        XCTAssertTrue(fixture.commands.contains("off"))
    }
    func testAcceptedNativeSetterWithOldReadbackDoesNotReportSuccess() async throws {
        let root = try directory(), runtime = try NativeRuntime(paths: NativePaths(root: root, home: root))
        let fixture = BatteryServiceFixture(); fixture.refuseNativeChange = true
        let service = NativeBatteryService(runtime: runtime, io: fixture.io)
        _ = try await service.handle("status")
        do { _ = try await service.handle("limit", input: ["limit": 90]); XCTFail("Old readback reported a successful change") }
        catch { XCTAssertTrue(error.localizedDescription.contains("acknowledged")) }
        let status = try await service.handle("status")
        XCTAssertEqual(status["limit"], 80); XCTAssertFalse(status["busy"].bool)
    }
    func testNativeSetterWaitsForIndependentDelayedReadback() async throws {
        let root = try directory(), runtime = try NativeRuntime(paths: NativePaths(root: root, home: root))
        let fixture = BatteryServiceFixture(); fixture.delayedReads = 3
        let service = NativeBatteryService(runtime: runtime, io: fixture.io)
        _ = try await service.handle("status")
        let result = try await service.handle("limit", input: ["limit": 90])
        XCTAssertEqual(result["limit"], 90)
        XCTAssertEqual(fixture.commands.filter { $0 == "set" }.count, 1)
        XCTAssertGreaterThanOrEqual(fixture.commands.filter { $0 == "state" }.count, 4)
    }
    func testAcknowledgmentDeadlineIncludesReadLatency() async throws {
        let root = try directory(), runtime = try NativeRuntime(paths: NativePaths(root: root, home: root))
        let fixture = BatteryServiceFixture(); fixture.delayedReads = 3; fixture.readLatency = 6
        let service = NativeBatteryService(runtime: runtime, io: fixture.io)
        _ = try await service.handle("status")
        do { _ = try await service.handle("limit", input: ["limit": 90]); XCTFail("Late acknowledgment escaped the deadline") }
        catch { XCTAssertTrue(error.localizedDescription.contains("deadline")) }
        XCTAssertLessThan(fixture.commands.filter { $0 == "state" }.count, 5)
    }
}

private final class BatteryPreferenceFixture: @unchecked Sendable {
    private let lock = NSRecursiveLock()
    private var values: JSONObject = ["mclLimitValue": 80, "MCLFeatureState": 1]
    var beforeWrite: (() -> Void)?
    var native = 80
    var delay = false
    func value(_ key: String) -> JSONValue { lock.lock(); defer { lock.unlock() }; return values[key] ?? .null }
    func set(_ key: String, _ value: JSONValue) { lock.lock(); defer { lock.unlock() }; values[key] = value }
    var io: NativeBatteryPreferenceIO {
        .init(read: { key, u, h in u == "current" && h == "any" ? self.value(key) : .null }, write: { key, _, _, value in self.beforeWrite?(); self.set(key, value) }, synchronize: { _, _ in }, notify: { if !self.delay { self.native = self.value("mclLimitValue").int } }, nativeLimit: { self.native })
    }
}
private final class BatteryDaemonFixture: @unchecked Sendable {
    var target = Data("55\n".utf8)
    var native = 80
    var battery: JSONValue = ["present": true, "percent": 40, "externalConnected": true, "charging": true]
    var applied: [Int] = []
    var reports: [JSONValue] = []
    var io: NativeBatteryDaemonIO { .init(target: { self.target }, apply: { self.applied.append($0) }, pending: { false }, nativeLimit: { self.native }, battery: { self.battery }, report: { self.reports.append($0) }, now: { 10000 }) }
}
private final class BatteryServiceFixture: @unchecked Sendable {
    private let lock = NSRecursiveLock()
    var target = 0
    var report: JSONValue = ["version": 2, "target": 0, "updatedAt": 10000, "state": "off"]
    var commands: [String] = []
    var nativeLimit = 80, delayedReads = 0
    var ticks: Double = 0, readLatency: Double = 0
    var policy: @Sendable () async throws -> JSONValue = { .null }
    var refuseNativeChange = false
    private var pendingNative: Int?
    var io: NativeBatteryIO {
        .init(call: { command, value in
            self.lock.lock(); defer { self.lock.unlock() }; self.commands.append(command)
            if command == "state" { self.ticks += self.readLatency }
            if ["set", "off", "enable"].contains(command), !self.refuseNativeChange {
                let target = command == "off" ? 100 : command == "enable" ? 80 : value!
                if self.delayedReads > 0 { self.pendingNative = target } else { self.nativeLimit = target }
            } else if command == "state", let pending = self.pendingNative {
                self.delayedReads -= 1
                if self.delayedReads <= 0 { self.nativeLimit = pending; self.pendingNative = nil }
            }
            return ["ok": true, "supported": true, "levels": [80, 85, 90, 95, 100], "limit": .number(Double(self.nativeLimit)), "engaged": .bool(self.nativeLimit < 100), "battery": ["present": true, "percent": 40, "externalConnected": true, "charging": false]]
        }, hold: { self.lock.lock(); defer { self.lock.unlock() }; return (true, Data((self.target == 0 ? "off\n" : "\(self.target)\n").utf8), self.report) }, writeTarget: { value in self.lock.lock(); defer { self.lock.unlock() }; self.target = value; if value == 0 { self.report = ["version": 2, "target": 0, "updatedAt": 10000, "state": "off"] } }, install: {}, now: { 10000 }, sleep: { self.advance($0) }, policy: { try await self.policy() }, monotonic: { self.time() })
    }
    private func advance(_ seconds: Double) { lock.lock(); defer { lock.unlock() }; ticks += seconds }
    private func time() -> Double { lock.lock(); defer { lock.unlock() }; return ticks }
    func acknowledge(state: String, percent: Int, charging: Bool = false) { lock.lock(); defer { lock.unlock() }; report = ["version": 2, "target": .number(Double(target)), "updatedAt": 10000, "state": .string(state), "battery": ["percent": .number(Double(percent)), "external": true, "charging": .bool(charging)]] }
}

private actor BatteryPolicyGate {
    private var continuation: CheckedContinuation<Void, Never>?
    var entered = false
    func wait() async { await withCheckedContinuation { entered = true; continuation = $0 } }
    func release() { continuation?.resume(); continuation = nil }
}
