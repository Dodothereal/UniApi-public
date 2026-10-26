import XCTest
import Darwin
@testable import UniApiCore

final class LegacyRetirementSystemTests: XCTestCase {
    func testConstructionAndReadOnlyPrepareCreateNoLockBackupOrControls() async throws {
        let f = try LegacySystemFixture(); defer { f.cleanup() }
        let io = try NativeLegacyRetirementSystem.make(paths: f.readOnlyPaths, dependencies: f.dependencies)
        XCTAssertTrue(f.commands.isEmpty)
        let result = await NativeLegacyRetirement.prepare(paths: f.readOnlyPaths, io: io)
        XCTAssertEqual(result["status"], "prepared"); XCTAssertTrue(f.signals.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: f.base.path)); XCTAssertEqual(f.healthCalls, 0)
        XCTAssertTrue(f.commands.allSatisfy { ["print", "print-disabled"].contains($0[0]) })
        XCTAssertThrowsError(try io.exclusive())
        XCTAssertThrowsError(try io.freeze(f.identities[111]!)); XCTAssertThrowsError(try io.resume(f.identities[111]!)); XCTAssertThrowsError(try io.terminate(f.identities[111]!))
        XCTAssertTrue(f.signals.isEmpty)
    }
    func testLoadedProofRejectsDomainProgramArgumentsEnvironmentUIDAndDirectory() async throws {
        for mode in 0..<7 {
            let f = try LegacySystemFixture(); defer { f.cleanup() }; f.badProof = mode
            let result = await NativeLegacyRetirement.prepare(paths: f.paths, io: try f.io())
            XCTAssertEqual(result["status"], "refused", "mode \(mode)"); XCTAssertTrue(f.signals.isEmpty)
        }
    }
    func testProtectedDefinitionRejectsLinksFIFOAndWritableFiles() async throws {
        for mode in 0..<4 {
            let f = try LegacySystemFixture(); defer { f.cleanup() }
            let path = f.definition(f.server)
            switch mode {
            case 0:
                let other = f.home.appendingPathComponent("other.plist"); try FileManager.default.copyItem(at: path, to: other)
                try FileManager.default.removeItem(at: path); try FileManager.default.createSymbolicLink(at: path, withDestinationURL: other)
            case 1: XCTAssertEqual(link(path.path, f.home.appendingPathComponent("linked.plist").path), 0)
            case 2: try FileManager.default.removeItem(at: path); XCTAssertEqual(mkfifo(path.path, 0o600), 0)
            default: XCTAssertEqual(chmod(path.path, 0o666), 0)
            }
            let result = await NativeLegacyRetirement.prepare(paths: f.paths, io: try f.io())
            XCTAssertEqual(result["status"], "refused"); XCTAssertTrue(f.signals.isEmpty)
        }
    }
    func testPerUserLockCoversDifferentRootsAndRejectsLinkedLockFile() throws {
        let f = try LegacySystemFixture(); defer { f.cleanup() }
        let a = try f.io(), b = try NativeLegacyRetirementSystem.make(paths: .init(root: f.home.appendingPathComponent("Other"), home: f.home), dependencies: f.dependencies)
        let lease = try a.exclusive(); XCTAssertThrowsError(try b.exclusive()); lease.close()
        let second = try b.exclusive(); second.close()
        let lock = f.base.appendingPathComponent("transfer.lock"); try FileManager.default.removeItem(at: lock)
        try FileManager.default.createSymbolicLink(at: lock, withDestinationURL: f.definition(f.server))
        XCTAssertThrowsError(try a.exclusive())
    }
    func testLockPathReplacementDoesNotPermitControlsUnderAStaleLease() throws {
        let f = try LegacySystemFixture(); defer { f.cleanup() }
        let io = try f.io(), lease = try io.exclusive(); defer { lease.close() }
        let path = f.base.appendingPathComponent("transfer.lock")
        try FileManager.default.removeItem(at: path); try Data().write(to: path); XCTAssertEqual(chmod(path.path, 0o600), 0)
        XCTAssertThrowsError(try io.freeze(f.identities[111]!)); XCTAssertTrue(f.signals.isEmpty)
    }
    func testExplicitRetireBootsOutOnlyVerifiedJobsAndKeepsOriginalDefinitions() async throws {
        let f = try LegacySystemFixture(); defer { f.cleanup() }
        let before = try Data(contentsOf: f.definition(f.server))
        let result = await NativeLegacyRetirement.retire(paths: f.paths, io: try f.io())
        XCTAssertEqual(result["status"], "retired"); XCTAssertEqual(result["safeToInstall"], true)
        XCTAssertEqual(f.signals.filter { $0.1 == SIGSTOP }.map(\.0), [111, 112, 222])
        XCTAssertEqual(f.commands.filter { $0[0] == "bootout" }.count, 2)
        XCTAssertEqual(try Data(contentsOf: f.definition(f.server)), before)
        XCTAssertTrue(f.commands.allSatisfy { !["enable", "disable", "kickstart"].contains($0[0]) })
    }
    func testPartialBootoutRecoversFromPrivateSnapshotWithFreshOwnedListener() async throws {
        let f = try LegacySystemFixture(); defer { f.cleanup() }; f.failShim = true; f.delayChild = true
        let result = await NativeLegacyRetirement.retire(paths: f.paths, io: try f.io())
        XCTAssertEqual(result["status"], "rolled-back"); XCTAssertEqual(f.healthCalls, 1)
        let restore = try XCTUnwrap(f.commands.first { $0[0] == "bootstrap" })
        XCTAssertTrue(restore[2].hasPrefix(f.base.path + "/")); XCTAssertNotEqual(restore[2], f.definition(f.server).path)
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: restore[2])), try Data(contentsOf: f.definition(f.server)))
        let again = await NativeLegacyRetirement.prepare(paths: f.paths, io: try f.io())
        XCTAssertEqual(again["status"], "prepared")
    }
    func testRecoveryDefinitionEditDisableAndWrongHealthPIDRemainUnconfirmed() async throws {
        for mode in 0..<3 {
            let f = try LegacySystemFixture(); defer { f.cleanup() }; f.failShim = true
            f.editDuringFailure = mode == 0; f.disableDuringFailure = mode == 1; f.wrongHealthPID = mode == 2
            let result = await NativeLegacyRetirement.retire(paths: f.paths, io: try f.io())
            XCTAssertEqual(result["status"], "recovery-incomplete", "mode \(mode)"); XCTAssertEqual(result["safeToInstall"], false)
            XCTAssertEqual(f.commands.filter { $0[0] == "bootout" }.count, 1)
            XCTAssertEqual(f.preCommandRefusals, [f.shim])
            if mode < 2 { XCTAssertFalse(f.commands.contains { $0[0] == "bootstrap" }) }
        }
    }
    func testMissingRegistrationIsDistinctFromInspectionFailureAndDisabledState() async throws {
        for mode in 0..<3 {
            let f = try LegacySystemFixture(); defer { f.cleanup() }
            var d = f.dependencies
            if mode == 0 {
                f.pids.removeAll(); f.advisory = .init(legacyPresent: false, activeJobs: 0, activeCode: 0, legacyWindowRunning: false)
            } else if mode == 1 { d.command = { _, _ in .init(status: 1, stdout: Data(), stderr: Data("permission denied".utf8)) } }
            else { f.disabled = true }
            let io = try NativeLegacyRetirementSystem.make(paths: f.paths, dependencies: d)
            let result = await NativeLegacyRetirement.prepare(paths: f.paths, io: io)
            XCTAssertEqual(result["status"], mode == 0 ? "prepared" : "refused"); XCTAssertTrue(f.signals.isEmpty)
        }
    }
    func testRegistrationRecognizesExactAbsentDiagnosticsForCanonicalOwner() async throws {
        for status in [Int32(3), 113] {
            for spaced in [true, false] {
                for preamble in [true, false] {
                    let f = try LegacySystemFixture(); defer { f.cleanup() }; f.pids.removeAll()
                    let domain = "gui:" + (spaced ? " " : "") + String(f.owner)
                    let target = "Could not find service \"\(f.server)\" in domain for user " + domain
                    f.absentResult = f.output(status, " \t\r\n", "\r\n " + (preamble ? "Bad request. \r\n\t" : "") + target + " \n\t")
                    let io = try NativeLegacyRetirementSystem.make(paths: f.paths, dependencies: f.dependencies)
                    let value = try await io.registration(f.server, 1)
                    XCTAssertNil(value, "status \(status), spaced \(spaced), preamble \(preamble)")
                    XCTAssertEqual(f.commands, [["print", "gui/\(f.owner)/\(f.server)"]])
                    XCTAssertTrue(f.signals.isEmpty); XCTAssertEqual(f.healthCalls, 0)
                    XCTAssertFalse(FileManager.default.fileExists(atPath: f.base.path))
                }
            }
        }
    }
    func testRegistrationRejectsMismatchedOrAmbiguousAbsenceDiagnostics() async throws {
        let f = try LegacySystemFixture(); defer { f.cleanup() }; f.pids.removeAll()
        let io = try NativeLegacyRetirementSystem.make(paths: f.paths, dependencies: f.dependencies)
        for (name, result) in invalidAbsenceResults(f) {
            f.absentResult = result
            do { _ = try await io.registration(f.server, 1); XCTFail("Invalid absence accepted: \(name)") }
            catch { XCTAssertEqual(error.localizedDescription, result.status == 0 ? "Loaded legacy domain or label differs" : "Legacy registration inspection failed", name) }
        }
        XCTAssertTrue(f.commands.allSatisfy { $0 == ["print", "gui/\(f.owner)/\(f.server)"] })
        XCTAssertTrue(f.signals.isEmpty); XCTAssertEqual(f.healthCalls, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: f.base.path))
    }
    func testLoadedStatusZeroWithoutPIDRemainsInspectionFailure() async throws {
        let f = try LegacySystemFixture(); defer { f.cleanup() }
        var dependencies = f.dependencies
        let command = dependencies.command
        dependencies.command = { arguments, seconds in
            if arguments == ["print", "gui/\(f.owner)/\(f.server)"] {
                f.commands.append(arguments)
                let loaded = f.printJob(f.server).replacingOccurrences(of: " pid = 111\n", with: "")
                return f.output(0, loaded, "Bad request.\nCould not find service \"\(f.server)\" in domain for user gui: \(f.owner)\n")
            }
            return try await command(arguments, seconds)
        }
        let io = try NativeLegacyRetirementSystem.make(paths: f.paths, dependencies: dependencies)
        do { _ = try await io.registration(f.server, 1); XCTFail("Loaded job without PID accepted") }
        catch { XCTAssertEqual(error.localizedDescription, "Loaded legacy job has no verified running instance") }
        let result = await NativeLegacyRetirement.retire(paths: f.paths, io: io)
        XCTAssertEqual(result["status"], "refused"); XCTAssertEqual(result["safeToInstall"], false)
        XCTAssertFalse(f.commands.contains { ["bootout", "bootstrap"].contains($0[0]) })
        XCTAssertTrue(f.signals.isEmpty); XCTAssertEqual(f.healthCalls, 0)
        XCTAssertEqual(f.pids[f.server], 111); XCTAssertEqual(f.pids[f.shim], 222)
    }
    func testInvalidPostBootoutAbsenceRemainsIncompleteWithoutBootstrapOrKill() async throws {
        let cases = try LegacySystemFixture(); defer { cases.cleanup() }
        for (name, invalid) in invalidAbsenceResults(cases) {
            let f = try LegacySystemFixture(); defer { f.cleanup() }; f.absentResult = invalid
            let definitions = try [f.server, f.shim].map { try Data(contentsOf: f.definition($0)) }
            let io = try NativeLegacyRetirementSystem.make(paths: f.paths, dependencies: f.dependencies)
            let result = await NativeLegacyRetirement.retire(paths: f.paths, io: io)
            XCTAssertEqual(result["status"], "recovery-incomplete", name)
            XCTAssertEqual(result["safeToInstall"], false, name)
            XCTAssertEqual(f.commands.filter { $0[0] == "bootout" }, [["bootout", "gui/\(f.owner)/\(f.server)"]], name)
            XCTAssertFalse(f.commands.contains { $0[0] == "bootstrap" }, name)
            XCTAssertFalse(f.signals.contains { $0.1 == SIGKILL }, name)
            XCTAssertEqual(f.healthCalls, 0, name); XCTAssertNil(f.pids[f.server], name)
            XCTAssertEqual(f.pids[f.shim], 222, name)
            XCTAssertEqual(try [f.server, f.shim].map { try Data(contentsOf: f.definition($0)) }, definitions, name)
        }
    }
    private func invalidAbsenceResults(_ f: LegacySystemFixture) -> [(String, NativeProcessResult)] {
        let target = "Could not find service \"\(f.server)\" in domain for user gui: \(f.owner)"
        let compact = "Could not find service \"\(f.server)\" in domain for user gui:\(f.owner)"
        return [
            ("wrong UID", f.output(113, "", "Could not find service \"\(f.server)\" in domain for user gui: \(f.owner + 1)")),
            ("spaced UID prefix", f.output(113, "", target + "0")),
            ("compact UID prefix", f.output(113, "", compact + "0")),
            ("noncanonical UID", f.output(113, "", "Could not find service \"\(f.server)\" in domain for user gui: 0\(f.owner)")),
            ("extra domain space", f.output(113, "", "Could not find service \"\(f.server)\" in domain for user gui:  \(f.owner)")),
            ("wrong label", f.output(113, "", "Could not find service \"\(f.shim)\" in domain for user gui: \(f.owner)")),
            ("label prefix", f.output(113, "", "Could not find service \"\(f.server).other\" in domain for user gui: \(f.owner)")),
            ("missing label quotes", f.output(113, "", "Could not find service \(f.server) in domain for user gui: \(f.owner)")),
            ("unrecognized status", f.output(1, "", target)),
            ("success is not absence", f.output(0, "", target)),
            ("nonblank stdout", f.output(113, "unexpected output\n", target)),
            ("invalid UTF8 stdout", .init(status: 113, stdout: Data([0xff]), stderr: Data(target.utf8))),
            ("empty stderr", f.output(113, "", " \t\r\n")),
            ("preamble only", f.output(113, "", "Bad request.")),
            ("extra error", f.output(113, "", "Bad request.\n" + target + "\nPermission denied")),
            ("extra compact error", f.output(113, "", compact + "\nPermission denied")),
            ("extra leading error", f.output(113, "", "Permission denied\n" + target)),
            ("duplicate target", f.output(113, "", target + "\n" + target)),
            ("reversed lines", f.output(113, "", target + "\nBad request.")),
            ("duplicate preamble", f.output(113, "", "Bad request.\nBad request.\n" + target)),
            ("target suffix", f.output(113, "", target + "; permission denied")),
            ("target prefix", f.output(113, "", "warning: " + target)),
            ("wrong domain", f.output(113, "", "Could not find service \"\(f.server)\" in domain for user system: \(f.owner)")),
            ("embedded NUL", f.output(113, "", target + "\0"))
        ]
    }
    func testHealthPIDRequiresANumberWithExactIntegralListenerIdentity() async throws {
        for pid in [JSONValue.string("1112"), .number(1112.5), .null] {
            let f = try LegacySystemFixture(); defer { f.cleanup() }; f.failShim = true; f.healthPID = pid
            let result = await NativeLegacyRetirement.retire(paths: f.paths, io: try f.io())
            XCTAssertEqual(result["status"], "recovery-incomplete"); XCTAssertEqual(result["safeToInstall"], false)
        }
    }
    func testLegacyShimWithoutHealthPIDRequiresItsRestoredKernelListener() async throws {
        for missing in [false, true] {
            let f = try LegacySystemFixture(); defer { f.cleanup() }
            f.failShim = true; f.failShimAfter = true; f.restoredShimListenerMissing = missing
            let result = await NativeLegacyRetirement.retire(paths: f.paths, io: try f.io())
            XCTAssertEqual(result["status"], missing ? "recovery-incomplete" : "rolled-back")
            XCTAssertEqual(f.shimHealthCalls, missing ? 0 : 1)
        }
    }
    func testBootoutValidationBeforeCommandReportsNotIssued() async throws {
        for changedDefinition in [false, true] {
            let f = try LegacySystemFixture(); defer { f.cleanup() }
            let io = try f.io(), loaded = try await io.registration(f.server, 1)
            let record = try XCTUnwrap(loaded)
            var lease: NativeLegacyRetirementLease?
            if changedDefinition { lease = try io.exclusive(); try Data("invalid private definition".utf8).write(to: f.definition(f.server)) }
            defer { lease?.close() }
            do { try await io.bootout(record, 1); XCTFail("Pre-command validation was accepted") }
            catch let failure as NativeLegacyBootoutFailure { XCTAssertEqual(failure.disposition, .notIssued) }
            catch { XCTFail("Missing typed pre-command disposition: \(error)") }
            XCTAssertFalse(f.commands.contains { $0[0] == "bootout" }); XCTAssertTrue(f.signals.isEmpty)
        }
    }
    func testBootoutCommandFailureCancellationAndDeadlineReportMayHaveApplied() async throws {
        for mode in 0..<4 {
            let f = try LegacySystemFixture(); defer { f.cleanup() }
            var dependencies = f.dependencies
            let command = dependencies.command
            dependencies.command = { arguments, seconds in
                guard arguments[0] == "bootout" else { return try await command(arguments, seconds) }
                f.commands.append(arguments)
                switch mode {
                case 0: return f.output(1)
                case 1: throw NativeFailure("Fixture command transport failed after issuance")
                case 2: withUnsafeCurrentTask { $0?.cancel() }; return f.output()
                default: f.time += 2; return f.output()
                }
            }
            let io = try NativeLegacyRetirementSystem.make(paths: f.paths, dependencies: dependencies)
            let lease = try io.exclusive(); defer { lease.close() }
            let loaded = try await io.registration(f.server, 1), record = try XCTUnwrap(loaded)
            let failure = await Task { () -> NativeLegacyBootoutFailure? in
                do { try await io.bootout(record, 1); XCTFail("Uncertain post-command outcome accepted"); return nil }
                catch let failure as NativeLegacyBootoutFailure { return failure }
                catch { XCTFail("Missing post-command disposition: \(error)"); return nil }
            }.value
            XCTAssertEqual(failure?.disposition, .mayHaveApplied, "mode \(mode)")
            XCTAssertEqual(f.commands.filter { $0[0] == "bootout" }.count, 1)
            XCTAssertFalse(f.commands.contains { $0[0] == "bootstrap" }); XCTAssertTrue(f.signals.isEmpty)
        }
    }
    func testProductionAdapterSettlesDelayedLoadedPrintBeforeRetired() async throws {
        let f = try LegacySystemFixture(); defer { f.cleanup() }; f.bootoutDelayReads = 2
        let value = await NativeLegacyRetirement.retire(paths: f.paths, io: try f.io())
        XCTAssertEqual(value["status"], "retired"); XCTAssertEqual(value["safeToInstall"], true)
        XCTAssertEqual(f.delayedOldReads, 4); XCTAssertEqual(f.pauses, [0.02, 0.02, 0.02, 0.02])
        XCTAssertTrue(f.pids.isEmpty); XCTAssertTrue(f.identities.isEmpty)
        XCTAssertEqual(f.commands.filter { $0[0] == "bootout" }.count, 2)
        XCTAssertFalse(f.commands.contains { $0[0] == "bootstrap" })
    }
    func testProductionAdapterCommandFailureRestoresRemovedLabelAndReportsPendingRecoveryIncomplete() async throws {
        let f = try LegacySystemFixture(); defer { f.cleanup() }
        f.failShim = true; f.failShimAfter = false
        // Bypass io()'s explicit pre-command refusal: this exercises Context's
        // real nonzero command result followed by the coordinator's recovery.
        let io = try NativeLegacyRetirementSystem.make(paths: f.paths, dependencies: f.dependencies)
        let value = await NativeLegacyRetirement.retire(paths: f.paths, io: io)
        XCTAssertEqual(value["status"], "recovery-incomplete"); XCTAssertEqual(value["safeToInstall"], false)
        XCTAssertTrue(f.preCommandRefusals.isEmpty)
        XCTAssertEqual(f.commands.filter { $0[0] == "bootout" }.count, 2)
        XCTAssertEqual(f.commands.filter { $0[0] == "bootstrap" }.count, 1)
        XCTAssertEqual(f.pids[f.server], 1111); XCTAssertEqual(f.identities[1111]?.bornSeconds, 200)
        XCTAssertEqual(f.healthCalls, 1); XCTAssertEqual(f.shimHealthCalls, 0)
        XCTAssertEqual(f.pids[f.shim], 222); XCTAssertEqual(f.identities[222]?.bornSeconds, 100)
        XCTAssertTrue(f.signals.contains { $0.0 == 222 && $0.1 == SIGCONT })
        XCTAssertFalse(f.signals.contains { $0.0 == 222 && $0.1 == SIGKILL })
    }
    func testProductionSettlementRetiresAfterDyingPIDMetadataThenExactAbsence() async throws {
        let f = try LegacySettlementObservationFixture(); defer { f.base.cleanup() }
        f.delays = [f.base.server: 2, f.base.shim: 2]
        let before = try [f.base.server, f.base.shim].map { try Data(contentsOf: f.base.definition($0)) }
        let io = try NativeLegacyRetirementSystem.make(paths: f.base.paths, dependencies: f.dependencies)
        XCTAssertNotNil(io.settlement)
        let result = await NativeLegacyRetirement.retire(paths: f.base.paths, io: io)
        XCTAssertEqual(result["status"], "retired"); XCTAssertEqual(result["safeToInstall"], true)
        XCTAssertEqual(f.pendingReads, [f.base.server: 2, f.base.shim: 2])
        XCTAssertEqual(f.explicitAbsences, [f.base.server, f.base.shim])
        XCTAssertTrue(f.dyingIdentityQueries.isEmpty); XCTAssertTrue(f.dyingDirectoryQueries.isEmpty)
        XCTAssertEqual(f.pythonQueries, 0); XCTAssertEqual(f.base.healthCalls, 0)
        XCTAssertEqual(f.base.pauses, [0.02, 0.02, 0.02, 0.02])
        XCTAssertTrue(f.base.pids.isEmpty); XCTAssertTrue(f.base.identities.isEmpty)
        XCTAssertFalse(f.base.commands.contains { $0[0] == "bootstrap" })
        XCTAssertEqual(try [f.base.server, f.base.shim].map { try Data(contentsOf: f.base.definition($0)) }, before)
    }
    func testProductionSettlementDoesNotRelaxFullRegistrationKernelProof() async throws {
        let f = try LegacySettlementObservationFixture(); defer { f.base.cleanup() }; f.delays[f.base.server] = 3
        let io = try NativeLegacyRetirementSystem.make(paths: f.base.paths, dependencies: f.dependencies)
        let loaded = try await io.registration(f.base.server, 1), record = try XCTUnwrap(loaded)
        let observe = try XCTUnwrap(io.settlement), reads = f.base.commands.count
        do { _ = try await observe(record, 1); XCTFail("Settlement without lease accepted") } catch {}
        let lease = try io.exclusive(); defer { lease.close() }
        do { _ = try await observe(record, 1); XCTFail("Settlement before command issuance accepted") } catch {}
        XCTAssertEqual(f.base.commands.count, reads)
        try await io.bootout(record, 1)
        do { _ = try await io.registration(f.base.server, 1); XCTFail("Full registration accepted a gone kernel PID") }
        catch { XCTAssertEqual(error.localizedDescription, "Fixture dying kernel PID must not be inspected") }
        XCTAssertEqual(f.dyingIdentityQueries, [111])
        let first = try await observe(record, 1), second = try await observe(record, 1), last = try await observe(record, 1)
        XCTAssertEqual(first, .capturedRegistrationStillVisible); XCTAssertEqual(second, .capturedRegistrationStillVisible)
        XCTAssertEqual(last, .absent); XCTAssertEqual(f.dyingIdentityQueries, [111])
        XCTAssertTrue(f.dyingDirectoryQueries.isEmpty); XCTAssertEqual(f.pythonQueries, 0)
        XCTAssertFalse(f.base.commands.contains { $0[0] == "bootstrap" })
        XCTAssertFalse(f.base.signals.contains { $0.1 == SIGKILL })
    }
    func testProductionSettlementRejectsForeignAndMalformedPendingEvidence() async throws {
        for fault in LegacySettlementObservationFixture.Fault.allCases {
            let f = try LegacySettlementObservationFixture(); defer { f.base.cleanup() }
            f.delays[f.base.server] = -1; f.fault = fault
            let io = try NativeLegacyRetirementSystem.make(paths: f.base.paths, dependencies: f.dependencies)
            let result = await NativeLegacyRetirement.retire(paths: f.base.paths, io: io)
            XCTAssertEqual(result["status"], "recovery-incomplete", fault.rawValue)
            XCTAssertEqual(result["safeToInstall"], false, fault.rawValue)
            XCTAssertEqual(f.base.commands.filter { $0[0] == "bootout" }.count, 1, fault.rawValue)
            XCTAssertFalse(f.base.commands.contains { $0[0] == "bootstrap" }, fault.rawValue)
            XCTAssertFalse(f.base.signals.contains { $0.1 == SIGKILL }, fault.rawValue)
            XCTAssertTrue(f.explicitAbsences.isEmpty, fault.rawValue)
            XCTAssertTrue(f.dyingIdentityQueries.isEmpty, fault.rawValue)
            XCTAssertTrue(f.dyingDirectoryQueries.isEmpty, fault.rawValue)
            XCTAssertEqual(f.pythonQueries, 0, fault.rawValue); XCTAssertEqual(f.base.healthCalls, 0, fault.rawValue)
        }
    }
    func testProductionSettlementHonorsDeadlineAndCancellation() async throws {
        for cancelled in [false, true] {
            let f = try LegacySettlementObservationFixture(); defer { f.base.cleanup() }
            f.delays[f.base.server] = cancelled ? 2 : -1
            let io = try NativeLegacyRetirementSystem.make(paths: f.base.paths, dependencies: f.dependencies)
            if cancelled {
                f.cancelPendingCommand = true
                let result = await Task { await NativeLegacyRetirement.retire(paths: f.base.paths, io: io) }.value
                XCTAssertEqual(result["status"], "rolled-back"); XCTAssertEqual(result["safeToInstall"], false)
                XCTAssertEqual(f.pendingReads[f.base.server], 2); XCTAssertEqual(f.base.pids[f.base.server], 1111)
                XCTAssertEqual(f.base.identities[1111]?.bornSeconds, 200); XCTAssertEqual(f.base.healthCalls, 1)
                XCTAssertEqual(f.cancelledForwardCommands, [["print-disabled", "gui/\(f.base.owner)"]])
                XCTAssertFalse(f.expectCancelledForwardDisabled)
                XCTAssertTrue(f.recoveryUncancelled); XCTAssertLessThanOrEqual(f.base.time, 0.02 + 0.000001)
                XCTAssertTrue(f.dyingIdentityQueries.isEmpty); XCTAssertTrue(f.dyingDirectoryQueries.isEmpty)
                XCTAssertEqual(f.pythonQueries, 0)
                continue
            }
            let lease = try io.exclusive(); defer { lease.close() }
            let loaded = try await io.registration(f.base.server, 1), record = try XCTUnwrap(loaded)
            try await io.bootout(record, 1)
            f.expirePendingCommand = true
            let observe = try XCTUnwrap(io.settlement)
            let refused = await Task { () -> Bool in
                do { _ = try await observe(record, 0.01); return false } catch { return true }
            }.value
            XCTAssertTrue(refused, "cancelled \(cancelled)")
            XCTAssertEqual(f.pendingReads[f.base.server], 1); XCTAssertTrue(f.base.pauses.isEmpty)
            XCTAssertLessThanOrEqual(f.base.time, 0.011 + 0.000001)
            XCTAssertTrue(f.dyingIdentityQueries.isEmpty); XCTAssertTrue(f.dyingDirectoryQueries.isEmpty)
            XCTAssertEqual(f.pythonQueries, 0); XCTAssertEqual(f.base.healthCalls, 0)
            XCTAssertFalse(f.base.commands.contains { $0[0] == "bootstrap" })
            XCTAssertTrue(f.base.signals.isEmpty)
        }
    }
    func testProductionSettlementForeverVisibleRemainsIncompleteWithinBudgets() async throws {
        let f = try LegacySettlementObservationFixture(); defer { f.base.cleanup() }; f.delays[f.base.server] = -1
        let io = try NativeLegacyRetirementSystem.make(paths: f.base.paths, dependencies: f.dependencies)
        let result = await NativeLegacyRetirement.retire(paths: f.base.paths, io: io, retirementDeadline: 0.06, rollbackDeadline: 0.06)
        XCTAssertEqual(result["status"], "recovery-incomplete"); XCTAssertEqual(result["safeToInstall"], false)
        XCTAssertGreaterThan(f.pendingReads[f.base.server, default: 0], 1)
        XCTAssertGreaterThanOrEqual(f.base.time, 0.12 - 0.000001); XCTAssertLessThanOrEqual(f.base.time, 0.12 + 0.000001)
        XCTAssertTrue(f.base.pauses.allSatisfy { $0 > 0 && $0 <= 0.02 })
        XCTAssertTrue(f.explicitAbsences.isEmpty); XCTAssertTrue(f.dyingIdentityQueries.isEmpty)
        XCTAssertFalse(f.base.commands.contains { $0[0] == "bootstrap" })
        XCTAssertFalse(f.base.signals.contains { $0.1 == SIGKILL }); XCTAssertEqual(f.base.healthCalls, 0)
    }
    func testProductionSettlementRestoresKnownRemovalBeforePendingAndRequiresFreshReadiness() async throws {
        for wrongHealth in [false, true] {
            let f = try LegacySettlementObservationFixture(); defer { f.base.cleanup() }
            f.delays[f.base.shim] = 2; f.cancelAfterBootout = f.base.shim; f.base.wrongHealthPID = wrongHealth
            let io = try NativeLegacyRetirementSystem.make(paths: f.base.paths, dependencies: f.dependencies)
            let result = await Task { await NativeLegacyRetirement.retire(paths: f.base.paths, io: io) }.value
            XCTAssertEqual(result["status"], wrongHealth ? "recovery-incomplete" : "rolled-back")
            XCTAssertEqual(result["safeToInstall"], false)
            let serverReady = try XCTUnwrap(f.events.firstIndex(of: "health:8780"))
            let pendingShim = try XCTUnwrap(f.events.firstIndex(of: "pending:" + f.base.shim))
            XCTAssertLessThan(serverReady, pendingShim)
            XCTAssertEqual(f.base.commands.filter { $0[0] == "bootstrap" }.count, 2)
            XCTAssertEqual(f.base.pids[f.base.server], 1111); XCTAssertEqual(f.base.pids[f.base.shim], 1222)
            XCTAssertEqual(f.base.identities[1111]?.bornSeconds, 200); XCTAssertEqual(f.base.identities[1222]?.bornSeconds, 200)
            XCTAssertEqual(f.base.healthCalls, 2); XCTAssertEqual(f.base.shimHealthCalls, 1)
            XCTAssertTrue(f.recoveryUncancelled); XCTAssertEqual(f.pendingReads[f.base.shim], 2)
            XCTAssertTrue(f.cancelledForwardCommands.isEmpty); XCTAssertFalse(f.expectCancelledForwardDisabled)
            XCTAssertTrue(f.dyingIdentityQueries.isEmpty); XCTAssertTrue(f.dyingDirectoryQueries.isEmpty)
            XCTAssertEqual(f.pythonQueries, 0)
        }
    }
    func testWorkCensusPrivateWALCopyIncludesQueuedAndWaitingAndNeverChangesSource() throws {
        let f = try LegacySystemFixture(); defer { f.cleanup() }
        try FileManager.default.createDirectory(at: f.paths.data, withIntermediateDirectories: true)
        let db = try NativeDatabase(url: f.paths.database)
        try db.executeScript("CREATE TABLE jobs(status TEXT); CREATE TABLE code_threads(status TEXT); INSERT INTO jobs VALUES ('done'),('queued'); INSERT INTO code_threads VALUES ('waiting'),('idle');")
        func stamps() throws -> [String] {
            try ["", "-wal", "-shm"].map { suffix in
                let path = URL(fileURLWithPath: f.paths.database.path + suffix), data = try Data(contentsOf: path)
                var s = stat(); XCTAssertEqual(lstat(path.path, &s), 0)
                return "\(s.st_ino):\(s.st_mtimespec.tv_sec):\(s.st_mtimespec.tv_nsec):\(s.st_ctimespec.tv_sec):\(s.st_ctimespec.tv_nsec):" + NativeLegacyRetirement.hash(data)
            }
        }
        let before = try stamps(), reader = NativeLegacyWorkReader(paths: f.paths)
        XCTAssertEqual(try reader.read().jobs, 1); XCTAssertEqual(try reader.read().code, 1)
        XCTAssertEqual(try stamps(), before)
        try db.execute("INSERT INTO jobs VALUES ('running')")
        XCTAssertEqual(try reader.read().jobs, 2)
        try db.execute("INSERT INTO jobs VALUES ('unknown-new-state')")
        XCTAssertThrowsError(try reader.read())
    }
    func testProbeSendsConnectionCloseAndCannotReturnBeforeTransportEOF() async throws {
        final class Requests: @unchecked Sendable { var values: [String] = [] }
        let requests = Requests(), wire = Data("HTTP/1.1 200 OK\r\nContent-Length: 11\r\n\r\n{\"ok\":true}".utf8)
        let value = try await NativeLegacyHTTPProbe.get(port: 9999, path: "/healthz", timeout: 1, exchange: { _, data, _ in
            requests.values.append(String(decoding: data, as: UTF8.self)); return .init(data: wire, reachedEOF: true)
        })
        XCTAssertEqual(value["ok"], true); XCTAssertTrue(requests.values[0].contains("Connection: close\r\n"))
        do { _ = try await NativeLegacyHTTPProbe.get(port: 9999, path: "/healthz", timeout: 1, exchange: { _, _, _ in .init(data: wire, reachedEOF: false) }); XCTFail("Unclosed probe accepted") } catch {}
        let chunked = Data("HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\nb\r\n{\"ok\":true}\r\n0\r\n\r\n".utf8)
        XCTAssertEqual(try NativeLegacyHTTPProbe.body(chunked), Data("{\"ok\":true}".utf8))
        XCTAssertThrowsError(try NativeLegacyHTTPProbe.body(Data("HTTP/1.1 200 OK\r\nContent-Length: 99\r\n\r\n{}".utf8)))
        let cancelled = Task { try await NativeLegacyHTTPProbe.get(port: 9999, path: "/healthz", timeout: 1, exchange: { _, _, _ in
            withUnsafeCurrentTask { $0?.cancel() }; return .init(data: wire, reachedEOF: true)
        }) }
        do { _ = try await cancelled.value; XCTFail("Cancelled probe accepted") } catch is CancellationError {}
    }
    func testRealDisposableProbeWaitsForEOFBeforeReturningAndClosesItsSocket() async throws {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw NativeFailure("Fixture socket failed") }; defer { close(fd) }
        var address = sockaddr_in(); address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size); address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        let bound = withUnsafePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
        guard bound == 0, listen(fd, 1) == 0 else { throw NativeFailure("Fixture ephemeral listener failed") }
        var size = socklen_t(MemoryLayout<sockaddr_in>.size)
        XCTAssertEqual(withUnsafeMutablePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &size) } }, 0)
        let port = UInt16(bigEndian: address.sin_port), completed = expectation(description: "Private fixture peer closes")
        DispatchQueue.global(qos: .utility).async {
            let peer = accept(fd, nil, nil); guard peer >= 0 else { completed.fulfill(); return }; defer { close(peer); completed.fulfill() }
            var request = [UInt8](repeating: 0, count: 4096); let count = recv(peer, &request, request.count, 0)
            XCTAssertGreaterThan(count, 0); XCTAssertTrue(String(decoding: request.prefix(max(0, count)), as: UTF8.self).contains("Connection: close\r\n"))
            let response = Data("HTTP/1.1 200 OK\r\nContent-Length: 11\r\n\r\n{\"ok\":true}".utf8)
            response.withUnsafeBytes { XCTAssertEqual(send(peer, $0.baseAddress, $0.count, 0), $0.count) }
            usleep(80_000)
        }
        let start = ProcessInfo.processInfo.systemUptime
        let result = try await NativeLegacyHTTPProbe.get(port: port, path: "/healthz", timeout: 2)
        XCTAssertEqual(result["ok"], true); XCTAssertGreaterThanOrEqual(ProcessInfo.processInfo.systemUptime - start, 0.07)
        await fulfillment(of: [completed], timeout: 2)
    }
}

