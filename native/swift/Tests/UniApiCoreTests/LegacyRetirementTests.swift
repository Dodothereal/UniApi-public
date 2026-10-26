import XCTest
@testable import UniApiCore

final class LegacyRetirementTests: XCTestCase {
    func testPrepareIsReadOnlyAdvisoryAndDoesNotExposeDefinitionOrEnvironment() async throws {
        let f = try LegacyRetirementFixture()
        let value = await NativeLegacyRetirement.prepare(paths: f.paths, io: f.io)
        XCTAssertEqual(value["status"], "prepared"); XCTAssertEqual(value["safeToInstall"], false)
        XCTAssertFalse(String(decoding: try value.encoded(), as: UTF8.self).contains("fixture-private"))
        XCTAssertTrue(f.frozen.isEmpty); XCTAssertTrue(f.booted.isEmpty)
    }
    func testNodeTsxParentAndChildPlusIndependentShimRetireOnlyVerifiedForest() async throws {
        let f = try LegacyRetirementFixture()
        let value = await NativeLegacyRetirement.retire(paths: f.paths, io: f.io)
        XCTAssertEqual(value["status"], "retired"); XCTAssertEqual(value["safeToInstall"], true)
        XCTAssertEqual(f.frozen, [111, 112, 222]); XCTAssertEqual(f.booted, NativeLegacyRetirement.labels)
        XCTAssertEqual(f.terminated, [112]); XCTAssertTrue(f.resumed.isEmpty); XCTAssertTrue(f.restored.isEmpty)
    }
    func testActiveWindowReadOnlyRuntimeUnknownChildAndFanOwnerRefuseWithoutBootout() async throws {
        for mode in 0..<4 {
            let f = try LegacyRetirementFixture()
            switch mode {
            case 0: f.advisory.legacyWindowRunning = true
            case 1: f.readOnly = true
            case 2: f.extraChild = true
            default: f.fanOwner = true
            }
            let value = await NativeLegacyRetirement.retire(paths: f.paths, io: f.io)
            XCTAssertEqual(value["status"], "refused", "mode \(mode)"); XCTAssertEqual(value["safeToInstall"], false)
            XCTAssertTrue(f.booted.isEmpty)
        }
    }
    func testActiveTCPAndPendingAcceptsOnShimRefuseAndResumeAdmission() async throws {
        for sockets in [NativeTransferSockets(listeningPorts: [8823], activeTCP: 1), .init(listeningPorts: [8823], pendingAccepts: 1)] {
            let f = try LegacyRetirementFixture(); f.shimSockets = sockets
            let value = await NativeLegacyRetirement.retire(paths: f.paths, io: f.io)
            XCTAssertEqual(value["status"], "refused"); XCTAssertTrue(f.booted.isEmpty)
            XCTAssertEqual(f.resumed, [222, 112, 111])
        }
    }
    func testLateWorkAndPIDReuseNeverRetireOrSignalReplacement() async throws {
        for reuse in [false, true] {
            let f = try LegacyRetirementFixture()
            f.onFreeze = { if reuse { f.replaced.insert(111) } else { f.pending = .init(jobs: 1) } }
            let value = await NativeLegacyRetirement.retire(paths: f.paths, io: f.io)
            XCTAssertEqual(value["status"], "refused"); XCTAssertTrue(f.booted.isEmpty)
            if reuse { XCTAssertFalse(f.resumed.contains(111)); XCTAssertFalse(f.terminated.contains(111)) }
        }
    }
    func testWrongSourceArgumentExecutionOrLoadedDefinitionRefusesBeforeFreeze() async throws {
        for mode in 0..<3 {
            let f = try LegacyRetirementFixture(), service = f.registrations[NativeLegacyRetirement.labels[0]]!
            if mode == 0 { f.replaceNode(111, arguments: ["/fixture/node", "--eval", f.root.appendingPathComponent("server/src/main.ts").path]) }
            else if mode == 1 { f.replaceNode(111, executable: "/other/node") }
            else { f.registrations[service.label] = f.registration(service, definition: Data("not-a-plist fixture-private".utf8)) }
            let value = await NativeLegacyRetirement.retire(paths: f.paths, io: f.io)
            XCTAssertEqual(value["status"], "refused"); XCTAssertTrue(f.frozen.isEmpty); XCTAssertTrue(f.booted.isEmpty)
        }
    }
    func testCustomNodeStorageIsSupportedButPythonHardcodedHomeMismatchIsRefused() async throws {
        let f = try LegacyRetirementFixture(), node = f.registrations[NativeLegacyRetirement.labels[0]]!
        f.customData = f.home.appendingPathComponent("custom-data"); f.customProviders = f.home.appendingPathComponent("custom-providers.json")
        f.registrations.removeValue(forKey: NativeLegacyRetirement.labels[1]); f.advisory.shimPresent = false
        let changed = f.registration(node, data: f.customData!, providers: f.customProviders!)
        f.registrations[node.label] = f.registration(changed, definition: try f.definition(changed))
        let custom = await NativeLegacyRetirement.retire(paths: f.paths, io: f.io)
        XCTAssertEqual(custom["status"], "retired")
        let mismatch = try LegacyRetirementFixture(); mismatch.customData = mismatch.home.appendingPathComponent("other-data")
        let refused = await NativeLegacyRetirement.retire(paths: mismatch.paths, io: mismatch.io)
        XCTAssertEqual(refused["status"], "refused")
        XCTAssertTrue(mismatch.frozen.isEmpty)
    }
    func testPartialBootoutFailureRestoresOnlyRemovedJobAndChecksNewPIDReadiness() async throws {
        let f = try LegacyRetirementFixture(); f.failBootout = NativeLegacyRetirement.labels[1]
        let value = await NativeLegacyRetirement.retire(paths: f.paths, io: f.io)
        XCTAssertEqual(value["status"], "rolled-back"); XCTAssertEqual(value["safeToInstall"], false)
        XCTAssertEqual(f.restored, [NativeLegacyRetirement.labels[0]]); XCTAssertEqual(f.readyCalls, 1)
        XCTAssertEqual(f.resumed, [222]); XCTAssertFalse(f.resumed.contains(111))
    }
    func testExactLegacyFanMonitorChildRetiresButRootDaemonIsUntouched() async throws {
        let f = try LegacyRetirementFixture(), monitor = f.root.appendingPathComponent("data/bin/uniapi-fans").path
        f.identities[113] = .init(pid: 113, parent: 112, uid: 503, bornSeconds: 100, bornMicroseconds: 30, executable: monitor, arguments: [monitor, "--monitor"])
        // A separate persistent daemon is not a descendant of the hub.
        f.identities[900] = .init(pid: 900, parent: 1, uid: 0, bornSeconds: 90, bornMicroseconds: 0, executable: "/fixture/root-fans", arguments: ["/fixture/root-fans", "--daemon"])
        let value = await NativeLegacyRetirement.retire(paths: f.paths, io: f.io)
        XCTAssertEqual(value["status"], "retired")
        XCTAssertEqual(f.frozen, [111, 112, 113, 222]); XCTAssertEqual(f.terminated, [113, 112])
        XCTAssertNotNil(f.identities[900]); XCTAssertFalse(f.frozen.contains(900)); XCTAssertFalse(f.terminated.contains(900))
    }
    func testFanControlsUnknownArgumentsWrongExecutableAndOwnerRefuseBeforePause() async throws {
        for mode in 0..<7 {
            let f = try LegacyRetirementFixture(), expected = f.root.appendingPathComponent("data/bin/uniapi-fans").path
            let executable = mode == 4 ? "/other/uniapi-fans" : expected
            let args: [String]
            switch mode {
            case 0: args = [executable, "--serve", "503", "112"]
            case 1: args = [executable, "--probe"]
            case 2: args = [executable, "--monitor", "extra"]
            case 3: args = [executable, "--daemon"]
            default: args = [executable, "--monitor"]
            }
            f.identities[113] = .init(pid: 113, parent: 112, uid: mode == 5 ? 0 : 503, bornSeconds: mode == 6 ? 0 : 100,
                                      bornMicroseconds: 30, executable: executable, arguments: args)
            let value = await NativeLegacyRetirement.retire(paths: f.paths, io: f.io)
            XCTAssertEqual(value["status"], "refused", "mode \(mode)"); XCTAssertTrue(f.frozen.isEmpty); XCTAssertTrue(f.booted.isEmpty)
        }
    }
    func testBootoutErrorAfterUnregisterAndCancellationStillRestoreBothDefinitions() async throws {
        for cancel in [false, true] {
            let f = try LegacyRetirementFixture(); f.failBootout = NativeLegacyRetirement.labels[1]; f.failAfterUnregister = true; f.cancelBootout = cancel
            let value = await Task { await NativeLegacyRetirement.retire(paths: f.paths, io: f.io) }.value
            XCTAssertEqual(value["status"], "rolled-back"); XCTAssertEqual(Set(f.restored), Set(NativeLegacyRetirement.labels))
            XCTAssertEqual(f.readyCalls, 2); XCTAssertTrue(f.restoreNeverCancelled)
        }
    }
    func testPartialRollbackDefinitionConflictOrReadinessFailureIsExplicitlyIncomplete() async throws {
        for conflict in [false, true] {
            let f = try LegacyRetirementFixture(); f.failBootout = NativeLegacyRetirement.labels[1]
            f.restoreConflict = conflict; f.failReady = !conflict
            let value = await NativeLegacyRetirement.retire(paths: f.paths, io: f.io)
            XCTAssertEqual(value["status"], "recovery-incomplete"); XCTAssertEqual(value["safeToInstall"], false)
            XCTAssertEqual(f.booted.count, 2) // No cleanup bootout of a conflicting new job.
        }
    }
    func testSlowBootoutCannotPublishSuccessAndStillRunsBoundedRecovery() async throws {
        let f = try LegacyRetirementFixture(); f.slowBootout = true
        let value = await NativeLegacyRetirement.retire(paths: f.paths, io: f.io, retirementDeadline: 1)
        XCTAssertEqual(value["status"], "rolled-back"); XCTAssertEqual(f.booted.count, 1)
        XCTAssertEqual(f.restored, [NativeLegacyRetirement.labels[0]])
    }
    func testInspectionFailureIsNotDisappearanceAndResumeFailureIsIncomplete() async throws {
        for failure in [false, true] {
            let f = try LegacyRetirementFixture(); f.inspectionFailure = !failure
            if failure { f.pending = .init(); f.onFreeze = { f.pending = .init(jobs: 1) }; f.failResume = true }
            let value = await NativeLegacyRetirement.retire(paths: f.paths, io: f.io)
            XCTAssertEqual(value["status"], failure ? "recovery-incomplete" : "refused"); XCTAssertTrue(f.booted.isEmpty)
        }
    }
    func testExclusiveTransferOwnershipRefusesASecondAttemptAndReleasesAfterRecovery() async throws {
        let f = try LegacyRetirementFixture(), blocked = RetirementFixtureGate()
        var io = f.io
        let bootout = io.bootout
        io.bootout = { record, remaining in
            if record.label == NativeLegacyRetirement.labels[0] { await blocked.hold() }
            try await bootout(record, remaining)
        }
        let first = Task { await NativeLegacyRetirement.retire(paths: f.paths, io: io) }
        await blocked.waitForEntry()
        let second = await NativeLegacyRetirement.retire(paths: f.paths, io: f.io)
        XCTAssertEqual(second["status"], "refused"); XCTAssertTrue(f.booted.isEmpty)
        await blocked.release()
        let completed = await first.value
        XCTAssertEqual(completed["status"], "retired")
        let lease = try f.io.exclusive(); lease.close(); lease.close()
    }
    func testChangedExecutionIsNotResumedAndUnexpectedMonitorListenerIsRefused() async throws {
        let f = try LegacyRetirementFixture()
        f.onFreeze = { f.replaceNode(111, executable: "/other/node") }
        let changed = await NativeLegacyRetirement.retire(paths: f.paths, io: f.io)
        XCTAssertEqual(changed["status"], "recovery-incomplete"); XCTAssertFalse(f.resumed.contains(111)); XCTAssertTrue(f.booted.isEmpty)
        let monitor = try LegacyRetirementFixture(), executable = monitor.root.appendingPathComponent("data/bin/uniapi-fans").path
        monitor.identities[113] = .init(pid: 113, parent: 112, uid: 503, bornSeconds: 100, bornMicroseconds: 30, executable: executable, arguments: [executable, "--monitor"])
        var io = monitor.io
        let sockets = io.sockets
        io.sockets = { node in node.pid == 113 ? .init(listeningPorts: [8780]) : try sockets(node) }
        let refused = await NativeLegacyRetirement.retire(paths: monitor.paths, io: io)
        XCTAssertEqual(refused["status"], "refused"); XCTAssertTrue(monitor.frozen.isEmpty)
    }
}

