import XCTest
@testable import UniApiCore

final class ShimReplaySafetyTests: XCTestCase {
    private let malformed = "ns_rejected</\u{ff5c}\u{ff5c}DSML\u{ff5c}\u{ff5c} parameter>\n<\u{ff5c}\u{ff5c}DSML\u{ff5c}\u{ff5c} parameter name="
    private func pair(custom: Bool = false, id: String = "rejected-call") -> [JSONValue] {
        var call: JSONValue = ["type": custom ? "custom_tool_call" : "function_call", "name": .string(malformed), "call_id": .string(id), "id": "keep-record-id", "status": "completed"]
        call[custom ? "input" : "arguments"] = "{}"
        return [call, ["type": custom ? "custom_tool_call_output" : "function_call_output", "call_id": .string(id), "output": .string("unsupported call: " + malformed)]]
    }
    private var declarations: JSONValue { [["type": "function", "name": "read", "parameters": ["type": "object"]]] }
    private func request(_ input: [JSONValue]) -> JSONValue { ["tools": declarations, "input": .array(input)] }
    private func conversationText(_ items: [JSONValue]) -> String { items.map { ShimTranslation.text($0) }.joined(separator: "\n") }
    private func originalRecord(_ item: JSONValue) throws -> JSONValue {
        let text = try XCTUnwrap(item["content"].array.first?["text"].string), newline = try XCTUnwrap(text.firstIndex(of: "\n"))
        return try JSONValue.decode(Data(text[text.index(after: newline)...].utf8))
    }
    func testClientRejectedMalformedCallsReplayAsCompleteNonExecutableEvidence() throws {
        for custom in [false, true] {
            let rejected = pair(custom: custom)
            let before: JSONValue = ["type": "message", "role": "user", "content": "prior work"]
            let after: JSONValue = ["type": "message", "role": "user", "content": "continue"]
            let raw = request([before] + rejected + [after]), original = raw
            let map = try ShimToolMap(raw), replay = try ShimToolMap.replayInput(raw)
            XCTAssertEqual(raw, original); XCTAssertEqual(replay.count, 4)
            XCTAssertEqual(replay.first, before); XCTAssertEqual(replay.last, after)
            XCTAssertEqual(replay[1]["type"], "message"); XCTAssertEqual(replay[1]["role"], "assistant")
            XCTAssertEqual(replay[2]["role"], "user")
            XCTAssertEqual(try originalRecord(replay[1]), rejected[0]); XCTAssertEqual(try originalRecord(replay[2]), rejected[1])
            XCTAssertFalse(map.names.keys.contains { $0.name == malformed })
            let translated = try ShimTranslation.responsesToAnthropic(raw, model: "fixture", tools: map)
            XCTAssertFalse(translated["messages"].array.flatMap { $0["content"].array }.contains { ["tool_use", "tool_result"].contains($0["type"].string) })
            XCTAssertTrue(conversationText(translated["messages"].array).contains("continue"))
        }
    }
    func testUnconfirmedAmbiguousMismatchedAndOpaqueFailuresStayStrict() throws {
        let good = pair()
        var changedOutput = good[1]; changedOutput["output"] = "a normal tool result"
        var wrongKind = good[1]; wrongKind["type"] = "custom_tool_call_output"
        var wrongID = good[1]; wrongID["call_id"] = "other-call"
        var encrypted = good[0]; encrypted["encrypted_content"] = "opaque"
        var encryptedOutput = good[1]; encryptedOutput["encrypted_content"] = "opaque"
        var encryptedArguments = good[0]; encryptedArguments["encrypted_function_args"] = ["opaque"]
        var numericCall = good[0]; numericCall["call_id"] = 7
        var stringCall = good[0]; stringCall["call_id"] = "7"
        var numericOutput = good[1]; numericOutput["call_id"] = 7
        var stringOutput = good[1]; stringOutput["call_id"] = "7"
        var badNamespace = good[0]; badNamespace["namespace"] = ""
        var nearMatch = good[1]; nearMatch["output"] = .string("unsupported call: " + malformed + " extra")
        for items in [[good[0]], [good[0], changedOutput], [good[0], wrongKind], [good[0], wrongID], [good[1], good[0]],
                      [good[0], good[0], good[1]], [good[0], good[1], good[1]], [encrypted, good[1]],
                      [good[0], encryptedOutput], [encryptedArguments, good[1]],
                      [numericCall, stringOutput], [numericCall, numericOutput], [stringCall, numericOutput],
                      [badNamespace, good[1]], [good[0], nearMatch]] {
            XCTAssertThrowsError(try ShimToolMap(request(items)))
        }
    }
    func testReplayPairingUsesExactIDBytesAndIdentityGuardIsNotWeakened() throws {
        var items = pair(id: "caf\u{e9}"); items[1]["call_id"] = "cafe\u{301}"
        XCTAssertThrowsError(try ShimToolMap(request(items)))
        let map = try ShimToolMap(["tools": declarations])
        XCTAssertThrowsError(try map.identity(["name": .string(malformed)]))
        XCTAssertThrowsError(try map.identity(["name": "read", "namespace": ""]))
        XCTAssertFalse(map.validOutputName(malformed)); XCTAssertTrue(map.validOutputName("read"))
    }
    func testValidCallsAndTheirUnsupportedResultsRemainOriginalToolHistory() throws {
        let input: [JSONValue] = [["type": "function_call", "name": "read", "call_id": "valid", "arguments": "{}"],
                                 ["type": "function_call_output", "call_id": "valid", "output": "unsupported call: read"]]
        let raw = request(input); XCTAssertEqual(try ShimToolMap.replayInput(raw), input)
        let translated = try ShimTranslation.responsesToAnthropic(raw, model: "fixture", tools: ShimToolMap(raw))
        XCTAssertTrue(translated["messages"].array.flatMap { $0["content"].array }.contains { $0["type"] == "tool_use" })
    }
    func testMalformedStreamWithholdsEntireToolBatchAndTerminatesIncomplete() throws {
        var stream = ShimResponsesStream(model: "fixture", tools: try ShimToolMap(["tools": declarations]))
        var frames = stream.feedOpenAI(["choices": [["delta": ["content": "retained answer", "tool_calls": [
            ["index": 0, "id": "valid", "function": ["name": "read", "arguments": "{}"]],
            ["index": 1, "id": "bad", "function": ["name": .string(malformed), "arguments": "{}"]]
        ]], "finish_reason": "tool_calls"]]])
        frames += stream.finish()
        XCTAssertFalse(stream.items.contains { ["function_call", "custom_tool_call"].contains($0["type"].string) })
        XCTAssertFalse(frames.contains { $0.event == "response.completed" })
        XCTAssertEqual(frames.dropLast().last?.event, "response.incomplete"); XCTAssertEqual(frames.last?.event, "done")
        XCTAssertTrue(conversationText(stream.items).contains("retained answer"))
        XCTAssertTrue(conversationText(stream.items).contains("invalid tool identity"))
        XCTAssertTrue(stream.finish().isEmpty); XCTAssertTrue(stream.terminated)
    }
    func testValidNamespacedStreamPreservesToolArgumentsAndLifecycle() throws {
        let map = try ShimToolMap(["tools": [["type": "namespace", "name": "functions", "tools": declarations]]])
        let name = try map.name(["name": "read"])
        var stream = ShimResponsesStream(model: "fixture", tools: map)
        var frames = stream.feedOpenAI(["choices": [["delta": ["tool_calls": [["index": 0, "id": "call-valid", "function": ["name": .string(name), "arguments": "{\"path\":\"file.txt\"}"]]]], "finish_reason": "tool_calls"]]])
        frames += stream.finish()
        let call = try XCTUnwrap(stream.items.first { $0["type"] == "function_call" })
        XCTAssertEqual(call["name"], "read"); XCTAssertEqual(call["namespace"], "functions"); XCTAssertEqual(call["call_id"], "call-valid")
        XCTAssertEqual(call["arguments"], "{\"path\":\"file.txt\"}")
        XCTAssertEqual(frames.dropLast().last?.event, "response.completed"); XCTAssertEqual(frames.last?.event, "done")
    }
    func testNonstreamMalformedToolsAreIncompleteAndDoNotExposeCallableItems() throws {
        let map = try ShimToolMap(["tools": declarations])
        let result = try ShimResponsesStream.nonstream(["content": [["type": "tool_use", "id": "bad", "name": .string(malformed), "input": [:]]], "usage": ["input_tokens": 2, "output_tokens": 3]], model: "fixture", tools: map)
        XCTAssertEqual(result["status"], "incomplete"); XCTAssertEqual(result["incomplete_details"]["reason"], "upstream_error")
        XCTAssertEqual(result["usage"]["total_tokens"], 5)
        XCTAssertFalse(result["output"].array.contains { ["function_call", "custom_tool_call"].contains($0["type"].string) })
        XCTAssertTrue(conversationText(result["output"].array).contains("invalid tool identity"))
    }
    func testToolsOnlyMapCannotDiscardSeparateRequestConversation() throws {
        let map = try ShimToolMap(["tools": declarations]), raw: JSONValue = ["input": "preserve this input"]
        let translated = try ShimTranslation.responsesToAnthropic(raw, model: "fixture", tools: map)
        XCTAssertEqual(translated["messages"].array.last?["content"].array.last?["text"], "preserve this input")
    }
}
