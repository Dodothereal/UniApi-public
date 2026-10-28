import Foundation

public struct ShimSSEFrame: Sendable {
    public let event: String, data: JSONValue
    public init(_ event: String, _ data: JSONValue) { self.event = event; self.data = data }
    public func encoded() throws -> Data {
        if event == "done" { return Data("data: [DONE]\n\n".utf8) }
        return Data(("event: " + event + "\ndata: " + String(decoding: try data.encoded(), as: UTF8.self) + "\n\n").utf8)
    }
}

/// Buffers only incomplete lines; UTF-8 and JSON may both span TCP chunks.
public struct ShimSSEParser: Sendable {
    private var pending = Data(), lines: [String] = [], name = ""
    public init() {}
    public mutating func feed(_ data: Data, final: Bool = false) throws -> [ShimSSEFrame] {
        pending.append(data); guard pending.count <= 8 * 1024 * 1024 else { throw NativeFailure("Upstream SSE frame exceeded its bound") }
        var output: [ShimSSEFrame] = []
        func consume(_ text: String) {
            if text == "[DONE]" { output.append(.init("done", .null)); return }
            if let value = try? JSONValue.decode(Data(text.utf8)) { output.append(.init(name.isEmpty ? value["type"].string : name, value)) }
        }
        func line(_ raw: String) {
            let text = raw.hasSuffix("\r") ? String(raw.dropLast()) : raw
            if text.isEmpty { if !lines.isEmpty { consume(lines.joined(separator: "\n")); lines.removeAll() }; name = "" }
            else if text.hasPrefix("event:") { name = String(text.dropFirst(6)).trimmingCharacters(in: .whitespaces) }
            else if text.hasPrefix("data:") {
                let payload = String(text.dropFirst(5)).trimmingCharacters(in: .whitespaces)
                if lines.isEmpty && (payload == "[DONE]" || (try? JSONValue.decode(Data(payload.utf8))) != nil) { consume(payload) }
                else { lines.append(payload) }
            }
        }
        while let newline = pending.firstIndex(of: 10) {
            line(String(decoding: pending[..<newline], as: UTF8.self)); pending = Data(pending[pending.index(after: newline)...])
        }
        if final { if !pending.isEmpty { line(String(decoding: pending, as: UTF8.self)); pending.removeAll() }; if !lines.isEmpty { consume(lines.joined(separator: "\n")); lines.removeAll() } }
        guard lines.reduce(0, { $0 + $1.utf8.count }) <= 8 * 1024 * 1024 else { throw NativeFailure("Upstream SSE event exceeded its bound") }
        return output
    }
}

