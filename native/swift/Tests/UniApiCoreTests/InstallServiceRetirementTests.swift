import XCTest
import Darwin
import CNativeSystem
@testable import UniApiCore

final class InstallServiceRetirementTests: XCTestCase {
    func testConstructionDoesNotInspectOrControlAnythingAndReadOnlyRefuses() async throws {
        let f = try InstallRetirementFixture(); defer { f.cleanup() }
        _ = try NativeInstallRetirementSystem(paths: f.paths, application: f.app, instance: f.nonce, dependencies: f.dependencies)
        XCTAssertTrue(f.commands.isEmpty); XCTAssertFalse(FileManager.default.fileExists(atPath: f.lockPath.path))
        let ro = NativePaths(root: f.paths.root, home: f.home, readOnly: true)
        let result = await NativeInstallServiceRetirement.retire(paths: ro, application: f.app, instance: f.nonce, dependencies: f.dependencies, gui: f.guiReader, nativeStatus: f.statusReader)
        XCTAssertEqual(result["status"], "refused"); XCTAssertTrue(f.commands.isEmpty); XCTAssertTrue(f.signals.isEmpty)
    }
    func testRetiresOnlyThisNativeNonceAndKeepsAllDefinitionsAndData() async throws {
        let f = try InstallRetirementFixture(); defer { f.cleanup() }
        let definitions = try f.labels.map { try Data(contentsOf: f.definition($0)) }
        let result = await f.retire()
        XCTAssertEqual(result["safeToRestore"], true); XCTAssertEqual(result["partialRecovery"], false)
        XCTAssertEqual(f.commands.filter { $0.first == "bootout" }.map { $0[1] }, f.labels.map { "gui/\(getuid())/" + $0 })
        XCTAssertEqual(try f.labels.map { try Data(contentsOf: f.definition($0)) }, definitions)
        XCTAssertTrue(f.pids.isEmpty); XCTAssertTrue(f.nodes.isEmpty); XCTAssertEqual(f.healthCalls, 1)
        XCTAssertFalse(f.commands.contains { ["bootstrap", "enable", "disable", "kickstart"].contains($0[0]) })
    }
    func testAbsentRegistrationsAreSafeOnlyWhenBothPortsAreAbsent() async throws {
        for occupied in [false, true] {
            let f = try InstallRetirementFixture(); defer { f.cleanup() }; f.pids = [:]; f.nodes = [:]; f.foreignPort = occupied
            let result = await f.retire(); XCTAssertEqual(result["safeToRestore"], .bool(!occupied))
            XCTAssertTrue(f.signals.isEmpty); XCTAssertFalse(f.commands.contains { $0[0] == "bootout" })
        }
    }
    func testForeignNonceAppArgumentsEnvironmentUIDAndControlRefuseBeforePause() async throws {
        for mode in 0..<9 {
            let f = try InstallRetirementFixture(); defer { f.cleanup() }; f.badProof = mode
            let result = await f.retire(); XCTAssertEqual(result["status"], "refused", "mode \(mode)")
            XCTAssertTrue(f.signals.isEmpty); XCTAssertFalse(f.commands.contains { $0[0] == "bootout" })
        }
    }
    func testLinkedDefinitionAndExecutableRefuse() async throws {
        for executable in [false, true] {
            let f = try InstallRetirementFixture(); defer { f.cleanup() }
            let file = executable ? f.binary(f.labels[0]) : f.definition(f.labels[0]), other = f.home.appendingPathComponent("other")
            try FileManager.default.moveItem(at: file, to: other); try FileManager.default.createSymbolicLink(at: file, withDestinationURL: other)
            let result = await f.retire(); XCTAssertEqual(result["safeToRestore"], false); XCTAssertTrue(f.signals.isEmpty)
        }
    }
    func testActiveJobsCodeUnknownChildrenAndTemporaryFanOwnersRefuse() async throws {
        for mode in 0..<4 {
            let f = try InstallRetirementFixture(); defer { f.cleanup() }
            if mode == 0 { f.work = .init(jobs: 1) }
            if mode == 1 { f.work = .init(code: 1) }
            if mode == 2 { f.addChild(arguments: ["/foreign/agent", "--work"]) }
            if mode == 3 { f.fanOwner = true }
            let result = await f.retire(); XCTAssertEqual(result["status"], "refused"); XCTAssertTrue(f.signals.isEmpty)
        }
    }
    func testOnlyReadonlyBundledFanMonitorChildIsAccepted() async throws {
        for arguments in [["--monitor"], ["--serve"], ["--monitor", "extra"], ["--probe"]] {
            let f = try InstallRetirementFixture(); defer { f.cleanup() }
            f.addChild(arguments: [f.monitor.path] + arguments)
            let result = await f.retire(); XCTAssertEqual(result["safeToRestore"], .bool(arguments == ["--monitor"]))
            if arguments != ["--monitor"] { XCTAssertTrue(f.signals.isEmpty) }
        }
    }
    func testShimNoncePIDRuntimeMissingCountAndActiveCountRefuse() async throws {
        for mode in 0..<6 {
            let f = try InstallRetirementFixture(); defer { f.cleanup() }; f.badHealth = mode
            let result = await f.retire(); XCTAssertEqual(result["safeToRestore"], false); XCTAssertTrue(f.signals.isEmpty)
        }
    }
    func testLateTrafficPendingAcceptsAndWorkResumeAllPausedIdentities() async throws {
        for mode in 0..<3 {
            let f = try InstallRetirementFixture(); defer { f.cleanup() }; f.late = mode
            let result = await f.retire(); XCTAssertEqual(result["status"], "refused")
            XCTAssertEqual(Set(f.signals.filter { $0.1 == SIGCONT }.map(\.0)), Set([111, 222])); XCTAssertTrue(f.stops.isEmpty)
            XCTAssertFalse(f.commands.contains { $0[0] == "bootout" })
        }
    }
    func testPartialUnregisterNeverKillsTheRemainingRegistrationAndReportsUnsafeRecovery() async throws {
        let f = try InstallRetirementFixture(); defer { f.cleanup() }; f.failShim = true
        let result = await f.retire(); XCTAssertEqual(result["status"], "partial-recovery"); XCTAssertEqual(result["partialRecovery"], true)
        XCTAssertEqual(result["safeToRestore"], false); XCTAssertNotNil(f.nodes[222]); XCTAssertFalse(f.stops.contains(222))
        XCTAssertTrue(f.signals.contains { $0 == (222, SIGCONT) }); XCTAssertFalse(f.signals.contains { $0.1 == SIGKILL })
        // The common transaction restores the already-absent backend before
        // reporting that the still-pending shim cannot be recovered safely.
        XCTAssertEqual(f.commands.filter { $0[0] == "bootstrap" }.count, 1)
        XCTAssertNotEqual(f.pids[f.labels[0]], 111)
    }
    func testPIDReuseAndLateDefinitionReplacementNeverSignalForeignIdentity() async throws {
        for mode in 0..<2 {
            let f = try InstallRetirementFixture(); defer { f.cleanup() }; f.replaceOnBootout = mode
            let result = await f.retire(); XCTAssertEqual(result["safeToRestore"], false); XCTAssertEqual(result["partialRecovery"], true)
            XCTAssertFalse(f.signals.contains { $0.1 == SIGKILL }); XCTAssertNotNil(f.nodes[222])
        }
    }
    func testInspectionAndDatabaseFailuresAreNotAbsenceEvidence() async throws {
        for mode in 0..<2 {
            let f = try InstallRetirementFixture(); defer { f.cleanup() }; f.readFailure = mode
            let result = await f.retire(); XCTAssertEqual(result["safeToRestore"], false); XCTAssertTrue(f.signals.isEmpty)
        }
    }
    func testNativePausedCensusIsIdleAndDoesNotWeakenLegacyOrChangeSourceDatabase() async throws {
        let f = try InstallRetirementFixture(); defer { f.cleanup() }
        let db = try NativeDatabase(url: f.paths.database)
        try db.executeScript("CREATE TABLE jobs(status TEXT); CREATE TABLE code_threads(status TEXT); INSERT INTO code_threads VALUES ('paused');")
        let files = [f.paths.database, f.paths.data.appendingPathComponent("uniapi.sqlite-wal"), f.paths.data.appendingPathComponent("uniapi.sqlite-shm")]
        let before = try files.map { try Data(contentsOf: $0) }
        XCTAssertThrowsError(try NativeLegacyWorkReader(paths: f.paths).read())
        let native = NativeInstallServiceRetirement.nativeWork(paths: f.paths)
        XCTAssertTrue(try native().isIdle); XCTAssertTrue(try native().isIdle)
        var dependencies = f.dependencies; dependencies.work = native
        let result = await NativeInstallServiceRetirement.retire(paths: f.paths, application: f.app, instance: f.nonce, dependencies: dependencies, gui: f.guiReader, nativeStatus: f.statusReader)
        XCTAssertEqual(result["safeToRestore"], true)
        XCTAssertEqual(try files.map { try Data(contentsOf: $0) }, before)
    }
    func testNativeCensusKeepsActiveAndUnknownOrNullStatesUnsafe() throws {
        let f = try InstallRetirementFixture(); defer { f.cleanup() }
        let db = try NativeDatabase(url: f.paths.database)
        try db.executeScript("CREATE TABLE jobs(status TEXT); CREATE TABLE code_threads(status TEXT);")
        let native = NativeInstallServiceRetirement.nativeWork(paths: f.paths)
        for status in ["starting", "running", "waiting"] {
            try db.execute("INSERT INTO code_threads VALUES (?)", [.string(status)])
            XCTAssertEqual(try native().code, 1)
            try db.executeScript("DELETE FROM code_threads;")
        }
        for table in ["jobs", "code_threads"] {
            for status in [JSONValue.string("future-unknown"), .null] {
                try db.execute("INSERT INTO \(table) VALUES (?)", [status])
                XCTAssertThrowsError(try native())
                try db.executeScript("DELETE FROM \(table);")
            }
        }
        try db.executeScript("INSERT INTO jobs VALUES ('queued'); INSERT INTO code_threads VALUES ('paused');")
        XCTAssertEqual(try native().jobs, 1)
    }
    func testLoadedStartupJobWithoutPIDIsNotAbsenceAndNeverBlindlyUnregistered() async throws {
        for mode in 0..<2 {
            let f = try InstallRetirementFixture(); defer { f.cleanup() }; f.noPID = mode
            let result = await f.retire(); XCTAssertEqual(result["status"], "refused"); XCTAssertEqual(result["safeToRestore"], false)
            XCTAssertTrue(f.signals.isEmpty); XCTAssertFalse(f.commands.contains { $0[0] == "bootout" })
        }
    }
    func testAbsentRoutingOverridesUseRootDefaults() async throws {
        let f = try InstallRetirementFixture(); defer { f.cleanup() }
        XCTAssertNil(f.environment["UNIAPI_DATA"]); XCTAssertNil(f.environment["UNIAPI_PROVIDERS"])
        let db = try f.database(f.paths)
        var dependencies = f.dependencies; dependencies.work = NativeInstallServiceRetirement.nativeWork(paths: f.paths)
        let result = await NativeInstallServiceRetirement.retire(paths: f.paths, application: f.app, instance: f.nonce, dependencies: dependencies, gui: f.guiReader, nativeStatus: f.statusReader)
        XCTAssertEqual(result["safeToRestore"], true); withExtendedLifetime(db) {}
    }
    func testAbsentDataOverrideCannotHideOriginalQueuedJobBehindAnotherIdleDatabase() async throws {
        let f = try InstallRetirementFixture(); defer { f.cleanup() }
        let original = try f.database(f.paths); try original.execute("INSERT INTO jobs VALUES ('queued')")
        let caller = NativePaths(root: f.paths.root, home: f.home, dataRoot: f.home.appendingPathComponent("other-data"))
        let unrelated = try f.database(caller), native = NativeInstallServiceRetirement.nativeWork(paths: caller)
        XCTAssertEqual(try NativeInstallServiceRetirement.nativeWork(paths: f.paths)().jobs, 1); XCTAssertTrue(try native().isIdle)
        var dependencies = f.dependencies; dependencies.work = { f.workReads += 1; return try native() }
        let result = await NativeInstallServiceRetirement.retire(paths: caller, application: f.app, instance: f.nonce, dependencies: dependencies, gui: f.guiReader, nativeStatus: f.statusReader)
        XCTAssertEqual(result["status"], "refused"); XCTAssertEqual(result["safeToRestore"], false)
        XCTAssertEqual(f.workReads, 0); XCTAssertTrue(f.signals.isEmpty); XCTAssertFalse(f.commands.contains { $0[0] == "bootout" })
        XCTAssertEqual(try original.query("SELECT status FROM jobs").first?["status"], "queued"); withExtendedLifetime(unrelated) {}
    }
    func testAbsentProviderOverrideCannotRetireDifferentProviderSelection() async throws {
        let f = try InstallRetirementFixture(); defer { f.cleanup() }
        let db = try f.database(f.paths), caller = NativePaths(root: f.paths.root, home: f.home, providersFile: f.home.appendingPathComponent("other-providers.json"))
        let native = NativeInstallServiceRetirement.nativeWork(paths: caller)
        var dependencies = f.dependencies; dependencies.work = { f.workReads += 1; return try native() }
        let result = await NativeInstallServiceRetirement.retire(paths: caller, application: f.app, instance: f.nonce, dependencies: dependencies, gui: f.guiReader, nativeStatus: f.statusReader)
        XCTAssertEqual(result["safeToRestore"], false); XCTAssertEqual(f.workReads, 0); XCTAssertTrue(f.signals.isEmpty)
        XCTAssertFalse(f.commands.contains { $0[0] == "bootout" }); withExtendedLifetime(db) {}
    }
    func testExplicitExternalDataAndProviderRoutesMustBothMatch() async throws {
        for mismatch in 0..<3 {
            let f = try InstallRetirementFixture(); defer { f.cleanup() }
            let data = f.home.appendingPathComponent("selected-data"), providers = f.home.appendingPathComponent("selected-providers.json")
            try f.declareRouting(["UNIAPI_DATA": data.path, "UNIAPI_PROVIDERS": providers.path])
            let selected = NativePaths(root: f.paths.root, home: f.home, dataRoot: data, providersFile: providers)
            let caller = NativePaths(root: f.paths.root, home: f.home,
                dataRoot: mismatch == 1 ? f.home.appendingPathComponent("wrong-data") : data,
                providersFile: mismatch == 2 ? f.home.appendingPathComponent("wrong-providers.json") : providers)
            let db = try f.database(selected), other = mismatch == 1 ? try f.database(caller) : nil
            let native = NativeInstallServiceRetirement.nativeWork(paths: caller)
            var dependencies = f.dependencies; dependencies.work = { f.workReads += 1; return try native() }
            let result = await NativeInstallServiceRetirement.retire(paths: caller, application: f.app, instance: f.nonce, dependencies: dependencies, gui: f.guiReader, nativeStatus: f.statusReader)
            XCTAssertEqual(result["safeToRestore"], .bool(mismatch == 0))
            if mismatch != 0 { XCTAssertEqual(f.workReads, 0); XCTAssertTrue(f.signals.isEmpty); XCTAssertFalse(f.commands.contains { $0[0] == "bootout" }) }
            withExtendedLifetime((db, other)) {}
        }
    }
    func testSurvivingReparentedReadonlyMonitorIsRetiredByItsCapturedBirth() async throws {
        let f = try InstallRetirementFixture(); defer { f.cleanup() }; f.keepMonitor = true
        f.addChild(arguments: [f.monitor.path, "--monitor"])
        let result = await f.retire(); XCTAssertEqual(result["safeToRestore"], true)
        XCTAssertTrue(f.signals.contains { $0 == (112, SIGKILL) }); XCTAssertTrue(f.nodes.isEmpty)
    }
    func testDeadlineAndResumeFailureRemainUnsafeAndHonest() async throws {
        for mode in 0..<2 {
            let f = try InstallRetirementFixture(); defer { f.cleanup() }
            if mode == 0 { f.keepProcesses = true } else { f.late = 2; f.failResume = true }
            let result = await f.retire(); XCTAssertEqual(result["safeToRestore"], false); XCTAssertEqual(result["partialRecovery"], true)
        }
    }
    func testCancellationAfterPauseStillResumesTheOwnedInstance() async throws {
        let f = try InstallRetirementFixture(); defer { f.cleanup() }; f.cancelAfterPause = true
        let task = Task { await f.retire() }, result = await task.value
        XCTAssertEqual(result["safeToRestore"], false); XCTAssertTrue(f.stops.isEmpty)
        XCTAssertTrue(f.signals.contains { $0 == (111, SIGCONT) }); XCTAssertFalse(f.commands.contains { $0[0] == "bootout" })
    }
    func testLockReplacementAfterPauseBlocksUnregisterButResumesCapturedInstances() async throws {
        let f = try InstallRetirementFixture(); defer { f.cleanup() }; f.replaceLockAfterPause = true
        let result = await f.retire(); XCTAssertEqual(result["status"], "refused"); XCTAssertTrue(f.stops.isEmpty)
        XCTAssertEqual(Set(f.signals.filter { $0.1 == SIGCONT }.map(\.0)), Set([111, 222]))
        XCTAssertFalse(f.commands.contains { $0[0] == "bootout" })
    }
    func testClosedOwnershipLeaseExemptionIsExactAndNeverAppliesToShimOrLiveTCP() {
        var socket = socket_fdinfo(); socket.psi.soi_kind = Int32(SOCKINFO_TCP)
        socket.psi.soi_proto.pri_tcp.tcpsi_state = TSI_S_CLOSED
        socket.psi.soi_proto.pri_tcp.tcpsi_ini.insi_vflag = UInt8(INI_IPV4)
        socket.psi.soi_proto.pri_tcp.tcpsi_ini.insi_lport = Int32(UInt16(8780).bigEndian)
        socket.psi.soi_proto.pri_tcp.tcpsi_ini.insi_laddr.ina_46.i46a_addr4.s_addr = inet_addr("127.0.0.1")
        XCTAssertTrue(NativeInstallServiceSockets.isLease(socket, backend: true)); XCTAssertFalse(NativeInstallServiceSockets.isLease(socket, backend: false))
        for mode in 0..<6 {
            var other = socket
            switch mode {
            case 0: other.psi.soi_proto.pri_tcp.tcpsi_state = TSI_S_ESTABLISHED
            case 1: other.psi.soi_proto.pri_tcp.tcpsi_state = TSI_S__CLOSE_WAIT
            case 2: other.psi.soi_proto.pri_tcp.tcpsi_ini.insi_fport = 123
            case 3: other.psi.soi_qlen = 1
            case 4: other.psi.soi_proto.pri_tcp.tcpsi_ini.insi_laddr.ina_46.i46a_addr4.s_addr = 0
            default: other.psi.soi_proto.pri_tcp.tcpsi_ini.insi_lport = Int32(UInt16(8823).bigEndian)
            }
            XCTAssertFalse(NativeInstallServiceSockets.isLease(other, backend: true))
        }
    }
}

