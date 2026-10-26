import Foundation
import Darwin
import XCTest
@testable import UniApiCore

final class LegacyRetirementPythonLauncherTests: XCTestCase {
    func testFixedSelectorCommandsReplaceEnvironmentAndResolveCanonicalPython() async throws {
        let f = try PythonLauncherFixture(); defer { f.cleanup() }
        let proof = try await f.resolve(seconds: 1)
        XCTAssertEqual(proof.developerDirectory, f.developer.path)
        XCTAssertEqual(proof.interpreter.path, f.interpreter.path)
        XCTAssertEqual(f.selectorCommands.map { $0.0 }, [NativePaths.xcodeSelect, NativePaths.xcrun, NativePaths.xcodeSelect])
        XCTAssertEqual(f.selectorCommands.map { $0.1 }, [["-p"], ["--find", "python3"], ["-p"]])
        for call in f.selectorCommands {
            XCTAssertEqual(call.2, ["HOME": f.home.path, "PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "LC_ALL": "C"])
            XCTAssertGreaterThan(call.3, 0); XCTAssertLessThanOrEqual(call.3, 1)
        }
        XCTAssertTrue(f.commands.isEmpty); XCTAssertTrue(f.signals.isEmpty)
    }

    func testSelectorRefusesFailedMalformedOversizedAndUnexpectedOutput() async throws {
        for mode in 0..<14 {
            let f = try PythonLauncherFixture(); defer { f.cleanup() }
            f.selectorHook = { call, _, _ in
                guard call == 2 else { return nil }
                switch mode {
                case 0: return f.output(1, f.selectedProgram.path + "\n")
                case 1: return f.output(0, "")
                case 2: return f.output(0, "relative/python3\n")
                case 3: return f.output(0, f.selectedProgram.path + "\n/other/python3\n")
                case 4: return f.output(0, f.selectedProgram.path + "\n\n")
                case 5: return f.output(0, f.selectedProgram.path + "\r\n")
                case 6: return f.output(0, f.selectedProgram.path + "\0")
                case 7: return f.output(0, "/" + String(repeating: "a", count: 4096))
                case 8: return f.output(0, f.selectedProgram.path + "\n", error: String(repeating: "x", count: 4097))
                case 9: return f.output(0, f.interpreter.path + "\n")
                case 10: return f.output(0, f.developer.path + "/usr/bin/../bin/python3\n")
                case 11: return f.output(0, "/other/developer/usr/bin/python3\n")
                case 12: return .init(status: 0, stdout: Data([0xff]), stderr: Data())
                default: throw NativeFailure("Injected selector failure")
                }
            }
            do { _ = try await f.resolve(seconds: 1); XCTFail("Selector case \(mode) accepted") } catch {}
            XCTAssertTrue(f.signals.isEmpty); XCTAssertTrue(f.commands.isEmpty)
        }
    }

    func testSelectorRefusesChangesDeadlinesCancellationAndUnresolvableTargets() async throws {
        for mode in 0..<8 {
            let f = try PythonLauncherFixture(); defer { f.cleanup() }
            if mode == 5 { try FileManager.default.removeItem(at: f.selectedProgram) }
            if mode == 6 { XCTAssertEqual(chmod(f.interpreter.path, 0o600), 0) }
            if mode == 7 {
                try FileManager.default.removeItem(at: f.selectedProgram)
                let outside = f.home.appendingPathComponent("outside/Python")
                try FileManager.default.createDirectory(at: outside.deletingLastPathComponent(), withIntermediateDirectories: true)
                try Data("inert".utf8).write(to: outside); XCTAssertEqual(chmod(outside.path, 0o700), 0)
                try FileManager.default.createSymbolicLink(at: f.selectedProgram, withDestinationURL: outside)
            }
            f.selectorHook = { call, _, _ in
                if mode == 0 && call == 3 { return f.output(0, f.otherDeveloper.path + "\n") }
                if mode == 1 { f.time += 1 }
                if mode == 2 { f.time = -1 }
                if mode == 3 { f.time = .nan }
                if mode == 4 { withUnsafeCurrentTask { $0?.cancel() } }
                return nil
            }
            let task = Task { try await f.resolve(seconds: 1) }
            do { _ = try await task.value; XCTFail("Selector boundary \(mode) accepted") } catch {}
            XCTAssertTrue(f.signals.isEmpty); XCTAssertTrue(f.commands.isEmpty)
        }
    }

    func testLiteralSystemPythonAliasPreparesThroughAdapterAndCoordinatorCapture() async throws {
        for unbuffered in [false, true] {
            let f = try PythonLauncherFixture(unbuffered: unbuffered); defer { f.cleanup() }
            let before = try Data(contentsOf: f.definition(f.shim)), io = try f.io(readOnly: true)
            let loaded = try await io.registration(f.shim, 1), registration = try XCTUnwrap(loaded)
            let node = try io.identity(registration.pid)
            XCTAssertEqual(registration.arguments, f.arguments(f.shim))
            XCTAssertEqual(registration.arguments[0], NativePaths.systemPython3.path)
            XCTAssertEqual(node.arguments[0], f.interpreter.path)
            XCTAssertEqual(node.executable, f.interpreter.path)
            XCTAssertNotNil(registration.pythonResolution)
            let proof = try XCTUnwrap(registration.pythonResolution)
            guard let physical = realpath(node.executable, nil) else { throw NativeFailure("Fixture interpreter realpath unavailable") }
            defer { free(physical) }
            let physicalPath = String(cString: physical)
            let normalized = URL(fileURLWithPath: physicalPath).standardizedFileURL.resolvingSymlinksInPath().path
            XCTAssertEqual(proof.interpreter.path, normalized)
            var physicalArguments = node.arguments; physicalArguments[0] = physicalPath
            let physicalNode = NativeTransferIdentity(pid: node.pid, parent: node.parent, uid: node.uid,
                bornSeconds: node.bornSeconds, bornMicroseconds: node.bornMicroseconds,
                executable: physicalPath, arguments: physicalArguments)
            XCTAssertTrue(proof.matches(physicalNode, registration: registration), "Raw realpath OS alias must compare through the same canonical policy")
            XCTAssertTrue(NativeLegacyRetirement.belongs(node, service: registration))
            let prepared = await NativeLegacyRetirement.prepare(paths: f.readOnlyPaths, io: io)
            XCTAssertEqual(prepared["status"], "prepared")
            XCTAssertEqual(try NativeLegacyRetirement.forest(registration, owner: f.owner, io: io).map(\.pid), [222])
            XCTAssertEqual(try Data(contentsOf: f.definition(f.shim)), before)
            XCTAssertTrue(f.signals.isEmpty); XCTAssertTrue(f.healthPorts.isEmpty)
            XCTAssertFalse(FileManager.default.fileExists(atPath: f.base.path))
        }
    }

    func testMissingResolutionAndNonliteralOrUnsupportedDeclarationsStayStrict() async throws {
        for mode in 0..<7 {
            let f = try PythonLauncherFixture(); defer { f.cleanup() }
            var dependencies = f.dependencies
            if mode == 0 { dependencies.resolveSystemPython = nil }
            else {
                switch mode {
                case 1: f.declaredPython = "/other/python3"
                case 2: f.declaredPython = "/usr/bin/../bin/python3"
                case 3: f.declaredTail = ["--unbuffered", f.script.path]
                case 4: f.declaredTail = ["-u", f.script.path, "extra"]
                case 5: f.declaredTail = ["-u", f.root.appendingPathComponent("other.py").path]
                default: f.declaredTail = ["-m", "module"]
                }
                try f.publishDefinitionsAndNodes()
            }
            let io = try NativeLegacyRetirementSystem.make(paths: f.paths, dependencies: dependencies)
            let result = await NativeLegacyRetirement.retire(paths: f.paths, io: io)
            XCTAssertEqual(result["status"], "refused", "declaration \(mode)")
            XCTAssertTrue(f.selectorCommands.isEmpty); XCTAssertTrue(f.signals.isEmpty)
            XCTAssertFalse(f.commands.contains { ["bootout", "bootstrap"].contains($0[0]) })
        }
    }

    func testResolvedAliasStillRequiresBothKernelPathsAndOriginalIdentityGuards() async throws {
        for mode in 0..<8 {
            let f = try PythonLauncherFixture(); defer { f.cleanup() }
            let node = try XCTUnwrap(f.nodes[222])
            var args = node.arguments, executable = node.executable, uid = node.uid, parent = node.parent
            switch mode {
            case 0: args[0] = f.otherInterpreter.path
            case 1: executable = f.otherInterpreter.path
            case 2: args.append("extra")
            case 3: args[args.count - 1] = f.root.appendingPathComponent("other.py").path
            case 4: uid += 1
            case 5: parent = 7
            case 6: f.sameInstance = false
            default: f.declaredDirectory = f.root; f.kernelDirectory = f.home.appendingPathComponent("other"); try f.publishDefinitionsAndNodes()
            }
            f.nodes[222] = .init(pid: 222, parent: parent, uid: uid, bornSeconds: node.bornSeconds, bornMicroseconds: node.bornMicroseconds, executable: executable, arguments: args)
            let result = await NativeLegacyRetirement.retire(paths: f.paths, io: try f.io())
            XCTAssertEqual(result["status"], "refused", "kernel guard \(mode)")
            XCTAssertTrue(f.signals.isEmpty); XCTAssertTrue(f.healthPorts.isEmpty)
            XCTAssertFalse(f.commands.contains { ["bootout", "bootstrap"].contains($0[0]) })
        }
    }

    func testPublicRegistrationCannotCarryAliasEvidenceAndProofCannotChangeRoles() async throws {
        for wrongRole in [false, true] {
            let f = try PythonLauncherFixture(); defer { f.cleanup() }
            let source = try f.io(), loaded = try await source.registration(f.shim, 1), original = try XCTUnwrap(loaded)
            var io = source
            io.registration = { label, seconds in
                guard let current = try await source.registration(label, seconds) else { return nil }
                if wrongRole {
                    var changed = current
                    if label == f.server { changed.pythonResolution = original.pythonResolution }
                    return changed
                }
                return .init(label: current.label, pid: current.pid, definitionPath: current.definitionPath, definition: current.definition,
                    arguments: current.arguments, directory: current.directory, sourceRoot: current.sourceRoot, home: current.home,
                    data: current.data, providers: current.providers, port: current.port, restorable: current.restorable)
            }
            let result = await NativeLegacyRetirement.retire(paths: f.paths, io: io)
            XCTAssertEqual(result["status"], "refused")
            XCTAssertTrue(f.signals.isEmpty); XCTAssertFalse(f.commands.contains { $0[0] == "bootout" })
        }
    }

    func testVerifiedAliasRetiresUsingOriginalDefinitionsAndActualKernelIdentities() async throws {
        let f = try PythonLauncherFixture(); defer { f.cleanup() }
        let before = try NativeLegacyRetirement.labels.map { try Data(contentsOf: f.definition($0)) }
        let result = await NativeLegacyRetirement.retire(paths: f.paths, io: try f.io())
        XCTAssertEqual(result["status"], "retired"); XCTAssertEqual(result["safeToInstall"], true)
        XCTAssertEqual(f.signals.filter { $0.1 == SIGSTOP }.map { $0.0.pid }, [111, 222])
        let pausedShim = try XCTUnwrap(f.signals.first { $0.0.pid == 222 })
        XCTAssertEqual(pausedShim.0.arguments[0], f.interpreter.path); XCTAssertEqual(pausedShim.0.executable, f.interpreter.path)
        XCTAssertEqual(f.commands.filter { $0[0] == "bootout" }.count, 2)
        XCTAssertEqual(try NativeLegacyRetirement.labels.map { try Data(contentsOf: f.definition($0)) }, before)
        XCTAssertTrue(f.pids.isEmpty); XCTAssertTrue(f.nodes.isEmpty); XCTAssertTrue(f.healthPorts.isEmpty)
    }

    func testSelectorChangeBeforeUnregisterRefusesAndResumesOnlyCapturedIdentities() async throws {
        let f = try PythonLauncherFixture(); defer { f.cleanup() }
        f.changeSelectionWhenPaused = true
        let result = await NativeLegacyRetirement.retire(paths: f.paths, io: try f.io())
        XCTAssertEqual(result["status"], "refused"); XCTAssertEqual(result["safeToInstall"], false)
        XCTAssertFalse(f.commands.contains { ["bootout", "bootstrap"].contains($0[0]) })
        XCTAssertEqual(f.signals.filter { $0.1 == SIGSTOP }.map { $0.0.pid }, [111, 222])
        XCTAssertEqual(f.signals.filter { $0.1 == SIGCONT }.map { $0.0.pid }, [222, 111])
        XCTAssertEqual(Set(f.nodes.keys), Set([Int32(111), 222])); XCTAssertTrue(f.stops.isEmpty)
    }

    func testAliasRecoveryRequiresFreshBirthAndTheSameSelectedInterpreterProof() async throws {
        for changed in [false, true] {
            let f = try PythonLauncherFixture(); defer { f.cleanup() }
            f.failShimAfterRemoval = true; f.changeSelectionOnRestore = changed
            let before = try Data(contentsOf: f.definition(f.shim))
            let result = await NativeLegacyRetirement.retire(paths: f.paths, io: try f.io())
            XCTAssertEqual(result["status"], changed ? "recovery-incomplete" : "rolled-back")
            XCTAssertEqual(result["safeToInstall"], false)
            let restore = try XCTUnwrap(f.commands.first { $0[0] == "bootstrap" && $0[2].hasSuffix(f.shim + ".plist") })
            XCTAssertTrue(restore[2].hasPrefix(f.base.path + "/")); XCTAssertNotEqual(restore[2], f.definition(f.shim).path)
            XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: restore[2])), before)
            XCTAssertEqual(try Data(contentsOf: f.definition(f.shim)), before)
            if changed {
                XCTAssertEqual(f.healthPorts, [8780], "Recover the unaffected server; a different interpreter must fail sameDefinition before shim health")
            } else {
                XCTAssertEqual(f.healthPorts, [8780, 8823])
                let node = try XCTUnwrap(f.nodes[1222])
                XCTAssertEqual(node.bornSeconds, 200); XCTAssertEqual(node.arguments[0], f.interpreter.path)
                let prepared = await NativeLegacyRetirement.prepare(paths: f.readOnlyPaths, io: try f.io(readOnly: true))
                XCTAssertEqual(prepared["status"], "prepared")
            }
        }
    }

    func testAppleFrameworkLauncherResolvesOnlyVerifiedSameVersionApp() async throws {
        let f = try PythonLauncherFixture(); defer { f.cleanup() }; try f.installFramework()
        let proof = try await f.resolve(seconds: 1)
        XCTAssertEqual(proof.selectedProgram, f.selectedProgram)
        XCTAssertEqual(proof.interpreter, f.interpreter)
        XCTAssertNotEqual(f.launcher(f.developer), f.interpreter)
        let signature = f.selectorCommands.filter { $0.0 == NativePaths.codesign }
        XCTAssertEqual(signature.map { $0.1 }, [f.launcher(f.developer), f.app(f.developer)].map {
            ["--verify", "--strict", "--all-architectures", "-R", "=anchor apple and identifier \"com.apple.python3\"", $0.path]
        })
        XCTAssertEqual(f.selectorCommands.map { $0.0 }, [NativePaths.xcodeSelect, NativePaths.xcrun, NativePaths.xcodeSelect,
            NativePaths.codesign, NativePaths.codesign, NativePaths.xcodeSelect, NativePaths.xcrun, NativePaths.xcodeSelect])
        for call in f.selectorCommands {
            XCTAssertEqual(call.2, ["HOME": f.home.path, "PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "LC_ALL": "C"])
            XCTAssertGreaterThan(call.3, 0); XCTAssertLessThanOrEqual(call.3, 1)
        }
        XCTAssertTrue(f.commands.isEmpty); XCTAssertTrue(f.signals.isEmpty)
    }

    func testAppleFrameworkProofPreparesAndRetiresOriginalDefinitions() async throws {
        for unbuffered in [false, true] {
            let f = try PythonLauncherFixture(unbuffered: unbuffered); defer { f.cleanup() }; try f.installFramework()
            let before = try NativeLegacyRetirement.labels.map { try Data(contentsOf: f.definition($0)) }
            let prepared = await NativeLegacyRetirement.prepare(paths: f.readOnlyPaths, io: try f.io(readOnly: true))
            XCTAssertEqual(prepared["status"], "prepared"); XCTAssertTrue(f.signals.isEmpty)
            let result = await NativeLegacyRetirement.retire(paths: f.paths, io: try f.io())
            XCTAssertEqual(result["status"], "retired"); XCTAssertEqual(result["safeToInstall"], true)
            XCTAssertEqual(try NativeLegacyRetirement.labels.map { try Data(contentsOf: f.definition($0)) }, before)
            XCTAssertEqual(f.signals.filter { $0.1 == SIGSTOP }.map { $0.0.pid }, [111, 222])
            XCTAssertEqual(f.signals.first { $0.0.pid == 222 }?.0.executable, f.interpreter.path)
            XCTAssertTrue(f.pids.isEmpty); XCTAssertTrue(f.healthPorts.isEmpty)
        }
    }

    func testAppleFrameworkProofRecoveryRequiresFreshSameFramework() async throws {
        for changed in [false, true] {
            let f = try PythonLauncherFixture(); defer { f.cleanup() }; try f.installFramework()
            f.failShimAfterRemoval = true; f.changeSelectionOnRestore = changed
            let before = try Data(contentsOf: f.definition(f.shim))
            let result = await NativeLegacyRetirement.retire(paths: f.paths, io: try f.io())
            XCTAssertEqual(result["status"], changed ? "recovery-incomplete" : "rolled-back")
            XCTAssertEqual(try Data(contentsOf: f.definition(f.shim)), before)
            if changed { XCTAssertEqual(f.healthPorts, [8780], "The unaffected server recovers; changed shim proof never reaches health") }
            else {
                XCTAssertEqual(f.healthPorts, [8780, 8823])
                XCTAssertEqual(f.nodes[1222]?.bornSeconds, 200)
                XCTAssertEqual(f.nodes[1222]?.executable, f.interpreter.path)
            }
        }
    }

    func testAppleFrameworkSignatureFailuresRefuseBeforeServiceControls() async throws {
        for mode in 0..<5 {
            let f = try PythonLauncherFixture(); defer { f.cleanup() }; try f.installFramework()
            f.selectorHook = { call, executable, _ in
                guard executable == NativePaths.codesign, call == (mode == 1 ? 5 : 4) else { return nil }
                if mode <= 1 { return f.output(1, error: "Rejected signature") }
                if mode == 2 { return f.output(0, String(repeating: "x", count: 4097)) }
                if mode == 3 { return f.output(0, error: String(repeating: "x", count: 4097)) }
                throw NativeFailure("Injected signature command failure")
            }
            let result = await NativeLegacyRetirement.retire(paths: f.paths, io: try f.io())
            XCTAssertEqual(result["status"], "refused", "signature \(mode)")
            XCTAssertTrue(f.signals.isEmpty); XCTAssertFalse(f.commands.contains { $0[0] == "bootout" })
        }
    }

    func testAppleFrameworkMetadataAndLayoutMismatchesRefuse() async throws {
        for mode in 0..<9 {
            let f = try PythonLauncherFixture(); defer { f.cleanup() }; try f.installFramework()
            var bundle = f.metadata(app: true), framework = f.metadata(app: false)
            switch mode {
            case 0: bundle["CFBundleExecutable"] = "Other"
            case 1: bundle["CFBundleIdentifier"] = "other.python"
            case 2: bundle["CFBundlePackageType"] = "FMWK"
            case 3: bundle["CFBundleShortVersionString"] = "3.9.7"
            case 4: bundle["CFBundleVersion"] = "3.10.6"; bundle["CFBundleShortVersionString"] = "3.10.6"
            case 5: framework["CFBundleVersion"] = "3.9.7"
            case 6: framework["CFBundleIdentifier"] = "other.python"
            case 7: bundle["CFBundleVersion"] = 396
            default:
                let selected = f.selectedProgram
                try FileManager.default.removeItem(at: selected)
                try FileManager.default.createSymbolicLink(at: selected, withDestinationURL: f.launcher(f.otherDeveloper))
            }
            try f.writeMetadata(bundle, app: true); try f.writeMetadata(framework, app: false)
            do { _ = try await f.resolve(seconds: 1); XCTFail("metadata/layout \(mode) admitted") } catch {}
            XCTAssertTrue(f.signals.isEmpty); XCTAssertTrue(f.commands.isEmpty)
        }
    }

    func testAppleFrameworkProtectedFilesAndDirectoriesRefuseUnsafeInputs() async throws {
        for mode in 0..<9 {
            let f = try PythonLauncherFixture(); defer { f.cleanup() }; try f.installFramework()
            switch mode {
            case 0: XCTAssertEqual(chmod(f.launcher(f.developer).path, 0o777), 0)
            case 1: XCTAssertEqual(chmod(f.interpreter.path, 0o600), 0)
            case 2: XCTAssertEqual(chmod(f.app(f.developer).path, 0o775), 0)
            case 3:
                let file = f.app(f.developer).appendingPathComponent("Contents/Info.plist")
                XCTAssertEqual(link(file.path, f.home.appendingPathComponent("hardlink").path), 0)
            case 4:
                let file = f.app(f.developer).appendingPathComponent("Contents/Info.plist"), other = f.home.appendingPathComponent("other-plist")
                try FileManager.default.moveItem(at: file, to: other)
                try FileManager.default.createSymbolicLink(at: file, withDestinationURL: other)
            case 5: try FileManager.default.removeItem(at: f.interpreter)
            case 6: f.frameworkExpectedOwner = f.owner + 1
            case 7:
                f.frameworkAnchor = f.otherDeveloper
            default: XCTAssertEqual(chmod(f.selectedProgram.deletingLastPathComponent().path, 0o775), 0)
            }
            do { _ = try await f.resolve(seconds: 1); XCTFail("protected boundary \(mode) admitted") } catch {}
            XCTAssertTrue(f.signals.isEmpty); XCTAssertTrue(f.commands.isEmpty)
        }
    }

    func testAppleFrameworkChangesDuringSignatureOrFinalSelectionRefuse() async throws {
        for mode in 0..<5 {
            let f = try PythonLauncherFixture(); defer { f.cleanup() }; try f.installFramework()
            f.selectorHook = { call, _, _ in
                if mode == 0 && call == 4 { try Data("changed runtime".utf8).write(to: f.interpreter) }
                if mode == 1 && call == 5 { try f.writeMetadata(f.metadata(app: true).merging(["extra": "changed"]) { _, n in n }, app: true) }
                if mode == 2 && call == 6 { return f.output(0, f.otherDeveloper.path + "\n") }
                if mode == 3 && call == 7 { return f.output(0, f.otherDeveloper.appendingPathComponent("usr/bin/python3").path + "\n") }
                if mode == 4 && call == 4 {
                    try FileManager.default.removeItem(at: f.selectedProgram)
                    try FileManager.default.createSymbolicLink(at: f.selectedProgram, withDestinationURL: f.launcher(f.developer))
                }
                return nil
            }
            do { _ = try await f.resolve(seconds: 1); XCTFail("changed proof \(mode) admitted") } catch {}
            XCTAssertTrue(f.signals.isEmpty); XCTAssertTrue(f.commands.isEmpty)
        }
    }

    func testAppleFrameworkSharedDeadlineAndCancellationRefuseBeforeControls() async throws {
        for mode in 0..<3 {
            let f = try PythonLauncherFixture(); defer { f.cleanup() }; try f.installFramework()
            f.selectorHook = { call, _, _ in
                if call == 4 {
                    if mode == 0 { f.time = 1 }
                    if mode == 1 { f.time = .infinity }
                    if mode == 2 { withUnsafeCurrentTask { $0?.cancel() } }
                }
                return nil
            }
            let task = Task { try await f.resolve(seconds: 1) }
            do { _ = try await task.value; XCTFail("framework deadline \(mode) admitted") } catch {}
            XCTAssertTrue(f.signals.isEmpty); XCTAssertTrue(f.commands.isEmpty)
        }
    }
}

private final class PythonLauncherFixture: @unchecked Sendable {
    let home = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent("legacy-python-launcher-" + UUID().uuidString, isDirectory: true)
    let owner = getuid(), unbuffered: Bool
    let server = NativeLegacyRetirement.labels[0], shim = NativeLegacyRetirement.labels[1]
    var root: URL { home.appendingPathComponent("UniApi", isDirectory: true) }
    var script: URL { root.appendingPathComponent("proxy/uniapi_shim.py") }
    var paths: NativePaths { .init(root: root, home: home) }
    var readOnlyPaths: NativePaths { .init(root: root, home: home, readOnly: true) }
    var base: URL { home.appendingPathComponent("Library/Application Support/UniApi Native Transfer") }
    var developer: URL { home.appendingPathComponent("Xcode-A.app/Contents/Developer") }
    var otherDeveloper: URL { home.appendingPathComponent("Xcode-B.app/Contents/Developer") }
    var selectedProgram: URL { developer.appendingPathComponent("usr/bin/python3") }
    var interpreter: URL { frameworkPython(developer) }
    var otherInterpreter: URL { frameworkPython(otherDeveloper) }
    var selectedOther = false, time = 0.0
    var declaredPython = NativePaths.systemPython3.path, declaredTail: [String]?, declaredDirectory: URL?, kernelDirectory: URL?
    var sameInstance = true, failShimAfterRemoval = false, changeSelectionOnRestore = false, changeSelectionWhenPaused = false
    var commands: [[String]] = [], selectorCommands: [(URL, [String], [String: String], Double)] = []
    var signals: [(NativeTransferIdentity, Int32)] = [], healthPorts: [UInt16] = [], stops = Set<Int32>()
    var nodes: [Int32: NativeTransferIdentity] = [:], pids: [String: Int32] = [:], sources: [String: URL] = [:]
    var selectorHook: ((Int, URL, [String]) throws -> NativeProcessResult?)?
    var frameworkExpectedOwner: UInt32?, frameworkAnchor: URL?

    init(unbuffered: Bool = true) throws {
        self.unbuffered = unbuffered
        try FileManager.default.createDirectory(at: home.appendingPathComponent("Library/LaunchAgents"), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        for directory in [developer, otherDeveloper] {
            let executable = frameworkPython(directory), selected = directory.appendingPathComponent("usr/bin/python3")
            try FileManager.default.createDirectory(at: executable.deletingLastPathComponent(), withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: selected.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("inert Python fixture; never executed".utf8).write(to: executable); XCTAssertEqual(chmod(executable.path, 0o700), 0)
            try FileManager.default.createSymbolicLink(at: selected, withDestinationURL: executable)
        }
        try publishDefinitionsAndNodes()
    }
    func cleanup() { try? FileManager.default.removeItem(at: home) }
    func frameworkPython(_ directory: URL) -> URL { directory.appendingPathComponent("Library/Frameworks/Python3.framework/Versions/3.9/Resources/Python.app/Contents/MacOS/Python") }
    func app(_ directory: URL) -> URL { frameworkPython(directory).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent() }
    func launcher(_ directory: URL) -> URL { directory.appendingPathComponent("Library/Frameworks/Python3.framework/Versions/3.9/bin/python3.9") }
    func metadata(app: Bool) -> [String: Any] {
        ["CFBundleVersion": "3.9.6", "CFBundleShortVersionString": "3.9.6", "CFBundleIdentifier": "com.apple.python3",
         "CFBundleExecutable": app ? "Python" : "Python3", "CFBundlePackageType": app ? "APPL" : "FMWK"]
    }
    func writeMetadata(_ value: [String: Any], app: Bool, developer: URL? = nil) throws {
        let directory = developer ?? self.developer
        let file = app ? self.app(directory).appendingPathComponent("Contents/Info.plist") : directory.appendingPathComponent("Library/Frameworks/Python3.framework/Versions/3.9/Resources/Info.plist")
        try PropertyListSerialization.data(fromPropertyList: value, format: .xml, options: 0).write(to: file)
        XCTAssertEqual(chmod(file.path, 0o600), 0)
    }
    func installFramework() throws {
        frameworkExpectedOwner = owner; frameworkAnchor = home
        for directory in [developer, otherDeveloper] {
            let file = launcher(directory), selected = directory.appendingPathComponent("usr/bin/python3")
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("inert Apple launcher fixture; never executed".utf8).write(to: file); XCTAssertEqual(chmod(file.path, 0o700), 0)
            try FileManager.default.removeItem(at: selected)
            try FileManager.default.createSymbolicLink(at: selected, withDestinationURL: file)
            try writeMetadata(metadata(app: false), app: false, developer: directory)
            try writeMetadata(metadata(app: true), app: true, developer: directory)
        }
    }
    func definition(_ label: String) -> URL { home.appendingPathComponent("Library/LaunchAgents/" + label + ".plist") }
    func arguments(_ label: String) -> [String] {
        label == server ? ["/fixture/node", root.appendingPathComponent("server/node_modules/tsx/dist/cli.mjs").path, root.appendingPathComponent("server/src/main.ts").path] : [declaredPython] + (declaredTail ?? ((unbuffered ? ["-u"] : []) + [script.path]))
    }
    func node(_ pid: Int32, label: String) -> NativeTransferIdentity {
        var args = arguments(label)
        if label == shim { args[0] = selectedOther ? otherInterpreter.path : interpreter.path }
        return .init(pid: pid, parent: 1, uid: owner, bornSeconds: pid < 1000 ? 100 : 200, bornMicroseconds: UInt64(pid), executable: args[0], arguments: args)
    }
    func publishDefinitionsAndNodes() throws {
        for (label, pid) in [(server, Int32(111)), (shim, Int32(222))] {
            var plist: [String: Any] = ["Label": label, "ProgramArguments": arguments(label), "KeepAlive": true]
            if label == server { plist["WorkingDirectory"] = root.path; plist["EnvironmentVariables"] = ["HOME": home.path, "UNIAPI_ROOT": root.path] }
            else if let declaredDirectory { plist["WorkingDirectory"] = declaredDirectory.path }
            try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0).write(to: definition(label))
            XCTAssertEqual(chmod(definition(label).path, 0o600), 0)
            pids[label] = pid; sources[label] = definition(label); nodes[pid] = node(pid, label: label)
        }
    }
    func output(_ status: Int32 = 0, _ value: String = "", error: String = "") -> NativeProcessResult {
        .init(status: status, stdout: Data(value.utf8), stderr: Data(error.utf8))
    }
    func resolve(seconds: Double) async throws -> NativeLegacyPythonResolution {
        try await NativeLegacyPythonResolution.resolve(home: home, seconds: seconds, clock: { self.time },
            frameworkOwner: frameworkExpectedOwner ?? 0, frameworkAnchor: frameworkAnchor, command: { executable, args, env, timeout in
            self.selectorCommands.append((executable, args, env, timeout))
            if let result = try self.selectorHook?(self.selectorCommands.count, executable, args) { return result }
            if executable == NativePaths.codesign { return self.output() }
            let directory = self.selectedOther ? self.otherDeveloper : self.developer
            return self.output(0, (executable == NativePaths.xcodeSelect ? directory.path : directory.appendingPathComponent("usr/bin/python3").path) + "\n")
        })
    }
    func printJob(_ label: String) -> String {
        let port = label == server ? "8780" : "8823"
        return "gui/\(owner)/\(label) = {\n path = \(sources[label]!.path)\n program = \(arguments(label)[0])\n arguments = {\n \(arguments(label).joined(separator: "\n "))\n }\n environment = {\n HOME => \(home.path)\n UNIAPI_ROOT => \(root.path)\n UNIAPI_DATA => \(paths.data.path)\n UNIAPI_PROVIDERS => \(paths.providers.path)\n UNIAPI_PORT => \(port)\n }\n pid = \(pids[label]!)\n}\n"
    }
    func io(readOnly: Bool = false) throws -> NativeLegacyRetirementIO { try NativeLegacyRetirementSystem.make(paths: readOnly ? readOnlyPaths : paths, dependencies: dependencies) }
    var dependencies: NativeLegacySystemDependencies {
        .init(owner: owner, home: home, command: { args, seconds in
            XCTAssertGreaterThan(seconds, 0); self.commands.append(args)
            switch args[0] {
            case "print-disabled": return self.output(0, "disabled services = {\n}\n")
            case "print":
                let label = String(args[1].split(separator: "/").last!)
                guard self.pids[label] != nil else { return self.output(113, error: "Could not find service \"\(label)\" in domain for user gui:\(self.owner)") }
                return self.output(0, self.printJob(label))
            case "bootout":
                let label = String(args[1].split(separator: "/").last!)
                if let pid = self.pids.removeValue(forKey: label) { self.nodes.removeValue(forKey: pid); self.stops.remove(pid) }
                return self.output(label == self.shim && self.failShimAfterRemoval ? 1 : 0)
            case "bootstrap":
                let copy = URL(fileURLWithPath: args[2]), label = copy.deletingPathExtension().lastPathComponent
                XCTAssertEqual(try Data(contentsOf: copy), try Data(contentsOf: self.definition(label)))
                if label == self.shim && self.changeSelectionOnRestore { self.selectedOther = true }
                let pid: Int32 = label == self.server ? 1111 : 1222
                self.pids[label] = pid; self.sources[label] = copy; self.nodes[pid] = self.node(pid, label: label)
                return self.output()
            default: throw NativeFailure("Unexpected Python-launcher fixture command")
            }
        }, inspect: { _ in .init(legacyPresent: true, activeJobs: 0, activeCode: 0, legacyWindowRunning: false, shimPresent: true) },
           identity: { pid in guard let node = self.nodes[pid] else { throw NativeFailure("Missing fixture process") }; return node },
           directory: { node in node.executable == "/fixture/node" ? self.root : self.kernelDirectory ?? self.root },
           same: { node in
               if node.executable != "/fixture/node", !self.sameInstance { return false }
               return self.nodes[node.pid].map { NativeLegacyRetirementSystem.sameExecution($0, node) } == true
           },
           stopped: { self.stops.contains($0.pid) }, children: { _ in [] },
           sockets: { node in .init(listeningPorts: [111, 1111].contains(node.pid) ? [8780] : [8823]) },
           signal: { node, number in
               self.signals.append((node, number))
               if number == SIGSTOP {
                   self.stops.insert(node.pid)
                   if self.changeSelectionWhenPaused { self.selectedOther = true }
               } else if number == SIGCONT { self.stops.remove(node.pid) }
               else if number == SIGKILL { self.nodes.removeValue(forKey: node.pid); self.stops.remove(node.pid) }
           }, fanOwner: { _ in false }, work: { .init() }, health: { port, _ in
               self.healthPorts.append(port)
               return port == 8780 ? ["ok": true, "service": "uniapi-server", "apps": ["code"], "pid": .number(Double(self.pids[self.server]!))] : ["ok": true, "service": "uniapi-shim"]
           }, absent: {}, pause: { self.time += $0 }, clock: { self.time }, resolveSystemPython: { try await self.resolve(seconds: $0) })
    }
}
