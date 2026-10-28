import Foundation
import XCTest
@testable import UniApiCore

private final class RoutingCommandFixture: @unchecked Sendable {
    typealias Command = NativeCodexRoutingCommand
    private let lock = NSLock()
    var states: [JSONValue]
    var fingerprints: [Command.Fingerprint]
    var statusError = false, actionError = false, cancelSleep = false, fingerprintError = false
    var actionResponse: JSONValue?
    private(set) var actions: [String] = [], sleeps: [TimeInterval] = []
    private(set) var reads = 0, factoryCalls = 0
    private var clock: TimeInterval = 0
    init(_ states: [JSONValue]) {
        self.states = states
        fingerprints = [.init(config: "a", providers: "b", bridgeConfig: "c", bridgeCatalog: "d", nativeCatalog: nil)]
    }
    func io() -> Command.IO {
        lock.withLock { factoryCalls += 1 }
        return .init(status: { try self.lock.withLock {
            self.reads += 1
            if self.statusError { throw NativeFailure("private transport /private/operator/capability") }
            let value = self.states[0]
            if self.states.count > 1 { self.states.removeFirst() }
            return value
        } }, action: { action in try self.lock.withLock {
            self.actions.append(action)
            if self.actionError { throw NativeFailure("private action /private/operator/capability") }
            if let response = self.actionResponse { return response }
            var status = self.states[0]
            status["native"]["connected"] = .bool(action == "nativeConnect")
            status["bridge"]["integrated"] = false
            return ["ok": true, "message": "private manager message", "reloadRequired": true, "status": status]
        } }, fingerprint: { try self.lock.withLock {
            if self.fingerprintError { throw NativeFailure("private fingerprint path") }
            let value = self.fingerprints[0]
            if self.fingerprints.count > 1 { self.fingerprints.removeFirst() }
            return value
        } }, now: { self.lock.withLock { self.clock } }, sleep: { seconds in try self.lock.withLock {
            self.sleeps.append(seconds)
            if self.cancelSleep { throw CancellationError() }
            self.clock += seconds
        } })
    }
    func run(_ arguments: [String]) async -> Command.Result {
        await Command.run(arguments, makeIO: { _ in self.io() })
    }
}

final class CodexRoutingCommandTests: XCTestCase {
    private var idle: JSONValue {
        ["configError": .null, "restoreAvailable": true, "catalog": ["error": .null],
         "native": ["connected": false, "running": true, "accepting": true, "activeRequests": 0, "error": .null, "healthError": .null],
         "bridge": ["integrated": true, "running": true, "busy": false]]
    }
    private var busy: JSONValue { var value = idle; value["bridge"]["busy"] = true; return value }
    private let wait = ["--codex-routing", "connect", "--wait-for-idle", "600"]

    func testInvalidArgumentsNeverConstructRuntimeOrReachIO() async {
        let malformed = [[], ["--codex-routing"], ["--codex-routing=status"], ["--codex-routing", "start"],
            ["--codex-routing", "connect", "--force"], ["--version", "--codex-routing", "status"],
            ["--codex-routing", "status", "--wait-for-idle", "1"], ["--codex-routing", "restore", "--wait-for-idle", "1"],
            ["--codex-routing", "connect", "--wait-for-idle"], ["--codex-routing", "connect", "--wait-for-idle", "1", "extra"]]
        for arguments in malformed {
            let f = RoutingCommandFixture([idle]), result = await f.run(arguments)
            XCTAssertEqual(result.exitCode, 64, "\(arguments)"); XCTAssertEqual(f.factoryCalls, 0)
        }
        for seconds in ["0", "601", "-1", "+1", "1.0", " 1", "1e2", "999999999999999999999999"] {
            let f = RoutingCommandFixture([idle])
            let result = await f.run(["--codex-routing", "connect", "--wait-for-idle", seconds])
            XCTAssertEqual(result.exitCode, 64); XCTAssertEqual(f.factoryCalls, 0)
        }
    }