final class InstallRetirementFixture: @unchecked Sendable {
    let home = FileManager.default.temporaryDirectory.appendingPathComponent("install-retirement-" + UUID().uuidString)
    let nonce = UUID().uuidString, labels = NativeLegacyRetirement.labels
    var paths: NativePaths { .init(root: home.appendingPathComponent("repository"), home: home) }
    var app: URL { home.appendingPathComponent("Applications/UniApi.app") }
    var monitor: URL { app.appendingPathComponent("Contents/Resources/Helpers/uniapi-fans") }
    var lockPath: URL { home.appendingPathComponent("Library/Application Support/UniApi Native Transfer/transfer.lock") }
    var pids: [String: Int32] = [:], nodes: [Int32: NativeTransferIdentity] = [:], stops = Set<Int32>()
    var commands: [[String]] = [], signals: [(Int32, Int32)] = [], healthCalls = 0, workReads = 0, time = 0.0
    var routing: [String: String] = [:]
    var sourcePaths: [String: URL] = [:], issuedTimes: [String: Double] = [:], bootoutTimes: [String: Double] = [:]
    var bootoutDelay = 0.0, shimDelayOffset = 0.0, throwDyingIdentity = false, dyingIdentityQueries = 0, issuedBackendWorkReads = 0
    var failShimAfterRemoval = false, cancelBootout = false, cancellationIssued = false, recoveryUncancelled = true
    var nextPID: Int32 = 1000, nativeHealthReads = 0, badNativeHealth: Int?, guiMode: Int?, guiAfterPause = false, guiAfterIssue = false, guiReads = 0
    var work = NativeTransferWork(), badProof: Int?, badHealth: Int?, late: Int?, readFailure: Int?, replaceOnBootout: Int?, noPID: Int?
    var fanOwner = false, foreignPort = false, failShim = false, keepMonitor = false, keepProcesses = false, failResume = false, cancelAfterPause = false, replaceLockAfterPause = false
    init() throws {
        try paths.ensureDirectories()
        try FileManager.default.createDirectory(at: home.appendingPathComponent("Library/LaunchAgents"), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        for (label, pid) in zip(labels, [Int32(111), Int32(222)]) {
            let data = try PropertyListSerialization.data(fromPropertyList: ["Label": label, "ProgramArguments": argv(label), "WorkingDirectory": paths.root.path,
                "EnvironmentVariables": environment, "KeepAlive": true], format: .xml, options: 0)
            try NativeFile.writeAtomic(data, to: definition(label)); try NativeFile.writeAtomic(Data("fixture executable".utf8), to: binary(label), permissions: 0o700)
            pids[label] = pid; nodes[pid] = node(pid, parent: 1, arguments: argv(label))
        }
        try NativeFile.writeAtomic(Data("fixture monitor".utf8), to: monitor, permissions: 0o700)
    }
    func cleanup() { try? FileManager.default.removeItem(at: home) }
    var environment: [String: String] { ["HOME": home.path, "UNIAPI_ROOT": paths.root.path, "UNIAPI_NATIVE_INSTALL_NONCE": nonce].merging(routing) { _, newer in newer } }
    func declareRouting(_ values: [String: String]) throws {
        routing = values
        for label in labels {
            var plist = try PropertyListSerialization.propertyList(from: Data(contentsOf: definition(label)), format: nil) as! [String: Any]
            plist["EnvironmentVariables"] = environment
            try NativeFile.writeAtomic(try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0), to: definition(label))
        }
    }
    func database(_ locations: NativePaths) throws -> NativeDatabase {
        let db = try NativeDatabase(url: locations.database)
        try db.executeScript("CREATE TABLE jobs(status TEXT); CREATE TABLE code_threads(status TEXT);")
        return db
    }
    func definition(_ label: String) -> URL { home.appendingPathComponent("Library/LaunchAgents/" + label + ".plist") }
    func binary(_ label: String) -> URL { app.appendingPathComponent(label == labels[0] ? "Contents/MacOS/UniApiNative" : "Contents/Resources/Helpers/uniapi-shim") }
    func argv(_ label: String) -> [String] { [binary(label).path, label == labels[0] ? "--background" : "--serve"] }
    func node(_ pid: Int32, parent: Int32, arguments: [String]) -> NativeTransferIdentity {
        .init(pid: pid, parent: parent, uid: getuid(), bornSeconds: 100, bornMicroseconds: UInt64(pid), executable: arguments[0], arguments: arguments)
    }
    func addChild(arguments: [String]) { nodes[112] = node(112, parent: 111, arguments: arguments) }
    func output(_ status: Int32 = 0, _ text: String = "", _ error: String = "") -> NativeProcessResult { .init(status: status, stdout: Data(text.utf8), stderr: Data(error.utf8)) }
    func job(_ label: String) -> String {
        var args = argv(label), env = environment
        if badProof == 0 { env["UNIAPI_NATIVE_INSTALL_NONCE"] = UUID().uuidString }
        if badProof == 1 { args[0] = "/foreign/UniApiNative" }
        if badProof == 2 { args.append("--profile-results") }
        if badProof == 3 { env["UNIAPI_DATA"] = "/foreign/data" }
        if badProof == 4 { env["UNIAPI_NATIVE_READ_ONLY"] = "1" }
        let domain = badProof == 7 ? "gui/999" : "gui/\(getuid())"
        let path = badProof == 8 ? home.appendingPathComponent("unowned.plist") : sourcePaths[label] ?? definition(label)
        let pid = noPID == 0 ? "" : " pid = \(noPID == 1 ? 0 : pids[label]!)\n"
        return "\(domain)/\(label) = {\n path = \(path.path)\n program = \(args[0])\n arguments = {\n \(args.joined(separator: "\n "))\n }\n environment = {\n \(env.sorted { $0.key < $1.key }.map { $0.key + " => " + $0.value }.joined(separator: "\n "))\n }\n\(pid)}\n"
    }
    var dependencies: NativeLegacySystemDependencies {
        .init(owner: getuid(), home: home, command: { [self] args, _ in
            commands.append(args)
            if cancellationIssued { recoveryUncancelled = recoveryUncancelled && !Task.isCancelled }
            if args[0] == "bootstrap" {
                let file = URL(fileURLWithPath: args[2]), label = file.deletingPathExtension().lastPathComponent
                guard try Data(contentsOf: file) == Data(contentsOf: definition(label)), pids[label] == nil else { throw NativeFailure("Invalid fixture bootstrap") }
                nextPID += 1; pids[label] = nextPID; sourcePaths[label] = file
                nodes[nextPID] = .init(pid: nextPID, parent: 1, uid: getuid(), bornSeconds: 200, bornMicroseconds: UInt64(nextPID), executable: binary(label).path, arguments: argv(label))
                return output()
            }
            if args[0] == "print-disabled" { return output(0, "disabled services = {\n \"\(labels[0])\" => \(badProof == 6 ? "true" : "false")\n}") }
            let label = args[1].components(separatedBy: "/").last!
            if args[0] == "print" {
                if let issued = issuedTimes[label], pids[label] == (label == labels[0] ? 111 : 222), time - issued >= bootoutDelay + (label == labels[1] ? shimDelayOffset : 0) { complete(label) }
                if readFailure == 0 { return output(1, "", "permission denied") }
                guard pids[label] != nil else { return output(113, "", "Could not find service \"\(label)\" in domain for user gui: \(getuid())") }
                return output(0, job(label))
            }
            if args[0] == "bootout" {
                bootoutTimes[label] = time
                if label == labels[1], failShim {
                    if failShimAfterRemoval { complete(label); throw NativeFailure("Fixture transport failure after removal") }
                    return output(1)
                }
                if label == labels[0], let mode = replaceOnBootout {
                    if mode == 0 { nodes[111] = .init(pid: 111, parent: 1, uid: getuid(), bornSeconds: 999, bornMicroseconds: 1, executable: "/foreign", arguments: ["/foreign"]) }
                    else { badProof = 0 }
                    return output(1)
                }
                issuedTimes[label] = time
                if bootoutDelay == 0 { complete(label) }
                if cancelBootout && label == labels[1] { cancellationIssued = true; withUnsafeCurrentTask { $0?.cancel() } }
                return output()
            }
            throw NativeFailure("Unexpected fixture control")
        }, inspect: { _ in throw NativeFailure("No advisory API needed") }, identity: { [self] pid in
            let label = pid == 111 ? labels[0] : labels[1]
            if throwDyingIdentity, [111, 222].contains(pid), issuedTimes[label] != nil, pids[label] == pid {
                dyingIdentityQueries += 1; throw NativeFailure("Dying fixture kernel identity must not be queried")
            }
            guard let value = nodes[pid] else { throw NativeFailure("Fixture absent identity") }
            if badProof == 5 { return .init(pid: value.pid, parent: value.parent, uid: value.uid + 1, bornSeconds: value.bornSeconds, bornMicroseconds: value.bornMicroseconds, executable: value.executable, arguments: value.arguments) }
            return value
        }, directory: { [self] _ in paths.root }, same: { [self] node in nodes[node.pid].map { $0.bornSeconds == node.bornSeconds && $0.bornMicroseconds == node.bornMicroseconds } ?? false },
           stopped: { [self] in stops.contains($0.pid) }, children: { [self] pid in nodes.values.filter { $0.parent == pid }.map(\.pid).sorted() },
           sockets: { [self] node in
               guard let current = nodes[node.pid], NativeLegacyRetirementSystem.sameExecution(current, node) else { throw NativeFailure("Fixture socket execution changed") }
               // A fresh bootstrap changes the PID, not the shim executable
               // role. An old paused survivor retains its listener even after
               // its launch registration has been removed.
               let shim = current.uid == getuid() && current.parent == 1 && current.bornSeconds > 0 && current.bornMicroseconds < 1_000_000 &&
                   current.executable == binary(labels[1]).path && current.arguments == argv(labels[1])
               let lateActive = stops.count >= 2 && late == 0, pending = stops.count >= 2 && late == 1
               return .init(listeningPorts: shim ? [8823] : [], activeTCP: lateActive ? 1 : 0, pendingAccepts: pending ? 1 : 0)
           }, signal: { [self] node, number in
               signals.append((node.pid, number))
               if number == SIGSTOP {
                   stops.insert(node.pid); if cancelAfterPause { withUnsafeCurrentTask { $0?.cancel() } }
                   if stops.count == 2 && replaceLockAfterPause { try FileManager.default.removeItem(at: lockPath); try NativeFile.writeAtomic(Data(), to: lockPath) }
               }
               if number == SIGCONT { if failResume { throw NativeFailure("Fixture resume failure") }; stops.remove(node.pid) }
               if number == SIGKILL && !keepProcesses { nodes.removeValue(forKey: node.pid); stops.remove(node.pid) }
           }, fanOwner: { [self] _ in fanOwner }, work: { [self] in
               workReads += 1
               if issuedTimes[labels[0]] != nil, pids[labels[0]] == nil || pids[labels[0]] == 111 { issuedBackendWorkReads += 1; throw NativeFailure("Issued backend must not be rescanned") }
               if readFailure == 1 { throw NativeFailure("Fixture private database unreadable") }
               return stops.count >= 2 && late == 2 ? .init(jobs: 1) : work
           }, health: { [self] _, _ in
               healthCalls += 1
               var value: JSONValue = ["ok": true, "service": "uniapi-shim", "runtime": "swift", "instance": .string(nonce), "pid": .number(Double(pids[labels[1]] ?? 222)), "activeRequests": 0]
               if let mode = badHealth { switch mode { case 0: value["instance"] = "other"; case 1: value["pid"] = 223; case 2: value["runtime"] = "python"; case 3: value["activeRequests"] = .null; case 4: value["activeRequests"] = 1; default: value["activeRequests"] = "0" } }
               return value
           }, absent: { [self] in guard pids.isEmpty, !foreignPort else { throw NativeFailure("Fixture port remains occupied") } },
           pause: { [self] seconds in time += seconds }, clock: { [self] in time })
    }
    func complete(_ label: String) {
        guard let pid = pids.removeValue(forKey: label) else { return }
        for node in Array(nodes.values) where node.pid == pid || node.parent == pid {
            if keepProcesses { continue }
            if keepMonitor && node.parent == pid { nodes[node.pid] = .init(pid: node.pid, parent: 1, uid: node.uid, bornSeconds: node.bornSeconds, bornMicroseconds: node.bornMicroseconds, executable: node.executable, arguments: node.arguments); continue }
            nodes.removeValue(forKey: node.pid); stops.remove(node.pid)
        }
    }
    var guiReader: NativeUpdateGUIAdmission.Reader { { [self] in
        guiReads += 1
        let active = (!guiAfterPause || !stops.isEmpty) && (!guiAfterIssue || !bootoutTimes.isEmpty)
        let mode = active ? guiMode : nil
        var apps: [NativeUpdateGUIAdmission.Application] = []
        if let pid = pids[labels[0]], mode != 4 {
            apps.append(.init(pid: pid, bundle: app, executable: binary(labels[0]), identifier: "app.devved.uniapi.hub", activation: mode == 0 ? .regular : mode == 3 ? .unknown : .accessory))
        }
        if mode == 2 { apps.append(.init(pid: 900, bundle: app, executable: binary(labels[0]), identifier: "app.devved.uniapi.hub", activation: .accessory)) }
        let windows: [NativeUpdateGUIAdmission.Window] = pids[labels[0]].map { pid in
            let layer = mode == 6 ? 101 : mode == 7 ? 8 : mode == 8 ? 3 : mode == 9 ? 25 : 0
            return [.init(pid: pid, layer: mode == 5 ? nil : layer, onScreen: mode == 1 || (mode ?? -1) >= 6,
                          bounds: mode == 9 ? CGRect(x: 1200, y: 0, width: 100, height: 24) : CGRect(x: 500, y: 200, width: 300, height: 400))]
        } ?? []
        return .init(applications: apps, windows: windows, displayBounds: [CGRect(x: 0, y: 0, width: 1440, height: 900)])
    } }
    var statusReader: @Sendable (Int32, String) throws -> JSONValue { { [self] pid, requested in
        nativeHealthReads += 1
        if cancellationIssued { recoveryUncancelled = recoveryUncancelled && !Task.isCancelled }
        var value: JSONValue = ["schema": 2, "runtime": "swift", "instance": .string(requested), "pid": .number(Double(pid)), "ready": true, "error": .null, "updatedAt": 250000]
        if let mode = badNativeHealth { switch mode { case 0: value["instance"] = "other"; case 1: value["pid"] = .number(Double(pid + 1)); case 2: value["runtime"] = "node"; case 3: value["ready"] = false; case 4: value["ready"] = "true"; default: value["updatedAt"] = 1 } }
        return value
    } }
    var updateDependencies: NativeUpdateDependencies { .init(system: dependencies, gui: guiReader, nativeStatus: statusReader) }
    func hashes() throws -> [String: String] {
        try Dictionary(uniqueKeysWithValues: labels.map { ($0, NativeLegacyRetirement.hash(try Data(contentsOf: definition($0)))) })
    }
    func retire() async -> JSONValue { await NativeInstallServiceRetirement.retire(paths: paths, application: app, instance: nonce, dependencies: dependencies, gui: guiReader, nativeStatus: statusReader) }
}
