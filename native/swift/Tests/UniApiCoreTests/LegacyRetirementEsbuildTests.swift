import Foundation
import Darwin
import XCTest
@testable import UniApiCore

final class LegacyRetirementEsbuildTests: XCTestCase {
    func testInstalledTsxEsbuildLeafPreparesAndRetiresOnlyOwnedForest() async throws {
        for architecture in ["arm64", "x64"] {
            let f = try EsbuildRetirementFixture(architecture: architecture); defer { f.cleanup() }
            let prepared = await NativeLegacyRetirement.prepare(paths: f.paths, io: f.io)
            XCTAssertEqual(prepared["status"], "prepared"); XCTAssertTrue(f.frozen.isEmpty); XCTAssertTrue(f.booted.isEmpty)
            let retired = await NativeLegacyRetirement.retire(paths: f.paths, io: f.io)
            XCTAssertEqual(retired["status"], "retired"); XCTAssertEqual(retired["safeToInstall"], true)
            XCTAssertEqual(f.frozen, [111, 112, 113, 114, 222]); XCTAssertEqual(f.terminated, [114, 113, 112])
            XCTAssertEqual(f.booted, NativeLegacyRetirement.labels); XCTAssertNotNil(f.nodes[700]); XCTAssertFalse(f.frozen.contains(700))
        }
    }
    func testEsbuildFingerprintRejectsWrongBinaryVersionArgumentsAndDependencyGraph() async throws {
        for mode in 0..<11 {
            let f = try EsbuildRetirementFixture(); defer { f.cleanup() }
            switch mode {
            case 0: f.replace(113, executable: f.root.appendingPathComponent("other/bin/esbuild").path, arguments: [f.root.appendingPathComponent("other/bin/esbuild").path, "--service=0.28.2", "--ping"])
            case 1: f.replace(113, arguments: [f.binary.path, "--service=0.28.1", "--ping"])
            case 2: f.replace(113, arguments: [f.binary.path, "--service=0.28.2"])
            case 3: f.replace(113, arguments: [f.binary.path, "--service=0.28.2", "--ping", "extra"])
            case 4: try f.writeJSON(["name": "esbuild", "version": "0.28.2", "optionalDependencies": ["@esbuild/darwin-arm64": "0.28.1"]], f.esbuild.appendingPathComponent("package.json"))
            case 5: try f.writeJSON(["name": "@esbuild/darwin-arm64", "version": "0.28.1", "os": ["darwin"], "cpu": ["arm64"]], f.platform.appendingPathComponent("package.json"))
            case 6: try f.writeJSON(["name": "unrelated-model-runtime", "dependencies": ["esbuild": "~0.28.0"]], f.tsx.appendingPathComponent("package.json"))
            case 7:
                let file = f.esbuild.appendingPathComponent("package.json"), saved = f.root.appendingPathComponent("other-package.json")
                try FileManager.default.moveItem(at: file, to: saved); try FileManager.default.createSymbolicLink(at: file, withDestinationURL: saved)
            case 8:
                let link = f.tsx.deletingLastPathComponent().appendingPathComponent("esbuild")
                try FileManager.default.removeItem(at: link); try FileManager.default.createSymbolicLink(at: link, withDestinationURL: f.home.appendingPathComponent("outside-esbuild"))
            case 9:
                let file = f.esbuild.appendingPathComponent("package.json"); try FileManager.default.removeItem(at: file); XCTAssertEqual(mkfifo(file.path, 0o600), 0)
            default: XCTAssertEqual(chmod(f.binary.path, 0o777), 0)
            }
            let result = await NativeLegacyRetirement.retire(paths: f.paths, io: f.io)
            XCTAssertEqual(result["status"], "refused", "mode \(mode)"); XCTAssertTrue(f.frozen.isEmpty); XCTAssertTrue(f.booted.isEmpty)
        }
    }
    func testEsbuildRequiresAdmittedNodeParentOwnerBirthAndLeafShape() async throws {
        for mode in 0..<6 {
            let f = try EsbuildRetirementFixture(); defer { f.cleanup() }
            switch mode {
            case 0: f.replace(113, parent: 114)
            case 1: f.replace(113, uid: 0)
            case 2: f.replace(113, born: 0)
            case 3: f.nodes[115] = f.node(115, parent: 113, executable: "/fixture/claude", arguments: ["/fixture/claude", "--print", "unrelated inference"])
            case 4: f.replace(113, executable: "/fixture/codex", arguments: ["/fixture/codex", "--service=0.28.2", "--ping"])
            default: f.nodes[115] = f.node(115, parent: 112, executable: "/fixture/node", arguments: ["/fixture/node", "--eval", "unrelated model work"])
            }
            let result = await NativeLegacyRetirement.retire(paths: f.paths, io: f.io)
            XCTAssertEqual(result["status"], "refused", "mode \(mode)"); XCTAssertTrue(f.frozen.isEmpty); XCTAssertTrue(f.booted.isEmpty)
        }
        // Even matching loaded/protected argv and a valid installed binary
        // cannot make an auxiliary the hub root when no listener is advertised.
        let rootFixture = try EsbuildRetirementFixture(); defer { rootFixture.cleanup() }
        try rootFixture.makeHelperRegistrationRoot()
        let registration = try XCTUnwrap(rootFixture.registrations[NativeLegacyRetirement.labels[0]])
        let rootNode = try XCTUnwrap(rootFixture.nodes[111])
        XCTAssertTrue(NativeLegacyEsbuild.matches(rootNode, service: registration))
        let prepared = await NativeLegacyRetirement.prepare(paths: rootFixture.paths, io: rootFixture.io)
        XCTAssertEqual(prepared["status"], "refused")
        let retired = await NativeLegacyRetirement.retire(paths: rootFixture.paths, io: rootFixture.io)
        XCTAssertEqual(retired["status"], "refused"); XCTAssertFalse(retired["safeToInstall"].bool)
        XCTAssertThrowsError(try NativeLegacyRetirement.forest(registration, owner: getuid(), io: rootFixture.io), "Restored hub roots also require an actual Node role")
        XCTAssertTrue(rootFixture.frozen.isEmpty); XCTAssertTrue(rootFixture.booted.isEmpty); XCTAssertTrue(rootFixture.readyNodes.isEmpty)
    }
    func testEsbuildListenerTrafficPendingAcceptsAndLateChildrenRefuse() async throws {
        for mode in 0..<5 {
            let f = try EsbuildRetirementFixture(); defer { f.cleanup() }
            switch mode {
            case 0: f.helperSockets = .init(listeningPorts: [8780])
            case 1: f.helperSockets = .init(listeningPorts: [9999])
            case 2: f.helperSockets = .init(activeTCP: 1)
            case 3: f.helperSockets = .init(pendingAccepts: 1)
            default: f.onFreeze = { f.nodes[115] = f.node(115, parent: 113, executable: "/fixture/unknown", arguments: ["/fixture/unknown", "work"]) }
            }
            let result = await NativeLegacyRetirement.retire(paths: f.paths, io: f.io)
            XCTAssertEqual(result["status"], "refused", "mode \(mode)"); XCTAssertTrue(f.booted.isEmpty); XCTAssertTrue(f.terminated.isEmpty)
            if mode >= 2 { XCTAssertEqual(f.resumed, [222, 114, 113, 112, 111]) }
        }
    }
    func testPartialRetirementRestoresFreshOwnedNodeEsbuildForestBeforeReady() async throws {
        let f = try EsbuildRetirementFixture(); defer { f.cleanup() }; f.failShim = true
        let result = await NativeLegacyRetirement.retire(paths: f.paths, io: f.io)
        XCTAssertEqual(result["status"], "rolled-back"); XCTAssertEqual(result["safeToInstall"], false)
        XCTAssertEqual(f.restored, [NativeLegacyRetirement.labels[0]]); XCTAssertEqual(f.readyNodes.map(\.pid), [1111, 1112, 1113, 1114])
        XCTAssertEqual(f.readyNodes.first { $0.pid == 1113 }?.executable, f.binary.path)
        XCTAssertEqual(f.readyNodes.first { $0.pid == 1113 }?.parent, 1112)
        XCTAssertEqual(f.terminated, [114, 113, 112]); XCTAssertEqual(f.resumed, [222]); XCTAssertNotNil(f.nodes[700])
    }
    func testCapturedEsbuildOrphanRetiresOnlyAfterOwnedRegistrationRemoval() async throws {
        let f = try EsbuildRetirementFixture(); defer { f.cleanup() }; f.orphanHelperOnBootout = true
        let result = await NativeLegacyRetirement.retire(paths: f.paths, io: f.io)
        XCTAssertEqual(result["status"], "retired"); XCTAssertEqual(f.terminated, [113])
        let early = try EsbuildRetirementFixture(); defer { early.cleanup() }
        early.onFreeze = { early.replace(113, parent: 1) }
        let refused = await NativeLegacyRetirement.retire(paths: early.paths, io: early.io)
        XCTAssertEqual(refused["status"], "refused"); XCTAssertTrue(early.booted.isEmpty); XCTAssertTrue(early.terminated.isEmpty)
    }
    func testRestoredEsbuildListenerOrChildrenPreventRecoveryConfirmation() async throws {
        for child in [false, true] {
            let f = try EsbuildRetirementFixture(); defer { f.cleanup() }; f.failShim = true; f.badRecoveryChild = child; f.badRecoveryListener = !child
            let result = await NativeLegacyRetirement.retire(paths: f.paths, io: f.io)
            XCTAssertEqual(result["status"], "recovery-incomplete"); XCTAssertEqual(result["safeToInstall"], false)
            XCTAssertTrue(f.readyNodes.isEmpty); XCTAssertEqual(f.restored.count, 1); XCTAssertEqual(f.booted.count, 2)
        }
    }
}

