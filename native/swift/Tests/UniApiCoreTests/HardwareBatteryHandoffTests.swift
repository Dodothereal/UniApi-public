import XCTest
import Darwin
@testable import UniApiCore

final class HardwareBatteryHandoffTests: XCTestCase {
    private let binary = "/Library/PrivilegedHelperTools/uniapi-battery"
    private let target = "/Library/Application Support/UniApi Battery/target"
    private let label = "app.devved.uniapi-battery"
    private let expectedSHA = String(repeating: "a", count: 64)
    private let birth: UInt64 = 1_700_000_000_000_123
    private var identity: NativeBatteryHandoffProcessIdentity { .init(pid: 4321, uid: 0, birthMicros: birth, executable: binary) }
    private var report: JSONValue {
        ["version": 2, "pid": 4321, "updatedAt": .number(Double((birth + 999) / 1000)), "target": 50,
         "state": "inhibiting", "nativeLimit": 50, "runtime": "swift", "binarySHA256": .string(expectedSHA),
         "processStartedAtMicros": .number(Double(birth)), "instanceID": "11111111-2222-3333-4444-555555555555"]
    }
    private func accept(_ value: JSONValue, process: NativeBatteryHandoffProcessIdentity? = nil, minimum: UInt64? = nil, expected: Int = 50, legacy: Bool = false) throws {
        try NativeBatteryHandoff.report(value, identity: process ?? identity, minimumBirth: minimum ?? birth - 1, hash: expectedSHA, target: expected, legacy: legacy, nowMicros: birth + 2_000_000)
    }
    private func job(pid: String = "pid = 4321") -> String {
        """
        system/\(label) = {
            program = \(binary)
            arguments = {
                \(binary)
                daemon
                \(target)
            }
            \(pid)
            environment = {
                FIXTURE_PRIVATE = never-returned
            }
        }
        """
    }
    private func arguments(_ values: [String], count: Int32? = nil) -> Data {
        var n = count ?? Int32(values.count)
        var data = withUnsafeBytes(of: &n) { Data($0) }
        data.append(Data((binary + "\0\0").utf8))
        for value in values { data.append(Data((value + "\0").utf8)) }
        data.append(Data("FIXTURE_PRIVATE=never-returned\0".utf8))
        return data
    }
    func testPriorFilesRequireRootProtectedSingletonNoACLAndBounds() throws {
        for role in [NativeBatteryHandoffFileRole.executable, .plist, .journal, .report] {
            let good = NativeBatteryHandoffFileMetadata(regular: true, links: 1, owner: 0, mode: 0o700, size: 10, hasACL: false)
            try role.validate(good)
            var value = good; value.owner = 503; XCTAssertThrowsError(try role.validate(value))
            value = good; value.mode = 0o777; XCTAssertThrowsError(try role.validate(value))
            value = good; value.hasACL = true; XCTAssertThrowsError(try role.validate(value))
            value = good; value.links = 2; XCTAssertThrowsError(try role.validate(value))
            value = good; value.regular = false; XCTAssertThrowsError(try role.validate(value))
            value = good; value.size = role.limit + 1; XCTAssertThrowsError(try role.validate(value))
            value = good; value.size = 0; XCTAssertThrowsError(try role.validate(value))
        }
        let ownerFile = NativeBatteryHandoffFileMetadata(regular: true, links: 1, owner: 503, mode: 0o600, size: 3, hasACL: false)
        try NativeBatteryHandoffFileRole.target(503).validate(ownerFile)
        XCTAssertThrowsError(try NativeBatteryHandoffFileRole.target(504).validate(ownerFile))
        var readable = ownerFile; readable.mode = 0o644
        XCTAssertThrowsError(try NativeBatteryHandoffFileRole.target(503).validate(readable))
        readable.owner = 0
        XCTAssertThrowsError(try NativeBatteryHandoffFileRole.journal.validate(readable))
        var noExecute = readable; noExecute.mode = 0o600
        XCTAssertThrowsError(try NativeBatteryHandoffFileRole.executable.validate(noExecute))
        try NativeBatteryHandoffFileRole.plist.validate(readable)
    }
    func testOnDiskDefinitionRequiresExactOwnedProgramAndNoPrivilegeOverrides() throws {
        let value: JSONValue = ["Label": .string(label), "ProgramArguments": .array([binary, "daemon", target].map(JSONValue.string)), "KeepAlive": true, "RunAtLoad": true, "ProcessType": "Background"]
        try NativeBatteryHandoff.validatePlist(value, binary: binary, target: target, label: label)
        for (key, invalid) in [("UserName", JSONValue.string("other")), ("EnvironmentVariables", ["PRIVATE": "fixture"]), ("Program", "/wrong"), ("KeepAlive", false), ("ProgramArguments", .array([binary, "daemon", "/wrong"].map(JSONValue.string)))] {
            var changed = value; changed[key] = invalid
            XCTAssertThrowsError(try NativeBatteryHandoff.validatePlist(changed, binary: binary, target: target, label: label), key)
        }
    }
    func testLoadedDefinitionMustMatchDiskDefinitionBeforePIDCanBeUsed() throws {
        XCTAssertEqual(try NativeBatteryHandoff.loadedPID(job(), binary: binary, target: target, label: label), 4321)
        XCTAssertEqual(try NativeBatteryHandoff.loadedPID(job(pid: ""), binary: binary, target: target, label: label), 0)
        for invalid in [job().replacingOccurrences(of: "program = \(binary)", with: "program = /wrong"), job().replacingOccurrences(of: target, with: "/wrong"), job().replacingOccurrences(of: label, with: "other"), job(pid: "pid = 4321\npid = 4322"), job(pid: "pid = 0"), job() + "}"] {
            XCTAssertThrowsError(try NativeBatteryHandoff.loadedPID(invalid, binary: binary, target: target, label: label))
        }
        XCTAssertThrowsError(try NativeBatteryHandoff.loadedPID(job().replacingOccurrences(of: "arguments = {", with: "unknown = {"), binary: binary, target: target, label: label))
    }
    func testKernelArgvIsExactAndNeverReturnsEnvironmentOrAcceptsEmptyArgvSlide() throws {
        let expected = [binary, "daemon", target]
        try NativeBatteryHandoffProcess.validateArguments(arguments(expected), expected: expected)
        for values in [["", "daemon", target], [binary, "daemon", "/wrong"], [binary, "daemon", target, "extra"], ["", "2"]] {
            XCTAssertThrowsError(try NativeBatteryHandoffProcess.validateArguments(arguments(values), expected: expected))
        }
        XCTAssertThrowsError(try NativeBatteryHandoffProcess.validateArguments(arguments(expected, count: 4), expected: expected))
        XCTAssertThrowsError(try NativeBatteryHandoffProcess.validateArguments(Data([3, 0, 0, 0, 1]), expected: expected))
    }
    func testSwiftReportRequiresRootFreshBirthExactSHAAndStartupMetadata() throws {
        try accept(report)
        for (key, invalid) in [("binarySHA256", JSONValue.string(String(repeating: "b", count: 64))), ("runtime", "other"), ("pid", 4322), ("processStartedAtMicros", .number(Double(birth - 1))), ("instanceID", "not-a-uuid"), ("error", "write failed"), ("target", 55), ("nativeLimit", 80), ("state", "pending"), ("updatedAt", .number(Double((birth - 1) / 1000)))] {
            var changed = report; changed[key] = invalid; XCTAssertThrowsError(try accept(changed), key)
        }
        XCTAssertThrowsError(try accept(report, minimum: birth + 1))
        XCTAssertThrowsError(try accept(report, process: .init(pid: 4321, uid: 503, birthMicros: birth, executable: binary)))
        XCTAssertThrowsError(try accept(report, process: .init(pid: 4321, uid: 0, birthMicros: birth - 10, executable: binary), minimum: birth))
    }
    func testLegacyRecoveryRequiresNewKernelBirthAndNextWholeSecondReport() throws {
        var value = report
        for key in ["runtime", "binarySHA256", "instanceID", "processStartedAtMicros"] { value[key] = .null }
        value["updatedAt"] = .number(Double((birth + 999_999) / 1_000_000 * 1000))
        try accept(value, legacy: true)
        value["updatedAt"] = .number(Double(birth / 1_000_000 * 1000))
        XCTAssertThrowsError(try accept(value, legacy: true))
        value["updatedAt"] = .number(Double((birth + 999_999) / 1_000_000 * 1000))
        XCTAssertThrowsError(try accept(value, minimum: birth + 1, legacy: true))
        // Swift rollback still proves its executable; legacy mode does not weaken it.
        var swift = report; swift["binarySHA256"] = "wrong"
        XCTAssertThrowsError(try accept(swift, legacy: true))
    }
    func testReportRejectsCoercionsFutureTimesAndIncompleteOffPolicy() throws {
        for (key, invalid) in [("pid", JSONValue.string("4321")), ("version", true), ("nativeLimit", .number(50.5)), ("updatedAt", .number(Double((birth + 9_000_000) / 1000)))] {
            var changed = report; changed[key] = invalid; XCTAssertThrowsError(try accept(changed), key)
        }
        XCTAssertThrowsError(try accept(report, expected: -1))
        var off = report; off["target"] = 0; off["state"] = "off"; off["nativeLimit"] = 0
        try accept(off, expected: 0)
        off["state"] = "pending"; XCTAssertThrowsError(try accept(off, expected: 0))
    }
    private func fixture() throws -> (URL, HandoffPreferenceFixture, NativeBatteryPreferences) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("charging-adoption-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let io = HandoffPreferenceFixture(), store = NativeBatteryPreferences(directory: root, io: io.preferenceIO)
        return (root, io, store)
    }
    func testFailedAdoptionReportPreservesOriginalJournalInodeBytesAndNativePolicy() throws {
        let (root, fixture, store) = try fixture(); try store.apply(50)
        let journal = root.appendingPathComponent("preferences.plist"), bytes = try Data(contentsOf: journal)
        let inode = try FileManager.default.attributesOfItem(atPath: journal.path)[.systemFileNumber] as? NSNumber
        XCTAssertEqual(try store.existingTarget(), 50)
        fixture.failReport = true; fixture.applied.removeAll(); fixture.preferenceWrites = 0
        let daemon = NativeBatteryDaemon(io: fixture.daemonIO(store), binaryIdentity: expectedSHA, processStartedAtMicros: birth, adoptingExistingPolicy: true)
        XCTAssertThrowsError(try daemon.tick())
        XCTAssertEqual(fixture.applied, [50]); XCTAssertEqual(fixture.native, 50); XCTAssertEqual(fixture.preferenceWrites, 0)
        XCTAssertEqual(try Data(contentsOf: journal), bytes)
        XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: journal.path)[.systemFileNumber] as? NSNumber, inode)
        _ = try store.validateHandoff(target: 50)
    }
    func testUnreadableTargetCannotRetireAdoptedPolicyBeforeFailedFirstReport() throws {
        for (adopting, marker) in [(true, false), (false, true), (true, true)] {
            let (root, fixture, store) = try fixture(); try store.apply(50)
            let journal = root.appendingPathComponent("preferences.plist"), bytes = try Data(contentsOf: journal)
            let inode = try FileManager.default.attributesOfItem(atPath: journal.path)[.systemFileNumber] as? NSNumber
            fixture.targetFails = true; fixture.failReport = true; fixture.marker = marker
            fixture.applied.removeAll(); fixture.preferenceWrites = 0
            let daemon = NativeBatteryDaemon(io: fixture.daemonIO(store), adoptingExistingPolicy: adopting, handoffInProgress: { fixture.marker })
            XCTAssertThrowsError(try daemon.tick())
            XCTAssertEqual(fixture.applied, []); XCTAssertEqual(fixture.preferenceWrites, 0); XCTAssertEqual(fixture.reportAttempts, 0)
            XCTAssertEqual(fixture.native, 50); XCTAssertEqual(try Data(contentsOf: journal), bytes)
            XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: journal.path)[.systemFileNumber] as? NSNumber, inode)
        }
    }
    func testInvalidTargetIsNotOffAndLeavesJournalUntouchedEvenWhenReportWouldSucceed() throws {
        for text in ["", "0", "bad", "24", "96", "50\0", "off junk", "50 "] {
            let (root, fixture, store) = try fixture(); try store.apply(50)
            let journal = root.appendingPathComponent("preferences.plist"), bytes = try Data(contentsOf: journal)
            fixture.targetBytes = Data(text.utf8); fixture.applied.removeAll(); fixture.preferenceWrites = 0
            let daemon = NativeBatteryDaemon(io: fixture.daemonIO(store), adoptingExistingPolicy: true, handoffInProgress: { true })
            XCTAssertThrowsError(try daemon.tick(), text)
            XCTAssertEqual(fixture.applied, [], text); XCTAssertEqual(fixture.preferenceWrites, 0, text)
            XCTAssertEqual(fixture.reportAttempts, 0, text); XCTAssertEqual(fixture.native, 50, text)
            XCTAssertEqual(try Data(contentsOf: journal), bytes, text)
        }
    }
    func testExplicitOffTargetStillRestoresAdoptedPolicyDuringUpgrade() throws {
        let (root, fixture, store) = try fixture(); try store.apply(50)
        fixture.targetBytes = Data("off\n".utf8); fixture.applied.removeAll()
        let daemon = NativeBatteryDaemon(io: fixture.daemonIO(store), adoptingExistingPolicy: true, handoffInProgress: { true })
        let report = try daemon.tick()
        XCTAssertEqual(report["state"], "off"); XCTAssertEqual(fixture.applied, [0]); XCTAssertEqual(fixture.native, 80)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("preferences.plist").path))
    }
    func testTransactionReportFailureAfterFirstReadinessStillPreservesAdoptedPolicy() throws {
        let (root, fixture, store) = try fixture(); try store.apply(50)
        let journal = root.appendingPathComponent("preferences.plist"), bytes = try Data(contentsOf: journal)
        fixture.marker = true
        let daemon = NativeBatteryDaemon(io: fixture.daemonIO(store), binaryIdentity: expectedSHA, processStartedAtMicros: birth, adoptingExistingPolicy: true, handoffInProgress: { fixture.marker })
        let first = try daemon.tick(); XCTAssertEqual(first["processStartedAtMicros"], .number(Double(birth)))
        fixture.failReport = true
        XCTAssertThrowsError(try daemon.tick()); XCTAssertEqual(fixture.native, 50); XCTAssertEqual(try Data(contentsOf: journal), bytes)
        fixture.marker = false
        XCTAssertThrowsError(try daemon.tick()); XCTAssertEqual(fixture.native, 80)
        XCTAssertFalse(FileManager.default.fileExists(atPath: journal.path))
    }
    func testPendingFirstReportDoesNotAcquireAdoptedLeaseBeforeNativeReadback() throws {
        let (root, fixture, store) = try fixture(); try store.apply(50)
        let journal = root.appendingPathComponent("preferences.plist"), bytes = try Data(contentsOf: journal)
        fixture.native = 80; fixture.delayAcknowledgement = true
        fixture.applied.removeAll(); fixture.preferenceWrites = 0
        let daemon = NativeBatteryDaemon(io: fixture.daemonIO(store), adoptingExistingPolicy: true)
        XCTAssertEqual(try daemon.tick()["state"], "pending")
        fixture.failReport = true
        XCTAssertThrowsError(try daemon.tick())
        XCTAssertEqual(fixture.applied, [50, 50]); XCTAssertEqual(fixture.preferenceWrites, 0)
        XCTAssertEqual(fixture.values["mclLimitValue"], 50); XCTAssertEqual(try Data(contentsOf: journal), bytes)
        fixture.native = 50; fixture.failReport = false
        XCTAssertEqual(try daemon.tick()["state"], "inhibiting")
        fixture.failReport = true; fixture.delayAcknowledgement = false
        XCTAssertThrowsError(try daemon.tick()); XCTAssertEqual(fixture.native, 80)
        XCTAssertFalse(FileManager.default.fileExists(atPath: journal.path))
    }
    func testFreshStandaloneReportFailureRetainsOriginalRestorationBehavior() throws {
        let (root, fixture, store) = try fixture()
        fixture.failReport = true
        let daemon = NativeBatteryDaemon(io: fixture.daemonIO(store))
        XCTAssertThrowsError(try daemon.tick())
        XCTAssertEqual(fixture.applied, [50, 0]); XCTAssertEqual(fixture.native, 80)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("preferences.plist").path))
    }
    func testExplicitShutdownStillRestoresAndPublishesOffWithSameInstanceMetadata() throws {
        let (root, fixture, store) = try fixture(); try store.apply(50)
        let daemon = NativeBatteryDaemon(io: fixture.daemonIO(store), binaryIdentity: expectedSHA, processStartedAtMicros: birth, instanceID: "11111111-2222-3333-4444-555555555555", adoptingExistingPolicy: true, handoffInProgress: { true })
        let ready = try daemon.tick(); try daemon.restore()
        XCTAssertEqual(fixture.native, 80); XCTAssertEqual(fixture.reports.last?["state"], "off")
        XCTAssertEqual(fixture.reports.last?["instanceID"], ready["instanceID"])
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("preferences.plist").path))
    }
}

