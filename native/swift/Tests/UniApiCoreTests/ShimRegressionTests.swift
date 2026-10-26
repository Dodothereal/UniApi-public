import XCTest
@testable import UniApiCore

private actor ShimRegressionTransport: ShimTransport {
    var requests: [ShimHTTPRequest] = []
    func captured() -> [ShimHTTPRequest] { requests }
    func open(_ request: ShimHTTPRequest) async throws -> ShimUpstream {
        requests.append(request)
        let body = try JSONValue.decode(request.body ?? Data())
        let data: Data
        if body["stream"] == true && request.headers["Accept"] == "text/event-stream" {
            data = Data("data: {\"choices\":[{\"delta\":{\"content\":\"negotiated answer\"},\"finish_reason\":\"stop\"}]}\n\ndata: [DONE]\n\n".utf8)
        } else { data = try JSONValue.object(["choices": [["message": ["content": "JSON answer"], "finish_reason": "stop"]]]).encoded() }
        return .init(status: 200, chunks: AsyncThrowingStream { $0.yield(data); $0.finish() })
    }
}
final class ShimRegressionTests: XCTestCase {
    func testRealIDWinsAliasRegardlessOfDocumentOrderAndRevocationCannotFallThrough() async throws {
        let (root, runtime, _) = try SwitcherFixture.create(); defer { try? FileManager.default.removeItem(at: root) }
        var first = JSONValue.object(try runtime.providers.list()[0]); first["proxy"]["aliases"] = ["real", "legacy"]
        var second = first; second["id"] = "real"; second["api_key"] = "second-fixture-key"; second["base_url"] = "https://second.invalid"; second["proxy"]["aliases"] = []
        let http = ShimRegressionTransport(), gateway = NativeShimGateway(providers: runtime.providers, dependencies: .init(transport: http, heartbeatSeconds: 0))
        let body: JSONValue = ["stream": false, "messages": [["role": "user", "content": "fixture"]]]
        func request(_ id: String) throws -> ShimClientRequest { .init(method: "POST", path: "/" + id + "/v1/messages", headers: ["host": "localhost"], body: try body.encoded()) }
        for rows in [[first, second], [second, first]] {
            try runtime.providers.mutate { $0["providers"] = .array(rows) }
            let response = try await gateway.handle(request("real")); XCTAssertEqual(response.status, 200)
            let calls = await http.captured(), call = try XCTUnwrap(calls.last)
            XCTAssertEqual(call.url.host, "second.invalid"); XCTAssertEqual(call.headers["Authorization"], "Bearer second-fixture-key")
            XCTAssertEqual(NativeClaudeSettingsStore.current("http://localhost:8823/real", providers: rows.map(NativeProviderInfo.init)), "real")
        }
        let alias = try await gateway.handle(request("legacy")); XCTAssertEqual(alias.status, 200)
        let calls = await http.captured(); XCTAssertEqual(calls.last?.url.host, "fixture.invalid")
        second["disabled"] = true; try runtime.providers.mutate { $0["providers"] = [first, second] }
        let before = await http.captured().count, revoked = try await gateway.handle(request("real")), after = await http.captured().count
        XCTAssertEqual(revoked.status, 404); XCTAssertEqual(before, after)
    }
    func testBothStreamingClientWiresNegotiateSSEAndBufferedRequestsStayJSON() async throws {
        let (root, runtime, _) = try SwitcherFixture.create(); defer { try? FileManager.default.removeItem(at: root) }
        let http = ShimRegressionTransport(), gateway = NativeShimGateway(providers: runtime.providers, dependencies: .init(transport: http, heartbeatSeconds: 0))
        for responses in [false, true] {
            for stream in [false, true] {
                let body: JSONValue = responses ? ["stream": .bool(stream), "input": "fixture"] : ["stream": .bool(stream), "messages": [["role": "user", "content": "fixture"]]]
                let response = try await gateway.handle(.init(method: "POST", path: responses ? "/fixture/v1/responses" : "/fixture/v1/messages", headers: ["host": "localhost"], body: try body.encoded()))
                let output = String(decoding: try await response.body(), as: UTF8.self), calls = await http.captured()
                XCTAssertEqual(calls.last?.headers["Accept"], stream ? "text/event-stream" : "*/*")
                XCTAssertTrue(output.contains(stream ? "negotiated answer" : "JSON answer")); XCTAssertFalse(output.contains("Upstream ended without a finish reason"))
            }
        }
    }
    func testCustomToolsUnwrapOnlyStringInputAndPreserveOtherJSON() throws {
        let map = try ShimToolMap(["tools": [["type": "custom", "name": "exec"]]])
        for (raw, expected) in [
            ("{\"input\":{\"cmd\":\"fixture\"}}", "{\"input\":{\"cmd\":\"fixture\"}}"),
            ("{\"input\":[1,2]}", "{\"input\":[1,2]}"), ("{\"input\":42}", "{\"input\":42}"),
            ("{\"input\":true}", "{\"input\":true}"), ("{\"input\":null}", "{\"input\":null}"),
            ("{\"input\":\"echo fixture\"}", "echo fixture"), ("{\"input\":\"\"}", ""), ("{}", "{}")
        ] {
            var stream = ShimResponsesStream(model: "fixture", tools: map)
            _ = stream.feedOpenAI(["choices": [["delta": ["tool_calls": [["index": 0, "id": "call", "function": ["name": "exec", "arguments": .string(raw)]]]], "finish_reason": "tool_calls"]]])
            _ = stream.finish(); XCTAssertEqual(stream.items.first?["input"], .string(expected))
            let message: JSONValue = ["content": [["type": "tool_use", "id": "call", "name": "exec", "input": try JSONValue.decode(Data(raw.utf8))]], "stop_reason": "tool_use"]
            let nonstream = try ShimResponsesStream.nonstream(message, model: "fixture", tools: map)
            if expected == "echo fixture" || expected.isEmpty { XCTAssertEqual(nonstream["output"].array.first?["input"], .string(expected)) }
            else { XCTAssertEqual(try JSONValue.decode(Data(nonstream["output"].array[0]["input"].string.utf8)), try JSONValue.decode(Data(raw.utf8))) }
        }
    }
}
