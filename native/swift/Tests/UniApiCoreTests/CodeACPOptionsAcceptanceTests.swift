import Foundation
import XCTest
@testable import UniApiCore

final class CodeACPOptionsAcceptanceTests: XCTestCase {
    static let advertised: JSONValue = ["sessionId": "fixture-session", "configOptions": [
        ["id": "agent/model-choice", "category": "model", "type": "select", "currentValue": "m1", "options": [["name": "Family", "options": [["value": "m1", "name": "Model one"], ["value": "m2", "name": "Model two"]]]]],
        ["id": "agent/reasoning-budget", "category": "thought_level", "type": "select", "currentValue": "balanced", "options": [["value": "balanced", "name": "Balanced"], ["value": "deep", "name": "Deep"]]],
        ["id": "agent/review-policy", "category": "mode", "type": "select", "currentValue": "review-only", "options": [["value": "review-only", "name": "Review only"], ["value": "workspace-auto", "name": "Workspace automatic"]]]
    ]]
    func testActualAdvertisedConfigIDsGroupedChoicesDefaultsAndPartialUpdates() throws {
        var options = CodeACPOptions(); options.read(Self.advertised)
        XCTAssertEqual(options.json["models"].array.map { $0["value"].string }, ["m1", "m2"])
        for (key, id, value) in [("model", "agent/model-choice", "m2"), ("effort", "agent/reasoning-budget", "deep"), ("permission_mode", "agent/review-policy", "workspace-auto")] {
            let request = try options.request(key, value: .string(value), session: "s")
            XCTAssertEqual(request.method, "session/set_config_option"); XCTAssertEqual(request.params["configId"].string, id)
            XCTAssertEqual(request.params["sessionId"], "s"); XCTAssertEqual(request.params["value"].string, value)
        }
        options.read(["configOptions": [["id": "agent/model-choice", "currentValue": "m2"]]])
        XCTAssertEqual(options.threadPatch["model"], "m2"); XCTAssertEqual(options.json["models"].array.count, 2)
        XCTAssertEqual(try options.request("model", value: "", session: "s").value, "m1")
        XCTAssertEqual(try options.request("effort", value: .null, session: "s").value, "balanced")
        XCTAssertThrowsError(try options.request("model", value: "unadvertised", session: "s"))
        options.read(["configOptions": [["id": "agent/model-choice", "type": "select", "options": []]]])
        XCTAssertNil(options.threadPatch["model"]); XCTAssertThrowsError(try options.request("model", value: "", session: "s"))
    }
    func testSessionModesUseModeEndpointAndExactByteIDs() throws {
        var response = Self.advertised
        response["modes"] = ["currentModeId": "audit", "availableModes": [["id": "audit", "name": "Audit"], ["id": "operate", "name": "Operate"]]]
        var options = CodeACPOptions(); options.read(response)
        let request = try options.request("permission_mode", value: "operate", session: "s")
        XCTAssertEqual(request.method, "session/set_mode"); XCTAssertEqual(request.params["modeId"], "operate"); XCTAssertTrue(request.params["configId"].isNull)
        XCTAssertTrue(options.modeChanged("operate")); XCTAssertEqual(options.threadPatch["permission_mode"], "operate")
        XCTAssertFalse(options.modeChanged("acceptEdits")); XCTAssertEqual(options.threadPatch["permission_mode"], "operate")
        var unicode = CodeACPOptions()
        unicode.read(["configOptions": [["id": "actual", "category": "model", "type": "select", "currentValue": "é", "options": [["value": "é"], ["value": "e\u{301}"]]]]])
        XCTAssertEqual(unicode.json["models"].array.count, 2)
        XCTAssertEqual(Array(try unicode.request("model", value: "e\u{301}", session: "s").value.string.utf8), Array("e\u{301}".utf8))
    }
    func testAdvertisedCategoryOutranksConflictingLegacyIDsAndRetainsLegacyFallback() throws {
        var options = CodeACPOptions()
        options.read(["configOptions": [
            ["id": "actual-model", "category": "model", "type": "select", "currentValue": "m1", "options": [["value": "m1"], ["value": "m2"]]],
            ["id": "model", "category": "thought_level", "type": "select", "currentValue": "balanced", "options": [["value": "balanced"], ["value": "deep"]]],
            ["id": "effort", "category": "mode", "type": "select", "currentValue": "review", "options": [["value": "review"], ["value": "operate"]]]
        ]])
        XCTAssertEqual(options.json["models"].array.map { $0["value"].string }, ["m1", "m2"])
        XCTAssertEqual(options.json["efforts"].array.map { $0["value"].string }, ["balanced", "deep"])
        XCTAssertEqual(options.json["modes"].array.map { $0["value"].string }, ["review", "operate"])
        for (key, configID, value) in [("model", "actual-model", "m2"), ("effort", "model", "deep"), ("permission_mode", "effort", "operate")] {
            let request = try options.request(key, value: .string(value), session: "s")
            XCTAssertEqual(request.method, "session/set_config_option"); XCTAssertEqual(request.params["configId"].string, configID)
            XCTAssertEqual(request.params["value"].string, value)
        }
        options.read(["configOptions": [["id": "model", "currentValue": "deep"], ["id": "effort", "currentValue": "operate"]]])
        XCTAssertEqual(options.threadPatch["model"], "m1"); XCTAssertEqual(options.threadPatch["effort"], "deep"); XCTAssertEqual(options.threadPatch["permission_mode"], "operate")
        options.read(["modes": ["currentModeId": "session-mode", "availableModes": [["id": "session-mode", "name": "Session mode"]]], "configOptions": [["id": "model", "category": "mode", "type": "select", "currentValue": "ignored", "options": [["value": "ignored"]]]]])
        XCTAssertEqual(options.json["models"].array.map { $0["value"].string }, ["m1", "m2"])
        XCTAssertEqual(try options.request("permission_mode", value: "session-mode", session: "s").method, "session/set_mode")
        var legacy = CodeACPOptions()
        legacy.read(["configOptions": [
            ["id": "model", "type": "select", "currentValue": "old-model", "options": [["value": "old-model"]]],
            ["id": "effort", "category": "vendor-extension", "type": "select", "currentValue": "old-effort", "options": [["value": "old-effort"]]]
        ]])
        XCTAssertEqual(try legacy.request("model", value: "old-model", session: "s").params["configId"], "model")
        XCTAssertEqual(try legacy.request("effort", value: "old-effort", session: "s").params["configId"], "effort")
    }
    func testDriverHandshakeAndLiveChangesUseActualIDsAndPublishAcknowledgedChoices() async throws {
        let runtime = try CodeRouteAcceptanceFixture.runtime(self), events = CodeRouteAcceptanceEvents()
        let channel = CodeFixtureChannel { frame in
            let method = frame["method"].string
            if method == "session/new" { return [CodeRouteAcceptanceFixture.acp(frame, Self.advertised)] }
            if method == "session/set_config_option" { return [CodeRouteAcceptanceFixture.acp(frame, ["configOptions": [["id": frame["params"]["configId"], "currentValue": frame["params"]["value"]]]])] }
            if !frame["id"].isNull { return [CodeRouteAcceptanceFixture.acp(frame, [:])] }; return []
        }
        let driver = CodeDriver(runtime: runtime, directory: runtime.paths.root, thread: ["id": "fixture", "model": "m2", "effort": "deep", "permission_mode": "workspace-auto"], wire: .acp, channelFactory: { channel }, sink: { type, data in await events.add(type, data) }, permission: { _ in })
        addTeardownBlock { await driver.close() }
        try await driver.boot()
        let requests = channel.frames().filter { $0["method"] == "session/set_config_option" }
        XCTAssertEqual(requests.map { $0["params"]["configId"].string }, ["agent/model-choice", "agent/review-policy", "agent/reasoning-budget"])
        try await driver.configure(["model": "m1", "effort": .null, "permission_mode": "review-only"])
        let options = await driver.currentOptions()
        XCTAssertEqual(options["current"]["model"], "m1"); XCTAssertEqual(options["current"]["effort"], "balanced"); XCTAssertEqual(options["current"]["permission_mode"], "review-only")
        let before = channel.frames().count
        do { try await driver.configure(["model": "unknown"]); XCTFail("Unsupported model reached the agent") } catch {}
        XCTAssertEqual(channel.frames().count, before)
        let published = await events.values("configuration")
        XCTAssertEqual(published.last?["effort"], "balanced")
        do { try await driver.configure(["model": "m2", "effort": "not-advertised"]); XCTFail("Unsupported effort accepted") } catch {}
        let partial = await events.values("configuration")
        XCTAssertEqual(partial.last?["model"], "m2", "A later refusal cannot erase an already acknowledged engine change")
    }
    func testServicePersistsCustomModeAndActualAgentUpdatesWithoutClaudeModeWhitelist() async throws {
        let runtime = try CodeRouteAcceptanceFixture.runtime(self)
        let channel = CodeFixtureChannel { frame in
            if frame["method"] == "session/new" { var response = Self.advertised; response["modes"] = ["currentModeId": "audit", "availableModes": [["id": "audit", "name": "Audit"], ["id": "operate", "name": "Operate"]]]; return [CodeRouteAcceptanceFixture.acp(frame, response)] }
            if frame["method"] == "session/prompt" { return [CodeRouteAcceptanceFixture.acp(frame, ["stopReason": "end_turn"])] }
            return frame["id"].isNull ? [] : [CodeRouteAcceptanceFixture.acp(frame, [:])]
        }
        let service = NativeCodeService(runtime: runtime, channelFactory: { _ in channel }); addTeardownBlock { await service.shutdown() }
        let project = try await service.handle("project.add", input: ["path": .string(runtime.paths.root.path)])
        let thread = try await service.handle("thread.create", input: ["projectId": project["id"], "routeId": "agent:opencode"]), id = thread["id"]
        XCTAssertEqual(thread["permission_mode"], "")
        _ = try await service.handle("send", input: ["id": id, "text": "injected fixture"])
        try await CodeRouteAcceptanceFixture.eventually { try await service.handle("thread", input: ["id": id])["thread"]["permission_mode"] == "audit" }
        let patched = try await service.handle("thread.patch", input: ["id": id, "patch": ["permission_mode": "operate", "effort": .null]])
        XCTAssertEqual(patched["permission_mode"], "operate"); XCTAssertEqual(patched["effort"], "balanced")
        XCTAssertTrue(channel.frames().contains { $0["method"] == "session/set_mode" && $0["params"]["modeId"] == "operate" })
        channel.emit(["jsonrpc": "2.0", "method": "session/update", "params": ["sessionId": "fixture-session", "update": ["sessionUpdate": "current_mode_update", "currentModeId": "audit"]]])
        try await CodeRouteAcceptanceFixture.eventually { try await service.handle("thread", input: ["id": id])["thread"]["permission_mode"] == "audit" }
        let cached = CodeRoutes.cachedOptions(runtime, route: "agent:opencode")
        XCTAssertEqual(cached["modes"].array.map { $0["value"].string }, ["audit", "operate"])
        do { _ = try await service.handle("thread.patch", input: ["id": id, "patch": ["permission_mode": "bypassPermissions"]]); XCTFail("Unadvertised mode accepted") } catch {}
        let routeChanged = try await service.handle("thread.patch", input: ["id": id, "patch": ["route_id": "subscription"]])
        XCTAssertEqual(routeChanged["permission_mode"], "acceptEdits"); XCTAssertTrue(routeChanged["effort"].isNull)
        do { _ = try await service.handle("thread.patch", input: ["id": id, "patch": ["permission_mode": "operate"]]); XCTFail("ACP mode leaked into Claude") } catch {}
    }
    func testNativeChoicePolicyUsesAdvertisedNamesAndDoesNotResurrectWithdrawnModels() {
        let cached: JSONValue = ["advertised": true, "models": [["value": "cached"]], "modes": [["value": "custom", "displayName": "Custom policy"]]]
        let route: JSONValue = ["kind": "agent", "models": ["cached"], "agent": ["options": cached]]
        let cachedModes = CodeSessionChoices.modes(route: route, options: [:], current: "custom")
        XCTAssertEqual(cachedModes.first?["displayName"], "Custom policy"); XCTAssertTrue(cachedModes.first?["available"].bool == true)
        let current: JSONValue = ["advertised": true, "models": [["value": "live"]], "modes": [["value": "next", "displayName": "Next policy"]]]
        let modes = CodeSessionChoices.modes(route: route, options: current, current: "custom")
        XCTAssertEqual(modes.map { $0["value"].string }, ["custom", "next"]); XCTAssertFalse(modes[0]["available"].bool)
        XCTAssertEqual(CodeSessionChoices.models(route: route, options: current).map { $0["value"].string }, ["", "live"])
        XCTAssertEqual(CodeSessionChoices.modes(route: ["kind": "subscription"], options: current, current: "default").count, 4)
        let local = CodeSessionChoices.modes(route: ["kind": "agent"], options: ["advertised": true, "modes": []], current: "plan")
        XCTAssertEqual(local.count, 5); XCTAssertEqual(local.first { $0["value"] == "plan" }?["displayName"], "Plan (local guard)")
    }
    func testLegacyAgentLocalPermissionPolicyDoesNotInventModeRPC() async throws {
        let runtime = try CodeRouteAcceptanceFixture.runtime(self), events = CodeRouteAcceptanceEvents()
        let channel = CodeFixtureChannel { frame in
            if frame["method"] == "session/new" { return [CodeRouteAcceptanceFixture.acp(frame, ["sessionId": "s"])] }
            return frame["id"].isNull ? [] : [CodeRouteAcceptanceFixture.acp(frame, [:])]
        }
        let driver = CodeDriver(runtime: runtime, directory: runtime.paths.root, thread: ["id": "fixture", "permission_mode": "plan"], wire: .acp, channelFactory: { channel }, sink: { type, data in await events.add(type, data) }, permission: { _ in })
        addTeardownBlock { await driver.close() }; try await driver.boot()
        try await driver.configure(["permission_mode": "acceptEdits"]); try await driver.configure(["permission_mode": ""])
        XCTAssertFalse(channel.frames().contains { ["session/set_mode", "session/set_config_option"].contains($0["method"].string) })
        let modes = await events.values("mode"); XCTAssertEqual(modes.map { $0["permission_mode"].string }, ["acceptEdits", ""])
    }
}

