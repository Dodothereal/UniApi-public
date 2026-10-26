import XCTest
import Foundation
import Darwin
@testable import UniApiCore

final class LegacyBootoutSettlementTests: XCTestCase {
    func testAcceptedBootoutWaitsThroughExactOldOldUntilNil() async throws {
        let f = try BootoutSettlementFixture(); f.delays[f.server] = 2
        XCTAssertNil(f.io.settlement)
        let value = await NativeLegacyRetirement.retire(paths: f.paths, io: f.io)
        XCTAssertEqual(value["status"], "retired"); XCTAssertEqual(value["safeToInstall"], true)
        XCTAssertEqual(f.oldReads[f.server], 2); XCTAssertEqual(f.absentReads[f.server], 1)
        XCTAssertEqual(f.pauses, [0.02, 0.02]); XCTAssertTrue(f.restored.isEmpty)
        XCTAssertTrue(f.registrations.isEmpty); XCTAssertTrue(f.nodes.isEmpty)
    }
    func testTwoAcceptedLabelsWaitForFiveSecondLaunchdGraceEachWithoutEarlyTermination() async throws {
        let f = try BootoutSettlementFixture(twoLabels: true)
        f.launchdGrace[f.server] = 5; f.launchdGrace[f.shim] = 5
        let value = await NativeLegacyRetirement.retire(paths: f.paths, io: f.io)
        XCTAssertEqual(value["status"], "retired"); XCTAssertEqual(value["safeToInstall"], true)
        XCTAssertEqual(f.issued, [f.server, f.shim]); XCTAssertEqual(f.frozen, [111, 222])
        for label in [f.server, f.shim] {
            let elapsed = try XCTUnwrap(f.absentTimes[label]) - XCTUnwrap(f.issueTimes[label])
            XCTAssertGreaterThanOrEqual(elapsed, 5); XCTAssertLessThanOrEqual(elapsed, 5.02 + 0.000001)
            XCTAssertGreaterThan(f.oldReads[label, default: 0], 0)
        }
        XCTAssertGreaterThanOrEqual(f.time, 10); XCTAssertLessThanOrEqual(f.time, 10.04 + 0.000001)
        XCTAssertTrue(f.pauses.allSatisfy { $0 > 0 && $0 <= 0.02 })
        XCTAssertTrue(f.terminated.isEmpty); XCTAssertTrue(f.resumed.isEmpty); XCTAssertTrue(f.restored.isEmpty)
        XCTAssertTrue(f.registrations.isEmpty); XCTAssertTrue(f.nodes.isEmpty)
    }
    func testAcceptedCancellationBeforeFirstAbsenceQueryRecoversUncancelled() async throws {
        let f = try BootoutSettlementFixture(); f.delays[f.server] = 2; f.cancelAfterAccepted = true
        let result = await Task { await NativeLegacyRetirement.retire(paths: f.paths, io: f.io) }.value
        XCTAssertEqual(result["status"], "rolled-back"); XCTAssertFalse(result["safeToInstall"].bool)
        XCTAssertEqual(f.restored, [f.server]); XCTAssertEqual(f.oldReads[f.server], 2)
        XCTAssertTrue(f.recoveryUncancelled); XCTAssertEqual(f.nodes[1111]?.bornSeconds, 200)
        XCTAssertEqual(f.readyLabels, [f.server]); XCTAssertFalse(f.resumed.contains(111))
    }
    func testAcceptedDeadlineBeforeFirstAbsenceQueryRecoversPending() async throws {
        let f = try BootoutSettlementFixture(); f.delays[f.server] = 2; f.expireAfterAccepted = true
        let value = await NativeLegacyRetirement.retire(paths: f.paths, io: f.io, retirementDeadline: 0.1)
        XCTAssertEqual(value["status"], "rolled-back"); XCTAssertEqual(f.restored, [f.server])
        XCTAssertEqual(f.oldReads[f.server], 2); XCTAssertEqual(f.readyLabels, [f.server])
        XCTAssertTrue(f.recoveryUncancelled); XCTAssertEqual(f.nodes[1111]?.bornSeconds, 200)
    }
    func testForeverOldAcceptedJobIsRecoveryIncomplete() async throws {
        let f = try BootoutSettlementFixture(); f.delays[f.server] = -1
        let value = await NativeLegacyRetirement.retire(paths: f.paths, io: f.io, retirementDeadline: 0.06, rollbackDeadline: 0.06)
        XCTAssertEqual(value["status"], "recovery-incomplete"); XCTAssertFalse(value["safeToInstall"].bool)
        XCTAssertTrue(f.restored.isEmpty); XCTAssertTrue(f.terminated.isEmpty); XCTAssertEqual(f.resumed, [111])
        XCTAssertNotNil(f.registrations[f.server]); XCTAssertTrue(f.pauses.allSatisfy { $0 > 0 && $0 <= 0.02 })
        XCTAssertLessThanOrEqual(f.time, 0.12 + 0.000001)
    }
    func testGenericAndTypedPostIssueErrorsSettleBeforeFreshRecovery() async throws {
        for typed in [false, true] {
            let f = try BootoutSettlementFixture(); f.delays[f.server] = 2; f.throwAfterIssue = true; f.typedPostIssue = typed
            let value = await NativeLegacyRetirement.retire(paths: f.paths, io: f.io)
            XCTAssertEqual(value["status"], "rolled-back"); XCTAssertEqual(f.restored, [f.server])
            XCTAssertEqual(f.oldReads[f.server], 2); XCTAssertEqual(f.readyLabels, [f.server])
            XCTAssertEqual(f.nodes[1111]?.bornSeconds, 200); XCTAssertTrue(f.recoveryUncancelled)
        }
    }
    func testPostIssueThrowAfterRemovalRestoresFreshBirth() async throws {
        let f = try BootoutSettlementFixture(); f.throwAfterIssue = true
        let value = await NativeLegacyRetirement.retire(paths: f.paths, io: f.io)
        XCTAssertEqual(value["status"], "rolled-back"); XCTAssertEqual(f.restored, [f.server])
        XCTAssertEqual(f.issued, [f.server]); XCTAssertEqual(f.readyLabels, [f.server])
        XCTAssertEqual(f.nodes[1111]?.bornSeconds, 200); XCTAssertTrue(f.terminated.isEmpty)
    }
    func testExplicitNotIssuedRefusalLeavesOldJobAndResumes() async throws {
        let f = try BootoutSettlementFixture(); f.notIssued.insert(f.server)
        let value = await NativeLegacyRetirement.retire(paths: f.paths, io: f.io)
        XCTAssertEqual(value["status"], "refused"); XCTAssertTrue(f.issued.isEmpty)
        XCTAssertTrue(f.restored.isEmpty); XCTAssertTrue(f.terminated.isEmpty); XCTAssertEqual(f.resumed, [111])
        XCTAssertEqual(f.registrations[f.server]?.pid, 111)
    }
    func testPendingForeignNoPIDAndInspectionErrorsNeverBecomeAbsence() async throws {
        for fault in [BootoutSettlementFixture.Fault.foreign, .noPID, .inspection, .processGone] {
            let f = try BootoutSettlementFixture(); f.delays[f.server] = -1; f.pendingFaults[f.server] = fault
            XCTAssertNil(f.io.settlement)
            let value = await NativeLegacyRetirement.retire(paths: f.paths, io: f.io)
            XCTAssertEqual(value["status"], "recovery-incomplete"); XCTAssertFalse(value["safeToInstall"].bool)
            XCTAssertTrue(f.restored.isEmpty); XCTAssertTrue(f.terminated.isEmpty); XCTAssertFalse(f.resumed.contains(999))
            if case .processGone = fault { XCTAssertNil(f.nodes[111]) } else { XCTAssertNotNil(f.nodes[111]) }
            XCTAssertEqual(f.issued, [f.server])
        }
    }
    func testAlreadyRemovedFirstLabelRestoresBeforePendingSecond() async throws {
        let f = try BootoutSettlementFixture(twoLabels: true); f.delays[f.shim] = -1
        let value = await NativeLegacyRetirement.retire(paths: f.paths, io: f.io, retirementDeadline: 0.06, rollbackDeadline: 0.06)
        XCTAssertEqual(value["status"], "recovery-incomplete"); XCTAssertFalse(value["safeToInstall"].bool)
        XCTAssertEqual(f.restored, [f.server]); XCTAssertEqual(f.readyLabels, [f.server])
        XCTAssertLessThanOrEqual(try XCTUnwrap(f.restoreTimes[f.server]), 0.06 + 0.000001)
        XCTAssertEqual(f.nodes[1111]?.bornSeconds, 200); XCTAssertEqual(f.registrations[f.shim]?.pid, 222)
        XCTAssertEqual(f.resumed, [222]); XCTAssertTrue(f.terminated.isEmpty)
    }
    func testRecoveryFailureDoesNotSkipOtherAbsentLabel() async throws {
        let f = try BootoutSettlementFixture(twoLabels: true); f.throwOnLabel = f.shim; f.failReady.insert(f.server)
        let value = await NativeLegacyRetirement.retire(paths: f.paths, io: f.io)
        XCTAssertEqual(value["status"], "recovery-incomplete"); XCTAssertFalse(value["safeToInstall"].bool)
        XCTAssertEqual(f.restored, [f.server, f.shim]); XCTAssertEqual(f.readyLabels, [f.server, f.shim])
        XCTAssertEqual(f.nodes[1111]?.bornSeconds, 200); XCTAssertEqual(f.nodes[1222]?.bornSeconds, 200)
    }
    func testFinalPortSettlementOutlastsServiceBudgetWithoutFurtherControls() async throws {
        let f = try BootoutSettlementFixture(twoLabels: true); f.addServerSurvivor()
        f.launchdGrace[f.server] = 5; f.launchdGrace[f.shim] = 5
        let probe = LegacyPortPhaseProbe(); var io = f.io
        io.portsAbsent = {
            probe.record(f, port: 8780)
            XCTAssertTrue(f.registrations.isEmpty); XCTAssertTrue(f.nodes.isEmpty)
            XCTAssertEqual(f.terminated, [112]); XCTAssertEqual(f.issued, [f.server, f.shim])
            if f.time - probe.start! < 16 { throw NativeOwnershipBindFailure(port: 8780, code: EADDRINUSE) }
            probe.record(f, port: 8823)
        }
        let value = await NativeLegacyRetirement.retire(paths: f.paths, io: io)
        let portStart = try XCTUnwrap(probe.start)
        XCTAssertEqual(value["status"], "retired"); XCTAssertEqual(value["safeToInstall"], true)
        XCTAssertGreaterThan(f.time, 15); XCTAssertGreaterThanOrEqual(f.time - portStart, 16)
        XCTAssertLessThanOrEqual(f.time - portStart, 16.02 + 0.000001)
        XCTAssertEqual(probe.ports.last, 8823); XCTAssertTrue(f.restored.isEmpty); XCTAssertTrue(f.resumed.isEmpty)
        let controls = try XCTUnwrap(probe.controlSnapshots.first)
        XCTAssertTrue(probe.controlSnapshots.allSatisfy { $0 == controls })
        XCTAssertTrue(f.pauses.allSatisfy { $0 > 0 && $0 <= 0.02 })
    }
    func testExpiredServiceBudgetCannotEnterFinalPortSettlement() async throws {
        let f = try BootoutSettlementFixture(twoLabels: true); f.addServerSurvivor()
        let probe = LegacyPortPhaseProbe(); var io = f.io; let terminate = io.terminate
        io.terminate = { node in try terminate(node); f.time = 15 }
        io.portsAbsent = { probe.record(f, port: 8780) }
        let value = await NativeLegacyRetirement.retire(paths: f.paths, io: io)
        XCTAssertEqual(value["status"], "rolled-back"); XCTAssertEqual(value["safeToInstall"], false)
        XCTAssertTrue(probe.times.isEmpty); XCTAssertEqual(f.terminated, [112])
        XCTAssertEqual(f.restored, [f.server, f.shim]); XCTAssertEqual(f.readyLabels, [f.server, f.shim])
        XCTAssertEqual(f.nodes[1111]?.bornSeconds, 200); XCTAssertEqual(f.nodes[1222]?.bornSeconds, 200)
        XCTAssertTrue(f.recoveryUncancelled)
    }
    func testBothPortsShareOneFinalSettlementDeadlineWithoutReset() async throws {
        let f = try BootoutSettlementFixture(twoLabels: true), probe = LegacyPortPhaseProbe(); var io = f.io
        io.portsAbsent = {
            if probe.ports.filter({ $0 == 8780 }).count >= 64 { throw NativeFailure("Fixture shared-port deadline watchdog") }
            probe.record(f, port: 8780)
            if f.time - probe.start! < 0.04 { throw NativeOwnershipBindFailure(port: 8780, code: EADDRINUSE) }
            probe.record(f, port: 8823)
            throw NativeOwnershipBindFailure(port: 8823, code: EADDRINUSE)
        }
        let value = await NativeLegacyRetirement.retire(paths: f.paths, io: io, portDeadline: 0.06)
        let portStart = try XCTUnwrap(probe.start)
        XCTAssertEqual(value["status"], "rolled-back"); XCTAssertEqual(value["safeToInstall"], false)
        XCTAssertTrue(probe.ports.contains(8780)); XCTAssertTrue(probe.ports.contains(8823))
        XCTAssertGreaterThanOrEqual(f.time - portStart, 0.06 - 0.000001)
        XCTAssertLessThanOrEqual(f.time - portStart, 0.06 + 0.000001)
        XCTAssertEqual(f.restored, [f.server, f.shim]); XCTAssertEqual(f.readyLabels, [f.server, f.shim])
        let controls = try XCTUnwrap(probe.controlSnapshots.first)
        XCTAssertTrue(probe.controlSnapshots.allSatisfy { $0 == controls })
        XCTAssertTrue(f.pauses.allSatisfy { $0 > 0 && $0 <= 0.02 })
    }
    func testFinalPortSettlementRetriesOnlyTypedAddressInUse() async throws {
        for mode in 0..<5 {
            let f = try BootoutSettlementFixture(twoLabels: true), probe = LegacyPortPhaseProbe(); var io = f.io
            io.portsAbsent = {
                probe.record(f, port: 8780)
                switch mode {
                case 0: throw NativeOwnershipBindFailure(port: 8780, code: EACCES)
                case 1: throw NativeOwnershipBindFailure(port: 8780, code: EADDRNOTAVAIL)
                case 2: throw NativeOwnershipBindFailure(port: 8823, code: EINTR)
                case 3: throw NativeOwnershipBindFailure(port: 8823, code: 0)
                default: throw NativeFailure("Fixture generic address already in use")
                }
            }
            let value = await NativeLegacyRetirement.retire(paths: f.paths, io: io)
            XCTAssertEqual(value["status"], "rolled-back", "mode \(mode)"); XCTAssertEqual(value["safeToInstall"], false)
            XCTAssertEqual(probe.times.count, 1); XCTAssertTrue(f.pauses.isEmpty)
            XCTAssertEqual(f.restored, [f.server, f.shim]); XCTAssertEqual(f.readyLabels, [f.server, f.shim])
            XCTAssertTrue(f.recoveryUncancelled)
        }
    }
    func testPortCallbackCancellationAndLateResultsRequireFreshRollback() async throws {
        for mode in 0..<4 {
            let f = try BootoutSettlementFixture(twoLabels: true), probe = LegacyPortPhaseProbe(); var io = f.io
            io.portsAbsent = {
                probe.record(f, port: 8780)
                if mode < 2 { withUnsafeCurrentTask { $0?.cancel() } } else { f.time += 0.07 }
                if mode % 2 == 1 { throw NativeOwnershipBindFailure(port: 8780, code: EADDRINUSE) }
            }
            let value = await Task { await NativeLegacyRetirement.retire(paths: f.paths, io: io, portDeadline: 0.06) }.value
            XCTAssertEqual(value["status"], "rolled-back", "mode \(mode)"); XCTAssertEqual(value["safeToInstall"], false)
            XCTAssertEqual(probe.times.count, 1); XCTAssertTrue(f.pauses.isEmpty)
            XCTAssertEqual(f.restored, [f.server, f.shim]); XCTAssertEqual(f.readyLabels, [f.server, f.shim])
            XCTAssertEqual(f.nodes[1111]?.bornSeconds, 200); XCTAssertEqual(f.nodes[1222]?.bornSeconds, 200)
            XCTAssertTrue(f.recoveryUncancelled); XCTAssertLessThanOrEqual(f.time, 0.07 + 0.000001)
        }
    }
    func testInvalidPortBudgetsRefuseBeforeServiceControls() async throws {
        let budgets: [Double] = [0, -1, .nan, .infinity, -.infinity, 30.0001]
        for budget in budgets {
            let f = try BootoutSettlementFixture(twoLabels: true), probe = LegacyPortPhaseProbe(); var io = f.io
            io.portsAbsent = { probe.record(f, port: 8780) }
            let value = await NativeLegacyRetirement.retire(paths: f.paths, io: io, portDeadline: budget)
            XCTAssertEqual(value["status"], "refused", "budget \(budget)"); XCTAssertEqual(value["safeToInstall"], false)
            XCTAssertTrue(f.frozen.isEmpty); XCTAssertTrue(f.issued.isEmpty); XCTAssertTrue(f.terminated.isEmpty)
            XCTAssertTrue(f.resumed.isEmpty); XCTAssertTrue(f.restored.isEmpty); XCTAssertTrue(probe.times.isEmpty)
            XCTAssertEqual(f.registrations[f.server]?.pid, 111); XCTAssertEqual(f.registrations[f.shim]?.pid, 222)
        }
    }
    func testInitialForeignNoPIDAndInspectionRefuseBeforeControls() async throws {
        for fault in [BootoutSettlementFixture.Fault.foreign, .noPID, .inspection] {
            let f = try BootoutSettlementFixture(); f.initialFaults[f.server] = fault
            let value = await NativeLegacyRetirement.retire(paths: f.paths, io: f.io)
            XCTAssertEqual(value["status"], "refused"); XCTAssertTrue(f.frozen.isEmpty)
            XCTAssertTrue(f.issued.isEmpty); XCTAssertTrue(f.restored.isEmpty); XCTAssertTrue(f.terminated.isEmpty)
            XCTAssertTrue(f.resumed.isEmpty)
        }
    }
}

