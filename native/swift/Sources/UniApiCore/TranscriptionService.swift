import Foundation

public actor NativeTranscriptionService {
    private let runtime: NativeRuntime
    private let io: NativeTranscriptionIO
    private let asr: NativeWisprASR?
    private let localModels: NativeLocalWhisperModels
    private let localASR: NativeLocalWhisperASR
    private let requiresLocalReadiness: Bool
    private let notify: @Sendable (String) async -> Void
    private let submitJob: @Sendable (String, JSONValue) async throws -> JSONObject
    private let cancelJob: @Sendable (String) async throws -> Bool
    private var initialized = false
    private var registered = false
    private var mutationAdmission = Set<String>()
    private var estimator: NativeTranscriptionEstimator { .init(db: runtime.db) }
    public init(runtime: NativeRuntime, io: NativeTranscriptionIO? = nil, asr: NativeWisprASR? = nil, notify: (@Sendable (String) async -> Void)? = nil, submitJob: (@Sendable (String, JSONValue) async throws -> JSONObject)? = nil, cancelJob: (@Sendable (String) async throws -> Bool)? = nil) {
        self.runtime = runtime; self.io = io ?? .production(runtime: runtime); self.asr = asr
        self.requiresLocalReadiness = io == nil && asr == nil
        let models = NativeLocalWhisperModels(paths: runtime.paths)
        self.localModels = models
        self.localASR = NativeLocalWhisperASR(models: models, process: runtime.process, temporary: runtime.paths.tmp)
        self.submitJob = submitJob ?? { title, params in try await runtime.jobs.submit(kind: "transcribe", app: "transcribe", title: title, params: params) }
        self.cancelJob = cancelJob ?? { try await runtime.jobs.cancelAndWait($0) }
        self.notify = notify ?? { text in
            do { try await NativeNotifications.send(text, home: runtime.paths.home) }
            catch { await runtime.events.publish("notify.error", ["message": "Telegram notification delivery failed"]) }
        }
    }
    public func start() async throws {
        try initialize()
        if !registered && !runtime.paths.readOnly {
            await runtime.jobs.register(kind: "transcribe", lane: "transcribe", concurrency: asr == nil ? 1 : 2, resumable: true) { [weak self] params, context in
                guard let self else { throw NativeFailure("Transcription service is unavailable") }
                return try await self.run(params["transcriptId"].string, context: context, notify: params["notify"].bool)
            }
            registered = true
        }
    }
    private func initialize() throws {
        guard !initialized else { return }
        try runtime.db.migrate("transcribe-1", sql: """
        CREATE TABLE IF NOT EXISTS transcripts(id TEXT PRIMARY KEY,title TEXT NOT NULL,source TEXT NOT NULL,source_kind TEXT NOT NULL,media_path TEXT,keep_media INTEGER NOT NULL DEFAULT 0,duration_s REAL,lang TEXT,text TEXT NOT NULL DEFAULT '',chunks INTEGER NOT NULL DEFAULT 0,failed_chunks INTEGER NOT NULL DEFAULT 0,status TEXT NOT NULL,error TEXT,summary TEXT,summary_model TEXT,created_at INTEGER NOT NULL,finished_at INTEGER,job_id TEXT);
        """)
        try runtime.db.migrate("transcribe-2", sql: "CREATE TABLE IF NOT EXISTS transcript_chunks(transcript_id TEXT NOT NULL,idx INTEGER NOT NULL,text TEXT NOT NULL,PRIMARY KEY(transcript_id,idx));")
        try runtime.db.migrate("transcribe-3", sql: "CREATE TABLE IF NOT EXISTS transcribe_runs(id INTEGER PRIMARY KEY AUTOINCREMENT,transcript_id TEXT NOT NULL,kind TEXT NOT NULL,host TEXT,ext TEXT,duration_s REAL NOT NULL,bytes INTEGER,download_ms INTEGER,decode_ms INTEGER,transcribe_ms INTEGER,chunks INTEGER,ts INTEGER NOT NULL);")
        try runtime.db.migrate("transcribe-4", sql: "CREATE INDEX IF NOT EXISTS transcribe_runs_transcript ON transcribe_runs(transcript_id,ts DESC,id DESC);")
        try runtime.db.migrate("transcribe-5", sql: """
        ALTER TABLE transcripts ADD COLUMN transcribe_ms REAL;
        UPDATE transcripts AS t SET transcribe_ms=(SELECT r.transcribe_ms FROM transcribe_runs r JOIN jobs j ON j.id=t.job_id WHERE r.transcript_id=t.id AND j.status='done' AND j.started_at>0 AND r.ts>=t.created_at AND r.ts>=j.started_at AND r.ts<=t.finished_at AND t.finished_at<=j.finished_at AND r.transcribe_ms>0 AND r.transcribe_ms<=r.ts-j.started_at ORDER BY r.ts DESC,r.id DESC LIMIT 1) WHERE t.status='done';
        """)
        if !runtime.paths.readOnly {
            for name in ["transcripts", "uploads"] { try FileManager.default.createDirectory(at: runtime.paths.data.appendingPathComponent(name), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700]) }
        }
        initialized = true
    }
    public func handle(_ operation: String, input: JSONObject = [:]) async throws -> JSONValue {
        try await start()
        let value = JSONValue.object(input), id = value["id"].string
        switch operation {
        case "status":
            var status = io.available()
            if asr == nil {
                let model = await localModels.status()
                status["model"] = model
                status["localReady"] = .bool(model["available"].bool && status["localRuntime"]?.bool == true)
            }
            status["runs"] = try runtime.db.query("SELECT COUNT(*) AS n FROM transcribe_runs").first?["n"] ?? 0
            status["rates"] = ["link": try estimator.rate(kind: "url", key: nil, phase: .transcribe), "file": try estimator.rate(kind: "file", key: nil, phase: .transcribe)]
            return .object(status)
        case "model.install":
            try await localModels.install { [runtime] fraction, message in
                await runtime.events.publish("transcribe.model", ["progress": .number(fraction), "message": .string(message)])
            }
            return await localModels.status()
        case "model.remove":
            try await localModels.remove()
            return await localModels.status()
        case "list": return .array(try runtime.db.query(Self.presentedQuery + " ORDER BY t.created_at DESC LIMIT 500").map { Self.summary(Self.presented($0)) })
        case "detail":
            var row = try transcript(id)
            row["checkpointParts"] = .array(try runtime.db.query("SELECT idx,text FROM transcript_chunks WHERE transcript_id=? ORDER BY idx", [.string(id)]).map { ["index": $0["idx"] ?? .null, "text": $0["text"] ?? .null] })
            if let jobID = row["job_id"], let job = try await runtime.jobs.get(jobID.string) { row["job"] = .object(job) }
            return .object(row)
        case "resume":
            try runtime.paths.assertWritable()
            try admitMutation(id); defer { mutationAdmission.remove(id) }
            try Task.checkCancellation()
            let row = try transcript(id)
            guard row["status"] != "done" else { throw NativeFailure("This transcript is already complete") }
            let previous = try await runtime.jobs.get((row["job_id"] ?? .null).string)
            guard !["running", "queued"].contains(previous?["status"]?.string ?? "") else { throw NativeFailure("Transcription work is already active") }
            try runtime.db.execute("UPDATE transcripts SET status='queued',error=NULL,finished_at=NULL,transcribe_ms=NULL WHERE id=?", [.string(id)])
            do {
                let notify = input["notify"] ?? previous?["params"]?["notify"] ?? false
                let job = try await submitJob("Resume " + (row["title"] ?? "transcription").string, ["transcriptId": .string(id), "notify": notify])
                try runtime.db.execute("UPDATE transcripts SET job_id=? WHERE id=?", [job["id"]!, .string(id)])
                await publish(id); return .object(try transcript(id))
            } catch {
                _ = try? runtime.db.execute("UPDATE transcripts SET status=?,error=?,finished_at=?,transcribe_ms=? WHERE id=?", [row["status"] ?? "failed", row["error"] ?? .null, row["finished_at"] ?? .null, row["transcribe_ms"] ?? .null, .string(id)])
                throw error
            }
        case "export":
            let row = try transcript(id), title = (row["title"] ?? .string(id)).string
            let name = String(title.replacingOccurrences(of: "[^a-zA-Z0-9_.-]+", with: "_", options: .regularExpression).prefix(120)) + ".txt"
            return ["filename": .string(name), "text": .string((row["text"] ?? "").string + "\n")]
        case "rename":
            try runtime.paths.assertWritable(); _ = try transcript(id)
            let title = String(value["title"].string.trimmingCharacters(in: .whitespacesAndNewlines).prefix(200))
            guard !title.isEmpty else { throw NativeFailure("A title is required") }
            try runtime.db.execute("UPDATE transcripts SET title=? WHERE id=?", [.string(title), .string(id)])
            await publish(id); return Self.summary(try transcript(id))
        case "delete":
            try runtime.paths.assertWritable()
            try admitMutation(id); defer { mutationAdmission.remove(id) }
            let row = try transcript(id)
            if let job = row["job_id"], !job.isNull { _ = try await cancelJob(job.string) }
            let ownedUpload = runtime.paths.data.appendingPathComponent("uploads").standardizedFileURL.path + "/"
            if let path = row["media_path"], !path.isNull, path.string.hasPrefix(ownedUpload) { try? FileManager.default.removeItem(at: URL(fileURLWithPath: path.string)) }
            try? FileManager.default.removeItem(at: try file(id))
            try? FileManager.default.removeItem(at: try work(id))
            try runtime.db.transaction { try runtime.db.execute("DELETE FROM transcript_chunks WHERE transcript_id=?", [.string(id)]); try runtime.db.execute("DELETE FROM transcripts WHERE id=?", [.string(id)]) }
            await runtime.events.publish("transcribe.deleted", ["id": .string(id)])
            return ["ok": true]
        case "submit", "upload":
            try runtime.paths.assertWritable()
            // Every input route (Enter, drop and chooser too) shares admission.
            // Do not fetch media or copy an upload before its local prerequisites exist.
            if requiresLocalReadiness {
                guard NativeLocalWhisperASR.bundledExecutable != nil else { throw NativeFailure("The bundled local Whisper runtime is missing; reinstall UniApi") }
                guard await localModels.status()["available"].bool else { throw NativeFailure("Install the local Whisper model in Transcribe before submitting media") }
            }
            var source = value["source"].string.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !source.isEmpty else { throw NativeFailure("Choose a link or media file") }
            let url = URL(string: source), isURL = ["http", "https"].contains(url?.scheme?.lowercased() ?? "") && url?.host != nil
            var media: URL?, keep = false
            if !isURL {
                media = source.hasPrefix("~/") ? runtime.paths.home.appendingPathComponent(String(source.dropFirst(2))) : URL(fileURLWithPath: source)
                var directory: ObjCBool = false
                guard let chosen = media, FileManager.default.fileExists(atPath: chosen.path, isDirectory: &directory), !directory.boolValue else { throw NativeFailure("No such media file") }
                if operation == "upload" {
                    let name = NativePromptFiles.uploadName(chosen.lastPathComponent)
                    let destination = runtime.paths.data.appendingPathComponent("uploads/up-\(UUID().uuidString)_\(name)")
                    try FileManager.default.copyItem(at: chosen, to: destination); try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: destination.path)
                    media = destination; source = name; keep = true
                }
            }
            return try await submit(source: source, kind: isURL ? "url" : "file", media: media, keep: keep, input: value)
        case "summary":
            let rows = try runtime.db.query(Self.presentedQuery + " ORDER BY t.created_at DESC").map(Self.presented)
            return ["count": .number(Double(rows.count)), "running": .number(Double(rows.filter { ["queued", "running"].contains($0["status"]?.string ?? "") }.count)), "lastTitle": rows.first?["title"] ?? .null]
        default: throw NativeFailure("Unknown transcription operation: \(operation)")
        }
    }
    private func submit(source: String, kind: String, media: URL?, keep: Bool, input: JSONValue) async throws -> JSONValue {
        let id = "tr-" + UUID().uuidString.lowercased(), title = input["title"].string
        try runtime.db.execute("INSERT INTO transcripts(id,title,source,source_kind,media_path,keep_media,lang,status,created_at) VALUES (?,?,?,?,?,?,?,'queued',?)", [.string(id), .string(title), .string(source), .string(kind), media.map { .string($0.path) } ?? .null, .number(keep ? 1 : 0), input["lang"].string.isEmpty ? .null : input["lang"], .number(Self.now)])
        do {
            let job = try await runtime.jobs.submit(kind: "transcribe", app: "transcribe", title: "Transcribe " + (title.isEmpty ? source : title), params: ["transcriptId": .string(id), "notify": input["notify"]])
            try runtime.db.execute("UPDATE transcripts SET job_id=? WHERE id=?", [job["id"]!, .string(id)])
            await publish(id); return .object(try transcript(id))
        } catch {
            _ = try? runtime.db.execute("DELETE FROM transcripts WHERE id=?", [.string(id)])
            if keep, let media { try? FileManager.default.removeItem(at: media) }
            throw error
        }
    }
    private static var now: Double { Date().timeIntervalSince1970 * 1000 }
    private static let presentedQuery = "SELECT t.*,j.status AS native_job_status FROM transcripts t LEFT JOIN jobs j ON j.id=t.job_id"
    private static func presented(_ row: JSONObject) -> JSONObject {
        var row = row
        let jobStatus = row.removeValue(forKey: "native_job_status")?.string
        // Queued jobs can be cancelled before their handler ever runs. Derive
        // their visible terminal state from Jobs without mutating read-only data.
        if ["running", "queued"].contains(row["status"]?.string ?? ""), jobStatus == "cancelled" { row["status"] = "cancelled" }
        return NativeTranscriptMetrics.augment(row)
    }
    private func transcript(_ id: String) throws -> JSONObject {
        guard let row = try runtime.db.query(Self.presentedQuery + " WHERE t.id=?", [.string(id)]).first else { throw NativeFailure("Transcript not found") }
        return Self.presented(row)
    }
    private static func summary(_ row: JSONObject) -> JSONValue {
        var output = row; let text = output.removeValue(forKey: "text")?.string ?? ""
        output["textLength"] = .number(Double(text.count)); output["preview"] = .string(String(text.prefix(200)))
        return .object(output)
    }
    private func publish(_ id: String) async { if let row = try? transcript(id) { await runtime.events.publish("transcribe.updated", Self.summary(row)) } }
    private func admitMutation(_ id: String) throws {
        // The actor is reentrant across queue admission and cancellation drain.
        // Only competing control operations are excluded; the worker may still
        // publish checkpoints while delete awaits its completion.
        guard mutationAdmission.insert(id).inserted else { throw NativeFailure("This transcript is busy resuming or deleting; retry after it finishes") }
    }
    private func work(_ id: String) throws -> URL { try runtime.paths.containedFile("transcribe-" + id, in: runtime.paths.tmp) }
    private func file(_ id: String) throws -> URL { try runtime.paths.containedFile(id + ".txt", in: runtime.paths.data.appendingPathComponent("transcripts")) }
    private func run(_ id: String, context: NativeJobContext, notify: Bool) async throws -> JSONValue {
        // Implemented below as a separate extension to keep the persistent
        // operations and the resumable media pipeline independently reviewable.
        try await pipeline(id, context: context, notify: notify)
    }
}

