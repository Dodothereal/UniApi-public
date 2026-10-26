import Foundation
import XCTest
@testable import UniApiCore

final class CodexNativeHistoryTests: XCTestCase {
    private typealias History = NativeCodexRouteHistory
    private func checkpoint(_ text: String) -> JSONValue { .string("ocx1:" + Data(text.utf8).base64EncodedString()) }
    private func request(_ items: [JSONValue]) -> JSONValue { ["model": "fixture", "input": .array(items), "tools": [], "metadata": ["keep": true]] }
    private let alias = "uniapi/fixture/model%3Afree"

    func testCanonicalCheckpointStrictUTF8AndBoundaryControls() {
        XCTAssertEqual(History.decodeCheckpoint(checkpoint("Résumé\n模型")), "Résumé\n模型")
        let invalidValues: [JSONValue] = [.null, 4, "other:YWJj", "ocx1:", "ocx1:Zg", "ocx1:Zh==", "ocx1:Zg===", "ocx1:Zg==\n", "ocx1:____", "ocx1:/w==", "ocx1:wK8=", "ocx1:7aCA"]
        for invalid in invalidValues {
            XCTAssertNil(History.decodeCheckpoint(invalid), "Accepted \(invalid)")
        }
        XCTAssertEqual(History.decodeCheckpoint("ocx1:77u/YQ=="), "a")
        XCTAssertEqual(History.decodeCheckpoint(checkpoint("\u{FEFF}\u{FEFF}a")), "\u{FEFF}a")
        XCTAssertEqual(History.decodeCheckpoint("ocx1:AA=="), "\0")
        XCTAssertNil(History.decodeCheckpoint(.string("ocx1:" + String(repeating: "A", count: 16 * 1024 * 1024 + 4))))
    }

    func testProviderRequiresFullHistoryAndRejectsReferences() throws {
        let base = request([["type": "message", "role": "user", "content": "hello"]])
        let references: [JSONValue] = ["native-response", "uniapi_response_foreign", [:], ["reference"]]
        for reference in references {
            var raw = base; raw["previous_response_id"] = reference
            XCTAssertThrowsError(try History.providerInput(raw))
        }
        let emptyReferences: [JSONValue] = [.null, "", false, 0]
        for empty in emptyReferences {
            var raw = base; raw["previous_response_id"] = empty
            XCTAssertEqual(try History.providerInput(raw), raw)
        }
        XCTAssertThrowsError(try History.providerInput(request([["type": "item_reference", "id": "native-item"]])))
        XCTAssertThrowsError(try History.providerInput(.null))
        let text: JSONValue = ["input": "simple input"]
        XCTAssertEqual(try History.providerInput(text), text)
    }

    func testEveryMandatoryEncryptedToolAndAgentBlockFailsClosed() throws {
        for type in ["agent_message", "function_call_output", "custom_tool_call_output"] {
            let field = type == "agent_message" ? "content" : "output"
            let ciphers: [JSONValue] = [["type": "encrypted_content", "data": "opaque"], ["type": "text", "encrypted_content": .null], ["encrypted_content": "opaque"]]
            for cipher in ciphers {
                var item: JSONValue = ["type": .string(type), "call_id": "call-stays"]
                item[field] = .array([["type": "text", "text": "readable"], cipher])
                XCTAssertThrowsError(try History.providerInput(request([item])))
                item[field] = cipher
                XCTAssertThrowsError(try History.providerInput(request([item])))
            }
            var topLevel: JSONValue = ["type": .string(type), "encrypted_content": .null]
            topLevel[field] = "plain part"
            XCTAssertThrowsError(try History.providerInput(request([topLevel])))
            topLevel["id"] = "uniapi_item_foreign"
            XCTAssertThrowsError(try History.nativeInput(request([topLevel])))
        }
    }

    func testProviderReplayPreservesToolsAndDropsOnlyOptionalReasoning() throws {
        let calls: [JSONValue] = [
            ["type": "function_call", "id": "item-function", "call_id": "call-function", "name": "read", "arguments": "{}"],
            ["type": "function_call_output", "id": "item-result", "call_id": "call-function", "output": "result"],
            ["type": "custom_tool_call", "id": "item-custom", "call_id": "call-custom", "name": "patch", "input": "patch text"],
            ["type": "custom_tool_call_output", "call_id": "call-custom", "output": [["type": "text", "text": "ok"]]],
            ["type": "agent_message", "author": "worker", "content": [["type": "text", "text": "plain context"]]]
        ]
        let reasoning: [JSONValue] = [
            ["type": "reasoning", "encrypted_content": "native-opaque"],
            ["type": "reasoning", "id": "reasoning", "encrypted_content": "ocxr1:opaque", "summary": [["text": "visible"]]]
        ]
        let raw = request(calls + reasoning + [["type": "compaction_trigger"], .null])
        let result = try History.providerInput(raw)
        XCTAssertEqual(result["metadata"], raw["metadata"])
        XCTAssertEqual(result["input"].array.count, calls.count + 2)
        for (original, clean) in zip(calls, result["input"].array) {
            var expected = original.object; expected.removeValue(forKey: "id")
            XCTAssertEqual(clean, .object(expected))
        }
        XCTAssertEqual(result["input"].array[calls.count]["summary"], reasoning[1]["summary"])
        XCTAssertNil(result["input"].array[calls.count].object["encrypted_content"])
        XCTAssertEqual(result["input"].array.last, .some(.null))
        XCTAssertEqual(raw["input"].array.first?["id"], "item-function")
    }

