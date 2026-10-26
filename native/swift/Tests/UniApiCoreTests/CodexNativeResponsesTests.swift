import Foundation
import XCTest
@testable import UniApiCore

private final class CodexResponsesGate: @unchecked Sendable {
    private let lock = NSLock()
    private var open = false, waiters: [CheckedContinuation<Void, Never>] = []
    init(open: Bool = false) { self.open = open }
    var isOpen: Bool { lock.withLock { open } }
    func wait() async {
        await withCheckedContinuation { continuation in
            let ready = lock.withLock { if open { return true }; waiters.append(continuation); return false }
            if ready { continuation.resume() }
        }
    }
    func signal() {
        let pending = lock.withLock { () -> [CheckedContinuation<Void, Never>] in open = true; let result = waiters; waiters = []; return result }
        pending.forEach { $0.resume() }
    }
}

/// Stream EOF/cancel and transport acknowledgement deliberately have separate gates.
private final class CodexResponsesUpstream: @unchecked Sendable {
    let cancelled = CodexResponsesGate(), drained: CodexResponsesGate
    private let stream: AsyncThrowingStream<Data, Error>, continuation: AsyncThrowingStream<Data, Error>.Continuation
    init(heldDrain: Bool = false) {
        drained = .init(open: !heldDrain)
        let pair = AsyncThrowingStream<Data, Error>.makeStream(); stream = pair.stream; continuation = pair.continuation
    }
    func response(sse: Bool = true, status: Int = 200) -> ShimClientResponse {
        .init(status: status, headers: ["content-type": sse ? "text/event-stream" : "application/json", "set-cookie": "must-not-forward"],
              chunks: stream, cancel: { self.cancel() }, waitForCompletion: { await self.drained.wait() })
    }
    func yield(_ bytes: Data) { continuation.yield(bytes) }
    func finish() { continuation.finish() }
    func fail(_ error: Error) { continuation.finish(throwing: error) }
    func cancel() { continuation.finish(throwing: CancellationError()); cancelled.signal() }
    func release() { cancel(); drained.signal() }
}

final class CodexNativeResponsesTests: XCTestCase {
    private typealias Responses = NativeCodexRouteResponses
    private let alias = "uniapi/fixture/model%3Afree"
    private func terminal(_ text: String = "handoff") -> JSONValue {
        ["id": "upstream-response", "object": "response", "status": "completed", "output": [
            ["type": "message", "id": "upstream-item", "role": "assistant", "status": "completed", "content": [["type": "output_text", "text": .string(text)]]]
        ]]
    }
    private func raw(stream: Bool = false, input: [JSONValue] = []) -> JSONValue { ["model": .string(alias), "stream": .bool(stream), "input": .array(input)] }
    private func bytes(_ data: Data, sse: Bool = true, status: Int = 200) -> ShimClientResponse {
        .init(status: status, headers: ["content-type": sse ? "text/event-stream" : "application/json"],
              chunks: AsyncThrowingStream { $0.yield(data); $0.finish() })
    }
    private func json(_ value: JSONValue) throws -> ShimClientResponse { bytes(try value.encoded(), sse: false) }
    private func event(_ value: JSONValue, crlf: Bool = false) throws -> Data {
        let newline = crlf ? "\r\n" : "\n"
        return Data(("event: " + value["type"].string + newline + "data: " + String(decoding: try value.encoded(), as: UTF8.self) + newline + newline).utf8)
    }
    private func events(_ bytes: Data) throws -> [JSONValue] {
        let text = try XCTUnwrap(String(data: bytes, encoding: .utf8))
        return try text.components(separatedBy: "\n\n").compactMap { frame in
            let text = frame.components(separatedBy: "\n").filter { $0.hasPrefix("data:") }.map { String($0.dropFirst(5)).trimmingCharacters(in: .whitespaces) }.joined(separator: "\n")
            if text.isEmpty || text == "[DONE]" { return nil }
            return try JSONValue.decode(Data(text.utf8))
        }
    }

