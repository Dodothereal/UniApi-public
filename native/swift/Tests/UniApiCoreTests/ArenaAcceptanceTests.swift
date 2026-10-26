import XCTest
import Foundation
@testable import UniApiCore

final class ArenaAcceptanceTests: XCTestCase {
    private func fixture() throws -> NativeRuntime {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("arena-acceptance-" + UUID().uuidString)
        let runtime = try NativeRuntime(paths: NativePaths(root: root, home: root.appendingPathComponent("home")))
        try FileManager.default.createDirectory(at: runtime.paths.home, withIntermediateDirectories: true)
        addTeardownBlock { await runtime.jobs.suspendForShutdown(); try? FileManager.default.removeItem(at: root) }; return runtime
    }
    private static func reply(_ frame: JSONValue) -> [JSONValue] {
        if frame["type"].string == "control_request" { return [["type": "control_response", "response": ["subtype": "success", "request_id": frame["request_id"], "response": ["hooks_applied": true, "models": []]]]] }
        if frame["type"].string == "user" { return [["type": "assistant", "message": ["content": [["type": "text", "text": "Fixture answer"]]]], ["type": "result", "subtype": "success", "usage": [:]]] }
        return []
    }
    func testDuplicateModelsAndDelimiterPairsHaveDistinctSafeCatalogAndSelection() async throws {
        let runtime = try fixture()
        let rows: [JSONValue] = [
            ["id": "fixture", "proxy": ["format": "anthropic", "models": ["same", "same", .null, 2]]],
            ["id": "a::b", "proxy": ["format": "anthropic", "models": ["c"]]],
            ["id": "a", "proxy": ["format": "anthropic", "models": ["b::c"]]]
        ]
        try runtime.providers.mutate { $0["providers"] = .array(rows) }
        let service = NativeArenaService(runtime: runtime, channelFactory: { _,_,_,_,_ in CodeFixtureChannel { frame in Self.reply(frame) } }, notification: { _ in true })
        let state = try await service.handle("state"), catalog = state["contestants"].array
        XCTAssertEqual(catalog.count, 7); XCTAssertEqual(Set(catalog.map { $0["key"].string }).count, 7)
        let colliding = catalog.filter { ["a::b", "a"].contains($0["route"].string) }
        XCTAssertEqual(colliding.count, 2); XCTAssertNotEqual(colliding[0]["key"], colliding[1]["key"])
        _ = try await service.handle("settings", input: ["excluded": ["a::b::c"]])
        let excluded = try await service.handle("state")["excluded"].array
        XCTAssertEqual(Set(excluded), Set(colliding.map { $0["key"] }))
        _ = try await service.handle("settings", input: ["excluded": []])
        let chosen = try await service.handle("match.create", input: ["mode": "chosen", "prompt": "Fixture", "notify": false, "contestants": .array(colliding)])
        try await codeFixtureEventually { try await service.handle("match", input: ["id": chosen["id"]])["status"].string == "done" }
        let store = try ArenaStore(runtime: runtime), slots = try store.slots(chosen["id"])
        XCTAssertEqual(Set(slots.map(ArenaRanking.key)).count, 2)
        let before = try await runtime.jobs.list(app: "arena").count
        do { _ = try await service.handle("match.create", input: ["mode": "random", "count": 8, "prompt": "Fixture", "notify": false]); XCTFail("Insufficient distinct pool accepted") } catch {}
        let after = try await runtime.jobs.list(app: "arena").count; XCTAssertEqual(before, after)
        let random = try await service.handle("match.create", input: ["mode": "random", "count": 7, "prompt": "Fixture", "notify": false])
        try await codeFixtureEventually { try await service.handle("match", input: ["id": random["id"]])["status"].string == "done" }
        XCTAssertEqual(Set(try store.slots(random["id"]).map(ArenaRanking.key)).count, 7)
    }
    func testOrdinarySavedKeysAndFirstPlaceReliabilityPresentationRemainCompatible() {
        XCTAssertEqual(ArenaContestantPolicy.key(["route": "fixture", "model": "normal"]), "fixture::normal")
        let values: [JSONValue] = [["route": "a::b", "model": "c"], ["route": "a", "model": "b::c"], ["route": "pair:abc", "model": "x"]]
        XCTAssertEqual(Set(values.map(ArenaContestantPolicy.key)).count, values.count)
        let unicode: [JSONValue] = [["route": "fixture", "model": "m-\u{00e9}"], ["route": "fixture", "model": "m-e\u{0301}"]]
        XCTAssertEqual(ArenaContestantPolicy.unique(unicode).count, 2)
        XCTAssertEqual(ArenaContestantPolicy.selection(["fixture::m-\u{00e9}"], contestants: unicode).count, 1)
        let selected = ArenaContestantPolicy.selection(["a::b::c"], contestants: values)
        XCTAssertEqual(selected.count, 2)
        let detail = ArenaStandingDetail(["firsts": 3, "failures": 1, "matches": 4])
        XCTAssertEqual(detail.firstPlaceLabel, "3 first places"); XCTAssertTrue(detail.accessibilitySummary.contains("1 failures in 4 matches"))
        XCTAssertEqual(ArenaStandingDetail(["firsts": 1]).firstPlaceLabel, "1 first place")
        let record: JSONValue = ["v": 1, "id": "pair", "ts": 1, "mode": "chosen", "verdict": "ranked", "contestants": [.object(values[0].object.merging(["status": "done", "rank": 1]) { _, new in new }), .object(values[1].object.merging(["status": "done", "rank": 2]) { _, new in new })]]
        XCTAssertTrue(ArenaRanking.valid(record)); let standings = ArenaRanking.standings([record])
        XCTAssertEqual(standings.count, 2); XCTAssertEqual(standings.first?["elo"], 1016)
    }
    func testRerunKeepsExecutedPromptLimitsAndContestantsAfterPresetChangesAndSkipDoesNotVote() async throws {
        let runtime = try fixture(), service = NativeArenaService(runtime: runtime, channelFactory: { _,_,_,_,_ in CodeFixtureChannel { frame in Self.reply(frame) } }, notification: { _ in true })
        let preset = try await service.handle("preset.save", input: ["title": "Fixture", "category": "fixture", "prompt": "original task"])
        let match = try await service.handle("match.create", input: ["mode": "chosen", "presetId": preset["id"], "notify": false, "timeoutMin": 12, "maxTurns": 25, "contestants": [["route": "subscription", "model": "sonnet"], ["route": "subscription", "model": "haiku"]]])
        try await codeFixtureEventually { try await service.handle("match", input: ["id": match["id"]])["status"].string == "done" }
        _ = try await service.handle("preset.save", input: ["id": preset["id"], "title": "Changed", "category": "different", "prompt": "changed task"])
        let rerun = try await service.handle("rerun", input: ["id": match["id"]])
        XCTAssertEqual(rerun["prompt"], "original task"); XCTAssertEqual(rerun["timeout_s"], 720); XCTAssertEqual(rerun["max_turns"], 25); XCTAssertEqual(rerun["category"], "fixture")
        try await codeFixtureEventually { try await service.handle("match", input: ["id": rerun["id"]])["status"].string == "done" }
        let skipped = try await service.handle("skip", input: ["id": rerun["id"]]); XCTAssertTrue(skipped["revealed"].bool); XCTAssertEqual(skipped["verdict"], "skipped")
        XCTAssertTrue(ArenaLedger(runtime: runtime).records().isEmpty)
        let store = try ArenaStore(runtime: runtime)
        XCTAssertEqual(Set(try store.slots(match["id"]).map(ArenaRanking.key)), Set(try store.slots(rerun["id"]).map(ArenaRanking.key)))
    }
    func testTwoMatchesShareProviderLimitAndSubscriptionLimitWithoutStartingQueuedThird() async throws {
        let runtime = try fixture(), witness = ArenaAdmissionWitness()
        try runtime.providers.mutate { $0["providers"] = [["id": "fixture", "proxy": ["format": "anthropic", "models": ["a", "b", "c", "d"]]]] }
        let service = NativeArenaService(runtime: runtime, channelFactory: { slot,_,_,_,_ in ArenaHeldChannel(slot: slot, witness: witness) }, notification: { _ in true })
        let provider: JSONValue = .array(["a", "b", "c", "d"].map { ["route": "fixture", "model": .string($0)] })
        let subscription: JSONValue = .array(["sonnet", "haiku", "opus[1m]", "claude-fable-5-1[1m]"].map { ["route": "subscription", "model": .string($0)] })
        let first = try await service.handle("match.create", input: ["mode": "chosen", "prompt": "Fixture", "notify": false, "contestants": provider])
        let second = try await service.handle("match.create", input: ["mode": "chosen", "prompt": "Fixture", "notify": false, "contestants": provider])
        let third = try await service.handle("match.create", input: ["mode": "chosen", "prompt": "Fixture", "notify": false, "contestants": subscription])
        try await codeFixtureEventually { witness.active("fixture") == 2 }
        let jobs = try await runtime.jobs.list(app: "arena")
        XCTAssertEqual(jobs.filter { $0["status"]?.string == "running" }.count, 2); XCTAssertEqual(jobs.filter { $0["status"]?.string == "queued" }.count, 1)
        XCTAssertEqual(witness.active("subscription"), 0)
        _ = try await service.handle("cancel", input: ["id": first["id"]])
        try await codeFixtureEventually { witness.active("subscription") == 3 && witness.active("fixture") == 2 }
        XCTAssertEqual(witness.peak("fixture"), 2); XCTAssertEqual(witness.peak("subscription"), 3); XCTAssertLessThanOrEqual(witness.matchPeak(), 2)
        _ = try await service.handle("cancel", input: ["id": second["id"]]); _ = try await service.handle("cancel", input: ["id": third["id"]])
        XCTAssertEqual(witness.total(), 0)
    }
    func testDeadlineClosesInjectedChannelAndFallbackPrefersIndexWhileKeepingFailure() async throws {
        let runtime = try fixture(), store = try ArenaStore(runtime: runtime)
        let m = try store.create(["mode": "chosen", "prompt": "Fixture", "notify": false, "timeout_s": 1, "max_turns": 9], contestants: [["route": "subscription", "model": "sonnet"], ["route": "subscription", "model": "haiku"]])
        let slot = try store.slots(m["id"])[0], channel = CodeFixtureChannel { frame in frame["type"].string == "control_request" ? Self.reply(frame) : [] }
        let runner = ArenaSlotRunner(runtime: runtime, slot: slot, match: m, factory: { _,_,_,args,_ in
            XCTAssertEqual(args[args.firstIndex(of: "--max-turns")! + 1], "9"); return channel
        }, onEvent: { _,_ in }, onLive: { _ in })
        let expired = await runner.run(); XCTAssertEqual(expired["status"], "failed"); XCTAssertTrue(expired["error"].string.contains("time limit")); XCTAssertTrue(channel.didClose())
        let workspace = URL(fileURLWithPath: slot["workdir"].string)
        try Data("<h1>Fixture</h1>".utf8).write(to: workspace.appendingPathComponent("index.html")); try Data("fallback".utf8).write(to: workspace.appendingPathComponent("README.md"))
        let failed = CodeFixtureChannel { frame in
            if frame["type"].string == "user" { return [["type": "result", "subtype": "error", "is_error": true, "errors": ["fixture failure"]]] }
            return Self.reply(frame)
        }
        let fallback = ArenaSlotRunner(runtime: runtime, slot: slot, match: m, factory: { _,_,_,_,_ in failed }, onEvent: { _,_ in }, onLive: { _ in })
        let outcome = await fallback.run(); XCTAssertEqual(outcome["status"], "done"); XCTAssertEqual(outcome["presents"].array.first?["path"], "index.html"); XCTAssertEqual(outcome["error"], "fixture failure"); XCTAssertTrue(failed.didClose())
    }
    func testRecoveredFailureWithNullJobErrorGetsHonestFallbackExplanation() async throws {
        let runtime = try fixture(), store = try ArenaStore(runtime: runtime)
        let match = try store.create(["mode": "chosen", "prompt": "Fixture", "notify": false, "timeout_s": 1, "max_turns": 5], contestants: [["route": "subscription", "model": "sonnet"], ["route": "subscription", "model": "haiku"]])
        try runtime.db.execute("INSERT INTO jobs(id,kind,app,title,lane,params,status,created_at,error) VALUES(?,?,?,?,?,?,?,1,NULL)", ["failed-no-error", "arena.match", "arena", "Fixture", "arena", "{}", "failed"])
        try store.patchMatch(match["id"], ["job_id": "failed-no-error"])
        let service = NativeArenaService(runtime: runtime)
        try await service.reconcileAfterRecovery()
        let recovered = try await service.handle("match", input: ["id": match["id"]])
        XCTAssertEqual(recovered["status"], "failed"); XCTAssertEqual(recovered["error"], "Run interrupted by restart")
    }
}

