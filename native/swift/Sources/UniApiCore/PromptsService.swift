import Foundation

/// Native operations mirror the existing prompt/result schema; saving a label
/// never calls the model it names. Tests use temporary roots and homes.
public actor NativePromptsService {
    private let runtime: NativeRuntime
    private var initialized = false
    private var cleanupTask: Task<Void, Never>?
    private var directory: URL { runtime.paths.data.appendingPathComponent("prompts") }
    public init(runtime: NativeRuntime) { self.runtime = runtime }
    public func start() async throws {
        try initialize()
        guard !runtime.paths.readOnly, cleanupTask == nil else { return }
        cleanupTask = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(nanoseconds: 60_000_000_000) } catch { return }
                guard let service = self else { return }
                await service.cleanup()
            }
        }
    }
    private func initialize() throws {
        guard !initialized else { return }
        let db = runtime.db
        try db.migrate("prompts-1", sql: """
        CREATE TABLE IF NOT EXISTS prompts(id TEXT PRIMARY KEY,title TEXT NOT NULL,text TEXT NOT NULL,created_at INTEGER NOT NULL,updated_at INTEGER NOT NULL);
        CREATE TABLE IF NOT EXISTS prompt_results(id TEXT PRIMARY KEY,prompt_id TEXT NOT NULL REFERENCES prompts(id) ON DELETE CASCADE,provider_id TEXT,provider_name TEXT,model TEXT NOT NULL,kind TEXT NOT NULL CHECK(kind IN ('upload','url')),url TEXT,rank INTEGER NOT NULL,created_at INTEGER NOT NULL);
        CREATE INDEX IF NOT EXISTS prompt_results_prompt_rank ON prompt_results(prompt_id,rank);
        """)
        try db.migrate("prompts-2", sql: "CREATE TABLE IF NOT EXISTS prompt_file_cleanup(id TEXT PRIMARY KEY,created_at INTEGER NOT NULL)")
        try db.migrate("prompts-3", sql: "ALTER TABLE prompt_results ADD COLUMN file_name TEXT; ALTER TABLE prompt_results ADD COLUMN file_extension TEXT NOT NULL DEFAULT '.html'; ALTER TABLE prompt_results ADD COLUMN file_size INTEGER; ALTER TABLE prompt_file_cleanup ADD COLUMN file_extension TEXT NOT NULL DEFAULT '.html';")
        if !runtime.paths.readOnly { try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700]); cleanup() }
        initialized = true
    }
    public func handle(_ operation: String, input: JSONObject = [:]) async throws -> JSONValue {
        try initialize()
        let value = JSONValue.object(input), id = value["id"].string
        if !["list", "models", "detail", "preview", "resolveFile"].contains(operation) { try runtime.paths.assertWritable() }
        switch operation {
        case "list":
            if !runtime.paths.readOnly { cleanup() }
            return ["prompts": .array(try runtime.db.query(Self.promptQuery + " ORDER BY p.updated_at DESC,p.id").map(Self.publicPrompt))]
        case "models": return try models()
        case "create":
            let title = try Self.title(value["title"]), text = try Self.text(value["text"])
            let id = "prompt-" + UUID().uuidString.lowercased(), now = Self.now
            try runtime.db.execute("INSERT INTO prompts VALUES (?,?,?,?,?)", [.string(id), .string(title), .string(text), .number(now), .number(now)])
            await changed(id); return ["prompt": try prompt(id)]
        case "detail": return ["prompt": try prompt(id), "results": .array(try results(id))]
        case "update":
            let old = try prompt(id)
            guard input["title"] != nil || input["text"] != nil else { throw NativeFailure("Nothing to update") }
            let title = try Self.title(input["title"] ?? old["title"]), text = try Self.text(input["text"] ?? old["text"])
            try runtime.db.execute("UPDATE prompts SET title=?,text=?,updated_at=? WHERE id=?", [.string(title), .string(text), .number(Self.now), .string(id)])
            await changed(id); return ["prompt": try prompt(id)]
        case "delete":
            _ = try prompt(id)
            try runtime.db.transaction {
                try enqueueCleanup(promptID: id)
                try runtime.db.execute("DELETE FROM prompts WHERE id=?", [.string(id)])
            }
            cleanup(); await changed(id); return ["ok": true, "cleanupPending": .bool(try cleanupPending())]
        case "addURL", "upload":
            _ = try prompt(id)
            let model = try Self.model(value["model"]), provider = try provider(value["providerId"])
            if operation == "addURL" { return ["result": try await addResult(promptID: id, model: model, provider: provider, url: try Self.url(value["url"]))] }
            let source = URL(fileURLWithPath: value["filePath"].string)
            guard !value["filePath"].string.isEmpty else { throw NativeFailure("Choose a result file") }
            let bytes = try NativePromptFiles.read(source)
            let name = NativePromptFiles.uploadName(source.lastPathComponent), ext = NativePromptFiles.fileExtension(name)
            let resultID = "result-" + UUID().uuidString.lowercased()
            let destination = try file(resultID, ext)
            try NativeFile.writeAtomic(bytes.data, to: destination)
            do { return ["result": try await addResult(promptID: id, model: model, provider: provider, url: nil, resultID: resultID, name: name, ext: ext, size: bytes.size)] }
            catch { try? FileManager.default.removeItem(at: destination); throw error }
        case "updateResult":
            let row = try result(value["resultId"].string, promptID: id)
            guard input["model"] != nil || input["providerId"] != nil || input["url"] != nil else { throw NativeFailure("Nothing to update") }
            let model = try Self.model(input["model"] ?? row["model"] ?? .null)
            let provider = try input["providerId"].map { try self.provider($0) } ?? (row["provider_id"] ?? .null, row["provider_name"] ?? .null)
            if row["kind"]?.string == "upload", input["url"] != nil { throw NativeFailure("File results cannot be changed into links") }
            let url = row["kind"]?.string == "url" ? JSONValue.string(try Self.url(input["url"] ?? row["url"] ?? .null)) : .null
            try runtime.db.transaction {
                try runtime.db.execute("UPDATE prompt_results SET model=?,provider_id=?,provider_name=?,url=? WHERE id=?", [.string(model), provider.0, provider.1, url, value["resultId"]])
                try touch(id)
            }
            await changed(id); return ["result": Self.publicResult(try result(value["resultId"].string, promptID: id))]
        case "deleteResult":
            let row = try result(value["resultId"].string, promptID: id)
            try runtime.db.transaction {
                if row["kind"]?.string == "upload" { try runtime.db.execute("INSERT OR IGNORE INTO prompt_file_cleanup(id,created_at,file_extension) VALUES (?,?,?)", [value["resultId"], .number(Self.now), row["file_extension"] ?? ".html"]) }
                try runtime.db.execute("DELETE FROM prompt_results WHERE id=?", [value["resultId"]])
                let remaining = try results(id)
                for (rank, result) in remaining.enumerated() { try runtime.db.execute("UPDATE prompt_results SET rank=? WHERE id=?", [.number(Double(rank + 1)), result["id"]]) }
                try touch(id)
            }
            cleanup(); await changed(id); return ["ok": true, "cleanupPending": .bool(try cleanupPending())]
        case "order":
            _ = try prompt(id)
            let current = try results(id).map { $0["id"].string }, order = value["resultIds"].array.map(\.string)
            guard order.count == current.count, Set(order) == Set(current), Set(order).count == order.count else { throw NativeFailure("Every result must appear in the order exactly once") }
            try runtime.db.transaction {
                for (rank, resultID) in order.enumerated() { try runtime.db.execute("UPDATE prompt_results SET rank=? WHERE id=? AND prompt_id=?", [.number(Double(rank + 1)), .string(resultID), .string(id)]) }
                try touch(id)
            }
            await changed(id); return ["results": .array(try results(id))]
        case "preview", "resolveFile":
            let row = try result(value["resultId"].string)
            guard row["kind"]?.string == "upload" else { throw NativeFailure("This result is a link") }
            let url = try file(row["id"]!.string, row["file_extension"]?.string ?? ".html")
            let read = try NativePromptFiles.read(url, limit: NativePromptFiles.previewBytes)
            let name = Self.resultFileName(row).string
            let type = NativePromptFiles.type(name: name, sample: read.data)
            let text: JSONValue = type.kind == "text" ? .string(String(decoding: read.data, as: UTF8.self)) : type.kind == "binary" ? .string(NativePromptFiles.hex(read.data)) : .null
            return ["kind": .string(type.kind), "mimeType": .string(type.mime), "fileName": .string(name), "path": .string(url.path), "size": .number(Double(read.size)), "text": text, "truncated": .bool(read.size > (type.kind == "binary" ? 4096 : NativePromptFiles.previewBytes))]
        default: throw NativeFailure("Unknown Prompts operation: \(operation)")
        }
    }
    private static let promptQuery = "SELECT p.*,(SELECT COUNT(*) FROM prompt_results r WHERE r.prompt_id=p.id) AS result_count FROM prompts p"
    private static var now: Double { Date().timeIntervalSince1970 * 1000 }
    private func prompt(_ id: String) throws -> JSONValue {
        guard let row = try runtime.db.query(Self.promptQuery + " WHERE p.id=?", [.string(id)]).first else { throw NativeFailure("Prompt not found") }
        return Self.publicPrompt(row)
    }
    private func result(_ id: String, promptID: String? = nil) throws -> JSONObject {
        let clauses = promptID == nil ? "id=?" : "id=? AND prompt_id=?"
        guard let row = try runtime.db.query("SELECT * FROM prompt_results WHERE " + clauses, [.string(id)] + (promptID.map { [JSONValue.string($0)] } ?? [])).first else { throw NativeFailure("Result not found") }
        return row
    }
    private func results(_ id: String) throws -> [JSONValue] { try runtime.db.query("SELECT * FROM prompt_results WHERE prompt_id=? ORDER BY rank,created_at,id", [.string(id)]).map(Self.publicResult) }
    private func touch(_ id: String) throws { try runtime.db.execute("UPDATE prompts SET updated_at=? WHERE id=?", [.number(Self.now), .string(id)]) }
    private func changed(_ id: String) async { await runtime.events.publish("prompts.changed", ["promptId": .string(id)]) }
    private func file(_ id: String, _ ext: String) throws -> URL {
        guard id.range(of: "^[a-zA-Z0-9_-]+$", options: .regularExpression) != nil, ext.range(of: "^\\.[a-zA-Z0-9_-]{1,32}$", options: .regularExpression) != nil else { throw NativeFailure("Invalid managed result path") }
        return try runtime.paths.containedFile(id + ext, in: directory)
    }
    private func enqueueCleanup(promptID: String) throws {
        for row in try runtime.db.query("SELECT id,file_extension FROM prompt_results WHERE prompt_id=? AND kind='upload'", [.string(promptID)]) {
            try runtime.db.execute("INSERT OR IGNORE INTO prompt_file_cleanup(id,created_at,file_extension) VALUES (?,?,?)", [row["id"]!, .number(Self.now), row["file_extension"]!])
        }
    }
    private func cleanup() {
        for row in (try? runtime.db.query("SELECT * FROM prompt_file_cleanup ORDER BY created_at,id")) ?? [] {
            do {
                let url = try file(row["id"]!.string, row["file_extension"]?.string ?? ".html")
                try NativePromptFiles.removeManagedFile(url)
                try runtime.db.execute("DELETE FROM prompt_file_cleanup WHERE id=?", [row["id"]!])
            } catch { /* The queue retains failures for the next pass. */ }
        }
    }
    private func cleanupPending() throws -> Bool { !(try runtime.db.query("SELECT id FROM prompt_file_cleanup LIMIT 1")).isEmpty }
    private func provider(_ value: JSONValue) throws -> (JSONValue, JSONValue) {
        if value.isNull || value.string.isEmpty { return (.null, .null) }
        guard let row = try runtime.providers.list().first(where: { $0["id"] == value }) else { throw NativeFailure("Choose a valid provider") }
        return (row["id"]!, row["name"] ?? row["id"]!)
    }
    private func addResult(promptID: String, model: String, provider: (JSONValue, JSONValue), url: String?, resultID: String = "result-" + UUID().uuidString.lowercased(), name: String? = nil, ext: String = ".html", size: Int? = nil) async throws -> JSONValue {
        try runtime.db.transaction {
            let rank = try runtime.db.query("SELECT COALESCE(MAX(rank),0)+1 AS n FROM prompt_results WHERE prompt_id=?", [.string(promptID)]).first?["n"] ?? 1
            try runtime.db.execute("INSERT INTO prompt_results(id,prompt_id,provider_id,provider_name,model,kind,url,rank,created_at,file_name,file_extension,file_size) VALUES (?,?,?,?,?,?,?,?,?,?,?,?)", [.string(resultID), .string(promptID), provider.0, provider.1, .string(model), .string(url == nil ? "upload" : "url"), url.map(JSONValue.string) ?? .null, rank, .number(Self.now), name.map(JSONValue.string) ?? .null, .string(ext), size.map { .number(Double($0)) } ?? .null])
            try touch(promptID)
        }
        await changed(promptID); return Self.publicResult(try result(resultID, promptID: promptID))
    }
    private static func publicPrompt(_ row: JSONObject) -> JSONValue { ["id": row["id"]!, "title": row["title"]!, "text": row["text"]!, "resultCount": row["result_count"] ?? 0, "createdAt": row["created_at"]!, "updatedAt": row["updated_at"]!] }
    private static func publicResult(_ row: JSONObject) -> JSONValue {
        ["id": row["id"]!, "promptId": row["prompt_id"]!, "providerId": row["provider_id"] ?? .null, "providerName": row["provider_name"] ?? .null, "model": row["model"]!, "kind": row["kind"]!, "url": row["url"] ?? .null, "rank": row["rank"]!, "createdAt": row["created_at"]!, "fileName": resultFileName(row), "fileSize": row["file_size"] ?? .null]
    }
    private static func resultFileName(_ row: JSONObject) -> JSONValue {
        guard row["kind"]?.string == "upload" else { return .null }
        if let name = row["file_name"], !name.isNull { return name }
        return .string((row["model"] ?? "result").string + ".html")
    }
    private static func label(_ value: JSONValue, maximum: Int, name: String) throws -> String {
        guard case .string(let raw) = value else { throw NativeFailure("\(name) is required") }
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, text.count <= maximum, !text.unicodeScalars.contains(where: { $0.value < 32 || $0.value == 127 }) else { throw NativeFailure("Invalid \(name.lowercased())") }
        return text
    }
    private static func title(_ value: JSONValue) throws -> String { try label(value, maximum: 200, name: "Title") }
    private static func model(_ value: JSONValue) throws -> String { try label(value, maximum: 300, name: "Model") }
    private static func text(_ value: JSONValue) throws -> String {
        guard case .string(let text) = value, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, text.count <= 200_000, !text.contains("\0") else { throw NativeFailure("Prompt text is required and must be at most 200,000 characters") }
        return text
    }
    private static func url(_ value: JSONValue) throws -> String {
        let text = value.string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.count <= 4096, let url = URL(string: text), ["http", "https"].contains(url.scheme?.lowercased() ?? ""), url.host != nil, url.user == nil, url.password == nil else { throw NativeFailure("Use an HTTP(S) link without embedded credentials") }
        return url.absoluteString
    }
    private func models() throws -> JSONValue {
        let discovered = (try? NativeFile.readJSON(runtime.paths.data.appendingPathComponent("models.json"))) ?? [:]
        return ["providers": .array(try runtime.providers.list().map { row in
            let p = JSONValue.object(row), catalog = discovered[p["id"].string]
            let ids = catalog["ids"].array + p["models"].array + p["codex"]["models"].array
            var seen = Set<String>()
            let models = ids.filter { seen.insert($0.string).inserted }.map { id -> JSONValue in
                var m: JSONValue = ["id": id]
                if !catalog["meta"][id.string]["name"].isNull { m["name"] = catalog["meta"][id.string]["name"] }
                return m
            }
            return ["id": p["id"], "name": p["name"], "models": .array(models)]
        })]
    }
}
