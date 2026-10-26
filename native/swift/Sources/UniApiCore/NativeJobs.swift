import Foundation

public struct NativeJobContext: Sendable {
    public let id: String
    public let runtimePaths: NativePaths
    private let queue: NativeJobQueue
    init(id: String, runtimePaths: NativePaths, queue: NativeJobQueue) { self.id = id; self.runtimePaths = runtimePaths; self.queue = queue }
    public func progress(_ fraction: Double, text: String = "") async throws { try await queue.update(id, fraction: fraction, text: text) }
    public func log(_ line: String) async throws { try await queue.appendLog(id, line: line) }
    public func emit(_ name: String, _ data: JSONValue) async throws { try await queue.emit(id, name: name, data: data) }
    public func setTitle(_ title: String) async throws { try await queue.rename(id, title: title) }
    public func checkCancellation() throws { try Task.checkCancellation() }
    public func wasExplicitlyCancelled() async -> Bool { await queue.wasExplicitlyCancelled(id) }
}

public actor NativeJobQueue {
    public static let defaultPruneAge: TimeInterval = 7 * 86400
    public typealias Handler = @Sendable (JSONValue, NativeJobContext) async throws -> JSONValue
    private struct Registration { let lane: String; let resumable: Bool; let handler: Handler }
    private let db: NativeDatabase
    private let paths: NativePaths
    private let events: NativeEvents
    private var registrations: [String: Registration] = [:]
    private var laneLimits: [String: Int] = [:]
    private var running: [String: (lane: String, task: Task<Void, Never>)] = [:]
    private var recovered = false
    private var suspended = false
    private var suspendedJobs = Set<String>()
    private var explicitCancellations = Set<String>()
    public init(db: NativeDatabase, paths: NativePaths, events: NativeEvents) throws {
        self.db = db; self.paths = paths; self.events = events
        try db.migrate("jobs-1", sql: """
        CREATE TABLE IF NOT EXISTS jobs (
            id TEXT PRIMARY KEY, kind TEXT NOT NULL, app TEXT NOT NULL, title TEXT NOT NULL,
            lane TEXT NOT NULL, params TEXT NOT NULL, status TEXT NOT NULL,
            progress REAL NOT NULL DEFAULT 0, progress_text TEXT NOT NULL DEFAULT '',
            result TEXT, error TEXT, log TEXT NOT NULL DEFAULT '[]', created_at INTEGER NOT NULL,
            started_at INTEGER, finished_at INTEGER
        ); CREATE INDEX IF NOT EXISTS jobs_status ON jobs(status,created_at);
        """)
    }
    public func register(kind: String, lane: String? = nil, concurrency: Int = 1, resumable: Bool = true, handler: @escaping Handler) {
        let lane = lane ?? kind, limit = max(1, concurrency)
        registrations[kind] = Registration(lane: lane, resumable: resumable, handler: handler)
        // A lane has one limit even when different job kinds share it. This
        // matches the server's registration policy (the latest limit wins).
        laneLimits[lane] = limit
    }
    @discardableResult public func submit(kind: String, app: String, title: String, params: JSONValue) async throws -> JSONObject {
        try paths.assertWritable()
        guard !suspended else { throw NativeFailure("The job runtime is shutting down") }
        guard let registration = registrations[kind] else { throw NativeFailure("Unknown job kind: \(kind)") }
        let id = "job-" + UUID().uuidString.lowercased()
        let json = String(decoding: try params.encoded(), as: UTF8.self)
        try db.execute("INSERT INTO jobs(id,kind,app,title,lane,params,status,created_at) VALUES (?,?,?,?,?,?,'queued',?)", [.string(id), .string(kind), .string(app), .string(title), .string(registration.lane), .string(json), .number(Self.now)])
        let job = try get(id)!
        await events.publish("job.updated", .object(job))
        try await schedule()
        return job
    }
    public func get(_ id: String) throws -> JSONObject? { try db.query("SELECT * FROM jobs WHERE id=?", [.string(id)]).first.map(Self.decodeRow) }
    public func activeCount() throws -> Int {
        try db.query("SELECT COUNT(*) AS n FROM jobs WHERE status IN ('running','queued')").first?["n"]?.int ?? 0
    }
    public func list(app: String? = nil, statuses: [String] = [], limit: Int = 200) throws -> [JSONObject] {
        var clauses: [String] = [], params: [JSONValue] = []
        if let app { clauses.append("app=?"); params.append(.string(app)) }
        if !statuses.isEmpty { clauses.append("status IN (\(statuses.map { _ in "?" }.joined(separator: ",")))"); params += statuses.map(JSONValue.string) }
        params.append(.number(Double(max(1, min(limit, 10000)))))
        return try db.query("SELECT * FROM jobs \(clauses.isEmpty ? "" : "WHERE " + clauses.joined(separator: " AND ")) ORDER BY created_at DESC LIMIT ?", params).map(Self.decodeRow)
    }
    public func cancel(_ id: String) async throws -> Bool {
        try paths.assertWritable()
        if let task = running[id]?.task { explicitCancellations.insert(id); task.cancel(); return true }
        let changed = try db.execute("UPDATE jobs SET status='cancelled',finished_at=? WHERE id=? AND status='queued'", [.number(Self.now), .string(id)])
        if changed > 0, let job = try get(id) { await events.publish("job.updated", .object(job)) }
        return changed > 0
    }
    public func cancelAndWait(_ id: String) async throws -> Bool {
        let task = running[id]?.task
        let cancelled = try await cancel(id)
        if let task { await task.value }
        return cancelled
    }
    /// Drain owned work on process shutdown while preserving restart recovery.
    /// GUI closure never calls this; explicit job cancellation remains final.
    public func suspendForShutdown() async {
        guard !suspended else { return }
        suspended = true
        let tasks = running
        suspendedJobs = Set(tasks.keys).subtracting(explicitCancellations)
        for value in tasks.values { value.task.cancel() }
        for value in tasks.values { await value.task.value }
    }
    public func recover() async throws {
        try paths.assertWritable()
        guard !recovered else { return }
        for row in try db.query("SELECT * FROM jobs WHERE status IN ('running','queued')") {
            let id = row["id"]!.string, kind = row["kind"]!.string
            guard let registration = registrations[kind] else {
                try db.execute("UPDATE jobs SET status='failed',error=?,finished_at=? WHERE id=?", ["No native handler registered after restart", .number(Self.now), .string(id)]); continue
            }
            if row["status"]?.string == "running" {
                if registration.resumable { try db.execute("UPDATE jobs SET status='queued',started_at=NULL,progress=0,progress_text='Requeued after restart' WHERE id=?", [.string(id)]) }
                else { try db.execute("UPDATE jobs SET status='failed',error='App restarted during a non-resumable job',finished_at=? WHERE id=?", [.number(Self.now), .string(id)]) }
            }
        }
        recovered = true
        try await schedule()
    }
    public func prune(olderThan seconds: TimeInterval) throws -> Int64 {
        try paths.assertWritable()
        guard seconds.isFinite else { throw NativeFailure("Prune age must be finite") }
        return try db.execute("DELETE FROM jobs WHERE status IN ('done','failed','cancelled') AND finished_at<?", [.number(Self.now - max(0, seconds) * 1000)])
    }
    private func schedule() async throws {
        guard !suspended else { return }
        for row in try db.query("SELECT * FROM jobs WHERE status='queued' ORDER BY created_at,rowid") {
            guard !suspended else { return }
            let kind = row["kind"]!.string, id = row["id"]!.string
            guard let registration = registrations[kind], running[id] == nil else { continue }
            let lane = row["lane"]!.string
            guard running.values.filter({ $0.lane == lane }).count < (laneLimits[lane] ?? 1) else { continue }
            guard try db.execute("UPDATE jobs SET status='running',started_at=?,progress=0,progress_text='' WHERE id=? AND status='queued'", [.number(Self.now), .string(id)]) > 0 else { continue }
            let parameters = (try? JSONValue.decode(Data((row["params"]?.string ?? "null").utf8))) ?? .null
            let context = NativeJobContext(id: id, runtimePaths: paths, queue: self)
            let task = Task { [weak self] in
                do {
                    try Task.checkCancellation()
                    let result = try await registration.handler(parameters, context)
                    try Task.checkCancellation()
                    await self?.finish(id, status: "done", result: result, error: nil)
                } catch is CancellationError { await self?.finish(id, status: "cancelled", result: .null, error: nil) }
                catch { await self?.finish(id, status: Task.isCancelled ? "cancelled" : "failed", result: .null, error: error.localizedDescription) }
            }
            running[id] = (lane, task)
            if let job = try get(id) { await events.publish("job.updated", .object(job)) }
        }
    }
    private func finish(_ id: String, status: String, result: JSONValue, error: String?) async {
        if suspendedJobs.contains(id), status != "done" {
            running.removeValue(forKey: id)
            // Keep the original running row: resumable handlers requeue on
            // startup, and non-resumable handlers fail through the same policy.
            return
        }
        do {
            let encoded = String(decoding: try result.encoded(), as: UTF8.self)
            try db.execute("UPDATE jobs SET status=?,result=?,error=?,finished_at=?,progress=CASE WHEN ?='done' THEN 1 ELSE progress END WHERE id=?", [.string(status), .string(encoded), error.map(JSONValue.string) ?? .null, .number(Self.now), .string(status), .string(id)])
            if let job = try get(id) { await events.publish("job.updated", .object(job)) }
        } catch { await events.publish("runtime.error", .string("Cannot persist job completion: \(error.localizedDescription)")) }
        running.removeValue(forKey: id)
        explicitCancellations.remove(id)
        do { try await schedule() } catch { await events.publish("runtime.error", .string(error.localizedDescription)) }
    }
    fileprivate func wasExplicitlyCancelled(_ id: String) -> Bool { explicitCancellations.contains(id) }
    fileprivate func update(_ id: String, fraction: Double, text: String) async throws {
        try Task.checkCancellation()
        guard fraction.isFinite else { throw NativeFailure("Job progress must be finite") }
        try db.execute("UPDATE jobs SET progress=?,progress_text=? WHERE id=? AND status='running'", [.number(max(0, min(1, fraction))), .string(text), .string(id)])
        if let job = try get(id) { await events.publish("job.progress", .object(job)) }
    }
    fileprivate func appendLog(_ id: String, line: String) async throws {
        try Task.checkCancellation()
        guard var row = try get(id) else { throw NativeFailure("Unknown job") }
        var log = row["log"]?.array ?? []; log.append(.string(line)); log = Array(log.suffix(400))
        try db.execute("UPDATE jobs SET log=? WHERE id=?", [.string(String(decoding: try JSONValue.array(log).encoded(), as: UTF8.self)), .string(id)])
        row["log"] = .array(log)
        await events.publish("job.log", .object(row))
    }
    fileprivate func emit(_ id: String, name: String, data: JSONValue) async throws {
        try Task.checkCancellation()
        guard let row = try get(id), let kind = row["kind"]?.string else { throw NativeFailure("Unknown job") }
        var payload = data.object
        payload["id"] = .string(id)
        await events.publish("job.\(kind).\(name)", .object(payload))
    }
    fileprivate func rename(_ id: String, title: String) async throws {
        try Task.checkCancellation()
        try db.execute("UPDATE jobs SET title=? WHERE id=?", [.string(title), .string(id)])
        if let row = try get(id) { await events.publish("job.updated", .object(row)) }
    }
    private static var now: Double { Date().timeIntervalSince1970 * 1000 }
    private static func decodeRow(_ row: JSONObject) -> JSONObject {
        var result = row
        for key in ["params", "result", "log"] {
            if let value = row[key], !value.isNull { result[key] = (try? JSONValue.decode(Data(value.string.utf8))) ?? .null }
        }
        return result
    }
}
