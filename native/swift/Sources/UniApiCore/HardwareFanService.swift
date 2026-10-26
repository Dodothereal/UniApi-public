import Foundation

public actor NativeFanService {
    private let runtime: NativeRuntime
    private let io: NativeFanIO
    private var history: NativeFanHistory?
    private var initialized = false, enabled = false, busy = false, pollBusy = false, daemon = true
    private var snapshot: JSONValue = .null
    private var reply: JSONValue = ["ok": true, "mode": "automatic", "message": "macOS manages your fans."]
    private var error: JSONValue = .null
    private var preferences: JSONValue = ["unit": "c", "menuMetric": "temperature"]
    private var keep: JSONValue = .null
    private var clientSeen: Double = 0, reassertAt: Double = 0, backoff: Double = 15000, appliedAt: Double = 0
    private var releaseRequested = false, helperMode = "automatic"
    private var monitor: Task<Void, Never>?, poller: Task<Void, Never>?
    private var monitoringStarted = false
    private var monitorError: String?
    public init(runtime: NativeRuntime, io: NativeFanIO? = nil) { self.runtime = runtime; self.io = io ?? .production(runtime: runtime) }
    deinit { monitor?.cancel(); poller?.cancel() }
    private func initialize() throws {
        guard !initialized else { return }
        try runtime.db.migrate("fans-1", sql: "CREATE TABLE IF NOT EXISTS fans_preferences(id INTEGER PRIMARY KEY CHECK(id=1),value TEXT NOT NULL)")
        try runtime.db.migrate("fans-3", sql: "CREATE TABLE IF NOT EXISTS fans_keep(id INTEGER PRIMARY KEY CHECK(id=1),value TEXT NOT NULL)")
        history = try NativeFanHistory(db: runtime.db, clock: io.now)
        if let text = try runtime.db.query("SELECT value FROM fans_preferences WHERE id=1").first?["value"]?.string, let saved = try? JSONValue.decode(Data(text.utf8)), ["c", "f"].contains(saved["unit"].string), ["temperature", "rpm", "both", "icon"].contains(saved["menuMetric"].string) { preferences = saved }
        if let text = try runtime.db.query("SELECT value FROM fans_keep WHERE id=1").first?["value"]?.string, let saved = try? JSONValue.decode(Data(text.utf8)) { keep = NativeHardwarePolicies.keptFanCommand(saved) }
        if !runtime.paths.readOnly { while try history!.backfill() == 250 { }; try history!.compact() }
        initialized = true
    }
    public func start() async throws {
        try initialize()
        monitoringStarted = true
        do { try startMonitor() } catch { await monitorFailed(error.localizedDescription) }
        guard !runtime.paths.readOnly else { return }
        if poller == nil {
            poller = Task { [weak self] in
                while !Task.isCancelled { guard let self else { return }; await self.poll(); do { try await self.io.sleep(2) } catch { return } }
            }
        }
    }
    private func startMonitor() throws {
        if monitor == nil && io.metadata()["installed"].bool {
            let stream = try io.monitor()
            monitor = Task { [weak self] in
                do { for try await sample in stream { guard let self else { return }; try await self.accept(sample) }; if !Task.isCancelled { await self?.monitorFailed("The temperature reader stopped") } }
                catch { if !Task.isCancelled { await self?.monitorFailed(error.localizedDescription) } }
            }
        }
    }
    /// Cancels only this service's unprivileged reader. Standing controller
    /// intent and helper lifetime remain owned by the existing control path.
    public func stopMonitoring() async {
        monitoringStarted = false
        let pending = monitor; monitor = nil
        pending?.cancel(); await pending?.value
        await io.stopMonitor()
        snapshot = .null
        await runtime.events.publish("fans.spin", ["spinning": false])
        await runtime.events.publish("fans.state", status())
    }
    public func accept(_ sample: JSONValue) async throws {
        try initialize()
        guard NativeHardwarePolicies.fanSnapshot(sample) else { throw NativeFailure("Invalid fan telemetry frame") }
        let wasSpinning = snapshot["fans"].array.contains { $0["actual"].double > 0 }
        snapshot = sample
        if let monitorError, error == .string(monitorError) { error = .null }
        monitorError = nil
        if !runtime.paths.readOnly { try history?.persist(sample) }
        let spinning = sample["fans"].array.contains { $0["actual"].double > 0 }
        if wasSpinning != spinning { await runtime.events.publish("fans.spin", ["spinning": .bool(spinning)]) }
        let idle = !enabled || reply["ok"].bool && reply["mode"].string == "automatic" || reply["mode"].string == "external"
        let automatic = sample["fans"].array.allSatisfy { [0, 3].contains($0["mode"].int) }
        if idle && reply["mode"].string == "unknown" && !sample["fans"].array.isEmpty && automatic { error = .null }
        if idle && error.isNull { reply = ["ok": true, "mode": .string(automatic ? "automatic" : "external"), "message": .string(automatic ? "macOS manages your fans." : "Another control session is active; return it to Auto before enabling UniApi.")] }
        await runtime.events.publish("fans.state", status())
    }
    private func monitorFailed(_ message: String) async {
        monitor = nil; snapshot = .null
        monitorError = message.isEmpty ? "The temperature reader stopped" : message
        error = .string(monitorError!)
        await runtime.events.publish("fans.spin", ["spinning": false])
        await runtime.events.publish("fans.state", status())
    }
    private func status() -> JSONValue {
        let metadata = io.metadata(), fresh = !snapshot.isNull && io.now() - snapshot["date"].double < 6000 ? snapshot : .null
        return ["supported": metadata["supported"], "installed": metadata["installed"], "snapshot": fresh, "enabled": .bool(enabled), "busy": .bool(busy), "control": reply, "error": error, "preferences": preferences, "daemon": ["installed": metadata["daemonInstalled"], "running": .bool(enabled && daemon), "current": metadata["current"]], "keep": keep, "historySeconds": 1800]
    }
    private func attach() async -> Bool {
        guard !enabled, !busy, io.metadata()["daemonAvailable"].bool else { return false }
        guard let answer = try? await io.request(["command": "status"], true), !enabled, !busy else { return false }
        reply = answer; helperMode = answer["mode"].string; daemon = true; enabled = true; error = .null; reassertAt = 0; backoff = 15000; appliedAt = io.now(); return true
    }
    public func poll() async {
        guard !runtime.paths.readOnly, !busy, !pollBusy else { return }
        if !enabled { pollBusy = true; _ = await attach(); pollBusy = false; return }
        pollBusy = true; defer { pollBusy = false }
        let before = helperMode
        let action = NativeHardwarePolicies.fanPoll(mode: reply["mode"].string, ok: reply["ok"].bool, kept: !keep.isNull, releaseRequested: releaseRequested, snapshotAge: snapshot.isNull ? .infinity : io.now() - snapshot["date"].double, clientAge: io.now() - clientSeen, reassertIn: reassertAt - io.now())
        do {
            reply = try await io.request(action == "reassert" ? keep : ["command": .string(action)], daemon)
            if action == "reassert" { if reply["ok"].bool { appliedAt = io.now() } else { backoff = NativeHardwarePolicies.fanBackoff(heldMs: 0, previous: backoff) }; reassertAt = io.now() + backoff }
            helperMode = reply["mode"].string
            if !keep.isNull && !releaseRequested && reply["ok"].bool && helperMode == "automatic" && !["automatic", "unknown"].contains(before) { backoff = NativeHardwarePolicies.fanBackoff(heldMs: io.now() - appliedAt, previous: backoff); reassertAt = io.now() + backoff; if !reply["message"].string.isEmpty { error = reply["message"] } }
            if !reply["ok"].bool { error = reply["message"] } else if helperMode != "automatic" { error = .null }
        } catch { enabled = false; reply = ["ok": false, "mode": "unknown", "message": "Control connection lost; verify automatic fan modes before starting another session."]; self.error = reply["message"] }
        await runtime.events.publish("fans.state", status())
    }
    private func remember(_ command: JSONValue) throws {
        keep = command; reassertAt = 0; backoff = 15000; appliedAt = io.now()
        try runtime.db.execute("INSERT INTO fans_keep(id,value) VALUES(1,?) ON CONFLICT(id) DO UPDATE SET value=excluded.value", [.string(command.isNull ? "" : String(decoding: try command.encoded(), as: UTF8.self))])
    }
    private func connect(daemon: Bool) async throws {
        for _ in 0..<25 {
            if let response = try? await io.request(["command": "status"], daemon) { reply = response; helperMode = response["mode"].string; self.daemon = daemon; enabled = true; backoff = 15000; reassertAt = 0; appliedAt = io.now(); return }
            try await io.sleep(0.2)
        }
        throw NativeFailure("The fan control helper did not establish a session")
    }
    public func handle(_ operation: String, input: JSONObject = [:]) async throws -> JSONValue {
        try initialize()
        if operation == "status" {
            clientSeen = io.now()
            // Like the web status route, a new client read retries a stopped reader.
            // Retrying never authorizes a helper or changes a hardware target.
            if monitoringStarted {
                do { try startMonitor() } catch { monitorError = error.localizedDescription; self.error = .string(error.localizedDescription) }
            }
            return status()
        }
        if operation == "summary" { return ["supported": io.metadata()["supported"], "enabled": .bool(enabled), "mode": reply["mode"], "spinning": .bool(snapshot["fans"].array.contains { $0["actual"].double > 0 })] }
        if operation == "history" {
            let intervals: [String: Double] = ["30m": 1800000, "1h": 3600000, "6h": 21600000, "24h": 86400000, "7d": 7 * 86400000, "30d": 30 * 86400000, "90d": 90 * 86400000, "1y": 365 * 86400000, "all": 0]
            let range = (input["range"] ?? "30m").string, until = (input["until"] ?? .number(io.now())).double.rounded()
            guard intervals[range] != nil || range == "custom" else { throw NativeFailure("Choose a valid fan history range") }
            let since = input["since"]?.double.rounded() ?? (range == "all" ? 0 : max(0, until - (intervals[range] ?? 0)))
            return try history!.read(since: since, until: until)
        }
        try runtime.paths.assertWritable()
        if operation == "preferences" {
            guard Set(input.keys).isSubset(of: ["unit", "menuMetric"]), input["unit"].map({ ["c", "f"].contains($0.string) }) ?? true, input["menuMetric"].map({ ["temperature", "rpm", "both", "icon"].contains($0.string) }) ?? true else { throw NativeFailure("Invalid fan preferences") }
            for (key, value) in input { preferences[key] = value }
            try runtime.db.execute("INSERT INTO fans_preferences(id,value) VALUES(1,?) ON CONFLICT(id) DO UPDATE SET value=excluded.value", [.string(String(decoding: try preferences.encoded(), as: UTF8.self))]); return preferences
        }
        if operation == "release" {
            releaseRequested = true; try remember(.null)
            for _ in 0..<220 { if !busy && !pollBusy { break }; try await io.sleep(0.1) }
            if enabled && !busy && !pollBusy { reply = (try? await io.request(["command": "automatic"], daemon)) ?? ["ok": false, "mode": "unknown", "message": "Automatic restoration is pending"]; helperMode = reply["mode"].string }
            return ["ok": .bool(!busy && reply["ok"].bool && helperMode == "automatic"), "mode": reply["mode"]]
        }
        if operation == "control" {
            let command = try NativeHardwarePolicies.fanCommand(.object(input))
            guard enabled else { throw NativeFailure("Enable fan controls first") }
            for _ in 0..<134 { if !busy && !pollBusy { break }; try await io.sleep(0.06) }
            guard !busy, !pollBusy else { throw NativeFailure("Fan controls are busy") }
            busy = true; defer { busy = false }; clientSeen = io.now(); releaseRequested = false; error = .null
            do { reply = try await io.request(command, daemon); guard reply["ok"].bool else { throw NativeFailure(reply["message"].string) } }
            catch {
                if let actual = try? await io.request(["command": "status"], daemon), actual["ok"].bool, actual["mode"] == command["command"] { reply = actual }
                else { self.error = .string(error.localizedDescription); throw error }
            }
            helperMode = reply["mode"].string; try remember(NativeHardwarePolicies.keptFanCommand(command)); busy = false; let value = status(); await runtime.events.publish("fans.state", value); return value
        }
        guard ["enable", "install", "uninstall"].contains(operation), !busy else { throw NativeFailure("Unknown or busy fan helper operation") }
        if operation == "enable" && enabled { return status() }
        if operation != "uninstall", (!io.metadata()["installed"].bool || snapshot.isNull || io.now() - snapshot["date"].double > 6000) { throw NativeFailure("Wait for live readings and a built helper before enabling controls") }
        busy = true; defer { busy = false }; clientSeen = io.now(); error = .null
        if operation == "uninstall" { releaseRequested = true }
        else { releaseRequested = false }
        do {
            if enabled && (operation == "uninstall" || operation == "install" && !daemon) { reply = (try? await io.request(["command": "automatic"], daemon)) ?? reply }
            try await io.authorize(operation)
            if operation == "uninstall" { try remember(.null); enabled = false; reply = ["ok": true, "mode": "automatic", "message": "macOS manages your fans."] }
            else { enabled = false; try await connect(daemon: operation == "install") }
            busy = false; let value = status(); await runtime.events.publish("fans.state", value); return value
        } catch { if operation == "uninstall" { releaseRequested = false }; self.error = .string(error.localizedDescription); throw error }
    }
}
