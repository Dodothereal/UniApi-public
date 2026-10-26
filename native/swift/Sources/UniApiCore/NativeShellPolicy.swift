import Foundation

/// Shared display decisions keep failed reads distinct from empty user state.
public enum NativeShellPolicy {
    public struct Route: Equatable, Sendable {
        public let name: String
        public let model: String
        public let effort: String
    }
    public struct Shim: Equatable, Sendable {
        public enum State: Equatable, Sendable { case checking, up, legacy, down }
        public let state: State
        public let text: String
    }
    public static func route(_ status: JSONValue, dashboard: JSONValue = .null) -> Route {
        if status["error"].isNull, !status["currentName"].string.isEmpty {
            let snapshot = status["snapshot"]
            return Route(name: status["currentName"].string,
                model: snapshot["model"].string.isEmpty ? "No model pinned · Claude Code chooses" : snapshot["model"].string,
                effort: snapshot["effort"].string.isEmpty ? "default" : snapshot["effort"].string)
        }
        let failed = !status["error"].isNull || dashboard["settingsReadable"] == false
        return Route(name: failed ? "Route unavailable" : "Reading route…", model: failed ? "Model unavailable" : "Reading model…", effort: failed ? "unavailable" : "…")
    }
    public static func shim(_ status: JSONValue) -> Shim {
        let shim = status["shim"]
        guard !shim.isNull else { return .init(state: status["error"].isNull ? .checking : .down, text: status["error"].isNull ? "Checking shim" : "Shim status unavailable") }
        let routes = shim["providers"].isNull ? "route count unavailable" : "\(shim["providers"].array.count) routes"
        if shim["ok"] == true { return .init(state: .up, text: (shim["owned"] == true ? "Owned Swift shim up · " : "Swift shim up · ") + routes) }
        if shim["legacyPresent"] == true { return .init(state: .legacy, text: "Legacy listener preserved · " + routes) }
        return .init(state: .down, text: "Swift shim down")
    }
    public static func refreshesHome(_ topic: String) -> Bool {
        ["job.updated", "switcher.changed", "code.thread", "code.thread.deleted", "code.projects", "arena.match", "arena.match.deleted", "transcribe.updated", "transcribe.deleted", "bench.started", "bench.finished", "bench.catalog", "stats.cached", "stats.scanned", "stats.failed"].contains(topic) || topic.hasPrefix("code.permission")
    }
    /// Unknown capability keeps navigation available; only a measured false hides it.
    public static func admits(_ destination: String, batterySupported: JSONValue) -> Bool {
        destination != "battery" || batterySupported != false
    }
    public static func startup(readOnly: Bool, prepared: Bool, sessionError: String?, health: JSONValue, pid: Int, instance: String) -> String {
        if let sessionError, !sessionError.isEmpty { return "Startup failed: " + sessionError }
        if !prepared { return "Preparing local storage" }
        if readOnly { return "Read-only preview · writable startup not checked" }
        guard health["schema"] == 2, health["runtime"] == "swift", health["pid"].int == pid, health["instance"].string == instance else { return "Startup not yet confirmed" }
        if !health["error"].string.isEmpty { return "Startup failed: " + health["error"].string }
        return health["ready"] == true ? "Ready" : "Startup not yet confirmed"
    }
}
