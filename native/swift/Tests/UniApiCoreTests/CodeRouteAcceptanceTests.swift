import Foundation
import XCTest
@testable import UniApiCore

final class CodeRouteAcceptanceTests: XCTestCase {
    func testEveryDisableFlagAndRemovedProxyRejectShimAndDirectRoutesWithoutLeakingKeys() throws {
        let runtime = try CodeRouteAcceptanceFixture.runtime(self)
        for direct in [false, true] {
            let enabled = CodeRouteAcceptanceFixture.provider(direct: direct)
            try CodeRouteAcceptanceFixture.providers(runtime, [enabled])
            XCTAssertTrue(CodeRoutes.list(runtime).contains { $0["id"] == "fixture-route" })
            let settings = try CodeRoutes.settings(runtime, route: "fixture-route", model: "chosen")
            XCTAssertEqual(settings["env"]["ANTHROPIC_BASE_URL"].string, direct ? "https://direct.invalid/anthropic" : "http://127.0.0.1:8823/fixture-route")
            XCTAssertFalse(String(decoding: try JSONValue.array(CodeRoutes.list(runtime)).encoded(), as: UTF8.self).contains("fixture-only"))
            for index in 0..<6 {
                var revoked = enabled
                switch index {
                case 0: revoked["disabled"] = true
                case 1: revoked["enabled"] = false
                case 2: revoked["proxy"]["disabled"] = true
                case 3: revoked["proxy"]["enabled"] = false
                case 4: revoked["proxy"] = .null
                default: revoked["transport"] = "chatgpt-web"; revoked["api_key"] = .null; revoked["proxy"] = .null
                }
                try CodeRouteAcceptanceFixture.providers(runtime, [revoked])
                XCTAssertFalse(CodeRoutes.list(runtime).contains { $0["id"] == "fixture-route" }, "direct=\(direct), flag=\(index)")
                XCTAssertThrowsError(try CodeRoutes.assertAvailable(runtime, route: "fixture-route"))
                XCTAssertThrowsError(try CodeRoutes.settings(runtime, route: "fixture-route", model: "m"))
            }
        }
        try CodeRouteAcceptanceFixture.providers(runtime, [])
        XCTAssertThrowsError(try CodeRoutes.admission(runtime, route: "fixture-route"))
        XCTAssertNoThrow(try CodeRoutes.assertAvailable(runtime, route: "subscription"))
    }
    func testWarmRouteRejectsCredentialOrDestinationReplacementButAllowsCatalogRefresh() throws {
        let runtime = try CodeRouteAcceptanceFixture.runtime(self), original = CodeRouteAcceptanceFixture.provider(direct: true)
        try CodeRouteAcceptanceFixture.providers(runtime, [original]); let admission = try CodeRoutes.admission(runtime, route: "fixture-route")
        var catalog = original; catalog["name"] = "Renamed"; catalog["proxy"]["models"] = ["new-model"]
        try CodeRouteAcceptanceFixture.providers(runtime, [catalog]); XCTAssertNoThrow(try admission())
        for field in ["api_key", "base_url", "format", "direct_url"] {
            var changed = original
            if field == "format" { changed["proxy"][field] = "anthropic" }
            else if field == "direct_url" { changed["proxy"][field] = "https://replacement.invalid" }
            else { changed[field] = "replacement-fixture" }
            try CodeRouteAcceptanceFixture.providers(runtime, [changed]); XCTAssertThrowsError(try admission(), field)
        }
        try CodeRouteAcceptanceFixture.providers(runtime, [original]); XCTAssertNoThrow(try admission())
    }
    func testDisabledSelectionAndCachedDriverSendRefuseBeforeDurableUserOrTransport() async throws {
        let runtime = try CodeRouteAcceptanceFixture.runtime(self), counter = CodeRouteAcceptanceCounter()
        var provider = CodeRouteAcceptanceFixture.provider(direct: true); try CodeRouteAcceptanceFixture.providers(runtime, [provider])
        let channel = CodeFixtureChannel { frame in
            if frame["type"] == "control_request" { return [CodeRouteAcceptanceFixture.claude(frame)] }
            if frame["type"] == "user" { return [["type": "result", "uuid": .string(UUID().uuidString), "subtype": "success", "is_error": false, "usage": [:]]] }; return []
        }
        let service = NativeCodeService(runtime: runtime, channelFactory: { _ in _ = counter.next(); return channel }); addTeardownBlock { await service.shutdown() }
        let project = try await service.handle("project.add", input: ["path": .string(runtime.paths.root.path)])
        let thread = try await service.handle("thread.create", input: ["projectId": project["id"], "routeId": "fixture-route"]), id = thread["id"]
        _ = try await service.handle("send", input: ["id": id, "text": "accepted fixture"])
        try await CodeRouteAcceptanceFixture.eventually { try await service.handle("thread", input: ["id": id])["thread"]["turns"].int == 1 }
        let before = try await service.handle("thread", input: ["id": id]), frameCount = channel.frames().count
        provider["proxy"]["disabled"] = true; try CodeRouteAcceptanceFixture.providers(runtime, [provider])
        let refused: [(String, JSONObject)] = [
            ("thread.create", ["projectId": project["id"], "routeId": "fixture-route"]),
            ("thread.patch", ["id": id, "patch": ["route_id": "fixture-route"]]),
            ("thread.patch", ["id": id, "patch": ["model": "n"]]),
            ("send", ["id": id, "text": "refused fixture"])
        ]
        for (op, body) in refused { do { _ = try await service.handle(op, input: body); XCTFail("Disabled \(op) accepted") } catch {} }
        let after = try await service.handle("thread", input: ["id": id])
        XCTAssertEqual(after["events"], before["events"]); XCTAssertEqual(after["thread"]["model"], before["thread"]["model"])
        XCTAssertEqual(counter.count(), 1); XCTAssertEqual(channel.frames().count, frameCount)
        let renamed = try await service.handle("thread.patch", input: ["id": id, "patch": ["title": "Can still organize history"]])
        XCTAssertEqual(renamed["title"], "Can still organize history")
        provider["proxy"]["disabled"] = false; try CodeRouteAcceptanceFixture.providers(runtime, [provider])
        _ = try await service.handle("send", input: ["id": id, "text": "enabled again"])
        try await CodeRouteAcceptanceFixture.eventually { channel.frames().filter { $0["type"] == "user" }.count == 2 }
        XCTAssertEqual(counter.count(), 1)
    }
    func testQueuedACPTurnRevocationLetsStartedTurnFinishAndNeverSendsFollowup() async throws {
        let runtime = try CodeRouteAcceptanceFixture.runtime(self), events = CodeRouteAcceptanceEvents()
        var provider = CodeRouteAcceptanceFixture.provider(direct: true); try CodeRouteAcceptanceFixture.providers(runtime, [provider])
        let channel = CodeFixtureChannel { frame in
            if frame["method"] == "session/new" { return [CodeRouteAcceptanceFixture.acp(frame, ["sessionId": "s"])] }
            if frame["method"] == "session/prompt" || frame["id"].isNull { return [] }
            return [CodeRouteAcceptanceFixture.acp(frame, [:])]
        }
        let admission = try CodeRoutes.admission(runtime, route: "fixture-route")
        let driver = CodeDriver(runtime: runtime, directory: runtime.paths.root, thread: ["id": "fixture"], wire: .acp, admission: admission, channelFactory: { channel }, sink: { type, data in await events.add(type, data) }, permission: { _ in })
        addTeardownBlock { await driver.close() }
        try await driver.send("already started"); try await driver.send("queued followup")
        try await CodeRouteAcceptanceFixture.eventually { channel.frames().filter { $0["method"] == "session/prompt" }.count == 1 }
        let active = try XCTUnwrap(channel.frames().first { $0["method"] == "session/prompt" })
        provider["enabled"] = false; try CodeRouteAcceptanceFixture.providers(runtime, [provider])
        XCTAssertFalse(channel.frames().contains { $0["method"] == "session/cancel" })
        channel.emit(CodeRouteAcceptanceFixture.acp(active, ["stopReason": "end_turn"]))
        try await CodeRouteAcceptanceFixture.eventually { !(await events.values("error")).isEmpty }
        XCTAssertEqual(channel.frames().filter { $0["method"] == "session/prompt" }.count, 1)
        let results = await events.values("result"); XCTAssertEqual(results.count, 1); XCTAssertFalse(results[0]["is_error"].bool)
        provider["enabled"] = true; try CodeRouteAcceptanceFixture.providers(runtime, [provider])
        try await driver.send("new explicit turn")
        try await CodeRouteAcceptanceFixture.eventually { channel.frames().filter { $0["method"] == "session/prompt" }.count == 2 }
        let last = try XCTUnwrap(channel.frames().last { $0["method"] == "session/prompt" })
        XCTAssertEqual(last["params"]["prompt"].array.first?["text"], "new explicit turn")
        channel.emit(CodeRouteAcceptanceFixture.acp(last, ["stopReason": "end_turn"]))
    }
    func testClaudeHeldHandshakeRechecksAndDropsAllUnstartedTurnsOnRevocation() async throws {
        let runtime = try CodeRouteAcceptanceFixture.runtime(self), channel = CodeFixtureChannel { _ in [] }
        var provider = CodeRouteAcceptanceFixture.provider(direct: true); try CodeRouteAcceptanceFixture.providers(runtime, [provider])
        let driver = CodeDriver(runtime: runtime, directory: runtime.paths.root, thread: ["id": "fixture", "permission_mode": "default"], wire: .claude, admission: try CodeRoutes.admission(runtime, route: "fixture-route"), channelFactory: { channel }, sink: { _,_ in }, permission: { _ in })
        addTeardownBlock { await driver.close() }
        let first = Task { try await driver.send("first") }
        try await CodeRouteAcceptanceFixture.eventually { channel.frames().contains { $0["request"]["subtype"] == "initialize" } }
        provider["disabled"] = true; try CodeRouteAcceptanceFixture.providers(runtime, [provider])
        // Finish the second refusal while initialize remains held. Its
        // admission failure deterministically clears the first sender's queue.
        do { try await driver.send("second"); XCTFail("Revoked second send returned success") }
        catch { XCTAssertTrue(error.localizedDescription.contains("disabled")) }
        XCTAssertFalse(channel.frames().contains { $0["type"] == "user" })
        let initialize = try XCTUnwrap(channel.frames().first { $0["request"]["subtype"] == "initialize" }); channel.emit(CodeRouteAcceptanceFixture.claude(initialize))
        do { try await first.value; XCTFail("Revoked first send returned success after its queue was cleared") }
        catch { XCTAssertTrue(error.localizedDescription.contains("disabled")) }
        XCTAssertFalse(channel.frames().contains { $0["type"] == "user" })
        provider["disabled"] = false; try CodeRouteAcceptanceFixture.providers(runtime, [provider])
        try await driver.send("explicit after enable")
        XCTAssertEqual(channel.frames().filter { $0["type"] == "user" }.map { $0["message"]["content"].string }, ["explicit after enable"])
    }
}
