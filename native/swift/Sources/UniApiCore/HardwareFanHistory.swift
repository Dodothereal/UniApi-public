import Foundation

public final class NativeFanHistory: @unchecked Sendable {
    private let db: NativeDatabase
    private let lock = NSRecursiveLock()
    private var last: Double = -.infinity, writes = 0
    private var storageCache: (time: Double, value: JSONValue)?
    private let clock: @Sendable () -> Double
    private static let minute: Double = 60000, hour: Double = 3600000, day: Double = 86400000
    private static let target: Double = 500 * 1024 * 1024
    public init(db: NativeDatabase, clock: @escaping @Sendable () -> Double = { Date().timeIntervalSince1970 * 1000 }) throws {
        self.db = db; self.clock = clock
        try db.migrate("fans-2", sql: "CREATE TABLE IF NOT EXISTS fans_history(timestamp INTEGER PRIMARY KEY,snapshot TEXT NOT NULL); CREATE INDEX IF NOT EXISTS idx_fans_history_ts ON fans_history(timestamp)")
        try db.migrate("fans-history-tiers-1", sql: "ALTER TABLE fans_history ADD COLUMN aggregated INTEGER NOT NULL DEFAULT 0; CREATE INDEX fans_history_pending ON fans_history(aggregated,timestamp); CREATE TABLE fans_history_rollups(resolution INTEGER NOT NULL,timestamp INTEGER NOT NULL,payload TEXT NOT NULL,PRIMARY KEY(resolution,timestamp));")
    }
    private static func metric(_ v: JSONValue) -> JSONValue { [1, v, v, v] }
    private static func mergedMetric(_ a: JSONValue, _ b: JSONValue) -> JSONValue {
        let x = a.array, y = b.array
        guard x.count == 4, y.count == 4 else { return b }
        return [.number(x[0].double + y[0].double), .number(x[1].double + y[1].double), .number(min(x[2].double, y[2].double)), .number(max(x[3].double, y[3].double))]
    }
    public static func aggregate(_ sample: JSONValue) -> JSONValue {
        let sensors = Dictionary(sample["sensors"].array.map { ($0["id"].string, metric($0["value"])) }, uniquingKeysWith: { _, last in last })
        let fans = Dictionary(sample["fans"].array.map { fan -> (String, JSONValue) in
            (fan["id"].string, ["actual": metric(fan["actual"]), "target": metric(fan["target"]), "minimum": fan["minimum"], "maximum": fan["maximum"], "mode": fan["mode"]])
        }, uniquingKeysWith: { _, last in last })
        return ["count": 1, "first": sample["date"], "last": sample["date"], "thermal": metric(sample["thermal"]), "sensors": .object(sensors), "fans": .object(fans)]
    }
    public static func merge(_ a: JSONValue, _ b: JSONValue) -> JSONValue {
        var result = a
        result["count"] = .number(a["count"].double + b["count"].double)
        result["first"] = .number(min(a["first"].double, b["first"].double)); result["last"] = .number(max(a["last"].double, b["last"].double))
        result["thermal"] = mergedMetric(a["thermal"], b["thermal"])
        var sensors = a["sensors"].object
        for (id, value) in b["sensors"].object { sensors[id] = sensors[id].map { mergedMetric($0, value) } ?? value }
        result["sensors"] = .object(sensors)
        var fans = a["fans"].object
        for (id, value) in b["fans"].object {
            var next = value
            if let prior = fans[id] { next["actual"] = mergedMetric(prior["actual"], value["actual"]); next["target"] = mergedMetric(prior["target"], value["target"]) }
            fans[id] = next
        }
        result["fans"] = .object(fans); return result
    }
    private static func snapshot(_ aggregate: JSONValue, kind: String) -> JSONValue {
        func value(_ m: JSONValue) -> JSONValue { let a = m.array; guard a.count == 4, a[0].double > 0 else { return .null }; return kind == "min" ? a[2] : kind == "max" ? a[3] : .number(a[1].double / a[0].double) }
        let sensors: [JSONValue] = aggregate["sensors"].object.keys.sorted().map { ["id": .string($0), "value": value(aggregate["sensors"][$0])] }
        let fans: [JSONValue] = aggregate["fans"].object.keys.sorted().map { id in let f = aggregate["fans"][id]; return ["id": .number(Double(id) ?? 0), "actual": value(f["actual"]), "target": value(f["target"]), "minimum": f["minimum"], "maximum": f["maximum"], "mode": f["mode"]] }
        return ["date": aggregate["first"], "thermal": value(aggregate["thermal"]), "sensors": .array(sensors), "fans": .array(fans)]
    }
    private func add(_ sample: JSONValue) throws {
        for resolution in [Self.minute, Self.hour, Self.day] {
            let bucket = floor(sample["date"].double / resolution) * resolution
            let stored = try db.query("SELECT payload FROM fans_history_rollups WHERE resolution=? AND timestamp=?", [.number(resolution), .number(bucket)]).first?["payload"]
            let fresh = Self.aggregate(sample), old = stored.flatMap { try? JSONValue.decode(Data($0.string.utf8)) }
            let value = old.map { Self.merge($0, fresh) } ?? fresh
            try db.execute("INSERT INTO fans_history_rollups VALUES (?,?,?) ON CONFLICT(resolution,timestamp) DO UPDATE SET payload=excluded.payload", [.number(resolution), .number(bucket), .string(String(decoding: try value.encoded(), as: UTF8.self))])
        }
    }
    @discardableResult public func backfill(limit: Int = 250) throws -> Int {
        lock.lock(); defer { lock.unlock() }
        let rows = try db.query("SELECT timestamp,snapshot FROM fans_history WHERE aggregated=0 ORDER BY timestamp LIMIT ?", [.number(Double(limit))])
        try db.transaction {
            for row in rows {
                var sample = (try? JSONValue.decode(Data((row["snapshot"] ?? "").string.utf8))) ?? .null
                let valid = NativeHardwarePolicies.fanSnapshot(sample)
                if valid { sample["date"] = row["timestamp"]!; try add(sample) }
                try db.execute("UPDATE fans_history SET aggregated=? WHERE timestamp=?", [.number(valid ? 1 : 2), row["timestamp"]!])
            }
        }
        if !rows.isEmpty { storageCache = nil }
        return rows.count
    }
    @discardableResult public func persist(_ sample: JSONValue, interval: Double = 10000) throws -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard NativeHardwarePolicies.fanSnapshot(sample), sample["date"].double.rounded() - last >= interval else { return false }
        var value = sample; let ts = sample["date"].double.rounded(); value["date"] = .number(ts)
        let inserted = try db.transaction { () -> Bool in
            let inserted = try db.execute("INSERT OR IGNORE INTO fans_history(timestamp,snapshot,aggregated) VALUES (?,?,1)", [.number(ts), .string(String(decoding: try value.encoded(), as: UTF8.self))]) > 0
            if inserted { try add(value) }; return inserted
        }
        last = ts
        if inserted { if storageCache?.value["first"].isNull == true { storageCache = nil }; writes += 1; if writes % 60 == 0 { try compact() } }
        return inserted
    }
    public func storage() throws -> JSONValue {
        lock.lock(); defer { lock.unlock() }
        if let cached = storageCache, clock() >= cached.time, clock() - cached.time < 60000 { return cached.value }
        let raw = try db.query("SELECT COALESCE(SUM(length(snapshot)+64),0) AS n FROM fans_history").first?["n"]?.double ?? 0
        let rollups = try db.query("SELECT COALESCE(SUM(length(payload)+64),0) AS n FROM fans_history_rollups").first?["n"]?.double ?? 0
        let first = try db.query("SELECT json_extract(payload,'$.first') AS value FROM fans_history_rollups WHERE resolution=? ORDER BY timestamp LIMIT 1", [.number(Self.day)]).first?["value"] ?? .null
        let last = try db.query("SELECT json_extract(payload,'$.last') AS value FROM fans_history_rollups WHERE resolution=? ORDER BY timestamp DESC LIMIT 1", [.number(Self.day)]).first?["value"] ?? .null
        let pressure = raw + rollups > Self.target * 0.85
        let value: JSONValue = ["bytes": .number(raw + rollups), "estimated": true, "targetBytes": .number(Self.target), "first": first, "last": last, "rawDays": .number(pressure ? 1 : 7), "minuteDays": .number(pressure ? 7 : 90), "hourlyDays": .number(pressure ? 90 : 365), "pending": try db.query("SELECT COUNT(*) AS n FROM fans_history WHERE aggregated=0").first?["n"] ?? 0]
        storageCache = (clock(), value); return value
    }
    public func compact() throws {
        lock.lock(); defer { lock.unlock() }
        storageCache = nil
        let policy = try storage(), now = clock()
        try db.transaction {
            try db.execute("DELETE FROM fans_history WHERE aggregated=1 AND timestamp<?", [.number(now - policy["rawDays"].double * Self.day)])
            try db.execute("DELETE FROM fans_history_rollups WHERE resolution=? AND timestamp<?", [.number(Self.minute), .number(floor((now - policy["minuteDays"].double * Self.day) / Self.minute) * Self.minute)])
            try db.execute("DELETE FROM fans_history_rollups WHERE resolution=? AND timestamp<?", [.number(Self.hour), .number(floor((now - policy["hourlyDays"].double * Self.day) / Self.hour) * Self.hour)])
        }
    }
    public func read(since: Double, until: Double, maximum: Int = 500) throws -> JSONValue {
        lock.lock(); defer { lock.unlock() }
        guard since >= 0, since < until, until <= clock() + Self.day, since.rounded() == since, until.rounded() == until, maximum > 0 else { throw NativeFailure("Choose a valid fan history range") }
        let policy = try storage(), first = since == 0 ? (policy["first"].isNull ? until : policy["first"].double) : since
        let coverage = max(first, policy["first"].isNull ? first : policy["first"].double), span = max(0, until - coverage)
        let tiers = [10000.0, Self.minute, Self.hour, Self.day]
        let limits = [policy["rawDays"].double * Self.day, policy["minuteDays"].double * Self.day, policy["hourlyDays"].double * Self.day, .infinity]
        var index = 0
        while index < 3 && (span / tiers[index] > Double(maximum) || clock() - coverage > limits[index]) { index += 1 }
        while index < 3 {
            let oldest = index == 0 ? try db.query("SELECT MIN(timestamp) AS t FROM fans_history WHERE aggregated=1").first?["t"] : try db.query("SELECT MIN(timestamp) AS t FROM fans_history_rollups WHERE resolution=?", [.number(tiers[index])]).first?["t"]
            if let oldest, !oldest.isNull, oldest.double <= coverage + tiers[index] { break }; index += 1
        }
        let resolution = tiers[index], step = max(resolution, ceil((span + 1) / Double(maximum) / resolution) * resolution)
        let start = index == 0 ? first : floor(first / resolution) * resolution
        let rows = index == 0 ? try db.query("SELECT timestamp,snapshot AS payload FROM fans_history WHERE timestamp>=? AND timestamp<=? ORDER BY timestamp", [.number(start), .number(until)]) : try db.query("SELECT timestamp,payload FROM fans_history_rollups WHERE resolution=? AND timestamp>=? AND timestamp<=? ORDER BY timestamp", [.number(resolution), .number(start), .number(until)])
        var buckets: [Double: JSONValue] = [:]
        for row in rows {
            guard let raw = try? JSONValue.decode(Data((row["payload"] ?? "").string.utf8)) else { continue }
            let value = index == 0 ? Self.aggregate(raw) : raw
            if value["last"].double < first || value["first"].double > until { continue }
            let bucket = floor(max(0, (row["timestamp"] ?? 0).double - coverage) / step) * step
            buckets[bucket] = buckets[bucket].map { Self.merge($0, value) } ?? value
        }
        let points: [JSONValue] = buckets.keys.sorted().map { key in let a = buckets[key]!; return ["mean": Self.snapshot(a, kind: "mean"), "min": Self.snapshot(a, kind: "min"), "max": Self.snapshot(a, kind: "max"), "count": a["count"], "end": a["last"], "resolutionMs": .number(step)] }
        return ["samples": .array(points.map { $0["mean"] }), "points": .array(points), "storage": policy, "since": .number(first), "until": .number(until), "resolutionMs": .number(step)]
    }
    public static func discontinuousSamples(_ points: [JSONValue], kind: String) -> [JSONValue] {
        var result: [JSONValue] = [], previous: JSONValue?
        for point in points {
            let sample = point[kind]
            if let previous, sample["date"].double - previous["end"].double > max(10000, previous["resolutionMs"].double) * 1.5 {
                result.append(["date": .number(previous["end"].double + 1), "sensors": [], "fans": []])
            }
            result.append(sample); previous = point
        }
        return result
    }
}
