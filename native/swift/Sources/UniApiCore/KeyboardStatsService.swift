import Foundation

public struct NativeKeyboardIO: Sendable {
    public var supported: @Sendable () -> Bool
    /// Whether macOS currently allows this app to observe key presses.
    public var permitted: @Sendable () -> Bool
    /// Shows the macOS Input Monitoring request and returns the answer so far.
    public var requestPermission: @Sendable () -> Bool
    /// Starts observing and reports whether macOS accepted the observer.
    public var begin: @Sendable () -> Bool
    public var end: @Sendable () -> Void
    /// Removes and returns the presses observed since the previous call.
    public var take: @Sendable () -> [NativeKeyboardEvent]
    /// The keyboards macOS lists and the standard of the one in use.
    public var hardware: @Sendable () -> NativeKeyboardHardware
    public var slot: @Sendable (Double) -> NativeKeyboardSlot
    public var now: @Sendable () -> Double
    public var sleep: @Sendable (Double) async throws -> Void
    public init(supported: @escaping @Sendable () -> Bool = { true }, permitted: @escaping @Sendable () -> Bool,
                requestPermission: @escaping @Sendable () -> Bool, begin: @escaping @Sendable () -> Bool,
                end: @escaping @Sendable () -> Void, take: @escaping @Sendable () -> [NativeKeyboardEvent],
                hardware: @escaping @Sendable () -> NativeKeyboardHardware = { .init() },
                slot: @escaping @Sendable (Double) -> NativeKeyboardSlot = { NativeKeyboardSlot.local($0) },
                now: @escaping @Sendable () -> Double = { Date().timeIntervalSince1970 * 1000 },
                sleep: @escaping @Sendable (Double) async throws -> Void = { try await Task.sleep(nanoseconds: UInt64($0 * 1e9)) }) {
        self.supported = supported; self.permitted = permitted; self.requestPermission = requestPermission
        self.begin = begin; self.end = end; self.take = take; self.hardware = hardware; self.slot = slot; self.now = now; self.sleep = sleep
    }
}