private final class HandoffPreferenceFixture: @unchecked Sendable {
    var values: JSONObject = ["mclLimitValue": 80, "MCLFeatureState": 1]
    var native = 80, preferenceWrites = 0
    var failReport = false, marker = false, targetFails = false
    var delayAcknowledgement = false
    var targetBytes = Data("50\n".utf8)
    var reportAttempts = 0
    var applied: [Int] = []
    var reports: [JSONValue] = []
    var preferenceIO: NativeBatteryPreferenceIO {
        .init(read: { key, user, host in user == "current" && host == "any" ? self.values[key] ?? .null : .null }, write: { key, _, _, value in self.preferenceWrites += 1; self.values[key] = value }, synchronize: { _, _ in }, notify: { if !self.delayAcknowledgement { self.native = self.values["mclLimitValue"]!.int } }, nativeLimit: { self.native })
    }
    func daemonIO(_ store: NativeBatteryPreferences) -> NativeBatteryDaemonIO {
        .init(target: { if self.targetFails { throw NativeFailure("Injected unreadable target") }; return self.targetBytes }, apply: { self.applied.append($0); try store.apply($0) }, pending: { store.pending }, nativeLimit: { self.native }, battery: { ["present": true, "percent": 55, "externalConnected": true] }, report: {
            self.reportAttempts += 1
            if self.failReport { throw NativeFailure("Injected report publication failure") }; self.reports.append($0)
        }, now: { 1_700_000_000_001 })
    }
}