/// Keep real Context/coordinator execution while launchd's old loaded record
/// outlives its kernel PID. No registration or settlement callback is replaced.
private final class LegacySettlementObservationFixture: @unchecked Sendable {
    enum Fault: String, CaseIterable {
        case foreignPID, definition, environment, sourcePath, arguments, program, routing, disabled
        case noPID, malformed, status, permission, wrongDomain, nonblankStdout
    }
    let base: LegacySystemFixture
    var delays: [String: Int] = [:], pending: [String: Int] = [:], loaded: [String: String] = [:]
    var pendingReads: [String: Int] = [:], explicitAbsences: [String] = [], events: [String] = []
    var gonePIDs = Set<Int32>(), dyingIdentityQueries: [Int32] = [], dyingDirectoryQueries: [Int32] = []
    var pythonQueries = 0, fault: Fault?, cancelPendingCommand = false, expirePendingCommand = false
    var cancelAfterBootout: String?, cancellationIssued = false, recoveryUncancelled = true
    var expectCancelledForwardDisabled = false, cancelledForwardCommands: [[String]] = []
    init() throws { base = try LegacySystemFixture() }

    func pendingResult(_ label: String) throws -> NativeProcessResult {
        var text = loaded[label]!
        let pid = base.pids[label]!
        switch fault {
        case .foreignPID: text = text.replacingOccurrences(of: " pid = \(pid)\n", with: " pid = 999\n")
        case .definition: try Data("Fixture changed original definition".utf8).write(to: base.definition(label))
        case .environment: text = text.replacingOccurrences(of: "UNIAPI_ROOT => \(base.root.path)", with: "UNIAPI_ROOT => /fixture/other-root")
        case .sourcePath: text = text.replacingOccurrences(of: "path = \(base.sources[label]!.path)", with: "path = \(base.home.appendingPathComponent("unowned.plist").path)")
        case .arguments: text = text.replacingOccurrences(of: base.argv(label).last!, with: "/fixture/other-main.ts")
        case .program: text = text.replacingOccurrences(of: "program = \(base.argv(label)[0])", with: "program = /fixture/other-program")
        case .routing: text = text.replacingOccurrences(of: " environment = {\n", with: " environment = {\n UNIAPI_PORT => 9999\n")
        case .disabled: base.disabled = true
        case .noPID: text = text.replacingOccurrences(of: " pid = \(pid)\n", with: "")
        case .malformed: text = "unsupported loaded record"
        case .status: return base.output(1, "", "Bad request.\nCould not find service \"\(label)\" in domain for user gui: \(base.owner)\n")
        case .permission: return base.output(113, "", "Permission denied")
        case .wrongDomain: text = text.replacingOccurrences(of: "gui/\(base.owner)/", with: "gui/\(base.owner + 1)/")
        case .nonblankStdout: return base.output(113, "unexpected stdout", "Bad request.\nCould not find service \"\(label)\" in domain for user gui: \(base.owner)\n")
        case nil: break
        }
        return base.output(0, text)
    }

