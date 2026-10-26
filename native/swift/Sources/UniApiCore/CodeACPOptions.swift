import Foundation

/// ACP IDs belong to the agent. Display categories do not name RPC config IDs,
/// and a mode exposed as a config option is not a session/set_mode endpoint.
struct CodeACPOptions: Sendable {
    private(set) var rows: [String: [JSONValue]] = ["model": [], "effort": [], "permission_mode": []]
    private(set) var current: [String: JSONValue] = [:]
    private var defaults: [String: JSONValue] = [:]
    private var configIDs: [String: String] = [:]
    private var sessionModes = false
    private static func same(_ a: String, _ b: String) -> Bool { Data(a.utf8) == Data(b.utf8) }
    private func contains(_ key: String, _ value: JSONValue) -> Bool {
        guard case .string(let id) = value else { return false }
        return rows[key, default: []].contains { Self.same($0["value"].string, id) }
    }
    private static func unique(_ rows: [JSONValue]) -> [JSONValue] {
        var seen = Set<Data>()
        return rows.compactMap { row -> JSONValue? in
            guard case .string(let value) = row["value"], seen.insert(Data(value.utf8)).inserted else { return nil }
            var row = row; if row["displayName"].string.isEmpty { row["displayName"] = .string(value) }; return row
        }
    }
    mutating func read(_ response: JSONValue) {
        if case .array = response["modes"]["availableModes"] {
            rows["permission_mode"] = Self.unique(response["modes"]["availableModes"].array.map { ["value": $0["id"], "displayName": $0["name"], "description": $0["description"]] })
            sessionModes = !rows["permission_mode", default: []].isEmpty
            if sessionModes { configIDs["permission_mode"] = nil }
            remember("permission_mode", response["modes"]["currentModeId"])
        }
        for option in response["configOptions"].array {
            guard case .string(let id) = option["id"], !id.isEmpty else { continue }
            let category = option["category"].string
            let key: String?
            // An agent may use a legacy-looking ID for another category.
            // Partial updates retain the already advertised binding as well.
            if category == "model" { key = "model" }
            else if category == "thought_level" { key = "effort" }
            else if category == "mode" { key = sessionModes ? nil : "permission_mode" }
            else if let known = configIDs.first(where: { Self.same($0.value, id) })?.key { key = known }
            else if id == "model" { key = "model" }
            else if id == "effort" { key = "effort" }
            else { key = nil }
            guard let key else { continue }
            if option["type"] == "select" {
                configIDs[key] = id
                if case .array = option["options"] { rows[key] = Self.unique(CodeRoutes.choices(option["options"])) }
            }
            // Partial notifications can update just currentValue. They cannot
            // erase prior choices/IDs, or silently retarget an advertised field.
            guard configIDs[key].map({ Self.same($0, id) }) == true else { continue }
            remember(key, option["currentValue"])
        }
        for key in Array(current.keys) where !contains(key, current[key]!) { current[key] = nil }
    }
    private mutating func remember(_ key: String, _ value: JSONValue) {
        guard contains(key, value) else { return }
        current[key] = value
        if defaults[key] == nil { defaults[key] = value }
    }
    mutating func modeChanged(_ value: JSONValue) -> Bool {
        guard contains("permission_mode", value) else { return false }
        remember("permission_mode", value); return true
    }
    struct Request: Sendable { let method: String, params: JSONValue, value: JSONValue }
    func request(_ key: String, value requested: JSONValue, session: String) throws -> Request {
        let value: JSONValue
        if requested.isNull || requested == "" && !contains(key, requested) {
            value = rows[key, default: []].first(where: { $0["value"] == "default" })?["value"] ?? defaults[key] ?? requested
        } else { value = requested }
        guard contains(key, value) else { throw NativeFailure("The agent does not advertise this \(key) choice") }
        if key == "permission_mode", sessionModes { return Request(method: "session/set_mode", params: ["sessionId": .string(session), "modeId": value], value: value) }
        guard let config = configIDs[key] else { throw NativeFailure("The agent does not advertise a \(key) configuration endpoint") }
        return Request(method: "session/set_config_option", params: ["sessionId": .string(session), "configId": .string(config), "value": value], value: value)
    }
    mutating func selected(_ key: String, value: JSONValue) { remember(key, value) }
    var json: JSONValue {
        ["advertised": true, "models": .array(rows["model", default: []]), "efforts": .array(rows["effort", default: []]), "modes": .array(rows["permission_mode", default: []]), "current": .object(current), "configIds": .object(configIDs.mapValues(JSONValue.string))]
    }
    var threadPatch: JSONObject { current }
}

/// The native controls use only advertised ACP choices. An old persisted value
/// remains visible as unavailable instead of becoming a fabricated agent mode.
public enum CodeSessionChoices {
    public static func effective(route: JSONValue, options: JSONValue) -> JSONValue {
        route["kind"] == "agent" && !options["advertised"].bool ? route["agent"]["options"] : options
    }
    public static func models(route: JSONValue, options: JSONValue) -> [JSONValue] {
        var route = route
        let advertised = effective(route: route, options: options)
        if route["kind"] == "agent", advertised["advertised"].bool { route["models"] = [] }
        return CodeModelChoices.choices(route: route, options: advertised)
    }
    public static func modes(route: JSONValue, options: JSONValue, current: String) -> [JSONValue] {
        if route["kind"] != "agent" { return [
            ["value": "default", "displayName": "Ask", "available": true], ["value": "acceptEdits", "displayName": "Accept edits", "available": true],
            ["value": "plan", "displayName": "Plan", "available": true], ["value": "bypassPermissions", "displayName": "Bypass", "available": true]
        ] }
        let source = effective(route: route, options: options)["modes"].array
        if source.isEmpty {
            // Legacy agents may expose no mode RPC. These remain client-side
            // file/permission policies and are labelled as such, never sent as
            // invented ACP mode IDs.
            var local: [JSONValue] = [["value": "", "displayName": "Agent default", "available": true],
                    ["value": "default", "displayName": "Ask (local guard)", "available": true],
                    ["value": "acceptEdits", "displayName": "Accept edits (local guard)", "available": true],
                    ["value": "plan", "displayName": "Plan (local guard)", "available": true],
                    ["value": "bypassPermissions", "displayName": "Bypass (local guard)", "available": true]]
            if !local.contains(where: { $0["value"].string == current }) { local.insert(["value": .string(current), "displayName": .string(current + " (not advertised)"), "available": false], at: 0) }
            return local
        }
        var rows = source.map { row -> JSONValue in var row = row; row["available"] = true; return row }
        if !rows.contains(where: { Data($0["value"].string.utf8) == Data(current.utf8) }) {
            rows.insert(["value": .string(current), "displayName": .string(current.isEmpty ? "Agent default" : current + " (not advertised)"), "available": false], at: 0)
        }
        return rows
    }
}