    func testWrapJSONAndByteSplitSSEHaveIdenticalProvenanceAndToolIDs() async throws {
        let response: JSONValue = ["object": "response", "id": "response-id", "output": [
            ["id": "item-id", "type": "function_call", "call_id": "call-link", "name": "read", "arguments": "{}"],
            ["type": "message", "content": [["type": "output_text", "text": "Résumé 模型"]]]
        ]]
        let wrappedJSON = try await Responses.wrap(json(response), alias: alias)
        let marked = try JSONValue.decode(await wrappedJSON.body())
        let added: JSONValue = ["type": "response.output_item.added", "output_index": 0, "item": response["output"].array[0]]
        let delta: JSONValue = ["type": "response.function_call_arguments.delta", "item_id": "item-id", "delta": "{}"]
        let missing: JSONValue = ["type": "response.output_item.done", "output_index": 1, "item": response["output"].array[1]]
        let done: JSONValue = ["type": "response.completed", "response": response]
        var wire = Data([0xef, 0xbb, 0xbf]); wire.append(Data(": keepalive\r\n\r\n".utf8))
        for value in [added, delta, missing, done] { wire.append(try event(value, crlf: true)) }
        wire.append(Data("data: [DONE]\r\n\r\n".utf8))
        let upstream = CodexResponsesUpstream(); defer { upstream.release() }
        for byte in wire { upstream.yield(Data([byte])) }; upstream.finish()
        let wrappedSSE = try await Responses.wrap(upstream.response(), alias: alias)
        let result = try await wrappedSSE.body(), values = try events(result)
        XCTAssertEqual(values.count, 4)
        XCTAssertEqual(values[0]["item"]["id"], marked["output"].array[0]["id"])
        XCTAssertEqual(values[1]["item_id"], values[0]["item"]["id"])
        XCTAssertEqual(values[2]["item"]["id"], marked["output"].array[1]["id"])
        XCTAssertEqual(values[3]["response"], marked)
        XCTAssertEqual(values[0]["item"]["call_id"], "call-link")
        XCTAssertTrue(String(decoding: result, as: UTF8.self).hasSuffix("data: [DONE]\n\n"))
        XCTAssertNil(wrappedSSE.headers["set-cookie"])
    }

    func testWrapRejectsMalformedJSONInvalidUTF8AndOversizedFrames() async throws {
        let invalidFrames = [Data("data: {broken}\n\n".utf8), Data("data: \"".utf8) + Data([0xff]) + Data("\"\n\n".utf8), Data(repeating: 65, count: 8 * 1024 * 1024 + 1)]
        for input in invalidFrames {
            let response = try await Responses.wrap(bytes(input), alias: alias)
            do { _ = try await response.body(); XCTFail("Invalid SSE accepted") } catch {}
        }
        for input in [Data("{broken}".utf8), Data([0xff]), Data(repeating: 32, count: 16 * 1024 * 1024 + 1)] {
            do { _ = try await Responses.wrap(bytes(input, sse: false), alias: alias); XCTFail("Invalid JSON accepted") } catch {}
        }
    }

    func testWrapMultilineDataAndUnterminatedFinalFrame() async throws {
        let wire = Data("event: response.output_item.done\ndata: {\"type\":\"response.output_item.done\",\ndata: \"output_index\":0,\"item\":{\"type\":\"message\"}}".utf8)
        let wrapped = try await Responses.wrap(bytes(wire), alias: alias)
        let values = try events(await wrapped.body())
        XCTAssertEqual(values.count, 1)
        XCTAssertTrue(values[0]["item"]["id"].string.hasPrefix("uniapi_item_"))
    }

    func testWrapDoesNotExposeUntrustedTransportErrorText() async throws {
        for sse in [false, true] {
            let upstream = CodexResponsesUpstream(); defer { upstream.release() }
            upstream.fail(NativeFailure("private-user-input"))
            do {
                let wrapped = try await Responses.wrap(upstream.response(sse: sse), alias: alias)
                _ = try await wrapped.body(); XCTFail("Transport error accepted")
            } catch { XCTAssertFalse(error.localizedDescription.contains("private-user-input")) }
        }
    }

    func testWrapTicketAndCancellationWaitForTransportAcknowledgement() async throws {
        let upstream = CodexResponsesUpstream(heldDrain: true), activity = ShimRequestActivity(), ticket = try XCTUnwrap(activity.begin())
        defer { upstream.release() }
        let response = try await Responses.wrap(upstream.response(), alias: alias, ticket: ticket)
        ticket.finish(); XCTAssertEqual(activity.active, 1)
        response.cancel(); response.cancel(); await upstream.cancelled.wait()
        let done = CodexResponsesGate(), waiter = Task { await response.waitForCompletion(); done.signal() }
        for _ in 0..<32 { await Task.yield() }
        XCTAssertFalse(done.isOpen); XCTAssertEqual(activity.active, 1)
        upstream.drained.signal(); await waiter.value
        XCTAssertEqual(activity.active, 0)
        do { _ = try await response.body(); XCTFail("Cancelled response succeeded") } catch { XCTAssertTrue(error is CancellationError) }
    }

