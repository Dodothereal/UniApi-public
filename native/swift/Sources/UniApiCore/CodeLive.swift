import Foundation

public struct CodeLiveBlock: Equatable, Sendable, Identifiable {
    public let index: Int
    public var type: String, text: String, name: String, toolID: String, inputJSON: String, done: Bool
    public var id: Int { index }
    public var input: JSONValue { (try? JSONValue.decode(Data(inputJSON.utf8))) ?? (inputJSON.isEmpty ? [:] : ["partial": .string(inputJSON)]) }
    public var tool: JSONValue { ["type": "tool_use", "id": .string(toolID), "name": .string(name), "input": input] }
}
/// Shared by the service's page-entry snapshot and the UI's live event fold.
/// Block indexes are sparse and immutable; nested agent streams never replace
/// the top-level assistant, and persisted prefixes are not rendered twice.
public struct CodeLiveState: Equatable, Sendable {
    public var messageID: String? = nil
    public private(set) var blocks: [Int: CodeLiveBlock] = [:]
    public private(set) var active = false
    public init() {}
    public init(json: JSONValue) {
        messageID = json["messageId"].isNull ? nil : json["messageId"].string; active = json["active"].bool
        for b in json["blocks"].array { let i = b["index"].int; guard (0...4096).contains(i) else { continue }; blocks[i] = CodeLiveBlock(index: i, type: b["type"].string, text: b["text"].string, name: b["name"].string, toolID: b["id"].string, inputJSON: b["inputJson"].string, done: b["done"].bool) }
    }
    public mutating func apply(_ event: JSONValue, parent: JSONValue = .null) {
        guard parent.isNull else { return }
        let index = event["index"].isNull ? (blocks.keys.max() ?? 0) : event["index"].int
        guard (0...4096).contains(index) else { return }
        switch event["type"].string {
        case "message_start": messageID = event["message"]["id"].string; blocks = [:]; active = true
        case "content_block_start":
            let b = event["content_block"], input = b["input"]
            blocks[index] = CodeLiveBlock(index: index, type: b["type"].string, text: b["type"].string == "thinking" ? b["thinking"].string : b["text"].string, name: b["name"].string, toolID: b["id"].string, inputJSON: input.object.isEmpty ? "" : String(decoding: (try? input.encoded()) ?? Data(), as: UTF8.self), done: false); active = true
        case "content_block_delta":
            guard var block = blocks[index] else { return }; let delta = event["delta"]
            block.text += delta["text"].string + delta["thinking"].string
            block.inputJSON += delta["partial_json"].string; blocks[index] = block
        case "content_block_stop": blocks[index]?.done = true
        case "message_stop": active = false
        default: break
        }
    }
    public func remaining(events: [JSONValue]) -> [CodeLiveBlock] {
        guard active else { return [] }
        let persisted = events.filter { $0["type"].string == "assistant" && $0["payload"]["parent_tool_use_id"].isNull && $0["payload"]["message_id"].string == messageID }.reduce(0) { $0 + $1["payload"]["content"].array.count }
        return blocks.values.sorted { $0.index < $1.index }.filter { $0.index >= persisted }
    }
    public var json: JSONValue { ["messageId": messageID.map(JSONValue.string) ?? .null, "active": .bool(active), "blocks": .array(blocks.values.sorted { $0.index < $1.index }.map { b in ["index": .number(Double(b.index)), "type": .string(b.type), "text": .string(b.text), "name": .string(b.name), "id": .string(b.toolID), "inputJson": .string(b.inputJSON), "done": .bool(b.done)] })] }
}

/// Scroll decisions use user intent, not content geometry changes. New output
/// can increase the bottom distance without meaning that the user scrolled up.
public struct CodeScrollPolicy: Equatable, Sendable {
    public private(set) var follows = true
    public init() {}
    public mutating func userScrolled(distanceToBottom: Double) { follows = distanceToBottom.isFinite && distanceToBottom <= 120 }
    public mutating func jumpToBottom() { follows = true }
    public mutating func userSent() { follows = true }
    public func target(oldHeight: Double, newHeight: Double, viewport: Double, oldOffset: Double) -> Double {
        let maximum = max(0, newHeight - viewport)
        return follows ? maximum : min(maximum, max(0, oldOffset))
    }
}
