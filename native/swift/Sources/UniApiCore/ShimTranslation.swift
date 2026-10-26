import Foundation

public enum ShimTranslation {
    public static func text(_ value: JSONValue) -> String {
        if case .string(let text) = value { return text }
        if case .array(let blocks) = value { return blocks.map { block in if case .string = block { return block.string }; return block["text"].string }.filter { !$0.isEmpty }.joined(separator: "\n") }
        if case .object = value { return text(value["content"]) }
        return value.isNull ? "" : value.string
    }
    public static func streamedText(_ value: JSONValue) -> String {
        if case .string = value { return value.string }; if case .array = value { return text(value) }; return ""
    }
    public static func effectiveModel(_ requested: String, fallback: String, format: String) -> String {
        let model = requested.isEmpty ? fallback : requested
        if format != "anthropic", let separator = model.range(of: "::") { return String(model[separator.upperBound...]) }; return model
    }
    public static func anthropicToOpenAI(_ request: JSONValue, model: String) throws -> JSONValue {
        var messages: [JSONValue] = [], systems: [String] = []
        if !text(request["system"]).isEmpty { systems.append(text(request["system"])) }
        systems += request["messages"].array.filter { $0["role"] == "system" }.map { text($0["content"]) }.filter { !$0.isEmpty }
        if !systems.isEmpty { messages.append(["role": "system", "content": .string(systems.joined(separator: "\n\n"))]) }
        for message in request["messages"].array where message["role"] != "system" {
            let role = message["role"].string.isEmpty ? "user" : message["role"].string, content = message["content"]
            guard case .array(let blocks) = content else { messages.append(["role": .string(role), "content": .string(text(content))]); continue }
            var plain: [String] = [], tools: [JSONValue] = [], results: [JSONValue] = [], rich: [JSONValue] = []
            for block in blocks {
                if case .string = block { plain.append(block.string); rich.append(["type": "text", "text": block]); continue }
                switch block["type"].string {
                case "text": plain.append(block["text"].string); rich.append(["type": "text", "text": block["text"]])
                case "image":
                    let source = block["source"]
                    if source["type"] == "base64" && !source["data"].string.isEmpty {
                        let media = source["media_type"].string.isEmpty ? "image/png" : source["media_type"].string
                        rich.append(["type": "image_url", "image_url": ["url": .string("data:" + media + ";base64," + source["data"].string)]])
                    }
                case "tool_use":
                    let input = block["input"].isNull ? JSONValue.object([:]) : block["input"]
                    let id = block["id"].string.isEmpty ? "call_" + UUID().uuidString : block["id"].string
                    let function: JSONValue = ["name": block["name"], "arguments": .string(String(decoding: try input.encoded(), as: UTF8.self))]
                    tools.append(["id": .string(id), "type": "function", "function": function])
                case "tool_result": results.append(["role": "tool", "tool_call_id": block["tool_use_id"], "content": .string(text(block["content"]))])
                default: break
                }
            }
            if role == "assistant" {
                let joined = plain.filter { !$0.isEmpty }.joined(separator: "\n")
                if !joined.isEmpty || !tools.isEmpty { var assistant: JSONValue = ["role": "assistant", "content": .string(joined)]; if !tools.isEmpty { assistant["tool_calls"] = .array(tools) }; messages.append(assistant) }
            } else {
                messages += results
                if !rich.isEmpty {
                    let plainOnly = rich.allSatisfy { $0["type"] == "text" }, joined = rich.map { $0["text"].string }.joined(separator: "\n")
                    if !plainOnly || !joined.isEmpty { messages.append(["role": "user", "content": plainOnly ? .string(joined) : .array(rich)]) }
                } else if results.isEmpty { messages.append(["role": "user", "content": .string(text(content))]) }
            }
        }
        var output: JSONValue = ["model": .string(model), "messages": .array(messages), "stream": request["stream"]]
        for (source, destination) in [("max_tokens", "max_tokens"), ("temperature", "temperature"), ("top_p", "top_p"), ("stop_sequences", "stop")] where !request[source].isNull { output[destination] = request[source] }
        let tools: [JSONValue] = request["tools"].array.compactMap { tool in
            guard !tool["name"].string.isEmpty, tool["type"].isNull || tool["type"] == "" || tool["type"] == "custom" else { return nil }
            var function: JSONValue = ["name": tool["name"], "parameters": tool["input_schema"].object.isEmpty ? ["type": "object", "properties": [:]] : tool["input_schema"]]
            if !tool["description"].isNull { function["description"] = tool["description"] }; return ["type": "function", "function": function]
        }
        if !tools.isEmpty {
            output["tools"] = .array(tools); let choice = request["tool_choice"]
            switch choice["type"].string {
            case "tool": output["tool_choice"] = ["type": "function", "function": ["name": choice["name"]]]
            case "any": output["tool_choice"] = "required"
            case "auto", "none": output["tool_choice"] = choice["type"]
            default: break
            }
        }
        if request["stream"].bool { output["stream_options"] = ["include_usage": true] }
        return output
    }
    public static func openAIToAnthropic(_ response: JSONValue, model: String) throws -> JSONValue {
        let choice = response["choices"].array.first ?? [:], message = choice["message"], usage = response["usage"]
        var blocks: [JSONValue] = []
        let reasoning = message["reasoning"].string.isEmpty ? message["reasoning_content"].string : message["reasoning"].string
        if !reasoning.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { blocks.append(["type": "thinking", "thinking": .string(reasoning), "signature": ""]) }
        var splitter = ShimThinkSplitter(); let part = splitter.feed(streamedText(message["content"])), tail = splitter.flush()
        if blocks.isEmpty && !(part.thinking + tail.thinking).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { blocks.append(["type": "thinking", "thinking": .string(part.thinking + tail.thinking), "signature": ""]) }
        if !(part.visible + tail.visible).isEmpty { blocks.append(["type": "text", "text": .string(part.visible + tail.visible)]) }
        for call in message["tool_calls"].array {
            let raw = call["function"]["arguments"].string
            var input = (try? JSONValue.decode(Data((raw.isEmpty ? "{}" : raw).utf8))) ?? [:]
            if case .object = input {} else { input = ["value": input] }
            blocks.append(["type": "tool_use", "id": call["id"].isNull ? .string("toolu_" + UUID().uuidString) : call["id"], "name": call["function"]["name"], "input": input])
        }
        if blocks.isEmpty { blocks = [["type": "text", "text": ""]] }
        let stop = blocks.contains { $0["type"] == "tool_use" } ? "tool_use" : finishReason(choice["finish_reason"].string)
        return ["id": response["id"].isNull ? .string("msg_" + UUID().uuidString) : response["id"], "type": "message", "role": "assistant", "model": response["model"].isNull ? .string(model) : response["model"], "content": .array(blocks), "stop_reason": .string(stop), "stop_sequence": .null, "usage": ["input_tokens": usage["prompt_tokens"].isNull ? 0 : usage["prompt_tokens"], "output_tokens": usage["completion_tokens"].isNull ? 0 : usage["completion_tokens"]]]
    }
    public static func finishReason(_ value: String) -> String { ["tool_calls": "tool_use", "length": "max_tokens", "stop": "end_turn", "content_filter": "end_turn"][value] ?? "end_turn" }
    public static func inputItems(_ request: JSONValue) -> [JSONValue] {
        if case .string = request["input"] { return [["type": "message", "role": "user", "content": request["input"]]] }
        return request["input"].array.filter { if case .object = $0 { return true }; return false }
    }
    public static func content(_ value: JSONValue) -> [JSONValue] {
        if case .string = value { return value.string.isEmpty ? [] : [["type": "text", "text": value]] }
        return value.array.compactMap { block in
            if case .string = block { return block.string.isEmpty ? nil : ["type": "text", "text": block] }
            switch block["type"].string {
            case "input_text", "output_text", "text", "summary_text", "reasoning_text": return block["text"].string.isEmpty ? nil : ["type": "text", "text": block["text"]]
            case "refusal": return block["refusal"].string.isEmpty ? nil : ["type": "text", "text": .string("[refusal: " + block["refusal"].string + "]")]
            case "input_image":
                let url = block["image_url"].string
                if url.hasPrefix("data:"), let comma = url.firstIndex(of: ",") {
                    let media = String(url[url.index(url.startIndex, offsetBy: 5)..<comma]).split(separator: ";").first.map(String.init) ?? "image/png"
                    return ["type": "image", "source": ["type": "base64", "media_type": .string(media), "data": .string(String(url[url.index(after: comma)...]))]]
                }
                if !url.isEmpty { return ["type": "image", "source": ["type": "url", "url": .string(url)]] }
                return ["type": "text", "text": .string("[image: " + (block["file_id"].string.isEmpty ? "?" : block["file_id"].string) + "]")]
            case "input_file": return ["type": "text", "text": .string("[file: " + (block["file_id"].string.isEmpty ? block["filename"].string.isEmpty ? "?" : block["filename"].string : block["file_id"].string) + "]")]
            default: return nil
            }
        }
    }
    public static func responsesToAnthropic(_ request: JSONValue, model: String, tools: ShimToolMap) throws -> JSONValue {
        var systems: [String] = request["instructions"].string.isEmpty ? [] : [request["instructions"].string], messages: [JSONValue] = []
        func push(_ role: String, _ blocks: [JSONValue]) {
            guard !blocks.isEmpty else { return }
            if messages.last?["role"] == .string(role) { var last = messages.removeLast(); last["content"] = .array(last["content"].array + blocks); messages.append(last) }
            else { messages.append(["role": .string(role), "content": .array(blocks)]) }
        }
        for item in try ShimToolMap.replayInput(request) {
            let kind = item["type"].string.isEmpty ? "message" : item["type"].string
            switch kind {
            case "message":
                let blocks = content(item["content"])
                if item["role"] == "system" { let value = text(.array(blocks)); if !value.isEmpty { systems.append(value) } }
                else { push(item["role"] == "assistant" ? "assistant" : "user", blocks) }
            case "agent_message":
                let parts = [item] + (item["content"].array.isEmpty ? [item["content"]] : item["content"].array)
                guard !parts.contains(where: { $0["type"] == "encrypted_content" || $0.object["encrypted_content"] != nil }) else { throw NativeFailure("Encrypted subagent context cannot be translated; send plaintext context") }
                let blocks = content(item["content"])
                guard blocks.contains(where: { $0["type"] != "text" || !$0["text"].string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }),
                      !blocks.contains(where: { $0["type"] == "image" && ($0["source"]["type"] != "base64" || $0["source"]["data"].string.isEmpty) }) else { throw NativeFailure("Subagent messages require plaintext or supported base64 image content") }
                let routing = item.object.filter { field in
                    guard ["author", "recipient"].contains(field.key) else { return false }
                    if case .string = field.value { return true }; return false
                }
                let marker = String(decoding: try JSONValue.object(routing).encoded(), as: UTF8.self)
                push("user", [["type": "text", "text": .string("[agent_message " + marker + "]")]] + blocks + [["type": "text", "text": "[/agent_message]"]])
            case "function_call", "custom_tool_call":
                let raw = item[kind == "custom_tool_call" ? "input" : "arguments"].string
                var input: JSONValue = kind == "custom_tool_call" ? ["input": .string(raw)] : (try? JSONValue.decode(Data((raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "{}" : raw).utf8))) ?? ["input": .string(raw)]
                if case .object = input {} else { input = ["input": input] }
                push("assistant", [["type": "tool_use", "id": item["call_id"].isNull ? .string("toolu_" + UUID().uuidString) : item["call_id"], "name": .string(try tools.name(item, history: true)), "input": input]])
            case "function_call_output", "custom_tool_call_output":
                let parts = [item] + (item["output"].array.isEmpty ? [item["output"]] : item["output"].array)
                guard !parts.contains(where: { $0["type"] == "encrypted_content" || $0.object["encrypted_content"] != nil }) else { throw NativeFailure("Encrypted tool results cannot be translated; use plain context") }
                push("user", [["type": "tool_result", "tool_use_id": item["call_id"], "content": .string(text(.array(content(item["output"]))))]])
            default: break
            }
        }
        if !messages.isEmpty && messages[0]["role"] != "user" { messages.insert(["role": "user", "content": [["type": "text", "text": "(continue)"]]], at: 0) }
        messages = pairTools(messages)
        let cap = request["max_output_tokens"].int
        var output: JSONValue = ["model": .string(model), "messages": .array(messages), "stream": .bool(request["stream"].bool), "max_tokens": .number(Double(cap > 0 ? cap : 32000))]
        if cap <= 0 { output["_uniapi_default_max_tokens"] = true }
        if !systems.isEmpty { output["system"] = .string(systems.joined(separator: "\n\n")) }
        for key in ["temperature", "top_p"] where !request[key].isNull { output[key] = request[key] }
        if case .string = request["stop"] { output["stop_sequences"] = [request["stop"]] }
        else if !request["stop"].array.isEmpty { output["stop_sequences"] = request["stop"] }
        let declarations = tools.definitions.map { definition -> JSONValue in
            let row = definition.tool
            let schema: JSONValue = row["type"] == "custom" || row["parameters"].isNull ? ["type": "object", "properties": ["input": ["type": "string"]], "required": ["input"]] : row["parameters"]
            return ["name": .string(tools.names[definition.identity]!), "description": row["description"].isNull ? "" : row["description"], "input_schema": schema]
        }
        if !declarations.isEmpty {
            output["tools"] = .array(declarations)
            let choice = request["tool_choice"]
            if choice == "required" { output["tool_choice"] = ["type": "any"] }
            else if choice == "auto" || choice == "none" { output["tool_choice"] = ["type": choice] }
            else if !choice["name"].string.isEmpty { output["tool_choice"] = ["type": "tool", "name": .string(try tools.name(choice))] }
        }
        return output
    }
    public static func pairTools(_ input: [JSONValue]) -> [JSONValue] {
        var messages = input
        let called = Set(messages.flatMap { $0["content"].array }.filter { $0["type"] == "tool_use" }.map { $0["id"].string })
        var answered = Set(messages.flatMap { $0["content"].array }.filter { $0["type"] == "tool_result" }.map { $0["tool_use_id"].string })
        for index in messages.indices where messages[index]["role"] == "user" {
            let kept = messages[index]["content"].array.filter { $0["type"] != "tool_result" || called.contains($0["tool_use_id"].string) }
            messages[index]["content"] = .array(kept.filter { $0["type"] == "tool_result" } + kept.filter { $0["type"] != "tool_result" })
        }
        for index in messages.indices.reversed() where messages[index]["role"] == "assistant" {
            let missing = messages[index]["content"].array.filter { $0["type"] == "tool_use" && !answered.contains($0["id"].string) }
            let stubs: [JSONValue] = missing.map { ["type": "tool_result", "tool_use_id": $0["id"], "content": "[uniapi-shim: this call was not answered in the transcript]"] }
            if !stubs.isEmpty {
                if index + 1 < messages.count && messages[index + 1]["role"] == "user" { messages[index + 1]["content"] = .array(stubs + messages[index + 1]["content"].array) }
                else { messages.insert(["role": "user", "content": .array(stubs)], at: index + 1) }
                answered.formUnion(missing.map { $0["id"].string })
            }
        }
        return messages.filter { !$0["content"].array.isEmpty }
    }
}

