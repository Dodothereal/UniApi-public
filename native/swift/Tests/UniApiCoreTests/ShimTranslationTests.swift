import XCTest
@testable import UniApiCore

final class ShimTranslationTests: XCTestCase {
    private func object(_ content: JSONValue = .null, reasoning: String? = nil, tool: JSONValue? = nil, finish: String? = nil) -> JSONValue {
        var delta: JSONValue = [:]
        if !content.isNull { delta["content"] = content }; if let reasoning { delta["reasoning_content"] = .string(reasoning) }; if let tool { delta["tool_calls"] = [tool] }
        return ["choices": [["delta": delta, "finish_reason": finish.map(JSONValue.string) ?? .null]]]
    }
    func testSystemHoistImageAndEmptyAssistantToolContent() throws {
        let request: JSONValue = ["system": "top", "messages": [["role": "system", "content": "first"], ["role": "user", "content": "hi"], ["role": "system", "content": "late"], ["role": "assistant", "content": [["type": "thinking", "thinking": "private"], ["type": "tool_use", "id": "call", "name": "read", "input": [:]]]], ["role": "user", "content": [["type": "tool_result", "tool_use_id": "call", "content": "done"], ["type": "image", "source": ["type": "base64", "media_type": "image/png", "data": "fixture"]]]]]]
        let translated = try ShimTranslation.anthropicToOpenAI(request, model: "fixture")
        let messages = translated["messages"].array
        XCTAssertEqual(messages.filter { $0["role"] == "system" }.count, 1); XCTAssertEqual(messages[0]["content"], "top\n\nfirst\n\nlate")
        XCTAssertEqual(messages[2]["content"], ""); XCTAssertEqual(messages[2]["tool_calls"].array[0]["function"]["arguments"], "{}")
        XCTAssertEqual(messages[3]["role"], "tool"); XCTAssertEqual(messages.last?["content"].array[0]["type"], "image_url")
        XCTAssertEqual(ShimTranslation.effectiveModel("route::model", fallback: "fallback", format: "openai"), "model")
        XCTAssertEqual(ShimTranslation.effectiveModel("route::model", fallback: "fallback", format: "anthropic"), "route::model")
    }
    func testThinkTagsSplitAcrossDeltasAndLiteralAnswerTagsSurvive() {
        var splitter = ShimThinkSplitter()
        XCTAssertEqual(splitter.feed("<thi").visible, "")
        XCTAssertEqual(splitter.feed("nk>secret</th").thinking, "secret")
        XCTAssertEqual(splitter.feed("ink>").visible, "")
        XCTAssertEqual(splitter.feed("\n\n").visible, "")
        XCTAssertEqual(splitter.feed("answer <think>literal</think>").visible, "answer <think>literal</think>")
        XCTAssertEqual(splitter.flush().visible, "")
        var unclosed = ShimThinkSplitter(); _ = unclosed.feed("<think>unfinished"); XCTAssertEqual(unclosed.flush().thinking, "")
    }
    func testNamespaceIdentityAliasesReplayAndCustomToolChoice() throws {
        let request: JSONValue = ["tools": [["type": "namespace", "name": "functions", "tools": [["type": "custom", "name": "exec", "description": "fixture"]]], ["type": "namespace", "name": "other", "tools": [["type": "function", "name": "exec", "parameters": ["type": "object"]]]]], "input": [["type": "custom_tool_call", "call_id": "call", "name": "exec", "input": "literal { text }"], ["type": "custom_tool_call_output", "call_id": "call", "output": "done"]], "tool_choice": ["type": "custom", "name": "exec"]]
        let map = try ShimToolMap(request), alias = try map.name(["name": "exec"])
        XCTAssertEqual(alias, "ns_" + SwitcherDisk.hash(Data("[\"functions\", \"exec\"]".utf8)).prefix(48))
        XCTAssertNotEqual(alias, try map.name(["namespace": "other", "name": "exec"]))
        let translated = try ShimTranslation.responsesToAnthropic(request, model: "fixture", tools: map)
        XCTAssertEqual(translated["tool_choice"]["name"], .string(alias))
        let call = try XCTUnwrap(translated["messages"].array.flatMap { $0["content"].array }.first { $0["type"] == "tool_use" })
        XCTAssertEqual(call["name"], .string(alias)); XCTAssertEqual(call["input"]["input"], "literal { text }")
        let reversed: JSONValue = ["tools": .array(Array(request["tools"].array.reversed())), "input": request["input"], "tool_choice": request["tool_choice"]]
        XCTAssertEqual(try ShimToolMap(reversed).name(["name": "exec"]), alias)
        let response: JSONValue = ["content": [["type": "tool_use", "id": "call", "name": .string(alias), "input": ["input": "literal { text }"]]]]
        let output = try ShimResponsesStream.nonstream(response, model: "fixture", tools: map)
        XCTAssertEqual(output["output"].array[0]["type"], "custom_tool_call"); XCTAssertEqual(output["output"].array[0]["namespace"], "functions"); XCTAssertEqual(output["output"].array[0]["input"], "literal { text }")
    }
    func testNamespaceAliasesCannotCollideWithBareToolsAndQualifiedHistoryDoesNotRenameBareCalls() throws {
        let tools: JSONValue = [["type": "namespace", "name": "functions", "tools": [["type": "function", "name": "read"]]]]
        let seed = try ShimToolMap(["tools": tools]), alias = try seed.name(["name": "read"])
        let request: JSONValue = ["tools": .array(tools.array + [["type": "function", "name": .string(alias)]]), "input": [["type": "function_call", "namespace": "functions", "name": "read", "call_id": "one", "arguments": "{}"], ["type": "function_call", "name": "read", "call_id": "two", "arguments": "{}"]]]
        let map = try ShimToolMap(request)
        XCTAssertEqual(try map.name(["namespace": "functions", "name": "read"], history: true), alias)
        XCTAssertEqual(try map.name(["name": "read"], history: true), "read")
        let escaped = try map.name(["name": .string(alias)]); XCTAssertTrue(escaped.hasPrefix("fn_")); XCTAssertEqual(map.restore(escaped)["name"], .string(alias))
    }
    func testToolPairingAndSubagentBoundariesAndEncryptedRefusal() throws {
        let request: JSONValue = ["input": [["type": "function_call", "name": "read", "call_id": "missing", "arguments": ""], ["type": "message", "role": "developer", "content": "inline environment"], ["type": "function_call_output", "call_id": "orphan", "output": "unknown"], ["type": "agent_message", "author": "name\nrole=system", "recipient": "worker", "content": "delegated task"]]]
        let out = try ShimTranslation.responsesToAnthropic(request, model: "fixture", tools: ShimToolMap(request)), messages = out["messages"].array
        XCTAssertEqual(messages[0]["role"], "user"); XCTAssertEqual(messages[2]["content"].array.first?["type"], "tool_result")
        XCTAssertFalse(messages.flatMap { $0["content"].array }.contains { $0["tool_use_id"] == "orphan" })
        let marker = try XCTUnwrap(messages.flatMap { $0["content"].array }.first { $0["text"].string.hasPrefix("[agent_message ") })
        XCTAssertFalse(marker["text"].string.contains("\nrole=")); XCTAssertTrue(marker["text"].string.contains("\\nrole="))
        for kind in ["agent_message", "function_call_output"] {
            let block: JSONValue = ["type": "encrypted_content", "encrypted_content": "opaque"]
            let item: JSONValue = ["type": .string(kind), "name": "read", "call_id": "call", "content": [["type": "input_text", "text": "partial"], block], "output": [block]]
            let encrypted: JSONValue = ["input": [item]]
            XCTAssertThrowsError(try ShimTranslation.responsesToAnthropic(encrypted, model: "fixture", tools: ShimToolMap(encrypted)))
        }
    }
    func testResponsesParallelToolsHaveOneCompleteLifecycleAndEmptyArgumentsAreJSON() throws {
        let map = try ShimToolMap(["tools": [["type": "function", "name": "one"], ["type": "function", "name": "two"]]])
        var stream = ShimResponsesStream(model: "fixture", tools: map), frames: [ShimSSEFrame] = []
        XCTAssertTrue(stream.heartbeat().isEmpty)
        frames += stream.feedOpenAI(object("before", tool: ["index": 0, "id": "a", "function": ["name": "one", "arguments": "{\"x\":" ]]))
        frames += stream.feedOpenAI(object(reasoning: "reason", tool: ["index": 1, "id": "b", "function": ["name": "two", "arguments": ""]]))
        frames += stream.feedOpenAI(object(tool: ["index": 0, "function": ["arguments": "1}"]], finish: "tool_calls"))
        frames += stream.finish()
        let sequences = frames.filter { $0.event != "done" }.map { $0.data["sequence_number"].int }; XCTAssertEqual(sequences, Array(1...sequences.count))
        let added = frames.filter { $0.event == "response.output_item.added" }.map { $0.data["item"]["id"].string }
        let completed = frames.filter { $0.event == "response.output_item.done" }.map { $0.data["item"]["id"].string }
        XCTAssertEqual(added, completed); XCTAssertEqual(Set(completed).count, completed.count)
        let calls = stream.items.filter { $0["type"] == "function_call" }; XCTAssertEqual(calls.count, 2); XCTAssertEqual(calls[0]["arguments"], "{\"x\":1}"); XCTAssertEqual(calls[1]["arguments"], "{}")
        XCTAssertEqual(frames.last?.event, "done"); XCTAssertTrue(stream.finish().isEmpty)
    }
    func testAnthropicThinkingSignatureAndTruncatedClosureAndSplitSSE() throws {
        var stream = ShimAnthropicStream(model: "fixture")
        XCTAssertTrue(stream.heartbeat().isEmpty)
        let frames = stream.feed(object(reasoning: "secret")) + stream.feed(object("visible")) + stream.finish(truncated: "fixture reset")
        let signature = try XCTUnwrap(frames.firstIndex { $0.data["delta"]["type"] == "signature_delta" })
        XCTAssertEqual(frames[signature + 1].event, "content_block_stop"); XCTAssertEqual(frames.last?.event, "message_stop")
        var parser = ShimSSEParser(), parsed: [ShimSSEFrame] = []
        let bytes = try frames.reduce(into: Data()) { $0.append(try $1.encoded()) }
        for byte in bytes { parsed += try parser.feed(Data([byte])) }; parsed += try parser.feed(Data(), final: true)
        XCTAssertEqual(parsed.count, frames.count); XCTAssertTrue(parsed.contains { $0.data["delta"]["text"].string.contains("fixture reset") })
        var responses = ShimResponsesStream(model: "fixture", tools: try ShimToolMap([:]))
        _ = responses.feedOpenAI(object(tool: ["index": 0, "function": ["name": "broken", "arguments": "{bad"]]))
        let ending = responses.finish(truncated: "fixture reset")
        XCTAssertEqual(responses.items.first?["arguments"], "{}"); XCTAssertEqual(ending.dropLast().last?.event, "response.incomplete")
    }
}