enum CodeRouteAcceptanceFixture {
    static func runtime(_ test: XCTestCase) throws -> NativeRuntime {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("code-route-acceptance-" + UUID().uuidString)
        let runtime = try NativeRuntime(paths: NativePaths(root: root, home: root.appendingPathComponent("home")))
        test.addTeardownBlock { await runtime.jobs.suspendForShutdown(); try? FileManager.default.removeItem(at: root) }; return runtime
    }
    static func provider(direct: Bool = false) -> JSONValue {
        var row: JSONValue = ["id": "fixture-route", "name": "Fixture", "base_url": "https://provider.invalid", "api_key": "fixture-only", "proxy": ["format": "openai", "model": "m", "models": ["m", "n"]]]
        if direct { row["proxy"]["direct_url"] = "https://direct.invalid/anthropic" }; return row
    }
    static func providers(_ runtime: NativeRuntime, _ rows: [JSONValue]) throws { try runtime.providers.mutate { $0["providers"] = .array(rows) } }
    static func acp(_ frame: JSONValue, _ result: JSONValue) -> JSONValue { ["jsonrpc": "2.0", "id": frame["id"], "result": result] }
    static func claude(_ frame: JSONValue, _ result: JSONValue = [:]) -> JSONValue { ["type": "control_response", "response": ["subtype": "success", "request_id": frame["request_id"], "response": result]] }
    static func eventually(_ condition: @escaping () async throws -> Bool) async throws {
        for _ in 0..<500 { if try await condition() { return }; try await Task.sleep(nanoseconds: 2_000_000) }
        XCTFail("Injected operation did not settle"); throw NativeFailure("Fixture timed out")
    }
}
actor CodeRouteAcceptanceEvents {
    private var rows: [(String, JSONValue)] = []
    func add(_ type: String, _ value: JSONValue) { rows.append((type, value)) }
    func values(_ type: String) -> [JSONValue] { rows.filter { $0.0 == type }.map { $0.1 } }
}
final class CodeRouteAcceptanceCounter: @unchecked Sendable {
    private let lock = NSLock(); private var value = 0
    func next() -> Int { lock.lock(); defer { lock.unlock() }; value += 1; return value }
    func count() -> Int { lock.lock(); defer { lock.unlock() }; return value }
}