    func testStatusIsSafeTypedProjectionAndNeverCallsAction() async throws {
        var value = idle
        let secret = "PRIVATE_CAPABILITY"
        value["configPath"] = .string(secret); value["current"] = ["model": .string(secret)]
        value["native"]["baseUrl"] = .string(secret); value["native"]["token"] = .string(secret)
        value["warnings"] = [.string(secret)]; value["models"] = [["id": .string(secret)]]
        value["bridge"]["controlToken"] = .string(secret)
        let f = RoutingCommandFixture([value]), result = await f.run(["--codex-routing", "status"])
        XCTAssertEqual(result.exitCode, 0); XCTAssertTrue(f.actions.isEmpty); XCTAssertTrue(f.sleeps.isEmpty)
        XCTAssertEqual(result.json["status"]["native"]["activeRequests"], 0)
        XCTAssertEqual(Set(result.json["status"].object.keys), ["configurationError", "catalogError", "restoreAvailable", "native", "bridge"])
        XCTAssertFalse(String(decoding: try result.json.encoded(), as: UTF8.self).contains(secret))
        value["native"]["connected"] = .string(secret); value["native"]["activeRequests"] = .string(secret)
        value["bridge"]["busy"] = .string(secret); value["native"]["error"] = .string(secret)
        let malformed = NativeCodexRoutingCommand.summary(value)
        XCTAssertEqual(malformed["native"]["ownershipError"], true)
        XCTAssertTrue(malformed["native"]["connected"].isNull); XCTAssertTrue(malformed["native"]["activeRequests"].isNull)
        XCTAssertTrue(malformed["bridge"]["busy"].isNull)
        XCTAssertFalse(String(decoding: try malformed.encoded(), as: UTF8.self).contains(secret))
    }

    func testImmediateBusyRefusesBothMutationsWithoutCallingAction() async {
        for operation in ["connect", "restore"] {
            for nativeBusy in [false, true] {
                var state = busy
                if nativeBusy { state = idle; state["native"]["connected"] = true; state["native"]["activeRequests"] = 1 }
                let f = RoutingCommandFixture([state]), result = await f.run(["--codex-routing", operation])
                XCTAssertEqual(result.exitCode, 2); XCTAssertEqual(result.json["outcome"], "busy")
                XCTAssertTrue(f.actions.isEmpty); XCTAssertTrue(f.sleeps.isEmpty)
            }
        }
    }

    func testIdleCommandsDelegateOnlyToExistingNativeActionsAndSanitizeResponse() async throws {
        for (operation, action) in [("connect", "nativeConnect"), ("restore", "restore")] {
            let f = RoutingCommandFixture([idle]), result = await f.run(["--codex-routing", operation])
            XCTAssertEqual(result.exitCode, 0); XCTAssertEqual(f.actions, [action])
            XCTAssertEqual(result.json["reloadRequired"], true)
            XCTAssertEqual(result.json["status"]["native"]["connected"], .bool(operation == "connect"))
            XCTAssertEqual(result.json["status"]["bridge"]["integrated"], false)
            XCTAssertFalse(String(decoding: try result.json.encoded(), as: UTF8.self).contains("private manager message"))
        }
    }

    func testAcknowledgedWrongPostconditionIsUncertainWithoutRetryOrPrivateOutput() async throws {
        let secret = "PRIVATE_POSTCONDITION_CAPABILITY"
        for operation in ["connect", "restore"] {
            var correct = idle
            correct["native"]["connected"] = .bool(operation == "connect")
            correct["bridge"]["integrated"] = false
            var conflicts: [JSONValue] = []
            var state = correct; state["native"]["connected"] = .bool(operation != "connect"); conflicts.append(state)
            state = correct; state["bridge"]["integrated"] = true; conflicts.append(state)
            state = correct; state["native"]["connected"] = .string(secret); conflicts.append(state)
            state = correct; state["bridge"]["integrated"] = .string(secret); conflicts.append(state)
            state = correct; state["configError"] = .string(secret); conflicts.append(state)
            state = correct; state["native"]["error"] = .string(secret); conflicts.append(state)
            state = correct; state["catalog"]["error"] = .string(secret); conflicts.append(state)
            state = correct; state["catalog"] = [:]; conflicts.append(state)
            var fields = correct.object; fields.removeValue(forKey: "configError"); conflicts.append(.object(fields))
            state = correct; var native = state["native"].object; native.removeValue(forKey: "error")
            state["native"] = .object(native); conflicts.append(state)
            conflicts.append(.null)
            for var status in conflicts {
                if !status.isNull {
                    status["configPath"] = .string(secret); status["native"]["baseUrl"] = .string(secret)
                    status["native"]["token"] = .string(secret); status["bridge"]["controlToken"] = .string(secret)
                    status["warnings"] = [.string(secret)]
                }
                let f = RoutingCommandFixture([idle])
                f.actionResponse = ["ok": true, "reloadRequired": true, "message": .string(secret), "status": status]
                let result = await f.run(operation == "connect" ? wait : ["--codex-routing", "restore"])
                XCTAssertEqual(result.exitCode, 1); XCTAssertEqual(result.json["outcome"], "uncertain")
                XCTAssertEqual(result.json["ok"], false); XCTAssertEqual(result.json["reloadRequired"], false)
                XCTAssertEqual(f.actions, [operation == "connect" ? "nativeConnect" : "restore"])
                XCTAssertEqual(f.reads, 1); XCTAssertTrue(f.sleeps.isEmpty)
                XCTAssertFalse(String(decoding: try result.json.encoded(), as: UTF8.self).contains(secret))
            }
        }
    }