private final class EsbuildRetirementFixture: @unchecked Sendable {
    let architecture: String
    let home = FileManager.default.temporaryDirectory.appendingPathComponent("retirement-esbuild-" + UUID().uuidString)
    var root: URL { home.appendingPathComponent("UniApi") }
    var paths: NativePaths { .init(root: root, home: home) }
    var tsx: URL { root.appendingPathComponent("node_modules/.pnpm/tsx@4.23.13/node_modules/tsx") }
    var esbuild: URL { root.appendingPathComponent("node_modules/.pnpm/esbuild@0.28.2/node_modules/esbuild") }
    var platform: URL { root.appendingPathComponent("node_modules/.pnpm/@esbuild+darwin-\(architecture)@0.28.2/node_modules/@esbuild/darwin-\(architecture)") }
    var binary: URL { platform.appendingPathComponent("bin/esbuild") }
    var nodes: [Int32: NativeTransferIdentity] = [:], registrations: [String: NativeLegacyRegistration] = [:]
    var frozen: [Int32] = [], resumed: [Int32] = [], terminated: [Int32] = [], booted: [String] = [], restored: [String] = []
    var readyNodes: [NativeTransferIdentity] = [], stopped = Set<Int32>(), helperSockets = NativeTransferSockets()
    var failShim = false, orphanHelperOnBootout = false, badRecoveryListener = false, badRecoveryChild = false
    var legacyPresent = true
    var onFreeze: (() -> Void)?, time = 0.0
    private let lock = NSLock(); private var leased = false
    init(architecture: String = "arm64") throws {
        self.architecture = architecture
        for path in [tsx.appendingPathComponent("dist"), esbuild, platform.appendingPathComponent("bin"), root.appendingPathComponent("server/node_modules"), esbuild.deletingLastPathComponent().appendingPathComponent("@esbuild")] { try FileManager.default.createDirectory(at: path, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700]) }
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("server/node_modules/tsx"), withDestinationURL: tsx)
        try FileManager.default.createSymbolicLink(at: tsx.deletingLastPathComponent().appendingPathComponent("esbuild"), withDestinationURL: esbuild)
        try FileManager.default.createSymbolicLink(at: esbuild.deletingLastPathComponent().appendingPathComponent("@esbuild/darwin-" + architecture), withDestinationURL: platform)
        try writeJSON(["name": "tsx", "dependencies": ["esbuild": "~0.28.0"]], tsx.appendingPathComponent("package.json"))
        try writeJSON(["name": "esbuild", "version": "0.28.2", "optionalDependencies": .object(["@esbuild/darwin-" + architecture: "0.28.2"])], esbuild.appendingPathComponent("package.json"))
        try writeJSON(["name": .string("@esbuild/darwin-" + architecture), "version": "0.28.2", "os": ["darwin"], "cpu": .array([.string(architecture)])], platform.appendingPathComponent("package.json"))
        try Data("fixture binary; never executed".utf8).write(to: binary); guard chmod(binary.path, 0o700) == 0 else { throw NativeFailure("Fixture executable mode failed") }
        for (label, pid, args, directory, port) in [
            (NativeLegacyRetirement.labels[0], Int32(111), ["/fixture/node", root.appendingPathComponent("server/node_modules/tsx/dist/cli.mjs").path, root.appendingPathComponent("server/src/main.ts").path], root.appendingPathComponent("server"), UInt16(8780)),
            (NativeLegacyRetirement.labels[1], Int32(222), ["/fixture/python3", root.appendingPathComponent("proxy/uniapi_shim.py").path], root, UInt16(8823))
        ] {
            let definition = try PropertyListSerialization.data(fromPropertyList: ["Label": label, "WorkingDirectory": directory.path, "ProgramArguments": args, "EnvironmentVariables": ["HOME": home.path, "UNIAPI_ROOT": root.path]], format: .xml, options: 0)
            registrations[label] = .init(label: label, pid: pid, definitionPath: home.appendingPathComponent("Library/LaunchAgents/" + label + ".plist"), definition: definition, arguments: args, directory: directory, sourceRoot: root, home: home, data: root.appendingPathComponent("data"), providers: root.appendingPathComponent("providers.json"), port: port)
            nodes[pid] = node(pid, parent: 1, executable: args[0], arguments: args)
        }
        addNodeChildren(rootPID: 111, mainPID: 112, helperPID: 113, monitorPID: 114)
        nodes[700] = node(700, parent: 1, executable: "/fixture/codex", arguments: ["/fixture/codex", "unrelated turn"])
    }
    func cleanup() { try? FileManager.default.removeItem(at: home) }
    func makeHelperRegistrationRoot() throws {
        let old = registrations[NativeLegacyRetirement.labels[0]]!, args = [binary.path, "--service=0.28.2", "--ping"]
        var definition = try PropertyListSerialization.propertyList(from: old.definition, options: [], format: nil) as! [String: Any]
        definition["ProgramArguments"] = args
        let bytes = try PropertyListSerialization.data(fromPropertyList: definition, format: .xml, options: 0)
        registrations[old.label] = .init(label: old.label, pid: old.pid, definitionPath: old.definitionPath, definition: bytes, arguments: args, directory: old.directory, sourceRoot: old.sourceRoot, home: old.home, data: old.data, providers: old.providers, port: old.port)
        nodes[111] = node(111, parent: 1, executable: binary.path, arguments: args)
        nodes[112] = nil; nodes[113] = nil; nodes[114] = nil; legacyPresent = false
    }
    func writeJSON(_ value: JSONValue, _ path: URL) throws { try NativeFile.writeAtomic(try value.encoded(), to: path) }
    func node(_ pid: Int32, parent: Int32, executable: String, arguments: [String], born: UInt64 = 100) -> NativeTransferIdentity {
        .init(pid: pid, parent: parent, uid: getuid(), bornSeconds: born, bornMicroseconds: 10, executable: executable, arguments: arguments)
    }
    func replace(_ pid: Int32, parent: Int32? = nil, uid: UInt32? = nil, born: UInt64? = nil, executable: String? = nil, arguments: [String]? = nil) {
        let n = nodes[pid]!
        nodes[pid] = .init(pid: pid, parent: parent ?? n.parent, uid: uid ?? n.uid, bornSeconds: born ?? n.bornSeconds, bornMicroseconds: n.bornMicroseconds, executable: executable ?? n.executable, arguments: arguments ?? n.arguments)
    }
    private func addNodeChildren(rootPID: Int32, mainPID: Int32, helperPID: Int32, monitorPID: Int32, born: UInt64 = 100) {
        let dist = root.appendingPathComponent("server/node_modules/tsx/dist"), monitor = root.appendingPathComponent("data/bin/uniapi-fans").path
        nodes[mainPID] = node(mainPID, parent: rootPID, executable: "/fixture/node", arguments: ["/fixture/node", "--require", dist.appendingPathComponent("preflight.cjs").path, "--import", dist.appendingPathComponent("loader.mjs").absoluteString, root.appendingPathComponent("server/src/main.ts").path], born: born)
        nodes[helperPID] = node(helperPID, parent: mainPID, executable: binary.path, arguments: [binary.path, "--service=0.28.2", "--ping"], born: born)
        nodes[monitorPID] = node(monitorPID, parent: mainPID, executable: monitor, arguments: [monitor, "--monitor"], born: born)
    }
    var io: NativeLegacyRetirementIO {
        .init(owner: getuid(), exclusive: {
            self.lock.lock(); guard !self.leased else { self.lock.unlock(); throw NativeFailure("Fixture lease busy") }; self.leased = true; self.lock.unlock()
            return NativeLegacyRetirementLease { self.lock.lock(); self.leased = false; self.lock.unlock() }
        }, inspect: { _ in .init(legacyPresent: self.legacyPresent, activeJobs: 0, activeCode: 0, legacyWindowRunning: false, shimPresent: true) }, registration: { label,_ in self.registrations[label] }, identity: { pid in
            guard let value = self.nodes[pid] else { throw NativeFailure("Fixture identity absent") }; return value
        }, sameInstance: { n in guard let current = self.nodes[n.pid] else { return false }; return current.uid == n.uid && current.bornSeconds == n.bornSeconds && current.bornMicroseconds == n.bornMicroseconds }, stopped: { self.stopped.contains($0.pid) }, freeze: { n in self.frozen.append(n.pid); self.stopped.insert(n.pid); self.onFreeze?() }, resume: { n in self.resumed.append(n.pid); self.stopped.remove(n.pid) }, terminate: { n in self.terminated.append(n.pid); self.nodes[n.pid] = nil; self.stopped.remove(n.pid) }, children: { pid in self.nodes.values.filter { $0.parent == pid }.map(\.pid).sorted() }, sockets: { n in
            if n.pid == 113 { return self.helperSockets }
            if n.pid == 1113, self.badRecoveryListener { return .init(listeningPorts: [8780]) }
            return .init(listeningPorts: n.pid == 222 ? [8823] : [112, 1112].contains(n.pid) ? [8780] : [])
        }, temporaryFanOwner: { _ in false }, work: { .init() }, bootout: { record,_ in
            self.booted.append(record.label)
            if record.label == NativeLegacyRetirement.labels[1], self.failShim { throw NativeLegacyBootoutFailure(disposition: .notIssued, message: "Fixture pre-command unregister refusal") }
            self.registrations[record.label] = nil; self.nodes[record.pid] = nil
            if record.label == NativeLegacyRetirement.labels[0] {
                if self.orphanHelperOnBootout { self.nodes[112] = nil; self.nodes[114] = nil; self.replace(113, parent: 1) }
                else { self.replace(112, parent: 1) }
            }
        }, restore: { record,_ in
            self.restored.append(record.label)
            let pid: Int32 = 1111
            self.registrations[record.label] = .init(label: record.label, pid: pid, definitionPath: record.definitionPath, definition: record.definition, arguments: record.arguments, directory: record.directory, sourceRoot: record.sourceRoot, home: record.home, data: record.data, providers: record.providers, port: record.port)
            self.nodes[pid] = self.node(pid, parent: 1, executable: record.arguments[0], arguments: record.arguments, born: 200)
            self.addNodeChildren(rootPID: pid, mainPID: 1112, helperPID: 1113, monitorPID: 1114, born: 200)
            if self.badRecoveryChild { self.nodes[1115] = self.node(1115, parent: 1113, executable: "/fixture/unknown", arguments: ["/fixture/unknown", "work"], born: 200) }
        }, ready: { _,nodes,_ in self.readyNodes = nodes; return true }, portsAbsent: {}, pause: { seconds in self.time += seconds }, clock: { self.time })
    }
}