extension NativeTranscriptionService {
    private func pipeline(_ id: String, context: NativeJobContext, notify shouldNotify: Bool) async throws -> JSONValue {
        let row = try transcript(id), value = JSONValue.object(row)
        let source = value["source"].string, kind = value["source_kind"].string
        let key = kind == "url" ? URL(string: source)?.host?.replacingOccurrences(of: "^www\\.", with: "", options: .regularExpression) : URL(fileURLWithPath: value["media_path"].isNull ? source : value["media_path"].string).pathExtension.lowercased()
        let work = try self.work(id)
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let completed = Dictionary(uniqueKeysWithValues: try runtime.db.query("SELECT idx,text FROM transcript_chunks WHERE transcript_id=?", [.string(id)]).map { (($0["idx"] ?? .null).int, ($0["text"] ?? "").string) })
        var title = value["title"].string
        var duration: Double? = value["duration_s"].isNull ? nil : value["duration_s"].double
        var knownBytes: Int?
        var timings: [NativeTranscriptionPhase: Double] = [:]
        let clock = ContinuousClock()
        func elapsed(_ start: ContinuousClock.Instant) -> Double { let v = start.duration(to: clock.now).components; return Double(v.seconds) * 1000 + Double(v.attoseconds) / 1e15 }
        var finalized = false
        try runtime.db.execute("UPDATE transcripts SET status='running',job_id=?,error=NULL WHERE id=?", [.string(context.id), .string(id)])
        await publish(id)
        if !completed.isEmpty { try await context.log("Resuming \(completed.count) completed chunks") }
        do {
            let token = try io.token()
            var media: URL?
            if kind == "url" {
                let receiptURL = work.appendingPathComponent("download.json")
                if let receipt = try? NativeFile.readJSON(receiptURL), receipt["source"].string == source,
                   let existing = try? runtime.paths.containedFile(receipt["file"].string, in: work), FileManager.default.fileExists(atPath: existing.path) {
                    media = existing
                    if title.isEmpty { title = receipt["title"].string }
                    if duration == nil && !receipt["duration"].isNull { duration = receipt["duration"].double }
                    try await context.log("Reusing downloaded \(existing.lastPathComponent)")
                } else {
                    // Resume a download left by the web implementation, whose
                    // work directory predates the explicit native receipt.
                    let files = try FileManager.default.contentsOfDirectory(at: work, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]).filter {
                        let info = try? $0.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
                        return !["audio.pcm", "download.json"].contains($0.lastPathComponent) && $0.pathExtension != "part" && info?.isRegularFile == true && info?.isSymbolicLink != true
                    }
                    media = files.max { ((try? $0.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) < ((try? $1.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) }
                    if media == nil {
                        try await context.progress(0.01, text: "Reading link metadata")
                        let metadata = (try? await io.probe(source)) ?? NativeMediaMetadata()
                        if duration == nil { duration = metadata.duration }; knownBytes = metadata.bytes
                        if title.isEmpty { title = metadata.title ?? "" }
                        let began = clock.now
                        try await emitETA(id, context: context, kind: kind, key: key, duration: duration, bytes: knownBytes, phase: .download, used: 0)
                        try await context.progress(0.02, text: "Downloading audio")
                        let download = try await io.download(source, work, context)
                        timings[.download] = elapsed(began)
                        guard let file = download.file else { throw NativeFailure("No media was downloaded") }
                        let checked = try runtime.paths.containedFile(file.lastPathComponent, in: work)
                        guard checked.standardizedFileURL == file.standardizedFileURL.resolvingSymlinksInPath() else { throw NativeFailure("Downloaded file escaped its work directory") }
                        media = checked
                        if title.isEmpty { title = download.title ?? file.deletingPathExtension().lastPathComponent }
                        if duration == nil { duration = download.duration }; knownBytes = download.bytes
                        try NativeFile.writeAtomic(try JSONValue.object(["source": .string(source), "file": .string(file.lastPathComponent), "title": .string(title), "duration": duration.map(JSONValue.number) ?? .null]).encoded(), to: receiptURL)
                    }
                }
            } else {
                let path = value["media_path"].isNull ? source : value["media_path"].string
                media = path.hasPrefix("~/") ? runtime.paths.home.appendingPathComponent(String(path.dropFirst(2))) : URL(fileURLWithPath: path)
            }
            guard let media, FileManager.default.fileExists(atPath: media.path) else { throw NativeFailure("The media file is unavailable") }
            if title.isEmpty { title = media.deletingPathExtension().lastPathComponent }
            if knownBytes == nil { knownBytes = try? media.resourceValues(forKeys: [.fileSizeKey]).fileSize }
            let decodeStart = clock.now
            try await emitETA(id, context: context, kind: kind, key: key, duration: duration, bytes: knownBytes, phase: .decode, used: 0)
            try await context.progress(0.3, text: "Decoding audio")
            let pcm = try await io.decode(media, work)
            timings[.decode] = elapsed(decodeStart); duration = pcm.duration
            // A rename made while download/decode is awaiting must win over
            // the title captured when the pipeline started.
            let currentTitle = try transcript(id)["title"]?.string ?? ""
            if !currentTitle.isEmpty { title = currentTitle }
            try runtime.db.execute("UPDATE transcripts SET title=?,duration_s=? WHERE id=?", [.string(title), .number(pcm.duration), .string(id)])
            try await context.setTitle("Transcribe " + title); await publish(id)
            try await context.log("\(Int(pcm.duration)) seconds of audio; decoded in \(String(format: "%.1f", timings[.decode]! / 1000)) seconds")
            let transcribeStart = clock.now
            try await emitETA(id, context: context, kind: kind, key: key, duration: duration, bytes: knownBytes, phase: .transcribe, used: 0)
            let etaTask = Task { [weak self] in
                while !Task.isCancelled {
                    do { try await Task.sleep(nanoseconds: 5_000_000_000) } catch { return }
                    try? await self?.emitETA(id, context: context, kind: kind, key: key, duration: pcm.duration, bytes: knownBytes, phase: .transcribe, used: elapsed(transcribeStart))
                }
            }
            defer { etaTask.cancel() }
            let report: NativeLocalWhisperASR.Progress = { [weak self] done, total, index, text in
                try await context.progress(0.32 + 0.66 * Double(done) / Double(total), text: "Transcribing \(done)/\(total) chunks")
                if let index, let text { try await self?.checkpoint(id, index: index, text: text, total: total, context: context) }
            }
            let result: JSONValue
            let language = value["lang"].isNull ? nil : value["lang"].string
            if let asr { result = try await asr.transcribe(pcm, language: language, token: token, completed: completed, progress: report) }
            else { result = try await localASR.transcribe(pcm, language: language, completed: completed, progress: report) }
            timings[.transcribe] = elapsed(transcribeStart)
            try context.checkCancellation()
            let text = result["text"].string, chunks = result["parts"].array.count, gaps = result["gaps"].array.count
            try NativeFile.writeAtomic(Data((text + "\n").utf8), to: try file(id))
            try runtime.db.transaction {
                if completed.isEmpty {
                    try runtime.db.execute("INSERT INTO transcribe_runs(transcript_id,kind,host,ext,duration_s,bytes,download_ms,decode_ms,transcribe_ms,chunks,ts) VALUES (?,?,?,?,?,?,?,?,?,?,?)", [.string(id), .string(kind), kind == "url" ? key.map(JSONValue.string) ?? .null : .null, .string(media.pathExtension.lowercased()), .number(pcm.duration), knownBytes.map { .number(Double($0)) } ?? .null, timings[.download].map(JSONValue.number) ?? .null, timings[.decode].map(JSONValue.number) ?? .null, timings[.transcribe].map(JSONValue.number) ?? .null, .number(Double(chunks)), .number(Self.now)])
                }
                try runtime.db.execute("UPDATE transcripts SET text=?,chunks=?,failed_chunks=?,status='done',finished_at=?,duration_s=?,transcribe_ms=? WHERE id=?", [.string(text), .number(Double(chunks)), .number(Double(gaps)), .number(Self.now), .number(pcm.duration), completed.isEmpty ? timings[.transcribe].map(JSONValue.number) ?? .null : .null, .string(id)])
                try runtime.db.execute("DELETE FROM transcript_chunks WHERE transcript_id=?", [.string(id)])
            }
            finalized = true; await publish(id)
            try? await context.progress(1, text: gaps > 0 ? "Done with \(gaps) missing chunks" : "Done")
            try? FileManager.default.removeItem(at: work)
            if shouldNotify { await notify("Done: Transcribe \(title) — \(chunks) chunks\(gaps > 0 ? ", \(gaps) missing" : "")") }
            return ["chars": .number(Double(text.count)), "chunks": .number(Double(chunks))]
        } catch {
            if !finalized {
                if error is CancellationError || Task.isCancelled {
                    let explicit = await context.wasExplicitlyCancelled()
                    try runtime.db.execute("UPDATE transcripts SET status=?,finished_at=? WHERE id=?", [explicit ? "cancelled" : "queued", explicit ? .number(Self.now) : .null, .string(id)])
                }
                else {
                    try runtime.db.execute("UPDATE transcripts SET status='failed',error=?,finished_at=? WHERE id=?", [.string(error.localizedDescription), .number(Self.now), .string(id)])
                    try? FileManager.default.removeItem(at: work)
                    if shouldNotify { await notify("Failed: Transcribe \(title.isEmpty ? source : title) — \(error.localizedDescription)") }
                }
                await publish(id)
            }
            throw error
        }
    }
    private func checkpoint(_ id: String, index: Int, text: String, total: Int, context: NativeJobContext) async throws {
        try runtime.db.execute("INSERT OR REPLACE INTO transcript_chunks(transcript_id,idx,text) VALUES (?,?,?)", [.string(id), .number(Double(index)), .string(text)])
        try await context.emit("chunk", ["transcriptId": .string(id), "index": .number(Double(index)), "total": .number(Double(total)), "text": .string(text)])
    }
    private func emitETA(_ id: String, context: NativeJobContext, kind: String, key: String?, duration: Double?, bytes: Int?, phase: NativeTranscriptionPhase, used: Double) async throws {
        guard let duration, duration > 0, duration.isFinite else { return }
        let estimate = try estimator.estimate(kind: kind, key: key, duration: duration, bytes: bytes, from: phase)
        try await context.emit("eta", ["transcriptId": .string(id), "phase": .string(phase.rawValue), "eta_ms": .number(max(0, estimate["ms"].double - used)), "basis": estimate["basis"], "duration_s": .number(duration)])
    }
}