    func testWrapNormalEOFKeepsProducerTicketThroughHeldDrain() async throws {
        let upstream = CodexResponsesUpstream(heldDrain: true), activity = ShimRequestActivity(), ticket = try XCTUnwrap(activity.begin())
        defer { upstream.release() }
        upstream.yield(Data("data: [DONE]\n\n".utf8)); upstream.finish()
        let response = try await Responses.wrap(upstream.response(), alias: alias, ticket: ticket)
        ticket.finish(); await upstream.cancelled.wait(); XCTAssertEqual(activity.active, 1)
        upstream.drained.signal(); await response.waitForCompletion(); XCTAssertEqual(activity.active, 0)
        let body = try await response.body(); XCTAssertTrue(String(decoding: body, as: UTF8.self).contains("[DONE]"))
    }

    func testWrapOverflowFailsClosedAndDrainsBeforeRetiringTicket() async throws {
        let upstream = CodexResponsesUpstream(heldDrain: true), activity = ShimRequestActivity(), ticket = try XCTUnwrap(activity.begin())
        defer { upstream.release() }
        upstream.yield(Data(String(repeating: ": keepalive\n\n", count: 513).utf8)); upstream.finish()
        let response = try await Responses.wrap(upstream.response(), alias: alias, ticket: ticket)
        ticket.finish(); await upstream.cancelled.wait(); XCTAssertEqual(activity.active, 1)
        upstream.drained.signal(); await response.waitForCompletion(); XCTAssertEqual(activity.active, 0)
        do { _ = try await response.body(); XCTFail("Dropped frame silently accepted") } catch { XCTAssertEqual(error.localizedDescription, "Invalid UniApi response stream") }
    }

    func testWrapJSONCancellationDuringEOFDrainCannotBecomeSuccess() async throws {
        let upstream = CodexResponsesUpstream(heldDrain: true), activity = ShimRequestActivity(), ticket = try XCTUnwrap(activity.begin())
        defer { upstream.release() }
        upstream.yield(try terminal().encoded()); upstream.finish()
        let pending = Task { try await Responses.wrap(upstream.response(sse: false), alias: alias, ticket: ticket) }
        await upstream.cancelled.wait(); ticket.finish(); XCTAssertEqual(activity.active, 1)
        pending.cancel(); upstream.drained.signal()
        do { _ = try await pending.value; XCTFail("Cancelled JSON returned") } catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertEqual(activity.active, 0)
    }

    func testCompactUnaryRetainsRecentHumanTextMetadataAndZeroImages() async throws {
        let first = try await Responses.compact(json(terminal("old summary")), raw: raw(), unary: true, context: 128000)
        let oldSummary = try JSONValue.decode(await first.body())["output"].array[0]
        let input: [JSONValue] = [
            ["role": "assistant", "content": "not human"], oldSummary,
            ["role": "user", "content": "<codex_internal_context source=\"goal_continue\">internal secret</codex_internal_context>"],
            ["role": "user", "content": [["type": "text", "text": "<goal_context>steering</goal_context>"]]],
            ["role": "user", "content": "too old"],
            ["id": "human-id", "role": "user", "metadata": ["real": true], "content": [
                ["type": "input_text", "text": "abcdefghijklmnop"], ["type": "input_image", "image_url": "data:must-not-retain"]
            ]]
        ]
        let compacted = try await Responses.compact(json(terminal()), raw: raw(input: input), unary: true, context: 12)
        let value = try JSONValue.decode(await compacted.body()), output = value["output"].array
        XCTAssertEqual(output.count, 2)
        XCTAssertEqual(output[0]["content"], [["type": "input_text", "text": "efghijklmnop"]])
        XCTAssertEqual(output[0]["id"], "human-id"); XCTAssertEqual(output[0]["metadata"], ["real": true])
        XCTAssertTrue(output[1]["content"].array[0]["text"].string.hasSuffix("\nhandoff"))
        XCTAssertFalse(String(decoding: try value.encoded(), as: UTF8.self).contains("must-not-retain"))
    }

    func testCompactUnaryExcludesOldSummaryAndInternalWrappersWithoutBudgetHidingThem() async throws {
        let prior = try await Responses.compact(json(terminal("previous")), raw: raw(), unary: true, context: 128000)
        let old = try JSONValue.decode(await prior.body())["output"].array[0]
        let input: [JSONValue] = [old, ["role": "user", "content": "<goal_context>secret</goal_context>"],
            ["role": "user", "content": "<codex_internal_context source=\"resume\">secret</codex_internal_context>"],
            ["role": "user", "content": "human"]]
        let response = try await Responses.compact(json(terminal()), raw: raw(input: input), unary: true, context: 128000)
        let output = try JSONValue.decode(await response.body())["output"].array
        XCTAssertEqual(output.count, 2); XCTAssertEqual(output[0]["content"].array[0]["text"], "human")
    }

