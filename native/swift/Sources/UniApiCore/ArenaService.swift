import Foundation

/// Native equivalents of /api/arena. Reads never start contestants or probes.
/// Operations: state/settings/check, presets/preset.save/preset.delete,
/// matches/match/match.create/vote/skip/cancel/rerun/delete, events/files/preview,
/// ranking, ledger.status/records/publish/sync and summary.
public actor NativeArenaService {
    public let runtime: NativeRuntime
    private static let pool = ArenaServicePool()
    public nonisolated static func shared(runtime: NativeRuntime) -> NativeArenaService { pool.get(runtime) }
    private var store: ArenaStore?, started = false, sharing = false
    private var semaphores: [String: ArenaSemaphore] = [:]
    private var live: [String: JSONValue] = [:]
    private let factory: ArenaChannelFactory?
    private let notification: (@Sendable (String) async -> Bool)?
    public init(runtime: NativeRuntime) { self.runtime = runtime; factory = nil; notification = nil }
    init(runtime: NativeRuntime, channelFactory: ArenaChannelFactory?, notification: (@Sendable (String) async -> Bool)? = nil) { self.runtime = runtime; factory = channelFactory; self.notification = notification }
    public func start() async throws {
        if store == nil { store = try ArenaStore(runtime: runtime) }
        guard !started else { return }; started = true
        await runtime.jobs.register(kind: "arena.match", lane: "arena", concurrency: 2, resumable: false) { [weak self] params, context in guard let self else { throw NativeFailure("Arena service unavailable") }; return try await self.runMatch(params["matchId"], context: context) }
    }
    /// Called after exclusive ownership and queue recovery. Registering this
    /// handler first lets recovery decide which non-resumable runs failed;
    /// recovered queued jobs remain eligible and are never failed by a read.
    public func reconcileAfterRecovery() async throws {
        guard !runtime.paths.readOnly else { return }
        try await start()
        for row in try runtime.db.query("SELECT id,job_id FROM arena_matches WHERE status IN ('queued','running')") {
            let job = try await runtime.jobs.get((row["job_id"] ?? .null).string)
            if job == nil || ["failed", "cancelled"].contains(job?["status"]?.string ?? "") {
                // A restart between these writes must not leave a failed match
                // with forever-running slots that the next pass would skip.
                try runtime.db.transaction {
                    try store?.patchMatch(row["id"]!, ["status": job?["status"] ?? "failed", "error": job?["error"].flatMap { $0.isNull ? Optional<JSONValue>.none : .some($0) } ?? .string(job == nil ? "Match interrupted before its background job was registered" : "Run interrupted by restart"), "finished_at": CodeStore.now()])
                    for slot in try store!.slots(row["id"]!) where ["queued", "running"].contains(slot["status"].string) { try store?.patchSlot(slot["id"], ["status": "failed", "error": "Run interrupted by restart", "finished_at": CodeStore.now()]) }
                }
                _ = try await publish(row["id"]!)
            }
        }
    }
    private func contestants() -> [JSONValue] {
        let rows = CodeRoutes.list(runtime).filter { $0["kind"].string != "agent" }.flatMap { route -> [JSONValue] in route["models"].array.filter { if case .string(let value) = $0 { return !value.isEmpty && value != "default" }; return false }.map { model in ["route": route["id"], "model": model, "label": .string(route["name"].string + " · " + model.string), "routeName": route["name"], "format": route["format"]] } }
        return ArenaContestantPolicy.unique(rows)
    }
    private func excluded(_ pool: [JSONValue]) throws -> Set<String> { ArenaContestantPolicy.selection(Set(try store!.get("excluded", fallback: []).array.map(\.string)), contestants: pool) }
    private static func roundedLimit(_ value: JSONValue, fallback: Int, bounds: ClosedRange<Int>) -> Int {
        guard case .number(let number) = value, number.isFinite else { return fallback }
        // Arena's limits are positive. Nearest/away therefore has web
        // Math.round's positive-half behavior. Bound the Double before Int so
        // even a finite JSON number beyond Int.max cannot trap or become zero.
        let bounded = max(Double(bounds.lowerBound), min(Double(bounds.upperBound), number))
        return Int(bounded.rounded(.toNearestOrAwayFromZero))
    }
    private static func creationLimit(_ value: JSONValue, fallback: Int, bounds: ClosedRange<Int>) -> Int {
        // Creation accepts scalar coercions that settings' number-only guard
        // excludes. Null still selects the saved/default value.
        switch value {
        case .bool(let flag): return roundedLimit(.number(flag ? 1 : 0), fallback: fallback, bounds: bounds)
        case .string(let text):
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty { return bounds.lowerBound }
            if let number = Double(trimmed) { return roundedLimit(.number(number), fallback: fallback, bounds: bounds) }
        default: break
        }
        return roundedLimit(value, fallback: fallback, bounds: bounds)
    }
    private func defaults() throws -> JSONValue {
        let saved = try store!.get("defaults", fallback: [:])
        return ["count": .number(Double(Self.creationLimit(saved["count"], fallback: 2, bounds: 2...8))), "timeoutMin": .number(Double(Self.creationLimit(saved["timeoutMin"], fallback: 20, bounds: 2...120))), "maxTurns": .number(Double(Self.creationLimit(saved["maxTurns"], fallback: 80, bounds: 5...400))), "notify": saved["notify"].isNull ? true : saved["notify"]]
    }
    public func handle(_ operation: String, input: JSONObject = [:]) async throws -> JSONValue {
        try await start(); let s = store!, b = JSONValue.object(input), id = b["id"], ledger = ArenaLedger(runtime: runtime)
        if !["state", "presets", "matches", "match", "events", "files", "preview", "ranking", "ledger.status", "ledger.records", "summary"].contains(operation) { try runtime.paths.assertWritable() }
        switch operation {
        case "state": let pool = contestants(); return ["contestants": .array(pool), "excluded": .array(try excluded(pool).sorted().map(JSONValue.string)), "defaults": try defaults(), "presets": .array(try s.presets()), "stats": try s.stats(), "voter": try s.voter(), "platform": "mac"]
        case "settings":
            if !b["excluded"].isNull { guard b["excluded"].array.allSatisfy({ if case .string = $0 { return true }; return false }) else { throw NativeFailure("Invalid exclusion list") }; try s.set("excluded", b["excluded"]) }
            if !b["defaults"].isNull {
                let keys = Set(["count", "timeoutMin", "maxTurns", "notify"])
                guard Set(b["defaults"].object.keys).isSubset(of: keys) else { throw NativeFailure("Unknown Arena defaults") }
                var d = try defaults()
                for (key, bounds) in [("count", 2...8), ("timeoutMin", 2...120), ("maxTurns", 5...400)] {
                    if case .number = b["defaults"][key] { d[key] = .number(Double(Self.roundedLimit(b["defaults"][key], fallback: d[key].int, bounds: bounds))) }
                }
                if case .bool = b["defaults"]["notify"] { d["notify"] = b["defaults"]["notify"] }
                try s.set("defaults", d)
            }
            return try await handle("state")
        case "check": return try await check(b["contestants"].array)
        case "presets": return .array(try s.presets())
        case "preset.save": let result = try s.savePreset(b, id: id.isNull ? Optional<JSONValue>.none : .some(id)); await runtime.events.publish("arena.presets", .array(try s.presets())); return result
        case "preset.delete": try s.removePreset(id); await runtime.events.publish("arena.presets", .array(try s.presets())); return ["ok": true]
        case "matches": return .array(try s.matches(view: b["view"].string, limit: b["limit"].isNull ? 100 : b["limit"].int).map(withLive))
        case "match": guard let match = try s.match(id) else { throw NativeFailure("Match no longer exists") }; return withLive(match)
        case "match.create": return try await create(b)
        case "vote":
            guard let match = try s.rawMatch(id), match["status"].string == "done", match["voted_at"].isNull else { throw NativeFailure("Only an unjudged finished match can be voted") }
            let slots = try s.slots(id), finished = slots.filter { $0["status"].string == "done" }.map { $0["idx"].int }.sorted()
            let ranking: [Int]?
            if b["allBad"].bool { ranking = nil } else { let values = b["ranking"].array; guard values.allSatisfy({ if case .number(let value) = $0 { return value.isFinite && value == value.rounded() }; return false }), values.map(\.int).sorted() == finished else { throw NativeFailure("Rank every finished contestant exactly once") }; ranking = values.map(\.int) }
            // No await from validation through durable ledger write and verdict
            // update: overlapping votes cannot publish two incompatible records.
            // Recover a ledger-first verdict if a previous database update was
            // interrupted. A conflicting second vote is refused by write().
            let existing = ledger.records().first { $0["id"] == id }
            let now = existing?["ts"] ?? CodeStore.now(), record = ArenaLedger.record(match: match, slots: slots, ranking: ranking, voter: try s.voter(), at: now), file = try ledger.write(record)
            try s.patchMatch(id, ["ranking": ranking.map { .string(String(decoding: try! JSONValue.array($0.map { .number(Double($0)) }).encoded(), as: UTF8.self)) } ?? .null, "verdict": ranking == nil ? "all_bad" : "ranked", "voted_at": now])
            let updated = try s.match(id)!; await runtime.events.publish("arena.match", updated); await runtime.events.publish("arena.voted", ["id": id, "file": .string(file.path)]); return updated
        case "skip": guard let match = try s.rawMatch(id), match["voted_at"].isNull, !["queued", "running"].contains(match["status"].string) else { throw NativeFailure("A running or already judged match cannot be skipped") }; try s.patchMatch(id, ["verdict": "skipped", "voted_at": CodeStore.now()]); return try await publish(id)
        case "cancel":
            guard let match = try s.rawMatch(id), ["queued", "running"].contains(match["status"].string) else { throw NativeFailure("Match is not running") }
            let cancelled = try await runtime.jobs.cancelAndWait(match["job_id"].string)
            if cancelled, let row = try s.rawMatch(id), row["status"].string == "queued" { try s.patchMatch(id, ["status": "cancelled", "finished_at": CodeStore.now()]); for slot in try s.slots(id) { try s.patchSlot(slot["id"], ["status": "cancelled", "finished_at": CodeStore.now()]) }; _ = try await publish(id) }
            return ["ok": .bool(cancelled)]
        case "rerun":
            guard let match = try s.match(id) else { throw NativeFailure("Match no longer exists") }
            let result = try await create(["mode": "chosen", "prompt": match["prompt"], "contestants": .array(try s.slots(id).map { ["route": $0["route"], "model": $0["model"]] }), "timeoutMin": .number(match["timeout_s"].double / 60), "maxTurns": match["max_turns"], "notify": match["notify"]])
            try s.patchMatch(result["id"], ["preset_id": match["preset_id"], "category": match["category"]]); return try s.match(result["id"])!
        case "delete": guard let match = try s.rawMatch(id) else { throw NativeFailure("Match no longer exists") }; if ["running", "queued"].contains(match["status"].string) { _ = try await runtime.jobs.cancelAndWait(match["job_id"].string) }; try s.delete(id); await runtime.events.publish("arena.match.deleted", ["id": id]); return ["ok": true]
        case "events": return .array(try s.events(id, after: b["after"].int))
        case "files", "preview":
            guard let slot = try s.rawSlot(id) else { throw NativeFailure("Slot no longer exists") }
            let workspace = try ownedWorkspace(slot)
            return operation == "files" ? ["files": .array(try ArenaSandbox.files(workspace: workspace, home: runtime.paths.home))] : try ArenaSandbox.preview(b["path"].string, workspace: workspace, home: runtime.paths.home)
        case "ranking": let records = ledger.records(); return ["standings": .array(ArenaRanking.standings(records, mode: b["mode"].string.isEmpty ? "all" : b["mode"].string)), "records": .number(Double(records.count)), "ledger": await ledger.status()]
        case "ledger.status": return await ledger.status()
        case "ledger.records": return .array(Array(ledger.records().sorted { $0["ts"].double > $1["ts"].double }.prefix(b["limit"].isNull ? 100 : max(1, min(500, b["limit"].int)))))
        case "ledger.publish", "ledger.sync": guard !sharing else { throw NativeFailure("Arena sharing is already active") }; sharing = true; defer { sharing = false }; return operation == "ledger.publish" ? try await ledger.publish(voter: s.voter()) : try await ledger.sync()
        case "summary": let stats = try s.stats(); return ["pendingVotes": stats["toJudge"], "matches": stats["total"], "running": stats["running"]]
        default: throw NativeFailure("Unknown Arena operation: \(operation)")
        }
    }
    private func ownedWorkspace(_ slot: JSONValue) throws -> URL {
        let root = store!.directory, relative = slot["match_id"].string + "/slot-\(slot["idx"].int)", expected = try runtime.paths.containedFile(relative, in: root)
        guard try ArenaSandbox.resolve(URL(fileURLWithPath: slot["workdir"].string)) == ArenaSandbox.resolve(expected) else { throw NativeFailure("Slot workspace does not belong to this runtime") }; return expected
    }
    private func create(_ b: JSONValue) async throws -> JSONValue {
        let s = store!, defaults = try defaults(), pool = contestants(), known = Dictionary(uniqueKeysWithValues: pool.map { ($0["key"].string, $0) })
        let mode = b["mode"].string == "chosen" ? "chosen" : "random"
        var preset: JSONValue = .null, prompt = b["prompt"].string.trimmingCharacters(in: .whitespacesAndNewlines)
        if !b["presetId"].isNull { guard let p = try s.preset(b["presetId"]) else { throw NativeFailure("Unknown preset") }; preset = p }
        else if b["randomPreset"].bool || prompt.isEmpty { guard let p = try s.presets().randomElement() else { throw NativeFailure("There are no presets to draw from") }; preset = p }
        if !preset.isNull { prompt = preset["prompt"].string }
        guard !prompt.isEmpty, prompt.count <= 100000 else { throw NativeFailure("Enter a bounded match prompt") }
        let picked: [JSONValue]
        if mode == "chosen" {
            let keys = Set(b["contestants"].array.map(ArenaRanking.key)); guard keys.count >= 2, keys.count <= 8, keys.allSatisfy({ known[$0] != nil }) else { throw NativeFailure("Choose two to eight distinct configured contestants") }; picked = keys.sorted().compactMap { known[$0] }.shuffled()
        } else {
            let count = Self.creationLimit(b["count"], fallback: defaults["count"].int, bounds: 2...8), excluded = try excluded(pool), eligible = pool.filter { !excluded.contains($0["key"].string) }
            guard eligible.count >= count else { throw NativeFailure("The random pool has too few eligible contestants") }; picked = Array(eligible.shuffled().prefix(count))
        }
        let minutes = Self.creationLimit(b["timeoutMin"], fallback: defaults["timeoutMin"].int, bounds: 2...120), turns = Self.creationLimit(b["maxTurns"], fallback: defaults["maxTurns"].int, bounds: 5...400)
        let match = try s.create(["mode": .string(mode), "prompt": .string(prompt), "preset_id": preset["id"], "category": preset["category"], "notify": b["notify"].isNull ? defaults["notify"] : b["notify"], "timeout_s": .number(Double(minutes * 60)), "max_turns": .number(Double(turns))], contestants: picked)
        let job = try await runtime.jobs.submit(kind: "arena.match", app: "arena", title: "Arena: " + String(prompt.prefix(48)), params: ["matchId": match["id"]])
        try s.patchMatch(match["id"], ["job_id": job["id"]!]); return try await publish(match["id"])
    }
    private func withLive(_ match: JSONValue) -> JSONValue { var value = match; let ids = Set(match["slots"].array.map { $0["id"].string }); value["live"] = .object(live.filter { ids.contains($0.key) }); return value }
    private func publish(_ id: JSONValue) async throws -> JSONValue { guard let match = try store?.match(id) else { throw NativeFailure("Match no longer exists") }; let value = withLive(match); await runtime.events.publish("arena.match", value); return value }
    private func slotLive(_ slot: JSONValue, _ value: JSONValue) async { live[slot["id"].string] = value; await runtime.events.publish("arena.slot.live", .object(value.object.merging(["matchId": slot["match_id"], "slotId": slot["id"]]) { _, new in new })) }
    private func semaphore(_ route: String) -> ArenaSemaphore { if let semaphore = semaphores[route] { return semaphore }; let semaphore = ArenaSemaphore(route == "subscription" ? 3 : 2); semaphores[route] = semaphore; return semaphore }
    private func runMatch(_ id: JSONValue, context: NativeJobContext) async throws -> JSONValue {
        let s = store!
        guard let match = try s.rawMatch(id) else { throw NativeFailure("Match no longer exists") }
        try s.patchMatch(id, ["status": "running", "started_at": CodeStore.now(), "job_id": .string(context.id)]); _ = try await publish(id)
        let slots = try s.slots(id), outcomes: [JSONValue] = await withTaskGroup(of: JSONValue.self) { group in
            for slot in slots { let semaphore = self.semaphore(slot["route"].string); group.addTask { [runtime, factory] in
                var permit: UUID?
                do {
                    permit = try await semaphore.acquire(); try context.checkCancellation()
                    await self.slotStarted(slot)
                    let runner = ArenaSlotRunner(runtime: runtime, slot: slot, match: match, factory: factory, onEvent: { type, payload in await self.slotEvent(slot, type: type, payload: payload) }, onLive: { live in await self.slotLive(slot, live) })
                    let outcome = await runner.run(); if let permit { await semaphore.release(permit) }; await self.slotFinished(slot, outcome: outcome); return outcome
                } catch { if let permit { await semaphore.release(permit) }; let outcome: JSONValue = ["status": .string(Task.isCancelled ? "cancelled" : "failed"), "error": .string(Task.isCancelled ? "cancelled" : error.localizedDescription)]; await self.slotFinished(slot, outcome: outcome); return outcome }
            } }
            var outcomes: [JSONValue] = []
            for await outcome in group { outcomes.append(outcome); try? await context.progress(Double(outcomes.count) / Double(max(1, slots.count)), text: "\(outcomes.count) of \(slots.count) finished") }
            return outcomes
        }
        let finished = outcomes.filter { $0["status"].string == "done" }.count
        if Task.isCancelled { try s.patchMatch(id, ["status": "cancelled", "finished_at": CodeStore.now()]); _ = try await publish(id); throw CancellationError() }
        let ok = finished >= 2, error = "Only \(finished) of \(slots.count) contestants finished; nothing to compare"
        try s.patchMatch(id, ["status": ok ? "done" : "failed", "error": ok ? .null : .string(error), "finished_at": CodeStore.now()]); _ = try await publish(id)
        if match["notify"].int != 0 {
            let message = ok ? "Done: Arena match ready to judge (\(finished) of \(slots.count) finished)" : "Arena match failed: \(finished) of \(slots.count) finished"
            let sent: Bool
            if let notification { sent = await notification(message) } else { sent = await nativeNotify(message) }
            if !sent { try? await context.log("Completion notification unavailable") }
        }
        guard ok else { throw NativeFailure(error) }; return ["finished": .number(Double(finished))]
    }
    private func slotStarted(_ slot: JSONValue) async { try? store?.patchSlot(slot["id"], ["status": "running", "started_at": CodeStore.now()]); if let m = try? store?.match(slot["match_id"]), let value = m["slots"].array.first(where: { $0["id"] == slot["id"] }) { await runtime.events.publish("arena.slot", value) } }
    private func slotFinished(_ slot: JSONValue, outcome: JSONValue) async { var fields = outcome.object; if fields["presents"] != nil { fields["presents"] = .string(String(decoding: (try? outcome["presents"].encoded()) ?? Data(), as: UTF8.self)) }; fields["finished_at"] = CodeStore.now(); try? store?.patchSlot(slot["id"], fields); if let m = try? store?.match(slot["match_id"]), let value = m["slots"].array.first(where: { $0["id"] == slot["id"] }) { await runtime.events.publish("arena.slot", value) } }
    private func slotEvent(_ slot: JSONValue, type: String, payload: JSONValue) async { do { if let event = try store?.addEvent(slot["id"], type: type, payload: payload) { await runtime.events.publish("arena.slot.event", ["matchId": slot["match_id"], "slotId": slot["id"], "event": ArenaStore.redact(event)]) } } catch { await runtime.events.publish("runtime.error", .string("Arena transcript persistence failed: \(error.localizedDescription)")) } }
    private func nativeNotify(_ message: String) async -> Bool {
        do { return try await NativeNotifications.send(message, home: runtime.paths.home) }
        catch { return false }
    }
    private func check(_ input: [JSONValue]) async throws -> JSONValue {
        guard input.count <= 64 else { throw NativeFailure("At most 64 route checks per request") }
        let known = Set(contestants().map { $0["key"].string }), rows = input.filter { known.contains(ArenaRanking.key($0)) }
        var output: [JSONValue] = []
        for c in rows {
            if c["route"].string == "subscription" { output.append(["route": c["route"], "model": c["model"], "key": .string(ArenaRanking.key(c)), "ok": true, "skipped": true, "ms": 0, "message": "Subscription is not probed"]); continue }
            let settings = try CodeRoutes.settings(runtime, route: c["route"].string, model: c["model"].string), env = settings["env"]
            guard let base = URL(string: env["ANTHROPIC_BASE_URL"].string) else { throw NativeFailure("Invalid provider route URL") }
            var request = URLRequest(url: base.appendingPathComponent("v1/messages")); request.httpMethod = "POST"; request.timeoutInterval = 45; request.setValue("application/json", forHTTPHeaderField: "Content-Type"); request.setValue(env["ANTHROPIC_API_KEY"].string, forHTTPHeaderField: "x-api-key"); request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version"); request.httpBody = try JSONValue.object(["model": c["model"], "max_tokens": 8, "messages": [["role": "user", "content": "Reply OK"]]]).encoded()
            let began = Date(); var result: JSONValue = ["route": c["route"], "model": c["model"], "key": .string(ArenaRanking.key(c))]
            do { let (data, response) = try await URLSession.shared.data(for: request), body = (try? JSONValue.decode(data)) ?? .null, text = body["content"].array.map { $0["text"].string }.joined(); let ok = (response as? HTTPURLResponse)?.statusCode == 200 && !text.isEmpty; result["ok"] = .bool(ok); result["message"] = ok ? "Responded" : body["error"]["message"].isNull ? "Empty response or refused route" : body["error"]["message"] }
            catch { result["ok"] = false; result["message"] = .string(error.localizedDescription) }
            result["ms"] = .number(Date().timeIntervalSince(began) * 1000); output.append(result)
        }
        return ["results": .array(output)]
    }
}
private final class ArenaServicePool: @unchecked Sendable {
    private final class Entry { weak var service: NativeArenaService?; init(_ service: NativeArenaService) { self.service = service } }
    private let lock = NSLock(); private var values: [ObjectIdentifier: Entry] = [:]
    func get(_ runtime: NativeRuntime) -> NativeArenaService { lock.lock(); defer { lock.unlock() }; values = values.filter { $0.value.service != nil }; let key = ObjectIdentifier(runtime); if let value = values[key]?.service { return value }; let value = NativeArenaService(runtime: runtime); values[key] = Entry(value); return value }
}
