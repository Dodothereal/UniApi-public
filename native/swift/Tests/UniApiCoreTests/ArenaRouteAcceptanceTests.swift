import Foundation
import XCTest
@testable import UniApiCore

final class ArenaRouteAcceptanceTests: XCTestCase {
    func testContestantSelectionExcludesRevokedRoutesAndRejectsExplicitBypass() async throws {
        let runtime = try CodeRouteAcceptanceFixture.runtime(self), counter = CodeRouteAcceptanceCounter()
        var provider = CodeRouteAcceptanceFixture.provider(direct: true); try CodeRouteAcceptanceFixture.providers(runtime, [provider])
        let service = NativeArenaService(runtime: runtime, channelFactory: { _,_,_,_,_ in _ = counter.next(); throw NativeFailure("Unexpected transport") })
        let enabled = try await service.handle("state")
        XCTAssertEqual(enabled["contestants"].array.filter { $0["route"] == "fixture-route" }.count, 2)
        provider["proxy"]["enabled"] = false; try CodeRouteAcceptanceFixture.providers(runtime, [provider])
        let disabled = try await service.handle("state")
        XCTAssertFalse(disabled["contestants"].array.contains { $0["route"] == "fixture-route" })
        do { _ = try await service.handle("match.create", input: ["mode": "chosen", "prompt": "fixture", "notify": false, "contestants": [["route": "fixture-route", "model": "m"], ["route": "fixture-route", "model": "n"]]]); XCTFail("Disabled direct contestants accepted") } catch {}
        XCTAssertEqual(counter.count(), 0); XCTAssertTrue(try runtime.db.query("SELECT * FROM arena_matches").isEmpty)
    }
    func testQueuedMatchRechecksRevocationBeforeAnyContestantTransport() async throws {
        let runtime = try CodeRouteAcceptanceFixture.runtime(self), counter = CodeRouteAcceptanceCounter()
        var provider = CodeRouteAcceptanceFixture.provider(direct: true); try CodeRouteAcceptanceFixture.providers(runtime, [provider])
        let service = NativeArenaService(runtime: runtime, channelFactory: { _,_,_,_,_ in _ = counter.next(); throw NativeFailure("Unexpected transport") })
        try await service.start()
        // Recreate a durable queued run before queue recovery. Calling submit
        // would schedule immediately and would not exercise this boundary.
        let store = try ArenaStore(runtime: runtime)
        let match = try store.create(["mode": "chosen", "prompt": "queued injected fixture", "notify": false, "timeout_s": 5, "max_turns": 5], contestants: [["route": "fixture-route", "model": "m"], ["route": "fixture-route", "model": "n"]])
        try store.patchMatch(match["id"], ["job_id": "revoked-queued-fixture"])
        let params = String(decoding: try JSONValue.object(["matchId": match["id"]]).encoded(), as: UTF8.self)
        try runtime.db.execute("INSERT INTO jobs(id,kind,app,title,lane,params,status,created_at) VALUES('revoked-queued-fixture','arena.match','arena','Fixture','arena',?,'queued',1)", [.string(params)])
        XCTAssertEqual(match["status"], "queued"); XCTAssertEqual(counter.count(), 0)
        provider["disabled"] = true; try CodeRouteAcceptanceFixture.providers(runtime, [provider])
        try await runtime.jobs.recover()
        try await CodeRouteAcceptanceFixture.eventually { try await service.handle("match", input: ["id": match["id"]])["status"] == "failed" }
        let slots = try store.slots(match["id"])
        XCTAssertEqual(slots.count, 2); XCTAssertTrue(slots.allSatisfy { $0["status"] == "failed" && $0["error"].string.contains("disabled") })
        XCTAssertEqual(counter.count(), 0)
    }
    func testSlotRechecksDirectRouteAfterLaunchHandshakeAndEnabledControlCompletes() async throws {
        let runtime = try CodeRouteAcceptanceFixture.runtime(self), provider = CodeRouteAcceptanceFixture.provider(direct: true)
        for revokeDuringLaunch in [false, true] {
            try CodeRouteAcceptanceFixture.providers(runtime, [provider])
            let workspace = runtime.paths.tmp.appendingPathComponent(UUID().uuidString)
            let slot: JSONValue = ["id": .string(UUID().uuidString), "route": "fixture-route", "model": "m", "workdir": .string(workspace.path)]
            let channel = CodeFixtureChannel { frame in
                if frame["type"] == "control_request" { return [CodeRouteAcceptanceFixture.claude(frame, ["hooks_applied": true])] }
                if frame["type"] == "user" { return [["type": "assistant", "message": ["content": [["type": "text", "text": "Injected answer"]]]], ["type": "result", "subtype": "success", "is_error": false, "usage": [:]]] }; return []
            }
            let runner = ArenaSlotRunner(runtime: runtime, slot: slot, match: ["prompt": "injected fixture", "timeout_s": 5, "max_turns": 5], factory: { _,_,settings,_,_ in
                guard settings["env"]["ANTHROPIC_BASE_URL"] == "https://direct.invalid/anthropic" else { throw NativeFailure("Wrong direct route") }
                if revokeDuringLaunch { var revoked = provider; revoked["proxy"]["disabled"] = true; try CodeRouteAcceptanceFixture.providers(runtime, [revoked]) }
                return channel
            }, onEvent: { _,_ in }, onLive: { _ in })
            let outcome = await runner.run()
            XCTAssertEqual(outcome["status"], revokeDuringLaunch ? "failed" : "done")
            XCTAssertEqual(channel.frames().filter { $0["type"] == "user" }.count, revokeDuringLaunch ? 0 : 1)
            if revokeDuringLaunch { XCTAssertTrue(outcome["error"].string.contains("disabled")) }
            XCTAssertTrue(channel.didClose())
        }
    }
}