    func testCompactRetainedTextCapAndScalarBoundary() async throws {
        let input: [JSONValue] = [["role": "user", "content": .string(String(repeating: "a", count: 80001))]]
        let response = try await Responses.compact(json(terminal()), raw: raw(input: input), unary: true, context: 1_048_576)
        let output = try JSONValue.decode(await response.body())["output"].array
        XCTAssertEqual(output[0]["content"].array[0]["text"].string.utf16.count, 80000)
        let scalarInput: [JSONValue] = [["role": "user", "content": "old\u{1D11E}abc"]]
        let scalarResponse = try await Responses.compact(json(terminal("ok")), raw: raw(input: scalarInput), unary: true, context: 4)
        let scalarText = try JSONValue.decode(await scalarResponse.body())["output"].array[0]["content"].array[0]["text"].string
        XCTAssertEqual(scalarText, "abc"); XCTAssertFalse(scalarText.contains("\u{FFFD}"))
    }

    func testCompactRequiresAuthoritativeCompletionNotTextDeltasOrDONE() async throws {
        let delta = try event(["type": "response.output_text.delta", "delta": "plausible partial summary"])
        for wire in [delta, delta + Data("data: [DONE]\n\n".utf8)] {
            do { _ = try await Responses.compact(bytes(wire), raw: raw(), unary: true, context: 128000); XCTFail("Partial summary accepted") } catch {}
        }
        let completed = try event(["type": "response.completed", "response": terminal("authoritative")])
        let response = try await Responses.compact(bytes(delta + completed), raw: raw(), unary: true, context: 128000)
        let value = try JSONValue.decode(await response.body())
        XCTAssertTrue(value["output"].array.last?["content"].array[0]["text"].string.hasSuffix("\nauthoritative") == true)
        XCTAssertFalse(String(decoding: try value.encoded(), as: UTF8.self).contains("plausible partial"))
    }

    func testCompactAcceptsAuthoritativeByteSplitUTF8AndCRLF() async throws {
        let upstream = CodexResponsesUpstream(); defer { upstream.release() }
        var wire = Data([0xef, 0xbb, 0xbf])
        wire.append(try event(["type": "response.completed", "response": terminal("Résumé 模型")], crlf: true))
        for byte in wire { upstream.yield(Data([byte])) }; upstream.finish()
        let response = try await Responses.compact(upstream.response(), raw: raw(), unary: false, context: 128000)
        let value = try JSONValue.decode(await response.body())
        XCTAssertEqual(value["status"], "completed")
        XCTAssertEqual(NativeCodexRouteHistory.decodeCheckpoint(value["output"].array[0]["encrypted_content"]), "Résumé 模型")
    }

    func testCompactRefusesFailedIncompleteToolAndMalformedSummariesWithoutInputDisclosure() async throws {
        var bad: [JSONValue] = []
        for status in ["failed", "incomplete"] { var value = terminal(); value["status"] = .string(status); bad.append(value) }
        for key in ["error", "last_error", "incomplete_details"] { var value = terminal(); value[key] = ["message": "private-user-input"]; bad.append(value) }
        for type in ["function_call", "custom_tool_call", "tool_search_call"] {
            var value = terminal(); value["output"] = .array(value["output"].array + [["type": .string(type)]]); bad.append(value)
        }
        bad += [terminal(" \n\t"), ["status": "completed", "output": []]]
        for value in bad {
            do { _ = try await Responses.compact(json(value), raw: raw(input: [["role": "user", "content": "private-user-input"]]), unary: true, context: 128000); XCTFail("Unsafe summary accepted") }
            catch { XCTAssertEqual(error.localizedDescription, "UniApi compaction failed; history was not replaced") }
        }
        let complete = try event(["type": "response.completed", "response": terminal()])
        let failures: [JSONValue] = [["type": "response.failed"], ["type": "response.incomplete"], ["type": "error", "message": "private-user-input"],
            ["type": "response.output_item.added", "item": ["type": "function_call"]]]
        for eventValue in failures {
            do { _ = try await Responses.compact(bytes(try event(eventValue) + complete), raw: raw(), unary: false, context: 128000); XCTFail("Unsafe stream accepted") }
            catch { XCTAssertFalse(error.localizedDescription.contains("private-user-input")) }
        }
        for wire in [Data("data: invalid\n\n".utf8), Data("data: \"".utf8) + Data([0xff]) + Data("\"\n\n".utf8)] {
            do { _ = try await Responses.compact(bytes(wire), raw: raw(), unary: true, context: 128000); XCTFail("Invalid SSE accepted") } catch {}
        }
        do {
            _ = try await Responses.compact(bytes(Data("private-user-input".utf8), sse: false, status: 503), raw: raw(), unary: true, context: 128000)
            XCTFail("Upstream error accepted")
        } catch { XCTAssertEqual(error.localizedDescription, "UniApi compaction failed; history was not replaced") }
    }

