import Foundation

final class CodeStore {
    let runtime: NativeRuntime
    init(runtime: NativeRuntime) throws {
        self.runtime = runtime
        try runtime.db.migrate("code-1", sql: """
        CREATE TABLE IF NOT EXISTS code_projects(id TEXT PRIMARY KEY,path TEXT NOT NULL UNIQUE,name TEXT NOT NULL,created_at INTEGER NOT NULL,last_used INTEGER NOT NULL);
        CREATE TABLE IF NOT EXISTS code_threads(id TEXT PRIMARY KEY,project_id TEXT NOT NULL REFERENCES code_projects(id) ON DELETE CASCADE,title TEXT NOT NULL,route_id TEXT NOT NULL,model TEXT NOT NULL,effort TEXT,permission_mode TEXT NOT NULL,claude_session_id TEXT,status TEXT NOT NULL,created_at INTEGER NOT NULL,updated_at INTEGER NOT NULL,cost_usd REAL NOT NULL DEFAULT 0,turns INTEGER NOT NULL DEFAULT 0,last_error TEXT,input_tokens INTEGER NOT NULL DEFAULT 0,output_tokens INTEGER NOT NULL DEFAULT 0);
        CREATE INDEX IF NOT EXISTS code_threads_project ON code_threads(project_id,updated_at);
        CREATE TABLE IF NOT EXISTS code_events(id INTEGER PRIMARY KEY AUTOINCREMENT,thread_id TEXT NOT NULL REFERENCES code_threads(id) ON DELETE CASCADE,seq INTEGER NOT NULL,type TEXT NOT NULL,payload TEXT NOT NULL,uuid TEXT,ts INTEGER NOT NULL);
        CREATE INDEX IF NOT EXISTS code_events_thread ON code_events(thread_id,seq);
        CREATE UNIQUE INDEX IF NOT EXISTS code_events_uuid ON code_events(thread_id,uuid) WHERE uuid IS NOT NULL;
        """)
    }
    static func now() -> JSONValue { .number(Date().timeIntervalSince1970 * 1000) }
    static func id(_ prefix: String) -> JSONValue { .string(prefix + "_" + UUID().uuidString.lowercased()) }
    func projects() throws -> [JSONObject] { try runtime.db.query("SELECT * FROM code_projects ORDER BY last_used DESC") }
    func project(_ id: JSONValue) throws -> JSONObject? { try runtime.db.query("SELECT * FROM code_projects WHERE id=?", [id]).first }
    func addProject(_ input: String) throws -> JSONObject {
        try runtime.paths.assertWritable()
        let expanded = input.hasPrefix("~") ? runtime.paths.home.path + input.dropFirst() : input
        let url = URL(fileURLWithPath: expanded).standardizedFileURL
        let info = try url.resourceValues(forKeys: [.isDirectoryKey]); guard info.isDirectory == true else { throw NativeFailure("Choose a project directory") }
        if let existing = try runtime.db.query("SELECT * FROM code_projects WHERE path=?", [.string(url.path)]).first {
            try runtime.db.execute("UPDATE code_projects SET last_used=? WHERE id=?", [Self.now(), existing["id"]!]); return existing
        }
        let id = Self.id("proj"), now = Self.now()
        try runtime.db.execute("INSERT INTO code_projects(id,path,name,created_at,last_used) VALUES(?,?,?,?,?)", [id, .string(url.path), .string(url.lastPathComponent), now, now])
        return try project(id)!
    }
    func threads(project: JSONValue? = nil) throws -> [JSONObject] { try runtime.db.query(project == nil ? "SELECT * FROM code_threads ORDER BY updated_at DESC" : "SELECT * FROM code_threads WHERE project_id=? ORDER BY updated_at DESC", project.map { [$0] } ?? []) }
    func thread(_ id: JSONValue) throws -> JSONObject? { try runtime.db.query("SELECT * FROM code_threads WHERE id=?", [id]).first }
    func create(_ input: JSONObject) throws -> JSONObject {
        let id = Self.id("th"), now = Self.now()
        try runtime.db.transaction {
            try runtime.db.execute("INSERT INTO code_threads(id,project_id,title,route_id,model,effort,permission_mode,status,created_at,updated_at) VALUES(?,?,?,?,?,?,?,'idle',?,?)", [id, input["project_id"]!, input["title"] ?? "New thread", input["route_id"] ?? "subscription", input["model"] ?? "", input["effort"] ?? .null, input["permission_mode"] ?? "acceptEdits", now, now])
            try runtime.db.execute("UPDATE code_projects SET last_used=? WHERE id=?", [now, input["project_id"]!])
        }
        return try thread(id)!
    }
    func patch(_ id: JSONValue, _ input: JSONObject) throws -> JSONObject {
        let allowed = Set(["title", "route_id", "model", "effort", "permission_mode", "claude_session_id", "status", "cost_usd", "turns", "last_error", "input_tokens", "output_tokens"])
        let keys = input.keys.filter { allowed.contains($0) }.sorted()
        if !keys.isEmpty { try runtime.db.execute("UPDATE code_threads SET " + keys.map { $0 + "=?" }.joined(separator: ",") + ",updated_at=? WHERE id=?", keys.map { input[$0]! } + [Self.now(), id]) }
        guard let thread = try thread(id) else { throw NativeFailure("Thread no longer exists") }; return thread
    }
    // Disable the inner transaction only when a caller already owns a database
    // transaction, such as the restart status/notice reconciliation.
    func event(_ id: JSONValue, type: String, payload: JSONValue, uuid: JSONValue = .null, transactional: Bool = true) throws -> JSONValue? {
        let write: () throws -> JSONValue? = { [self] in
            if !uuid.isNull, !(try runtime.db.query("SELECT id FROM code_events WHERE thread_id=? AND uuid=?", [id, uuid])).isEmpty { return nil }
            let sequence = (try runtime.db.query("SELECT MAX(seq) AS n FROM code_events WHERE thread_id=?", [id]).first?["n"]?.int ?? 0) + 1
            let now = Self.now(), content = String(decoding: try payload.encoded(), as: UTF8.self)
            try runtime.db.execute("INSERT INTO code_events(thread_id,seq,type,payload,uuid,ts) VALUES(?,?,?,?,?,?)", [id, .number(Double(sequence)), .string(type), .string(content), uuid, now])
            let eventID = try runtime.db.query("SELECT last_insert_rowid() AS id").first?["id"] ?? .null
            try runtime.db.execute("UPDATE code_threads SET updated_at=? WHERE id=?", [now, id])
            return ["id": eventID, "thread_id": id, "seq": .number(Double(sequence)), "type": .string(type), "payload": payload, "uuid": uuid, "ts": now]
        }
        if transactional { return try runtime.db.transaction(write) }; return try write()
    }
    func events(_ id: JSONValue, after: Int = 0) throws -> [JSONValue] { try runtime.db.query("SELECT * FROM code_events WHERE thread_id=? AND seq>? ORDER BY seq LIMIT 5000", [id, .number(Double(max(0, after)))]).map { row in var r = JSONValue.object(row); r["payload"] = (try? JSONValue.decode(Data(r["payload"].string.utf8))) ?? .null; return r } }
    func removeThread(_ id: JSONValue) throws { try runtime.db.execute("DELETE FROM code_threads WHERE id=?", [id]) }
    func removeProject(_ id: JSONValue) throws { try runtime.db.execute("DELETE FROM code_projects WHERE id=?", [id]) }
}