/// Only a leading model scaffold is split. Once it closes, literal tags in
/// answers and patches pass through, including across chunk boundaries.
public struct ShimThinkSplitter: Sendable {
    private var buffer = "", state = 0, stripNewlines = false
    public init() {}
    private mutating func lead(_ text: String) -> String {
        guard stripNewlines else { return text }; let trimmed = String(text.drop(while: { $0 == "\n" })); if !trimmed.isEmpty { stripNewlines = false }; return trimmed
    }
    public mutating func feed(_ text: String) -> (visible: String, thinking: String) {
        if state == 2 { return (lead(text), "") }; buffer += text
        var visible = ""
        if state == 0 {
            let trimmed = buffer.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty { return ("", "") }
            let opens = ["<think>", "<thinking>"]
            if let opener = opens.first(where: { trimmed.hasPrefix($0) }) {
                let start = buffer.range(of: opener)!.lowerBound; visible = String(buffer[..<start]); buffer = String(buffer[buffer.index(start, offsetBy: opener.count)...]); state = 1
            } else if opens.contains(where: { $0.hasPrefix(trimmed) }) { return ("", "") }
            else { state = 2; let value = buffer; buffer = ""; return (value, "") }
        }
        let closers = ["</think>", "</thinking>"]
        if let range = closers.compactMap({ buffer.range(of: $0) }).min(by: { $0.lowerBound < $1.lowerBound }) {
            let thinking = String(buffer[..<range.lowerBound]), rest = String(buffer[range.upperBound...]); buffer = ""; state = 2; stripNewlines = true; return (visible + lead(rest), thinking)
        }
        var hold = 0
        for count in 1...min(11, max(1, buffer.count)) where closers.contains(where: { $0.hasPrefix(String(buffer.suffix(count))) }) { hold = count }
        let thinking = String(buffer.dropLast(hold)); buffer = String(buffer.suffix(hold)); return (visible, thinking)
    }
    public mutating func flush() -> (visible: String, thinking: String) { let rest = buffer; buffer = ""; return state == 1 ? ("", rest) : (rest, "") }
}
