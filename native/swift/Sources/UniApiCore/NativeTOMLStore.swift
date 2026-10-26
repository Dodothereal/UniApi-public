import Foundation
import Darwin

public enum NativeCodexWriteOperation: Equatable, Sendable { case select, restore }
public enum NativeCodexPublicationPoint: Equatable, Sendable {
    case beforeConfigRename(NativeCodexWriteOperation)
    case afterConfigRename(NativeCodexWriteOperation)
}

/// Owns only Codex defaults and an exact marked provider block. Pending phases
/// are recoverable; a successful selection retires its prior generation before
/// acknowledgment. Native routing and the optional bridge have separate
/// transport/catalog ownership journals.
public final class NativeCodexSettingsStore: @unchecked Sendable {
    public let configPath: URL, stateDirectory: URL
    private let mutex = NSRecursiveLock()
    private let publicationHook: @Sendable (NativeCodexPublicationPoint) throws -> Void
    public var journalPath: URL { stateDirectory.appendingPathComponent("defaults-journal.json") }
    /// The hook is a fixture seam at the real publication boundary: before
    /// rename runs after the private temporary file has been written/fsynced;
    /// after rename runs before journal commit/removal. Production is a no-op.
    public init(configPath: URL, stateDirectory: URL, publicationHook: @escaping @Sendable (NativeCodexPublicationPoint) throws -> Void = { _ in }) {
        self.configPath = configPath; self.stateDirectory = stateDirectory; self.publicationHook = publicationHook
    }
    public func read() throws -> (text: String, config: JSONObject) {
        let text = try SwitcherDisk.text(configPath); return (text, try NativeTOML.parse(text))
    }
    public func hasRestore() throws -> Bool { try journal() != nil }
    private func journal() throws -> JSONValue? {
        let data = try SwitcherDisk.read(journalPath); if data.isEmpty { return nil }
        let value = try JSONValue.decode(data), phase = value["phase"].string
        func defaults(_ fields: JSONValue) -> Bool {
            if case .object = fields { return Set(fields.object.keys).isSubset(of: Set(NativeTOML.defaultKeys)) && fields.object.values.allSatisfy { field in field.isNull || { if case .string = field { return true }; return false }() } }; return false
        }
        func block(_ value: JSONValue) -> Bool { value.isNull || { if case .string = value { return true }; return false }() }
        guard value["version"] == 1, value["configPath"] == .string(configPath.path), defaults(value["previous"]), defaults(value["installed"]),
              Set(value["previous"].object.keys) == Set(value["installed"].object.keys), block(value["providerBlock"]),
              value["backupPath"].string.hasPrefix(stateDirectory.standardizedFileURL.path + "/"),
              value["phase"].isNull || ["pending-select", "committed", "pending-restore"].contains(phase) else { throw NativeFailure("Codex defaults recovery journal does not match this configuration") }
        if !value["priorGeneration"].isNull {
            let prior = value["priorGeneration"]
            guard value["phase"].isNull || phase == "pending-select", case .bool = prior["owned"], case .object = prior["values"],
                  Set(prior["values"].object.keys) == Set(value["installed"].object.keys), block(prior["providerBlock"]), defaults(prior["previous"]), defaults(prior["installed"]),
                  Set(prior["previous"].object.keys) == Set(prior["installed"].object.keys), Set(prior["installed"].object.keys).isSubset(of: Set(prior["values"].object.keys)),
                  prior["owned"].bool || (prior["previous"].object.isEmpty && prior["installed"].object.isEmpty && prior["providerBlock"].isNull) else { throw NativeFailure("Invalid prior Codex defaults generation") }
        } else if phase == "pending-select" { throw NativeFailure("Pending Codex selection is missing its prior generation") }
        if phase == "pending-restore" {
            let restore = value["restoreGeneration"]
            guard defaults(restore["values"]), Set(value["installed"].object.keys).isSubset(of: Set(restore["values"].object.keys)),
                  case .bool = restore["providerRemoved"], case .bool = restore["owned"], case .object = restore["beforeValues"],
                  Set(restore["beforeValues"].object.keys) == Set(restore["values"].object.keys),
                  value["priorGeneration"].isNull else { throw NativeFailure("Invalid pending Codex restoration") }
        } else if !value["restoreGeneration"].isNull { throw NativeFailure("Unexpected pending Codex restoration") }
        return value
    }
    private func matches(_ config: JSONObject, _ values: JSONValue) -> Bool { values.object.allSatisfy { (config[$0.key] ?? .null) == $0.value } }
    private func present(_ text: String, block: JSONValue) throws -> Bool {
        guard !block.string.isEmpty else { return false }
        return try NativeTOML.ownedProviderBlockRange(text, block: block.string) != nil
    }
    private func installed(_ text: String, _ config: JSONObject, _ journal: JSONValue) throws -> Bool {
        guard matches(config, journal["installed"]) else { return false }
        return try present(text, block: journal["providerBlock"]) == !journal["providerBlock"].string.isEmpty
    }
    private func committed(_ journal: JSONValue) -> JSONValue {
        var result = JSONValue.object(journal.object.filter { !["priorGeneration", "restoreGeneration"].contains($0.key) }); result["phase"] = "committed"; return result
    }
    private func checked() throws -> (String, JSONObject, JSONValue?) {
        let (text, config) = try read(); guard let journal = try journal() else { return (text, config, nil) }
        let phase = journal["phase"].string
        if phase == "pending-restore" {
            let restore = journal["restoreGeneration"]
            if matches(config, restore["values"]), restore["providerRemoved"] != true || (config["model_providers"]?["uniapi_managed"].isNull ?? true) {
                try FileManager.default.removeItem(at: journalPath); return (text, config, nil)
            }
            if matches(config, restore["beforeValues"]), try present(text, block: journal["providerBlock"]) == !journal["providerBlock"].string.isEmpty {
                if restore["owned"] != true { try FileManager.default.removeItem(at: journalPath); return (text, config, nil) }
                let saved = committed(journal); try SwitcherDisk.atomic(journalPath, try saved.encoded(pretty: true)); return (text, config, saved)
            }
        }
        if try installed(text, config, journal) {
            if phase != "committed" {
                let saved = committed(journal); try SwitcherDisk.atomic(journalPath, try saved.encoded(pretty: true)); return (text, config, saved)
            }
            return (text, config, journal)
        }
        // Only an explicitly pending selection may authorize rollback. Old
        // journals lack commit evidence, so a prior-value edit fails closed.
        if phase == "pending-select" {
            let prior = journal["priorGeneration"]
            if matches(config, prior["values"]), try present(text, block: prior["providerBlock"]) == !prior["providerBlock"].string.isEmpty,
               !(try present(text, block: journal["providerBlock"])) || journal["providerBlock"] == prior["providerBlock"] {
                if !prior["owned"].bool { try FileManager.default.removeItem(at: journalPath); return (text, config, nil) }
                var saved = committed(journal); saved["previous"] = prior["previous"]; saved["installed"] = prior["installed"]; saved["providerBlock"] = prior["providerBlock"]
                try SwitcherDisk.atomic(journalPath, try saved.encoded(pretty: true)); return (text, config, saved)
            }
        }
        if phase != "pending-restore", !(try present(text, block: journal["providerBlock"])), matches(config, journal["previous"]) {
            try FileManager.default.removeItem(at: journalPath); return (text, config, nil)
        }
        throw NativeFailure("Codex owned settings changed outside UniApi; restoration is paused to preserve that edit. The original is in the private backup, and ownership can be released by deleting the defaults journal.")
    }
    public func assertRestorable() throws { mutex.lock(); defer { mutex.unlock() }; try SwitcherDisk.locked(configPath) { _ = try checked() } }
    public func select(_ values: JSONObject, provider: JSONValue? = nil) throws {
        mutex.lock(); defer { mutex.unlock() }
        try SwitcherDisk.locked(configPath) {
            let (text, config, oldJournal) = try checked()
            var journal: JSONValue = oldJournal ?? ["version": 1, "configPath": .string(configPath.path), "previous": [:], "installed": [:], "providerBlock": .null,
                "backupPath": .string(stateDirectory.appendingPathComponent("config-" + UUID().uuidString + ".toml").path)]
            var output = text, changed = values
            let priorBlock = journal["providerBlock"].string
            if !priorBlock.isEmpty {
                output = try NativeTOML.removingOwnedProviderBlock(output, block: priorBlock); journal["providerBlock"] = .null
                if provider == nil { changed["model_provider"] = journal["previous"]["model_provider"] }
            }
            if let provider {
                guard try NativeTOML.parse(output)["model_providers"]?["uniapi_managed"].isNull ?? true else { throw NativeFailure("The reserved UniApi provider ID already belongs to another configuration") }
                guard SwitcherDisk.validLabel(provider["name"]), let url = URL(string: provider["baseUrl"].string), ["http", "https"].contains(url.scheme ?? ""), url.host != nil, url.user == nil, url.password == nil else { throw NativeFailure("Invalid managed Codex provider") }
                var block = "\n# UniApi managed Codex provider: begin\n[model_providers.uniapi_managed]\n"
                block += "name = " + (try NativeTOML.quote(provider["name"].string)) + "\nbase_url = " + (try NativeTOML.quote(url.absoluteString)) + "\nwire_api = \"responses\"\nrequires_openai_auth = false\nsupports_websockets = false\n"
                if !provider["apiKey"].string.isEmpty { block += "experimental_bearer_token = " + (try NativeTOML.quote(provider["apiKey"].string)) + "\n" }
                block += "# UniApi managed Codex provider: end\n"; journal["providerBlock"] = .string(block); output += block; changed["model_provider"] = "uniapi_managed"
            }
            for (key, value) in changed {
                var previous = journal["previous"], installed = journal["installed"]
                if previous.object[key] == nil { if let found = config[key], case .string = found { previous[key] = found } else { previous[key] = .null } }
                installed[key] = value; journal["previous"] = previous; journal["installed"] = installed
            }
            output = try NativeTOML.patchDefaults(output, values: changed); if output == text { return }
            if oldJournal == nil { try SwitcherDisk.atomic(URL(fileURLWithPath: journal["backupPath"].string), Data(text.utf8)) }
            let priorValues = Dictionary(uniqueKeysWithValues: journal["installed"].object.keys.map { ($0, config[$0] ?? .null) })
            journal["phase"] = "pending-select"; journal["priorGeneration"] = ["owned": .bool(oldJournal != nil), "values": .object(priorValues),
                "previous": oldJournal?["previous"] ?? [:], "installed": oldJournal?["installed"] ?? [:], "providerBlock": oldJournal?["providerBlock"] ?? .null]
            try SwitcherDisk.atomic(journalPath, try journal.encoded(pretty: true))
            try publishConfig(Data(output.utf8), expected: Data(text.utf8), operation: .select)
            try SwitcherDisk.atomic(journalPath, try committed(journal).encoded(pretty: true))
        }
    }
    public func restore(clearWebDefault: Bool = false) throws {
        mutex.lock(); defer { mutex.unlock() }
        try SwitcherDisk.locked(configPath) {
            let (text, config, journal) = try checked()
            func routed(_ value: JSONValue) -> Bool { value.string.hasPrefix("chatgpt-web/") || value.string.hasPrefix("uniapi/") }
            guard journal != nil || (clearWebDefault && routed(config["model"] ?? .null)) else { return }
            var output = text
            if let journal, !journal["providerBlock"].string.isEmpty { output = try NativeTOML.removingOwnedProviderBlock(output, block: journal["providerBlock"].string) }
            output = try NativeTOML.patchDefaults(output, values: journal?["previous"].object ?? [:])
            let restored = try NativeTOML.parse(output)
            let clearRouted = clearWebDefault && routed(restored["model"] ?? .null)
            if clearRouted { output = try NativeTOML.patchDefaults(output, values: ["model": .null, "model_reasoning_effort": .null]) }
            var pending: JSONValue
            if let journal { pending = committed(journal) }
            else {
                let backup = stateDirectory.appendingPathComponent("web-default-" + UUID().uuidString + ".toml")
                try SwitcherDisk.atomic(backup, Data(text.utf8))
                let before = Dictionary(uniqueKeysWithValues: ["model", "model_reasoning_effort"].map { key -> (String, JSONValue) in
                    if let value = config[key], case .string = value { return (key, value) }; return (key, .null)
                })
                pending = ["version": 1, "configPath": .string(configPath.path), "backupPath": .string(backup.path), "previous": .object(before), "installed": .object(before), "providerBlock": .null]
            }
            let after = try NativeTOML.parse(output), keys = Set(pending["installed"].object.keys).union(clearRouted ? ["model", "model_reasoning_effort"] : [])
            let finalValues = Dictionary(uniqueKeysWithValues: keys.map { ($0, after[$0] ?? .null) })
            let beforeValues = Dictionary(uniqueKeysWithValues: keys.map { ($0, config[$0] ?? .null) })
            pending["phase"] = "pending-restore"; pending["restoreGeneration"] = ["values": .object(finalValues), "beforeValues": .object(beforeValues),
                "owned": .bool(journal != nil), "providerRemoved": .bool(!pending["providerBlock"].string.isEmpty)]
            try SwitcherDisk.atomic(journalPath, try pending.encoded(pretty: true))
            try publishConfig(Data(output.utf8), expected: Data(text.utf8), operation: .restore)
            try FileManager.default.removeItem(at: journalPath)
        }
    }
    private func publishConfig(_ data: Data, expected: Data, operation: NativeCodexWriteOperation) throws {
        let directory = configPath.deletingLastPathComponent(), temporary = directory.appendingPathComponent(".uniapi-defaults-" + UUID().uuidString + ".tmp")
        let fd = open(temporary.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw NativeFailure("Cannot prepare a private Codex config update") }
        defer { close(fd); try? FileManager.default.removeItem(at: temporary) }
        try data.withUnsafeBytes { bytes in var offset = 0; while offset < bytes.count { let count = Darwin.write(fd, bytes.baseAddress!.advanced(by: offset), bytes.count - offset); if count < 0 && errno == EINTR { continue }; guard count > 0 else { throw NativeFailure("Cannot write Codex config update") }; offset += count } }
        guard fsync(fd) == 0 else { throw NativeFailure("Cannot synchronize Codex config update") }
        try publicationHook(.beforeConfigRename(operation))
        guard try SwitcherDisk.read(configPath) == expected else { throw NativeFailure("Configuration changed during this operation; the other edit was preserved") }
        guard rename(temporary.path, configPath.path) == 0 else { throw NativeFailure("Cannot publish Codex config update") }
        let parent = open(directory.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard parent >= 0 else { throw NativeFailure("Cannot synchronize Codex config directory") }; defer { close(parent) }
        guard fsync(parent) == 0 else { throw NativeFailure("Cannot synchronize Codex config directory") }
        try publicationHook(.afterConfigRename(operation))
    }
}

/// A completed explicit restore initializes the picker from the restored
/// defaults. Polls, failures and unrelated saves retain the user's draft.
public extension NativeSwitcherSelectionDraft {
    mutating func acceptCompletedAction(_ operation: String, input: JSONObject, result: JSONValue) {
        guard operation == "codexAction", input["action"] == "restore", result["ok"] == true, !result["status"].isNull else { return }
        self = .init(); accept(result["status"])
    }
}
public extension NativeSwitcherDisplayPolicies {
    /// Matches the web picker's keyboard choice: a proposed custom row wins;
    /// otherwise Enter chooses the first filtered catalog row.
    static func claudeSubmitChoice(models: [String], query: String) -> String? {
        let custom = query.trimmingCharacters(in: .whitespacesAndNewlines)
        if models.contains(custom) { return custom }
        if !custom.isEmpty && !models.contains(custom) { return custom }
        return matchingModels(models, query: query).first
    }
}
