import Foundation
import CoreFoundation
import CryptoKit
import CSQLite
import Darwin

/// Run once after exclusive writable ownership, before creating page models or
/// the window. Existing destination values (including false, zero and empty)
/// win. The private pending journal permits restart after a partial migration;
/// a completed journal prevents a cleared native choice being imported again.
///
/// AppStorage destinations retain web names except theme/sidebar/page and fan
/// keys. Benchmark services already consume state/native-selection.json and
/// state/native-results-view.json. Views consume typed defaults: fan curve is
/// JSON Data, favorites a string array, timers seconds, and stats range an Int.
/// Nothing reads cookies or imports arbitrary defaults/localStorage fields.
public final class NativePreferences: @unchecked Sendable {
    public static let webKeys = [
        "uniapi.theme", "uniapi.sidebar", "uniapi.bench.sel", "uniapi.results.view.v1",
        "uniapi.rank.metric", "uniapi.switcher.engine", "uniapi.code.project",
        "uniapi.stats.range", "uniapi.stats.source", "uniapi.stats.measure", "uniapi.stats.metric", "uniapi.stats.ttft.log",
        "uniapi.transcribe.lang", "uniapi.transcribe.notify", "uniapi.arena.prompt", "uniapi.arena.mode", "uniapi.arena.chosen",
        "fans.tab", "fans.history.range", "fans.curve", "fans.duration", "fans.boost", "fans.favorites"
    ]
    private static let legacyKeys = ["uniapi-page", "uniapi-sidebar", "uniapi-sel-v1", "uniapi-results-tab", "uniapi-rank-metric", "uniapi-stats-range", "uniapi-stats-measure", "uniapi-stats-model-metric", "uniapi-stats-ttft-log", "NSWindow Frame UniApiMain"]
    private static let mutex = NSRecursiveLock()
    public let paths: NativePaths, destinationDomain: String
    private let defaults: UserDefaults, legacyDefaults: UserDefaults?, legacyDomain: String, hubDefaults: UserDefaults?, hubDomain: String
    public var journalURL: URL {
        // Development and production share data files, but not defaults domains.
        // Never let completion for one destination suppress migration for another.
        let hash = SHA256.hash(data: Data(destinationDomain.utf8)).map { String(format: "%02x", $0) }.joined()
        return paths.data.appendingPathComponent("native-preferences/migration-v1-" + hash + ".json")
    }
    /// Inject isolated suites in fixtures. When not injected, old domains are
    /// read as bounded property lists beneath paths.home; never opened writable.
    /// Production retains the old web hub identity. Its existing defaults are
    /// also the destination, while the separate legacy Swift domain stays read-only.
    public init(paths: NativePaths, defaults: UserDefaults, destinationDomain: String,
                legacyDefaults: UserDefaults? = nil, legacyDomain: String = "app.devved.uniapi",
                hubDefaults: UserDefaults? = nil, hubDomain: String = "app.devved.uniapi.hub") {
        self.paths = paths; self.defaults = defaults; self.destinationDomain = destinationDomain
        self.legacyDefaults = legacyDefaults; self.legacyDomain = legacyDomain; self.hubDefaults = hubDefaults; self.hubDomain = hubDomain
    }
    public func migrate() throws -> NativePreferenceMigrationReport {
        try paths.assertWritable()
        guard Self.domain(destinationDomain), Self.domain(legacyDomain), Self.domain(hubDomain) else { throw NativeFailure("Preference migration needs valid application domains") }
        guard destinationDomain != legacyDomain else { throw NativeFailure("Native preference migration cannot write the legacy Swift source domain") }
        Self.mutex.lock(); defer { Self.mutex.unlock() }
        let directory = try PreferenceDisk.directory(root: paths.data, components: ["native-preferences"])
        let lockFD = openat(directory, "migration.lock", O_RDWR | O_CREAT | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC, 0o600)
        guard lockFD >= 0 else { close(directory); throw NativeFailure("Preference migration lock is unavailable") }
        defer { flock(lockFD, LOCK_UN); close(lockFD); close(directory) }
        var info = stat()
        guard fstat(lockFD, &info) == 0, info.st_nlink == 1, info.st_uid == geteuid(), info.st_mode & S_IFMT == S_IFREG, flock(lockFD, LOCK_EX) == 0 else { throw NativeFailure("Preference migration lock is invalid") }
        let journal: JSONValue
        let saved = try PreferenceDisk.read(journalURL, root: paths.data, limit: 16 * 1024 * 1024)
        if let saved {
            journal = try JSONValue.decode(saved)
            try Self.validateJournal(journal, domain: destinationDomain)
            if journal["phase"] == "complete" { return .init(alreadyComplete: true, imported: [], preserved: [], rejected: journal["rejected"].array.map(\.string), warnings: journal["warnings"].array.map(\.string)) }
        } else {
            let web = try PreferenceWebStore.read(home: paths.home)
            let legacy = try source(legacyDefaults, domain: legacyDomain, keys: Self.legacyKeys)
            // Reusing the production hub domain is intentional. Read its frame
            // from the same persistent view used to preserve destination values,
            // rather than a potentially older on-disk copy of that live domain.
            let hub = try source(destinationDomain == hubDomain ? defaults : hubDefaults, domain: hubDomain, keys: ["NSWindow Frame UniApiMain"])
            journal = Self.plan(web: web.values, legacy: legacy, hub: hub, domain: destinationDomain, warnings: web.warnings)
            try Self.validateJournal(journal, domain: destinationDomain)
            try PreferenceDisk.publish(try journal.encoded(pretty: true), directory: directory, name: journalURL.lastPathComponent, replace: false)
        }
        var imported: [String] = [], preserved: [String] = []
        for key in journal["defaults"].object.keys.sorted() {
            if defaults.persistentDomain(forName: destinationDomain)?[key] != nil { preserved.append(key); continue }
            let entry = journal["defaults"][key], value = try Self.propertyValue(entry)
            defaults.set(value, forKey: key)
            guard let readback = defaults.persistentDomain(forName: destinationDomain)?[key], Self.entry(readback) == entry else { throw NativeFailure("A migrated preference could not be stored; the pending journal was retained") }
            imported.append(key)
        }
        guard defaults.synchronize() else { throw NativeFailure("Native preferences could not synchronize; migration will retry") }
        for name in journal["files"].object.keys.sorted() {
            let target = paths.bench.appendingPathComponent("state/" + name + ".json")
            if try PreferenceDisk.read(target, root: paths.data, limit: 16 * 1024 * 1024) != nil { preserved.append(name); continue }
            let stateDirectory = try PreferenceDisk.directory(root: paths.data, components: ["bench", "state"]); defer { close(stateDirectory) }
            let created = try PreferenceDisk.publish(try journal["files"][name].encoded(pretty: true), directory: stateDirectory, name: name + ".json", replace: false)
            (created ? imported.append(name) : preserved.append(name))
        }
        // Completion contains provenance/key names only, never prompt text or
        // source records. The pending plan itself contains only typed allowlists.
        let complete: JSONValue = ["version": 1, "domain": .string(destinationDomain), "phase": "complete", "defaults": [:], "files": [:], "rejected": journal["rejected"], "warnings": journal["warnings"]]
        try PreferenceDisk.publish(try complete.encoded(pretty: true), directory: directory, name: journalURL.lastPathComponent, replace: true)
        return .init(alreadyComplete: false, imported: imported, preserved: preserved, rejected: journal["rejected"].array.map(\.string), warnings: journal["warnings"].array.map(\.string))
    }
    private static func domain(_ value: String) -> Bool { !value.isEmpty && value.utf8.count <= 240 && value.range(of: "^[A-Za-z0-9_.-]+$", options: .regularExpression) != nil }
    private func source(_ suite: UserDefaults?, domain: String, keys: [String]) throws -> [String: Any] {
        let values: [String: Any]
        if let suite { values = suite.persistentDomain(forName: domain) ?? [:] }
        else if let data = try PreferenceDisk.read(paths.home.appendingPathComponent("Library/Preferences/" + domain + ".plist"), root: paths.home, limit: 16 * 1024 * 1024) {
            guard let parsed = try PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any] else { throw NativeFailure("Legacy preferences must be a property list dictionary") }; values = parsed
        } else { values = [:] }
        return values.filter { keys.contains($0.key) }
    }
    private static func plan(web: [String: String], legacy: [String: Any], hub: [String: Any], domain: String, warnings: [String]) -> JSONValue {
        var saved: JSONObject = [:], files: JSONObject = [:], rejected: [String] = []
        func add(_ source: String, _ destination: String, _ value: JSONValue?, type: String = "string") {
            guard let value else { rejected.append(source); return }; if saved[destination] == nil { saved[destination] = ["type": .string(type), "value": value] }
        }
        for key in web.keys.sorted() {
            let text = web[key]!
            switch key {
            case "uniapi.theme": add(key, "uniapi-theme", choice(text, ["dark", "light", "auto"]))
            case "uniapi.sidebar": add(key, "uniapi-sidebar", boolean(text), type: "bool")
            case "uniapi.bench.sel": if let value = selection(json(text)) { files["native-selection"] = value } else { rejected.append(key) }
            case "uniapi.results.view.v1": if let value = results(json(text)) { files["native-results-view"] = value } else { rejected.append(key) }
            case "uniapi.rank.metric": add(key, key, choice(text, ["ttft", "decode", "context", "reliability", "gap"]))
            case "uniapi.switcher.engine": add(key, key, choice(text, ["claude", "codex"]))
            case "uniapi.code.project": add(key, key, label(text, limit: 1024, empty: true))
            case "uniapi.stats.range": add(key, key, integer(text, allowed: [0, 7, 30]), type: "integer")
            case "uniapi.stats.source": add(key, key, choice(text, ["all", "claude", "codex", "antigravity", "zcode", "opencode"]))
            case "uniapi.stats.measure": add(key, key, choice(text, ["all", "output", "thinking", "messages"]))
            case "uniapi.stats.metric": add(key, key, choice(text, ["tokens", "output", "messages"]))
            case "uniapi.stats.ttft.log", "uniapi.transcribe.notify": add(key, key, boolean(text), type: "bool")
            case "uniapi.transcribe.lang": add(key, key, language(text))
            case "uniapi.arena.prompt": add(key, key, text.utf8.count <= 8 * 1024 * 1024 ? .string(text) : nil)
            case "uniapi.arena.mode": add(key, key, choice(text, ["random", "chosen"]))
            case "uniapi.arena.chosen": add(key, key, strings(json(text)).flatMap { try? $0.encoded() }.map { .string(String(decoding: $0, as: UTF8.self)) })
            case "fans.tab": let tab = jsonString(text) ?? "invalid"; add(key, "uniapi.fans.tab", ["overview": "control", "history": "timeline", "sensors": "sensors", "curve": "curve", "settings": "settings"][tab].map(JSONValue.string))
            case "fans.history.range": add(key, "uniapi.fans.range", choice(jsonString(text) ?? "invalid", ["30m", "1h", "6h", "24h", "7d", "30d", "90d", "1y", "all", "custom"]))
            case "fans.duration", "fans.boost":
                let value = jsonString(text) ?? "invalid", allowed = key == "fans.duration" ? ["1", "5", "10", "30", "60", "never"] : ["1", "5", "10", "30"]
                add(key, key == "fans.duration" ? "uniapi.fans.duration" : "uniapi.fans.boost", allowed.contains(value) ? .number(Double(value == "never" ? 0 : (Int(value) ?? 0) * 60)) : nil, type: "integer")
            case "fans.curve": add(key, "uniapi.fans.curve", curve(json(text)).flatMap { try? $0.encoded() }.map { .string($0.base64EncodedString()) }, type: "data")
            case "fans.favorites": add(key, "uniapi.fans.favorites", strings(json(text)), type: "strings")
            default: break
            }
        }
        for key in legacy.keys.sorted() {
            let raw = legacy[key]!
            switch key {
            case "uniapi-page": add(key, "uniapi-native-page", (raw as? String).flatMap { ["home": "home", "benchmark": "speed", "results": "results", "stats": "stats", "claude": "switcher"][$0] }.map(JSONValue.string))
            case "uniapi-sidebar": add(key, key, strictBool(raw), type: "bool")
            case "uniapi-sel-v1":
                let data = raw as? Data, value = data.flatMap { try? JSONValue.decode($0) } ?? .null
                if files["native-selection"] == nil { if let normalized = selection(value) { files["native-selection"] = normalized } else { rejected.append(key) } }
            case "uniapi-results-tab": if files["native-results-view"] == nil { if let text = raw as? String, let tab = choice(text, ["table", "charts"]) { files["native-results-view"] = ["scope": "latest", "family": "", "tab": tab, "newestRun": ""] } else { rejected.append(key) } }
            case "uniapi-rank-metric": add(key, "uniapi.rank.metric", (raw as? String).flatMap { choice($0, ["ttft", "decode", "context", "reliability", "gap"]) })
            case "uniapi-stats-range": add(key, "uniapi.stats.range", strictInteger(raw).flatMap { [0, 7, 30].contains($0) ? .number(Double($0)) : nil }, type: "integer")
            case "uniapi-stats-measure": add(key, "uniapi.stats.measure", (raw as? String).flatMap { choice($0, ["all", "output", "thinking", "messages"]) })
            case "uniapi-stats-model-metric": add(key, "uniapi.stats.metric", (raw as? String).flatMap { choice($0, ["tokens", "output", "messages"]) })
            case "uniapi-stats-ttft-log": add(key, "uniapi.stats.ttft.log", strictBool(raw), type: "bool")
            default: break
            }
        }
        if let geometry = hub["NSWindow Frame UniApiMain"] ?? legacy["NSWindow Frame UniApiMain"] { add("NSWindow Frame UniApiMain", "NSWindow Frame UniApiMain", (geometry as? String).flatMap(frame)) }
        return ["version": 1, "domain": .string(domain), "phase": "pending", "defaults": .object(saved), "files": .object(files), "rejected": .array(Array(Set(rejected)).sorted().map(JSONValue.string)), "warnings": .array(warnings.map(JSONValue.string))]
    }
    private static func choice(_ value: String, _ allowed: [String]) -> JSONValue? { allowed.contains(value) ? .string(value) : nil }
    private static func boolean(_ text: String) -> JSONValue? { text == "1" ? true : text == "0" ? false : nil }
    private static func integer(_ text: String, allowed: [Int]) -> JSONValue? { guard let n = Int(text), String(n) == text, allowed.contains(n) else { return nil }; return .number(Double(n)) }
    private static func strictBool(_ raw: Any) -> JSONValue? { guard let n = raw as? NSNumber, CFGetTypeID(n) == CFBooleanGetTypeID() else { return nil }; return .bool(n.boolValue) }
    private static func strictInteger(_ raw: Any) -> Int? { guard let n = raw as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID(), n.doubleValue.isFinite, let integer = Int(exactly: n.doubleValue) else { return nil }; return integer }
    private static func jsonString(_ text: String) -> String? { if case .string(let value) = json(text) { return value }; return nil }
    private static func json(_ value: String) -> JSONValue { (try? JSONValue.decode(Data(value.utf8))) ?? .null }
    private static func label(_ text: String, limit: Int = 1024, empty: Bool = false) -> JSONValue? { (empty || !text.isEmpty) && text.utf8.count <= limit && !text.unicodeScalars.contains(where: { $0.value < 32 || $0.value == 127 }) ? .string(text) : nil }
    private static func language(_ text: String) -> JSONValue? { text.isEmpty || text.range(of: "^[A-Za-z]{2,3}([_-][A-Za-z0-9]{2,8})*$", options: .regularExpression) != nil ? .string(text) : nil }
    private static func strings(_ value: JSONValue) -> JSONValue? {
        guard case .array = value, value.array.count <= 16384, value.array.allSatisfy({ if case .string = $0 { return label($0.string) != nil }; return false }) else { return nil }
        var seen = Set<String>(); return .array(value.array.filter { seen.insert($0.string).inserted })
    }
    private static func selection(_ value: JSONValue) -> JSONValue? {
        guard case .object = value, let included = strings(value["included"]), case .object = value["models"], value["models"].object.count <= 4096, let tier = choice(value["tier"].string, ["quick", "standard", "deep"]) else { return nil }
        var models: JSONObject = [:]
        for (id, rows) in value["models"].object { guard label(id) != nil, let rows = strings(rows) else { return nil }; models[id] = rows }
        return ["included": included, "models": .object(models), "tier": tier]
    }
    private static func results(_ value: JSONValue) -> JSONValue? {
        guard case .object = value, case .string = value["scope"], label(value["scope"].string, limit: 180) != nil, case .string = value["family"], label(value["family"].string, limit: 4096, empty: true) != nil, let tab = choice(value["tab"].string, ["table", "charts"]), value["lastRunId"].isNull || { if case .string = value["lastRunId"] { return label(value["lastRunId"].string, limit: 180, empty: true) != nil }; return false }() else { return nil }
        return ["scope": value["scope"], "family": value["family"], "tab": tab, "newestRun": value["lastRunId"].isNull ? "" : value["lastRunId"]]
    }
    private static func curve(_ value: JSONValue) -> JSONValue? {
        guard value.array.count == 4 else { return nil }; var previousT = 25.0, previousP = 0.0, points: [JSONValue] = []
        for point in value.array {
            guard case .number(let t) = point["temperature"], case .number(let p) = point["percent"], t.isFinite, p.isFinite, (30...90).contains(t), (0...100).contains(p), t - previousT >= 5, p >= previousP else { return nil }
            previousT = t; previousP = p; points.append(["temperature": .number(t), "percent": .number(p)])
        }
        return previousP == 100 ? .array(points) : nil
    }
    private static func frame(_ value: String) -> JSONValue? {
        let fields = value.split(whereSeparator: { $0.isWhitespace }), parts = fields.compactMap { Double($0) }
        guard fields.count == 8, parts.count == 8, parts.allSatisfy({ $0.isFinite && abs($0) <= 1_000_000 }), parts[2] > 0, parts[3] > 0, parts[6] > 0, parts[7] > 0 else { return nil }; return .string(value)
    }
    private static func entry(_ value: Any) -> JSONValue {
        if let data = value as? Data { return ["type": "data", "value": .string(data.base64EncodedString())] }
        if let boolean = strictBool(value) { return ["type": "bool", "value": boolean] }
        if let integer = strictInteger(value) { return ["type": "integer", "value": .number(Double(integer))] }
        if let array = value as? [String] { return ["type": "strings", "value": .array(array.map(JSONValue.string))] }
        if let text = value as? String { return ["type": "string", "value": .string(text)] }; return .null
    }
    private static func propertyValue(_ entry: JSONValue) throws -> Any {
        switch entry["type"].string {
        case "data": guard let data = Data(base64Encoded: entry["value"].string) else { throw NativeFailure("Invalid migrated preference data") }; return data
        case "integer": return entry["value"].int
        default: return entry["value"].any
        }
    }
    private static func validateJournal(_ journal: JSONValue, domain: String) throws {
        guard Set(journal.object.keys) == ["version", "domain", "phase", "defaults", "files", "rejected", "warnings"], journal["version"] == 1, journal["domain"] == .string(domain), ["pending", "complete"].contains(journal["phase"].string), case .object = journal["defaults"], case .object = journal["files"], strings(journal["rejected"]) != nil, strings(journal["warnings"]) != nil else { throw NativeFailure("Preference migration journal is invalid; it was preserved") }
        var reconstructed: [String: String] = [:], legacy: [String: Any] = [:]
        for (key, entry) in journal["defaults"].object {
            guard Set(entry.object.keys) == ["type", "value"], ["string", "integer", "bool", "data", "strings"].contains(entry["type"].string) else { throw NativeFailure("Preference migration journal contains an invalid value") }
            let value = try propertyValue(entry)
            guard Self.entry(value) == entry else { throw NativeFailure("Preference migration journal has a wrong value type") }
            switch key {
            case "uniapi-theme": reconstructed["uniapi.theme"] = entry["value"].string
            case "uniapi-sidebar": reconstructed["uniapi.sidebar"] = entry["value"] == true ? "1" : entry["value"] == false ? "0" : "invalid"
            case "uniapi-native-page": guard ["home", "speed", "results", "stats", "switcher"].contains(entry["value"].string) else { throw NativeFailure("Invalid migrated page") }; legacy["uniapi-page"] = ["speed": "benchmark", "switcher": "claude"][entry["value"].string] ?? entry["value"].string
            case "NSWindow Frame UniApiMain": legacy[key] = value
            case "uniapi.fans.tab": let web = ["control": "overview", "timeline": "history", "sensors": "sensors", "curve": "curve", "settings": "settings"][entry["value"].string] ?? "invalid"; reconstructed["fans.tab"] = String(decoding: try JSONValue.string(web).encoded(), as: UTF8.self)
            case "uniapi.fans.range": reconstructed["fans.history.range"] = String(decoding: try entry["value"].encoded(), as: UTF8.self)
            case "uniapi.fans.duration", "uniapi.fans.boost": let seconds = entry["value"].int; guard seconds % 60 == 0 else { throw NativeFailure("Invalid migrated duration") }; reconstructed[key == "uniapi.fans.duration" ? "fans.duration" : "fans.boost"] = String(decoding: try JSONValue.string(seconds == 0 ? "never" : String(seconds / 60)).encoded(), as: UTF8.self)
            case "uniapi.fans.curve": guard let data = value as? Data else { throw NativeFailure("Invalid migrated curve") }; reconstructed["fans.curve"] = String(decoding: data, as: UTF8.self)
            case "uniapi.fans.favorites": reconstructed["fans.favorites"] = String(decoding: try entry["value"].encoded(), as: UTF8.self)
            default:
                guard webKeys.contains(key), !["uniapi.bench.sel", "uniapi.results.view.v1"].contains(key) else { throw NativeFailure("Preference migration journal contains an unowned key") }
                if key == "uniapi.stats.ttft.log" || key == "uniapi.transcribe.notify" { reconstructed[key] = entry["value"] == true ? "1" : entry["value"] == false ? "0" : "invalid" }
                else { reconstructed[key] = entry["value"].string }
            }
        }
        let normalized = plan(web: reconstructed, legacy: legacy, hub: [:], domain: domain, warnings: [])
        guard normalized["defaults"] == journal["defaults"] else { throw NativeFailure("Preference migration journal contains an invalid preference") }
        for (name, value) in journal["files"].object {
            if name == "native-selection" { guard selection(value) == value else { throw NativeFailure("Invalid migrated benchmark selection") } }
            else if name == "native-results-view" { var web = value; web["lastRunId"] = value["newestRun"]; web = .object(web.object.filter { $0.key != "newestRun" }); guard results(web) == value else { throw NativeFailure("Invalid migrated Results state") } }
            else { throw NativeFailure("Preference migration journal contains an unowned file") }
        }
    }
}

