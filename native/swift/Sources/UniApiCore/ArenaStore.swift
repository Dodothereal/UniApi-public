import Foundation

final class ArenaStore {
    let runtime: NativeRuntime
    var directory: URL { runtime.paths.data.appendingPathComponent("arena/matches") }
    init(runtime: NativeRuntime) throws {
        self.runtime = runtime
        try runtime.db.migrate("arena-2", sql: """
        CREATE TABLE IF NOT EXISTS arena_matches(id TEXT PRIMARY KEY,mode TEXT NOT NULL,prompt TEXT NOT NULL,preset_id TEXT,category TEXT,status TEXT NOT NULL,error TEXT,ranking TEXT,verdict TEXT,notify INTEGER NOT NULL DEFAULT 0,timeout_s INTEGER NOT NULL,max_turns INTEGER NOT NULL,job_id TEXT,created_at INTEGER NOT NULL,started_at INTEGER,finished_at INTEGER,voted_at INTEGER);
        CREATE INDEX IF NOT EXISTS arena_matches_status ON arena_matches(status,voted_at,created_at);
        CREATE TABLE IF NOT EXISTS arena_slots(id TEXT PRIMARY KEY,match_id TEXT NOT NULL REFERENCES arena_matches(id) ON DELETE CASCADE,idx INTEGER NOT NULL,route TEXT NOT NULL,model TEXT NOT NULL,status TEXT NOT NULL,workdir TEXT NOT NULL,session_id TEXT,error TEXT,final_text TEXT NOT NULL DEFAULT '',presents TEXT NOT NULL DEFAULT '[]',duration_ms INTEGER,turns INTEGER NOT NULL DEFAULT 0,input_tokens INTEGER NOT NULL DEFAULT 0,output_tokens INTEGER NOT NULL DEFAULT 0,cost_usd REAL NOT NULL DEFAULT 0,tool_calls INTEGER NOT NULL DEFAULT 0,blocked INTEGER NOT NULL DEFAULT 0,started_at INTEGER,finished_at INTEGER);
        CREATE INDEX IF NOT EXISTS arena_slots_match ON arena_slots(match_id,idx);
        CREATE TABLE IF NOT EXISTS arena_slot_events(id INTEGER PRIMARY KEY AUTOINCREMENT,slot_id TEXT NOT NULL REFERENCES arena_slots(id) ON DELETE CASCADE,seq INTEGER NOT NULL,type TEXT NOT NULL,payload TEXT NOT NULL,ts INTEGER NOT NULL);
        CREATE INDEX IF NOT EXISTS arena_slot_events_slot ON arena_slot_events(slot_id,seq);
        CREATE TABLE IF NOT EXISTS arena_prompts(id TEXT PRIMARY KEY,title TEXT NOT NULL,category TEXT NOT NULL,prompt TEXT NOT NULL,builtin INTEGER NOT NULL,created_at INTEGER NOT NULL,updated_at INTEGER NOT NULL);
        CREATE TABLE IF NOT EXISTS arena_kv(key TEXT PRIMARY KEY,value TEXT NOT NULL);
        """)
        if !runtime.paths.readOnly {
            try migratePresets(); try seed()
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
    }
    private func migratePresets() throws {
        let tables = Set(try runtime.db.query("SELECT name FROM sqlite_master WHERE type='table'").compactMap { $0["name"]?.string })
        if tables.contains("arena_presets") {
            try runtime.db.transaction {
                try runtime.db.executeScript("INSERT OR IGNORE INTO arena_prompts(id,title,category,prompt,builtin,created_at,updated_at) SELECT id,title,category,prompt,0,created_at,created_at FROM arena_presets WHERE builtin=0; DROP TABLE arena_presets;")
            }
        }
        // Old raw-completion battles remain historical data; the native service
        // does not include them in sandboxed-match rankings or delete their tables.
    }
    func get(_ key: String, fallback: JSONValue = .null) throws -> JSONValue { guard let raw = try runtime.db.query("SELECT value FROM arena_kv WHERE key=?", [.string(key)]).first?["value"] else { return fallback }; return (try? JSONValue.decode(Data(raw.string.utf8))) ?? fallback }
    func set(_ key: String, _ value: JSONValue) throws { try runtime.db.execute("INSERT INTO arena_kv(key,value) VALUES(?,?) ON CONFLICT(key) DO UPDATE SET value=excluded.value", [.string(key), .string(String(decoding: try value.encoded(), as: UTF8.self))]) }
    func voter() throws -> JSONValue { let existing = try get("voter", fallback: ""); if !existing.string.isEmpty { return existing }; guard !runtime.paths.readOnly else { return .null }; let value = JSONValue.string(String(UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(10)).lowercased()); try set("voter", value); return value }
    private func seed() throws {
        var seeded = Set(try get("seededPresets", fallback: []).array.map(\.string))
        for preset in ArenaPresets.values where !seeded.contains(preset["id"].string) {
            try runtime.db.execute("INSERT OR IGNORE INTO arena_prompts(id,title,category,prompt,builtin,created_at,updated_at) VALUES(?,?,?,?,1,?,?)", [preset["id"], preset["title"], preset["category"], preset["prompt"], CodeStore.now(), CodeStore.now()]); seeded.insert(preset["id"].string)
        }
        try set("seededPresets", .array(seeded.sorted().map(JSONValue.string)))
    }
    func presets() throws -> [JSONValue] { try runtime.db.query("SELECT * FROM arena_prompts ORDER BY category,title").map { row in var r = JSONValue.object(row); r["builtin"] = .bool(r["builtin"].int != 0); return r } }
    func preset(_ id: JSONValue) throws -> JSONValue? { try presets().first { $0["id"] == id } }
    func savePreset(_ input: JSONValue, id: JSONValue? = nil) throws -> JSONValue {
        let title = input["title"].string.trimmingCharacters(in: .whitespacesAndNewlines), prompt = input["prompt"].string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty, !prompt.isEmpty, title.count <= 200, prompt.count <= 100000 else { throw NativeFailure("A preset needs a title and bounded prompt") }
        let category = input["category"].string.isEmpty ? "custom" : input["category"].string, key = id ?? CodeStore.id("preset")
        if id != nil {
            guard try preset(key) != nil else { throw NativeFailure("Preset no longer exists") }
            try runtime.db.execute("UPDATE arena_prompts SET title=?,category=?,prompt=?,updated_at=? WHERE id=?", [.string(title), .string(category), .string(prompt), CodeStore.now(), key])
        } else { try runtime.db.execute("INSERT INTO arena_prompts(id,title,category,prompt,builtin,created_at,updated_at) VALUES(?,?,?,?,0,?,?)", [key, .string(title), .string(category), .string(prompt), CodeStore.now(), CodeStore.now()]) }
        return try preset(key)!
    }
    func removePreset(_ id: JSONValue) throws { try runtime.db.execute("DELETE FROM arena_prompts WHERE id=?", [id]) }
    func create(_ input: JSONValue, contestants: [JSONValue]) throws -> JSONValue {
        let id = CodeStore.id("match")
        try runtime.db.transaction {
            try runtime.db.execute("INSERT INTO arena_matches(id,mode,prompt,preset_id,category,status,notify,timeout_s,max_turns,created_at) VALUES(?,?,?,?,?,'queued',?,?,?,?)", [id, input["mode"], input["prompt"], input["preset_id"], input["category"], .number(input["notify"].bool ? 1 : 0), input["timeout_s"], input["max_turns"], CodeStore.now()])
            for (index, c) in contestants.enumerated() {
                try runtime.db.execute("INSERT INTO arena_slots(id,match_id,idx,route,model,status,workdir) VALUES(?,?,?,?,?,'queued',?)", [CodeStore.id("slot"), id, .number(Double(index)), c["route"], c["model"], .string(directory.appendingPathComponent(id.string).appendingPathComponent("slot-\(index)").path)])
            }
        }
        return try match(id)!
    }
    func rawMatch(_ id: JSONValue) throws -> JSONValue? { try runtime.db.query("SELECT * FROM arena_matches WHERE id=?", [id]).first.map(JSONValue.object) }
    func slots(_ match: JSONValue) throws -> [JSONValue] { try runtime.db.query("SELECT * FROM arena_slots WHERE match_id=? ORDER BY idx", [match]).map(JSONValue.object) }
    func rawSlot(_ id: JSONValue) throws -> JSONValue? { try runtime.db.query("SELECT * FROM arena_slots WHERE id=?", [id]).first.map(JSONValue.object) }
    func match(_ id: JSONValue) throws -> JSONValue? {
        guard var m = try rawMatch(id) else { return nil }
        let revealed = !m["voted_at"].isNull || ["failed", "cancelled"].contains(m["status"].string)
        m["ranking"] = m["ranking"].isNull ? .null : (try? JSONValue.decode(Data(m["ranking"].string.utf8))) ?? .null; m["notify"] = .bool(m["notify"].int != 0); m["revealed"] = .bool(revealed)
        m["slots"] = .array(try slots(id).map { publicSlot($0, revealed: revealed) }); return m
    }
    func publicSlot(_ slot: JSONValue, revealed: Bool) -> JSONValue {
        var s = JSONValue.object(slot.object.filter { $0.key != "workdir" })
        s["presents"] = (try? JSONValue.decode(Data(slot["presents"].string.utf8))) ?? []; s["revealed"] = .bool(revealed)
        s["label"] = .string("Contestant " + String(UnicodeScalar(65 + max(0, min(7, slot["idx"].int)))!))
        if !revealed { s["route"] = ""; s["model"] = "" }; return s
    }
    func matches(view: String, limit: Int) throws -> [JSONValue] { try runtime.db.query("SELECT id FROM arena_matches " + (view == "all" ? "" : "WHERE voted_at IS NULL AND status IN ('queued','running','done') ") + "ORDER BY created_at DESC LIMIT ?", [.number(Double(max(1, min(500, limit))))]).compactMap { try match($0["id"]!) } }
    func patchMatch(_ id: JSONValue, _ fields: JSONObject) throws { try patch("arena_matches", id, fields, allowed: ["status", "error", "ranking", "verdict", "job_id", "started_at", "finished_at", "voted_at", "preset_id", "category"]) }
    func patchSlot(_ id: JSONValue, _ fields: JSONObject) throws { try patch("arena_slots", id, fields, allowed: ["status", "session_id", "error", "final_text", "presents", "duration_ms", "turns", "input_tokens", "output_tokens", "cost_usd", "tool_calls", "blocked", "started_at", "finished_at"]) }
    private func patch(_ table: String, _ id: JSONValue, _ fields: JSONObject, allowed: Set<String>) throws { let keys = fields.keys.filter { allowed.contains($0) }.sorted(); guard !keys.isEmpty else { return }; try runtime.db.execute("UPDATE \(table) SET " + keys.map { $0 + "=?" }.joined(separator: ",") + " WHERE id=?", keys.map { fields[$0]! } + [id]) }
    func addEvent(_ slot: JSONValue, type: String, payload: JSONValue) throws -> JSONValue {
        try runtime.db.transaction {
            let seq = (try runtime.db.query("SELECT MAX(seq) AS n FROM arena_slot_events WHERE slot_id=?", [slot]).first?["n"]?.int ?? 0) + 1, now = CodeStore.now()
            try runtime.db.execute("INSERT INTO arena_slot_events(slot_id,seq,type,payload,ts) VALUES(?,?,?,?,?)", [slot, .number(Double(seq)), .string(type), .string(String(decoding: try payload.encoded(), as: UTF8.self)), now])
            let id = try runtime.db.query("SELECT last_insert_rowid() AS id").first?["id"] ?? .null
            return ["id": id, "slot_id": slot, "seq": .number(Double(seq)), "type": .string(type), "payload": payload, "ts": now]
        }
    }
    func events(_ id: JSONValue, after: Int) throws -> [JSONValue] {
        guard let slot = try rawSlot(id), let m = try rawMatch(slot["match_id"]) else { throw NativeFailure("Slot no longer exists") }
        let revealed = !m["voted_at"].isNull || ["failed", "cancelled"].contains(m["status"].string)
        return try runtime.db.query("SELECT * FROM arena_slot_events WHERE slot_id=? AND seq>? ORDER BY seq LIMIT 5000", [id, .number(Double(max(0, after)))]).map { row in var e = JSONValue.object(row); e["payload"] = (try? JSONValue.decode(Data(e["payload"].string.utf8))) ?? .null; return revealed ? e : Self.redact(e) }
    }
    static func redact(_ event: JSONValue) -> JSONValue { var e = event; if e["type"].string == "init" { e["payload"]["model"] = .null; e["payload"]["cwd"] = .null }; if e["type"].string == "assistant" { e["payload"]["model"] = .null }; return e }
    func delete(_ id: JSONValue) throws {
        guard try rawMatch(id) != nil else { throw NativeFailure("Match no longer exists") }
        let work = try runtime.paths.containedFile(id.string, in: directory)
        try runtime.db.execute("DELETE FROM arena_matches WHERE id=?", [id]); if FileManager.default.fileExists(atPath: work.path) { try FileManager.default.removeItem(at: work) }
    }
    func stats() throws -> JSONValue {
        let rows = try runtime.db.query("SELECT status,voted_at FROM arena_matches")
        return ["total": .number(Double(rows.count)), "toJudge": .number(Double(rows.filter { $0["status"]?.string == "done" && $0["voted_at"]?.isNull == true }.count)), "running": .number(Double(rows.filter { ["queued", "running"].contains($0["status"]?.string ?? "") }.count)), "voted": .number(Double(rows.filter { $0["voted_at"]?.isNull == false }.count))]
    }
}
