import Foundation

/// Persistent multi-tier SQLite energy history and cumulative Wh / draw aggregation.
public final class NativeEnergyHistory: @unchecked Sendable {
    public static let minute = 60_000.0
    public static let hour = 60 * minute
    public static let day = 24 * hour
    public static let levels = [minute, hour, day]
    public static let targetBytes = 500.0 * 1024.0 * 1024.0

    private let db: NativeDatabase
    private let readOnly: Bool
    private let clock: @Sendable () -> Double
    private let lock = NSRecursiveLock()
    private var lastSample = -Double.infinity
    private var writes = 0
    private var storageCache: (time: Double, value: JSONValue)?

    public init(db: NativeDatabase, readOnly: Bool = false, clock: @escaping @Sendable () -> Double = { Date().timeIntervalSince1970 * 1000 }) throws {
        self.db = db
        self.readOnly = readOnly
        self.clock = clock
        guard !readOnly else { return }
        try db.migrate("energy-history-tiers-1", sql: """
            CREATE TABLE IF NOT EXISTS energy_history(timestamp INTEGER PRIMARY KEY, snapshot TEXT NOT NULL, aggregated INTEGER NOT NULL DEFAULT 0);
            CREATE INDEX IF NOT EXISTS energy_history_pending ON energy_history(aggregated, timestamp);
            CREATE TABLE IF NOT EXISTS energy_history_rollups(resolution INTEGER NOT NULL, timestamp INTEGER NOT NULL, payload TEXT NOT NULL, PRIMARY KEY(resolution, timestamp));
        """)
    }

    private static func metric(_ value: Double) -> JSONValue {
        .array([1, .number(value), .number(value), .number(value)])
    }

    private static func mergeMetric(_ a: JSONValue, _ b: JSONValue) -> JSONValue {
        let av = a.array, bv = b.array
        guard av.count >= 4, bv.count >= 4 else { return b }
        return .array([
            .number(av[0].double + bv[0].double),
            .number(av[1].double + bv[1].double),
            .number(min(av[2].double, bv[2].double)),
            .number(max(av[3].double, bv[3].double))
        ])
    }

    private static func metricValue(_ metric: JSONValue, kind: String) -> Double {
        let values = metric.array
        guard values.count >= 4 else { return 0 }
        if kind == "min" { return values[2].double }
        if kind == "max" { return values[3].double }
        return values[1].double / max(1, values[0].double)
    }

    public static func aggregateSnapshot(_ sample: JSONValue, sliceMs: Double = 10_000) -> JSONValue {
        let date = sample["date"].double
        let hours = max(0, min(60_000, sliceMs)) / 3_600_000.0
        let wallW = sample["wallPowerW"].double
        let sysInW = sample["systemPowerInW"].double
        let sysLoadW = sample["systemLoadW"].double
        let battW = sample["batteryPowerW"].double
        let lossW = sample["adapterLossW"].double
        let voltV = sample["voltageInV"].double
        let currA = sample["currentInA"].double

        let sensors = Dictionary(sample["sensors"].array.map { sensor in
            (sensor["id"].string, [
                "value": metric(sensor["value"].double),
                "unit": .string(sensor["unit"].string)
            ] as JSONValue)
        }, uniquingKeysWith: { _, last in last })

        let subsystems = Dictionary(sample["subsystems"].array.map { sub in
            (sub["id"].string, [
                "watts": metric(sub["watts"].double),
                "label": .string(sub["label"].string),
                "group": .string(sub["group"].string)
            ] as JSONValue)
        }, uniquingKeysWith: { _, last in last })

        return [
            "count": 1,
            "first": .number(date),
            "last": .number(date),
            "durationMs": .number(max(0, min(60_000, sliceMs))),
            "wallPowerW": metric(wallW),
            "systemPowerInW": metric(sysInW),
            "systemLoadW": metric(sysLoadW),
            "batteryPowerW": metric(battW),
            "adapterLossW": metric(lossW),
            "voltageInV": metric(voltV),
            "currentInA": metric(currA),
            "wallEnergyWh": .number(wallW * hours),
            "systemInEnergyWh": .number(sysInW * hours),
            "systemEnergyWh": .number(sysLoadW * hours),
            "batteryNetWh": .number(battW * hours),
            "batteryChargedWh": .number(max(0, battW) * hours),
            "batteryDischargedWh": .number(max(0, -battW) * hours),
            "adapterLossWh": .number(lossW * hours),
            "sensors": .object(sensors),
            "subsystems": .object(subsystems)
        ]
    }