public struct NativePreferenceMigrationReport: Sendable {
    public let alreadyComplete: Bool, imported: [String], preserved: [String], rejected: [String], warnings: [String]
}

private enum PreferenceDisk {
    static func read(_ file: URL, root: URL, limit: Int = 32 * 1024 * 1024) throws -> Data? {
        // The declared home/root may be symlinked, but individual store files
        // and their directories may not redirect the bounded reader.
        let rootPath = root.standardizedFileURL.path, filePath = file.standardizedFileURL.path
        let prefix = rootPath.hasSuffix("/") ? rootPath : rootPath + "/"
        guard filePath.hasPrefix(prefix) else { throw NativeFailure("Preference source escaped its declared directory") }
        let components = filePath.dropFirst(prefix.count).split(separator: "/").map(String.init)
        guard let name = components.last, !components.contains(".."), !components.contains(".") else { throw NativeFailure("Invalid preference source path") }
        var parent = open(root.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        if parent < 0 { if errno == ENOENT { return nil }; throw NativeFailure("Preference source root is unavailable") }
        for component in components.dropLast() {
            let next = openat(parent, component, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC), code = errno
            close(parent); parent = next
            if parent < 0 { if code == ENOENT { return nil }; throw NativeFailure("Linked preference source directories are unsupported") }
        }
        let fd = openat(parent, name, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC), code = errno
        close(parent)
        if fd < 0 { if code == ENOENT { return nil }; throw NativeFailure("Preference source is not readable") }; defer { close(fd) }
        var before = stat(); guard fstat(fd, &before) == 0, before.st_mode & S_IFMT == S_IFREG, before.st_nlink == 1, before.st_uid == geteuid(), before.st_size >= 0, before.st_size <= limit else { throw NativeFailure("Preference source must be a bounded owned regular file") }
        var result = Data(), bytes = [UInt8](repeating: 0, count: 65536)
        while true { let count = Darwin.read(fd, &bytes, bytes.count); if count == 0 { break }; if count < 0 && errno == EINTR { continue }; guard count > 0, result.count + count <= limit else { throw NativeFailure("Preference source read failed") }; result.append(contentsOf: bytes.prefix(count)) }
        var after = stat(); guard fstat(fd, &after) == 0, stable(before, after), result.count == before.st_size else { throw NativeFailure("Preference source changed during its snapshot; retry migration") }; return result
    }
    static func stable(_ a: stat, _ b: stat) -> Bool { a.st_dev == b.st_dev && a.st_ino == b.st_ino && a.st_size == b.st_size && a.st_mtimespec.tv_sec == b.st_mtimespec.tv_sec && a.st_mtimespec.tv_nsec == b.st_mtimespec.tv_nsec && a.st_ctimespec.tv_sec == b.st_ctimespec.tv_sec && a.st_ctimespec.tv_nsec == b.st_ctimespec.tv_nsec }
    static func directory(root: URL, components: [String]) throws -> Int32 {
        var fd = open(root.resolvingSymlinksInPath().path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw NativeFailure("Preference destination root is unavailable") }
        for component in components {
            if mkdirat(fd, component, 0o700) != 0 && errno != EEXIST { close(fd); throw NativeFailure("Cannot create preference directory") }
            let next = openat(fd, component, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC); close(fd); fd = next
            var info = stat(); guard fd >= 0, fstat(fd, &info) == 0, info.st_uid == geteuid() else { if fd >= 0 { close(fd) }; throw NativeFailure("Preference directory must be owned and unlinked") }
        }
        return fd
    }
    @discardableResult static func publish(_ bytes: Data, directory: Int32, name: String, replace: Bool) throws -> Bool {
        let temporary = ".preferences-" + UUID().uuidString
        let fd = openat(directory, temporary, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw NativeFailure("Cannot prepare private preference file") }
        defer { close(fd); unlinkat(directory, temporary, 0) }
        try bytes.withUnsafeBytes { raw in var offset = 0; while offset < raw.count { let count = Darwin.write(fd, raw.baseAddress!.advanced(by: offset), raw.count - offset); if count < 0 && errno == EINTR { continue }; guard count > 0 else { throw NativeFailure("Cannot write private preference file") }; offset += count } }
        guard fsync(fd) == 0 else { throw NativeFailure("Cannot synchronize preference file") }
        if replace { guard renameat(directory, temporary, directory, name) == 0 else { throw NativeFailure("Cannot publish preference journal") } }
        else { if renameatx_np(directory, temporary, directory, name, UInt32(RENAME_EXCL)) != 0 { if errno == EEXIST { return false }; throw NativeFailure("Cannot publish migrated preference file") } }
        guard fsync(directory) == 0 else { throw NativeFailure("Cannot synchronize preference directory") }; return true
    }
}

private enum PreferenceWebStore {
    struct Snapshot { let values: [String: String], warnings: [String] }
    static func read(home: URL) throws -> Snapshot {
        let root = home.appendingPathComponent("Library/WebKit/app.devved.uniapi.hub")
        var folders: [(URL, Int)] = [(root, 0)], candidates: [URL] = [], visited = 0
        while let (folder, depth) = folders.popLast() {
            var info = stat(); if lstat(folder.path, &info) != 0 { if errno == ENOENT { continue }; throw NativeFailure("Legacy website storage discovery failed") }
            guard info.st_mode & S_IFMT == S_IFDIR, info.st_uid == geteuid() else { continue }
            visited += 1; guard visited <= 4096 else { throw NativeFailure("Legacy website storage exceeds its discovery bound") }
            for child in try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil) {
                var st = stat(); guard lstat(child.path, &st) == 0 else { throw NativeFailure("Legacy website storage changed during discovery") }
                if st.st_mode & S_IFMT == S_IFDIR, depth < 6 { folders.append((child, depth + 1)) }
                else if st.st_mode & S_IFMT == S_IFREG {
                    if child.lastPathComponent == "http_127.0.0.1_8780.localstorage" { candidates.append(child) }
                    else if child.lastPathComponent == "localstorage.sqlite3", folder.lastPathComponent == "LocalStorage", let marker = try PreferenceDisk.read(folder.deletingLastPathComponent().appendingPathComponent("origin"), root: home, limit: 4096), origin(marker) { candidates.append(child) }
                }
            }
        }
        // A current store wins over old on-disk layouts; WAL modification time
        // counts because the SQLite main file may not have been checkpointed.
        let newest = candidates.sorted {
            let left = modified($0), right = modified($1)
            if left != right { return left > right }
            let leftCurrent = $0.path.contains("/WebsiteData/Default/"), rightCurrent = $1.path.contains("/WebsiteData/Default/")
            if leftCurrent != rightCurrent { return leftCurrent }
            return $0.path < $1.path
        }.first
        guard let newest else { return .init(values: [:], warnings: []) }
        let captured = try snapshot(newest, home: home)
        return .init(values: captured.values, warnings: captured.warnings + (candidates.count > 1 ? ["Multiple confirmed UniApi website stores found; the newest complete store was used"] : []))
    }
    private static func modified(_ file: URL) -> Double { [file, URL(fileURLWithPath: file.path + "-wal")].map { path in var st = stat(); return lstat(path.path, &st) == 0 ? Double(st.st_mtimespec.tv_sec) + Double(st.st_mtimespec.tv_nsec) / 1e9 : 0 }.max() ?? 0 }
    /// WebKit serializes top and client origins independently: UInt32 LE string
    /// length, 8-bit flag, bytes; then optional UInt16 LE port. Both must match.
    static func origin(_ data: Data) -> Bool {
        let bytes = Array(data); var offset = 0
        func number(_ count: Int) -> UInt32? { guard offset + count <= bytes.count else { return nil }; var n: UInt32 = 0; for i in 0..<count { n |= UInt32(bytes[offset + i]) << (i * 8) }; offset += count; return n }
        func text() -> String? { guard let size = number(4), size <= 1024, let flag = number(1), flag == 1, offset + Int(size) <= bytes.count else { return nil }; defer { offset += Int(size) }; return String(bytes: bytes[offset..<offset + Int(size)], encoding: .utf8) }
        func one() -> Bool { guard text() == "http", text() == "127.0.0.1", number(1) == 1, number(2) == 8780 else { return false }; return true }
        return one() && one() && offset == bytes.count
    }
    private static func snapshot(_ file: URL, home: URL) throws -> Snapshot {
        let workspace = FileManager.default.temporaryDirectory.appendingPathComponent("uniapi-preference-snapshot-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700]); defer { try? FileManager.default.removeItem(at: workspace) }
        let destination = workspace.appendingPathComponent("store.sqlite3"), sourceFiles = [file, URL(fileURLWithPath: file.path + "-wal")]
        // Rebuild the mutable SHM index only in the private snapshot; copying
        // a concurrently mapped source index can make a valid WAL look stale.
        var finished = false
        for _ in 0..<3 {
            do {
            var before: [stat?] = [], copies: [Data?] = []
            for source in sourceFiles { var info = stat(); before.append(lstat(source.path, &info) == 0 ? info : nil); copies.append(try PreferenceDisk.read(source, root: home)) }
            let stable = sourceFiles.indices.allSatisfy { index in var after = stat(); let exists = lstat(sourceFiles[index].path, &after) == 0; return before[index].map { exists && PreferenceDisk.stable($0, after) } ?? !exists }
            if !stable { continue }
            guard copies[0] != nil else { throw NativeFailure("Confirmed website preferences disappeared") }
            for i in sourceFiles.indices { if let bytes = copies[i] { try NativeFile.writeAtomic(bytes, to: URL(fileURLWithPath: destination.path + ["", "-wal"][i])) } }
            finished = true; break
            } catch let error as NativeFailure where error.message.contains("changed during") { continue }
        }
        guard finished else { throw NativeFailure("Website preferences are changing; retry migration") }
        var database: OpaquePointer?
        guard sqlite3_open_v2(destination.path, &database, SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK, let database else { if let database { sqlite3_close(database) }; throw NativeFailure("Website preference snapshot could not be opened") }
        defer { sqlite3_close(database) }; sqlite3_busy_timeout(database, 250)
        var values: [String: String] = [:], warnings: [String] = []
        for key in NativePreferences.webKeys {
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(database, "SELECT value FROM ItemTable WHERE key=? LIMIT 2", -1, &statement, nil) == SQLITE_OK, let statement else { if let statement { sqlite3_finalize(statement) }; throw NativeFailure("Confirmed website storage has no readable localStorage table") }
            defer { sqlite3_finalize(statement) }
            let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
            guard key.withCString({ sqlite3_bind_text(statement, 1, $0, -1, transient) }) == SQLITE_OK else { throw NativeFailure("Website preference query failed") }
            let step = sqlite3_step(statement)
            if step == SQLITE_DONE { continue }
            guard step == SQLITE_ROW else { throw NativeFailure("Website preference snapshot is invalid") }
            let size = Int(sqlite3_column_bytes(statement, 0)), kind = sqlite3_column_type(statement, 0)
            if size <= 8 * 1024 * 1024 && [SQLITE_TEXT, SQLITE_BLOB].contains(kind) {
                let bytes = sqlite3_column_blob(statement, 0).map { Data(bytes: $0, count: size) } ?? Data()
                let text = kind == SQLITE_BLOB ? utf16(bytes) : String(data: bytes, encoding: .utf8)
                if let text { values[key] = text } else { warnings.append("Malformed string for " + key + " was skipped; the source was preserved") }
            } else { warnings.append("Unsupported or oversized value for " + key + " was skipped; the source was preserved") }
            guard sqlite3_step(statement) == SQLITE_DONE else { throw NativeFailure("Website preference key is ambiguous or unreadable") }
        }
        return .init(values: values, warnings: warnings)
    }
    private static func utf16(_ data: Data) -> String? {
        guard data.count % 2 == 0 else { return nil }
        let big = data.starts(with: [0xfe, 0xff]), bom = big || data.starts(with: [0xff, 0xfe])
        let bytes = Array(data); var index = bom ? 2 : 0, output = String.UnicodeScalarView()
        func unit(_ index: Int) -> UInt32 { big ? (UInt32(bytes[index]) << 8) | UInt32(bytes[index + 1]) : UInt32(bytes[index]) | (UInt32(bytes[index + 1]) << 8) }
        while index < bytes.count {
            let first = unit(index); index += 2; let code: UInt32
            if (0xd800...0xdbff).contains(first) {
                guard index < bytes.count else { return nil }; let second = unit(index); index += 2
                guard (0xdc00...0xdfff).contains(second) else { return nil }
                code = 0x10000 + ((first - 0xd800) << 10) + second - 0xdc00
            } else { guard !(0xdc00...0xdfff).contains(first) else { return nil }; code = first }
            guard let scalar = UnicodeScalar(code) else { return nil }; output.append(scalar)
        }
        return String(output)
    }
}