    func testProviderCheckpointFormsAndOldPlainMarker() throws {
        for type in ["compaction", "compaction_summary", "context_compaction"] {
            let raw = request([["type": .string(type), "encrypted_content": checkpoint("handoff")]])
            let item = try XCTUnwrap(History.providerInput(raw)["input"].array.first)
            XCTAssertEqual(item["role"], "user")
            XCTAssertTrue(item["content"].array[0]["text"].string.hasSuffix("\n\nhandoff"))
            let badValues: [JSONValue] = [.null, "native-opaque", "ocx1:Zh==", checkpoint(" \n\t")]
            for bad in badValues {
                XCTAssertThrowsError(try History.providerInput(request([["type": .string(type), "encrypted_content": bad]])))
            }
        }
        XCTAssertEqual(try History.providerInput(request([["type": "context_compaction"]]))["input"], [])
    }

    func testNativeSameBackendReferencesAndCiphertextAreExactlyPreserved() throws {
        let raw: JSONValue = ["previous_response_id": "resp_native", "input": [
            ["type": "item_reference", "id": "native-item"],
            ["type": "reasoning", "id": "rs_0123456789abcdef0123456789abcdef", "encrypted_content": "native-ciphertext"],
            ["type": "compaction", "encrypted_content": "native-checkpoint"],
            ["type": "function_call_output", "call_id": "native-call", "output": [["type": "encrypted_content", "data": "native-output"]]]
        ]]
        let result = try History.nativeInput(raw)
        XCTAssertFalse(result.changed); XCTAssertEqual(result.value, raw)
        XCTAssertFalse(try History.nativeInput(.null).changed)
        XCTAssertFalse(try History.nativeInput(request([["type": "reasoning", "id": "rs_short", "summary": []]])).changed)
        XCTAssertFalse(try History.nativeInput(request([["type": "reasoning", "id": "rs_0123456789abcdef0123456789abcdef", "summary": "not-array"]])).changed)
    }

    func testNativeRejectsProviderReferencesAndOpaqueProviderCheckpoints() throws {
        var raw = request([]); raw["previous_response_id"] = "uniapi_response_foreign"
        XCTAssertThrowsError(try History.nativeInput(raw))
        XCTAssertThrowsError(try History.nativeInput(request([["type": "item_reference", "id": "uniapi_item_foreign"]])))
        for type in ["compaction", "compaction_summary", "context_compaction"] {
            let badValues: [JSONValue] = [.null, "native-opaque", "ocx1:Zh==", checkpoint(" ")]
            for bad in badValues {
                XCTAssertThrowsError(try History.nativeInput(request([["type": .string(type), "id": "uniapi_item_foreign", "encrypted_content": bad]])))
            }
        }
        let legacy = try History.nativeInput(request([["type": "context_compaction", "id": "uniapi_item_legacy"]]))
        XCTAssertTrue(legacy.changed); XCTAssertEqual(legacy.value["input"], [])
    }

    func testNativeCrossBackendScrubsForeignAuthorityButKeepsToolLinkage() throws {
        var raw = request([
            ["type": "function_call", "id": "uniapi_item_provider", "call_id": "call-stays", "name": "read", "arguments": "{}"],
            ["type": "function_call_output", "id": "result", "call_id": "call-stays", "output": "ok"],
            ["type": "reasoning", "id": "uniapi_item_reason", "encrypted_content": "provider-opaque", "summary": [["text": "visible"]]],
            ["type": "reasoning", "id": "native-reason", "encrypted_content": "native-opaque"],
            ["type": "reasoning", "id": "uniapi_item_empty", "encrypted_content": "provider-opaque"]
        ])
        raw["previous_response_id"] = "resp_native"
        let result = try History.nativeInput(raw)
        XCTAssertTrue(result.changed); XCTAssertNil(result.value.object["previous_response_id"])
        XCTAssertEqual(result.value["input"].array.count, 4)
        XCTAssertTrue(result.value["input"].array.allSatisfy { $0.object["id"] == nil })
        XCTAssertEqual(result.value["input"].array[0]["call_id"], "call-stays")
        XCTAssertEqual(result.value["input"].array[1]["call_id"], "call-stays")
        XCTAssertNil(result.value["input"].array[2].object["encrypted_content"])
        XCTAssertEqual(result.value["input"].array[3]["encrypted_content"], "native-opaque")
    }

