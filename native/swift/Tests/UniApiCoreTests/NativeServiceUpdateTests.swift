import XCTest
import Darwin
import CoreGraphics
@testable import UniApiCore

final class NativeServiceUpdateTests: XCTestCase {
    func testDefinitionMarkerSelectsNativeWithoutTransportAndRejectsMixedInvalidOrLinkedMetadata() throws {
        for mode in 0..<4 {
            let f = try InstallRetirementFixture(); defer { f.cleanup() }
            if mode == 0 { XCTAssertTrue(try NativeServiceUpdate.isNativeInstallation(paths: f.paths)) }
            if mode == 1 { try Self.changeDefinition(f, label: f.labels[1]) { plist in var env = plist["EnvironmentVariables"] as! [String: String]; env.removeValue(forKey: "UNIAPI_NATIVE_INSTALL_NONCE"); plist["EnvironmentVariables"] = env } }
            if mode == 2 { try Self.changeDefinition(f, label: f.labels[1]) { var env = $0["EnvironmentVariables"] as! [String: String]; env["UNIAPI_NATIVE_INSTALL_NONCE"] = "invalid"; $0["EnvironmentVariables"] = env } }
            if mode == 3 {
                let file = f.definition(f.labels[0]), other = f.home.appendingPathComponent("linked.plist")
                try FileManager.default.moveItem(at: file, to: other); try FileManager.default.createSymbolicLink(at: file, withDestinationURL: other)
            }
            if mode != 0 { XCTAssertThrowsError(try NativeServiceUpdate.isNativeInstallation(paths: f.paths)) }
            XCTAssertTrue(f.commands.isEmpty); XCTAssertTrue(f.signals.isEmpty)
        }
        // Actual fresh-home directory layouts exercise selection itself, with
        // no fixture registration or transport capable of masking a refusal.
        for mode in 0..<10 {
            let home = FileManager.default.temporaryDirectory.appendingPathComponent("native-selection-" + UUID().uuidString)
            let library = home.appendingPathComponent("Library"), agents = library.appendingPathComponent("LaunchAgents"), other = home.appendingPathComponent("other")
            try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            defer {
                if mode == 9 { _ = chmod(library.path, 0o700) }
                try? FileManager.default.removeItem(at: home)
            }
            let paths = NativePaths(root: home.appendingPathComponent("repository"), home: home)
            if mode == 3 {
                try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
                try FileManager.default.createSymbolicLink(at: library, withDestinationURL: other)
            } else if mode == 6 {
                try NativeFile.writeAtomic(Data("not a directory".utf8), to: library)
            } else if mode != 0 && mode != 8 {
                try FileManager.default.createDirectory(at: library, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
                if mode == 4 {
                    try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
                    try FileManager.default.createSymbolicLink(at: agents, withDestinationURL: other)
                } else if mode == 2 || mode == 7 {
                    try FileManager.default.createDirectory(at: agents, withIntermediateDirectories: true, attributes: [.posixPermissions: mode == 7 ? 0o777 : 0o700])
                    if mode == 7 { XCTAssertEqual(chmod(agents.path, 0o777), 0) }
                }
                if mode == 5 { XCTAssertEqual(chmod(library.path, 0o777), 0) }
                if mode == 9 { XCTAssertEqual(chmod(library.path, 0), 0) }
            }
            if mode == 8 { XCTAssertEqual(chmod(home.path, 0o777), 0) }
            if mode <= 2 {
                XCTAssertFalse(try NativeServiceUpdate.isNativeInstallation(paths: paths), "fresh layout \(mode)")
                if mode == 0 { XCTAssertFalse(FileManager.default.fileExists(atPath: library.path)) }
                if mode == 1 { XCTAssertFalse(FileManager.default.fileExists(atPath: agents.path)) }
            } else { XCTAssertThrowsError(try NativeServiceUpdate.isNativeInstallation(paths: paths), "unsafe layout \(mode)") }
        }
    }
    func testPrepareUsesActualNativeAdapterStatusShimAndGUIWithoutLegacyHTTPOrControls() async throws {
        let f = try InstallRetirementFixture(); defer { f.cleanup() }
        let value = await NativeServiceUpdate.prepare(paths: f.paths, application: f.app, dependencies: f.updateDependencies)
        XCTAssertEqual(value["kind"], "native"); XCTAssertEqual(value["oldInstance"], .string(f.nonce))
        XCTAssertEqual(value["definitionHashes"], .object(try f.hashes().mapValues(JSONValue.string)))
        XCTAssertEqual(value["canPrepare"], true); XCTAssertEqual(value["safeToInstall"], false)
        XCTAssertEqual(f.nativeHealthReads, 1); XCTAssertEqual(f.healthCalls, 1); XCTAssertGreaterThan(f.guiReads, 0)
        XCTAssertFalse(f.commands.contains { $0[0] == "bootout" }); XCTAssertTrue(f.signals.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: f.lockPath.path))
    }
    func testPinnedNonceAndDefinitionHashesIncludingLateReplacementRefuseBeforeControl() async throws {
        for mode in 0..<3 {
            let f = try InstallRetirementFixture(); defer { f.cleanup() }
            let hashes = try f.hashes(); var dependencies = f.updateDependencies
            if mode == 2 {
                let reader = f.guiReader
                dependencies.gui = {
                    let value = try reader()
                    if f.guiReads == 2 { try Self.changeDefinition(f, label: f.labels[0]) { $0["FixtureChanged"] = true } }
                    return value
                }
            }
            let value = await NativeServiceUpdate.retire(paths: f.paths, application: f.app, instance: mode == 0 ? UUID().uuidString : f.nonce,
                expectedDefinitionHashes: mode == 1 ? [:] : hashes, dependencies: dependencies)
            XCTAssertEqual(value["status"], "refused", "mode \(mode)"); XCTAssertTrue(f.signals.isEmpty)
            XCTAssertFalse(f.commands.contains { $0[0] == "bootout" })
        }
    }
    func testBothBootoutsPrecedeTwentySecondGraceWithoutDyingKernelOrBackendCensus() async throws {
        let f = try InstallRetirementFixture(); defer { f.cleanup() }
        f.bootoutDelay = 20; f.throwDyingIdentity = true
        let value = await Self.update(f)
        XCTAssertEqual(value["status"], "retired"); XCTAssertEqual(value["safeToInstall"], true)
        XCTAssertEqual(f.bootoutTimes.count, 2); XCTAssertEqual(f.bootoutTimes[f.labels[0]], 0); XCTAssertEqual(f.bootoutTimes[f.labels[1]], 0)
        XCTAssertGreaterThanOrEqual(f.time, 20); XCTAssertLessThan(f.time, 30)
        XCTAssertEqual(f.dyingIdentityQueries, 0); XCTAssertEqual(f.issuedBackendWorkReads, 0)
        XCTAssertFalse(f.signals.contains { $0.1 == SIGKILL }); XCTAssertTrue(f.pids.isEmpty)
    }
    func testGUIRegularMinimizedVisibleForeignUnknownAndMissingMembershipRefuseBeforePause() async throws {
        for mode in 0..<6 {
            let f = try InstallRetirementFixture(); defer { f.cleanup() }; f.guiMode = mode
            let value = await Self.update(f)
            XCTAssertEqual(value["status"], "refused", "mode \(mode)"); XCTAssertTrue(f.signals.isEmpty)
            XCTAssertFalse(f.commands.contains { $0[0] == "bootout" })
        }
    }
    func testFreshGUIChangeDuringPauseResumesOnlyCapturedPauseWithoutUnregister() async throws {
        for mode in [0, 1, 2] {
            let f = try InstallRetirementFixture(); defer { f.cleanup() }; f.guiMode = mode; f.guiAfterPause = true
            let value = await Self.update(f)
            XCTAssertEqual(value["status"], "refused"); XCTAssertTrue(f.stops.isEmpty)
            XCTAssertEqual(f.signals.filter { $0.1 == SIGSTOP }.map(\.0), [111])
            XCTAssertEqual(f.signals.filter { $0.1 == SIGCONT }.map(\.0), [111])
            XCTAssertFalse(f.commands.contains { $0[0] == "bootout" })
        }
    }
    func testForeignGUIBetweenBatchCommandsAbortsFurtherIssuanceAndRestoresFirst() async throws {
        let f = try InstallRetirementFixture(); defer { f.cleanup() }; f.guiMode = 2; f.guiAfterIssue = true
        let value = await Self.update(f)
        XCTAssertEqual(value["status"], "rolled-back"); XCTAssertEqual(value["safeToInstall"], false)
        XCTAssertEqual(f.commands.filter { $0[0] == "bootout" }.count, 1)
        XCTAssertNotEqual(f.pids[f.labels[0]], 111); XCTAssertEqual(f.pids[f.labels[1]], 222)
        XCTAssertTrue(f.stops.isEmpty); XCTAssertGreaterThanOrEqual(f.nativeHealthReads, 2)
        XCTAssertFalse(f.signals.contains { $0.0 == 900 })
    }
    func testPostIssueFailureRestoresFreshOldNonceFromImmutableCopiesAcceptedByNextPrepare() async throws {
        let f = try InstallRetirementFixture(); defer { f.cleanup() }; f.failShim = true; f.failShimAfterRemoval = true
        let definitions = try f.labels.map { try Data(contentsOf: f.definition($0)) }
        let oldShim = try XCTUnwrap(f.nodes[222]), sockets = f.dependencies.sockets
        XCTAssertEqual(try sockets(oldShim).listeningPorts, [8823])
        f.pids.removeValue(forKey: f.labels[1]); f.stops.insert(222)
        XCTAssertEqual(try sockets(oldShim).listeningPorts, [8823], "Label absence must not erase a surviving paused shim's listener")
        f.pids[f.labels[1]] = 222; f.stops.remove(222)
        XCTAssertTrue(try sockets(XCTUnwrap(f.nodes[111])).listeningPorts.isEmpty)
        let monitor = f.node(901, parent: 111, arguments: [f.monitor.path, "--monitor"])
        f.nodes[901] = monitor; XCTAssertTrue(try sockets(monitor).listeningPorts.isEmpty); f.nodes.removeValue(forKey: 901)
        let foreignArguments = f.node(902, parent: 1, arguments: f.argv(f.labels[1]) + ["extra"])
        f.nodes[902] = foreignArguments; XCTAssertTrue(try sockets(foreignArguments).listeningPorts.isEmpty); f.nodes.removeValue(forKey: 902)
        let foreignExecutable = NativeTransferIdentity(pid: 903, parent: 1, uid: getuid(), bornSeconds: 100, bornMicroseconds: 903,
            executable: f.binary(f.labels[0]).path, arguments: f.argv(f.labels[1]))
        f.nodes[903] = foreignExecutable; XCTAssertTrue(try sockets(foreignExecutable).listeningPorts.isEmpty); f.nodes.removeValue(forKey: 903)
        let value = await Self.update(f)
        XCTAssertEqual(value["status"], "rolled-back", value["message"].string); XCTAssertEqual(value["safeToInstall"], false)
        XCTAssertEqual(f.commands.filter { $0[0] == "bootstrap" }.count, 2)
        XCTAssertTrue(f.pids.values.allSatisfy { $0 >= 1000 }); XCTAssertGreaterThanOrEqual(f.nativeHealthReads, 2)
        let freshPID = try XCTUnwrap(f.pids[f.labels[1]]), freshShim = try XCTUnwrap(f.nodes[freshPID])
        XCTAssertNotEqual(freshShim.pid, oldShim.pid); XCTAssertEqual(try sockets(freshShim).listeningPorts, [8823])
        XCTAssertThrowsError(try sockets(oldShim), "An absent old execution cannot donate its listener to the fresh PID")
        XCTAssertEqual(try f.labels.map { try Data(contentsOf: f.definition($0)) }, definitions)
        for label in f.labels {
            let source = try XCTUnwrap(f.sourcePaths[label]); XCTAssertNotEqual(source, f.definition(label))
            XCTAssertEqual(try Data(contentsOf: source), try Data(contentsOf: f.definition(label)))
        }
        let prepared = await NativeServiceUpdate.prepare(paths: f.paths, application: f.app, dependencies: f.updateDependencies)
        XCTAssertEqual(prepared["canPrepare"], true, prepared["message"].string)
    }
    func testCancellationAfterBothIssuesUsesUncancelledThirtySecondRollback() async throws {
        let f = try InstallRetirementFixture(); defer { f.cleanup() }; f.bootoutDelay = 20; f.cancelBootout = true; f.throwDyingIdentity = true
        let value = await Task { await Self.update(f) }.value
        XCTAssertEqual(value["status"], "rolled-back", value["message"].string); XCTAssertEqual(value["safeToInstall"], false)
        XCTAssertTrue(f.cancellationIssued); XCTAssertTrue(f.recoveryUncancelled); XCTAssertEqual(f.dyingIdentityQueries, 0)
        XCTAssertGreaterThanOrEqual(f.time, 20); XCTAssertLessThan(f.time, 30)
        XCTAssertEqual(f.commands.filter { $0[0] == "bootstrap" }.count, 2); XCTAssertTrue(f.stops.isEmpty)
    }
    func testNativeLabelsShareServiceBudgetAndKnownRemovalRestoresBeforePendingLabel() async throws {
        let f = try InstallRetirementFixture(); defer { f.cleanup() }; f.bootoutDelay = 20; f.shimDelayOffset = 25
        let value = await Self.update(f)
        // A per-label reset would incorrectly report retired at 45 seconds.
        // The shared forward budget expires at 30; rollback first restores the
        // known-absent backend, then settles the still-pending shim at 45.
        XCTAssertEqual(value["status"], "rolled-back", value["message"].string); XCTAssertEqual(value["safeToInstall"], false)
        XCTAssertGreaterThanOrEqual(f.time, 45); XCTAssertLessThan(f.time, 60)
        let restored = f.commands.filter { $0[0] == "bootstrap" }.map { URL(fileURLWithPath: $0[2]).deletingPathExtension().lastPathComponent }
        XCTAssertEqual(restored, f.labels); XCTAssertTrue(f.stops.isEmpty)
    }
    func testPostIssueForeignMalformedNoPIDAndInspectionErrorsRemainIncompleteWithoutKill() async throws {
        for mode in 0..<7 {
            let f = try InstallRetirementFixture(); defer { f.cleanup() }; f.bootoutDelay = 60
            var dependencies = f.updateDependencies; let command = dependencies.system.command
            dependencies.system.command = { args, seconds in
                let value = try await command(args, seconds)
                guard args[0] == "print", args[1].hasSuffix(f.labels[0]), f.issuedTimes.count == 2 else { return value }
                switch mode {
                case 0: return f.output(0, value.output.replacingOccurrences(of: " pid = 111", with: " pid = 999"))
                case 1: return f.output(0, value.output.replacingOccurrences(of: "UNIAPI_ROOT => " + f.paths.root.path, with: "UNIAPI_ROOT => /foreign"))
                case 2: return f.output(0, value.output.replacingOccurrences(of: f.definition(f.labels[0]).path, with: f.home.appendingPathComponent("foreign.plist").path))
                case 3: return f.output(113, "", "Could not find service \"" + f.labels[0] + "\" in domain for user gui: 999")
                case 4: return f.output(0, value.output.replacingOccurrences(of: " pid = 111\n", with: ""))
                case 5: return f.output(1, "", "permission denied")
                default: return f.output(113, "", "Bad request.\nCould not find service \"" + f.labels[0] + "\" in domain for user gui: \(getuid())\nextra error")
                }
            }
            let value = await Self.update(f, dependencies: dependencies)
            XCTAssertEqual(value["status"], "recovery-incomplete", "mode \(mode)")
            XCTAssertFalse(f.signals.contains { $0.1 == SIGKILL }); XCTAssertFalse(f.commands.contains { $0[0] == "bootstrap" })
            XCTAssertEqual(f.pids[f.labels[0]], 111); XCTAssertEqual(f.pids[f.labels[1]], 222)
        }
    }
    func testNativeHealthIdentityAndReadyStateMustMatchBeforePause() async throws {
        for mode in 0..<6 {
            let f = try InstallRetirementFixture(); defer { f.cleanup() }; f.badNativeHealth = mode
            let value = await Self.update(f)
            XCTAssertEqual(value["status"], "refused"); XCTAssertTrue(f.signals.isEmpty)
            XCTAssertFalse(f.commands.contains { $0[0] == "bootout" })
        }
    }
    func testCleanupCompatibilityUsesCommonRecoveryButRestoredServicesAreNeverSafeToReplace() async throws {
        let f = try InstallRetirementFixture(); defer { f.cleanup() }; f.failShim = true; f.failShimAfterRemoval = true
        let value = await f.retire()
        XCTAssertEqual(value["transactionStatus"], "rolled-back", value["message"].string); XCTAssertEqual(value["status"], "refused", value["message"].string)
        XCTAssertEqual(value["safeToRestore"], false); XCTAssertEqual(value["partialRecovery"], false)
        XCTAssertEqual(f.commands.filter { $0[0] == "bootstrap" }.count, 2)
    }
    func testDefaultLegacyRoleStillRejectsNativeKernelRoles() async throws {
        let f = try InstallRetirementFixture(); defer { f.cleanup() }
        let context = try NativeInstallRetirementSystem(paths: f.paths, application: f.app, instance: f.nonce, dependencies: f.dependencies, gui: f.guiReader, nativeStatus: f.statusReader)
        var io = context.makeIO(); io.role = .legacy
        let value = await NativeLegacyRetirement.prepare(paths: f.paths, io: io)
        XCTAssertEqual(value["status"], "refused"); XCTAssertTrue(f.signals.isEmpty)
        let registration = try await io.registration(f.labels[0], 1)
        XCTAssertFalse(NativeLegacyRetirement.belongs(try XCTUnwrap(f.nodes[111]), service: try XCTUnwrap(registration)))
    }
    func testNativePortSettlementIsControlFreeAndMayOutlastTheServiceBudget() async throws {
        let f = try InstallRetirementFixture(); defer { f.cleanup() }; f.bootoutDelay = 20
        let probe = NativeUpdatePortProbe(); var dependencies = f.updateDependencies
        dependencies.system.absent = {
            guard f.pids.isEmpty else { throw NativeFailure("Port phase started before explicit label absence") }
            if probe.start == nil { probe.start = f.time }
            probe.calls += 1
            guard probe.calls <= 2000 else { throw NativeFailure("Native port fixture watchdog") }
            if f.time - probe.start! < 16 { throw NativeOwnershipBindFailure(port: 8780, code: EADDRINUSE) }
        }
        let value = await Self.update(f, dependencies: dependencies)
        XCTAssertEqual(value["status"], "retired"); XCTAssertGreaterThanOrEqual(f.time, 36); XCTAssertLessThan(f.time, 50)
        XCTAssertEqual(f.bootoutTimes.count, 2); XCTAssertEqual(f.signals.filter { $0.1 == SIGSTOP }.count, 2)
        XCTAssertFalse(f.signals.contains { $0.1 == SIGKILL }); XCTAssertGreaterThan(probe.calls, 1)
    }
    func testProductionSettlementRequiresLeaseAndExactIssuedRecordWithoutKernelReinspection() async throws {
        let f = try InstallRetirementFixture(); defer { f.cleanup() }; f.bootoutDelay = 20; f.throwDyingIdentity = true
        let context = try NativeInstallRetirementSystem(paths: f.paths, application: f.app, instance: f.nonce, dependencies: f.dependencies, gui: f.guiReader, nativeStatus: f.statusReader)
        let io = context.makeIO(), record = try await io.registration(f.labels[0], 1)
        let captured = try XCTUnwrap(record), observe = try XCTUnwrap(io.settlement)
        do { _ = try await observe(captured, 1); XCTFail("Observation without a lease must refuse") } catch {}
        let lease = try io.exclusive(); defer { lease.close() }
        do { _ = try await observe(captured, 1); XCTFail("Observation before issuance must refuse") } catch {}
        try await io.bootout(captured, 1)
        let pending = try await observe(captured, 1)
        XCTAssertEqual(pending, .capturedRegistrationStillVisible); XCTAssertEqual(f.dyingIdentityQueries, 0)
        lease.close()
        do { _ = try await observe(captured, 1); XCTFail("Observation after release must refuse") } catch {}
    }
    func testRetainedAccessoryWindowAndOnlyKnownHeadlessCallerAreAdmitted() throws {
        let f = try InstallRetirementFixture(); defer { f.cleanup() }
        var snapshot = try f.guiReader()
        // Main constructs a window even for --background. An offscreen retained
        // window plus accessory policy is the actual supported background state.
        XCTAssertNoThrow(try NativeUpdateGUIAdmission.check(snapshot, application: f.app, managedPID: 111))
        let caller = NativeUpdateGUIAdmission.Application(pid: getpid(), bundle: f.app, executable: f.binary(f.labels[0]), identifier: "app.devved.uniapi.hub", activation: .prohibited)
        snapshot = .init(applications: snapshot.applications + [caller], windows: snapshot.windows)
        XCTAssertNoThrow(try NativeUpdateGUIAdmission.check(snapshot, application: f.app, managedPID: 111))
        snapshot.callerIsHeadless = false
        XCTAssertThrowsError(try NativeUpdateGUIAdmission.check(snapshot, application: f.app, managedPID: 111))
    }
    func testCGWindowOptionalOffscreenKeyUsesSDKContractAndMalformedMetadataRefuses() throws {
        var raw: [String: Any] = [kCGWindowOwnerPID as String: NSNumber(value: 111), kCGWindowLayer as String: NSNumber(value: 0)]
        XCTAssertEqual(try NativeUpdateGUIAdmission.window(raw).onScreen, false)
        raw[kCGWindowIsOnscreen as String] = NSNumber(value: true)
        XCTAssertEqual(try NativeUpdateGUIAdmission.window(raw).onScreen, true)
        raw[kCGWindowIsOnscreen as String] = "unknown"
        XCTAssertThrowsError(try NativeUpdateGUIAdmission.window(raw))
        raw.removeValue(forKey: kCGWindowIsOnscreen as String); raw.removeValue(forKey: kCGWindowLayer as String)
        XCTAssertThrowsError(try NativeUpdateGUIAdmission.window(raw))
    }
    func testExplicitInfiniteMalformedAndUnsettleableExitGraceRefusesBeforePause() async throws {
        let values: [Any] = [0, -1, 30, 31, NSNumber(value: true), "infinite", 1.5, 5]
        for (index, grace) in values.enumerated() {
            let f = try InstallRetirementFixture(); defer { f.cleanup() }
            try Self.changeDefinition(f, label: f.labels[1]) { $0["ExitTimeOut"] = grace }
            let value = await NativeServiceUpdate.prepare(paths: f.paths, application: f.app, dependencies: f.updateDependencies)
            XCTAssertEqual(value["canPrepare"], .bool(index == values.count - 1), "case \(index)")
            if index != values.count - 1 {
                let retired = await Self.update(f)
                XCTAssertEqual(retired["status"], "refused")
            }
            XCTAssertTrue(f.signals.isEmpty); XCTAssertFalse(f.commands.contains { $0[0] == "bootout" })
        }
        // A permitted explicit grace can cease to fit after slow pre-command
        // validation. It must still refuse issuance and resume both old roots.
        let f = try InstallRetirementFixture(); defer { f.cleanup() }
        try Self.changeDefinition(f, label: f.labels[0]) { $0["ExitTimeOut"] = 20 }
        var dependencies = f.updateDependencies; let command = dependencies.system.command
        dependencies.system.command = { args, seconds in
            let value = try await command(args, seconds)
            if f.stops.count == 2 && ["print", "print-disabled"].contains(args[0]) { f.time += 6 }
            return value
        }
        let value = await Self.update(f, dependencies: dependencies)
        XCTAssertEqual(value["status"], "refused"); XCTAssertTrue(f.stops.isEmpty)
        XCTAssertFalse(f.commands.contains { $0[0] == "bootout" }); XCTAssertEqual(f.pids[f.labels[0]], 111)
    }
    func testOnscreenMenuModalAndFloatingWindowsRefuseButBackgroundStatusGlyphAdmits() async throws {
        for mode in 6...9 {
            let f = try InstallRetirementFixture(); defer { f.cleanup() }; f.guiMode = mode
            let value = await NativeServiceUpdate.prepare(paths: f.paths, application: f.app, dependencies: f.updateDependencies)
            XCTAssertEqual(value["canPrepare"], .bool(mode == 9), "case \(mode)")
            XCTAssertTrue(f.signals.isEmpty); XCTAssertFalse(f.commands.contains { $0[0] == "bootout" })
        }
        let f = try InstallRetirementFixture(); defer { f.cleanup() }; f.guiMode = 9
        let accepted = try f.guiReader()
        for bounds in [CGRect(x: 1200, y: 24, width: 100, height: 24), CGRect(x: 1200, y: 0, width: 100, height: 240), CGRect(x: 1200, y: 0, width: 300, height: 24)] {
            let panel = NativeUpdateGUIAdmission.Window(pid: 111, layer: 25, onScreen: true, bounds: bounds)
            let snapshot = NativeUpdateGUIAdmission.Snapshot(applications: accepted.applications, windows: [panel], displayBounds: accepted.displayBounds)
            XCTAssertThrowsError(try NativeUpdateGUIAdmission.check(snapshot, application: f.app, managedPID: 111))
        }
        let unknown = NativeUpdateGUIAdmission.Window(pid: 111, layer: 25, onScreen: true)
        XCTAssertThrowsError(try NativeUpdateGUIAdmission.check(.init(applications: accepted.applications, windows: [unknown], displayBounds: accepted.displayBounds), application: f.app, managedPID: 111))
        // A menu appearing after the first STOP also uses the fresh work proof.
        f.guiMode = 6; f.guiAfterPause = true
        let value = await Self.update(f)
        XCTAssertEqual(value["status"], "refused"); XCTAssertTrue(f.stops.isEmpty)
        XCTAssertFalse(f.commands.contains { $0[0] == "bootout" })
    }

    private static func update(_ f: InstallRetirementFixture, dependencies: NativeUpdateDependencies? = nil) async -> JSONValue {
        do { return await NativeServiceUpdate.retire(paths: f.paths, application: f.app, instance: f.nonce, expectedDefinitionHashes: try f.hashes(), dependencies: dependencies ?? f.updateDependencies) }
        catch { XCTFail(error.localizedDescription); return .null }
    }
    private static func changeDefinition(_ f: InstallRetirementFixture, label: String, _ mutate: (inout [String: Any]) -> Void) throws {
        let file = f.definition(label)
        var value = try XCTUnwrap(try PropertyListSerialization.propertyList(from: Data(contentsOf: file), format: nil) as? [String: Any])
        mutate(&value)
        try NativeFile.writeAtomic(try PropertyListSerialization.data(fromPropertyList: value, format: .xml, options: 0), to: file)
    }
}

private final class NativeUpdatePortProbe: @unchecked Sendable { var start: Double?; var calls = 0 }
