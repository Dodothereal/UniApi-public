import Foundation
import CryptoKit

/// Pure history boundary ported from codex-web-catalog's uniapi-history.ts and
/// native-passthrough.ts. Mandatory context fails closed; optional reasoning may drop.
enum NativeCodexRouteHistory {
    private static let itemPrefix = "uniapi_item_", responsePrefix = "uniapi_response_"
    // Exact responses/{compaction,reasoning-envelope}.ts protocol constants.
    private static let checkpointPrefix = "ocx1:", reasoningPrefix = "ocxr1:"
    private static let summaryPrefix = "Another language model started to solve this problem and produced a summary of its thinking process. You also have access to the state of the tools that were used by that language model. Use this to build on the work that has already been done and avoid duplicating work. Here is the summary produced by the other language model, use the information in this summary to assist with your own analysis:"
    private static let maximumCheckpointBytes = 16 * 1024 * 1024

    static func decodeCheckpoint(_ value: JSONValue) -> String? {
        guard case .string(let text) = value, text.hasPrefix(checkpointPrefix),
              text.utf8.count <= maximumCheckpointBytes + checkpointPrefix.utf8.count else { return nil }
        let encoded = String(text.dropFirst(checkpointPrefix.count))
        guard !encoded.isEmpty, let bytes = Data(base64Encoded: encoded),
              bytes.base64EncodedString() == encoded else { return nil }
        // TextDecoder(utf-8, fatal: true) consumes one initial UTF-8 BOM.
        let payload = bytes.starts(with: [0xef, 0xbb, 0xbf]) ? Data(bytes.dropFirst(3)) : bytes
        let decoded = String(decoding: payload, as: UTF8.self)
        // Reject repaired UTF-8 while preserving every valid scalar after the BOM.
        return decoded.utf8.elementsEqual(payload) ? decoded : nil
    }

    static func providerInput(_ raw: JSONValue) throws -> JSONValue {
        try bounded(raw)
        guard case .object(var body) = raw else { throw NativeFailure("Expected a history object") }
        guard !truthy(raw["previous_response_id"]) else {
            throw NativeFailure("UniApi requires complete input history; previous_response_id is unsupported")
        }
        guard case .array(let items) = raw["input"] else { return raw }
        body["input"] = .array(try items.compactMap { item in
            guard case .object(var clean) = item else { return item }
            try rejectMandatoryCiphertext(item)
            let type = item["type"].string
            if type == "item_reference" { throw NativeFailure("UniApi requires complete input items, not backend item references") }
            if type == "compaction_trigger" { return nil }
            if isCheckpoint(type) {
                if type == "context_compaction", clean["encrypted_content"] == nil { return nil }
                return try summaryItem(item["encrypted_content"])
            }
            clean.removeValue(forKey: "id")
            if type == "reasoning" {
                clean.removeValue(forKey: "encrypted_content")
                if !hasContent(clean["summary"]) && !hasContent(clean["content"]) { return nil }
            }
            return .object(clean)
        })
        return .object(body)
    }

    static func nativeInput(_ raw: JSONValue) throws -> (value: JSONValue, changed: Bool) {
        try bounded(raw)
        if case .string(let id) = raw["previous_response_id"], id.hasPrefix(responsePrefix) {
            throw NativeFailure("Provider response references require complete history without previous_response_id")
        }
        guard case .object(var body) = raw, case .array(let items) = raw["input"],
              items.contains(where: { isProviderItem($0) || isBridgeReasoning($0) || isBridgeCheckpoint($0) }) else {
            return (raw, false)
        }
        body["input"] = .array(try items.compactMap { item in
            guard case .object(var clean) = item else { return item }
            let provider = isProviderItem(item), type = item["type"].string
            if provider {
                if type == "item_reference" { throw NativeFailure("Provider item references require complete input items") }
                try rejectMandatoryCiphertext(item)
            }
            clean.removeValue(forKey: "id")
            if provider && isCheckpoint(type) {
                if type == "context_compaction", clean["encrypted_content"] == nil { return nil }
                return try summaryItem(item["encrypted_content"])
            }
            if isBridgeCheckpoint(item) { return try summaryItem(item["encrypted_content"]) }
            if type == "reasoning" {
                if provider || string(item["encrypted_content"])?.hasPrefix(reasoningPrefix) == true || item["encrypted_content"].isNull {
                    clean.removeValue(forKey: "encrypted_content")
                }
                let nativeEncrypted = string(clean["encrypted_content"]) != nil
                if !hasArrayContent(clean["summary"]) && !hasArrayContent(clean["content"]) && !nativeEncrypted { return nil }
            }
            return .object(clean)
        })
        body.removeValue(forKey: "previous_response_id")
        return (.object(body), true)
    }

