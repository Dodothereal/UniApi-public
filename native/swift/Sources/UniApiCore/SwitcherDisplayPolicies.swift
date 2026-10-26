import Foundation

public struct NativeSwitcherModelKey: Hashable, Sendable {
    public let source: String, providerID: String?, model: String
    public init(_ row: JSONValue) {
        source = row["source"].string; providerID = row["providerId"].isNull ? nil : row["providerId"].string; model = row["id"].string
    }
    public func matches(_ current: JSONValue) -> Bool {
        source == current["source"].string && providerID == (current["providerId"].isNull ? nil : current["providerId"].string) && model == current["model"].string
    }
}

public struct NativeSwitcherSelectionDraft: Equatable, Sendable {
    public private(set) var initialized = false
    public var key: NativeSwitcherModelKey?, effort = ""
    public init() {}
    public mutating func accept(_ status: JSONValue) {
        guard !initialized, !status.isNull else { return }; initialized = true
        let row = status["models"].array.first { NativeSwitcherModelKey($0).matches(status["current"]) }
        key = row.map(NativeSwitcherModelKey.init)
        effort = Self.supportedEffort(row, status["current"]["effort"].string)
    }
    public mutating func choose(_ row: JSONValue?) { key = row.map(NativeSwitcherModelKey.init); effort = Self.supportedEffort(row, effort) }
    public static func supportedEffort(_ row: JSONValue?, _ effort: String) -> String { row?["efforts"].array.contains(.string(effort)) == true ? effort : "" }
}

/// Polls update the saved baseline, never an unfinished editor. Worker order defines roster slots.
public struct NativeSwitcherCatalogDraft: Equatable, Sendable {
    public private(set) var initialized = false
    public private(set) var providerIDs = Set<String>(), workers: [String] = []
    public private(set) var savedProviderIDs = Set<String>(), savedWorkers: [String] = []
    public init() {}
    public var dirty: Bool { providerIDs != savedProviderIDs || workers != savedWorkers }
    public var body: JSONObject { ["providerIds": .array(providerIDs.sorted().map(JSONValue.string)), "workerModels": .array(workers.map(JSONValue.string))] }
    public mutating func accept(_ catalog: JSONValue) {
        guard !catalog.isNull else { return }
        let wasDirty = dirty
        let providers = Set(catalog["providerIds"].array.map(\.string)), nextWorkers = catalog["workerModels"].array.map(\.string)
        if !initialized || providers != savedProviderIDs || nextWorkers != savedWorkers {
            if !initialized || !wasDirty { providerIDs = providers; workers = nextWorkers }
            savedProviderIDs = providers; savedWorkers = nextWorkers; initialized = true
        }
    }
    public mutating func toggleProvider(_ provider: JSONValue, models: [JSONValue]) {
        let id = provider["id"].string
        if providerIDs.contains(id) {
            providerIDs.remove(id)
            let removed = Set(models.filter { $0["source"] == "provider" && $0["providerId"].string == id }.map(Self.workerID))
            let prefix = "uniapi/" + NativeProviderInfo.encoded(id) + "/"
            workers.removeAll { removed.contains($0) || $0.hasPrefix(prefix) }
        } else if provider["available"] == true { providerIDs.insert(id) }
    }
    public mutating func toggleWorker(_ model: JSONValue) {
        let key = Self.workerID(model)
        if workers.contains(key) { workers.removeAll { $0 == key }; return }
        guard model["available"] == true, model["workerReserved"] != true, workers.count < 4,
              model["source"] != "provider" || providerIDs.contains(model["providerId"].string) else { return }
        workers.append(key)
    }
    public static func workerID(_ model: JSONValue) -> String { model["catalogId"].string.isEmpty ? model["id"].string : model["catalogId"].string }
    public func visibleProviders(_ rows: [JSONValue]) -> [JSONValue] {
        rows + providerIDs.sorted().filter { id in !rows.contains { $0["id"].string == id } }.map {
            ["id": .string($0), "name": .string($0), "available": false, "reason": "This provider is no longer listed. Remove it from the catalog."]
        }
    }
    public func visibleWorkers(_ rows: [JSONValue]) -> [JSONValue] {
        var found = Set<String>()
        var shown = rows.filter { $0["source"] != "provider" || providerIDs.contains($0["providerId"].string) }.filter { found.insert(Self.workerID($0)).inserted }
        for key in workers where !found.contains(key) {
            let parsed = NativeCodexCatalogStore.parseID(key)
            shown.append(["id": .string(parsed?.model ?? key), "catalogId": .string(key), "name": .string(key), "source": parsed == nil ? "subscription" : "provider", "providerId": parsed.map { .string($0.provider) } ?? .null,
                          "available": false, "reason": "This model is no longer listed. Remove it from preferred workers."])
        }
        return shown
    }
}

public enum NativeSwitcherDisplayPolicies {
    public static func engine(_ value: String) -> String { value == "codex" ? "codex" : "claude" }
    public static func checksRunning(_ jobs: [JSONValue]) -> Bool {
        jobs.contains { ["switcher.codex.verify", "switcher.codex.provider"].contains($0["kind"].string) && ["queued", "running"].contains($0["status"].string) }
    }
    public static func matchingModels(_ models: [String], query: String) -> [String] {
        let words = query.lowercased().split(whereSeparator: \.isWhitespace)
        return Array(Set(models)).sorted().filter { id in words.allSatisfy { id.lowercased().contains($0) } }
    }
    public static func selectionIssue(_ status: JSONValue, model: JSONValue?) -> String? {
        if status["installed"] != true { return "Codex is not installed." }
        if !status["configError"].isNull { return "Fix the Codex configuration error before changing its default." }
        if status["bridge"]["busy"] == true { return "The bridge is handling a request. Wait before changing its default." }
        guard let model else { return "Choose a model from this source." }
        if model["available"] != true { return model["reason"].string.isEmpty ? "This model is unavailable." : model["reason"].string }
        if model["source"] == "provider", status["bridge"]["integrated"] == true,
           !(status["catalog"]["supported"] == true && status["catalog"]["enabled"] == true && status["catalog"]["providerIds"].array.contains(model["providerId"])) {
            return "Add this provider to Models in Codex and save the catalog before setting it as the default."
        }
        if model["source"] != "provider", status["current"]["source"] == "provider", status["restoreAvailable"] != true { return "This provider is managed outside UniApi. Restore its routing before choosing another source." }
        return nil
    }
    public static func catalogIssue(_ status: JSONValue) -> String? {
        if status["catalog"]["supported"] != true { return "Shared model catalogs require a running bridge with catalog support." }
        if status["installed"] != true { return "Install Codex before saving its model catalog." }
        if !status["configError"].isNull { return "Fix the Codex configuration error before saving its model catalog." }
        if status["bridge"]["busy"] == true { return "The bridge is handling a request. Wait before saving its model catalog." }
        return nil
    }
}