    func testWaitObservesBothIdleOwnersBeforeOneNormalAction() async {
        var nativeBusy = idle; nativeBusy["native"]["activeRequests"] = 1
        let f = RoutingCommandFixture([busy, nativeBusy, idle]), result = await f.run(wait)
        XCTAssertEqual(result.exitCode, 0); XCTAssertEqual(f.reads, 3)
        XCTAssertEqual(f.sleeps, [1, 1]); XCTAssertEqual(f.actions, ["nativeConnect"])
    }

    func testWaitTimesOutAtRequestedBoundWithNoMutation() async {
        let f = RoutingCommandFixture([busy]), result = await f.run(wait)
        XCTAssertEqual(result.exitCode, 2); XCTAssertEqual(result.json["outcome"], "timed_out")
        XCTAssertEqual(f.sleeps.count, 600); XCTAssertEqual(f.sleeps.reduce(0, +), 600)
        XCTAssertTrue(f.sleeps.allSatisfy { $0 <= 1 }); XCTAssertTrue(f.actions.isEmpty)
    }

    func testEveryPinnedFingerprintChangeRefusesEvenWhenOwnersBecomeIdle() async {
        typealias Fingerprint = NativeCodexRoutingCommand.Fingerprint
        let changed: [Fingerprint] = [
            .init(config: "changed", providers: "b", bridgeConfig: "c", bridgeCatalog: "d", nativeCatalog: nil),
            .init(config: "a", providers: "changed", bridgeConfig: "c", bridgeCatalog: "d", nativeCatalog: nil),
            .init(config: "a", providers: "b", bridgeConfig: "changed", bridgeCatalog: "d", nativeCatalog: nil),
            .init(config: "a", providers: "b", bridgeConfig: "c", bridgeCatalog: "changed", nativeCatalog: nil),
            .init(config: "a", providers: "b", bridgeConfig: "c", bridgeCatalog: "d", nativeCatalog: "created")]
        for fingerprint in changed {
            let f = RoutingCommandFixture([busy, idle]), initial = f.fingerprints[0]
            f.fingerprints = [initial, initial, fingerprint]
            let result = await f.run(wait)
            XCTAssertEqual(result.json["outcome"], "intent_changed"); XCTAssertEqual(result.exitCode, 2)
            XCTAssertEqual(f.sleeps, [1]); XCTAssertTrue(f.actions.isEmpty)
        }
    }

    func testUnhealthyStateNeverWaitsOrMutates() async {
        var failures: [JSONValue] = []
        for key in ["configError"] { var value = busy; value[key] = "private failure"; failures.append(value) }
        for key in ["error", "healthError"] { var value = busy; value["native"][key] = "private failure"; failures.append(value) }
        for key in ["running", "accepting"] { var value = busy; value["native"][key] = false; failures.append(value) }
        for count: JSONValue in [-1, 0.5, "0", .null] { var value = busy; value["native"]["activeRequests"] = count; failures.append(value) }
        var value = busy; value["catalog"]["error"] = "private failure"; failures.append(value)
        value = busy; value["bridge"]["running"] = false; failures.append(value)
        value = busy; value["bridge"]["busy"] = .null; failures.append(value)
        for state in failures {
            let f = RoutingCommandFixture([state]), result = await f.run(wait)
            XCTAssertEqual(result.json["outcome"], "unhealthy"); XCTAssertEqual(result.exitCode, 2)
            XCTAssertTrue(f.sleeps.isEmpty); XCTAssertTrue(f.actions.isEmpty)
        }
    }

