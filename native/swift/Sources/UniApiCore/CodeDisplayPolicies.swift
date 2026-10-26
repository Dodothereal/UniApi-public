import Foundation

public enum CodeProjectSelection {
    public static func resolve(_ saved: String, projects: [JSONValue]) -> String {
        projects.contains { $0["id"].string == saved } ? saved : projects.first?["id"].string ?? ""
    }
}

public struct CodeAgentSetup: Equatable, Sendable {
    public let installed: Bool, canDownload: Bool, canSignIn: Bool, canDiscover: Bool
    public let installHint: String, authHint: String, signInLabel: String
    public init(_ agent: JSONValue) {
        installed = agent["installed"].bool
        canDownload = !installed && agent["install"]["kind"].string == "download"
        canSignIn = installed && agent["auth"]["kind"].string == "browser"
        canDiscover = installed && (agent["auth"]["ready"].bool || agent["auth"]["kind"].string == "none")
        installHint = !installed && !canDownload ? agent["install"]["hint"].string : ""
        authHint = installed && !agent["auth"]["ready"].bool ? agent["auth"]["hint"].string : ""
        signInLabel = agent["auth"]["ready"].bool ? "Sign in again" : agent["auth"]["label"].string.isEmpty ? "Sign in" : agent["auth"]["label"].string
    }
}

public enum CodeModelChoices {
    public static func sameID(_ first: String, _ second: String) -> Bool { first.utf8.elementsEqual(second.utf8) }
    public static func choices(route: JSONValue, options: JSONValue) -> [JSONValue] {
        var rows: [JSONValue] = [], seen = Set<Data>()
        if route["kind"].string == "agent" { rows.append(["value": "", "displayName": "Agent default"]); seen.insert(Data()) }
        for item in options["models"].array + route["models"].array {
            let row: JSONValue
            if case .string(let value) = item { row = ["value": .string(value), "displayName": .string(value)] }
            else { row = item }
            guard case .string(let value) = row["value"], seen.insert(Data(value.utf8)).inserted else { continue }
            var choice = row
            if choice["displayName"].string.isEmpty { choice["displayName"] = .string(value) }
            rows.append(choice)
        }
        return rows
    }
    public static func filter(_ choices: [JSONValue], query: String) -> [JSONValue] {
        let terms = query.lowercased().split(whereSeparator: { $0.isWhitespace })
        return choices.filter { row in
            let text = [row["value"].string, row["displayName"].string, row["description"].string].joined(separator: " ").lowercased()
            return terms.allSatisfy { text.contains($0) }
        }
    }
    public static func customModel(query: String, route: JSONValue, choices: [JSONValue]) -> String? {
        let value = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let exists = choices.contains { sameID($0["value"].string, value) }
        return route["kind"].string != "agent" && !value.isEmpty && !exists ? value : nil
    }
}

public enum CodeEventPresentation {
    public static func errorText(_ value: JSONValue) -> String? {
        if value.isNull { return nil }
        if value == false || value == 0 { return nil }
        if case .string(let text) = value { return text.isEmpty ? nil : text }
        if !value["message"].string.isEmpty { return value["message"].string }
        return String(decoding: (try? value.encoded()) ?? Data(), as: UTF8.self)
    }
    public static func resultError(_ payload: JSONValue) -> String? {
        guard payload["is_error"].bool || payload["subtype"].string != "success" else { return nil }
        if let error = errorText(payload["error"]) { return error }
        let errors = payload["errors"].array.compactMap(errorText)
        if !errors.isEmpty { return errors.joined(separator: "; ") }
        return errorText(payload["result"]) ?? errorText(payload["subtype"]) ?? "The turn failed"
    }
    public static func inputTokens(_ payload: JSONValue) -> Int {
        let usage = payload["usage"]
        return usage["input_tokens"].int + usage["cache_read_input_tokens"].int + usage["cache_creation_input_tokens"].int
    }
}

public struct CodeGitContext: Equatable, Hashable, Sendable {
    public let project: String, thread: String
    public init(project: String, thread: String) { self.project = project; self.thread = thread }
}
public struct CodeGitRead: Equatable, Sendable {
    public let context: CodeGitContext, file: String?
    fileprivate let generation: UInt64
}
public struct CodeGitSelection: Sendable {
    public private(set) var context = CodeGitContext(project: "", thread: "")
    public private(set) var file: String?
    private var generation: UInt64 = 0
    public init() {}
    @discardableResult public mutating func configure(_ context: CodeGitContext) -> Bool {
        guard self.context != context else { return false }
        self.context = context; file = nil; generation &+= 1; return true
    }
    public mutating func select(_ file: String?) { self.file = file; generation &+= 1 }
    public mutating func begin() -> CodeGitRead { generation &+= 1; return CodeGitRead(context: context, file: file, generation: generation) }
    public func accepts(_ read: CodeGitRead) -> Bool { read.context == context && read.file == file && read.generation == generation }
}

enum CodeGitEnvironment {
    static func make(_ input: [String: String] = ProcessInfo.processInfo.environment) -> [String: String] {
        var env = input
        // Hooks export these variables; cwd alone does not select the intended
        // repository in that environment. Transport/auth configuration survives.
        for key in ["GIT_DIR", "GIT_WORK_TREE", "GIT_INDEX_FILE", "GIT_COMMON_DIR", "GIT_OBJECT_DIRECTORY", "GIT_ALTERNATE_OBJECT_DIRECTORIES", "GIT_PREFIX", "GIT_INTERNAL_SUPER_PREFIX", "GIT_SHALLOW_FILE", "GIT_GRAFT_FILE", "GIT_NO_REPLACE_OBJECTS", "GIT_REPLACE_REF_BASE", "GIT_IMPLICIT_WORK_TREE", "GIT_CONFIG", "GIT_CONFIG_PARAMETERS", "GIT_CONFIG_COUNT"] { env[key] = nil }
        for key in Array(env.keys) where key.hasPrefix("GIT_CONFIG_KEY_") || key.hasPrefix("GIT_CONFIG_VALUE_") { env[key] = nil }
        return env
    }
}
