import Foundation
import CryptoKit
import CSQLite
import Darwin

struct StatisticsReadResult: Sendable { var records: [StatisticsUsage] = []; var excluded = 0 }

/// Source stores belong to other applications. SQLite only sees the coherent
/// private DB/WAL copy, so its shared-memory bookkeeping cannot touch a source.
final class StatisticsSourceDatabase {
    private var db: OpaquePointer?
    private let snapshot: SQLiteSnapshotCore
    init(_ url: URL) throws {
        snapshot = try SQLiteSnapshotCore(url)
        guard sqlite3_open_v2(snapshot.database.path, &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK else {
            let message = db.map { String(cString: sqlite3_errmsg($0)) } ?? "Source database unavailable"
            sqlite3_close(db); db = nil; throw NativeFailure(message)
        }
        sqlite3_busy_timeout(db, 5000)
        guard sqlite3_exec(db, "BEGIN", nil, nil, nil) == SQLITE_OK else { throw NativeFailure("Cannot begin source snapshot") }
    }
    deinit { sqlite3_close(db) }
    func rows(_ sql: String) throws -> [JSONObject] {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let s = statement else { throw NativeFailure(String(cString: sqlite3_errmsg(db))) }
        defer { sqlite3_finalize(s) }
        var rows: [JSONObject] = []
        while true {
            let state = sqlite3_step(s); if state == SQLITE_DONE { break }
            guard state == SQLITE_ROW else { throw NativeFailure(String(cString: sqlite3_errmsg(db))) }
            var row: JSONObject = [:]
            for i in 0..<sqlite3_column_count(s) {
                let name = String(cString: sqlite3_column_name(s, i))
                switch sqlite3_column_type(s, i) {
                case SQLITE_INTEGER, SQLITE_FLOAT: row[name] = .number(sqlite3_column_double(s, i))
                case SQLITE_TEXT: row[name] = .string(String(cString: sqlite3_column_text(s, i)))
                case SQLITE_BLOB: row[name] = sqlite3_column_blob(s, i).map { .string(Data(bytes: $0, count: Int(sqlite3_column_bytes(s, i))).base64EncodedString()) } ?? .null
                default: row[name] = .null
                }
            }
            rows.append(row)
        }
        return rows
    }
    func tables() throws -> Set<String> { Set(try rows("SELECT name FROM sqlite_master WHERE type='table'").compactMap { $0["name"]?.string }) }
}

enum StatisticsImporter {
    static func read(_ url: URL, source: String) throws -> StatisticsReadResult {
        switch source {
        case "claude": let reader = StatisticsClaudeReader(); try lines(url, usageOnly: true) { reader.push($0) }; return reader.finish()
        case "codex": let reader = StatisticsCodexReader(); try lines(url, usageOnly: true) { reader.push($0) }; return reader.finish()
        case "dsh": let reader = StatisticsDeepSeekReader(); try lines(url, strictJSON: true) { try reader.push($0) }; return try reader.finish()
        case "zcode": return try zcode(url)
        case "opencode": return try opencode(url)
        case "antigravity": return try antigravity(url)
        default: throw NativeFailure("Unknown Statistics source")
        }
    }
    static func lines(_ url: URL, usageOnly: Bool = false, strictJSON: Bool = false, body: (JSONValue) throws -> Void) throws {
        let fd = open(url.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else { throw NativeFailure("Usage ledger is unavailable or linked") }
        defer { close(fd) }
        try lines(descriptor: fd, usageOnly: usageOnly, compressed: url.lastPathComponent.hasSuffix(".jsonl.zst") || url.lastPathComponent.hasSuffix(".jsonl.zstd"), strictJSON: strictJSON, body: body)
    }
    static func lines(descriptor: Int32, usageOnly: Bool = false, maximumRowBytes: Int? = nil, compressed: Bool = false, strictJSON: Bool = false, body: (JSONValue) throws -> Void) throws {
        var info = stat()
        guard fstat(descriptor, &info) == 0, info.st_mode & S_IFMT == S_IFREG else { throw NativeFailure("Usage ledger must be a regular file") }
        let compressedReader = compressed ? try StatisticsZstdReader(descriptor: descriptor) : nil
        let decoder = JSONDecoder()
        func decode(_ data: Data) -> JSONValue? { usageOnly ? (try? decoder.decode(StatisticsEnvelope.self, from: data).value) : (try? JSONValue.decode(data)) }
        var tail = Data(), buffer = [UInt8](repeating: 0, count: 1 << 20)
        while true {
            try Task.checkCancellation()
            let count = try compressedReader?.read(into: &buffer) ?? Darwin.read(descriptor, &buffer, buffer.count)
            if count == 0 { break }; if count < 0 && errno == EINTR { continue }
            guard count > 0 else { throw NativeFailure("Usage ledger read failed") }
            tail.append(contentsOf: buffer.prefix(count))
            // Data.firstIndex visits every byte through collection subscripts.
            // Transcript bodies dominate corpus size even though only metadata
            // is decoded; libc scans them in bulk without building those bodies.
            let newlines = tail.withUnsafeBytes { (bytes: UnsafeRawBufferPointer) -> [Int] in
                guard let base = bytes.baseAddress else { return [] }
                var cursor = 0, offsets: [Int] = []
                while cursor < bytes.count,
                      let end = memchr(base.advanced(by: cursor), 10, bytes.count - cursor) {
                    let index = base.distance(to: end)
                    offsets.append(index); cursor = index + 1
                }
                return offsets
            }
            var offset = tail.startIndex
            for distance in newlines {
                let end = tail.index(tail.startIndex, offsetBy: distance)
                if let maximumRowBytes, end - offset > maximumRowBytes { throw NativeFailure("Usage ledger contains an oversized row") }
                if let o = decode(Data(tail[offset..<end])) { try body(o) }
                else if strictJSON { throw NativeFailure("Usage ledger contains malformed JSON") }
                offset = tail.index(after: end)
            }
            if offset != tail.startIndex { tail.removeSubrange(tail.startIndex..<offset) }
            if let maximumRowBytes, tail.count > maximumRowBytes { throw NativeFailure("Usage ledger contains an oversized row") }
        }
        if !tail.isEmpty {
            if let o = decode(tail) { try body(o) }
            else if strictJSON { throw NativeFailure("Usage ledger has an incomplete final row") }
        }
    }
    static func zcode(_ url: URL) throws -> StatisticsReadResult {
        let db = try StatisticsSourceDatabase(url); let tables = try db.tables()
        guard tables.contains("model_usage") else { return StatisticsReadResult() }
        var sessions: [String: String] = [:]
        if tables.contains("session") { for r in try db.rows("SELECT id,directory FROM session") { sessions[r["id"]?.string ?? ""] = r["directory"]?.string } }
        let columns = Set(try db.rows("PRAGMA table_info(model_usage)").compactMap { $0["name"]?.string })
        let duration = columns.contains("duration_ms") ? "duration_ms" : "NULL AS duration_ms"
        let completed = columns.contains("completed_at") ? "completed_at" : "NULL AS completed_at"
        let rows = try db.rows("SELECT id,session_id,query_source,model_id,variant,agent,status,started_at,\(duration),\(completed),input_tokens,output_tokens,reasoning_tokens,cache_creation_input_tokens,cache_read_input_tokens FROM model_usage ORDER BY started_at")
        var result = StatisticsReadResult()
        for row in rows {
            let r = JSONValue.object(row), ts = statisticsNumber(r["started_at"], coerce: true)
            guard r["status"].string == "completed", statisticsValidDate(ts) else { result.excluded += 1; continue }
            let input = statisticsTokens(r["input_tokens"]), output = statisticsTokens(r["output_tokens"])
            let read = min(input, statisticsTokens(r["cache_read_input_tokens"])), write = min(input - read, statisticsTokens(r["cache_creation_input_tokens"]))
            guard input + output > 0 else { result.excluded += 1; continue }
            let session = r["session_id"].string
            var e = StatisticsUsage(id: "zcode:\(r["id"].string)", source: "zcode", ts: ts, model: r["model_id"].string.isEmpty ? "unknown" : r["model_id"].string)
            e.session = "zcode:\(session.isEmpty ? "unknown" : session)"; e.project = sessions[session].flatMap { $0.isEmpty ? nil : $0 } ?? "unknown"
            e.sidechain = r["query_source"].string == "subagent" || r["agent"].string == "zcode-general-purpose"; e.effort = r["variant"].string
            e.input = input - read - write; e.output = output; e.cacheRead = read; e.cacheWrite = write; e.thinking = min(output, statisticsTokens(r["reasoning_tokens"]))
            let dt = statisticsNumber(r["duration_ms"])
            e.durationMs = dt > 0 ? dt : statisticsDuration(ts, statisticsNumber(r["completed_at"]))
            e.timing = "recorded"; result.records.append(e)
        }
        return result
    }
    static func opencode(_ url: URL) throws -> StatisticsReadResult {
        let db = try StatisticsSourceDatabase(url), tables = try db.tables()
        guard tables.contains("message") else { return StatisticsReadResult() }
        var untimed = Set<String>(), sessions: [String: JSONObject] = [:]
        if tables.contains("part") {
            let rows = try db.rows("SELECT DISTINCT message_id FROM part WHERE CASE WHEN json_valid(data) THEN json_type(data) IS NOT 'object' OR json_type(data,'$.type') IS NOT 'text' OR json_extract(data,'$.type') IN ('','tool') ELSE 1 END")
            for row in rows { untimed.insert(row["message_id"]?.string ?? "") }
        }
        if tables.contains("session") { for s in try db.rows("SELECT id,directory,parent_id FROM session") { sessions[s["id"]?.string ?? ""] = s } }
        var result = StatisticsReadResult()
        for row in try db.rows("SELECT id,session_id,time_created,data FROM message ORDER BY time_created") {
            guard let d = try? JSONValue.decode(Data((row["data"]?.string ?? "").utf8)), case .object = d else { result.excluded += 1; continue }
            guard d["role"].string == "assistant" else { continue }
            let created = statisticsNumber(d["time"]["created"], coerce: true)
            let ts = created > 0 ? created : statisticsNumber(row["time_created"] ?? .null, coerce: true)
            guard statisticsValidDate(ts) else { result.excluded += 1; continue }
            let tokens = d["tokens"], reasoning = statisticsTokens(tokens["reasoning"])
            var e = StatisticsUsage(id: "opencode:\(row["id"]?.string ?? "")", source: "opencode", ts: ts, model: d["modelID"].string.isEmpty ? "unknown" : d["modelID"].string)
            e.input = statisticsTokens(tokens["input"]); e.output = statisticsTokens(tokens["output"]) + reasoning; e.thinking = reasoning
            e.cacheRead = statisticsTokens(tokens["cache"]["read"]); e.cacheWrite = statisticsTokens(tokens["cache"]["write"])
            guard e.grand > 0 else { result.excluded += 1; continue }
            let sid = row["session_id"]?.string ?? "", session = JSONValue.object(sessions[sid] ?? [:])
            e.session = "opencode:\(sid.isEmpty ? "unknown" : sid)"; e.project = session["directory"].string.isEmpty ? "unknown" : session["directory"].string
            e.sidechain = !session["parent_id"].isNull; e.effort = d["variant"].string; e.timing = "recorded"
            if !untimed.contains(row["id"]?.string ?? "") && d["finish"].string != "tool-calls" { e.durationMs = statisticsDuration(created, statisticsNumber(d["time"]["completed"])) }
            result.records.append(e)
        }
        return result
    }
}

final class StatisticsClaudeReader {
    private var nodes: [String: Double] = [:], records: [StatisticsUsage] = []
    private var response: [String: (start: Double?, end: Double)] = [:]
    func push(_ o: JSONValue) {
        guard let ts = statisticsTimestamp(o["timestamp"]) else { return }
        let start = o["type"].string == "user" ? ts : nodes[o["parentUuid"].string]
        if !o["uuid"].string.isEmpty { nodes[o["uuid"].string] = start }
        let m = o["message"], u = m["usage"]
        guard o["type"].string == "assistant", !m["id"].string.isEmpty, case .object = u,
              !m["model"].string.isEmpty, m["model"].string != "<synthetic>" else { return }
        var e = StatisticsUsage(id: m["id"].string, source: "claude", ts: ts, model: m["model"].string)
        e.project = o["cwd"].string.isEmpty ? "unknown" : o["cwd"].string; e.session = o["sessionId"].string
        e.sidechain = o["isSidechain"].bool; e.effort = o["effort"].string
        e.input = statisticsNumber(u["input_tokens"]); e.output = statisticsNumber(u["output_tokens"])
        e.thinking = statisticsNumber(u["output_tokens_details"]["thinking_tokens"])
        e.cacheWrite = statisticsNumber(u["cache_creation_input_tokens"]); e.cacheRead = statisticsNumber(u["cache_read_input_tokens"])
        e.webSearch = statisticsNumber(u["server_tool_use"]["web_search_requests"]); e.webFetch = statisticsNumber(u["server_tool_use"]["web_fetch_requests"])
        e.rawDay = String(o["timestamp"].string.prefix(10)); records.append(e)
        if let old = response[e.id] { response[e.id] = (old.start, max(ts, old.end)) } else { response[e.id] = (start, ts) }
    }
    func finish() -> StatisticsReadResult {
        for i in records.indices { if let r = response[records[i].id], let dt = statisticsDuration(r.start, r.end) { records[i].durationMs = dt; records[i].timing = "estimated" } }
        return StatisticsReadResult(records: records)
    }
}

final class StatisticsCodexReader {
    private var meta: JSONValue = [:], context: JSONValue = [:], contexts: [String: JSONValue] = [:]
    private var modernTurns = Set<String>(), modern: [StatisticsUsage] = [], fallback: [(String, StatisticsUsage)] = [], exclusions: [String] = []
    private var previous: Double = 0, starts: [String: Double] = [:], tools = Set<String>()
    func push(_ o: JSONValue) {
        let p = o["payload"], type = o["type"].string
        // Most transcript frames only update context or are unrelated output.
        // Parse clocks only at the usage and timing boundaries that consume it.
        let at = { statisticsTimestamp(o["timestamp"]) }
        if type == "session_meta" { meta = p; return }
        if type == "turn_context" { context = p; if !p["turn_id"].string.isEmpty { contexts[p["turn_id"].string] = p }; return }
        let turn = p["turn_id"].string.isEmpty ? context["turn_id"].string : p["turn_id"].string
        if type == "event_msg" && p["type"].string == "task_started" { tools.removeAll(); starts[turn] = at(); return }
        if type == "event_msg" && ["task_complete", "task_aborted"].contains(p["type"].string) { starts[turn] = nil; tools.removeAll(); return }
        if type == "response_item" {
            if ["function_call", "custom_tool_call"].contains(p["type"].string) { tools.insert(p["call_id"].string) }
            if ["function_call_output", "custom_tool_call_output"].contains(p["type"].string) { tools.remove(p["call_id"].string); if tools.isEmpty { starts[turn] = at() } }
            else if p["type"].string == "message" && p["role"].string == "user" { starts[turn] = at() }
            return
        }
        let isModern = type == "token_usage_record"
        guard isModern || (type == "event_msg" && p["type"].string == "token_count"), let ts = at() else { return }
        var usage: JSONValue, id: String
        if isModern {
            id = p["response_id"].string; guard !id.isEmpty else { return }; usage = p["usage"]; modernTurns.insert(turn)
        } else {
            let total = p["info"]["total_token_usage"]
            let count = max(0, statisticsNumber(total["total_tokens"]))
            let cumulative = count > 0 ? count : max(0, statisticsNumber(total["input_tokens"])) + max(0, statisticsNumber(total["output_tokens"]))
            let changed = cumulative != previous; previous = cumulative
            guard changed, cumulative > 0, !modernTurns.contains(turn) else { return }
            usage = p["info"]["last_token_usage"]
            let key: JSONValue = [o["timestamp"], total, .string(turn)]
            id = SHA256.hash(data: (try? key.encoded()) ?? Data()).map { String(format: "%02x", $0) }.joined()
        }
        let input = max(0, statisticsNumber(usage["input_tokens"])), output = max(0, statisticsNumber(usage["output_tokens"]))
        guard input + output > 0 else { exclusions.append(turn); return }
        let read = min(input, max(0, statisticsNumber(usage["cached_input_tokens"]))), write = min(input - read, max(0, statisticsNumber(usage["cache_write_input_tokens"])))
        let ctx = contexts[turn] ?? context
        var e = StatisticsUsage(id: "codex:\(id)", source: "codex", ts: ts, model: ctx["model"].string.isEmpty ? "unknown" : ctx["model"].string)
        e.project = !ctx["cwd"].string.isEmpty ? ctx["cwd"].string : meta["cwd"].string.isEmpty ? "unknown" : meta["cwd"].string
        let sid = [p["thread_id"].string, meta["id"].string, meta["session_id"].string].first { !$0.isEmpty } ?? ""
        let subagent = meta["source"]["subagent"]
        let hasSubagent: Bool
        switch subagent { case .object, .array: hasSubagent = true; default: hasSubagent = subagent.bool || !subagent.string.isEmpty }
        e.session = "codex:\(sid)"; e.sidechain = hasSubagent || !meta["parent_thread_id"].string.isEmpty; e.effort = ctx["effort"].string
        e.input = input - read - write; e.output = output; e.cacheRead = read; e.cacheWrite = write; e.thinking = min(output, max(0, statisticsNumber(usage["reasoning_output_tokens"])))
        e.durationMs = statisticsDuration(starts[turn], ts); e.timing = "estimated"; starts[turn] = nil
        if isModern { modern.append(e) } else { fallback.append((turn, e)) }
    }
    func finish() -> StatisticsReadResult { StatisticsReadResult(records: modern + fallback.filter { !modernTurns.contains($0.0) }.map(\.1), excluded: exclusions.filter { !modernTurns.contains($0) }.count) }
}
