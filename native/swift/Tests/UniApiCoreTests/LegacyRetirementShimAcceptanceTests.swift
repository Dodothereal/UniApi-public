import Foundation
import Darwin
import XCTest
@testable import UniApiCore

final class LegacyRetirementShimAcceptanceTests: XCTestCase {
    func testAbsentShimEnvironmentAndUnbufferedPythonPrepareWithoutControls() async throws {
        let f = try ShimDefinitionFixture(); defer { f.cleanup() }
        let before = try Data(contentsOf: f.definition(f.shim))
        let plist = try XCTUnwrap(try PropertyListSerialization.propertyList(from: before, format: nil) as? [String: Any])
        XCTAssertNil(plist["EnvironmentVariables"]); XCTAssertNil(plist["WorkingDirectory"])
        let io = try f.io(readOnly: true)
        XCTAssertTrue(f.commands.isEmpty)
        let result = await NativeLegacyRetirement.prepare(paths: f.readOnlyPaths, io: io)
        XCTAssertEqual(result["status"], "prepared"); XCTAssertEqual(result["canPrepare"], true)
        XCTAssertTrue(f.signals.isEmpty); XCTAssertTrue(f.healthPorts.isEmpty)
        XCTAssertTrue(f.commands.allSatisfy { ["print", "print-disabled"].contains($0[0]) })
        XCTAssertFalse(FileManager.default.fileExists(atPath: f.base.path))
        XCTAssertEqual(try Data(contentsOf: f.definition(f.shim)), before)
    }

    func testPresentEmptyAndStringShimEnvironmentsAndBothPythonFormsPrepare() async throws {
        for unbuffered in [false, true] {
            for environment in [[String: String](), ["HOME": "fixture-home", "PROFILE_FIXTURE": "literal"]] {
                let f = try ShimDefinitionFixture(); defer { f.cleanup() }
                var declared = environment
                if declared["HOME"] != nil { declared["HOME"] = f.home.path }
                f.loadedEnvironment[f.shim]?["PROFILE_FIXTURE"] = "literal"
                try f.setShim(environment: declared, arguments: [f.python] + (unbuffered ? ["-u"] : []) + [f.script.path])
                let result = await NativeLegacyRetirement.prepare(paths: f.readOnlyPaths, io: try f.io(readOnly: true))
                XCTAssertEqual(result["status"], "prepared", "unbuffered \(unbuffered), environment \(declared.keys.sorted())")
                XCTAssertTrue(f.signals.isEmpty); XCTAssertTrue(f.healthPorts.isEmpty)
            }
        }
    }

    func testMalformedPresentShimEnvironmentRefusesBeforeControls() async throws {
        let malformed: [Any] = [
            [String](), ["HOME"], [["HOME": "nested"]], "", "HOME=value", 1, true,
            ["HOME": 1], ["HOME": false], ["NESTED": ["VALUE": "string"]],
            ["ARRAY": [String]()], Data("not-a-dictionary".utf8)
        ]
        for (index, value) in malformed.enumerated() {
            let f = try ShimDefinitionFixture(); defer { f.cleanup() }
            try f.setShim(environment: value)
            let result = await NativeLegacyRetirement.retire(paths: f.paths, io: try f.io())
            XCTAssertEqual(result["status"], "refused", "malformed case \(index)")
            XCTAssertEqual(result["message"], "Loaded legacy definition or environment disagrees")
            XCTAssertFalse(result["safeToInstall"].bool)
            XCTAssertTrue(f.signals.isEmpty); XCTAssertTrue(f.healthPorts.isEmpty)
            XCTAssertFalse(f.commands.contains { ["bootout", "bootstrap"].contains($0[0]) })
        }
    }

    func testAbsentShimEnvironmentStillRejectsInheritedRoutingMismatch() async throws {
        for key in ["HOME", "UNIAPI_ROOT", "UNIAPI_DATA", "UNIAPI_PROVIDERS", "UNIAPI_PORT"] {
            let f = try ShimDefinitionFixture(); defer { f.cleanup() }
            f.loadedEnvironment[f.shim]?[key] = key == "UNIAPI_PORT" ? "9999" : f.home.appendingPathComponent("wrong-routing").path
            let result = await NativeLegacyRetirement.prepare(paths: f.readOnlyPaths, io: try f.io(readOnly: true))
            XCTAssertEqual(result["status"], "refused", key)
            XCTAssertEqual(result["message"], "Inherited legacy routing differs from this transfer")
            XCTAssertTrue(f.signals.isEmpty); XCTAssertTrue(f.healthPorts.isEmpty)
            XCTAssertFalse(FileManager.default.fileExists(atPath: f.base.path))
        }
    }