    func testCompactSummaryByteAndUTF16LimitsAreQualified() async throws {
        let cases: [(String, Int)] = [(String(repeating: "a", count: 256 * 1024 + 1), 1_048_576), ("ééé", 4)]
        for (text, context) in cases {
            do { _ = try await Responses.compact(json(terminal(text)), raw: raw(), unary: true, context: context); XCTFail("Oversized summary accepted") } catch {}
        }
        for context in [0, -1] {
            do { _ = try await Responses.compact(json(terminal()), raw: raw(), unary: true, context: context); XCTFail("Invalid context accepted") } catch {}
        }
        let valid = try await Responses.compact(json(terminal("éé")), raw: raw(), unary: true, context: 4)
        XCTAssertEqual(valid.status, 200)
    }

    func testTriggerJSONAndSSEContainExactlyOneCheckpointWithConsistentIDs() async throws {
        let jsonResponse = try await Responses.compact(json(terminal("checkpoint")), raw: raw(), unary: false, context: 128000)
        let value = try JSONValue.decode(await jsonResponse.body()), item = try XCTUnwrap(value["output"].array.first)
        XCTAssertEqual(value["object"], "response"); XCTAssertEqual(value["status"], "completed")
        XCTAssertEqual(value["output"].array.count, 1); XCTAssertEqual(item["type"], "compaction")
        XCTAssertEqual(NativeCodexRouteHistory.decodeCheckpoint(item["encrypted_content"]), "checkpoint")
        XCTAssertTrue(value["id"].string.hasPrefix("uniapi_response_")); XCTAssertTrue(item["id"].string.hasPrefix("uniapi_item_"))
        let response = try await Responses.compact(json(terminal("checkpoint")), raw: raw(stream: true), unary: false, context: 128000)
        let body = try await response.body(), values = try events(body)
        XCTAssertEqual(values.map { $0["type"].string }, ["response.created", "response.output_item.done", "response.completed"])
        XCTAssertEqual(values[1]["item"], values[2]["response"]["output"].array[0])
        XCTAssertEqual(values[0]["response"]["id"], values[2]["response"]["id"])
        XCTAssertEqual(values[2]["response"]["output"].array.count, 1)
        XCTAssertTrue(String(decoding: body, as: UTF8.self).hasSuffix("data: [DONE]\n\n"))
    }

    func testCompactCancellationWaitsForHeldTransportDrain() async throws {
        let upstream = CodexResponsesUpstream(heldDrain: true), finished = CodexResponsesGate()
        defer { upstream.release() }
        let pending = Task { () async throws -> ShimClientResponse in
            defer { finished.signal() }
            return try await Responses.compact(upstream.response(), raw: raw(), unary: true, context: 128000)
        }
        pending.cancel(); await upstream.cancelled.wait()
        for _ in 0..<32 { await Task.yield() }
        XCTAssertFalse(finished.isOpen)
        upstream.drained.signal()
        do { _ = try await pending.value; XCTFail("Cancelled compaction succeeded") } catch { XCTAssertTrue(error is CancellationError) }
    }

    func testCompactCompletedSummaryCannotEscapeCancellationDuringDrain() async throws {
        let upstream = CodexResponsesUpstream(heldDrain: true), finished = CodexResponsesGate()
        defer { upstream.release() }
        let completed = try event(["type": "response.completed", "response": terminal("Résumé 模型")])
        for byte in completed { upstream.yield(Data([byte])) }; upstream.finish()
        let pending = Task { () async throws -> ShimClientResponse in
            defer { finished.signal() }
            return try await Responses.compact(upstream.response(), raw: raw(stream: true), unary: false, context: 128000)
        }
        await upstream.cancelled.wait(); XCTAssertFalse(finished.isOpen)
        pending.cancel(); upstream.drained.signal()
        do { _ = try await pending.value; XCTFail("Cancelled completed summary returned history") } catch { XCTAssertTrue(error is CancellationError) }
    }
}