private actor RetirementFixtureGate {
    private var entered = false, waiting: CheckedContinuation<Void, Never>?
    private var observers: [CheckedContinuation<Void, Never>] = []
    func hold() async {
        entered = true; observers.forEach { $0.resume() }; observers.removeAll()
        await withCheckedContinuation { waiting = $0 }
    }
    func waitForEntry() async {
        if entered { return }
        await withCheckedContinuation { observers.append($0) }
    }
    func release() { waiting?.resume(); waiting = nil }
}

private final class LegacyRetirementFixture: @unchecked Sendable {
    let transferLock = NSLock()
    var transferOwned = false
    let home = FileManager.default.temporaryDirectory.appendingPathComponent("legacy-retire-" + UUID().uuidString)
    var root: URL { home.appendingPathComponent("UniApi", isDirectory: true) }
    var paths: NativePaths { .init(root: root, home: home, readOnly: readOnly, dataRoot: customData, providersFile: customProviders) }
    var registrations: [String: NativeLegacyRegistration] = [:], identities: [Int32: NativeTransferIdentity] = [:]
    var advisory = NativeTransferCheck(legacyPresent: true, activeJobs: 0, activeCode: 0, legacyWindowRunning: false, shimPresent: true, activeShim: nil)
    var frozen: [Int32] = [], resumed: [Int32] = [], terminated: [Int32] = [], booted: [String] = [], restored: [String] = []
    var stopped = Set<Int32>(), replaced = Set<Int32>(), pending = NativeTransferWork(), shimSockets = NativeTransferSockets(listeningPorts: [8823])
    var readOnly = false, extraChild = false, fanOwner = false, failAfterUnregister = false, cancelBootout = false, restoreConflict = false, failReady = false
    var slowBootout = false, inspectionFailure = false, failResume = false, restoreNeverCancelled = true, readyCalls = 0, time = 0.0
    var customData: URL?, customProviders: URL?, failBootout: String?, onFreeze: (() -> Void)?
    init() throws {
        for (label, pid, exe, directory, argv, port) in [
            (NativeLegacyRetirement.labels[0], Int32(111), "/fixture/node", root.appendingPathComponent("server", isDirectory: true), ["/fixture/node", root.appendingPathComponent("server/node_modules/tsx/dist/cli.mjs").path, root.appendingPathComponent("server/src/main.ts").path], UInt16(8780)),
            (NativeLegacyRetirement.labels[1], Int32(222), "/fixture/python3", root, ["/fixture/python3", root.appendingPathComponent("proxy/uniapi_shim.py").path], UInt16(8823))
        ] {
            let record = NativeLegacyRegistration(label: label, pid: pid, definitionPath: home.appendingPathComponent("Library/LaunchAgents/" + label + ".plist"), definition: Data(), arguments: argv, directory: directory, sourceRoot: root, home: home, data: root.appendingPathComponent("data"), providers: root.appendingPathComponent("providers.json"), port: port)
            registrations[label] = registration(record, definition: try definition(record))
            identities[pid] = .init(pid: pid, parent: 1, uid: 503, bornSeconds: 100, bornMicroseconds: 10, executable: exe, arguments: argv)
        }
        let tsx = root.appendingPathComponent("server/node_modules/tsx/dist")
        identities[112] = .init(pid: 112, parent: 111, uid: 503, bornSeconds: 100, bornMicroseconds: 20, executable: "/fixture/node", arguments: ["/fixture/node", "--require", tsx.appendingPathComponent("preflight.cjs").path, "--import", tsx.appendingPathComponent("loader.mjs").absoluteString, root.appendingPathComponent("server/src/main.ts").path])
    }
    func definition(_ r: NativeLegacyRegistration) throws -> Data {
        try PropertyListSerialization.data(fromPropertyList: ["Label": r.label, "WorkingDirectory": r.directory.path, "ProgramArguments": r.arguments,
            "EnvironmentVariables": ["HOME": r.home.path, "UNIAPI_ROOT": r.sourceRoot.path, "UNIAPI_DATA": r.data.path, "UNIAPI_PROVIDERS": r.providers.path, "PRIVATE_FIXTURE": "fixture-private"]], format: .xml, options: 0)
    }
    func registration(_ r: NativeLegacyRegistration, pid: Int32? = nil, definition: Data? = nil, data: URL? = nil, providers: URL? = nil) -> NativeLegacyRegistration {
        .init(label: r.label, pid: pid ?? r.pid, definitionPath: r.definitionPath, definition: definition ?? r.definition, arguments: r.arguments, directory: r.directory, sourceRoot: r.sourceRoot, home: r.home, data: data ?? r.data, providers: providers ?? r.providers, port: r.port, restorable: r.restorable)
    }
    func replaceNode(_ pid: Int32, executable: String? = nil, arguments: [String]? = nil, parent: Int32? = nil) {
        let n = identities[pid]!
        identities[pid] = .init(pid: pid, parent: parent ?? n.parent, uid: n.uid, bornSeconds: n.bornSeconds, bornMicroseconds: n.bornMicroseconds, executable: executable ?? n.executable, arguments: arguments ?? n.arguments)
    }
    var io: NativeLegacyRetirementIO {
        .init(owner: 503, exclusive: {
            self.transferLock.lock()
            guard !self.transferOwned else { self.transferLock.unlock(); throw NativeFailure("Fixture transfer already owned") }
            self.transferOwned = true; self.transferLock.unlock()
            return NativeLegacyRetirementLease {
                self.transferLock.lock(); self.transferOwned = false; self.transferLock.unlock()
            }
        }, inspect: { remaining in XCTAssertGreaterThan(remaining, 0); return self.advisory }, registration: { label, remaining in
            XCTAssertGreaterThan(remaining, 0); return self.registrations[label]
        }, identity: { pid in guard let value = self.identities[pid] else { throw NativeFailure("fixture disappeared") }; return value }, sameInstance: { node in
            if self.inspectionFailure { throw NativeFailure("fixture census failed") }
            guard let now = self.identities[node.pid] else { return false }
            return !self.replaced.contains(node.pid) && now.uid == node.uid && now.bornSeconds == node.bornSeconds && now.bornMicroseconds == node.bornMicroseconds
        }, stopped: { self.stopped.contains($0.pid) }, freeze: { self.stopped.insert($0.pid); self.frozen.append($0.pid); self.onFreeze?() }, resume: {
            if self.failResume { throw NativeFailure("fixture resume failed") }; self.stopped.remove($0.pid); self.resumed.append($0.pid)
        }, terminate: { self.terminated.append($0.pid); self.identities.removeValue(forKey: $0.pid); self.stopped.remove($0.pid) }, children: { pid in
            self.identities.values.filter { $0.parent == pid }.map(\.pid).sorted() + (self.extraChild && pid == 111 ? [999] : [])
        }, sockets: { node in
            if node.pid == 222 { return self.shimSockets }
            return .init(listeningPorts: node.pid == 112 || node.pid == 1111 ? [8780] : [])
        }, temporaryFanOwner: { _ in self.fanOwner }, work: { self.pending }, bootout: { record, remaining in
            XCTAssertGreaterThan(remaining, 0); self.booted.append(record.label)
            if self.failBootout == record.label && !self.failAfterUnregister { throw NativeLegacyBootoutFailure(disposition: .notIssued, message: "fixture bootout refused before issuance") }
            self.registrations.removeValue(forKey: record.label); self.identities.removeValue(forKey: record.pid)
            if record.pid == 111 { self.replaceNode(112, parent: 1) }
            if self.slowBootout { self.time += 2 }
            if self.failBootout == record.label {
                if self.cancelBootout { withUnsafeCurrentTask { $0?.cancel() }; throw CancellationError() }
                throw NativeFailure("fixture bootout failed after unregister")
            }
        }, restore: { record, remaining in
            XCTAssertGreaterThan(remaining, 0); self.restoreNeverCancelled = self.restoreNeverCancelled && !Task.isCancelled
            if self.restoreConflict { throw NativeFailure("fixture definition hash changed") }
            self.restored.append(record.label)
            let pid = record.pid + 1000
            self.registrations[record.label] = self.registration(record, pid: pid)
            self.identities[pid] = .init(pid: pid, parent: 1, uid: 503, bornSeconds: 200, bornMicroseconds: 10, executable: record.arguments[0], arguments: record.arguments)
        }, ready: { record, nodes, remaining in
            XCTAssertGreaterThan(remaining, 0); self.readyCalls += 1
            return !self.failReady && nodes.first?.pid == record.pid && self.registrations[record.label] == record
        }, portsAbsent: {}, pause: { seconds in self.time += seconds }, clock: { self.time })
    }
}