    func testPresentShimEnvironmentStillRequiresLoadedValueAgreement() async throws {
        for missing in [false, true] {
            let f = try ShimDefinitionFixture(); defer { f.cleanup() }
            try f.setShim(environment: ["PROFILE_FIXTURE": "expected"])
            f.loadedEnvironment[f.shim]?["PROFILE_FIXTURE"] = missing ? nil : "different"
            let result = await NativeLegacyRetirement.retire(paths: f.paths, io: try f.io())
            XCTAssertEqual(result["status"], "refused")
            XCTAssertEqual(result["message"], "Loaded legacy definition or environment disagrees")
            XCTAssertTrue(f.signals.isEmpty)
            XCTAssertFalse(f.commands.contains { ["bootout", "bootstrap"].contains($0[0]) })
        }
    }

    func testPythonShimAdmissionAcceptsOnlyExactScriptOrSingleUnbufferedFlag() async throws {
        let f = try ShimDefinitionFixture(); defer { f.cleanup() }
        let io = try f.io()
        let loaded = try await io.registration(f.shim, 1)
        let registration = try XCTUnwrap(loaded)
        for arguments in [[f.python, f.script.path], [f.python, "-u", f.script.path]] {
            XCTAssertTrue(NativeLegacyRetirement.belongs(f.node(222, arguments: arguments), service: registration))
        }
        let invalid = [
            [f.python], [f.python, "-u"], [f.python, "--unbuffered", f.script.path],
            [f.python, "-B", f.script.path], [f.python, "-c", f.script.path], [f.python, "-m", f.script.path],
            [f.python, "-u", "-u", f.script.path], [f.python, f.script.path, "-u"],
            [f.python, "-u", f.script.path, "extra"], [f.python, "-u", f.root.appendingPathComponent("other.py").path],
            [f.python, f.root.appendingPathComponent("other.py").path], ["/fixture/not-python", "-u", f.script.path]
        ]
        for arguments in invalid {
            XCTAssertFalse(NativeLegacyRetirement.belongs(f.node(222, arguments: arguments), service: registration), "invalid shape \(arguments.count)")
            try f.setShim(environment: nil, arguments: arguments)
            let result = await NativeLegacyRetirement.retire(paths: f.paths, io: try f.io())
            XCTAssertEqual(result["status"], "refused", "invalid shape \(arguments.count)")
            XCTAssertTrue(f.signals.isEmpty)
            XCTAssertFalse(f.commands.contains { ["bootout", "bootstrap"].contains($0[0]) })
        }
        let mismatchedExecutable = NativeTransferIdentity(pid: 222, parent: 1, uid: f.owner,
            bornSeconds: 100, bornMicroseconds: 222, executable: "/fixture/other-python3", arguments: [f.python, "-u", f.script.path])
        XCTAssertFalse(NativeLegacyRetirement.belongs(mismatchedExecutable, service: registration))
    }

    func testAbsentEnvironmentUnbufferedShimRetiresOnlyVerifiedRegistrations() async throws {
        let f = try ShimDefinitionFixture(); defer { f.cleanup() }
        let before = try NativeLegacyRetirement.labels.map { try Data(contentsOf: f.definition($0)) }
        let result = await NativeLegacyRetirement.retire(paths: f.paths, io: try f.io())
        XCTAssertEqual(result["status"], "retired"); XCTAssertEqual(result["safeToInstall"], true)
        XCTAssertEqual(f.signals.filter { $0.1 == SIGSTOP }.map(\.0), [111, 222])
        XCTAssertEqual(f.commands.filter { $0[0] == "bootout" }.map { String($0[1].split(separator: "/").last!) }, NativeLegacyRetirement.labels)
        XCTAssertTrue(f.pids.isEmpty); XCTAssertTrue(f.identities.isEmpty); XCTAssertTrue(f.healthPorts.isEmpty)
        XCTAssertEqual(try NativeLegacyRetirement.labels.map { try Data(contentsOf: f.definition($0)) }, before)
        XCTAssertTrue(f.commands.allSatisfy { ["print", "print-disabled", "bootout"].contains($0[0]) })
    }