private final class LegacyPortPhaseProbe: @unchecked Sendable {
    var start: Double?, times: [Double] = [], ports: [UInt16] = [], controlSnapshots: [[String]] = []
    func record(_ f: BootoutSettlementFixture, port: UInt16) {
        if start == nil { start = f.time }
        times.append(f.time); ports.append(port)
        var controls = f.frozen.map { "freeze:\($0)" }
        controls += f.issued.map { "bootout:" + $0 }; controls += f.terminated.map { "terminate:\($0)" }
        controls += f.resumed.map { "resume:\($0)" }; controls += f.restored.map { "restore:" + $0 }
        controlSnapshots.append(controls)
    }
}

private final class BootoutSettlementFixture: @unchecked Sendable {
    enum Fault { case foreign, noPID, inspection, processGone }
    let home = FileManager.default.temporaryDirectory.appendingPathComponent("bootout-settlement-" + UUID().uuidString)
    var root: URL { home.appendingPathComponent("UniApi") }
    var paths: NativePaths { .init(root: root, home: home) }
    let server = NativeLegacyRetirement.labels[0], shim = NativeLegacyRetirement.labels[1]
    var registrations: [String: NativeLegacyRegistration] = [:], nodes: [Int32: NativeTransferIdentity] = [:]
    var delays: [String: Int] = [:], pending: [String: Int] = [:], oldReads: [String: Int] = [:], absentReads: [String: Int] = [:]
    var launchdGrace: [String: Double] = [:], pendingUntil: [String: Double] = [:], issueTimes: [String: Double] = [:], absentTimes: [String: Double] = [:]
    var initialFaults: [String: Fault] = [:], pendingFaults: [String: Fault] = [:]
    var stopped = Set<Int32>(), notIssued = Set<String>(), failReady = Set<String>()
    var frozen: [Int32] = [], resumed: [Int32] = [], terminated: [Int32] = []
    var issued: [String] = [], restored: [String] = [], readyLabels: [String] = [], pauses: [Double] = []
    var restoreTimes: [String: Double] = [:], time = 0.0
    var cancelAfterAccepted = false, expireAfterAccepted = false, throwAfterIssue = false, typedPostIssue = false, recoveryUncancelled = true
    var throwOnLabel: String?
    let twoLabels: Bool
    init(twoLabels: Bool = false) throws {
        self.twoLabels = twoLabels
        for (label, pid, executable, directory, arguments, port) in [
            (server, Int32(111), "/fixture/node", root.appendingPathComponent("server"), ["/fixture/node", root.appendingPathComponent("server/node_modules/tsx/dist/cli.mjs").path, root.appendingPathComponent("server/src/main.ts").path], UInt16(8780)),
            (shim, Int32(222), "/fixture/python3", root, ["/fixture/python3", root.appendingPathComponent("proxy/uniapi_shim.py").path], UInt16(8823))
        ] where twoLabels || label == server {
            let definition = try PropertyListSerialization.data(fromPropertyList: ["Label": label, "ProgramArguments": arguments, "WorkingDirectory": directory.path,
                "EnvironmentVariables": ["HOME": home.path, "UNIAPI_ROOT": root.path]], format: .xml, options: 0)
            registrations[label] = .init(label: label, pid: pid, definitionPath: home.appendingPathComponent("Library/LaunchAgents/" + label + ".plist"), definition: definition, arguments: arguments, directory: directory, sourceRoot: root, home: home, data: root.appendingPathComponent("data"), providers: root.appendingPathComponent("providers.json"), port: port)
            nodes[pid] = .init(pid: pid, parent: 1, uid: 503, bornSeconds: 100, bornMicroseconds: 1, executable: executable, arguments: arguments)
        }
    }
    func copied(_ value: NativeLegacyRegistration, pid: Int32) -> NativeLegacyRegistration {
        .init(label: value.label, pid: pid, definitionPath: value.definitionPath, definition: value.definition, arguments: value.arguments, directory: value.directory, sourceRoot: value.sourceRoot, home: value.home, data: value.data, providers: value.providers, port: value.port)
    }
    func addServerSurvivor() {
        let record = registrations[server]!
        nodes[112] = .init(pid: 112, parent: record.pid, uid: 503, bornSeconds: 100, bornMicroseconds: 2,
                           executable: record.arguments[0], arguments: record.arguments)
    }
    func remove(_ label: String) {
        if let value = registrations.removeValue(forKey: label) { nodes.removeValue(forKey: value.pid); stopped.remove(value.pid) }
    }
    func fault(_ kind: Fault, label: String) throws -> NativeLegacyRegistration? {
        switch kind {
        case .inspection: throw NativeFailure("Fixture registration inspection failed")
        case .foreign: return copied(registrations[label]!, pid: 999)
        case .noPID: return copied(registrations[label]!, pid: 0)
        case .processGone:
            let record = registrations[label]!
            nodes[record.pid] = nil; stopped.remove(record.pid)
            return record
        }
    }
    var io: NativeLegacyRetirementIO {
        .init(owner: 503, exclusive: { .init(release: {}) }, inspect: { _ in
            .init(legacyPresent: true, activeJobs: 0, activeCode: 0, legacyWindowRunning: false, shimPresent: self.twoLabels)
        }, registration: { label, _ in
            if let kind = self.initialFaults[label] { return try self.fault(kind, label: label) }
            if let until = self.pendingUntil[label] {
                if self.time < until {
                    self.oldReads[label, default: 0] += 1
                    return self.registrations[label]
                }
                self.pendingUntil[label] = nil; self.remove(label)
                self.absentTimes[label] = self.time; self.absentReads[label, default: 0] += 1
            }
            if let remaining = self.pending[label] {
                if let kind = self.pendingFaults[label] { return try self.fault(kind, label: label) }
                if remaining != 0 {
                    if remaining > 0 { self.pending[label] = remaining - 1 }
                    self.oldReads[label, default: 0] += 1
                    return self.registrations[label]
                }
                self.pending[label] = nil; self.remove(label); self.absentReads[label, default: 0] += 1
            }
            return self.registrations[label]
        }, identity: { pid in guard let node = self.nodes[pid] else { throw NativeFailure("Fixture process absent") }; return node }, sameInstance: { node in
            guard let current = self.nodes[node.pid] else { return false }
            return current == node
        }, stopped: { self.stopped.contains($0.pid) }, freeze: { self.frozen.append($0.pid); self.stopped.insert($0.pid) }, resume: { self.resumed.append($0.pid); self.stopped.remove($0.pid) }, terminate: { node in
            self.terminated.append(node.pid); self.nodes[node.pid] = nil; self.stopped.remove(node.pid)
        }, children: { pid in self.nodes.values.filter { $0.parent == pid }.map(\.pid).sorted() }, sockets: { node in .init(listeningPorts: [111, 112, 1111].contains(node.pid) ? [8780] : [8823]) }, temporaryFanOwner: { _ in false }, work: { .init() }, bootout: { record, _ in
            if self.notIssued.contains(record.label) { throw NativeLegacyBootoutFailure(disposition: .notIssued, message: "Fixture proved pre-command refusal") }
            self.issued.append(record.label)
            self.issueTimes[record.label] = self.time
            if let grace = self.launchdGrace[record.label] { self.pendingUntil[record.label] = self.time + grace }
            else if let delay = self.delays[record.label] { self.pending[record.label] = delay } else { self.remove(record.label) }
            if self.expireAfterAccepted { self.time += 0.2 }
            if self.cancelAfterAccepted { withUnsafeCurrentTask { $0?.cancel() }; return }
            if self.throwAfterIssue || self.throwOnLabel == record.label {
                if self.typedPostIssue { throw NativeLegacyBootoutFailure(disposition: .mayHaveApplied, message: "Fixture post-issue failure") }
                throw NativeFailure("Fixture uncertain command failure")
            }
        }, restore: { record, _ in
            self.recoveryUncancelled = self.recoveryUncancelled && !Task.isCancelled
            self.restored.append(record.label); self.restoreTimes[record.label] = self.time
            let pid = record.pid + 1000
            self.registrations[record.label] = self.copied(record, pid: pid)
            self.nodes[pid] = .init(pid: pid, parent: 1, uid: 503, bornSeconds: 200, bornMicroseconds: 1, executable: record.arguments[0], arguments: record.arguments)
        }, ready: { record, nodes, _ in
            self.recoveryUncancelled = self.recoveryUncancelled && !Task.isCancelled
            self.readyLabels.append(record.label)
            return !self.failReady.contains(record.label) && self.registrations[record.label] == record && nodes.first?.bornSeconds == 200
        }, portsAbsent: {}, pause: { seconds in
            self.recoveryUncancelled = self.recoveryUncancelled && !Task.isCancelled
            self.pauses.append(seconds); self.time += seconds
        }, clock: { self.time })
    }
}
