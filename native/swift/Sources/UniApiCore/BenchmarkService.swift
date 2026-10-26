import Foundation

/// Operations: catalog, discover(provider), selection, saveSelection,
/// resultsState, saveResultsState, run(tier,pairs,resumeRun?), resume(run_id),
/// stop(jobId?), progress, summary(scope), curves(scope),
/// rows(provider?,model?,scope?,test?,limit?), usage,
/// export(scope,summary,family?), freeTest, freeTestReport, saveSchedule,
/// key(provider), updateProvider(provider,name,baseUrl,apiKey).
/// Reads both historical ledgers; all execution and folds are native Swift.
public actor NativeBenchmarkService {
    private static let pool = BenchmarkServicePool()
    public nonisolated static func shared(runtime: NativeRuntime) -> NativeBenchmarkService { pool.get(runtime) }
    public let runtime: NativeRuntime
    private let dependencies: BenchmarkDependencies, store: BenchmarkStore
    private var registered = false, scheduler: Task<Void, Never>?, discovering = Set<String>()
    private var registration: Task<Void, Error>?
    private var progress: JSONValue = [:]
    private var freeProgress: JSONValue = [:]
    private var operationPending = false
    public init(runtime: NativeRuntime, dependencies: BenchmarkDependencies? = nil) {
        self.runtime = runtime; store = BenchmarkStore(paths: runtime.paths)
        self.dependencies = dependencies ?? BenchmarkDependencies(transport: BenchmarkCurlTransport(runtime: runtime))
    }
    deinit { scheduler?.cancel() }
    public func start() async throws {
        if let registration { try await registration.value; return }
        let task = Task { try await self.registerHandlers() }; registration = task
        do { try await task.value } catch { registration = nil; throw error }
    }
    private func registerHandlers() async throws {
        guard !registered else { return }
        if !runtime.paths.readOnly { try await store.seedCalibration() }
        await runtime.jobs.register(kind: "bench.run", lane: "bench", concurrency: 1, resumable: false) { [weak self] parameters, context in
            guard let self else { throw NativeFailure("Benchmark service is unavailable") }
            return try await self.execute(parameters, context: context)
        }
        await runtime.jobs.register(kind: "bench.freetest", lane: "bench", concurrency: 1, resumable: false) { [weak self] _, context in
            guard let self else { throw NativeFailure("Benchmark service is unavailable") }
            return try await self.sweep(context: context)
        }
        registered = true
        if dependencies.schedulingEnabled && !runtime.paths.readOnly {
            scheduler = Task { [weak self] in
                while !Task.isCancelled {
                    do { try await Task.sleep(nanoseconds: 30_000_000_000) } catch { return }
                    guard let service = self else { return }; await service.scheduledTick()
                }
            }
        }
    }
    public func handle(_ operation: String, input: JSONObject = [:]) async throws -> JSONValue {
        let value = JSONValue.object(input)
        switch operation {
        case "catalog": return try await catalog()
        case "discover":
            try await assertIdle()
            defer { operationPending = false }
            let provider = value["provider"].isNull ? value["id"].string : value["provider"].string
            if provider.isEmpty {
                var output: JSONObject = [:]
                for row in try runtime.providers.list() { output[row["id"]!.string] = try await discover(.object(row)) }
                return .object(output)
            }
            guard let row = try runtime.providers.list().first(where: { $0["id"]?.string == provider }) else { throw NativeFailure("Unknown provider") }
            return try await discover(.object(row))
        case "selection":
            let saved = await store.state("native-selection", fallback: .null)
            if !saved.isNull { return saved }
            return dependencies.legacySelection(runtime.paths) ?? ["included": [], "models": [:], "tier": "standard"]
        case "saveSelection":
            guard BenchmarkTier.names.contains(value["tier"].string), case .array = value["included"], case .object = value["models"] else { throw NativeFailure("Invalid benchmark selection") }
            try await store.save("native-selection", value); return value
        case "resultsState": return await store.state("native-results-view", fallback: ["scope": "latest", "family": "", "tab": "table", "newestRun": ""])
        case "saveResultsState":
            guard ["table", "charts"].contains(value["tab"].string), validLabel(value["scope"].string) else { throw NativeFailure("Invalid Results selection") }
            try await store.save("native-results-view", value); return value
        case "run":
            try await assertIdle(); defer { operationPending = false }; try await start()
            guard BenchmarkTier.names.contains(value["tier"].string), !value["pairs"].array.isEmpty else { throw NativeFailure("Choose a depth and at least one provider/model") }
            let providers = try runtime.providers.list(), models = await store.catalog()
            var seen = Set<String>(), pairs: [JSONValue] = []
            for pair in value["pairs"].array {
                guard validLabel(pair["provider"].string), validLabel(pair["model"].string), let provider = providers.first(where: { $0["id"] == pair["provider"] }) else { throw NativeFailure("Unknown or invalid benchmark pair") }
                if provider["transport"] == "chatgpt-web" {
                    _ = try dependencies.bridge(runtime.paths)
                    let entry = models[pair["provider"].string]
                    guard entry["error"].isNull || entry["error"] == "", entry["ids"].array.contains(pair["model"]), entry["meta"][pair["model"].string]["available"] != false else { throw NativeFailure("Refresh the browser catalog and choose an available mode") }
                }
                let key = pair["provider"].string + "|" + pair["model"].string
                if seen.insert(key).inserted { pairs.append(["provider": pair["provider"], "model": pair["model"]]) }
            }
            let resume = value["resumeRun"].string
            if !resume.isEmpty {
                let checkpoint = try await store.state("native-run-" + safeRun(resume), fallback: .null)
                guard !checkpoint.isNull, checkpoint["tier"] == value["tier"], checkpoint["pairs"] == .array(pairs) else { throw NativeFailure("Resume requires the recorded run's exact depth and pairs") }
            }
            let run = resume.isEmpty ? newRun(value["tier"].string) : resume
            let params: JSONValue = ["tier": value["tier"], "pairs": .array(pairs), "run_id": .string(run), "resume": .bool(!resume.isEmpty), "notify": value["notify"]]
            try await store.save("native-run-" + safeRun(run), params)
            let job = try await runtime.jobs.submit(kind: "bench.run", app: "bench", title: "Benchmark " + value["tier"].string, params: params)
            var view = await store.state("native-results-view", fallback: ["scope": "latest", "family": "", "tab": "table"]); view["scope"] = "latest"; view["newestRun"] = .string(run); try await store.save("native-results-view", view)
            return ["job": .object(job), "run_id": .string(run)]
        case "resume":
            let run = try safeRun(value["run_id"].string)
            var saved = await store.state("native-run-" + run, fallback: .null)
            guard !saved.isNull else { throw NativeFailure("No native checkpoint exists for this run") }
            saved["resumeRun"] = .string(run)
            return try await handle("run", input: saved.object)
        case "stop":
            let jobs = try await activeJobs(), requested = value["jobId"].string
            guard let job = jobs.first(where: { requested.isEmpty || $0["id"]?.string == requested }) else { return ["cancelled": false] }
            return ["cancelled": .bool(try await runtime.jobs.cancel(job["id"]!.string))]
        case "progress":
            let current = await store.state("progress", fallback: .null)
            let job = try await runtime.jobs.list(app: "bench", limit: 100).first(where: { $0["kind"] == "bench.run" }).map(JSONValue.object) ?? .null
            let run = current["run_id"].string
            let checkpoint = run.isEmpty ? JSONValue.null : try await store.state("native-run-" + safeRun(run), fallback: .null)
            let active = ["queued", "running"].contains(job["status"].string)
            let interrupted = !active && !run.isEmpty && !current["done"].bool
            return ["job": job, "progress": current, "interrupted": .bool(interrupted), "resumeAvailable": .bool(!active && (current["aborted"].bool || interrupted) && !checkpoint.isNull)]
        case "summary":
            var scope = value["scope"].string.isEmpty ? "all" : value["scope"].string
            if scope == "latest", let active = try await activeJobs().first(where: { $0["kind"] == "bench.run" }), let run = active["params"]?["run_id"].string, !run.isEmpty { scope = run }
            return BenchmarkFold.summary(try await store.rows(), scope: scope)
        case "home":
            let runs = try await store.runHistory()
            let jobs = try await activeJobs(), selection = try await handle("selection")
            let planned = selection["included"].array.reduce(0) { $0 + selection["models"][$1.string].array.count }
            return ["running": .bool(jobs.contains { $0["kind"] == "bench.run" }), "progress": jobs.first?["progress"] ?? .null, "lastRun": runs.first ?? .null, "runs": .array(Array(runs.prefix(4))), "planned": .number(Double(planned))]
        case "rows": return .array(Array(try await selectedRows(value).suffix(max(1, min(2000, input["limit"]?.int ?? 2000)))).reversed())
        case "curves":
            var latest: [String: JSONValue] = [:]
            for row in try await selectedRows(value) where row["ok"].bool && row["test"] == "throughput" && !row["curve"].array.isEmpty {
                latest[row["provider"].string + "|" + row["model"].string] = row
            }
            return .array(latest.keys.sorted().compactMap { latest[$0] })
        case "usage": return BenchmarkFold.usage(try await store.rows())
        case "export":
            let scope = value["scope"].string.isEmpty ? "all" : value["scope"].string
            var summary = BenchmarkFold.summary(try await store.rows(), scope: scope)
            let family = value["family"].string
            if value["filterFamily"].bool && !family.isEmpty { summary["cells"] = .object(summary["cells"].object.filter { $0.value["family"] == .string(family) }) }
            let rows = try await selectedRows(["scope": .string(scope)]).filter { !value["filterFamily"].bool || family.isEmpty || BenchmarkMath.family($0["model"].string) == family }
            let name = scope == "all" ? "all-runs" : summary["scope"].string.lowercased().replacingOccurrences(of: "[^a-z0-9-]+", with: "-", options: .regularExpression).trimmingCharacters(in: CharacterSet(charactersIn: "-"))
            let csvSummary: JSONValue? = value["summary"].bool ? Optional<JSONValue>.some(summary) : Optional<JSONValue>.none
            return ["filename": .string("uniapi-" + (name.isEmpty ? "run" : name) + (value["summary"].bool ? "-summary.csv" : "-raw.csv")), "text": .string(BenchmarkFold.csv(rows, summary: csvSummary, label: value["label"].string.isEmpty ? nil : value["label"].string))]
        case "freeTest":
            try await assertIdle(); defer { operationPending = false }; try await start()
            let job = try await runtime.jobs.submit(kind: "bench.freetest", app: "bench", title: "Free Test: configured Claude routes", params: [:]); return ["job": .object(job)]
        case "freeTestReport": return ["report": await store.state("free-test", fallback: .null), "schedule": await schedule(), "job": try await activeJobs().first(where: { $0["kind"] == "bench.freetest" }).map(JSONValue.object) ?? .null]
        case "saveSchedule":
            guard value["enabled"].isNull || { if case .bool = value["enabled"] { return true }; return false }(), value["time"].isNull || Self.validTime(value["time"].string) else { throw NativeFailure("Use an enabled flag and a 24-hour HH:MM time") }
            var next = await schedule()
            if value["enabled"] == true && next["enabled"] != true { next["lastRun"] = .number(dependencies.now().timeIntervalSince1970 * 1000) }
            if !value["enabled"].isNull { next["enabled"] = value["enabled"] }; if !value["time"].isNull { next["time"] = value["time"] }
            try await store.save("free-test-schedule", next); return next
        case "key":
            guard let provider = try runtime.providers.list().first(where: { $0["id"] == value["provider"] }), provider["transport"] != "chatgpt-web" else { throw NativeFailure("Browser credentials cannot be copied") }
            return ["key": provider["api_key"] ?? .null]
        case "updateProvider":
            try await assertIdle(); defer { operationPending = false }
            guard validLabel(value["name"].string), let url = URL(string: value["baseUrl"].string),
                  ["http", "https"].contains(url.scheme ?? ""), url.host != nil, url.user == nil, url.password == nil,
                  !value["apiKey"].string.unicodeScalars.contains(where: { $0.value < 32 || $0.value == 127 }) else { throw NativeFailure("Use a name, HTTP endpoint and valid API key") }
            try runtime.providers.mutate { document in
                var providers = document["providers"]!.array
                guard let index = providers.firstIndex(where: { $0["id"] == value["provider"] }), providers[index]["transport"] != "chatgpt-web" else { throw NativeFailure("Browser credentials remain in the external bridge") }
                providers[index]["name"] = value["name"]; providers[index]["base_url"] = .string(url.absoluteString.trimmingCharacters(in: CharacterSet(charactersIn: "/"))); providers[index]["api_key"] = value["apiKey"]
                document["providers"] = .array(providers)
            }
            await runtime.events.publish("bench.catalog", ["provider": value["provider"]])
            return ["updated": true]
        default: throw NativeFailure("Unknown Benchmark operation: " + operation)
        }
    }
    private func validLabel(_ label: String) -> Bool { !label.isEmpty && label.count <= 1024 && !label.unicodeScalars.contains { $0.value < 32 || $0.value == 127 } }
    private func safeRun(_ run: String) throws -> String {
        guard run.range(of: "^[A-Za-z0-9_-]{1,160}$", options: .regularExpression) != nil else { throw NativeFailure("Invalid run ID") }; return run
    }
    private func newRun(_ tier: String) -> String { let f = DateFormatter(); f.dateFormat = "yyyyMMdd-HHmmss"; return f.string(from: dependencies.now()) + "-" + tier + "-" + UUID().uuidString.prefix(6) }
    private func activeJobs() async throws -> [JSONObject] { try await runtime.jobs.list(app: "bench", statuses: ["running", "queued"]) }
    private func assertIdle() async throws {
        try runtime.paths.assertWritable()
        guard !operationPending, discovering.isEmpty else { throw NativeFailure("A benchmark, free test or discovery is already active") }
        operationPending = true
        do { guard try await activeJobs().isEmpty else { throw NativeFailure("A benchmark, free test or discovery is already active") } }
        catch { operationPending = false; throw error }
    }
    private func catalog() async throws -> JSONValue {
        let catalog = await store.catalog()
        let providers = try runtime.providers.list().map { raw -> JSONValue in
            let p = JSONValue.object(raw), id = p["id"].string, entry = catalog[id], browser = p["transport"] == "chatgpt-web"
            let models = !entry["ids"].array.isEmpty ? entry["ids"].array : browser ? [] : Array(Set(p["proxy"]["models"].array + p["models"].array + p["codex"]["models"].array)).sorted { $0.string < $1.string }
            let key = p["api_key"].string
            var reason: JSONValue = entry["error"]
            if browser {
                do { _ = try dependencies.bridge(runtime.paths); if models.isEmpty { reason = "Discover available browser modes" } }
                catch { reason = .string(error.localizedDescription) }
            }
            return ["id": p["id"], "name": p["name"].isNull ? p["id"] : p["name"], "baseUrl": browser ? .null : p["base_url"], "format": browser ? .null : p["proxy"]["format"], "transport": .string(browser ? "chatgpt-web" : "api"), "maskedKey": .string(browser ? "" : key.count > 14 ? String(key.prefix(10)) + "..." + String(key.suffix(4)) : key), "hasKey": .bool(!browser && !key.isEmpty), "catalogTs": entry["ts"], "catalogError": entry["error"], "ready": .bool(!browser || reason.isNull || reason == ""), "readinessReason": reason,
                "capabilities": ["arbitraryModels": .bool(!browser), "maxOutput": .bool(!browser), "prefill": .bool(!browser), "tokenCounts": .string(browser ? "estimated" : "reported"), "latency": .string(browser ? "visible-text" : "first-token")],
                "catalog": .array(models.map { model in let meta = entry["meta"][model.string], context = ["context_length", "max_context_length", "max_model_len", "context_window", "max_input_tokens"].compactMap { BenchmarkMath.number(meta[$0]) }.first; return ["id": model, "name": meta["name"], "context": BenchmarkMath.optional(context), "available": meta["available"], "reason": meta["reason"]] })]
        }
        return ["engine": true, "tiers": .array(BenchmarkTier.names.map(JSONValue.string)), "providers": .array(providers), "running": try await activeJobs().first.map(JSONValue.object) ?? .null]
    }
    private func discover(_ provider: JSONValue) async throws -> JSONValue {
        let id = provider["id"].string; discovering.insert(id); defer { discovering.remove(id) }
        let browser = provider["transport"] == "chatgpt-web"
        var entry: JSONValue = ["ts": .string(BenchmarkMath.iso(dependencies.now())), "http_code": 0, "ids": [], "meta": [:], "error": .null, "count": 0]
        var privateKey = ""
        do {
            let connection: BenchmarkConnection
            if browser { connection = try dependencies.bridge(runtime.paths) }
            else {
                guard let url = URL(string: provider["base_url"].string), ["http", "https"].contains(url.scheme ?? ""), url.host != nil, url.user == nil, url.password == nil else { throw NativeFailure("Invalid provider URL") }
                connection = .init(baseURL: url, key: provider["api_key"].string)
            }
            privateKey = connection.key
            let base = connection.baseURL.absoluteString.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            var headers = ["Authorization": "Bearer " + connection.key, "User-Agent": "Mozilla/5.0 api-bench/native"]
            if !browser { headers["x-api-key"] = connection.key }
            let response = try await dependencies.transport.execute(.init(url: URL(string: base + "/models")!, headers: headers, timeout: 45))
            entry["http_code"] = .number(Double(response.status))
            let parsed = (try? JSONValue.decode(response.data)) ?? .null, models = parsed.array.isEmpty ? parsed["data"].array : parsed.array
            var ids: [JSONValue] = [], meta: JSONObject = [:], seen = Set<String>()
            for row in models {
                let id = row.string.isEmpty ? row["id"].string : row.string
                guard validLabel(id), seen.insert(id).inserted else { continue }; ids.append(.string(id))
                let keys = ["context_length", "max_context_length", "max_model_len", "context_window", "max_input_tokens", "max_output_tokens", "input_modalities", "vision"] + (browser ? ["name", "available", "reason", "capabilities"] : [])
                meta[id] = .object(row.object.filter { keys.contains($0.key) })
            }
            entry["ids"] = .array(ids); entry["meta"] = .object(meta); entry["count"] = .number(Double(ids.count))
            if response.status != 200 { entry["error"] = .string(String(response.text.replacingOccurrences(of: connection.key, with: connection.key.isEmpty ? "" : "<redacted>").prefix(300))) }
        } catch is CancellationError { throw CancellationError() }
        catch { entry["error"] = .string(error.localizedDescription) }
        entry = BenchmarkMath.redact(entry, key: privateKey)
        try await store.saveCatalog(id, entry)
        var matrix = await store.state("matrix")
        for model in entry["ids"].array { let family = BenchmarkMath.family(model.string); var group = matrix[family], cell = group[id]; var variants = cell["variants"].array; if !variants.contains(model) { variants.append(model) }; cell["variants"] = .array(variants.sorted { $0.string.count < $1.string.count }); if cell["primary"].isNull { cell["primary"] = model }; group[id] = cell; matrix[family] = group }
        try await store.save("matrix", matrix); await runtime.events.publish("bench.catalog", ["provider": .string(id)]); return entry
    }
    private func selectedRows(_ filter: JSONValue) async throws -> [JSONValue] {
        let all = try await store.rows(), scope = filter["scope"].string
        let actual = scope == "latest" ? BenchmarkFold.summary(all, scope: "latest")["scope"].string : scope
        return all.filter { row in
            let run = row["run_id"].string.isEmpty ? "unknown" : row["run_id"].string
            return (actual.isEmpty || actual == "all" || run == actual) && (filter["provider"].string.isEmpty || row["provider"] == filter["provider"]) && (filter["model"].string.isEmpty || row["model"] == filter["model"]) && (filter["test"].string.isEmpty || row["test"] == filter["test"])
        }
    }
    private func execute(_ parameters: JSONValue, context: NativeJobContext) async throws -> JSONValue {
        let run = parameters["run_id"].string, tier = parameters["tier"].string, pairs = parameters["pairs"].array
        let providers = try runtime.providers.document(), catalog = await store.catalog()
        let previous = parameters["resume"].bool ? try await store.rows().filter { $0["run_id"] == .string(run) } : []
        var saved: [String: JSONValue] = [:]; for row in previous where !row["unit_id"].string.isEmpty { saved[row["unit_id"].string] = row }
        progress = ["run_id": .string(run), "tier": .string(tier), "started": .string(BenchmarkMath.iso(dependencies.now())), "done": false, "aborted": false, "pairs": [:]]
        try await store.save("progress", progress)
        try await context.log("Run \(run): \(tier), \(pairs.count) selected pairs. Providers run in parallel; models per key run in sequence.")
        await runtime.events.publish("bench.started", ["run_id": .string(run)])
        do {
            let grouped = Dictionary(grouping: pairs) { $0["provider"].string }
            try await withThrowingTaskGroup(of: Void.self) { tasks in
                for (id, pairs) in grouped {
                    guard let row = providers["providers"]?.array.first(where: { $0["id"] == .string(id) }) else { throw NativeFailure("Selected provider was removed") }
                    let worker = BenchmarkWorker(provider: row, settings: providers["settings"] ?? [:], catalog: catalog[id], store: store, dependencies: dependencies, runID: run, tierName: tier, savedUnits: saved,
                        report: { [weak self] key, model, total, done, current in try await self?.step(key, model: model, total: total, done: done, current: current, context: context) },
                        rowEvent: { [weak self] row in try context.checkCancellation(); await self?.runtime.events.publish("bench.row", row) },
                        diagnostic: { try await context.log($0) })
                    tasks.addTask { try await worker.run(pairs.map { $0["model"].string }) }
                }
                try await tasks.waitForAll()
            }
            progress["done"] = true; progress["finished"] = .string(BenchmarkMath.iso(dependencies.now())); try await store.save("progress", progress)
            let summary = BenchmarkFold.summary(try await store.rows(), scope: run); try await store.save("summary", summary)
            try await context.log("Run \(run) finished: \(summary["rows"].int) recorded tests.")
            await runtime.events.publish("bench.finished", ["run_id": .string(run)])
            if parameters["notify"].bool {
                do { try await dependencies.notify("Done: benchmark \(tier) — \(summary["rows"].int) recorded tests", runtime.paths) }
                catch { await runtime.events.publish("runtime.error", .string("Benchmark completed; notification delivery failed")) }
            }
            return ["run_id": .string(run), "rows": summary["rows"]]
        } catch {
            progress["done"] = true; progress["aborted"] = true; progress["finished"] = .string(BenchmarkMath.iso(dependencies.now())); try? await store.save("progress", progress)
            // The queue rejects logs in a cancelled task. Drain one fixed,
            // non-cancelled final write before returning cancellation to it.
            let line = error is CancellationError ? "Run \(run) cancelled; completed units remain checkpointed." : "Run \(run) failed; inspect the recorded test details."
            _ = try? await Task { try await context.log(line) }.value
            await runtime.events.publish("bench.finished", ["run_id": .string(run), "aborted": true]); throw error
        }
    }
    private func step(_ key: String, model: String, total: Int, done: Int, current: String?, context: NativeJobContext) async throws {
        try context.checkCancellation()
        var pairs = progress["pairs"], pair = pairs[key]
        pair["model"] = .string(model); pair["provider"] = .string(String(key.split(separator: "|").first ?? "")); pair["provider_name"] = (try? runtime.providers.list().first(where: { $0["id"] == pair["provider"] })?["name"]) ?? pair["provider"]
        pair["total"] = .number(Double(total)); pair["done"] = .number(Double(done)); pair["current"] = current.map(JSONValue.string) ?? .null
        pairs[key] = pair; progress["pairs"] = pairs; try await store.save("progress", progress)
        let totals = pairs.object.values.reduce((0.0, 0.0)) { ($0.0 + $1["total"].double, $0.1 + $1["done"].double) }
        try await context.progress(totals.0 > 0 ? totals.1 / totals.0 : 0, text: current ?? "\(Int(totals.1))/\(Int(totals.0)) tests")
        await runtime.events.publish("bench.progress", progress)
    }
    private func schedule() async -> JSONValue { await store.state("free-test-schedule", fallback: ["enabled": false, "time": "04:00", "lastRun": .null]) }
    public static func validTime(_ time: String) -> Bool { time.range(of: "^([01][0-9]|2[0-3]):[0-5][0-9]$", options: .regularExpression) != nil }
    public static func scheduleDue(_ schedule: JSONValue, now: Date, calendar: Calendar = .current) -> Bool {
        guard schedule["enabled"].bool, validTime(schedule["time"].string) else { return false }
        let parts = schedule["time"].string.split(separator: ":").compactMap { Int($0) }
        guard let slot = calendar.date(bySettingHour: parts[0], minute: parts[1], second: 0, of: now), now >= slot else { return false }
        return schedule["lastRun"].isNull || schedule["lastRun"].double < slot.timeIntervalSince1970 * 1000
    }
    private func scheduledTick() async {
        var schedule = await schedule()
        guard Self.scheduleDue(schedule, now: dependencies.now()), (try? await activeJobs().isEmpty) == true, discovering.isEmpty else { return }
        do {
            _ = try await handle("freeTest"); schedule["lastRun"] = .number(dependencies.now().timeIntervalSince1970 * 1000); try await store.save("free-test-schedule", schedule)
        } catch { await runtime.events.publish("runtime.error", .string(error.localizedDescription)) }
    }
    private func sweep(context: NativeJobContext) async throws -> JSONValue {
        let providers = try runtime.providers.list().map(JSONValue.object)
        let total = providers.reduce(0) { $0 + ($1["transport"] == "chatgpt-web" ? $1["models"].array.count : $1["proxy"]["models"].array.count) }
        var report: JSONValue = ["startedAt": .number(dependencies.now().timeIntervalSince1970 * 1000), "finishedAt": .null, "done": 0, "total": .number(Double(total)), "cancelled": false, "rows": []]
        freeProgress = report
        try await store.save("free-test", report)
        do {
            try await withThrowingTaskGroup(of: Void.self) { tasks in
                for provider in providers {
                    let models = provider["transport"] == "chatgpt-web" ? provider["models"].array : provider["proxy"]["models"].array
                    tasks.addTask {
                        var denied = 0
                        for model in models {
                            try context.checkCancellation()
                            var result: JSONValue
                            if !NativeProviderInfo(provider).enabled {
                                result = ["provider": provider["id"], "model": model, "outcome": "skipped", "ms": 0, "message": "No enabled Claude Code route; browser modes are benchmark-only"]
                            } else if denied >= 40 {
                                result = ["provider": provider["id"], "model": model, "outcome": "skipped", "ms": 0, "message": "Stopped after 40 consecutive entitlement refusals"]
                            } else { result = try await self.freeProbe(provider, model: model.string) }
                            let outcome = result["outcome"].string
                            if outcome != "skipped" || denied < 40 { denied = ["denied", "missing"].contains(outcome) ? denied + 1 : 0 }
                            try await self.freeRow(result, context: context)
                            try await self.dependencies.sleep(0.25)
                        }
                    }
                }
                try await tasks.waitForAll()
            }
            report = freeProgress; report["finishedAt"] = .number(dependencies.now().timeIntervalSince1970 * 1000)
            let ranks = ["works", "empty", "limited", "missing", "denied", "timeout", "failed", "skipped"]
            report["rows"] = .array(report["rows"].array.sorted { let a = ranks.firstIndex(of: $0["outcome"].string) ?? 8, b = ranks.firstIndex(of: $1["outcome"].string) ?? 8; return a == b ? $0["provider"].string + $0["model"].string < $1["provider"].string + $1["model"].string : a < b })
            try await store.save("free-test", report); await runtime.events.publish("bench.freetest.done", report); return report
        } catch {
            report = freeProgress; report["cancelled"] = true; report["finishedAt"] = .number(dependencies.now().timeIntervalSince1970 * 1000); try? await store.save("free-test", report); throw error
        }
    }
    private func freeRow(_ row: JSONValue, context: NativeJobContext) async throws {
        var report = freeProgress, rows = report["rows"].array; rows.append(row); report["rows"] = .array(rows); report["done"] = .number(Double(rows.count)); freeProgress = report
        try await store.save("free-test", report); try await context.progress(report["total"].double > 0 ? Double(rows.count) / report["total"].double : 1, text: "\(rows.count)/\(report["total"].int) models")
        await runtime.events.publish("bench.freetest.row", row)
    }
    private func freeProbe(_ provider: JSONValue, model: String) async throws -> JSONValue {
        let began = dependencies.now(), info = NativeProviderInfo(provider), key = info.key
        for attempt in 0..<2 {
            try Task.checkCancellation()
            var outcome = "failed", message = ""
            do {
                let route = try NativeClaudeTextProbe.request(info, model: model, timeout: 15)
                let response = try await dependencies.transport.execute(.init(url: route.url, headers: route.headers, body: route.body, timeout: route.timeout))
                let value = (try? JSONValue.decode(response.data)) ?? .null
                if response.status == 200 {
                    message = value["content"].array.filter { $0["type"] == "text" || $0["type"].isNull }.map { $0["text"].string }.joined().trimmingCharacters(in: .whitespacesAndNewlines)
                    outcome = message.isEmpty ? "empty" : "works"; if message.isEmpty { message = "answered with an empty reply" }
                }
                else { message = response.text.isEmpty ? response.error : response.text; outcome = BenchmarkMath.freeOutcome(status: response.status, text: message) }
                if response.exitCode == 28 { outcome = "timeout" }
            } catch is CancellationError { throw CancellationError() }
            catch { try Task.checkCancellation(); message = error.localizedDescription; outcome = BenchmarkMath.freeOutcome(status: 0, text: message) }
            if outcome == "limited" && attempt == 0 { try await dependencies.sleep(4); continue }
            if !key.isEmpty { message = message.replacingOccurrences(of: key, with: "<redacted>") }
            return ["provider": provider["id"], "model": .string(model), "outcome": .string(outcome), "message": .string(String(message.prefix(outcome == "works" ? 80 : 200))), "ms": .number(dependencies.now().timeIntervalSince(began) * 1000)]
        }
        throw NativeFailure("Free-test retry exhausted")
    }
}

private final class BenchmarkServicePool: @unchecked Sendable {
    private let lock = NSLock()
    private final class Entry { weak var service: NativeBenchmarkService?; init(_ service: NativeBenchmarkService) { self.service = service } }
    private var services: [ObjectIdentifier: Entry] = [:]
    func get(_ runtime: NativeRuntime) -> NativeBenchmarkService {
        lock.lock(); defer { lock.unlock() }; let id = ObjectIdentifier(runtime)
        if let service = services[id]?.service { return service }
        services = services.filter { $0.value.service != nil }
        let service = NativeBenchmarkService(runtime: runtime); services[id] = Entry(service); return service
    }
}