    func testAbsentEnvironmentUnbufferedShimRecoveryPreservesDefinitionAndRejectsChangedArgv() async throws {
        for changed in [false, true] {
            let f = try ShimDefinitionFixture(); defer { f.cleanup() }
            f.failShimAfterRemoval = true; f.corruptRestoredShimArguments = changed
            let before = try Data(contentsOf: f.definition(f.shim))
            let result = await NativeLegacyRetirement.retire(paths: f.paths, io: try f.io())
            XCTAssertEqual(result["status"], changed ? "recovery-incomplete" : "rolled-back")
            XCTAssertEqual(result["safeToInstall"], false)
            let copies = f.commands.filter { $0[0] == "bootstrap" }
            XCTAssertFalse(copies.isEmpty)
            let shimCopy = try XCTUnwrap(copies.first { $0[2].hasSuffix(f.shim + ".plist") })
            XCTAssertTrue(shimCopy[2].hasPrefix(f.base.path + "/"))
            XCTAssertNotEqual(shimCopy[2], f.definition(f.shim).path)
            XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: shimCopy[2])), before)
            XCTAssertEqual(try Data(contentsOf: f.definition(f.shim)), before)
            if changed {
                XCTAssertEqual(f.healthPorts, [8780], "Recover the unaffected server; changed shim argv must fail before shim readiness")
            } else {
                XCTAssertEqual(f.healthPorts, [8780, 8823])
                let shim = try XCTUnwrap(f.identities[1222])
                XCTAssertEqual(shim.arguments, [f.python, "-u", f.script.path]); XCTAssertEqual(shim.bornSeconds, 200)
                let again = await NativeLegacyRetirement.prepare(paths: f.readOnlyPaths, io: try f.io(readOnly: true))
                XCTAssertEqual(again["status"], "prepared")
            }
        }
    }
}

/// Exercises the real production adapter with protected temporary plists and
/// injected launchctl/kernel/transport operations. No fixture executable runs.
private final class ShimDefinitionFixture: @unchecked Sendable {
    let home = FileManager.default.temporaryDirectory.appendingPathComponent("legacy-shim-definition-" + UUID().uuidString, isDirectory: true)
    let owner = getuid(), python = "/fixture/python3"
    let server = NativeLegacyRetirement.labels[0], shim = NativeLegacyRetirement.labels[1]
    var root: URL { home.appendingPathComponent("UniApi", isDirectory: true) }
    var script: URL { root.appendingPathComponent("proxy/uniapi_shim.py") }
    var paths: NativePaths { .init(root: root, home: home) }
    var readOnlyPaths: NativePaths { .init(root: root, home: home, readOnly: true) }
    var base: URL { home.appendingPathComponent("Library/Application Support/UniApi Native Transfer") }
    var commands: [[String]] = [], signals: [(Int32, Int32)] = [], healthPorts: [UInt16] = []
    var pids: [String: Int32] = [:], sources: [String: URL] = [:], identities: [Int32: NativeTransferIdentity] = [:]
    var loadedEnvironment: [String: [String: String]] = [:], stops = Set<Int32>()
    var shimEnvironment: Any?, shimArguments: [String]?, time = 0.0
    var failShimAfterRemoval = false, corruptRestoredShimArguments = false