    func testExactBridgeReasoningPrefixAndLegacyReasoningRecognition() throws {
        let items: [JSONValue] = [
            ["type": "reasoning", "encrypted_content": "ocxr1:e30=", "summary": [["text": "visible"]]],
            ["type": "reasoning", "id": "rs_0123456789ABCDEF0123456789abcdef", "encrypted_content": .null, "content": [["text": "visible"]]]
        ]
        for item in items {
            let result = try History.nativeInput(request([item]))
            XCTAssertTrue(result.changed); XCTAssertEqual(result.value["input"].array.count, 1)
            XCTAssertNil(result.value["input"].array[0].object["encrypted_content"])
            XCTAssertNil(result.value["input"].array[0].object["id"])
        }
        let lookalike = request([["type": "reasoning", "encrypted_content": "ocxr2:e30="]])
        XCTAssertFalse(try History.nativeInput(lookalike).changed)
        XCTAssertEqual(try History.nativeInput(lookalike).value, lookalike)
        XCTAssertEqual(try History.nativeInput(request([["type": "reasoning", "encrypted_content": "ocxr1:e30="]])).value["input"], [])
    }

    func testNativeLocalCheckpointRecoveryAndStrictRejection() throws {
        let ids: [JSONValue] = ["bridge-item", "uniapi_item_checkpoint"]
        for id in ids {
            let result = try History.nativeInput(request([["type": "compaction", "id": id, "encrypted_content": checkpoint("carry this")]]))
            XCTAssertTrue(result.changed)
            XCTAssertTrue(result.value["input"].array[0]["content"].array[0]["text"].string.hasSuffix("\n\ncarry this"))
            XCTAssertThrowsError(try History.nativeInput(request([["type": "compaction", "id": id, "encrypted_content": "ocx1:/w=="]])))
        }
    }

    func testMarkKnownDigestAliasIsolationAndToolIdentifiers() throws {
        // SHA-256 of one NUL byte is an independent fixed protocol vector.
        let vector = History.mark(["object": "response", "id": ""], alias: "")
        XCTAssertEqual(vector["id"], "uniapi_response_6e340b9cffb37a989ca544e6bb780a2c")
        let raw: JSONValue = ["object": "response", "id": "resp", "output": [
            ["id": "tool-item", "type": "function_call", "call_id": "call-original", "tool_call_id": "tool-original", "arguments": "{}"],
            ["type": "custom_tool_call", "call_id": "custom-original", "input": "raw"]
        ]]
        let marked = History.mark(raw, alias: alias)
        XCTAssertTrue(marked["id"].string.hasPrefix("uniapi_response_"))
        XCTAssertEqual(marked["input"], .null)
        XCTAssertEqual(marked["output"].array[0]["call_id"], "call-original")
        XCTAssertEqual(marked["output"].array[0]["tool_call_id"], "tool-original")
        XCTAssertEqual(marked["output"].array[1]["call_id"], "custom-original")
        XCTAssertEqual(marked["output"].array[1]["input"], "raw")
        XCTAssertEqual(History.mark(raw, alias: alias), marked)
        let another = History.mark(raw, alias: alias + "-other")
        XCTAssertNotEqual(another["id"], marked["id"])
        XCTAssertNotEqual(another["output"].array[0]["id"], marked["output"].array[0]["id"])
        XCTAssertEqual(raw["output"].array[0]["id"], "tool-item")
    }

    func testMarkSSEItemsResponseAndMissingIndexAgreeWithJSON() {
        let response: JSONValue = ["id": "resp", "output": [["id": "item", "type": "message"], ["type": "message"]]]
        let marked = History.mark(response, alias: alias)
        let added = History.mark(["type": "response.output_item.added", "output_index": 0, "item": response["output"].array[0]], alias: alias)
        let missing = History.mark(["type": "response.output_item.done", "output_index": 1, "item": response["output"].array[1]], alias: alias)
        let delta = History.mark(["type": "response.output_text.delta", "item_id": "item", "delta": "hello"], alias: alias)
        let done = History.mark(["type": "response.completed", "response": response], alias: alias)
        XCTAssertEqual(added["item"]["id"], marked["output"].array[0]["id"])
        XCTAssertEqual(missing["item"]["id"], marked["output"].array[1]["id"])
        XCTAssertEqual(delta["item_id"], added["item"]["id"])
        XCTAssertEqual(done["response"], marked)
        XCTAssertEqual(delta["delta"], "hello")
        let firstMissing = History.mark(["output": [["type": "message"]]], alias: alias)
        let defaultIndex = History.mark(["item": ["type": "message"]], alias: alias)
        XCTAssertEqual(defaultIndex["item"]["id"], firstMissing["output"].array[0]["id"])
        XCTAssertNil(History.mark(["object": "response", "output": []], alias: alias).object["id"])
        XCTAssertEqual(History.mark(.null, alias: alias), .null)
    }

    func testHistoryStructuralBoundFailsBeforeAnyRewrite() {
        var nested: JSONValue = "leaf"
        for _ in 0..<130 { nested = .array([nested]) }
        XCTAssertThrowsError(try History.providerInput(request([nested])))
        XCTAssertThrowsError(try History.nativeInput(request([nested])))
    }
}