private final class ArenaAdmissionWitness: @unchecked Sendable {
    private let lock = NSLock()
    private var slots: [String: (String, String)] = [:], peaks: [String: Int] = [:], maximumMatches = 0
    func begin(_ slot: JSONValue) { lock.lock(); defer { lock.unlock() }; slots[slot["id"].string] = (slot["route"].string, slot["match_id"].string); let route = slot["route"].string; peaks[route] = max(peaks[route] ?? 0, slots.values.filter { $0.0 == route }.count); maximumMatches = max(maximumMatches, Set(slots.values.map { $0.1 }).count) }
    func end(_ id: String) { lock.lock(); defer { lock.unlock() }; slots[id] = nil }
    func active(_ route: String) -> Int { lock.lock(); defer { lock.unlock() }; return slots.values.filter { $0.0 == route }.count }
    func peak(_ route: String) -> Int { lock.lock(); defer { lock.unlock() }; return peaks[route] ?? 0 }
    func matchPeak() -> Int { lock.lock(); defer { lock.unlock() }; return maximumMatches }
    func total() -> Int { lock.lock(); defer { lock.unlock() }; return slots.count }
}
private final class ArenaHeldChannel: CodeChannel, @unchecked Sendable {
    private let base: CodeFixtureChannel, slotID: String, witness: ArenaAdmissionWitness
    var output: AsyncThrowingStream<Data, Error> { base.output }
    init(slot: JSONValue, witness: ArenaAdmissionWitness) {
        slotID = slot["id"].string; self.witness = witness; witness.begin(slot)
        base = CodeFixtureChannel { frame in
            guard frame["type"].string == "control_request" else { return [] }
            return [["type": "control_response", "response": ["subtype": "success", "request_id": frame["request_id"], "response": ["hooks_applied": true]]]]
        }
    }
    func write(_ value: JSONValue) async throws { try await base.write(value) }
    func close() async { await base.close(); witness.end(slotID) }
    func wait() async throws -> Int32 { try await base.wait() }
}