    init() throws {
        try FileManager.default.createDirectory(at: home.appendingPathComponent("Library/LaunchAgents"), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        for (label, pid) in [(server, Int32(111)), (shim, Int32(222))] {
            loadedEnvironment[label] = ["HOME": home.path, "UNIAPI_ROOT": root.path,
                "UNIAPI_DATA": paths.data.path, "UNIAPI_PROVIDERS": paths.providers.path, "UNIAPI_PORT": label == server ? "8780" : "8823"]
            try publish(label)
            pids[label] = pid; sources[label] = definition(label); identities[pid] = node(pid, arguments: argv(label))
        }
    }
    func cleanup() { try? FileManager.default.removeItem(at: home) }
    func definition(_ label: String) -> URL { home.appendingPathComponent("Library/LaunchAgents/" + label + ".plist") }
    func argv(_ label: String) -> [String] {
        label == server ? ["/fixture/node", root.appendingPathComponent("server/node_modules/tsx/dist/cli.mjs").path, root.appendingPathComponent("server/src/main.ts").path] : shimArguments ?? [python, "-u", script.path]
    }
    func node(_ pid: Int32, arguments: [String]) -> NativeTransferIdentity {
        .init(pid: pid, parent: 1, uid: owner, bornSeconds: pid < 1000 ? 100 : 200, bornMicroseconds: UInt64(pid), executable: arguments[0], arguments: arguments)
    }
    func publish(_ label: String) throws {
        var plist: [String: Any] = ["Label": label, "ProgramArguments": argv(label), "KeepAlive": true]
        if label == server {
            plist["WorkingDirectory"] = root.path
            plist["EnvironmentVariables"] = ["HOME": home.path, "UNIAPI_ROOT": root.path]
        } else if let shimEnvironment { plist["EnvironmentVariables"] = shimEnvironment }
        let bytes = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        try bytes.write(to: definition(label)); XCTAssertEqual(chmod(definition(label).path, 0o600), 0)
    }
    func setShim(environment: Any?, arguments: [String]? = nil) throws {
        shimEnvironment = environment; shimArguments = arguments
        try publish(shim)
        if let pid = pids[shim] { identities[pid] = node(pid, arguments: argv(shim)) }
    }
    func output(_ status: Int32 = 0, _ value: String = "", error: String = "") -> NativeProcessResult {
        .init(status: status, stdout: Data(value.utf8), stderr: Data(error.utf8))
    }
    func printJob(_ label: String) -> String {
        let environment = loadedEnvironment[label, default: [:]].sorted { $0.key < $1.key }.map { " \($0.key) => \($0.value)" }.joined(separator: "\n")
        return "gui/\(owner)/\(label) = {\n path = \(sources[label]!.path)\n program = \(argv(label)[0])\n arguments = {\n \(argv(label).joined(separator: "\n "))\n }\n environment = {\n\(environment)\n }\n pid = \(pids[label]!)\n}\n"
    }
    func io(readOnly: Bool = false) throws -> NativeLegacyRetirementIO {
        try NativeLegacyRetirementSystem.make(paths: readOnly ? readOnlyPaths : paths, dependencies: dependencies)
    }
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
                if let pid = self.pids.removeValue(forKey: label) { self.identities.removeValue(forKey: pid); self.stops.remove(pid) }
                return self.output(label == self.shim && self.failShimAfterRemoval ? 1 : 0)
            case "bootstrap":
                let copy = URL(fileURLWithPath: args[2]), label = copy.deletingPathExtension().lastPathComponent
                XCTAssertEqual(try Data(contentsOf: copy), try Data(contentsOf: self.definition(label)))
                let pid: Int32 = label == self.server ? 1111 : 1222
                var arguments = self.argv(label)
                if label == self.shim && self.corruptRestoredShimArguments { arguments.insert("-u", at: 1) }
                self.pids[label] = pid; self.sources[label] = copy; self.identities[pid] = self.node(pid, arguments: arguments)
                return self.output()
            default: throw NativeFailure("Unexpected shim-definition fixture command")
            }
        }, inspect: { _ in .init(legacyPresent: true, activeJobs: 0, activeCode: 0, legacyWindowRunning: false, shimPresent: true) },
           identity: { pid in guard let node = self.identities[pid] else { throw NativeFailure("Missing fixture process") }; return node },
           directory: { _ in self.root }, same: { node in
               guard let current = self.identities[node.pid] else { return false }
               return NativeLegacyRetirementSystem.sameExecution(current, node)
           }, stopped: { self.stops.contains($0.pid) }, children: { _ in [] }, sockets: { node in
               .init(listeningPorts: [111, 1111].contains(node.pid) ? [8780] : [8823])
           }, signal: { node, number in
               self.signals.append((node.pid, number))
               if number == SIGSTOP { self.stops.insert(node.pid) }
               else if number == SIGCONT { self.stops.remove(node.pid) }
               else if number == SIGKILL { self.identities.removeValue(forKey: node.pid); self.stops.remove(node.pid) }
           }, fanOwner: { _ in false }, work: { .init() }, health: { port, _ in
               self.healthPorts.append(port)
               return port == 8780 ? ["ok": true, "service": "uniapi-server", "apps": ["code"], "pid": .number(Double(self.pids[self.server]!))] : ["ok": true, "service": "uniapi-shim"]
           }, absent: {}, pause: { self.time += $0 }, clock: { self.time })
    }
}