    var dependencies: NativeLegacySystemDependencies {
        var d = base.dependencies
        let command = d.command, identity = d.identity, directory = d.directory, health = d.health, pause = d.pause
        d.command = { arguments, seconds in
            XCTAssertTrue(seconds.isFinite); XCTAssertGreaterThan(seconds, 0)
            if self.cancellationIssued {
                // The pending print cancels its forward task. Context still
                // validates disabled state before the coordinator observes it.
                let forward = self.expectCancelledForwardDisabled && Task.isCancelled
                    && arguments == ["print-disabled", "gui/\(self.base.owner)"]
                self.expectCancelledForwardDisabled = false
                if forward { self.cancelledForwardCommands.append(arguments) }
                else { self.recoveryUncancelled = self.recoveryUncancelled && !Task.isCancelled }
            }
            if arguments[0] == "print" {
                let label = String(arguments[1].split(separator: "/").last!)
                if let remaining = self.pending[label] {
                    if remaining != 0 {
                        if remaining > 0 { self.pending[label] = remaining - 1 }
                        self.base.commands.append(arguments); self.events.append("pending:" + label)
                        self.pendingReads[label, default: 0] += 1
                        let result = try self.pendingResult(label)
                        if self.expirePendingCommand { self.base.time += seconds + 0.001 }
                        if self.cancelPendingCommand {
                            self.cancelPendingCommand = false; self.cancellationIssued = true
                            self.expectCancelledForwardDisabled = true
                            withUnsafeCurrentTask { $0?.cancel() }
                        }
                        return result
                    }
                    self.pending[label] = nil; self.base.pids[label] = nil
                    self.explicitAbsences.append(label); self.events.append("absent:" + label)
                }
            }
            if arguments[0] == "bootout" {
                let label = String(arguments[1].split(separator: "/").last!)
                let pid = self.base.pids[label]!, loaded = self.base.printJob(label)
                let result = try await command(arguments, seconds)
                self.events.append("bootout:" + label)
                if result.status == 0, let delay = self.delays[label] {
                    self.pending[label] = delay; self.loaded[label] = loaded
                    // Restore only launchd's metadata, never a live kernel node.
                    self.base.pids[label] = pid; self.gonePIDs.insert(pid)
                    XCTAssertNil(self.base.identities[pid])
                }
                if label == self.cancelAfterBootout {
                    self.cancellationIssued = true; withUnsafeCurrentTask { $0?.cancel() }
                }
                return result
            }
            if arguments[0] == "bootstrap" { self.events.append("bootstrap:" + URL(fileURLWithPath: arguments[2]).deletingPathExtension().lastPathComponent) }
            return try await command(arguments, seconds)
        }
        d.identity = { pid in
            if self.gonePIDs.contains(pid) {
                self.dyingIdentityQueries.append(pid)
                throw NativeFailure("Fixture dying kernel PID must not be inspected")
            }
            return try identity(pid)
        }
        d.directory = { node in
            if self.gonePIDs.contains(node.pid) {
                self.dyingDirectoryQueries.append(node.pid)
                throw NativeFailure("Fixture dying CWD must not be inspected")
            }
            return try directory(node)
        }
        d.resolveSystemPython = { _ in
            self.pythonQueries += 1; throw NativeFailure("Fixture Python selector must not be invoked")
        }
        d.health = { port, seconds in
            if self.cancellationIssued { self.recoveryUncancelled = self.recoveryUncancelled && !Task.isCancelled }
            self.events.append("health:\(port)"); return try await health(port, seconds)
        }
        d.pause = { seconds in
            if self.cancellationIssued { self.recoveryUncancelled = self.recoveryUncancelled && !Task.isCancelled }
            try await pause(seconds)
        }
        return d
    }
}