    public static func mergeAggregate(_ a: JSONValue, _ b: JSONValue) -> JSONValue {
        var sensors = a["sensors"].object
        for (id, value) in b["sensors"].object {
            if let old = sensors[id] {
                sensors[id] = [
                    "value": mergeMetric(old["value"], value["value"]),
                    "unit": value["unit"]
                ]
            } else {
                sensors[id] = value
            }
        }
        var subsystems = a["subsystems"].object
        for (id, value) in b["subsystems"].object {
            if let old = subsystems[id] {
                subsystems[id] = [
                    "watts": mergeMetric(old["watts"], value["watts"]),
                    "label": value["label"],
                    "group": value["group"]
                ]
            } else {
                subsystems[id] = value
            }
        }
        var out: JSONObject = [
            "count": .number(a["count"].double + b["count"].double),
            "first": .number(min(a["first"].double, b["first"].double)),
            "last": .number(max(a["last"].double, b["last"].double)),
            "durationMs": .number(a["durationMs"].double + b["durationMs"].double),
            "sensors": .object(sensors),
            "subsystems": .object(subsystems)
        ]
        for key in ["wallPowerW", "systemPowerInW", "systemLoadW", "batteryPowerW", "adapterLossW", "voltageInV", "currentInA"] {
            out[key] = mergeMetric(a[key], b[key])
        }
        for key in ["wallEnergyWh", "systemInEnergyWh", "systemEnergyWh", "batteryNetWh", "batteryChargedWh", "batteryDischargedWh", "adapterLossWh"] {
            out[key] = .number(a[key].double + b[key].double)
        }
        return .object(out)
    }

    public static func snapshot(from aggregate: JSONValue, kind: String, date: Double? = nil) -> JSONValue {
        func round3(_ v: Double) -> Double { (v * 1000).rounded() / 1000 }
        let sensors = aggregate["sensors"].object.keys.sorted().map { id -> JSONValue in
            let s = aggregate["sensors"][id]
            return [
                "id": .string(id),
                "value": .number(round3(metricValue(s["value"], kind: kind))),
                "unit": .string(s["unit"].string.isEmpty ? "W" : s["unit"].string)
            ]
        }
        let subsystems = aggregate["subsystems"].object.keys.sorted().map { id -> JSONValue in
            let sub = aggregate["subsystems"][id]
            return [
                "id": .string(id),
                "label": .string(sub["label"].string),
                "group": .string(sub["group"].string),
                "watts": .number(round3(metricValue(sub["watts"], kind: kind)))
            ]
        }
        let wallW = round3(metricValue(aggregate["wallPowerW"], kind: kind))
        let sysInW = round3(metricValue(aggregate["systemPowerInW"], kind: kind))
        let eff: JSONValue = (wallW > 0.25 && sysInW > 0) ? .number(((min(100, max(0, (sysInW / wallW) * 100.0)) * 100).rounded()) / 100) : .null
        return [
            "date": .number(date ?? aggregate["first"].double),
            "wallPowerW": .number(wallW),
            "systemPowerInW": .number(sysInW),
            "systemLoadW": .number(round3(metricValue(aggregate["systemLoadW"], kind: kind))),
            "batteryPowerW": .number(round3(metricValue(aggregate["batteryPowerW"], kind: kind))),
            "adapterLossW": .number(round3(metricValue(aggregate["adapterLossW"], kind: kind))),
            "efficiencyPercent": eff,
            "voltageInV": .number(round3(metricValue(aggregate["voltageInV"], kind: kind))),
            "currentInA": .number(round3(metricValue(aggregate["currentInA"], kind: kind))),
            "subsystems": .array(subsystems),
            "sensors": .array(sensors)
        ]
    }