public struct ShimResponsesStream: Sendable {
    public let model: String, id: String, created: Int
    public private(set) var items: [JSONValue] = [], started = false, terminated = false, sequence = 0
    public private(set) var inputTokens = 0, outputTokens = 0, contentCount = 0, sawTool = false, stopReason: String?
    private var openKind = "", openID = "", openText = "", outputIndex = 0
    private var tools: [String: JSONValue] = [:], toolOrder: [String] = [], splitter = ShimThinkSplitter()
    private var toolFailure: String?
    private var reasoningOutputTokens: Int?
    private let map: ShimToolMap
    public init(model: String, tools: ShimToolMap, now: Date = Date()) { self.model = model; map = tools; id = "resp_" + UUID().uuidString; created = Int(now.timeIntervalSince1970) }
    private mutating func event(_ name: String, _ fields: JSONObject) -> ShimSSEFrame {
        sequence += 1; var value = fields; value["type"] = .string(name); value["sequence_number"] = .number(Double(sequence)); return .init(name, .object(value))
    }
    private func snapshot(_ status: String, extra: JSONObject = [:]) -> JSONValue {
        var value: JSONObject = ["id": .string(id), "object": "response", "created_at": .number(Double(created)), "status": .string(status), "model": .string(model), "output": .array(items), "usage": .null]
        for (key, field) in extra { value[key] = field }; return .object(value)
    }
    private var usage: JSONValue {
        var result: JSONObject = ["input_tokens": .number(Double(inputTokens)), "output_tokens": .number(Double(outputTokens)), "total_tokens": .number(Double(inputTokens + outputTokens))]
        if let reasoningOutputTokens { result["output_tokens_details"] = ["reasoning_tokens": .number(Double(reasoningOutputTokens))] }
        return .object(result)
    }
    public mutating func start() -> [ShimSSEFrame] { guard !started else { return [] }; started = true; return [event("response.created", ["response": snapshot("in_progress")])] }
    public mutating func heartbeat() -> [ShimSSEFrame] { started && !terminated ? [event("response.heartbeat", [:])] : [] }
    private mutating func close() -> [ShimSSEFrame] {
        guard !openKind.isEmpty else { return [] }
        var frames: [ShimSSEFrame] = [], item: JSONValue
        let base: JSONObject = ["item_id": .string(openID), "output_index": .number(Double(outputIndex))]
        if openKind == "message" {
            let part: JSONValue = ["type": "output_text", "text": .string(openText), "annotations": []]
            item = ["type": "message", "id": .string(openID), "status": "completed", "role": "assistant", "content": [part]]
            var fields = base; fields["content_index"] = 0; fields["text"] = .string(openText); frames.append(event("response.output_text.done", fields)); fields.removeValue(forKey: "text"); fields["part"] = part; frames.append(event("response.content_part.done", fields))
        } else {
            let part: JSONValue = ["type": "summary_text", "text": .string(openText)]
            item = ["type": "reasoning", "id": .string(openID), "summary": openText.isEmpty ? [] : [part]]
            if !openText.isEmpty { var fields = base; fields["summary_index"] = 0; fields["text"] = .string(openText); frames.append(event("response.reasoning_summary_text.done", fields)); fields.removeValue(forKey: "text"); fields["part"] = part; frames.append(event("response.reasoning_summary_part.done", fields)) }
        }
        frames.append(event("response.output_item.done", ["output_index": .number(Double(outputIndex)), "item": item])); items.append(item); outputIndex += 1; openKind = ""; openText = ""; return frames
    }
    private mutating func delta(_ text: String, reasoning: Bool) -> [ShimSSEFrame] {
        guard !text.isEmpty && !terminated else { return [] }
        var frames = start(); let kind = reasoning ? "reasoning" : "message"
        if openKind != kind {
            frames += close(); openKind = kind; openID = (reasoning ? "rs_" : "msg_") + UUID().uuidString; openText = ""
            let item: JSONValue = reasoning ? ["type": "reasoning", "id": .string(openID), "summary": []] : ["type": "message", "id": .string(openID), "status": "in_progress", "role": "assistant", "content": []]
            frames.append(event("response.output_item.added", ["output_index": .number(Double(outputIndex)), "item": item]))
            let part: JSONValue = reasoning ? ["type": "summary_text", "text": ""] : ["type": "output_text", "text": "", "annotations": []]
            var fields: JSONObject = ["item_id": .string(openID), "output_index": .number(Double(outputIndex)), "part": part]; fields[reasoning ? "summary_index" : "content_index"] = 0
            frames.append(event(reasoning ? "response.reasoning_summary_part.added" : "response.content_part.added", fields))
        }
        openText += text; if !reasoning { contentCount += text.unicodeScalars.count }
        var fields: JSONObject = ["item_id": .string(openID), "output_index": .number(Double(outputIndex)), "delta": .string(text)]; fields[reasoning ? "summary_index" : "content_index"] = 0
        frames.append(event(reasoning ? "response.reasoning_summary_text.delta" : "response.output_text.delta", fields)); return frames
    }
    private mutating func tool(_ key: String, id: String, name: String, arguments: String) -> [ShimSSEFrame] {
        guard !terminated else { return [] }; sawTool = true; let frames = start()
        if tools[key] == nil { tools[key] = ["id": .string("fc_" + UUID().uuidString), "call_id": .string(id.isEmpty ? "call_" + UUID().uuidString : id), "name": .string(name), "arguments": ""]; toolOrder.append(key) }
        var item = tools[key]!
        if !name.isEmpty { item["name"] = .string(name) }; if !id.isEmpty { item["call_id"] = .string(id) }; item["arguments"] = .string(item["arguments"].string + arguments); tools[key] = item
        return frames
    }
    public mutating func feedOpenAI(_ object: JSONValue) -> [ShimSSEFrame] {
        guard !terminated else { return [] }
        let usage = object["usage"]; if !usage["prompt_tokens"].isNull { inputTokens = usage["prompt_tokens"].int }
        if !usage["completion_tokens"].isNull {
            outputTokens = usage["completion_tokens"].int
            // The detail is usable only when it is explicit and belongs to this
            // same total; a later total without details invalidates the pair.
            reasoningOutputTokens = nil
            if case .number(let total) = usage["completion_tokens"], case .number(let reasoning) = usage["completion_tokens_details"]["reasoning_tokens"],
               total.isFinite, reasoning.isFinite, total >= 0, total <= 1_000_000_000,
               total.rounded(.towardZero) == total, reasoning >= 0, reasoning <= total, reasoning.rounded(.towardZero) == reasoning {
                reasoningOutputTokens = Int(reasoning)
            }
        }
        guard let choice = object["choices"].array.first else { return [] }; let change = choice["delta"]
        let reasoning = change["reasoning"].string.isEmpty ? change["reasoning_content"].string : change["reasoning"].string
        var frames = delta(reasoning, reasoning: true)
        if !ShimTranslation.streamedText(change["content"]).isEmpty { let parts = splitter.feed(ShimTranslation.streamedText(change["content"])); frames += delta(parts.thinking, reasoning: true); frames += delta(parts.visible, reasoning: false) }
        for call in change["tool_calls"].array { frames += tool(String(call["index"].int), id: call["id"].string, name: call["function"]["name"].string, arguments: call["function"]["arguments"].string) }
        if !choice["finish_reason"].isNull { stopReason = choice["finish_reason"].string }; return frames
    }
    public mutating func feedAnthropic(_ object: JSONValue) -> [ShimSSEFrame] {
        guard !terminated else { return [] }
        switch object["type"].string {
        case "message_start": inputTokens = object["message"]["usage"]["input_tokens"].int; return start()
        case "content_block_start": let block = object["content_block"]; return block["type"] == "tool_use" ? tool(String(object["index"].int), id: block["id"].string, name: block["name"].string, arguments: "") : []
        case "content_block_delta":
            let change = object["delta"]
            switch change["type"].string {
            case "text_delta": return delta(change["text"].string, reasoning: false)
            case "thinking_delta": return delta(change["thinking"].string, reasoning: true)
            case "input_json_delta": return tool(String(object["index"].int), id: "", name: "", arguments: change["partial_json"].string)
            default: return []
            }
        case "message_delta": if !object["delta"]["stop_reason"].isNull { stopReason = object["delta"]["stop_reason"].string }; if !object["usage"]["output_tokens"].isNull { outputTokens = object["usage"]["output_tokens"].int }; return []
        default: return []
        }
    }
    private mutating func emitTools() -> [ShimSSEFrame] {
        guard toolOrder.allSatisfy({ map.validOutputName(tools[$0]!["name"].string) }) else {
            toolFailure = "Provider returned an invalid tool identity; no tool calls from this response were emitted"
            tools.removeAll(); toolOrder.removeAll()
            return []
        }
        var frames: [ShimSSEFrame] = []
        for key in toolOrder {
            let tool = tools[key]!, raw = tool["arguments"].string
            let arguments = raw.isEmpty || (try? JSONValue.decode(Data(raw.utf8))) == nil ? "{}" : raw
            let decoded = (try? JSONValue.decode(Data(arguments.utf8))) ?? .null
            let custom = map.custom.contains(tool["name"].string)
            let value: String
            if custom, case .string(let input) = decoded["input"] { value = input } else { value = arguments }
            var head: JSONValue = ["type": custom ? "custom_tool_call" : "function_call", "id": tool["id"], "call_id": tool["call_id"]]
            for (key, value) in map.restore(tool["name"].string).object { head[key] = value }
            let field = custom ? "input" : "arguments", prefix = custom ? "response.custom_tool_call_input" : "response.function_call_arguments"
            var opening = head; opening[field] = ""; frames.append(event("response.output_item.added", ["output_index": .number(Double(outputIndex)), "item": opening]))
            frames.append(event(prefix + ".delta", ["item_id": tool["id"], "output_index": .number(Double(outputIndex)), "delta": .string(value)]))
            var fields: JSONObject = ["item_id": tool["id"], "output_index": .number(Double(outputIndex))]; fields[field] = .string(value); frames.append(event(prefix + ".done", fields))
            head[field] = .string(value); frames.append(event("response.output_item.done", ["output_index": .number(Double(outputIndex)), "item": head])); items.append(head); outputIndex += 1
        }
        tools.removeAll(); toolOrder.removeAll(); return frames
    }
    public mutating func finish(truncated: String? = nil) -> [ShimSSEFrame] {
        guard !terminated else { return [] }; var frames = start(); let tail = splitter.flush()
        frames += delta(tail.thinking, reasoning: true); frames += delta(tail.visible, reasoning: false); frames += close(); frames += emitTools()
        let failure = truncated ?? toolFailure
        if let failure { frames += delta("\n\n[uniapi-shim: " + failure + "]", reasoning: false); frames += close() }
        let incomplete = failure != nil || ["length", "max_tokens"].contains(stopReason ?? "")
        var extra: JSONObject = ["usage": usage]
        if incomplete { extra["incomplete_details"] = ["reason": failure == nil ? "max_output_tokens" : "upstream_error"] }
        frames.append(event(incomplete ? "response.incomplete" : "response.completed", ["response": snapshot(incomplete ? "incomplete" : "completed", extra: extra)])); frames.append(.init("done", .null)); terminated = true; return frames
    }
    public static func nonstream(_ message: JSONValue, model: String, tools: ShimToolMap) throws -> JSONValue {
        var stream = ShimResponsesStream(model: model, tools: tools)
        stream.inputTokens = message["usage"]["input_tokens"].int; stream.outputTokens = message["usage"]["output_tokens"].int; stream.stopReason = message["stop_reason"].string
        var texts: [String] = []
        for block in message["content"].array {
            if block["type"] == "text" { texts.append(block["text"].string) }
            else if block["type"] == "thinking" { _ = stream.delta(block["thinking"].string, reasoning: true); _ = stream.close() }
            else if block["type"] == "tool_use" { _ = stream.tool(String(stream.toolOrder.count), id: block["id"].string, name: block["name"].string, arguments: String(decoding: try (block["input"].isNull ? JSONValue.object([:]) : block["input"]).encoded(), as: UTF8.self)) }
        }
        _ = stream.emitTools(); _ = stream.delta(texts.filter { !$0.isEmpty }.joined(separator: "\n"), reasoning: false); _ = stream.close()
        if let failure = stream.toolFailure { _ = stream.delta("\n\n[uniapi-shim: " + failure + "]", reasoning: false); _ = stream.close() }
        let incomplete = stream.toolFailure != nil || stream.stopReason == "max_tokens"
        var extra: JSONObject = ["usage": stream.usage]; if incomplete { extra["incomplete_details"] = ["reason": stream.toolFailure == nil ? "max_output_tokens" : "upstream_error"] }
        return stream.snapshot(incomplete ? "incomplete" : "completed", extra: extra)
    }
}