private final class LegacySystemFixture: @unchecked Sendable {
    let home = FileManager.default.temporaryDirectory.appendingPathComponent("legacy-system-" + UUID().uuidString, isDirectory: true)
    let owner = getuid()
    var root: URL { home.appendingPathComponent("UniApi", isDirectory: true) }
    var paths: NativePaths { .init(root: root, home: home) }
    var readOnlyPaths: NativePaths { .init(root: root, home: home, readOnly: true) }
    var base: URL { home.appendingPathComponent("Library/Application Support/UniApi Native Transfer") }
    let server = NativeLegacyRetirement.labels[0], shim = NativeLegacyRetirement.labels[1]
    var commands: [[String]] = [], signals: [(Int32, Int32)] = [], time = 0.0, healthCalls = 0
    var advisory = NativeTransferCheck(legacyPresent: true, activeJobs: 0, activeCode: 0, legacyWindowRunning: false, shimPresent: true)
    var pids: [String: Int32] = [:], sources: [String: URL] = [:], identities: [Int32: NativeTransferIdentity] = [:], stops = Set<Int32>()
    var badProof: Int?, failShim = false, delayChild = false, restoredReads = 0, disabled = false
    var editDuringFailure = false, disableDuringFailure = false, wrongHealthPID = false
    var healthPID: JSONValue?
    var failShimAfter = false, restoredShimListenerMissing = false, shimHealthCalls = 0
    var preCommandRefusals: [String] = [], bootoutDelayReads = 0, delayedOldReads = 0
    var delayedRemovals: [String: Int] = [:], pauses: [Double] = []
    var absentResult: NativeProcessResult?
    init() throws {
        try FileManager.default.createDirectory(at: home.appendingPathComponent("Library/LaunchAgents"), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        for (label, pid) in [(server, Int32(111)), (shim, Int32(222))] {
            let data = try PropertyListSerialization.data(fromPropertyList: ["Label": label, "ProgramArguments": argv(label), "WorkingDirectory": cwd(label).path,
                "EnvironmentVariables": ["HOME": home.path, "UNIAPI_ROOT": root.path], "KeepAlive": true], format: .xml, options: 0)
            try data.write(to: definition(label)); XCTAssertEqual(chmod(definition(label).path, 0o600), 0)
            pids[label] = pid; sources[label] = definition(label)
            identities[pid] = identity(pid, parent: 1, argv: argv(label))
        }
        identities[112] = identity(112, parent: 111, argv: childArgv())
    }
    func cleanup() { try? FileManager.default.removeItem(at: home) }
    func definition(_ label: String) -> URL { home.appendingPathComponent("Library/LaunchAgents/" + label + ".plist") }
    func cwd(_ label: String) -> URL { label == server ? root.appendingPathComponent("server") : root }
    func argv(_ label: String) -> [String] {
        label == server ? ["/fixture/node", root.appendingPathComponent("server/node_modules/tsx/dist/cli.mjs").path, root.appendingPathComponent("server/src/main.ts").path] : ["/fixture/python3", root.appendingPathComponent("proxy/uniapi_shim.py").path]
    }
    func childArgv() -> [String] {
        let tsx = root.appendingPathComponent("server/node_modules/tsx/dist")
        return ["/fixture/node", "--require", tsx.appendingPathComponent("preflight.cjs").path, "--import", tsx.appendingPathComponent("loader.mjs").absoluteString, root.appendingPathComponent("server/src/main.ts").path]
    }
    func identity(_ pid: Int32, parent: Int32, argv: [String]) -> NativeTransferIdentity {
        .init(pid: pid, parent: parent, uid: owner, bornSeconds: pid < 1000 ? 100 : 200, bornMicroseconds: UInt64(pid), executable: argv[0], arguments: argv)
    }
    func output(_ status: Int32 = 0, _ stdout: String = "", _ stderr: String = "") -> NativeProcessResult { .init(status: status, stdout: Data(stdout.utf8), stderr: Data(stderr.utf8)) }
    func printJob(_ label: String) -> String {
        let domain = badProof == 0 ? "gui/999" : "gui/\(owner)", args = badProof == 2 ? ["/fixture/node", "--eval", "bad"] : argv(label)
        let program = badProof == 1 ? "/other/node" : args[0], source = badProof == 4 ? home.appendingPathComponent("unowned.plist") : sources[label]!
        return "\(domain)/\(label) = {\n path = \(source.path)\n program = \(program)\n arguments = {\n \(args.joined(separator: "\n "))\n }\n environment = {\n HOME => \(home.path)\n UNIAPI_ROOT => \(badProof == 3 ? "/other/root" : root.path)\n }\n pid = \(pids[label]!)\n}\n"
    }
    func io() throws -> NativeLegacyRetirementIO {
        var io = try NativeLegacyRetirementSystem.make(paths: paths, dependencies: dependencies)
        let bootout = io.bootout
        io.bootout = { record, seconds in
            if record.label == self.shim && self.failShim && !self.failShimAfter {
                self.preCommandRefusals.append(record.label)
                if self.editDuringFailure { try Data("operator edit".utf8).write(to: self.definition(self.server)) }
                if self.disableDuringFailure { self.disabled = true }
                throw NativeLegacyBootoutFailure(disposition: .notIssued, message: "Fixture refusal before calling production bootout")
            }
            try await bootout(record, seconds)
        }
        return io
    }
    func removeForBootout(_ label: String) {
        if let pid = pids.removeValue(forKey: label) { identities.removeValue(forKey: pid) }
        if label == server, let child = identities[112] { identities[112] = identity(child.pid, parent: 1, argv: child.arguments) }
    }
    var dependencies: NativeLegacySystemDependencies {
        .init(owner: owner, home: home, command: { args, seconds in
            XCTAssertGreaterThan(seconds, 0); self.commands.append(args)
            if args[0] == "print-disabled" { return self.output(0, "disabled services = {\n \"\(self.server)\" => \(self.disabled ? "true" : "false")\n}") }
            if args[0] == "print" {
                let label = String(args[1].split(separator: "/").last!)
                if let remaining = self.delayedRemovals[label] {
                    if remaining > 0 { self.delayedRemovals[label] = remaining - 1; self.delayedOldReads += 1 }
                    else { self.delayedRemovals[label] = nil; self.removeForBootout(label) }
                }
                guard self.pids[label] != nil else { return self.absentResult ?? self.output(113, "", "Bad request.\nCould not find service \"\(label)\" in domain for user gui: \(self.owner)\n") }
                if self.delayChild && self.pids[label] == 1111 {
                    self.restoredReads += 1
                    if self.restoredReads >= 3 { self.identities[1112] = self.identity(1112, parent: 1111, argv: self.childArgv()) }
                }
                return self.output(0, self.printJob(label))
            }
            if args[0] == "bootout" {
                let label = String(args[1].split(separator: "/").last!)
                if label == self.shim && self.failShim {
                    if self.editDuringFailure { try Data("operator edit".utf8).write(to: self.definition(self.server)) }
                    if self.disableDuringFailure { self.disabled = true }
                    if !self.failShimAfter { return self.output(1) }
                }
                if self.bootoutDelayReads > 0 { self.delayedRemovals[label] = self.bootoutDelayReads; return self.output() }
                self.removeForBootout(label)
                if label == self.shim && self.failShim && self.failShimAfter { return self.output(1) }
                return self.output()
            }
            if args[0] == "bootstrap" {
                let copy = URL(fileURLWithPath: args[2]), label = copy.deletingPathExtension().lastPathComponent
                XCTAssertEqual(try Data(contentsOf: copy), try Data(contentsOf: self.definition(label)))
                let pid: Int32 = label == self.server ? 1111 : 1222
                self.pids[label] = pid; self.sources[label] = copy; self.identities[pid] = self.identity(pid, parent: 1, argv: self.argv(label))
                if label == self.server && !self.delayChild { self.identities[1112] = self.identity(1112, parent: 1111, argv: self.childArgv()) }
                return self.output()
            }
            throw NativeFailure("Unexpected fixture control")
        }, inspect: { _ in self.advisory }, identity: { pid in
            guard let n = self.identities[pid] else { throw NativeFailure("Fixture missing PID") }
            if self.badProof == 5 { return .init(pid: n.pid, parent: n.parent, uid: self.owner + 1, bornSeconds: n.bornSeconds, bornMicroseconds: n.bornMicroseconds, executable: n.executable, arguments: n.arguments) }
            return n
        }, directory: { node in self.badProof == 6 ? self.home.appendingPathComponent("other") : self.cwd(node.arguments[0].contains("python") ? self.shim : self.server) },
           same: { node in
               guard let current = self.identities[node.pid] else { return false }
               return current.uid == node.uid && current.bornSeconds == node.bornSeconds && current.bornMicroseconds == node.bornMicroseconds
           },
           stopped: { self.stops.contains($0.pid) }, children: { pid in self.identities.values.filter { $0.parent == pid }.map(\.pid).sorted() },
           sockets: { node in
               if node.pid == 1222 && self.restoredShimListenerMissing { return .init() }
               return .init(listeningPorts: [112, 1112].contains(node.pid) ? [8780] : [222, 1222].contains(node.pid) ? [8823] : [])
           },
           signal: { node, number in
               self.signals.append((node.pid, number))
               if number == SIGSTOP { self.stops.insert(node.pid) }
               else if number == SIGCONT { self.stops.remove(node.pid) }
               else if number == SIGKILL { self.identities.removeValue(forKey: node.pid); self.stops.remove(node.pid) }
           }, fanOwner: { _ in false }, work: { .init() }, health: { port, _ in
               self.healthCalls += 1
               if port == 8823 { self.shimHealthCalls += 1 }
               return port == 8780 ? ["ok": true, "service": "uniapi-server", "apps": ["code"], "pid": self.healthPID ?? .number(self.wrongHealthPID ? 999 : 1112)] : ["ok": true, "service": "uniapi-shim"]
           }, absent: {}, pause: { self.pauses.append($0); self.time += $0 }, clock: { self.time })
    }
}
