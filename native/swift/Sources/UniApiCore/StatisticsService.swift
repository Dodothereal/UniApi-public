import Foundation
import CryptoKit
import Darwin

/// Operations: overview(range,source), model(model,range,source), refresh, rescan,
/// summary, bench, exportDailyCSV(model,range,source). No web/API subprocess.
public actor NativeStatisticsService {
    private static let pool = StatisticsServicePool()
    public nonisolated static func shared(runtime: NativeRuntime) -> NativeStatisticsService { pool.service(runtime) }
    public let runtime: NativeRuntime
    private let environment: [String: String], calendar: Calendar
    private let clock: @Sendable () -> Double
    private let beforeScan: @Sendable () async throws -> Void
    private let beforeCodexCommit: @Sendable (NativeRuntime) throws -> Void
    private let streamTimingPollNanoseconds: UInt64
    private var streamTimingMonitor: Task<Void, Never>?
    private var initialized = false, loaded = false, lastCheck: Double = 0, generation = 0
    private var scanNeedsRebuild = false
    private struct ScanFlight { let id: UUID, full: Bool, task: Task<Void, Error> }
    private var scanTask: ScanFlight?
    private var stopping = false
    private var events: [StatisticsUsage] = [], cache: StatisticsCache?
    private var streamTimingSignature = "", streamTimingGeneration = -1
    private var streamTimingObservations: [String: NativeCodexStreamTimingObservation]?
    private var cacheDocument: JSONValue?
    private var importedFiles: [File] = []
    private var importedCacheFiles: [JSONObject] = []
    private var importedDataVersion: JSONValue = .null
    private var codexAppendCache = StatisticsCodexAppendCache()
    private var codexPublication: StatisticsAppendPublication?
    private let codexPublicationEnabled: Bool
    private var scan: JSONValue = [:], progress: JSONValue = ["scanId": "", "phase": "", "status": "idle", "done": 0, "total": 0, "file": "", "generation": 0, "loaded": false]
    private var rawByDay: [String: Double] = [:], colors: JSONValue = [:], warnings: [String] = []
    private var folds: [String: StatisticsDerived] = [:]
    private var publishedTotals: StatisticsPublishedTotals?
    private var queryDay: Double?, sourceTotals: [Int: JSONValue] = [:]
    private var claudeLifetimeModels: [String: StatisticsModel]?
    private struct DetailKey: Hashable { let model: String, range: Int, source: String }
    private var details: [DetailKey: JSONValue] = [:], detailOrder: [DetailKey] = []
    private var benchSignature = "", benchRows: [JSONValue] = []
    private nonisolated let publishedSummary: StatisticsPublishedSummary

    public init(runtime: NativeRuntime) {
        self.runtime = runtime; calendar = .current; clock = { Date().timeIntervalSince1970 * 1000 }
        publishedSummary = StatisticsPublishedSummary()
        beforeScan = {}
        beforeCodexCommit = { _ in }
        codexPublicationEnabled = true
        streamTimingPollNanoseconds = 10_000_000_000
        // A supplied test home must not accidentally import the process user's stores.
        environment = runtime.paths.home.standardizedFileURL == FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL ? ProcessInfo.processInfo.environment : [:]
    }
    init(runtime: NativeRuntime, environment: [String: String], calendar: Calendar = .current, clock: @escaping @Sendable () -> Double,
         streamTimingPollNanoseconds: UInt64 = 10_000_000_000,
         bootstrapQueue: DispatchQueue = .global(qos: .utility),
         bootstrapLoad: @escaping @Sendable (NativeRuntime, Double) throws -> JSONValue = { try StatisticsSummaryBootstrap.load(runtime: $0, now: $1) },
         codexPublicationEnabled: Bool = true,
         beforeCodexCommit: @escaping @Sendable (NativeRuntime) throws -> Void = { _ in },
         beforeScan: @escaping @Sendable () async throws -> Void = {}) {
        self.runtime = runtime; self.environment = environment; self.calendar = calendar; self.clock = clock
        self.streamTimingPollNanoseconds = max(1_000_000, streamTimingPollNanoseconds)
        publishedSummary = StatisticsPublishedSummary(queue: bootstrapQueue, load: bootstrapLoad)
        self.beforeScan = beforeScan
        self.codexPublicationEnabled = codexPublicationEnabled
        self.beforeCodexCommit = beforeCodexCommit
    }
    public func start() async throws {
        try checkRunning(); try initialize(); try await ensureScan()
        _ = refreshNativeStreamTimings()
        guard !runtime.paths.readOnly, streamTimingMonitor == nil, !stopping else { return }
        let interval = streamTimingPollNanoseconds
        // Check one tiny journal's metadata, not the transcript corpus. A weak
        // capture lets fixture/services deallocate without a background cycle.
        streamTimingMonitor = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(nanoseconds: interval) } catch { break }
                await self?.collectNativeStreamTimings()
            }
        }
    }
    deinit { streamTimingMonitor?.cancel() }
    /// Reserve before mounting the native page tree. This owns pending work,
    /// never a loaded generation; the app must immediately schedule the start.
    package nonisolated func reserveInitialGeneration() -> UUID? { publishedSummary.reserveInitial() }
    package func startInitialGeneration(_ token: UUID) async throws {
        do {
            guard publishedSummary.ownsInitial(token) else { throw CancellationError() }
            try await start()
            _ = publishedSummary.finishInitial(token)
        } catch {
            if publishedSummary.finishInitial(token, error: error.localizedDescription) {
                await runtime.cache.invalidate("hub:summaries")
                await runtime.events.publish("stats.cached", publishedSummary.read())
            }
            throw error
        }
    }
    /// Final runtime shutdown, not page disappearance: cancel the real shared
    /// scan and await it. A running synchronous fallback must drain too.
    package func shutdownInitialGeneration() async {
        stopping = true; publishedSummary.stop()
        let monitor = streamTimingMonitor; streamTimingMonitor = nil
        monitor?.cancel(); await monitor?.value
        if let flight = scanTask {
            flight.task.cancel()
            do { try await flight.task.value; finishScan(flight.id) }
            catch { finishScan(flight.id, error: error) }
        }
        codexAppendCache.removeAll()
        codexPublication = nil
        await publishedSummary.drainBootstrap()
    }
    private func checkRunning() throws {
        guard !stopping else { throw CancellationError() }
        try Task.checkCancellation()
    }
    /// Home can show honest readiness without forcing a corpus scan in its
    /// initial request. A completed scan updates it through stats.scanned.
    public nonisolated func cachedSummary() -> JSONValue {
        publishedSummary.bootstrap(runtime: runtime, clock: clock)
        return publishedSummary.read()
    }
    /// Metadata-only diagnosis: never parse transcript content or modify cache.
    public func metadataDiagnostics() throws -> JSONValue {
        let files = try discover(), known = try cachedFiles()
        let indexed = Dictionary(uniqueKeysWithValues: known.map { (($0["path"] ?? .null).string, $0) })
        var counts: JSONObject = [:]
        for file in files {
            let old = indexed[file.cachePath]
            guard let info = try Self.discoveryMetadata(file.url) else { continue }
            var exact = Double(info.st_mtimespec.tv_sec) * 1000 + Double(info.st_mtimespec.tv_nsec) / 1e6
            if ["antigravity", "zcode", "opencode"].contains(file.source) {
                if let wal = try Self.checkedDiscoverySignature(URL(fileURLWithPath: file.url.path + "-wal")) { exact = max(exact, wal.mtime) }
            }
            var group = counts[file.source] ?? [:]
            let field = old == nil ? "uncached" : old?["size"]?.double != file.size ? "sizeChanged" : old?["mtime"]?.double == file.mtime ? "matched" : old?["mtime"]?.double == exact ? "foundationPrecisionMismatch" : abs((old?["mtime"]?.double ?? 0) - file.mtime) <= 0.001 ? "subMicrosecondMismatch" : "mtimeChanged"
            group[field] = .number(group[field].double + 1)
            counts[file.source] = group
        }
        return ["files": .number(Double(files.count)), "known": .number(Double(known.count)), "sources": .object(counts)]
    }
    private func initialize() throws {
        guard !initialized else { return }
        try runtime.db.migrate("stats-1", sql: """
        CREATE TABLE IF NOT EXISTS stats_files(path TEXT PRIMARY KEY,mtime REAL NOT NULL,size INTEGER NOT NULL);
        CREATE TABLE IF NOT EXISTS stats_records(path TEXT NOT NULL,msg_id TEXT NOT NULL,ts INTEGER NOT NULL,raw_day TEXT NOT NULL,model TEXT NOT NULL,project TEXT NOT NULL,session TEXT NOT NULL,sidechain INTEGER NOT NULL,effort TEXT NOT NULL,input INTEGER NOT NULL,output INTEGER NOT NULL,thinking INTEGER NOT NULL,cache_write INTEGER NOT NULL,cache_read INTEGER NOT NULL,web_search INTEGER NOT NULL,web_fetch INTEGER NOT NULL);
        CREATE INDEX IF NOT EXISTS stats_records_path ON stats_records(path);
        """
        )
        try runtime.db.migrate("stats-codex-1", sql: "ALTER TABLE stats_records ADD COLUMN source TEXT NOT NULL DEFAULT 'claude'; ALTER TABLE stats_files ADD COLUMN excluded_usage INTEGER NOT NULL DEFAULT 0;")
        try runtime.db.migrate("stats-throughput-1", sql: "ALTER TABLE stats_records ADD COLUMN duration_ms REAL; ALTER TABLE stats_records ADD COLUMN timing TEXT; UPDATE stats_files SET mtime=-1,size=-1;")
        // Reparse once on migration so canonical fallback IDs and timing boundaries
        // are consistent across files cached by the old web implementation.
        try runtime.db.migrate("native-statistics-readers-1", sql: "UPDATE stats_files SET mtime=-1,size=-1;")
        try runtime.db.migrate("stats-source-path-1", sql: "ALTER TABLE stats_files ADD COLUMN source_path TEXT NOT NULL DEFAULT '';")
        try runtime.db.migrate("stats-native-stream-timing-1", sql: "CREATE TABLE IF NOT EXISTS stats_native_stream_timing(record_id TEXT PRIMARY KEY,observation TEXT NOT NULL,completed_at REAL NOT NULL); CREATE INDEX IF NOT EXISTS stats_native_stream_timing_recent ON stats_native_stream_timing(completed_at DESC,record_id ASC);")
        // Older metadata projection discarded explicit response-item turn IDs.
        // Only Codex records can contain clocks inferred under that projection.
        try runtime.db.migrate("native-statistics-turn-clocks-1", sql: "UPDATE stats_files SET mtime=-1,size=-1 WHERE path IN (SELECT path FROM stats_records WHERE source='codex');")
        // Native writers advance this with the file transaction, even when
        // a forced reparse preserves its physical size and modification time.
        // Opaque commit identities also survive deletion/recreation ABA: a new
        // row cannot restart an integer counter at the old observed value.
        try runtime.db.migrate("native-statistics-record-revision-1", sql: "ALTER TABLE stats_files ADD COLUMN record_revision TEXT NOT NULL DEFAULT '';")
        // Shared with the retained web reader. Only Antigravity already has
        // persisted stream clocks; other old response estimates remain intact.
        try runtime.db.migrate("stats-streaming-1", sql: "ALTER TABLE stats_records ADD COLUMN stream_duration_ms REAL; ALTER TABLE stats_records ADD COLUMN stream_output_tokens REAL; ALTER TABLE stats_records ADD COLUMN stream_timing TEXT; UPDATE stats_files SET mtime=-1,size=-1 WHERE path IN (SELECT path FROM stats_records WHERE source='antigravity');")
        initialized = true
    }
    private func cachedFiles() throws -> [JSONObject] {
        // Read-only previews can inspect a legacy cache before this additive
        // migration is installed. Absence of the column means plain identity.
        let columns = Set(try runtime.db.query("PRAGMA table_info(stats_files)").map { ($0["name"] ?? .null).string })
        return try runtime.db.query("SELECT path,mtime,size,\(columns.contains("source_path") ? "source_path" : "'' AS source_path"),\(columns.contains("record_revision") ? "record_revision" : "'' AS record_revision") FROM stats_files ORDER BY path")
    }
    private func ensureScan(full: Bool = false, force: Bool = false) async throws {
        try checkRunning()
        while let flight = scanTask {
            do { try await flight.task.value; finishScan(flight.id) }
            catch { finishScan(flight.id, error: error); throw error }
            try checkRunning()
            // A manual full rescan cannot be satisfied by the incremental
            // check it happened to join. Concurrent full requests coalesce.
            if !full || flight.full { return }
        }
        // Explicit Reload must check source metadata even inside the ordinary
        // read freshness window; it need not decode unchanged history again.
        if !force && !full && loaded && clock() - lastCheck < 30_000 { return }
        publishedSummary.scanning(true)
        let id = UUID(), task = Task {
            self.progress = ["scanId": .string(id.uuidString), "done": 0, "total": 0, "file": ""]
            await self.publishProgress("discovering")
            do { try await self.beforeScan(); try Task.checkCancellation(); try await self.importCorpus(full: full) }
            catch {
                await self.publishProgress(self.progress["phase"].string, failed: true)
                throw error
            }
        }
        scanTask = ScanFlight(id: id, full: full, task: task)
        do { try await task.value; finishScan(id) }
        catch { finishScan(id, error: error); throw error }
    }
    private func finishScan(_ id: UUID, error: Error? = nil) {
        // An earlier waiter must never clear a newer full scan's ownership.
        guard scanTask?.id == id else { return }
        scanTask = nil; publishedSummary.scanning(false, error: error?.localizedDescription)
    }
    private func publishProgress(_ phase: String, failed: Bool = false) async {
        // Failure retains its work phase and last published generation; a
        // completed file count alone never claims successful publication.
        progress["phase"] = .string(phase)
        progress["status"] = .string(failed ? "failed" : phase == "complete" ? "complete" : "running")
        progress["generation"] = .number(Double(generation)); progress["loaded"] = .bool(loaded)
        if phase != "reading" || failed { progress["file"] = "" }
        await runtime.events.publish("stats.progress", progress)
    }
    public func handle(_ operation: String, input: JSONObject = [:]) async throws -> JSONValue {
        try checkRunning()
        try initialize()
        let op = operation == "stats" ? "overview" : operation
        if op == "refresh" || op == "rescan" {
            try await ensureScan(full: op == "rescan", force: true)
            return ["ok": true, "scan": scan]
        }
        if op == "bench" { return try benchmark(model: nil, range: 0) }
        if !loaded { try await ensureScan() }
        else if clock() - lastCheck >= 30_000 { Task { try? await self.ensureScan() } }
        _ = refreshNativeStreamTimings()
        let now = clock()
        let requestedRange = (input["range"] ?? 0).int
        let requestedSource = (input["source"] ?? "all").string
        let allowedSources = ["all"] + StatisticsSource.allCases.map(\.rawValue)
        let source = allowedSources.contains(requestedSource) ? requestedSource : "all"
        let range = [0, 7, 30].contains(requestedRange) ? requestedRange : 0
        switch op {
        case "overview":
            let key = "statistics:\(ObjectIdentifier(runtime)):\(generation):\(statisticsDay(now, calendar: calendar)):\(range):\(source)"
            var value = try await runtime.cache.read(key, load: { await self.overview(range: range, source: source, now: now) })
            value["scanning"] = .bool(scanTask != nil)
            value["progress"] = progress
            return value
        case "summary":
            let totals = publicationTotals(now: now)
            return ["loaded": true, "grand": .number(totals.totals.grand), "models": .number(Double(totals.models)), "responses": .number(totals.totals.messages)]
        case "model", "exportDailyCSV":
            let model = (input["model"] ?? .null).string
            guard !model.isEmpty, model.count <= 300, !model.unicodeScalars.contains(where: { $0.value < 32 }), [0, 7, 30, 90, 365].contains(requestedRange), allowedSources.contains(requestedSource) else { throw NativeFailure("Choose a valid model, source and date range.") }
            var value = try detail(model: model, range: requestedRange, source: source, now: now)
            if op == "exportDailyCSV" { return ["filename": "UniApi-model-daily-usage.csv", "text": .string(dailyCSV(value, model: model, source: source))] }
            value["loaded"] = true; value["scanning"] = .bool(scanTask != nil); value["model"] = .string(model); value["range"] = .number(Double(requestedRange)); value["source"] = .string(source); value["colors"] = colors
            value["bench"] = try benchmark(model: model, range: requestedRange, now: now); return value
        default: throw NativeFailure("Unknown Statistics operation: \(operation)")
        }
    }
    private func lifetimeModel(range: Int, source: String, model: String, now: Double) -> StatisticsModel? {
        guard range == 0, source == "all" || source == "claude", cache?.perModel[model] != nil else { return nil }
        prepareQueryDay(now: now)
        if source == "all" { return derived(range: 0, source: source, now: now).models.first { $0.model == model } }
        if claudeLifetimeModels == nil, let cache {
            let rows = events.filter { $0.source == "claude" }
            var board = StatisticsDerived()
            board.summary = StatisticsFold.summary(rows, calendar: calendar); board.models = StatisticsFold.models(rows, calendar: calendar)
            StatisticsFold.lifetime(&board, events: rows, cache: cache, calendar: calendar)
            claudeLifetimeModels = Dictionary(uniqueKeysWithValues: board.models.map { ($0.model, $0) })
        }
        return claudeLifetimeModels?[model]
    }
    private func prepareQueryDay(now: Double) {
        let day = statisticsDay(now, calendar: calendar)
        if queryDay != day { clearQueries(); queryDay = day }
    }
    private func clearQueries() {
        folds.removeAll(); sourceTotals.removeAll(); claudeLifetimeModels = nil
        publishedTotals = nil
        details.removeAll(); detailOrder.removeAll()
    }
    private func publicationTotals(now: Double) -> StatisticsPublishedTotals {
        prepareQueryDay(now: now)
        if let publishedTotals { return publishedTotals }
        let totals = StatisticsPublishedTotals.fold(events, cache: cache)
        publishedTotals = totals
        return totals
    }
    private func detail(model: String, range: Int, source: String, now: Double) throws -> JSONValue {
        prepareQueryDay(now: now)
        let key = DetailKey(model: model, range: range, source: source)
        if let value = details[key] {
            detailOrder.removeAll { $0 == key }; detailOrder.append(key); return value
        }
        // Filter the corpus once. Every detail chart and source card after
        // this point visits only this exact model's records.
        let rows = events.filter { $0.model == model }
        guard var value = StatisticsFold.detail(rows, range: range, cache: cache, source: source, model: model, now: now, calendar: calendar, lifetimeModel: lifetimeModel(range: range, source: source, model: model, now: now)) else { throw NativeFailure("No usage is recorded for this model.") }
        let totals = StatisticsSourceTotals.fold(rows, range: range, cache: nil, now: now, calendar: calendar)
        let lifetime = lifetimeModel(range: range, source: "claude", model: model, now: now)
        value["sources"] = .object(Dictionary(uniqueKeysWithValues: StatisticsSource.allCases.map { source in
            let total = source == .claude ? lifetime?.totals.json ?? totals[source.rawValue] : totals[source.rawValue]
            return (source.rawValue, total["messages"].double > 0 || source == .claude && lifetime != nil ? total : .null)
        }))
        details[key] = value; detailOrder.append(key)
        // The payload contains no raw corpus or benchmark rows. Bound retained
        // chart boards when users inspect many models and range combinations.
        if detailOrder.count > 16 { details.removeValue(forKey: detailOrder.removeFirst()) }
        return value
    }
    private func derived(range: Int, source: String, now: Double) -> StatisticsDerived {
        prepareQueryDay(now: now)
        let key = "\(source):\(range):\(statisticsDay(now, calendar: calendar))"
        if let fold = folds[key] { return fold }
        let fold = StatisticsFold.sources(events, range: range, cache: cache, source: source, now: now, calendar: calendar)
        folds[key] = fold; return fold
    }
    private func collectNativeStreamTimings() async {
        guard !stopping, !Task.isCancelled else { return }
        if refreshNativeStreamTimings() { await runtime.events.publish("stats.scanned", scan) }
    }
    private func refreshNativeStreamTimings() -> Bool {
        // A complete corpus generation owns publication. Never interfere with
        // its cache consistency checks or expose partially folded records.
        guard loaded, scanTask == nil else { return false }
        let file = runtime.paths.data.appendingPathComponent("statistics/stream-timings.jsonl")
        var info = stat()
        let exists = lstat(file.path, &info) == 0
        guard exists || errno == ENOENT else { return false }
        let signature = exists
            ? "\(info.st_dev):\(info.st_ino):\(info.st_size):\(info.st_mtimespec.tv_sec):\(info.st_mtimespec.tv_nsec):\(info.st_ctimespec.tv_sec):\(info.st_ctimespec.tv_nsec)" : "absent"
        guard signature != streamTimingSignature || streamTimingGeneration != generation else { return false }
        guard let fresh = try? NativeCodexStreamTimings.readSnapshot(paths: runtime.paths) else { return false }
        // Load the bounded durable tail once, then merge only changed journals.
        // Persist observations before matching: transcripts may not exist yet.
        let stored: [String: NativeCodexStreamTimingObservation]
        do { stored = try streamTimingObservations ?? StatisticsNativeStreamTiming.stored(runtime) }
        catch { return false }
        var observations = stored
        let additions = fresh.filter { observations[$0.key] != $0.value }
        observations.merge(additions) { _, next in next }
        observations = StatisticsNativeStreamTiming.bounded(observations)
        let saved = (try? StatisticsNativeStreamTiming.save(additions, runtime: runtime)) != nil
        guard saved else { return false }
        streamTimingObservations = observations
        var changed = false
        for index in events.indices where events[index].source == "codex" {
            let original = events[index]
            guard let observation = observations[original.id],
                  let measured = StatisticsNativeStreamTiming.applying(observation, to: original) else { continue }
            if original.streamDurationMs != measured.streamDurationMs || original.streamOutputTokens != measured.streamOutputTokens || original.streamTiming != measured.streamTiming {
                events[index] = measured; changed = true
            }
        }
        // Optional measurement storage cannot make historical usage disappear
        // or turn a valid Statistics response into a failure.
        if changed { generation += 1; clearQueries() }
        if saved { streamTimingSignature = signature; streamTimingGeneration = generation }
        return changed
    }
    private func overview(range: Int, source: String, now: Double) -> JSONValue {
        prepareQueryDay(now: now)
        let totals: JSONValue
        if let cached = sourceTotals[range] { totals = cached }
        else {
            totals = StatisticsSourceTotals.fold(events, range: range, cache: cache, now: now, calendar: calendar)
            sourceTotals[range] = totals
        }
        var matched = 0, checked = 0
        for (key, value) in cache?.daily ?? [:] { if let raw = rawByDay[key], raw > 0 { checked += 1; if raw == value { matched += 1 } } }
        return ["loaded": true, "scanning": .bool(scanTask != nil), "progress": progress, "scan": scan, "range": .number(Double(range)), "source": .string(source), "derived": derived(range: range, source: source, now: now).json, "sources": totals, "cache": source == "claude" ? cache?.json ?? .null : .null, "dayMatch": ["matched": .number(Double(matched)), "checked": .number(Double(checked))], "colors": colors, "warnings": .array(warnings.map(JSONValue.string))]
    }
    struct File: Sendable, Equatable {
        var url: URL, source: String, mtime: Double, size: Double
        var cachePath: String {
            if source == "codex", url.path.hasSuffix(".jsonl.zst") { return String(url.path.dropLast(4)) }
            if source == "dsh", url.path.hasSuffix(".jsonl.zstd") { return String(url.path.dropLast(5)) }
            return url.path
        }
    }
    // Only ENOENT proves absence. In particular, unreadable directories must
    // never become a complete empty inventory that authorizes cache pruning.
    private static func discoveryMetadata(_ url: URL) throws -> stat? {
        var info = stat()
        guard lstat(url.path, &info) == 0 else {
            let code = errno
            if code == ENOENT { return nil }
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(code), userInfo: [NSFilePathErrorKey: url.path])
        }
        return info
    }
    private static func discoveryMissing(_ error: Error) -> Bool {
        let value = error as NSError
        if value.domain == NSPOSIXErrorDomain { return value.code == Int(ENOENT) }
        if let underlying = value.userInfo[NSUnderlyingErrorKey] as? NSError { return discoveryMissing(underlying) }
        return value.domain == NSCocoaErrorDomain && [NSFileNoSuchFileError, NSFileReadNoSuchFileError].contains(value.code)
    }
    private static func discoverySignature(_ info: stat) -> (mtime: Double, size: Double) {
        (Double(info.st_mtimespec.tv_sec) * 1000 + Double(info.st_mtimespec.tv_nsec) / 1e6, Double(info.st_size))
    }
    // Discovery-only checked variant. Existing optional diskSignature callers
    // keep their contract; a WAL inspection error here aborts the whole scan.
    static func checkedDiscoverySignature(_ url: URL) throws -> (mtime: Double, size: Double)? {
        guard let info = try discoveryMetadata(url), info.st_mode & S_IFMT == S_IFREG else { return nil }
        return discoverySignature(info)
    }
    private func discover() throws -> [File] {
        var files: [File] = []; let fm = FileManager.default
        func walk(_ root: URL, source: String, flat: Bool = false) throws {
            guard let info = try Self.discoveryMetadata(root) else { return }
            guard info.st_mode & S_IFMT == S_IFDIR else { throw NativeFailure("Usage source directory must be a real, unlinked directory: \(root.lastPathComponent)") }
            let entries: [URL]
            do {
                entries = try fm.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isSymbolicLinkKey, .isDirectoryKey, .isRegularFileKey, .contentModificationDateKey, .fileSizeKey], options: [.skipsHiddenFiles])
            } catch {
                // A directory can disappear between lstat and enumeration.
                // Require both the no-such-file error and a fresh absent path;
                // never reinterpret EACCES/EPERM or another error as deletion.
                if Self.discoveryMissing(error), try Self.discoveryMetadata(root) == nil { return }
                throw error
            }
            var inspected: [(url: URL, info: stat)] = []
            for url in entries {
                if let info = try Self.discoveryMetadata(url) { inspected.append((url, info)) }
            }
            var selected = ""
            if source == "zcode" { selected = "db.sqlite" }
            if source == "opencode" {
                if inspected.contains(where: { $0.url.lastPathComponent == "opencode.db" }) { selected = "opencode.db" }
                else {
                    // Filter regular/nonlink candidates before newest-channel
                    // selection. Metadata failures abort instead of losing the
                    // valid pool; verified disappeared entries are omitted.
                    selected = inspected.filter { item in
                        item.url.lastPathComponent.range(of: "^opencode-[a-zA-Z0-9._-]+\\.db$", options: .regularExpression) != nil && item.info.st_mode & S_IFMT == S_IFREG
                    }.max { Self.discoverySignature($0.info).mtime < Self.discoverySignature($1.info).mtime }?.url.lastPathComponent ?? ""
                }
            }
            for item in inspected {
                let url = item.url, type = item.info.st_mode & S_IFMT
                if type == S_IFLNK { continue }
                if type == S_IFDIR && !flat { try walk(url, source: source) }
                else if type == S_IFREG && ((flat && url.lastPathComponent == selected) || (!flat && (source != "dsh" && url.pathExtension == (source == "antigravity" ? "db" : "jsonl") || source == "codex" && url.lastPathComponent.hasSuffix(".jsonl.zst") || source == "dsh" && ["session.jsonl", "session.jsonl.zstd"].contains(url.lastPathComponent)))) {
                    let signature = Self.discoverySignature(item.info)
                    var mtime = signature.mtime, size = signature.size
                    if ["antigravity", "zcode", "opencode"].contains(source), let wal = try Self.checkedDiscoverySignature(URL(fileURLWithPath: url.path + "-wal")) { mtime = max(mtime, wal.mtime); size += wal.size }
                    files.append(File(url: url, source: source, mtime: mtime, size: size))
                }
            }
        }
        let home = runtime.paths.home
        try walk(home.appendingPathComponent(".claude/projects"), source: "claude")
        let codex = environment["CODEX_HOME"].map { URL(fileURLWithPath: $0) } ?? home.appendingPathComponent(".codex")
        try walk(codex.appendingPathComponent("sessions"), source: "codex"); try walk(codex.appendingPathComponent("archived_sessions"), source: "codex")
        for root in ["antigravity", "antigravity-ide", "antigravity-acp"] { try walk(home.appendingPathComponent(".gemini/\(root)/conversations"), source: "antigravity") }
        let zcode = environment["ZCODE_HOME"].map { URL(fileURLWithPath: $0) } ?? home.appendingPathComponent(".zcode")
        try walk(zcode.appendingPathComponent("cli/db"), source: "zcode", flat: true)
        let xdg = environment["XDG_DATA_HOME"].map { URL(fileURLWithPath: $0) } ?? home.appendingPathComponent(".local/share")
        try walk(xdg.appendingPathComponent("opencode"), source: "opencode", flat: true)
        try walk(runtime.paths.statisticsDeepSeekHome(environment: environment).appendingPathComponent("sessions"), source: "dsh")
        // Compression changes representation, not ledger identity. Prefer the
        // active plain sibling during a transition; distant mirrors retain the
        // existing response-ID deduplication and lexical path precedence.
        var selected: [String: File] = [:]
        for file in files {
            if selected[file.cachePath] == nil || selected[file.cachePath]!.url.path != file.cachePath && file.url.path == file.cachePath { selected[file.cachePath] = file }
        }
        return selected.values.sorted { $0.cachePath < $1.cachePath }
    }
    static func diskSignature(_ file: URL) -> (mtime: Double, size: Double)? {
        var info = stat()
        guard lstat(file.path, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG else { return nil }
        // Node's mtimeMs is formed directly from these epoch seconds/nanoseconds.
        // NSDate's different epoch adds a rounding step that invalidated hundreds
        // of unchanged files in the existing cache. Do not relax time precision.
        return (Double(info.st_mtimespec.tv_sec) * 1000 + Double(info.st_mtimespec.tv_nsec) / 1e6, Double(info.st_size))
    }
    private func importCorpus(full: Bool) async throws {
        let begin = clock(), files = try discover()
        var warnings: [String] = []
        let known = try cachedFiles()
        let dataVersion = try runtime.db.query("PRAGMA data_version").first?["data_version"] ?? .null
        let byPath = Dictionary(uniqueKeysWithValues: known.map { (($0["path"] ?? .null).string, $0) })
        let migrationObjects = try runtime.db.query("SELECT type FROM sqlite_master WHERE name='schema_migrations'")
        guard migrationObjects.isEmpty || migrationObjects.count == 1 && migrationObjects.first?["type"] == "table" else { throw NativeFailure("Usage migration metadata must be a table") }
        // Pre-versioned read-only caches have no migration table. An absent
        // journal requires fresh parsing; inspection/query failures still throw.
        let readerMarkers: [JSONObject]
        if migrationObjects.isEmpty { readerMarkers = [] }
        else { readerMarkers = try runtime.db.query("SELECT name FROM schema_migrations WHERE name IN (?,?,?)", ["native-statistics-readers-1", "native-statistics-turn-clocks-1", "stats-streaming-1"]) }
        let nativeReaders = readerMarkers.contains { $0["name"] == "native-statistics-readers-1" }
        let turnClocks = readerMarkers.contains { $0["name"] == "native-statistics-turn-clocks-1" }
        let streamingClocks = readerMarkers.contains { $0["name"] == "stats-streaming-1" }
        let incompleteGeneration = !nativeReaders || known.contains { ($0["mtime"]?.double ?? 0) < 0 || ($0["size"]?.double ?? 0) < 0 }
        let present = Set(files.map { $0.cachePath })
        // Retain only the four most recently modified plain Codex files, not
        // a second parsed copy of the history corpus. Rebuild and reader repair
        // always start afresh; read-only caches cannot commit a matching revision.
        let appendEligible = !full && !runtime.paths.readOnly && !incompleteGeneration && turnClocks && streamingClocks
        let appendPaths = appendEligible ? Set(files.filter { $0.source == "codex" && $0.url.lastPathComponent.hasSuffix(".jsonl") }
            .sorted { $0.mtime == $1.mtime ? $0.cachePath < $1.cachePath : $0.mtime > $1.mtime }
            .prefix(StatisticsCodexAppendCache.maximumFiles).map(\.cachePath)) : []
        codexAppendCache.retain(appendPaths)
        // A read-only legacy cache cannot receive the migration invalidation.
        // Reparse every file together; fresh canonical IDs must never meet old
        // cached IDs from an unchanged mirror in the same published generation.
        // A read-only cache cannot save the turn-clock repair either. Keep
        // reparsing Codex on later refreshes until a writable upgrade completes.
        let todo = files.filter { file in
            let previous = byPath[file.cachePath], sourcePath = previous?["source_path"]?.string ?? ""
            return full || runtime.paths.readOnly && (incompleteGeneration || !turnClocks && file.source == "codex" || !streamingClocks && file.source == "antigravity") || previous?["mtime"]?.double != file.mtime || previous?["size"]?.double != file.size || (sourcePath.isEmpty ? file.cachePath : sourcePath) != file.url.path
        }
        let assemblySchema = appendEligible && codexPublicationEnabled && !appendPaths.isEmpty ? statisticsAssemblySchema() : nil
        let canReuseAssembly = assemblySchema != nil && !todo.isEmpty && loaded && !scanNeedsRebuild
            && known == importedCacheFiles && dataVersion == importedDataVersion && present == Set(byPath.keys)
            && codexPublication?.schema == assemblySchema && codexPublication?.generation == generation
            && todo.allSatisfy { $0.source == "codex" && appendPaths.contains($0.cachePath) }
        var expectedCache = byPath, appendedOffsets: [String: Int] = [:]
        progress["total"] = .number(Double(todo.count))
        if !full, loaded, !scanNeedsRebuild, !incompleteGeneration, turnClocks, streamingClocks, todo.isEmpty, present == Set(byPath.keys), files == importedFiles, known == importedCacheFiles, dataVersion == importedDataVersion {
            // Discovery still checks every source, including directory errors,
            // compression representation changes and SQLite WAL signatures.
            // Compare the inventory to this actor's generation too: another
            // reader may have refreshed stats_files since this actor loaded.
            // A cold load never reuses only the metadata as complete totals.
            let document = try? NativeFile.readJSON(runtime.paths.home.appendingPathComponent(".claude/stats-cache.json"))
            if document == cacheDocument {
                scan["elapsedMs"] = .number(clock() - begin); scan["scannedAt"] = .number(clock()); scan["parsedFiles"] = 0
                scan["codexAppendFiles"] = 0; scan["codexValidatedPrefixBytes"] = 0; scan["codexAppendDecodedBytes"] = 0
                scan["assemblyMode"] = "metadata"; scan["assembledRecords"] = 0
                scan["reusedRecords"] = scan["records"]; scan["codexSQLAppendFiles"] = 0
                scan["scanId"] = progress["scanId"]
                self.warnings = []; lastCheck = clock()
                await publishProgress("reading")
                await publishProgress("folding")
                try Task.checkCancellation()
                await publishScan()
                return
            }
        }
        // A failed import may already have committed individual file rows.
        // Never reuse the older in-memory generation on its next retry merely
        // because those files now match the persisted signatures.
        await publishProgress("reading")
        scanNeedsRebuild = true
        var memory: [(File, StatisticsReadResult)] = [], failedUpgrade = false
        var appendFiles = 0, sqlAppendFiles = 0, validatedBytes: Int64 = 0, decodedBytes: Int64 = 0
        for (index, f) in todo.enumerated() {
            try Task.checkCancellation()
            progress["file"] = .string(f.url.lastPathComponent)
            do {
                // Parsing and SQLite reads execute on this service, never MainActor.
                let append: StatisticsCodexAppendRead?
                if appendPaths.contains(f.cachePath) {
                    // Read the current transaction identity, not just the scan's
                    // earlier inventory: another reader may have committed while
                    // progress publication yielded this actor.
                    let row = try runtime.db.query("SELECT mtime,size,source_path,record_revision FROM stats_files WHERE path=?", [.string(f.cachePath)]).first
                    let checkpoint = codexAppendCache.checkpoint(path: f.cachePath, sourcePath: row?["source_path"]?.string ?? "",
                        revision: row?["record_revision"]?.string ?? "", mtime: row?["mtime"]?.double ?? -1, size: row?["size"]?.double ?? -1)
                    append = try StatisticsCodexAppend.read(f.url, checkpoint: checkpoint)
                } else { append = nil }
                let result: StatisticsReadResult
                if let append { result = append.result }
                else { result = try StatisticsImporter.read(f.url, source: f.source) }
                if runtime.paths.readOnly { memory.append((f, result)) }
                else {
                    let revision = UUID().uuidString
                    var ordered = false, appendedOffset: Int?
                    // The fixture seam can commit through a second connection
                    // after prefix validation. The real guard belongs inside
                    // BEGIN IMMEDIATE, where another writer can no longer race it.
                    if canReuseAssembly { try beforeCodexCommit(runtime) }
                    try runtime.db.transaction {
                        let current = canReuseAssembly ? try runtime.db.query("SELECT path,mtime,size,source_path,record_revision FROM stats_files WHERE path=?", [.string(f.cachePath)]).first : nil
                        if canReuseAssembly, let schema = assemblySchema, statisticsAssemblySchema() == schema,
                           try runtime.db.query("PRAGMA data_version").first?["data_version"] == dataVersion,
                           current == byPath[f.cachePath], let offset = append?.appendedRecordOffset,
                           let oldRevision = current?["record_revision"]?.string,
                           codexAppendCache.hasOrderedRows(path: f.cachePath, revision: oldRevision, schema: schema),
                           try statisticsRowHeadroom(result.records.count - offset),
                           try runtime.db.query("SELECT COUNT(*) AS n FROM stats_records WHERE path=?", [.string(f.cachePath)]).first?["n"]?.int == offset {
                            // The decoded old prefix and its committed row order
                            // are proven unchanged. Do not rewrite those rows.
                            try insertRecords(Array(result.records.dropFirst(offset)), path: f.cachePath)
                            ordered = true; appendedOffset = offset
                        } else {
                            try runtime.db.execute("DELETE FROM stats_records WHERE path=?", [.string(f.cachePath)])
                            if append != nil, let schema = assemblySchema, statisticsAssemblySchema() == schema {
                                ordered = try statisticsRowHeadroom(result.records.count)
                            }
                            try insertRecords(result.records, path: f.cachePath)
                        }
                        try runtime.db.execute("INSERT INTO stats_files(path,mtime,size,excluded_usage,source_path,record_revision) VALUES (?,?,?,?,?,?) ON CONFLICT(path) DO UPDATE SET mtime=excluded.mtime,size=excluded.size,excluded_usage=excluded.excluded_usage,source_path=excluded.source_path,record_revision=excluded.record_revision", [.string(f.cachePath), .number(f.mtime), .number(f.size), .number(Double(result.excluded)), .string(f.url.path), .string(revision)])
                        if canReuseAssembly {
                            expectedCache[f.cachePath] = try runtime.db.query("SELECT path,mtime,size,source_path,record_revision FROM stats_files WHERE path=?", [.string(f.cachePath)]).first
                        }
                    }
                    if let appendedOffset { appendedOffsets[f.cachePath] = appendedOffset; sqlAppendFiles += 1 }
                    if let append {
                        codexAppendCache.commit(append.checkpoint, path: f.cachePath, sourcePath: f.url.path,
                                                revision: revision, mtime: f.mtime, size: f.size, rowOrderSchema: ordered ? assemblySchema : nil)
                        if append.validatedPrefixBytes > 0 { appendFiles += 1 }
                        validatedBytes += append.validatedPrefixBytes; decodedBytes += append.decodedBytes
                    }
                }
            } catch {
                if error is CancellationError { throw error }
                warnings.append("\(f.source): \(f.url.lastPathComponent): \(error.localizedDescription)")
                if incompleteGeneration || !turnClocks && f.source == "codex" || !streamingClocks && f.source == "antigravity" { failedUpgrade = true }
            }
            progress["done"] = .number(Double(index + 1))
            if (index + 1) % 5 == 0 || index + 1 == todo.count { await publishProgress("reading") }
        }
        // Mixing old fallback IDs with successfully upgraded copies can bill a
        // duplicate twice. Keep the last complete published generation until
        // all invalidated files have reparsed; failed signatures remain stale.
        guard !failedUpgrade else { throw NativeFailure("Usage cache upgrade is incomplete; retry after unavailable source files become readable. No mixed reader generation was published.") }
        await publishProgress("assembling")
        if !runtime.paths.readOnly {
            try runtime.db.transaction { for path in byPath.keys where !present.contains(path) { try runtime.db.execute("DELETE FROM stats_records WHERE path=?", [.string(path)]); try runtime.db.execute("DELETE FROM stats_files WHERE path=?", [.string(path)]) } }
        }
        let cacheFilesBeforeRead = try cachedFiles()
        let dataVersionBeforeRead = try runtime.db.query("PRAGMA data_version").first?["data_version"] ?? .null
        var nextEvents: [StatisticsUsage] = [], nextPublication: StatisticsAppendPublication?
        var recordCount = 0, duplicates = 0, rawGrand: Double = 0, raw: [String: Double] = [:]
        var reusedAssembly = false, assembledRecords = 0
        if canReuseAssembly, warnings.isEmpty, appendedOffsets.count == todo.count,
           cacheFilesBeforeRead == expectedCache.values.sorted(by: { ($0["path"] ?? .null).string.utf8.lexicographicallyPrecedes(($1["path"] ?? .null).string.utf8) }),
           dataVersionBeforeRead == dataVersion, var candidate = codexPublication,
           candidate.generation == generation, statisticsAssemblySchema() == candidate.schema {
            var tail: [StatisticsUsage] = [], admitted = true
            // SQL bytewise path order precedes its original per-file row order.
            // All admitted timestamps are strictly after the old global maximum.
            for f in todo.sorted(by: { $0.cachePath.utf8.lexicographicallyPrecedes($1.cachePath.utf8) }) {
                guard let offset = appendedOffsets[f.cachePath] else { admitted = false; break }
                var columns = StatisticsCachedRecordColumns([]), count = 0
                try runtime.db.forEachValueRow("SELECT * FROM stats_records WHERE path=? ORDER BY rowid LIMIT -1 OFFSET ?",
                    [.string(f.cachePath), .number(Double(offset))], columns: { columns = StatisticsCachedRecordColumns($0) }) { values in
                    count += 1
                    guard admitted, let row = candidate.admit(columns.usage(in: values), path: f.cachePath, after: events.last?.ts ?? -.infinity) else { admitted = false; return }
                    tail.append(row)
                }
                let expectedCount = try runtime.db.query("SELECT COUNT(*) AS n FROM stats_records WHERE path=?", [.string(f.cachePath)]).first?["n"]?.int ?? -1
                if count != expectedCount - offset { admitted = false }
                if !admitted { break }
            }
            if admitted {
                nextEvents = events; nextEvents.append(contentsOf: tail.sorted { $0.ts < $1.ts })
                raw = rawByDay; rawGrand = scan["rawGrand"].double; duplicates = scan["duplicates"].int
                recordCount = scan["records"].int + tail.count; assembledRecords = tail.count
                nextPublication = candidate; reusedAssembly = true
            }
        }
        if !reusedAssembly {
            var rows: [StatisticsUsage] = [], seen = Set<String>()
            let replacements = Dictionary(uniqueKeysWithValues: memory.map { ($0.0.cachePath, $0.1.records) })
            let replacementPaths = replacements.keys.sorted { $0.utf8.lexicographicallyPrecedes($1.utf8) }
            var replacementIndex = 0, interned: [String: String] = [:]
            var origins = StatisticsInternerOrigins(enabled: assemblySchema != nil)
            func intern(_ value: String, path: String) -> String {
                guard value.utf8.count > 15 else { return value }
                if let existing = interned[value] { return existing }
                interned[value] = value
                origins.note(value, representative: value, path: path)
                return value
            }
            func consume(_ record: StatisticsUsage, path: String) {
                var e = record
                recordCount += 1
                if e.source == "claude" { rawGrand += e.grand; let key = e.rawDay.isEmpty ? statisticsUTC(e.ts) : e.rawDay; raw[key, default: 0] += e.grand }
                if !seen.insert(e.source + ":" + e.id).inserted { if e.source == "claude" { duplicates += 1 }; return }
                e.model = intern(e.model, path: path); e.project = intern(e.project, path: path)
                e.session = intern(e.session, path: path); e.effort = intern(e.effort, path: path)
                rows.append(e)
            }
            func flushReplacements(through path: String?) {
                while replacementIndex < replacementPaths.count {
                    let next = replacementPaths[replacementIndex]
                    if let path, path.utf8.lexicographicallyPrecedes(next.utf8) { break }
                    for record in replacements[next] ?? [] { consume(record, path: next) }
                    replacementIndex += 1
                }
            }
            // Preserve the established dedup/interner order in the fallback.
            var columns = StatisticsCachedRecordColumns([])
            try runtime.db.forEachValueRow("SELECT * FROM stats_records ORDER BY path,rowid", columns: { columns = StatisticsCachedRecordColumns($0) }) { values in
                let path = columns.path(in: values)
                flushReplacements(through: path)
                guard present.contains(path), replacements[path] == nil else { return }
                consume(columns.usage(in: values), path: path)
            }
            flushReplacements(through: nil)
            nextEvents = rows.sorted { $0.ts < $1.ts }; assembledRecords = recordCount
            if let schema = assemblySchema, nextEvents.allSatisfy({ $0.ts.isFinite }) {
                nextPublication = StatisticsAppendPublication(keys: seen, origins: origins, schema: schema)
            }
        }
        let nextDocument = try? NativeFile.readJSON(runtime.paths.home.appendingPathComponent(".claude/stats-cache.json"))
        let nextCache = nextDocument.flatMap(StatisticsCache.parse)
        var weights: [String: Double] = [:]; for e in nextEvents { weights[e.model, default: 0] += e.grand }; for (name, total) in nextCache?.perModel ?? [:] where weights[name] == nil { weights[name] = total.grand }
        let palette = ["#3b82f6", "#f97316", "#10b981", "#a855f7", "#f59e0b", "#ec4899", "#06b6d4", "#84cc16", "#ef4444", "#6366f1", "#d946ef", "#eab308"]
        let nextColors = JSONValue.object(Dictionary(uniqueKeysWithValues: weights.keys.sorted { weights[$0] == weights[$1] ? $0 < $1 : weights[$0]! > weights[$1]! }.enumerated().map { ($0.element, .string(palette[$0.offset % palette.count])) }))
        var nextScan: JSONValue = ["files": .number(Double(files.count)), "bytes": .number(files.reduce(0) { $0 + $1.size }), "elapsedMs": .number(clock() - begin), "scannedAt": .number(clock()), "rawGrand": .number(rawGrand), "duplicates": .number(Double(duplicates)), "records": .number(Double(recordCount)), "claudeFiles": .number(Double(files.filter { $0.source == "claude" }.count)), "parsedFiles": .number(Double(todo.count))]
        nextScan["scanId"] = progress["scanId"]
        nextScan["assemblyMode"] = .string(reusedAssembly ? "append" : "full")
        nextScan["assembledRecords"] = .number(Double(assembledRecords))
        nextScan["reusedRecords"] = .number(Double(reusedAssembly ? scan["records"].int : 0))
        nextScan["codexSQLAppendFiles"] = .number(Double(sqlAppendFiles))
        nextScan["codexAppendFiles"] = .number(Double(appendFiles))
        nextScan["codexValidatedPrefixBytes"] = .number(Double(validatedBytes))
        nextScan["codexAppendDecodedBytes"] = .number(Double(decodedBytes))
        let excludedRows = try runtime.db.query("SELECT path,excluded_usage FROM stats_files")
        var excluded = Dictionary(uniqueKeysWithValues: excludedRows.map { (($0["path"] ?? .null).string, ($0["excluded_usage"] ?? 0).int) })
        for (file, result) in memory { excluded[file.cachePath] = result.excluded }
        for s in StatisticsSource.allCases where s != .claude { nextScan[s.rawValue + "Excluded"] = .number(Double(files.filter { $0.source == s.rawValue }.reduce(0) { $0 + (excluded[$1.cachePath] ?? 0) })) }
        // Yield before the final consistency reads, never between their guard
        // and generation replacement. A reader still sees the old complete board.
        await publishProgress("folding")
        // All throwing reads finish before replacing any published generation
        // state or invalidating its query boards. Failures keep the old totals.
        try Task.checkCancellation()
        let cacheFilesAfterRead = try cachedFiles()
        let dataVersionAfterRead = try runtime.db.query("PRAGMA data_version").first?["data_version"] ?? .null
        guard cacheFilesBeforeRead == cacheFilesAfterRead, dataVersionBeforeRead == dataVersionAfterRead else { throw NativeFailure("Usage cache changed during publication; retry the read.") }
        if reusedAssembly, statisticsAssemblySchema() != assemblySchema { throw NativeFailure("Usage cache schema changed during publication; retry the read.") }
        events = nextEvents; rawByDay = raw; cache = nextCache; cacheDocument = nextDocument; importedFiles = files
        importedCacheFiles = cacheFilesAfterRead; importedDataVersion = dataVersionAfterRead
        colors = nextColors; scan = nextScan; self.warnings = warnings
        generation += 1; clearQueries(); loaded = true; scanNeedsRebuild = false; lastCheck = clock()
        nextPublication?.generation = generation; codexPublication = nextPublication
        await publishScan()
    }
    /// A rowid proof is tied to both schema journals. Temporary triggers can
    /// affect this connection too; an unknown layout only disables the shortcut.
    private func statisticsAssemblySchema() -> String? {
        // Capability inspection is optional. Failure disables reuse; ordinary
        // reads and their existing error handling remain authoritative.
        do {
            guard try runtime.db.query("SELECT name FROM sqlite_temp_master WHERE lower(name) IN ('stats_records','stats_files')").isEmpty else { return nil }
            let objects = try runtime.db.query("SELECT type,sql FROM sqlite_master WHERE name IN ('stats_records','stats_files')")
            guard objects.count == 2, objects.allSatisfy({ $0["type"] == "table" && !($0["sql"]?.string.uppercased().contains("WITHOUT ROWID") ?? true) }),
                  runtime.db.hasBinaryCollation(table: "stats_records", column: "path") else { return nil }
            let columns = try runtime.db.query("PRAGMA main.table_xinfo(stats_records)")
            guard !columns.contains(where: { ($0["pk"]?.int ?? 0) != 0 || ["rowid", "_rowid_", "oid"].contains(($0["name"] ?? .null).string.lowercased()) }) else { return nil }
            let triggers = try runtime.db.query("SELECT name FROM sqlite_master WHERE type='trigger' AND lower(tbl_name) IN ('stats_records','stats_files') UNION ALL SELECT name FROM sqlite_temp_master WHERE type='trigger' AND lower(tbl_name) IN ('stats_records','stats_files')")
            guard triggers.isEmpty else { return nil }
            let main = try runtime.db.query("PRAGMA main.schema_version").first?["schema_version"]?.int
            let temporary = try runtime.db.query("PRAGMA temp.schema_version").first?["schema_version"]?.int
            guard let main, let temporary else { return nil }
            return "\(main):\(temporary)"
        } catch { return nil }
    }
    private func statisticsRowHeadroom(_ count: Int) throws -> Bool {
        // INTEGER -> JSON number rounds through Double. Text preserves MAX's
        // exact signed boundary and prevents SQLite's random-rowid fallback.
        let text = try runtime.db.query("SELECT COALESCE(CAST(MAX(rowid) AS TEXT),'0') AS largest FROM stats_records").first?["largest"]?.string ?? ""
        guard let largest = Int64(text), largest >= 0, count >= 0, let n = Int64(exactly: count) else { return false }
        return largest <= Int64.max - n
    }
    private func insertRecords(_ records: [StatisticsUsage], path: String) throws {
        // Bound to 704 variables, below SQLite's historical 999-variable limit.
        // Keep one file transaction and original row order/dedup precedence,
        // amortizing SQL preparation across response rows.
        let prefix = "INSERT INTO stats_records(path,msg_id,ts,raw_day,model,project,session,sidechain,effort,input,output,thinking,cache_write,cache_read,web_search,web_fetch,source,duration_ms,timing,stream_duration_ms,stream_output_tokens,stream_timing) VALUES "
        let tuple = "(?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)"
        for start in stride(from: 0, to: records.count, by: 32) {
            let end = min(start + 32, records.count)
            var values: [JSONValue] = []; values.reserveCapacity((end - start) * 22)
            for e in records[start..<end] {
                values += [.string(path), .string(e.id), .number(e.ts), .string(e.rawDay.isEmpty ? statisticsUTC(e.ts) : e.rawDay), .string(e.model), .string(e.project), .string(e.session), .number(e.sidechain ? 1 : 0), .string(e.effort), .number(e.input), .number(e.output), .number(e.thinking), .number(e.cacheWrite), .number(e.cacheRead), .number(e.webSearch), .number(e.webFetch), .string(e.source), statisticsOptional(e.durationMs), e.timing.map(JSONValue.string) ?? .null, statisticsOptional(e.streamDurationMs), statisticsOptional(e.streamOutputTokens), e.streamTiming.map(JSONValue.string) ?? .null]
            }
            try runtime.db.execute(prefix + Array(repeating: tuple, count: end - start).joined(separator: ","), values)
        }
    }
    private func publishScan() async {
        let now = clock()
        // Publish only a complete generation, including Claude lifetime
        // reconciliation. Readers never observe a partially reparsed corpus.
        let complete = publicationTotals(now: now)
        publishedSummary.replace(["loaded": true, "loading": false, "scanning": false, "provenance": "corpus", "readerGeneration": "native", "grand": .number(complete.totals.grand), "models": .number(Double(complete.models)), "responses": .number(complete.totals.messages)])
        // The scanned-event page load can supersede the awaiting manual reload.
        // Invalidate before yielding so a restored ledger with the same size
        // and mtime is reread alongside the newly committed usage.
        benchSignature = ""
        await runtime.cache.invalidate("statistics:\(ObjectIdentifier(runtime)):")
        await runtime.cache.invalidate("hub:summaries")
        await publishProgress("complete")
        await runtime.events.publish("stats.scanned", scan)
    }
    private func readBench() throws -> [JSONValue] {
        let urls = [runtime.paths.data.appendingPathComponent("results.jsonl"), runtime.paths.bench.appendingPathComponent("results/results.jsonl")]
        let signature = urls.map { url -> String in let info = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey]); return "\(url.path):\(info?.fileSize ?? -1):\(info?.contentModificationDate?.timeIntervalSince1970 ?? -1)" }.joined(separator: "|")
        if signature == benchSignature { return benchRows }
        var rows: [JSONValue] = [], seen = Set<String>()
        for url in urls where FileManager.default.fileExists(atPath: url.path) {
            try StatisticsImporter.lines(url) { r in
                guard case .object = r else { return }
                let key = !r["id"].string.isEmpty ? "id:" + r["id"].string : "record:" + SHA256.hash(data: (try? r.encoded()) ?? Data()).map { String(format: "%02x", $0) }.joined()
                // Statistics needs spend and per-run latency, not token-arrival
                // curves or raw response headers. Hash the complete row before
                // projection so historical ID-less dedup semantics stay exact.
                if seen.insert(key).inserted {
                    let fields = ["provider", "provider_name", "model", "target", "run_id", "ts", "ok", "tokens", "test", "timing_ms"]
                    rows.append(.object(Dictionary(uniqueKeysWithValues: fields.compactMap { field in r.object[field].map { (field, $0) } })))
                }
            }
        }
        benchRows = rows.sorted { $0["ts"].string < $1["ts"].string }; benchSignature = signature; return benchRows
    }
    private func benchmark(model: String?, range: Int, now: Double? = nil) throws -> JSONValue {
        let cutoff = statisticsDay(now ?? clock(), calendar: calendar) - Double(range - 1) * 86_400_000
        var totals: [String: Double] = ["input": 0, "output": 0, "reasoning": 0, "cached": 0, "calls": 0, "estimated": 0]
        var pairs: [String: JSONValue] = [:], runs = Set<String>(), first: String?, last: String?
        var trend: [String: (ts: Double, label: String, key: String, run: String, ms: [Double])] = [:]
        for r in try readBench() {
            let provider = r["provider"].string, name = r["model"].string.isEmpty ? r["target"].string : r["model"].string
            if provider.isEmpty || name.isEmpty || (model != nil && model != name) { continue }
            let clock = StatisticsBenchmarkClock(r, range: range)
            if range > 0 && (clock.timestamp == nil || clock.timestamp! < cutoff) { continue }
            let key = provider + "|" + name, tok = r["tokens"], input = statisticsNumber(tok["in"]), output = statisticsNumber(tok["out"])
            if input > 0 || output > 0 {
                var p = pairs[key] ?? ["key": .string(key), "provider": .string(provider), "providerName": .string(r["provider_name"].string.isEmpty ? provider : r["provider_name"].string), "model": .string(name)]
                let values: [String: Double] = ["input": input, "output": output, "reasoning": statisticsNumber(tok["reasoning"]), "cached": statisticsNumber(tok["cached"]), "calls": 1, "estimated": tok["in_est"].bool || tok["out_est"].bool ? 1 : 0]
                for (field, value) in values { totals[field, default: 0] += value; p[field] = .number(p[field].double + value) }; pairs[key] = p
                if !r["run_id"].string.isEmpty { runs.insert(r["run_id"].string) }
                let stamp = r["ts"].string; if !stamp.isEmpty { first = min(first ?? stamp, stamp); last = max(last ?? stamp, stamp) }
            }
            if let ms = clock.latencyMs, let at = clock.timestamp {
                let run = r["run_id"].string, group = key + "@" + run
                var bucket = trend[group] ?? (at, "\(name.split(separator: "/").last ?? Substring(name)) · \(r["provider_name"].string.isEmpty ? provider : r["provider_name"].string)", key, run, [])
                bucket.ts = min(bucket.ts, at); bucket.ms.append(ms); trend[group] = bucket
            }
        }
        var spend = JSONValue.object(totals.mapValues(JSONValue.number)); spend["runs"] = .number(Double(runs.count)); spend["first"] = first.map(JSONValue.string) ?? .null; spend["last"] = last.map(JSONValue.string) ?? .null
        spend["pairs"] = .array(pairs.values.sorted { $0["input"].double + $0["output"].double > $1["input"].double + $1["output"].double })
        let points: [JSONValue] = trend.values.map { b in let sorted = b.ms.sorted(), n = sorted.count; let median = n % 2 == 0 ? (sorted[n / 2 - 1] + sorted[n / 2]) / 2 : sorted[n / 2]; return ["runId": .string(b.run), "key": .string(b.key), "label": .string(b.label), "at": .number(b.ts), "ms": .number(median), "samples": .number(Double(n))] }.sorted { $0["at"].double == $1["at"].double ? $0["key"].string < $1["key"].string : $0["at"].double < $1["at"].double }
        return ["spend": spend, "trend": .array(points)]
    }
    private func dailyCSV(_ detail: JSONValue, model: String, source: String) -> String {
        let fields = ["input", "output", "thinking", "cacheWrite", "cacheRead", "messages", "webSearch", "webFetch"]
        let quote = { (s: String) in "\"" + s.replacingOccurrences(of: "\"", with: "\"\"") + "\"" }
        var rows = [(["date", "model", "source"] + fields + ["response_avg_tps", "timed_responses", "timed_output", "response_ms", "estimated_responses", "streaming_tps", "stream_timed_responses", "stream_output", "stream_ms"]).joined(separator: ",")]
        for day in detail["derived"]["days"].array {
            let speed = detail["derived"]["throughput"]["days"].array.first { $0["day"] == day["day"] }?["models"][model] ?? .null
            let stream = detail["derived"]["throughput"]["streaming"]["days"].array.first { $0["day"] == day["day"] }?["models"][model] ?? .null
            let values = [statisticsDayKey(day["day"].double, calendar: calendar), quote(model), source] + fields.map { day["totals"][$0].string } + [speed["avgTps"].isNull ? "" : speed["avgTps"].string, speed["timedResponses"].isNull ? "0" : speed["timedResponses"].string, speed["outputTokens"].isNull ? "0" : speed["outputTokens"].string, speed["durationMs"].isNull ? "0" : speed["durationMs"].string, speed["estimatedResponses"].isNull ? "0" : speed["estimatedResponses"].string, stream["avgTps"].isNull ? "" : stream["avgTps"].string, stream["timedResponses"].isNull ? "0" : stream["timedResponses"].string, stream["outputTokens"].isNull ? "0" : stream["outputTokens"].string, stream["durationMs"].isNull ? "0" : stream["durationMs"].string]
            rows.append(values.joined(separator: ","))
        }
        return rows.joined(separator: "\n")
    }
}

