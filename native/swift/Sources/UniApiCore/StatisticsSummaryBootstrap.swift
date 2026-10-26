import Foundation
import Darwin

/// Home reads one persisted reader generation, never a mixture of cached rows
/// and freshly parsed files. The single SELECT pins rows and migration metadata
/// to the same SQLite snapshot. Only the three Home totals are retained.
enum StatisticsSummaryBootstrap {
    static func load(runtime: NativeRuntime, now: Double) throws -> JSONValue {
        // An independent private connection avoids holding the runtime's shared
        // database lock across the cached-row iteration. Home's other domains
        // stay responsive and all SQLite sidecars belong to this private copy.
        let snapshot = try SQLiteSnapshotCore(runtime.paths.database)
        defer { withExtendedLifetime(snapshot) {} }
        let db = try NativeDatabase(url: snapshot.database, readOnly: true)
        let tables = try db.query("SELECT name FROM sqlite_master WHERE name IN ('stats_records','stats_files')")
        let names = Set(tables.compactMap { $0["name"]?.string })
        let lifetime = try claudeCache(runtime.paths.home)
        var seen = Set<String>(), models = Set<String>(), sources = Set<String>()
        var claude = StatisticsTotals(), others = StatisticsTotals(), fresh = StatisticsTotals()
        var readerGeneration = "none", files = 0
        let watermark = lifetime.flatMap { $0.computedOn.count == 10 && statisticsDate($0.computedOn, utc: true) != nil ? $0.computedOn : nil }
        if names.contains("stats_records"), names.contains("stats_files") {
            try db.forEachRow("""
            SELECT r.path,r.msg_id,r.source,r.ts,r.model,r.input,r.output,r.cache_write,r.cache_read,
                   r.rowid IS NOT NULL AS has_record,
                   (SELECT COUNT(*) FROM stats_files) AS cache_files,
                   (SELECT COUNT(*) FROM stats_files WHERE mtime<0 OR size<0) AS invalid_files,
                   EXISTS(SELECT 1 FROM schema_migrations WHERE name='native-statistics-readers-1') AS native_readers
            FROM (SELECT 1) LEFT JOIN stats_records r ON 1=1
            ORDER BY r.path COLLATE BINARY,r.rowid
            """) { row in
                guard (row["invalid_files"] ?? 0).int == 0 else { throw NativeFailure("Cached usage is awaiting a complete reader upgrade") }
                files = (row["cache_files"] ?? 0).int
                readerGeneration = (row["native_readers"] ?? 0).int == 1 ? "native" : "legacy"
                guard (row["has_record"] ?? 0).int == 1 else { return }
                let source = (row["source"] ?? .null).string
                guard seen.insert(source + ":" + (row["msg_id"] ?? .null).string).inserted else { return }
                var usage = StatisticsUsage(id: "", source: source, ts: (row["ts"] ?? 0).double, model: (row["model"] ?? .null).string)
                usage.input = (row["input"] ?? 0).double; usage.output = (row["output"] ?? 0).double
                usage.cacheWrite = (row["cache_write"] ?? 0).double; usage.cacheRead = (row["cache_read"] ?? 0).double
                models.insert(usage.model); sources.insert(source)
                if source == "claude" {
                    claude.add(usage)
                    if let watermark, statisticsUTC(usage.ts) > watermark { fresh.add(usage) }
                } else { others.add(usage) }
            }
        } else if !names.isEmpty {
            throw NativeFailure("Cached usage schema is incomplete")
        }
        if let lifetime {
            claude = lifetime.totals; claude.messages = lifetime.messages
            if watermark != nil { claude.addReported(fresh); claude.messages += fresh.messages }
            models.formUnion(lifetime.perModel.keys); sources.insert("claude")
        }
        guard files > 0 || !seen.isEmpty || lifetime != nil else {
            return ["loaded": false, "loading": false, "provenance": "none", "cacheStatus": "empty"]
        }
        return ["loaded": true, "loading": false, "provenance": "cache", "readerGeneration": .string(readerGeneration),
                "cacheFiles": .number(Double(files)), "cacheReadAt": .number(now), "cachedSources": .array(sources.sorted().map(JSONValue.string)),
                "grand": .number(claude.grand + others.grand), "models": .number(Double(models.count)),
                "responses": .number(claude.messages + others.messages)]
    }
    private static func claudeCache(_ home: URL) throws -> StatisticsCache? {
        let file = home.appendingPathComponent(".claude/stats-cache.json")
        let fd = open(file.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        if fd < 0 { if errno == ENOENT { return nil }; throw NativeFailure("Claude lifetime cache is unavailable or linked") }
        defer { close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_size >= 0, info.st_size <= 16 * 1024 * 1024 else { throw NativeFailure("Claude lifetime cache must be a bounded regular file") }
        var data = Data(), bytes = [UInt8](repeating: 0, count: 65536)
        while true {
            let count = Darwin.read(fd, &bytes, bytes.count)
            if count == 0 { break }; if count < 0 && errno == EINTR { continue }
            guard count > 0, data.count + count <= 16 * 1024 * 1024 else { throw NativeFailure("Claude lifetime cache exceeded its read bound") }
            data.append(contentsOf: bytes.prefix(count))
        }
        // A malformed optional cache contributes no lifetime reconciliation,
        // matching the full Statistics scan; protected-path failures are errors.
        return (try? JSONValue.decode(data)).flatMap(StatisticsCache.parse)
    }
}
