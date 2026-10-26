import Foundation

/// AskUserQuestion's CLI wire requires one comma-separated string per question,
/// including a freeform answer alongside any selected choices.
public enum CodeQuestionAnswers {
    public static func build(questions: [JSONValue], single: [String: String], multiple: [String: Set<String>], other: [String: String]) throws -> JSONObject {
        var answers: JSONObject = [:]
        for q in questions {
            let key = q["question"].string, free = (other[key] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let chosen = q["multiSelect"].bool ? Array(multiple[key] ?? []).sorted() : (single[key] ?? "").isEmpty ? [] : [single[key]!]
            let values = chosen + (free.isEmpty ? [] : [free])
            guard !values.isEmpty else { throw NativeFailure("Answer every question before submitting") }
            answers[key] = .string(values.joined(separator: ", "))
        }
        return answers
    }
}

/// Incremental durable prefix: text/thinking close before a tool opens; a tool
/// result follows the assistant block that announced that same immutable ID.
struct CodeACPBlocks {
    struct Block { var content: JSONValue, done: Bool, id: String }
    var messageID = "acp_" + UUID().uuidString
    var blocks: [Block] = [], flushed = 0, toolCalls = 0, cost: Double = 0
    var results: [String: JSONValue] = [:]
    mutating func update(_ u: JSONValue) -> [(String, JSONValue)] {
        var frames: [(String, JSONValue)] = []
        let kind = u["sessionUpdate"].string
        if kind == "usage_update" { cost = max(cost, u["cost"]["amount"].double); return [] }
        if ["agent_message_chunk", "agent_thought_chunk"].contains(kind), u["content"]["type"].string == "text" {
            let type = kind == "agent_message_chunk" ? "text" : "thinking", key = type == "text" ? "text" : "thinking", text = u["content"]["text"].string
            if blocks.last?.done != false || blocks.last?.content["type"].string != type { frames += closeOpen(); blocks.append(Block(content: .object(["type": .string(type), key: .string("")]), done: false, id: "")); frames += publish(blocks.count - 1) }
            let index = blocks.count - 1; blocks[index].content[key] = .string(blocks[index].content[key].string + text)
            let delta = JSONValue.object(["type": .string(type == "text" ? "text_delta" : "thinking_delta"), key: .string(text)])
            frames.append(("stream", ["type": "content_block_delta", "index": .number(Double(index)), "delta": delta]))
        } else if ["tool_call", "tool_call_update"].contains(kind) {
            let id = u["toolCallId"].string
            if let index = blocks.firstIndex(where: { $0.id == id }) {
                if blocks[index].done { return [] }
                let previous = blocks[index].content
                let shaped = Self.shape(u, previous: previous); blocks[index].content = shaped
                if !u["rawInput"].isNull || !u["title"].isNull || !u["kind"].isNull || shaped["name"] != previous["name"] || u["content"].array.contains(where: { $0["type"].string == "diff" }) { frames += publish(index) }
                if ["completed", "failed"].contains(u["status"].string) { blocks[index].done = true; var result = Self.result(u); if result["text"].string.isEmpty { result["text"] = results[id]?["text"] ?? "" }; results[id] = result; frames.append(("stream", ["type": "content_block_stop", "index": .number(Double(index))])) }
                else if !u["content"].array.isEmpty { results[id] = Self.result(u) }
            } else if kind == "tool_call" || !u["rawInput"].isNull || !u["title"].isNull {
                frames += closeOpen()
                let done = ["completed", "failed"].contains(u["status"].string); blocks.append(Block(content: Self.shape(u), done: done, id: id)); toolCalls += 1
                frames += publish(blocks.count - 1)
                if done { results[id] = Self.result(u); frames.append(("stream", ["type": "content_block_stop", "index": .number(Double(blocks.count - 1))])) }
            }
        } else if kind == "plan" {
            frames += closeOpen()
            let todos = u["entries"].array.map { row -> JSONValue in ["content": row["content"], "status": ["completed", "in_progress"].contains(row["status"].string) ? row["status"] : "pending", "priority": row["priority"]] }
            let content: JSONValue = ["type": "tool_use", "id": .string("plan_" + UUID().uuidString), "name": "TodoWrite", "input": ["todos": .array(todos)], "title": "Plan", "kind": "think"]
            if let index = blocks.firstIndex(where: { !$0.done && $0.content["name"].string == "TodoWrite" }) { blocks[index].content["input"] = ["todos": .array(todos)]; frames += publish(index) }
            else { blocks.append(Block(content: content, done: false, id: content["id"].string)); frames += publish(blocks.count - 1) }
        }
        frames += flush(all: false); return frames
    }
    private func publish(_ index: Int) -> [(String, JSONValue)] {
        let content = blocks[index].content
        if content["type"].string != "tool_use" { return [("stream", ["type": "content_block_start", "index": .number(Double(index)), "content_block": content])] }
        return [("stream", ["type": "content_block_start", "index": .number(Double(index)), "content_block": ["type": "tool_use", "id": content["id"], "name": content["name"]]]), ("stream", ["type": "content_block_delta", "index": .number(Double(index)), "delta": ["type": "input_json_delta", "partial_json": .string(String(decoding: (try? content["input"].encoded()) ?? Data("{}".utf8), as: UTF8.self))]])]
    }
    mutating func closeOpen() -> [(String, JSONValue)] { if let i = blocks.indices.last, !blocks[i].done, blocks[i].content["type"].string != "tool_use" { blocks[i].done = true; return [("stream", ["type": "content_block_stop", "index": .number(Double(i))])] }; return [] }
    mutating func flush(all: Bool, aborted: Bool = false) -> [(String, JSONValue)] {
        var output: [(String, JSONValue)] = [], content: [JSONValue] = [], toolResults: [JSONValue] = []
        if all { for i in blocks.indices where !blocks[i].done { blocks[i].done = true; output.append(("stream", ["type": "content_block_stop", "index": .number(Double(i))])) } }
        while flushed < blocks.count && (blocks[flushed].done || all) {
            var b = blocks[flushed]; b.done = true; blocks[flushed] = b; flushed += 1; content.append(b.content)
            if let result = results[b.id] { toolResults.append(["type": "tool_result", "tool_use_id": .string(b.id), "content": result["text"], "is_error": result["is_error"]]) }
        }
        if !content.isEmpty { output.append(("assistant", ["message_id": .string(messageID), "content": .array(content), "stop_reason": .null, "usage": .null, "parent_tool_use_id": .null, "aborted": .bool(aborted)])) }
        if !toolResults.isEmpty { output.append(("tool_result", ["content": .array(toolResults), "parent_tool_use_id": .null])) }
        return output
    }
    static func shape(_ u: JSONValue, previous: JSONValue = [:]) -> JSONValue {
        let kind = u["kind"].string.isEmpty ? previous["kind"].string.isEmpty ? "other" : previous["kind"].string : u["kind"].string
        let title = u["title"].isNull ? previous["title"].string : u["title"].string
        var input: JSONValue
        if case .object = u["rawInput"] { input = u["rawInput"] } else { input = .object(previous["input"].object) }
        let metadata = u["_meta"].isNull ? previous["_meta"] : u["_meta"]
        let meta = metadata["claudeCode"]["toolName"].string
        let generic = ["read": "Read", "edit": "Edit", "delete": "Delete", "move": "Move", "search": "Grep", "execute": "Bash", "think": "Think", "fetch": "WebFetch", "switch_mode": "SwitchMode"][kind]
        // Generic announcements can gain a kind later; only explicit metadata
        // outranks that newer shape. Unknown kinds retain a prior diff name.
        let fallback = previous["name"].string.isEmpty ? "Tool" : previous["name"].string
        var name = meta.isEmpty ? generic ?? fallback : meta
        let path = [input["file_path"], input["filePath"], input["path"], input["file"], u["locations"].array.first?["path"] ?? .null].first { !$0.string.isEmpty } ?? .string(title)
        if let diff = u["content"].array.first(where: { $0["type"].string == "diff" }) {
            let write = diff["oldText"].isNull
            name = meta.isEmpty ? write ? "Write" : "Edit" : meta; input = ["file_path": diff["path"]]
            if write { input["content"] = diff["newText"] } else { input["old_string"] = diff["oldText"]; input["new_string"] = diff["newText"] }
        } else if meta.isEmpty {
            if ["read", "edit"].contains(kind) { input["file_path"] = path }
            if kind == "execute" { input["command"] = input["command"].isNull ? input["cmd"].isNull ? .string(title) : input["cmd"] : input["command"] }
            if kind == "search" { input["pattern"] = input["pattern"].isNull ? input["query"].isNull ? .string(title) : input["query"] : input["pattern"] }
            if kind == "fetch" && input["url"].isNull { input["url"] = .string(title) }
            if kind == "edit" {
                let old = ["old_string", "oldString", "old_text", "oldText"].compactMap { key -> JSONValue? in if case .string = input[key] { return input[key] }; return nil }.first
                let new = ["new_string", "newString", "new_text", "newText"].compactMap { key -> JSONValue? in if case .string = input[key] { return input[key] }; return nil }.first
                if let old, let new { input["old_string"] = old; input["new_string"] = new }
                else if !input["content"].isNull { name = "Write" }
            }
        }
        return ["type": "tool_use", "id": u["toolCallId"].isNull ? previous["id"] : u["toolCallId"], "name": .string(name), "input": input, "title": .string(title), "kind": .string(kind), "_meta": metadata]
    }
    static func result(_ u: JSONValue) -> JSONValue {
        var parts = u["content"].array.compactMap { c -> String? in if c["type"].string == "content" && c["content"]["type"].string == "text" { return c["content"]["text"].string }; if c["type"].string == "diff" { return "updated " + c["path"].string }; if c["type"].string == "terminal" { return "(terminal \(c["terminalId"].string))" }; return nil }
        if parts.isEmpty && !u["rawOutput"].isNull { parts = [u["rawOutput"].string.isEmpty ? String(decoding: (try? u["rawOutput"].encoded()) ?? Data(), as: UTF8.self) : u["rawOutput"].string] }
        return ["text": .string(parts.joined(separator: "\n")), "is_error": .bool(u["status"].string == "failed")]
    }
}