/// The actor may be busy parsing or rebuilding its cache. Home reads this
/// immutable value through a short lock instead of joining that actor's queue.
private final class StatisticsPublishedSummary: @unchecked Sendable {
    private let lock = NSLock()
    private let queue: DispatchQueue
    private let load: @Sendable (NativeRuntime, Double) throws -> JSONValue
    private let bootstrapWork = DispatchGroup()
    private var value: JSONValue = ["loaded": false, "loading": false, "scanning": false, "provenance": "none"]
    private var bootstrapStarted = false, revision = 0
    private var bootstrapRunning: Int?
    private var initialOwner: UUID?
    private var stopped = false
    init(queue: DispatchQueue = .global(qos: .utility),
         load: @escaping @Sendable (NativeRuntime, Double) throws -> JSONValue = { try StatisticsSummaryBootstrap.load(runtime: $0, now: $1) }) {
        self.queue = queue; self.load = load
    }
    func read() -> JSONValue { lock.lock(); defer { lock.unlock() }; return value }
    func replace(_ next: JSONValue) { lock.lock(); revision += 1; value = next; lock.unlock() }
    func reserveInitial() -> UUID? {
        lock.lock(); defer { lock.unlock() }
        guard !stopped, initialOwner == nil, value["provenance"] != "corpus" else { return nil }
        let token = UUID(); initialOwner = token
        if bootstrapStarted, bootstrapRunning == nil {
            // A queued fallback must recheck this ticket before snapshot I/O.
            revision += 1; bootstrapStarted = false
        }
        value["loading"] = true
        return token
    }
    func ownsInitial(_ token: UUID) -> Bool { lock.lock(); defer { lock.unlock() }; return !stopped && initialOwner == token }
    @discardableResult func finishInitial(_ token: UUID, error: String? = nil) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard !stopped, initialOwner == token else { return false }
        initialOwner = nil
        if value["provenance"] != "corpus" {
            value["loading"] = false
            if let error { value["error"] = .string(error) }
        }
        return true
    }
    func stop() {
        lock.lock(); defer { lock.unlock() }
        stopped = true; revision += 1; initialOwner = nil; value["loading"] = false
    }
    func drainBootstrap() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            bootstrapWork.notify(queue: .global(qos: .utility)) { continuation.resume() }
        }
    }
    func bootstrap(runtime: NativeRuntime, clock: @escaping @Sendable () -> Double) {
        lock.lock()
        guard !stopped, initialOwner == nil, !bootstrapStarted, value["provenance"] != "corpus" else { lock.unlock(); return }
        bootstrapStarted = true; let ticket = revision; value["loading"] = true
        bootstrapWork.enter()
        lock.unlock()
        // SQLite iteration and reconciliation are synchronous work. Keep them
        // off both the scan actor and Swift's cooperative executor.
        queue.async {
            guard self.beginBootstrap(ticket: ticket) else { self.bootstrapWork.leave(); return }
            let next: JSONValue
            do { next = try self.load(runtime, clock()) }
            catch { next = ["loaded": false, "loading": false, "provenance": "none", "cacheStatus": "unavailable", "cacheError": .string(error.localizedDescription)] }
            guard self.finishBootstrap(next, ticket: ticket) else { self.bootstrapWork.leave(); return }
            Task {
                defer { self.bootstrapWork.leave() }
                guard self.canNotifyBootstrap(ticket: ticket) else { return }
                await runtime.cache.invalidate("hub:summaries")
                guard self.canNotifyBootstrap(ticket: ticket) else { return }
                await runtime.events.publish("stats.cached", self.read())
            }
        }
    }
    private func beginBootstrap(ticket: Int) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard !stopped, initialOwner == nil, revision == ticket else { return false }
        bootstrapRunning = ticket
        return true
    }
    private func canNotifyBootstrap(ticket: Int) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return !stopped && revision == ticket
    }
    private func finishBootstrap(_ next: JSONValue, ticket: Int) -> Bool {
        lock.lock(); defer { lock.unlock() }
        if bootstrapRunning == ticket { bootstrapRunning = nil }
        guard !stopped, revision == ticket else { return false }
        var complete = next
        complete["loading"] = false; complete["scanning"] = value["scanning"]
        if !value["error"].isNull { complete["error"] = value["error"] }
        value = complete
        return true
    }
    func scanning(_ active: Bool, error: String? = nil) {
        lock.lock(); defer { lock.unlock() }
        var next = value; next["scanning"] = .bool(active)
        next = .object(next.object.filter { $0.key != "error" })
        if let error { next["error"] = .string(error) }
        value = next
    }
}

private final class StatisticsServicePool: @unchecked Sendable {
    private let lock = NSLock()
    private final class Reference {
        weak var value: NativeStatisticsService?
        init(_ value: NativeStatisticsService) { self.value = value }
    }
    private var services: [ObjectIdentifier: Reference] = [:]
    func service(_ runtime: NativeRuntime) -> NativeStatisticsService {
        lock.lock(); defer { lock.unlock() }
        let key = ObjectIdentifier(runtime)
        if let service = services[key]?.value { return service }
        services = services.filter { $0.value.value != nil }
        let service = NativeStatisticsService(runtime: runtime); services[key] = Reference(service); return service
    }
}