    /// Rewrites only response/item identities, never function/tool call linkage.
    static func mark(_ value: JSONValue, alias: String) -> JSONValue {
        guard case .object(var event) = value else { return value }
        func id(_ source: String, _ prefix: String) -> JSONValue {
            let digest = SHA256.hash(data: Data((alias + "\0" + source).utf8))
            return .string(prefix + String(NativeHex.encode(digest).prefix(32)))
        }
        func item(_ value: JSONValue, index: String) -> JSONValue {
            guard case .object(var row) = value else { return value }
            row["id"] = id(string(row["id"]) ?? "missing-output-id:\(index)", itemPrefix)
            return .object(row)
        }
        func response(_ value: JSONValue) -> JSONValue {
            guard case .object(var row) = value else { return value }
            if let original = string(row["id"]) { row["id"] = id(original, responsePrefix) }
            if let outputValue = row["output"], case .array(let output) = outputValue {
                row["output"] = .array(output.enumerated().map { item($0.element, index: String($0.offset)) })
            }
            return .object(row)
        }
        if event["object"] == "response" { return response(value) }
        if let output = event["output"], case .array = output { return response(value) }
        if let child = event["item"] {
            let index: String
            if let value = event["output_index"], case .number(let number) = value, number.isFinite { index = value.string }
            else { index = "0" }
            event["item"] = item(child, index: index)
        }
        if let original = string(event["item_id"]) { event["item_id"] = id(original, itemPrefix) }
        if let child = event["response"] { event["response"] = response(child) }
        return .object(event)
    }

    private static func string(_ value: JSONValue?) -> String? {
        if let value, case .string(let text) = value { return text }; return nil
    }
    private static func isProviderItem(_ item: JSONValue) -> Bool {
        string(item["id"])?.hasPrefix(itemPrefix) == true
    }
    private static func isCheckpoint(_ type: String) -> Bool {
        ["compaction", "compaction_summary", "context_compaction"].contains(type)
    }
    private static func isBridgeCheckpoint(_ item: JSONValue) -> Bool {
        item["type"] == "compaction" && string(item["encrypted_content"])?.hasPrefix(checkpointPrefix) == true
    }
    private static func isBridgeReasoning(_ item: JSONValue) -> Bool {
        guard item["type"] == "reasoning" else { return false }
        if string(item["encrypted_content"])?.hasPrefix(reasoningPrefix) == true { return true }
        guard let id = string(item["id"]), id.range(of: "^rs_[0-9a-fA-F]{32}$", options: .regularExpression) != nil,
              item["encrypted_content"].isNull else { return false }
        if case .array = item["summary"] { return true }
        if case .array = item["content"] { return true }; return false
    }
    private static func summaryItem(_ checkpoint: JSONValue) throws -> JSONValue {
        guard let summary = decodeCheckpoint(checkpoint), !summary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw NativeFailure("Unreadable encrypted checkpoint; replay complete plain context or start a new task")
        }
        return ["type": "message", "role": "user", "content": [["type": "input_text", "text": .string(summaryPrefix + "\n\n" + summary)]]]
    }
    private static func rejectMandatoryCiphertext(_ item: JSONValue) throws {
        guard ["agent_message", "function_call_output", "custom_tool_call_output"].contains(item["type"].string) else { return }
        let content = item[item["type"] == "agent_message" ? "content" : "output"]
        let parts: [JSONValue]
        if case .array(let values) = content { parts = values } else { parts = [content] }
        if ([item] + parts).contains(where: { $0["type"] == "encrypted_content" || $0.object["encrypted_content"] != nil }) {
            throw NativeFailure("Encrypted tool or subagent results require complete plain context")
        }
    }
    private static func hasArrayContent(_ value: JSONValue?) -> Bool {
        if let value, case .array(let values) = value { return !values.isEmpty }; return false
    }
    private static func hasContent(_ value: JSONValue?) -> Bool {
        if let value, case .string(let text) = value { return !text.isEmpty }; return hasArrayContent(value)
    }
    private static func truthy(_ value: JSONValue) -> Bool {
        switch value {
        case .null: return false
        case .bool(let flag): return flag
        case .string(let text): return !text.isEmpty
        case .number(let number): return number != 0 && !number.isNaN
        default: return true
        }
    }
    /// Walk iteratively so even an already-decoded hostile tree cannot exhaust the stack.
    /// The socket also bounds encoded input; this bounds node overhead and checkpoint work.
    private static func bounded(_ raw: JSONValue) throws {
        var pending: [(JSONValue, Int)] = [(raw, 0)], bytes = 0, nodes = 0
        while let (value, depth) = pending.popLast() {
            nodes += 1
            guard depth <= 128, nodes <= 1_000_000 else { throw NativeFailure("History exceeds its structural bound") }
            switch value {
            case .string(let text): bytes += text.utf8.count
            case .array(let values):
                guard nodes + pending.count + values.count <= 1_000_000 else { throw NativeFailure("History has too many items") }
                pending.append(contentsOf: values.map { ($0, depth + 1) })
            case .object(let fields):
                guard nodes + pending.count + fields.count <= 1_000_000 else { throw NativeFailure("History has too many fields") }
                for (key, child) in fields { bytes += key.utf8.count; pending.append((child, depth + 1)) }
            default: break
            }
            guard bytes <= 64 * 1024 * 1024 else { throw NativeFailure("History exceeds its byte bound") }
        }
    }
}
