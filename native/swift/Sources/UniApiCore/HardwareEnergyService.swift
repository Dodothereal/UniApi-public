import Foundation

public struct NativeEnergyIO: Sendable {
    public var supported: @Sendable () -> Bool
    public var sample: @Sendable (Double) -> JSONValue
    public var now: @Sendable () -> Double
    public var sleep: @Sendable (Double) async throws -> Void
    public init(
        supported: @escaping @Sendable () -> Bool,
        sample: @escaping @Sendable (Double) -> JSONValue,
        now: @escaping @Sendable () -> Double = { Date().timeIntervalSince1970 * 1000 },
        sleep: @escaping @Sendable (Double) async throws -> Void = { try await Task.sleep(nanoseconds: UInt64($0 * 1e9)) }
    ) {
        self.supported = supported
        self.sample = sample
        self.now = now
        self.sleep = sleep
    }
    public static func production() -> NativeEnergyIO {
        .init(
            supported: { NativeEnergySystem.isSupported() },
            sample: { now in NativeEnergySystem.sample(now: now) }
        )
    }
}

public actor NativeEnergyService {
    private let runtime: NativeRuntime
    private let io: NativeEnergyIO
    private var history: NativeEnergyHistory?
    private var initialized = false
    private var snapshot: JSONValue = .null
    private var error: String?
    private var samplerTask: Task<Void, Never>?
    private var preferences: JSONObject = [
        "ratePerKwh": 0.30,
        "currency": "$",
        "badgeMetric": "systemLoad"
    ]

    // Session tracking
    private var sessionStartedAt: Double
    private var sessionLastAt: Double?
    private var sessionSampleCount = 0
    private var sessionSystemLoadSum = 0.0
    private var sessionMinLoad: Double?
    private var sessionPeakLoad: Double?
    private var sessionWallPowerSum = 0.0
    private var sessionPeakWall: Double?
    private var sessionSystemEnergyWh = 0.0
    private var sessionWallEnergyWh = 0.0
    private var sessionAdapterLossWh = 0.0
    private var sessionBatteryChargedWh = 0.0
    private var sessionBatteryDischargedWh = 0.0
    private var sessionLoadSamples: [Double] = []
    private var sensorPeaks: [String: Double] = [:]
    private var sensorSums: [String: (sum: Double, count: Int)] = [:]

    public init(runtime: NativeRuntime, io: NativeEnergyIO? = nil) {
        self.runtime = runtime
        let io = io ?? .production()
        self.io = io
        self.sessionStartedAt = io.now()
    }

    deinit {
        samplerTask?.cancel()
    }

    private func initialize() throws {
        guard !initialized else { return }
        if !runtime.paths.readOnly {
            try runtime.db.migrate("energy-1", sql: "CREATE TABLE IF NOT EXISTS energy_preferences(id INTEGER PRIMARY KEY CHECK(id=1),value TEXT NOT NULL)")
        }
        history = try NativeEnergyHistory(db: runtime.db, readOnly: runtime.paths.readOnly, clock: io.now)
        if let text = (try? runtime.db.query("SELECT value FROM energy_preferences WHERE id=1"))?.first?["value"]?.string,
           let saved = try? JSONValue.decode(Data(text.utf8)),
           let merged = try? NativeHardwarePolicies.energyPreferences(saved, current: preferences) {
            preferences = merged
        }
        if !runtime.paths.readOnly {
            try? history?.compact()
        }
        initialized = true
    }

    public func start() async throws {
        try initialize()
        if snapshot.isNull && io.supported() {
            await refreshSnapshot(persistToHistory: true)
        }
        guard !runtime.paths.readOnly, io.supported() else { return }
        if samplerTask == nil {
            samplerTask = Task { [weak self] in
                while !Task.isCancelled {
                    do {
                        try await self?.io.sleep(2.0)
                        try Task.checkCancellation()
                    } catch {
                        return
                    }
                    await self?.refreshSnapshot(persistToHistory: true)
                }
            }
        }
    }

    public func stop() async {
        samplerTask?.cancel()
        samplerTask = nil
    }

    private func refreshSnapshot(persistToHistory: Bool) async {
        guard io.supported() else { return }
        let currentNow = io.now()
        let next = io.sample(currentNow)
        guard NativeHardwarePolicies.energySnapshot(next) else {
            error = "The energy telemetry reader returned an invalid reading"
            return
        }
        error = nil
        snapshot = next
        recordSessionSample(next)
        if persistToHistory && !runtime.paths.readOnly {
            _ = try? history?.persist(next)
        }
        await runtime.events.publish("energy.state", currentState(now: currentNow))
    }

    private func recordSessionSample(_ sample: JSONValue) {
        let ts = sample["date"].double
        let sliceHours: Double
        if let prev = sessionLastAt, ts > prev {
            sliceHours = min(60_000, max(0, ts - prev)) / 3_600_000.0
        } else {
            sliceHours = 0
        }
        sessionLastAt = ts
        sessionSampleCount += 1

        let sysLoad = sample["systemLoadW"].double
        let wall = sample["wallPowerW"].double
        let batt = sample["batteryPowerW"].double
        let loss = sample["adapterLossW"].double

        sessionSystemLoadSum += sysLoad
        sessionMinLoad = sessionMinLoad.map { min($0, sysLoad) } ?? sysLoad
        sessionPeakLoad = sessionPeakLoad.map { max($0, sysLoad) } ?? sysLoad
        sessionWallPowerSum += wall
        sessionPeakWall = sessionPeakWall.map { max($0, wall) } ?? wall

        sessionSystemEnergyWh += sysLoad * sliceHours
        sessionWallEnergyWh += wall * sliceHours
        sessionAdapterLossWh += loss * sliceHours
        if batt >= 0 {
            sessionBatteryChargedWh += batt * sliceHours
        } else {
            sessionBatteryDischargedWh += (-batt) * sliceHours
        }

        if sessionLoadSamples.count >= 3600 {
            sessionLoadSamples.removeFirst(sessionLoadSamples.count - 3599)
        }
        sessionLoadSamples.append(sysLoad)

        for sensor in sample["sensors"].array {
            let id = sensor["id"].string
            let val = sensor["value"].double
            guard !id.isEmpty, val.isFinite else { continue }
            sensorPeaks[id] = sensorPeaks[id].map { max($0, val) } ?? val
            let prev = sensorSums[id] ?? (0, 0)
            sensorSums[id] = (prev.sum + val, prev.count + 1)
        }
    }

    private func resetSessionState(now: Double) {
        sessionStartedAt = now
        sessionLastAt = nil
        sessionSampleCount = 0
        sessionSystemLoadSum = 0
        sessionMinLoad = nil
        sessionPeakLoad = nil
        sessionWallPowerSum = 0
        sessionPeakWall = nil
        sessionSystemEnergyWh = 0
        sessionWallEnergyWh = 0
        sessionAdapterLossWh = 0
        sessionBatteryChargedWh = 0
        sessionBatteryDischargedWh = 0
        sessionLoadSamples = []
        sensorPeaks = [:]
        sensorSums = [:]
        if !snapshot.isNull {
            recordSessionSample(snapshot)
        }
    }

    private func sessionSummary(now: Double) -> JSONValue {
        func round3(_ v: Double) -> Double { (v * 1000).rounded() / 1000 }
        let count = sessionSampleCount
        let avgLoad: JSONValue = count > 0 ? .number(round3(sessionSystemLoadSum / Double(count))) : .null
        let avgWall: JSONValue = count > 0 ? .number(round3(sessionWallPowerSum / Double(count))) : .null
        let sorted = sessionLoadSamples.sorted()
        let p95: JSONValue = sorted.isEmpty ? .null : .number(round3(sorted[min(sorted.count - 1, Int(Double(sorted.count - 1) * 0.95))]))
        var peaksObj: JSONObject = [:]
        for (k, v) in sensorPeaks { peaksObj[k] = .number(round3(v)) }
        var avgsObj: JSONObject = [:]
        for (k, v) in sensorSums where v.count > 0 { avgsObj[k] = .number(round3(v.sum / Double(v.count))) }

        return [
            "startedAt": .number(sessionStartedAt),
            "durationMs": .number(max(0, now - sessionStartedAt)),
            "sampleCount": .number(Double(count)),
            "avgSystemLoadW": avgLoad,
            "minSystemLoadW": sessionMinLoad.map { .number(round3($0)) } ?? .null,
            "peakSystemLoadW": sessionPeakLoad.map { .number(round3($0)) } ?? .null,
            "p95SystemLoadW": p95,
            "avgWallPowerW": avgWall,
            "peakWallPowerW": sessionPeakWall.map { .number(round3($0)) } ?? .null,
            "systemEnergyWh": .number(round3(sessionSystemEnergyWh)),
            "wallEnergyWh": .number(round3(sessionWallEnergyWh)),
            "adapterLossWh": .number(round3(sessionAdapterLossWh)),
            "batteryChargedWh": .number(round3(sessionBatteryChargedWh)),
            "batteryDischargedWh": .number(round3(sessionBatteryDischargedWh)),
            "sensorPeaks": .object(peaksObj),
            "sensorAverages": .object(avgsObj)
        ]
    }

    private func currentState(now: Double) -> JSONValue {
        let supported = io.supported()
        let allTime = history?.allTimeTotals() ?? [
            "systemEnergyWh": 0,
            "wallEnergyWh": 0,
            "adapterLossWh": 0,
            "batteryChargedWh": 0,
            "batteryDischargedWh": 0,
            "avgSystemLoadW": .null,
            "peakSystemLoadW": .null,
            "sampleCount": 0
        ]
        return [
            "supported": .bool(supported),
            "snapshot": snapshot,
            "session": sessionSummary(now: now),
            "allTime": allTime,
            "preferences": .object(preferences),
            "error": error.map(JSONValue.string) ?? .null
        ]
    }

    public func handle(_ operation: String, input: JSONObject = [:]) async throws -> JSONValue {
        try initialize()
        let now = io.now()
        switch operation {
        case "status":
            if snapshot.isNull || input["force"]?.bool == true {
                await refreshSnapshot(persistToHistory: true)
            } else if now - snapshot["date"].double >= 1_800 {
                await refreshSnapshot(persistToHistory: true)
            }
            return currentState(now: io.now())
        case "summary":
            if snapshot.isNull { await refreshSnapshot(persistToHistory: false) }
            let state = currentState(now: now)
            return [
                "supported": state["supported"],
                "systemLoadW": snapshot.isNull ? .null : snapshot["systemLoadW"],
                "wallPowerW": snapshot.isNull ? .null : snapshot["wallPowerW"],
                "batteryPowerW": snapshot.isNull ? .null : snapshot["batteryPowerW"],
                "sessionEnergyWh": state["session"]["systemEnergyWh"],
                "bootEnergyWh": snapshot.isNull ? .null : snapshot["boot"]["systemEnergyWh"],
                "badge": .string(NativeHardwareDisplayPolicies.energyBadgeText(state))
            ]
        case "preferences":
            preferences = try NativeHardwarePolicies.energyPreferences(.object(input), current: preferences)
            if !runtime.paths.readOnly {
                let encoded = String(decoding: try JSONValue.object(preferences).encoded(), as: UTF8.self)
                _ = try runtime.db.execute("INSERT INTO energy_preferences VALUES (1,?) ON CONFLICT(id) DO UPDATE SET value=excluded.value", [.string(encoded)])
            }
            let next = currentState(now: now)
            await runtime.events.publish("energy.state", next)
            return next
        case "resetSession":
            resetSessionState(now: now)
            let next = currentState(now: now)
            await runtime.events.publish("energy.state", next)
            return next
        case "history":
            if snapshot.isNull && io.supported() {
                await refreshSnapshot(persistToHistory: true)
            }
            let spans: [String: Double] = [
                "30m": 30 * 60_000,
                "1h": 3_600_000,
                "6h": 6 * 3_600_000,
                "24h": 86_400_000,
                "7d": 7 * 86_400_000,
                "30d": 30 * 86_400_000,
                "90d": 90 * 86_400_000,
                "1y": 365 * 86_400_000,
                "all": now
            ]
            let range = input["range"]?.string ?? "30m"
            let until: Double
            let since: Double
            if range == "custom" {
                guard let rawSince = input["since"].flatMap(NativeHardwarePolicies.number),
                      let rawUntil = input["until"].flatMap(NativeHardwarePolicies.number),
                      rawSince >= 0, rawUntil >= rawSince else {
                    throw NativeFailure("Choose a valid custom history date range")
                }
                since = rawSince.rounded()
                until = min(now + 86_400_000, rawUntil.rounded())
            } else {
                until = now.rounded()
                guard let span = spans[range] else { throw NativeFailure("Invalid energy history range") }
                since = max(0, (until - span).rounded())
            }
            return try history!.read(since: since, until: until)
        default:
            throw NativeFailure("Unknown energy operation")
        }
    }
}
