import XCTest
import Foundation
import Darwin
@testable import UniApiCore

final class ArenaTests: XCTestCase {
    private func runtime() throws -> NativeRuntime {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("arena-fixture-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("home"), withIntermediateDirectories: true)
        try NativeFile.writeAtomic(try JSONValue.object(["providers": []]).encoded(), to: root.appendingPathComponent("providers.json"))
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return try NativeRuntime(paths: NativePaths(root: root, home: root.appendingPathComponent("home")))
    }
    private func match(_ store: ArenaStore) throws -> JSONValue { try store.create(["mode": "chosen", "prompt": "Fixture task", "notify": false, "timeout_s": 5, "max_turns": 5], contestants: [["route": "subscription", "model": "sonnet"], ["route": "subscription", "model": "haiku"]]) }
    private func finished(_ store: ArenaStore) throws -> JSONValue { let m = try match(store); for slot in try store.slots(m["id"]) { try store.patchSlot(slot["id"], ["status": "done", "duration_ms": 1000, "turns": 2, "final_text": "fixture"] ) }; try store.patchMatch(m["id"], ["status": "done"]); return try store.match(m["id"])! }
    func testSeededPresetsStayDeletedAndCustomPresetsUpdate() throws {
        let runtime = try runtime(), store = try ArenaStore(runtime: runtime)
        XCTAssertEqual(try store.presets().count, 14)
        let first = try XCTUnwrap(store.presets().first); try store.removePreset(first["id"])
        let reopened = try ArenaStore(runtime: runtime); XCTAssertEqual(try reopened.presets().count, 13)
        let custom = try reopened.savePreset(["title": "Fixture", "prompt": "Build fixture", "category": "fixture"])
        let updated = try reopened.savePreset(["title": "Updated", "prompt": "Updated fixture"], id: custom["id"])
        XCTAssertEqual(updated["title"].string, "Updated"); XCTAssertFalse(updated["builtin"].bool)
    }
    func testBlindEventsIdentityRevealAndWorkspaceDeletionPreservesLedger() throws {
        let runtime = try runtime(), store = try ArenaStore(runtime: runtime), m = try finished(store), slots = try store.slots(m["id"]), slot = slots[0]
        _ = try store.addEvent(slot["id"], type: "init", payload: ["model": slot["model"], "cwd": slot["workdir"]])
        _ = try store.addEvent(slot["id"], type: "assistant", payload: ["model": slot["model"], "content": []])
        XCTAssertEqual(m["slots"].array[0]["model"].string, ""); XCTAssertTrue(m["slots"].array[0]["workdir"].isNull)
        XCTAssertTrue(try store.events(slot["id"], after: 0)[0]["payload"]["model"].isNull)
        let ledger = ArenaLedger(runtime: runtime), record = ArenaLedger.record(match: try store.rawMatch(m["id"])!, slots: slots, ranking: [0, 1], voter: "fixture", at: 1000)
        _ = try ledger.write(record); try store.patchMatch(m["id"], ["voted_at": 1000, "verdict": "ranked", "ranking": "[0,1]"])
        XCTAssertEqual(try store.match(m["id"])!["slots"].array[0]["model"].string, "sonnet")
        XCTAssertEqual(try store.events(slot["id"], after: 0)[0]["payload"]["model"].string, "sonnet")
        try FileManager.default.createDirectory(atPath: slot["workdir"].string, withIntermediateDirectories: true)
        try store.delete(m["id"]); XCTAssertFalse(FileManager.default.fileExists(atPath: slot["workdir"].string)); XCTAssertEqual(ledger.records(), [record]); XCTAssertTrue(try runtime.db.query("SELECT * FROM arena_slot_events").isEmpty)
    }
    func testVoteValidatesCompleteRanksWritesOnceAndReconcilesInterruptedDatabaseUpdate() async throws {
        let runtime = try runtime(), store = try ArenaStore(runtime: runtime), m = try finished(store), service = NativeArenaService(runtime: runtime)
        do { _ = try await service.handle("vote", input: ["id": m["id"], "ranking": [0,0]]); XCTFail("Duplicate ranks accepted") } catch {}
        let ledger = ArenaLedger(runtime: runtime), record = ArenaLedger.record(match: try store.rawMatch(m["id"])!, slots: try store.slots(m["id"]), ranking: [1,0], voter: try store.voter(), at: 1000)
        _ = try ledger.write(record)
        let result = try await service.handle("vote", input: ["id": m["id"], "ranking": [1,0]])
        XCTAssertEqual(result["voted_at"].int, 1000); XCTAssertTrue(result["revealed"].bool); XCTAssertEqual(ledger.records().count, 1)
        do { _ = try await service.handle("vote", input: ["id": m["id"], "allBad": true]); XCTFail("Second vote accepted") } catch {}
        var changed = record; changed["ts"] = 2000
        XCTAssertThrowsError(try ledger.write(changed)); XCTAssertEqual(ledger.records(), [record])
    }
    func testLedgerWriteFailureDoesNotMarkMatchJudged() async throws {
        let runtime = try runtime(), store = try ArenaStore(runtime: runtime), m = try finished(store), service = NativeArenaService(runtime: runtime)
        let ledgerRoot = runtime.paths.root.appendingPathComponent("arena"); try Data("blocking-file".utf8).write(to: ledgerRoot)
        do { _ = try await service.handle("vote", input: ["id": m["id"], "allBad": true]); XCTFail("Expected ledger failure") } catch {}
        XCTAssertTrue(try store.rawMatch(m["id"])!["voted_at"].isNull)
    }
    func testPairwiseEloAllBadFailureAndModeScopes() {
        let rows: [JSONValue] = [["v": 1, "id": "one", "ts": 1, "mode": "random", "verdict": "ranked", "contestants": [["route": "p", "model": "a", "status": "done", "rank": 1, "duration_ms": 1000, "turns": 2], ["route": "p", "model": "b", "status": "done", "rank": 2], ["route": "p", "model": "c", "status": "failed", "rank": .null]]], ["v": 1, "id": "two", "ts": 2, "mode": "chosen", "verdict": "all_bad", "contestants": [["route": "p", "model": "a", "status": "done"], ["route": "p", "model": "b", "status": "done"]]]]
        let random = ArenaRanking.standings(rows, mode: "random")
        XCTAssertEqual(random.first?["elo"].int, 1016); XCTAssertEqual(random.first?["firsts"].int, 1); XCTAssertEqual(random.first?["avg_duration_ms"].int, 1000)
        let all = ArenaRanking.standings(rows); XCTAssertEqual(all.first?["draws"].int, 1); XCTAssertEqual(all.first?["matches"].int, 2); XCTAssertEqual(all.first { $0["model"].string == "c" }?["elo"].int, 1000); XCTAssertEqual(all.first { $0["model"].string == "c" }?["failures"].int, 1)
        var duplicate = rows[0]; duplicate["contestants"] = .array([rows[0]["contestants"].array[0], rows[0]["contestants"].array[0]]); XCTAssertFalse(ArenaRanking.valid(duplicate)); XCTAssertTrue(ArenaRanking.standings([duplicate]).isEmpty)
        var invalid = rows[0]; invalid["v"] = "1"; XCTAssertFalse(ArenaRanking.valid(invalid))
    }
    func testSandboxRejectsTraversalDanglingLinksHardlinksHiddenStoresAndSpecialFiles() throws {
        let runtime = try runtime(), workspace = runtime.paths.tmp.appendingPathComponent("slot")
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        let outside = runtime.paths.home.appendingPathComponent("outside"); try Data("private".utf8).write(to: outside)
        XCTAssertThrowsError(try ArenaSandbox.file("../outside", workspace: workspace, home: runtime.paths.home))
        try FileManager.default.createSymbolicLink(at: workspace.appendingPathComponent("dangling"), withDestinationURL: runtime.paths.home.appendingPathComponent("missing"))
        XCTAssertThrowsError(try ArenaSandbox.file("dangling/new", workspace: workspace, home: runtime.paths.home))
        try FileManager.default.linkItem(at: outside, to: workspace.appendingPathComponent("hardlink")); XCTAssertThrowsError(try ArenaSandbox.file("hardlink", workspace: workspace, home: runtime.paths.home))
        try FileManager.default.createDirectory(at: workspace.appendingPathComponent(".claude"), withIntermediateDirectories: true)
        try Data("private".utf8).write(to: workspace.appendingPathComponent(".claude/settings.json"))
        XCTAssertThrowsError(try ArenaSandbox.readAsset(".claude/settings.json", workspace: workspace, home: runtime.paths.home))
        try Data("body{}".utf8).write(to: workspace.appendingPathComponent("style.css"))
        XCTAssertEqual(try ArenaSandbox.readAsset("style.css", workspace: workspace, home: runtime.paths.home).mime, "text/css")
        XCTAssertEqual(try ArenaSandbox.files(workspace: workspace, home: runtime.paths.home).map { $0["path"].string }, ["style.css"])
        let fifo = workspace.appendingPathComponent("pipe"); XCTAssertEqual(mkfifo(fifo.path, 0o600), 0)
        XCTAssertThrowsError(try ArenaSandbox.readAsset("pipe", workspace: workspace, home: runtime.paths.home))
        XCTAssertEqual(ArenaSandbox.offendingPath("Read", input: ["file_path": .string(outside.path)], workspace: workspace, home: runtime.paths.home), outside.path)
        XCTAssertNil(ArenaSandbox.offendingPath("Bash", input: ["command": "fixture"], workspace: workspace, home: runtime.paths.home))
    }
    func testPresentValidationAndOwnedAssetRead() throws {
        let runtime = try runtime(), store = try ArenaStore(runtime: runtime), m = try match(store), slot = try store.slots(m["id"])[0], workspace = URL(fileURLWithPath: slot["workdir"].string)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        try Data("<h1>Fixture</h1>".utf8).write(to: workspace.appendingPathComponent("index.html"))
        let p = try ArenaSandbox.present(["kind": "file", "title": "Fixture", "path": "index.html"], workspace: workspace, home: runtime.paths.home)
        XCTAssertEqual(p["path"].string, "index.html"); XCTAssertThrowsError(try ArenaSandbox.present(["kind": "url", "title": "Unsafe", "url": "file:///fixture"], workspace: workspace, home: runtime.paths.home))
        XCTAssertThrowsError(try ArenaSandbox.present(["kind": "text", "title": 3, "text": "Fixture"], workspace: workspace, home: runtime.paths.home))
        XCTAssertEqual(try NativeArenaArtifacts.read(runtime: runtime, slotID: slot["id"].string, path: "index.html").mime, "text/html")
        try runtime.db.execute("UPDATE arena_slots SET workdir=? WHERE id=?", [.string(runtime.paths.home.path), slot["id"]])
        XCTAssertThrowsError(try NativeArenaArtifacts.read(runtime: runtime, slotID: slot["id"].string, path: "outside"))
    }
    func testWorkspaceArtifactAssetsAndMarkdownImageLinksRemainBounded() throws {
        let runtime = try runtime(), store = try ArenaStore(runtime: runtime), match = try match(store), slot = try store.slots(match["id"])[0], workspace = URL(fileURLWithPath: slot["workdir"].string)
        try FileManager.default.createDirectory(at: workspace.appendingPathComponent("docs"), withIntermediateDirectories: true)
        try Data("body{color:blue}".utf8).write(to: workspace.appendingPathComponent("style.css"))
        try Data("console.log('fixture')".utf8).write(to: workspace.appendingPathComponent("script.mjs"))
        try Data("<svg xmlns='http://www.w3.org/2000/svg'></svg>".utf8).write(to: workspace.appendingPathComponent("image.svg"))
        let path = try XCTUnwrap(CodeMarkdown.relativeAsset("../image.svg", document: "docs/readme.md"))
        XCTAssertEqual(try NativeArenaArtifacts.read(runtime: runtime, slotID: slot["id"].string, path: path).mime, "image/svg+xml")
        XCTAssertEqual(try NativeArenaArtifacts.read(runtime: runtime, slotID: slot["id"].string, path: "style.css").mime, "text/css")
        XCTAssertEqual(try NativeArenaArtifacts.read(runtime: runtime, slotID: slot["id"].string, path: "script.mjs").mime, "text/javascript")
        XCTAssertThrowsError(try NativeArenaArtifacts.read(runtime: runtime, slotID: slot["id"].string, path: "../../outside"))
        let oversized = workspace.appendingPathComponent("oversized.bin"); XCTAssertTrue(FileManager.default.createFile(atPath: oversized.path, contents: nil)); let handle = try FileHandle(forWritingTo: oversized); try handle.truncate(atOffset: 26 * 1024 * 1024); try handle.close()
        XCTAssertThrowsError(try NativeArenaArtifacts.read(runtime: runtime, slotID: slot["id"].string, path: "oversized.bin"))
    }
    func testSlotRefusesMissingHooksBeforeSendingPrompt() async throws {
        let runtime = try runtime(), store = try ArenaStore(runtime: runtime), m = try match(store), slot = try store.slots(m["id"])[0]
        let channel = CodeFixtureChannel { frame in Self.controlReply(frame, hooks: false) }
        let runner = ArenaSlotRunner(runtime: runtime, slot: slot, match: m, factory: { _,_,_,_,_ in channel }, onEvent: { _,_ in }, onLive: { _ in })
        let result = await runner.run(); XCTAssertEqual(result["status"].string, "failed"); XCTAssertTrue(result["error"].string.contains("hooks")); XCTAssertFalse(channel.frames().contains { $0["type"].string == "user" }); XCTAssertTrue(channel.didClose())
    }
    func testSlotHostedPresentationSurvivesFailedResultAndAccountsCacheTokens() async throws {
        let runtime = try runtime(), store = try ArenaStore(runtime: runtime), m = try match(store), slot = try store.slots(m["id"])[0]
        let channel = CodeFixtureChannel { frame in
            if frame["type"].string == "control_request" { return Self.controlReply(frame, hooks: true) }
            if frame["type"].string == "user" { return [["type": "control_request", "request_id": "present", "request": ["subtype": "mcp_message", "server_name": "arena", "message": ["jsonrpc": "2.0", "id": 7, "method": "tools/call", "params": ["name": "present", "arguments": ["kind": "text", "title": "Fixture", "text": "Judge me"]]]]], ["type": "result", "subtype": "error", "is_error": true, "errors": ["fixture failure"], "num_turns": 3, "usage": ["input_tokens": 2, "cache_read_input_tokens": 5, "cache_creation_input_tokens": 1, "output_tokens": 9], "total_cost_usd": 0.1]] }; return []
        }
        let runner = ArenaSlotRunner(runtime: runtime, slot: slot, match: m, factory: { _,_,settings,args,_ in XCTAssertTrue(settings["sandbox"]["failIfUnavailable"].bool); XCTAssertTrue(args.contains("--setting-sources=")); return channel }, onEvent: { _,_ in }, onLive: { _ in })
        let result = await runner.run(); XCTAssertEqual(result["status"].string, "done"); XCTAssertEqual(result["presents"].array.count, 1); XCTAssertEqual(result["input_tokens"].int, 8); XCTAssertEqual(result["output_tokens"].int, 9); XCTAssertEqual(result["error"].string, "fixture failure")
        XCTAssertEqual(channel.frames().first { $0["response"]["request_id"].string == "present" }?["response"]["response"]["mcp_response"]["id"].int, 7)
    }
    func testSemaphoreCancellationAndIdempotentRelease() async throws {
        let semaphore = ArenaSemaphore(1), first = try await semaphore.acquire()
        let waiting = Task { try await semaphore.acquire() }; await Task.yield(); waiting.cancel()
        do { _ = try await waiting.value; XCTFail("Cancelled waiter acquired permit") } catch {}
        await semaphore.release(first); await semaphore.release(first); let next = try await semaphore.acquire(); await semaphore.release(next)
    }
    func testErrorWithoutPresentationIsFailureAndCleanEmptyCompletionKeepsCurrentClassification() async throws {
        let runtime = try runtime(), store = try ArenaStore(runtime: runtime), m = try match(store), slot = try store.slots(m["id"])[0]
        for isError in [true, false] {
            let channel = CodeFixtureChannel { frame in if frame["type"].string == "control_request" { return Self.controlReply(frame, hooks: true) }; if frame["type"].string == "user" { return [["type": "result", "is_error": .bool(isError), "subtype": .string(isError ? "error" : "success"), "errors": isError ? ["fixture authentication refused"] : []]] }; return [] }
            let runner = ArenaSlotRunner(runtime: runtime, slot: slot, match: m, factory: { _,_,_,_,_ in channel }, onEvent: { _,_ in }, onLive: { _ in })
            let outcome = await runner.run(); XCTAssertEqual(outcome["status"].string, isError ? "failed" : "done"); XCTAssertTrue(outcome["presents"].array.isEmpty)
        }
    }
    func testServiceRunsIsolatedContestantsVotesAndCancelsWithoutLiveAgent() async throws {
        let runtime = try runtime(), channels = ArenaFixtureChannels(), notices = ArenaFixtureNotices()
        let service = NativeArenaService(runtime: runtime, channelFactory: { _,_,_,_,_ in let channel = CodeFixtureChannel { frame in if frame["type"].string == "control_request" { return Self.controlReply(frame, hooks: true) }; if frame["type"].string == "user" { return [["type": "assistant", "message": ["content": [["type": "text", "text": "Fixture answer"]]]], ["type": "result", "subtype": "success", "usage": ["output_tokens": 3]]] }; return [] }; channels.add(channel); return channel }, notification: { text in await notices.add(text); return true })
        let state = try await service.handle("state"); XCTAssertFalse(state["contestants"].array.contains { $0["route"].string.hasPrefix("agent:") })
        let m = try await service.handle("match.create", input: ["mode": "chosen", "prompt": "Fixture", "notify": true, "contestants": [["route": "subscription", "model": "sonnet"], ["route": "subscription", "model": "haiku"]]])
        try await eventually { (try? await service.handle("match", input: ["id": m["id"]])["status"].string) == "done" }
        let result = try await service.handle("vote", input: ["id": m["id"], "allBad": true]); XCTAssertEqual(result["verdict"].string, "all_bad"); XCTAssertTrue(channels.rows().allSatisfy { $0.didClose() }); let count = await notices.count(); XCTAssertEqual(count, 1)
        let hanging = NativeArenaService(runtime: runtime, channelFactory: { _,_,_,_,_ in let channel = CodeFixtureChannel { frame in Self.controlReply(frame, hooks: true) }; channels.add(channel); return channel }, notification: { _ in XCTFail("Cancelled match notified"); return false })
        let pending = try await hanging.handle("match.create", input: ["mode": "chosen", "prompt": "Hanging fixture", "notify": true, "contestants": [["route": "subscription", "model": "sonnet"], ["route": "subscription", "model": "haiku"]]])
        try await eventually { channels.rows().count == 4 }
        _ = try await hanging.handle("cancel", input: ["id": pending["id"]]); XCTAssertTrue(channels.rows().allSatisfy { $0.didClose() }); let cancelled = try await hanging.handle("match", input: ["id": pending["id"]]); XCTAssertEqual(cancelled["status"].string, "cancelled")
    }
    func testNativeCredentialGateScansLongLinesWithoutPlaceholderBypass() {
        let synthetic = "sk-" + String(repeating: "Z", count: 32)
        XCTAssertTrue(ArenaSecretScan.hasSecret(String(repeating: "a", count: 9000) + " " + synthetic)); XCTAssertTrue(ArenaSecretScan.hasSecret("example in unrelated text " + synthetic)); XCTAssertFalse(ArenaSecretScan.hasSecret("fixture output"))
    }
    func testReadOnlyStateAndMatchWithoutVoterNeverReconcileOrWriteDatabase() async throws {
        let writable = try runtime(), store = try ArenaStore(runtime: writable), match = try match(store), id = match["id"]
        try writable.db.execute("INSERT INTO jobs(id,kind,app,title,lane,params,status,created_at,error) VALUES(?,?,?,?,?,?,?,1,?)", ["interrupted-job", "arena.match", "arena", "Fixture", "arena", "{}", "failed", "Fixture failure"])
        try store.patchMatch(id, ["job_id": "interrupted-job"])
        XCTAssertTrue(try writable.db.query("SELECT * FROM arena_kv WHERE key='voter'").isEmpty)
        func rows() throws -> JSONValue { .array(try ["arena_matches", "arena_slots", "arena_slot_events", "arena_prompts", "arena_kv", "jobs"].map { .array(try writable.db.query("SELECT * FROM \($0) ORDER BY rowid").map(JSONValue.object)) }) }
        let before = try rows(), database = writable.paths.database, bytes = try Data(contentsOf: database), wal = try? Data(contentsOf: URL(fileURLWithPath: database.path + "-wal"))
        let readOnly = try NativeRuntime(paths: NativePaths(root: writable.paths.root, home: writable.paths.home, readOnly: true)), service = NativeArenaService(runtime: readOnly)
        let state = try await service.handle("state"); XCTAssertTrue(state["voter"].isNull); XCTAssertEqual(state["presets"].array.count, 14)
        let loaded = try await service.handle("match", input: ["id": id]); XCTAssertEqual(loaded["status"].string, "queued"); XCTAssertFalse(loaded["revealed"].bool)
        try await service.reconcileAfterRecovery()
        let readStore = try ArenaStore(runtime: readOnly); XCTAssertTrue(try readStore.voter().isNull); XCTAssertEqual(try readStore.rawMatch(id)?["status"].string, "queued")
        XCTAssertEqual(try rows(), before); XCTAssertEqual(try Data(contentsOf: database), bytes); XCTAssertEqual(try? Data(contentsOf: URL(fileURLWithPath: database.path + "-wal")), wal)
        do { _ = try await service.handle("vote", input: ["id": id, "allBad": true]); XCTFail("Read-only snapshot allowed a vote") } catch { XCTAssertEqual(error.localizedDescription, "This runtime is read-only") }
    }
    func testReconcileAfterRecoveryFailsInterruptedRunButPreservesRecoveredQueuedJob() async throws {
        let runtime = try runtime(), store = try ArenaStore(runtime: runtime), running = try match(store), queued = try match(store), orphan = try match(store), gate = ArenaRecoveryGate()
        try store.patchMatch(running["id"], ["status": "running", "job_id": "running-original"]); try store.patchMatch(queued["id"], ["job_id": "queued-original"])
        for slot in try store.slots(running["id"]) { try store.patchSlot(slot["id"], ["status": "running"]) }
        for (job, status, id) in [("running-original", "running", running["id"]), ("queued-original", "queued", queued["id"])] {
            try runtime.db.execute("INSERT INTO jobs(id,kind,app,title,lane,params,status,created_at) VALUES(?,?,?,?,?,?,?,1)", [.string(job), "arena.match", "arena", "Fixture", "arena", .string(String(decoding: try JSONValue.object(["matchId": id]).encoded(), as: UTF8.self)), .string(status)])
        }
        let service = NativeArenaService(runtime: runtime)
        try await service.start(); XCTAssertEqual(try store.rawMatch(running["id"])?["status"].string, "running")
        // Replace the fixture queue handler before recovery; no contestant,
        // network request or vendor process may execute in this test.
        await runtime.jobs.register(kind: "arena.match", lane: "arena", concurrency: 2, resumable: false) { _,_ in await gate.wait(); return [:] }
        try await runtime.jobs.recover()
        try runtime.db.executeScript("CREATE TRIGGER fixture_reconcile_failure BEFORE UPDATE ON arena_slots BEGIN SELECT RAISE(ABORT,'fixture write failure'); END;")
        do { try await service.reconcileAfterRecovery(); XCTFail("Expected fixture write failure") } catch {}
        XCTAssertEqual(try store.rawMatch(running["id"])?["status"].string, "running")
        XCTAssertTrue(try store.slots(running["id"]).allSatisfy { $0["status"].string == "running" })
        try runtime.db.executeScript("DROP TRIGGER fixture_reconcile_failure")
        try await service.reconcileAfterRecovery()
        let interrupted = try await service.handle("match", input: ["id": running["id"]]); XCTAssertEqual(interrupted["status"].string, "failed"); XCTAssertTrue(interrupted["slots"].array.allSatisfy { $0["status"].string == "failed" })
        let remaining = try await service.handle("match", input: ["id": queued["id"]]); XCTAssertEqual(remaining["status"].string, "queued")
        let missing = try await service.handle("match", input: ["id": orphan["id"]]); XCTAssertEqual(missing["status"].string, "failed"); XCTAssertTrue(missing["error"].string.contains("registered"))
        try await service.reconcileAfterRecovery(); XCTAssertEqual(try store.rawMatch(queued["id"])?["status"].string, "queued")
        await gate.release()
        try await eventually { (try? await runtime.jobs.get("queued-original")?["status"]?.string) == "done" }
    }
    private static func controlReply(_ frame: JSONValue, hooks: Bool) -> [JSONValue] { guard frame["type"].string == "control_request" else { return [] }; return [["type": "control_response", "response": ["subtype": "success", "request_id": frame["request_id"], "response": ["hooks_applied": .bool(hooks), "models": []]]]] }
    private func eventually(_ condition: @escaping () async -> Bool) async throws { for _ in 0..<500 { if await condition() { return }; try await Task.sleep(nanoseconds: 1_000_000) }; XCTFail("Fixture did not settle") }
}
private final class ArenaFixtureChannels: @unchecked Sendable { private let lock = NSLock(); private var values: [CodeFixtureChannel] = []; func add(_ channel: CodeFixtureChannel) { lock.lock(); values.append(channel); lock.unlock() }; func rows() -> [CodeFixtureChannel] { lock.lock(); defer { lock.unlock() }; return values } }
private actor ArenaFixtureNotices { private var values: [String] = []; func add(_ value: String) { values.append(value) }; func count() -> Int { values.count } }
private actor ArenaRecoveryGate { private var released = false; private var waiters: [CheckedContinuation<Void, Never>] = []; func wait() async { if !released { await withCheckedContinuation { waiters.append($0) } } }; func release() { released = true; let pending = waiters; waiters = []; for waiter in pending { waiter.resume() } } }