/// Counts key presses while the user has turned recording on. Only counters
/// reach storage: no characters, words, key order, window or app is kept.
public actor NativeKeyboardService {
    private let runtime: NativeRuntime
    private let io: NativeKeyboardIO
    private var fold: NativeKeyboardFold
    private var initialized = false
    private var enabled = false
    /// Chosen drawing; nil follows the detected keyboard.
    private var form: NativeKeyboardLayout.Form?, standard: NativeKeyboardLayout.Standard?
    /// Chosen key arrangement: Apple or third-party. Nil follows detection.
    private var apple: Bool?
    private var recording = false
    private var permission = false
    private var error: String?
    private var loop: Task<Void, Never>?
    private var lastPublished: Double = 0

    public init(runtime: NativeRuntime, io: NativeKeyboardIO = .production()) {
        self.runtime = runtime; self.io = io
        fold = NativeKeyboardFold(slot: io.slot)
    }

    private func initialize() throws {
        guard !initialized else { return }
        if !runtime.paths.readOnly {
            try runtime.db.migrate("keyboard-1", sql: """
            CREATE TABLE IF NOT EXISTS keyboard_preferences(id INTEGER PRIMARY KEY CHECK(id=1),value TEXT NOT NULL);
            CREATE TABLE IF NOT EXISTS keyboard_hours(day TEXT NOT NULL,hour INTEGER NOT NULL,keys INTEGER NOT NULL DEFAULT 0,
              characters INTEGER NOT NULL DEFAULT 0,timed_characters INTEGER NOT NULL DEFAULT 0,words INTEGER NOT NULL DEFAULT 0,
              deleted INTEGER NOT NULL DEFAULT 0,corrections INTEGER NOT NULL DEFAULT 0,shortcuts INTEGER NOT NULL DEFAULT 0,
              repeats INTEGER NOT NULL DEFAULT 0,bursts INTEGER NOT NULL DEFAULT 0,active_ms REAL NOT NULL DEFAULT 0,
              peak_wpm REAL NOT NULL DEFAULT 0,PRIMARY KEY(day,hour));
            CREATE TABLE IF NOT EXISTS keyboard_keys(day TEXT NOT NULL,code INTEGER NOT NULL,count INTEGER NOT NULL DEFAULT 0,PRIMARY KEY(day,code));
            CREATE TABLE IF NOT EXISTS keyboard_shortcuts(day TEXT NOT NULL,combo TEXT NOT NULL,count INTEGER NOT NULL DEFAULT 0,PRIMARY KEY(day,combo));
            """)
        }
        if let text = (try? runtime.db.query("SELECT value FROM keyboard_preferences WHERE id=1"))?.first?["value"]?.string,
           let saved = try? JSONValue.decode(Data(text.utf8)) {
            enabled = saved["enabled"].bool
            form = .init(rawValue: saved["form"].string); standard = .init(rawValue: saved["standard"].string)
            apple = Self.style(saved["style"].string)
        }
        initialized = true
    }

    public func start() async throws {
        try initialize()
        startPolling()
        refreshRecording()
    }

    private func startPolling() {
        guard !runtime.paths.readOnly, io.supported(), loop == nil else { return }
        loop = Task { [weak self] in
            while !Task.isCancelled, let sleep = self?.io.sleep {
                do { try await sleep(1); try Task.checkCancellation() } catch { return }
                await self?.tick()
            }
        }
    }
    public func stop() async {
        loop?.cancel(); loop = nil
        if recording { io.end(); recording = false }
        persist(io.take())
    }

    private func tick() async {
        let stateChanged = refreshRecording()
        let events = recording ? io.take() : []
        let changed = persist(events)
        let now = io.now()
        // Follow live typing, then publish once more when it falls silent.
        if stateChanged || changed || (lastPublished > 0 && now - lastPublished < 4_000) {
            if changed { lastPublished = now }
            await runtime.events.publish("keyboard.state", .object(live(now: now)))
        } else { lastPublished = 0 }
    }

    @discardableResult private func refreshRecording() -> Bool {
        let wasPermitted = permission, wasRecording = recording
        permission = enabled && !runtime.paths.readOnly && io.supported() && io.permitted()
        if permission, !recording {
            recording = io.begin()
        } else if !permission, recording {
            io.end()
            recording = false
            persist(io.take())
        }
        return permission != wasPermitted || recording != wasRecording
    }

    @discardableResult private func persist(_ events: [NativeKeyboardEvent]) -> Bool {
        for event in events { fold.record(event) }
        fold.settle(now: io.now())
        let delta = fold.pendingDelta
        guard !delta.isEmpty else { return !events.isEmpty }
        guard !runtime.paths.readOnly else { fold.clearPending(); return !events.isEmpty }
        do {
            try runtime.db.transaction {
                for (slot, value) in delta.slots {
                    try runtime.db.execute("""
                    INSERT INTO keyboard_hours(day,hour,keys,characters,timed_characters,words,deleted,corrections,shortcuts,repeats,bursts,active_ms,peak_wpm)
                    VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?) ON CONFLICT(day,hour) DO UPDATE SET keys=keys+excluded.keys,
                    characters=characters+excluded.characters,timed_characters=timed_characters+excluded.timed_characters,
                    words=words+excluded.words,deleted=deleted+excluded.deleted,corrections=corrections+excluded.corrections,
                    shortcuts=shortcuts+excluded.shortcuts,repeats=repeats+excluded.repeats,bursts=bursts+excluded.bursts,
                    active_ms=active_ms+excluded.active_ms,peak_wpm=MAX(peak_wpm,excluded.peak_wpm)
                    """, [.string(slot.day), .number(Double(slot.hour)), .number(Double(value.keys)), .number(Double(value.characters)),
                          .number(Double(value.timedCharacters)), .number(Double(value.words)), .number(Double(value.deleted)),
                          .number(Double(value.corrections)), .number(Double(value.shortcuts)), .number(Double(value.repeats)),
                          .number(Double(value.bursts)), .number(value.activeMs), .number(value.peakWpm)])
                }
                for (day, counts) in delta.keys {
                    for (code, count) in counts {
                        try runtime.db.execute("INSERT INTO keyboard_keys(day,code,count) VALUES (?,?,?) ON CONFLICT(day,code) DO UPDATE SET count=count+excluded.count",
                                               [.string(day), .number(Double(code)), .number(Double(count))])
                    }
                }
                for (day, counts) in delta.shortcuts {
                    for (combo, count) in counts {
                        try runtime.db.execute("INSERT INTO keyboard_shortcuts(day,combo,count) VALUES (?,?,?) ON CONFLICT(day,combo) DO UPDATE SET count=count+excluded.count",
                                               [.string(day), .string(combo), .number(Double(count))])
                    }
                }
            }
            fold.clearPending()
            error = nil
        } catch { self.error = "Keyboard statistics could not be saved: " + error.localizedDescription }
        return true
    }

    private func live(now: Double) -> JSONObject {
        ["wpm": .number(fold.liveWpm(now: now)), "sessionKeys": .number(Double(fold.sessionKeys)),
         "lastKeyAt": fold.lastKeyAt.map(JSONValue.number) ?? .null, "recording": .bool(recording), "permitted": .bool(permission)]
    }

    private func status(range requested: String) throws -> JSONValue {
        let now = io.now(), range = NativeKeyboardSummary.ranges.contains(requested) ? requested : "7d"
        let first = NativeKeyboardSummary.firstDay(range, now: now)
        let filter = first == nil ? "" : " WHERE day>=?", parameters: [JSONValue] = first.map { [.string($0)] } ?? []
        // A read-only session may open a database that never recorded keys.
        let readOnly = runtime.paths.readOnly
        func rows(_ sql: String, _ values: [JSONValue] = []) throws -> [JSONObject] {
            do { return try runtime.db.query(sql, values) } catch { if readOnly { return [] }; throw error }
        }
        var slots: [NativeKeyboardSlot: NativeKeyboardTotals] = [:]
        for row in try rows("SELECT * FROM keyboard_hours" + filter, parameters) {
            var value = NativeKeyboardTotals()
            value.keys = row["keys"]?.int ?? 0; value.characters = row["characters"]?.int ?? 0
            value.timedCharacters = row["timed_characters"]?.int ?? 0; value.words = row["words"]?.int ?? 0
            value.deleted = row["deleted"]?.int ?? 0; value.corrections = row["corrections"]?.int ?? 0
            value.shortcuts = row["shortcuts"]?.int ?? 0; value.repeats = row["repeats"]?.int ?? 0
            value.bursts = row["bursts"]?.int ?? 0; value.activeMs = row["active_ms"]?.double ?? 0; value.peakWpm = row["peak_wpm"]?.double ?? 0
            slots[.init(day: row["day"]?.string ?? "", hour: row["hour"]?.int ?? 0)] = value
        }
        var keys: [Int: Int] = [:], shortcuts: [String: Int] = [:]
        for row in try rows("SELECT code,SUM(count) AS n FROM keyboard_keys" + filter + " GROUP BY code", parameters) {
            keys[row["code"]?.int ?? -1] = row["n"]?.int ?? 0
        }
        for row in try rows("SELECT combo,SUM(count) AS n FROM keyboard_shortcuts" + filter + " GROUP BY combo", parameters) {
            shortcuts[row["combo"]?.string ?? ""] = row["n"]?.int ?? 0
        }
        let days = try rows("SELECT DISTINCT day FROM keyboard_hours WHERE keys>0").compactMap { $0["day"]?.string }
        // The drawing follows every key ever counted, not only the range shown.
        let used = Set(try rows("SELECT DISTINCT code FROM keyboard_keys WHERE count>0").compactMap { $0["code"]?.int })
        var model = NativeKeyboardLayout.detect(io.hardware(), used: used)
        if let form { model.form = form }
        if let standard { model.standard = standard }
        if let apple { model.apple = apple }
        var state = NativeKeyboardSummary.build(slots: slots, keys: keys, shortcuts: shortcuts, allDays: days, range: range, now: now, model: model)
        state["layoutChoice"] = ["form": .string(form?.rawValue ?? "auto"), "standard": .string(standard?.rawValue ?? "auto"),
                                 "style": .string(apple.map { $0 ? "apple" : "other" } ?? "auto")]
        state["supported"] = .bool(io.supported()); state["readOnly"] = .bool(runtime.paths.readOnly)
        state["enabled"] = .bool(enabled); state["permitted"] = .bool(io.permitted()); state["recording"] = .bool(recording)
        state["live"] = .object(live(now: now)); state["error"] = error.map(JSONValue.string) ?? .null
        state["hasData"] = .bool(!days.isEmpty)
        return .object(state)
    }

    private static func style(_ value: String) -> Bool? { value == "apple" ? true : value == "other" ? false : nil }
    private func savePreferences() throws {
        var value: JSONObject = ["enabled": .bool(enabled)]
        if let form { value["form"] = .string(form.rawValue) }
        if let standard { value["standard"] = .string(standard.rawValue) }
        if let apple { value["style"] = .string(apple ? "apple" : "other") }
        try runtime.db.execute("INSERT INTO keyboard_preferences VALUES (1,?) ON CONFLICT(id) DO UPDATE SET value=excluded.value",
                               [.string(String(decoding: try JSONValue.object(value).encoded(), as: UTF8.self))])
    }

    public func handle(_ operation: String, input: JSONObject = [:]) async throws -> JSONValue {
        try initialize()
        let range = input["range"]?.string ?? "7d"
        switch operation {
        case "status": break
        case "live": return .object(live(now: io.now()))
        case "set-enabled":
            try runtime.paths.assertWritable()
            guard io.supported() else { throw NativeFailure("Keyboard statistics are unavailable on this Mac") }
            let next = input["enabled"]?.bool == true
            let previous = enabled
            enabled = next
            do { try savePreferences() } catch { enabled = previous; throw error }
            if next {
                startPolling()
                if !io.permitted() { _ = io.requestPermission() }
            }
            refreshRecording()
        case "set-layout":
            try runtime.paths.assertWritable()
            if let value = input["form"]?.string { form = .init(rawValue: value) }
            if let value = input["standard"]?.string { standard = .init(rawValue: value) }
            if let value = input["style"]?.string { apple = Self.style(value) }
            try savePreferences()
        case "request-permission":
            try runtime.paths.assertWritable()
            guard enabled, io.supported() else { break }
            startPolling()
            if !io.permitted() { _ = io.requestPermission() }
            refreshRecording()
        case "reset":
            try runtime.paths.assertWritable()
            _ = io.take()
            fold = NativeKeyboardFold(slot: io.slot)
            try runtime.db.transaction {
                try runtime.db.execute("DELETE FROM keyboard_hours"); try runtime.db.execute("DELETE FROM keyboard_keys")
                try runtime.db.execute("DELETE FROM keyboard_shortcuts")
            }
        default: throw NativeFailure("Unknown keyboard statistics operation")
        }
        let state = try status(range: range)
        if operation != "status" { await runtime.events.publish("keyboard.state", .object(live(now: io.now()))) }
        return state
    }
}