    private func addRollups(_ sample: JSONValue, sliceMs: Double) throws {
        let ts = sample["date"].double
        let aggregate = Self.aggregateSnapshot(sample, sliceMs: sliceMs)
        for resolution in Self.levels {
            let bucket = floor(ts / resolution) * resolution
            let stored = try db.query("SELECT payload FROM energy_history_rollups WHERE resolution=? AND timestamp=?", [.number(resolution), .number(bucket)]).first?["payload"]
            let old = stored.flatMap { try? JSONValue.decode(Data($0.string.utf8)) }
            let merged = old.map { Self.mergeAggregate($0, aggregate) } ?? aggregate
            let encoded = String(decoding: try merged.encoded(), as: UTF8.self)
            try db.execute("INSERT INTO energy_history_rollups VALUES(?,?,?) ON CONFLICT(resolution,timestamp) DO UPDATE SET payload=excluded.payload", [.number(resolution), .number(bucket), .string(encoded)])
        }
    }

    @discardableResult
    public func persist(_ sample: JSONValue, interval: Double = 10_000) throws -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard !readOnly, NativeHardwarePolicies.energySnapshot(sample) else { return false }
        let timestamp = sample["date"].double.rounded()
        guard timestamp - lastSample >= interval else { return false }
        let sliceMs = lastSample.isFinite && timestamp > lastSample ? min(60_000, max(1_000, timestamp - lastSample)) : interval
        var normalized = sample
        normalized["date"] = .number(timestamp)
        let encoded = String(decoding: try normalized.encoded(), as: UTF8.self)
        let inserted = try db.transaction { () -> Bool in
            let ok = try db.execute("INSERT OR IGNORE INTO energy_history(timestamp,snapshot,aggregated) VALUES(?,?,1)", [.number(timestamp), .string(encoded)]) > 0
            if ok { try addRollups(normalized, sliceMs: sliceMs) }
            return ok
        }
        lastSample = timestamp
        if inserted {
            if storageCache?.value["first"].isNull == true { storageCache = nil }
            writes += 1
            if writes % 60 == 0 { try? compact() }
        }
        return inserted
    }

    public func storage(force: Bool = false) throws -> JSONValue {
        lock.lock(); defer { lock.unlock() }
        if readOnly {
            let exists = (try? db.query("SELECT 1 AS ok FROM sqlite_master WHERE type='table' AND name='energy_history'").first) != nil
            if !exists {
                return ["bytes": 0, "estimated": true, "targetBytes": .number(Self.targetBytes), "first": .null, "last": .null, "rawDays": 7, "minuteDays": 90, "hourlyDays": 365, "pending": 0]
            }
        }
        let now = clock()
        if !force, let cached = storageCache, now >= cached.time, now - cached.time < Self.minute {
            return cached.value
        }
        let raw = (try? db.query("SELECT COALESCE(SUM(length(snapshot)+64),0) AS n FROM energy_history").first?["n"]?.double) ?? 0
        let rollups = (try? db.query("SELECT COALESCE(SUM(length(payload)+64),0) AS n FROM energy_history_rollups").first?["n"]?.double) ?? 0
        let first = (try? db.query("SELECT json_extract(payload,'$.first') AS value FROM energy_history_rollups WHERE resolution=? ORDER BY timestamp LIMIT 1", [.number(Self.day)]).first?["value"]) ?? .null
        let last = (try? db.query("SELECT json_extract(payload,'$.last') AS value FROM energy_history_rollups WHERE resolution=? ORDER BY timestamp DESC LIMIT 1", [.number(Self.day)]).first?["value"]) ?? .null
        let pending = (try? db.query("SELECT COUNT(*) AS n FROM energy_history WHERE aggregated=0").first?["n"]) ?? 0
        let pressured = raw + rollups > Self.targetBytes * 0.85
        let value: JSONValue = [
            "bytes": .number(raw + rollups),
            "estimated": true,
            "targetBytes": .number(Self.targetBytes),
            "first": first,
            "last": last,
            "rawDays": .number(pressured ? 1 : 7),
            "minuteDays": .number(pressured ? 7 : 90),
            "hourlyDays": .number(pressured ? 90 : 365),
            "pending": pending
        ]
        storageCache = (now, value)
        return value
    }

    public func compact() throws {
        lock.lock(); defer { lock.unlock() }
        guard !readOnly else { return }
        storageCache = nil
        let policy = try storage(force: true)
        let now = clock()
        try db.transaction {
            _ = try db.execute("DELETE FROM energy_history WHERE aggregated=1 AND timestamp<?", [.number(now - policy["rawDays"].double * Self.day)])
            _ = try db.execute("DELETE FROM energy_history_rollups WHERE resolution=? AND timestamp<?", [.number(Self.minute), .number(floor((now - policy["minuteDays"].double * Self.day) / Self.minute) * Self.minute)])
            _ = try db.execute("DELETE FROM energy_history_rollups WHERE resolution=? AND timestamp<?", [.number(Self.hour), .number(floor((now - policy["hourlyDays"].double * Self.day) / Self.hour) * Self.hour)])
        }
    }

    public func allTimeTotals() -> JSONValue {
        lock.lock(); defer { lock.unlock() }
        let rows = (try? db.query("SELECT payload FROM energy_history_rollups WHERE resolution=? ORDER BY timestamp", [.number(Self.day)])) ?? []
        guard !rows.isEmpty else {
            return [
                "systemEnergyWh": 0,
                "wallEnergyWh": 0,
                "adapterLossWh": 0,
                "batteryChargedWh": 0,
                "batteryDischargedWh": 0,
                "avgSystemLoadW": .null,
                "peakSystemLoadW": .null,
                "sampleCount": 0
            ]
        }
        var combined: JSONValue?
        for row in rows {
            guard let text = row["payload"]?.string, let agg = try? JSONValue.decode(Data(text.utf8)) else { continue }
            combined = combined.map { Self.mergeAggregate($0, agg) } ?? agg
        }
        guard let total = combined else {
            return ["systemEnergyWh": 0, "wallEnergyWh": 0, "adapterLossWh": 0, "batteryChargedWh": 0, "batteryDischargedWh": 0, "avgSystemLoadW": .null, "peakSystemLoadW": .null, "sampleCount": 0]
        }
        func round3(_ v: Double) -> Double { (v * 1000).rounded() / 1000 }
        let avgLoad = round3(Self.metricValue(total["systemLoadW"], kind: "mean"))
        let peakLoad = round3(Self.metricValue(total["systemLoadW"], kind: "max"))
        return [
            "systemEnergyWh": .number(round3(total["systemEnergyWh"].double)),
            "wallEnergyWh": .number(round3(total["wallEnergyWh"].double)),
            "adapterLossWh": .number(round3(total["adapterLossWh"].double)),
            "batteryChargedWh": .number(round3(total["batteryChargedWh"].double)),
            "batteryDischargedWh": .number(round3(total["batteryDischargedWh"].double)),
            "avgSystemLoadW": .number(avgLoad),
            "peakSystemLoadW": .number(peakLoad),
            "sampleCount": .number(total["count"].double)
        ]
    }

    public func read(since: Double, until: Double, maximum: Int = 500) throws -> JSONValue {
        lock.lock(); defer { lock.unlock() }
        let now = clock()
        let store = try storage()
        let first = since == 0 ? (store["first"].isNull ? until : store["first"].double) : since
        let coverageStart = max(first, store["first"].isNull ? first : store["first"].double)
        let span = max(0, until - coverageStart)
        let limits = [store["rawDays"].double * Self.day, store["minuteDays"].double * Self.day, store["hourlyDays"].double * Self.day, .infinity]
        let tiers = [10_000.0, Self.minute, Self.hour, Self.day]
        var index = 0
        while index < 3 && (span / tiers[index] > Double(maximum) || now - coverageStart > limits[index]) { index += 1 }
        while index < 3 {
            let oldest: JSONValue? = index == 0
                ? (try? db.query("SELECT MIN(timestamp) AS t FROM energy_history WHERE aggregated=1"))?.first?["t"]
                : (try? db.query("SELECT MIN(timestamp) AS t FROM energy_history_rollups WHERE resolution=?", [.number(tiers[index])]))?.first?["t"]
            if let oldest, !oldest.isNull, oldest.double <= coverageStart + tiers[index] { break }
            index += 1
        }
        let resolution = tiers[index]
        let step = max(resolution, ceil((span + 1) / Double(maximum) / resolution) * resolution)
        let start = index == 0 ? first : floor(first / resolution) * resolution
        let rows: [[String: JSONValue]] = (try? (index == 0
            ? db.query("SELECT timestamp,snapshot AS payload FROM energy_history WHERE timestamp>=? AND timestamp<=? ORDER BY timestamp", [.number(start), .number(until)])
            : db.query("SELECT timestamp,payload FROM energy_history_rollups WHERE resolution=? AND timestamp>=? AND timestamp<=? ORDER BY timestamp", [.number(resolution), .number(start), .number(until)]))) ?? []

        var buckets: [Double: JSONValue] = [:]
        var overall: JSONValue?
        var previousRawTimestamp: Double?
        for row in rows {
            let ts = (row["timestamp"] ?? 0).double
            let payload = (row["payload"] ?? "").string
            guard let decoded = try? JSONValue.decode(Data(payload.utf8)) else { continue }
            let value: JSONValue
            if index == 0 {
                let slice = previousRawTimestamp.map { min(60_000, max(1_000, ts - $0)) } ?? 10_000
                previousRawTimestamp = ts
                value = Self.aggregateSnapshot(decoded, sliceMs: slice)
            } else {
                value = decoded
            }
            guard value["last"].double >= first, value["first"].double <= until else { continue }
            let bucket = floor(max(0, ts - coverageStart) / step) * step
            buckets[bucket] = buckets[bucket].map { Self.mergeAggregate($0, value) } ?? value
            overall = overall.map { Self.mergeAggregate($0, value) } ?? value
        }

        func round3(_ v: Double) -> Double { (v * 1000).rounded() / 1000 }
        let points = buckets.keys.sorted().compactMap { buckets[$0] }.map { agg -> JSONValue in
            [
                "mean": Self.snapshot(from: agg, kind: "mean"),
                "min": Self.snapshot(from: agg, kind: "min"),
                "max": Self.snapshot(from: agg, kind: "max"),
                "systemEnergyWh": .number(round3(agg["systemEnergyWh"].double)),
                "wallEnergyWh": .number(round3(agg["wallEnergyWh"].double)),
                "systemInEnergyWh": .number(round3(agg["systemInEnergyWh"].double)),
                "batteryNetWh": .number(round3(agg["batteryNetWh"].double)),
                "batteryChargedWh": .number(round3(agg["batteryChargedWh"].double)),
                "batteryDischargedWh": .number(round3(agg["batteryDischargedWh"].double)),
                "adapterLossWh": .number(round3(agg["adapterLossWh"].double)),
                "count": agg["count"],
                "end": agg["last"],
                "resolutionMs": .number(step)
            ]
        }

        let loadMeans = points.map { $0["mean"]["systemLoadW"].double }.filter { $0.isFinite }.sorted()
        let p95LoadW: JSONValue = loadMeans.isEmpty ? .null : .number(round3(loadMeans[min(loadMeans.count - 1, Int(Double(loadMeans.count - 1) * 0.95))]))

        let summary: JSONValue = {
            guard let total = overall else {
                return [
                    "systemEnergyWh": 0,
                    "wallEnergyWh": 0,
                    "systemInEnergyWh": 0,
                    "adapterLossWh": 0,
                    "batteryNetWh": 0,
                    "batteryChargedWh": 0,
                    "batteryDischargedWh": 0,
                    "avgSystemLoadW": .null,
                    "minSystemLoadW": .null,
                    "peakSystemLoadW": .null,
                    "p95SystemLoadW": .null,
                    "avgWallPowerW": .null,
                    "peakWallPowerW": .null,
                    "avgEfficiencyPercent": .null,
                    "sampleCount": 0,
                    "durationMs": 0
                ]
            }
            let sysWh = round3(total["systemEnergyWh"].double)
            let wallWh = round3(total["wallEnergyWh"].double)
            let sysInWh = round3(total["systemInEnergyWh"].double)
            let eff: JSONValue = (wallWh > 0.001 && sysInWh > 0) ? .number(((min(100, max(0, (sysInWh / wallWh) * 100.0)) * 100).rounded()) / 100) : .null
            return [
                "systemEnergyWh": .number(sysWh),
                "wallEnergyWh": .number(wallWh),
                "systemInEnergyWh": .number(sysInWh),
                "adapterLossWh": .number(round3(total["adapterLossWh"].double)),
                "batteryNetWh": .number(round3(total["batteryNetWh"].double)),
                "batteryChargedWh": .number(round3(total["batteryChargedWh"].double)),
                "batteryDischargedWh": .number(round3(total["batteryDischargedWh"].double)),
                "avgSystemLoadW": .number(round3(Self.metricValue(total["systemLoadW"], kind: "mean"))),
                "minSystemLoadW": .number(round3(Self.metricValue(total["systemLoadW"], kind: "min"))),
                "peakSystemLoadW": .number(round3(Self.metricValue(total["systemLoadW"], kind: "max"))),
                "p95SystemLoadW": p95LoadW,
                "avgWallPowerW": .number(round3(Self.metricValue(total["wallPowerW"], kind: "mean"))),
                "peakWallPowerW": .number(round3(Self.metricValue(total["wallPowerW"], kind: "max"))),
                "avgEfficiencyPercent": eff,
                "sampleCount": total["count"],
                "durationMs": total["durationMs"]
            ]
        }()

        return [
            "samples": .array(points.map { $0["mean"] }),
            "points": .array(points),
            "summary": summary,
            "storage": store,
            "since": .number(first),
            "until": .number(until),
            "resolutionMs": .number(step)
        ]
    }

    public static func discontinuousSamples(_ points: [JSONValue], kind: String = "mean") -> [JSONValue] {
        var output: [JSONValue] = [], previous: Double?, gapMs = 30_000.0, index = 0
        for point in points {
            let sample = point[kind]
            let date = sample["date"].double
            gapMs = max(30_000, point["resolutionMs"].double * 2)
            if let previous, date - previous > gapMs {
                output.append([
                    "date": .number(previous + 1),
                    "wallPowerW": .null,
                    "systemPowerInW": .null,
                    "systemLoadW": .null,
                    "batteryPowerW": .null,
                    "adapterLossW": .null,
                    "voltageInV": .null,
                    "currentInA": .null,
                    "subsystems": [],
                    "sensors": [],
                    "gap": .number(Double(index))
                ])
                index += 1
            }
            output.append(sample)
            previous = date
        }
        return output
    }
}
