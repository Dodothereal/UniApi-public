import Foundation

public struct ShimToolIdentity: Hashable, Sendable {
    public let namespace: String?, name: String
    public static func == (a: Self, b: Self) -> Bool { a.namespace.map { Array($0.utf8) } == b.namespace.map { Array($0.utf8) } && Array(a.name.utf8) == Array(b.name.utf8) }
    public func hash(into hasher: inout Hasher) { hasher.combine(namespace.map { Array($0.utf8) }); hasher.combine(Array(name.utf8)) }
}
public struct ShimToolMap: Sendable {
    public struct Definition: Sendable { public let identity: ShimToolIdentity, tool: JSONValue }
    public private(set) var definitions: [Definition] = [], names: [ShimToolIdentity: String] = [:], originals: [String: JSONValue] = [:], custom = Set<String>()
    private var defaultNames = Set<[UInt8]>(), qualifiedHistory = Set<[UInt8]>()
    public init(_ request: JSONValue) throws {
        let replayInput = try Self.replayInput(request)
        var identities = Set<ShimToolIdentity>(), customIdentities = Set<ShimToolIdentity>()
        func add(_ tool: JSONValue, namespace: String?) {
            guard tool["type"].isNull || ["function", "custom"].contains(tool["type"].string) else { return }
            let name = tool["name"].string.isEmpty ? tool["function"]["name"].string : tool["name"].string; guard !name.isEmpty else { return }
            let key = ShimToolIdentity(namespace: namespace, name: name); identities.insert(key); if tool["type"] == "custom" { customIdentities.insert(key) }; definitions.append(.init(identity: key, tool: tool))
        }
        for tool in request["tools"].array {
            if tool["type"] == "namespace" {
                guard SwitcherDisk.validLabel(tool["name"], limit: 1024), case .array = tool["tools"] else { throw NativeFailure("Namespace tools require a name and a tools array") }
                for child in tool["tools"].array { add(child, namespace: tool["name"].string) }
            } else { add(tool, namespace: nil) }
        }
        let declared = identities
        defaultNames = Set(declared.filter { $0.namespace == "functions" && !declared.contains(.init(namespace: nil, name: $0.name)) }.map { Array($0.name.utf8) })
        let history = replayInput.filter { ["function_call", "custom_tool_call"].contains($0["type"].string) }
        qualifiedHistory = Set(history.filter { $0["namespace"] == "functions" }.map { Array($0["name"].string.utf8) })
        for item in history where !item["name"].string.isEmpty {
            let key = try identity(item, history: true); identities.insert(key)
            if item["type"] == "custom_tool_call" && !declared.contains(key) { customIdentities.insert(key) }
        }
        if !request["tool_choice"]["name"].string.isEmpty { identities.insert(try identity(request["tool_choice"])) }
        func order(_ a: ShimToolIdentity, _ b: ShimToolIdentity) -> Bool {
            if a.namespace != b.namespace { return Array((a.namespace ?? "").utf8).lexicographicallyPrecedes(Array((b.namespace ?? "").utf8)) }
            return Array(a.name.utf8).lexicographicallyPrecedes(Array(b.name.utf8))
        }
        func alias(_ key: ShimToolIdentity) throws -> String {
            let namespace = try key.namespace.map(Self.asciiQuote) ?? "null"
            let input = "[" + namespace + ", " + (try Self.asciiQuote(key.name)) + "]"
            let base = (key.namespace == nil ? "fn_" : "ns_") + SwitcherDisk.hash(Data(input.utf8)).prefix(48)
            var name = base, suffix = 0
            while originals[name] != nil { suffix += 1; name = String(base.prefix(64 - String(suffix).count - 1)) + "_" + String(suffix) }; return name
        }
        for key in identities.filter({ $0.namespace != nil }).sorted(by: order) { let name = try alias(key); names[key] = name; originals[name] = ["name": .string(key.name), "namespace": .string(key.namespace!)] }
        var collisions: [ShimToolIdentity] = []
        for key in identities.filter({ $0.namespace == nil }).sorted(by: order) {
            if originals[key.name] != nil { collisions.append(key) }
            else { names[key] = key.name; originals[key.name] = ["name": .string(key.name)] }
        }
        for key in collisions { let name = try alias(key); names[key] = name; originals[name] = ["name": .string(key.name)] }
        custom = Set(customIdentities.compactMap { names[$0] })
    }
    /// A client-confirmed rejection is evidence, not an executable tool call.
    /// Keep both complete original records as text; never guess a valid tool
    /// from a corrupt alias, edit the durable transcript, or relax identity().
    static func replayInput(_ request: JSONValue) throws -> [JSONValue] {
        let input = ShimTranslation.inputItems(request)
        let calls = Dictionary(grouping: input.indices.filter { ["function_call", "custom_tool_call"].contains(input[$0]["type"].string) }, by: { Array(input[$0]["call_id"].string.utf8) })
        let outputs = Dictionary(grouping: input.indices.filter { ["function_call_output", "custom_tool_call_output"].contains(input[$0]["type"].string) }, by: { Array(input[$0]["call_id"].string.utf8) })
        var replacements: [Int: JSONValue] = [:]
        for (id, indices) in calls where !id.isEmpty && indices.count == 1 {
            guard let callIndex = indices.first, let resultIndices = outputs[id], resultIndices.count == 1,
                  let resultIndex = resultIndices.first, resultIndex > callIndex else { continue }
            let call = input[callIndex], output = input[resultIndex], custom = call["type"] == "custom_tool_call"
            guard case .string = call["call_id"], case .string = output["call_id"],
                  case .string(let name) = call["name"], !SwitcherDisk.validLabel(call["name"], limit: 1024),
                  call["namespace"].isNull || SwitcherDisk.validLabel(call["namespace"], limit: 1024),
                  case .string = call[custom ? "input" : "arguments"],
                  output["type"] == .string(custom ? "custom_tool_call_output" : "function_call_output"),
                  case .string(let rejection) = output["output"], Array(rejection.utf8) == Array(("unsupported call: " + name).utf8),
                  call["encrypted_content"].isNull, output["encrypted_content"].isNull,
                  call["encrypted_function_args"].isNull, output["encrypted_function_args"].isNull else { continue }
            for (index, role, prefix) in [(callIndex, "assistant", "Client-rejected malformed tool call; non-executable conversation evidence"),
                                          (resultIndex, "user", "Client rejection result; non-executable conversation evidence")] {
                let record = try input[index].encoded()
                guard record.count <= ShimSecurity.maximumBody / 2 else { throw NativeFailure("Rejected tool record exceeds replay bound") }
                replacements[index] = ["type": "message", "role": .string(role), "content": [["type": "input_text", "text": .string("[UniApi: " + prefix + "]\n" + String(decoding: record, as: UTF8.self))]]]
            }
        }
        return input.indices.map { replacements[$0] ?? input[$0] }
    }
    private static func asciiQuote(_ value: String) throws -> String {
        let json = try NativeTOML.quote(value)
        var result = ""
        for scalar in json.unicodeScalars {
            if scalar.value < 128 { result.unicodeScalars.append(scalar) }
            else if scalar.value <= 0xffff { result += String(format: "\\u%04x", scalar.value) }
            else { let code = scalar.value - 0x10000; result += String(format: "\\u%04x\\u%04x", 0xd800 + (code >> 10), 0xdc00 + (code & 0x3ff)) }
        }
        return result
    }
    public func identity(_ item: JSONValue, history: Bool = false) throws -> ShimToolIdentity {
        guard SwitcherDisk.validLabel(item["name"], limit: 1024), item["namespace"].isNull || SwitcherDisk.validLabel(item["namespace"], limit: 1024) else { throw NativeFailure("Tool names and namespaces must be nonempty strings") }
        var namespace: String? = item["namespace"].isNull ? nil : item["namespace"].string
        let name = item["name"].string
        if namespace == nil && defaultNames.contains(Array(name.utf8)) && !(history && qualifiedHistory.contains(Array(name.utf8))) { namespace = "functions" }
        return .init(namespace: namespace, name: name)
    }
    public func name(_ item: JSONValue, history: Bool = false) throws -> String {
        guard let name = names[try identity(item, history: history)] else { throw NativeFailure("Tool identity was absent from this request") }; return name
    }
    public func restore(_ name: String) -> JSONValue { originals[name] ?? ["name": .string(name)] }
    func validOutputName(_ name: String) -> Bool {
        let restored = restore(name)
        return SwitcherDisk.validLabel(.string(name), limit: 1024) && SwitcherDisk.validLabel(restored["name"], limit: 1024)
            && (restored["namespace"].isNull || SwitcherDisk.validLabel(restored["namespace"], limit: 1024))
    }
}
