import Foundation

public final class NativeDashboardService: @unchecked Sendable {
    private let runtime: NativeRuntime
    public init(runtime: NativeRuntime) { self.runtime = runtime }
    public func snapshot() async throws -> JSONValue {
        let runtime = self.runtime
        return try await runtime.cache.readCurrent("dashboard", freshness: .seconds(5)) {
            let providers = try runtime.providers.list()
            let settingsURL = runtime.paths.home.appendingPathComponent(".claude/settings.json")
            let settings = (try? NativeFile.readJSON(settingsURL)) ?? .null
            let base = settings["env"]["ANTHROPIC_BASE_URL"].string
            let current = providers.first { provider in
                let p = JSONValue.object(provider), proxy = p["proxy"]
                let direct = proxy["direct_url"].string
                let suffix = "/\(p["id"].string)"
                return !base.isEmpty && ((!direct.isEmpty && base == direct) || base.hasSuffix(suffix) || proxy["aliases"].array.contains { base.hasSuffix("/" + $0.string) })
            }
            let jobs = try await runtime.jobs.list(limit: 8)
            var counts: JSONObject = [:]
            for (table, key) in [("code_threads", "threads"), ("arena_matches", "matches"), ("transcripts", "transcripts"), ("stats_records", "usageRecords"), ("prompts", "prompts")] {
                let exists = !(try runtime.db.query("SELECT name FROM sqlite_master WHERE type='table' AND name=?", [.string(table)])).isEmpty
                if exists { counts[key] = try runtime.db.query("SELECT COUNT(*) AS n FROM \(table)").first?["n"] ?? .null }
                else { counts[key] = .number(0) }
            }
            let newestRows = [runtime.paths.bench.appendingPathComponent("results/results.jsonl"), runtime.paths.data.appendingPathComponent("results.jsonl")].compactMap(Self.lastRow)
            let latest = newestRows.max { $0["ts"].string < $1["ts"].string } ?? .null
            return ["providers": .number(Double(providers.count)), "currentName": current?["name"] ?? .string(base.isEmpty ? "Anthropic subscription" : "Unknown gateway"),
                "model": settings["model"], "effort": settings["effortLevel"], "settingsReadable": .bool(!settings.isNull),
                "counts": .object(counts), "jobs": .array(jobs.map(JSONValue.object)), "latestBenchmark": latest]
        }
    }
    private static func lastRow(_ url: URL) -> JSONValue? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let end = try? handle.seekToEnd() else { return nil }
        try? handle.seek(toOffset: end > 65536 ? end - 65536 : 0)
        guard let data = try? handle.readToEnd() else { return nil }
        for line in data.split(separator: 10).reversed() {
            if let row = try? JSONValue.decode(Data(line)), !row["run_id"].isNull { return row }
        }
        return nil
    }
}