    func testUnexpectedErrorsAndActionRefusalNeverRetryOrLeakDetails() async throws {
        for mode in 0..<3 {
            let f = RoutingCommandFixture([idle])
            f.statusError = mode == 0; f.fingerprintError = mode == 1; f.actionError = mode == 2
            let result = await f.run(wait)
            XCTAssertEqual(result.exitCode, 1); XCTAssertEqual(result.json["outcome"], "failed")
            XCTAssertEqual(f.actions.count, mode == 2 ? 1 : 0); XCTAssertTrue(f.sleeps.isEmpty)
            XCTAssertFalse(String(decoding: try result.json.encoded(), as: UTF8.self).contains("private"))
        }
    }

    func testCancellationDuringWaitStopsBeforeAction() async {
        let f = RoutingCommandFixture([busy, idle]); f.cancelSleep = true
        let result = await f.run(wait)
        XCTAssertEqual(result.exitCode, 130); XCTAssertEqual(result.json["outcome"], "cancelled")
        XCTAssertEqual(f.reads, 1); XCTAssertTrue(f.actions.isEmpty)
    }

    func testTaskCancellationAfterStatusIsCheckedBeforeAction() async {
        let task = Task { await NativeCodexRoutingCommand.run(wait, makeIO: { _ in
            .init(status: {
                withUnsafeCurrentTask { $0?.cancel() }
                return self.idle
            }, action: { _ in XCTFail("Cancelled intent reached mutation"); return [:] },
            fingerprint: { .init(config: nil, providers: nil, bridgeConfig: nil, bridgeCatalog: nil, nativeCatalog: nil) })
        }) }
        let result = await task.value
        XCTAssertEqual(result.exitCode, 130)
    }

    func testOptionalDisconnectedWebDoesNotBlockNativeAndConnectedNativeNeverWaits() async {
        var state = idle; state["native"]["connected"] = true
        state["bridge"] = ["integrated": false, "running": .null, "busy": .null]
        let f = RoutingCommandFixture([state]), result = await f.run(wait)
        XCTAssertEqual(result.exitCode, 0); XCTAssertEqual(f.actions, ["nativeConnect"]); XCTAssertTrue(f.sleeps.isEmpty)
        state["native"]["activeRequests"] = 1
        let busy = RoutingCommandFixture([state]), refused = await busy.run(wait)
        XCTAssertEqual(refused.json["outcome"], "busy"); XCTAssertTrue(busy.actions.isEmpty); XCTAssertTrue(busy.sleeps.isEmpty)
    }

    func testDiskFingerprintPinsFiveFilesButIgnoresRefreshedModelCache() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("routing-fingerprint-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = NativePaths(root: root, home: root.appendingPathComponent("home"))
        let files = [SwitcherDisk.codexHome(paths).appendingPathComponent("config.toml"), paths.providers,
            SwitcherDisk.bridgeHome(paths).appendingPathComponent("config.json"),
            NativeCodexCatalogStore(bridgeHome: SwitcherDisk.bridgeHome(paths), providersFile: paths.providers).file,
            NativeCodexRouteStore(paths: paths).catalog.file]
        let absent = try NativeCodexRoutingCommand.Fingerprint.capture(paths: paths)
        for file in files {
            let before = try NativeCodexRoutingCommand.Fingerprint.capture(paths: paths)
            try NativeFile.writeAtomic(Data(), to: file)
            let empty = try NativeCodexRoutingCommand.Fingerprint.capture(paths: paths)
            XCTAssertNotEqual(before, empty)
            try NativeFile.writeAtomic(Data("synthetic changed bytes".utf8), to: file)
            XCTAssertNotEqual(empty, try NativeCodexRoutingCommand.Fingerprint.capture(paths: paths))
        }
        XCTAssertNotEqual(absent, try NativeCodexRoutingCommand.Fingerprint.capture(paths: paths))
        let before = try NativeCodexRoutingCommand.Fingerprint.capture(paths: paths)
        try NativeFile.writeAtomic(Data("refreshed model catalog".utf8), to: SwitcherDisk.codexHome(paths).appendingPathComponent("models_cache.json"))
        XCTAssertEqual(before, try NativeCodexRoutingCommand.Fingerprint.capture(paths: paths))
    }
}