public struct ShimAnthropicStream: Sendable {
    public let model: String, id: String
    public private(set) var started = false, terminated = false, contentCount = 0, sawTool = false, stopReason: String?
    private var index = -1, open = "", inputTokens = 0, outputTokens = 0, tools: [String: JSONValue] = [:], order: [String] = [], splitter = ShimThinkSplitter()
    public init(model: String) { self.model = model; id = "msg_" + UUID().uuidString }
    private func frame(_ name: String, _ fields: JSONObject = [:]) -> ShimSSEFrame { var value = fields; value["type"] = .string(name); return .init(name, .object(value)) }
    public mutating func start() -> [ShimSSEFrame] { guard !started else { return [] }; started = true; let message: JSONValue = ["id": .string(id), "type": "message", "role": "assistant", "content": [], "model": .string(model), "stop_reason": .null, "stop_sequence": .null, "usage": ["input_tokens": .number(Double(inputTokens)), "output_tokens": 0]]; return [frame("message_start", ["message": message])] }
    public func heartbeat() -> [ShimSSEFrame] { started && !terminated ? [frame("ping")] : [] }
    private mutating func close() -> [ShimSSEFrame] {
        guard !open.isEmpty else { return [] }; var frames: [ShimSSEFrame] = []
        if open == "thinking" { frames.append(frame("content_block_delta", ["index": .number(Double(index)), "delta": ["type": "signature_delta", "signature": ""]])) }
        frames.append(frame("content_block_stop", ["index": .number(Double(index))])); open = ""; return frames
    }
    private mutating func delta(_ text: String, thinking: Bool) -> [ShimSSEFrame] {
        guard !text.isEmpty else { return [] }; var frames = start(); let kind = thinking ? "thinking" : "text"
        if open != kind { frames += close(); index += 1; open = kind; let block: JSONValue = thinking ? ["type": "thinking", "thinking": ""] : ["type": "text", "text": ""]; frames.append(frame("content_block_start", ["index": .number(Double(index)), "content_block": block])) }
        if !thinking { contentCount += text.unicodeScalars.count }
        let change: JSONValue = thinking ? ["type": "thinking_delta", "thinking": .string(text)] : ["type": "text_delta", "text": .string(text)]
        frames.append(frame("content_block_delta", ["index": .number(Double(index)), "delta": change])); return frames
    }
    public mutating func feed(_ object: JSONValue) -> [ShimSSEFrame] {
        guard !terminated else { return [] }; let usage = object["usage"]
        if !usage["prompt_tokens"].isNull { inputTokens = usage["prompt_tokens"].int }; if !usage["completion_tokens"].isNull { outputTokens = usage["completion_tokens"].int }
        guard let choice = object["choices"].array.first else { return [] }; let change = choice["delta"]
        var frames = start(); frames += delta(change["reasoning"].string.isEmpty ? change["reasoning_content"].string : change["reasoning"].string, thinking: true)
        let parts = splitter.feed(ShimTranslation.streamedText(change["content"])); frames += delta(parts.thinking, thinking: true); frames += delta(parts.visible, thinking: false)
        for call in change["tool_calls"].array {
            sawTool = true; let key = String(call["index"].int)
            if tools[key] == nil { tools[key] = ["id": call["id"].isNull ? .string("toolu_" + UUID().uuidString) : call["id"], "name": call["function"]["name"], "arguments": ""]; order.append(key) }
            var item = tools[key]!; if !call["function"]["name"].string.isEmpty { item["name"] = call["function"]["name"] }; if !call["id"].string.isEmpty { item["id"] = call["id"] }; item["arguments"] = .string(item["arguments"].string + call["function"]["arguments"].string); tools[key] = item
        }
        if !choice["finish_reason"].isNull { stopReason = sawTool ? "tool_use" : ShimTranslation.finishReason(choice["finish_reason"].string) }; return frames
    }
    public mutating func finish(truncated: String? = nil) -> [ShimSSEFrame] {
        guard !terminated else { return [] }; var frames = start(); let tail = splitter.flush(); frames += delta(tail.thinking, thinking: true); frames += delta(tail.visible, thinking: false); frames += close()
        for key in order {
            let item = tools[key]!; index += 1
            let block: JSONValue = ["type": "tool_use", "id": item["id"], "name": item["name"], "input": [:]]
            frames.append(frame("content_block_start", ["index": .number(Double(index)), "content_block": block]))
            frames.append(frame("content_block_delta", ["index": .number(Double(index)), "delta": ["type": "input_json_delta", "partial_json": item["arguments"].string.isEmpty ? "{}" : item["arguments"]]]))
            frames.append(frame("content_block_stop", ["index": .number(Double(index))]))
        }
        if let truncated { frames += delta("\n\n[uniapi-shim: " + truncated + "]", thinking: false); frames += close() }
        frames.append(frame("message_delta", ["delta": ["stop_reason": .string(truncated == nil ? stopReason ?? (sawTool ? "tool_use" : "end_turn") : "end_turn"), "stop_sequence": .null], "usage": ["output_tokens": .number(Double(outputTokens))]])); frames.append(frame("message_stop")); terminated = true; return frames
    }
}
