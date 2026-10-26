import XCTest
@testable import UniApiCore

final class ShimGatewayTests: XCTestCase {
    private func fixture(_ mode: ShimFixtureTransport.Mode = .normal) throws -> (URL, NativeShimGateway, ShimFixtureTransport) {
        let http = ShimFixtureTransport(mode), (root, runtime, _) = try SwitcherFixture.create(transport: http)
        if mode == .anthropic { try runtime.providers.mutate { var rows = $0["providers"]!.array; rows[0]["proxy"]["format"] = "anthropic"; $0["providers"] = .array(rows) } }
        return (root, NativeShimGateway(providers: runtime.providers, dependencies: .init(transport: http, sleep: { _ in try Task.checkCancellation() }, heartbeatSeconds: 0)), http)
    }
    private func request(_ responses: Bool = false, stream: Bool = true) throws -> ShimClientRequest {
        let body: JSONValue = responses ? ["model": "api-model", "stream": .bool(stream), "input": "fixture input"] : ["model": "api-model", "stream": .bool(stream), "max_tokens": 16, "messages": [["role": "user", "content": "fixture input"]]]
        let bytes = try body.encoded()
        return .init(method: "POST", path: responses ? "/fixture/v1/responses" : "/fixture/v1/messages", headers: ["host": "127.0.0.1:8823", "content-length": String(bytes.count)], body: bytes)
    }
    func testHostOriginBodyAndKeyGuardsNeverReachUpstream() async throws {
        let (root, gateway, http) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        for header in [["host": "evil.example"], ["host": "127.0.0.1:8823", "origin": "https://evil.example"], ["host": "127.0.0.1", "content-length": "-1"]] {
            let reply = try await gateway.handle(.init(method: "POST", path: "/fixture/v1/messages", headers: header, body: Data("{}".utf8)))
            XCTAssertNotEqual(reply.status, 200)
        }
        let calls = await http.captured(); XCTAssertTrue(calls.isEmpty)
        let provider = NativeProviderInfo(["id": "fixture", "api_key": "fixture-key"])
        XCTAssertThrowsError(try ShimSecurity.guardRequest(.init(method: "POST", path: "/", headers: ["host": "127.0.0.1", "x-api-key": "wrong"]), provider: provider, requireKey: true))
        XCTAssertNoThrow(try ShimSecurity.guardRequest(.init(method: "POST", path: "/", headers: ["host": "localhost:8823", "authorization": "Bearer fixture-key"]), provider: provider, requireKey: true))
    }
    func testStrictHTTPDecoderSplitBodyAndSmugglingRefusal() throws {
        let body = Data("{}".utf8), header = "POST /fixture/v1/messages HTTP/1.1\r\nHost: 127.0.0.1:8823\r\nContent-Length: 2\r\n\r\n"
        var decoder = ShimHTTPDecoder(); XCTAssertNil(try decoder.feed(Data(header.utf8))); let parsed = try XCTUnwrap(decoder.feed(body)); XCTAssertEqual(parsed.body, body)
        for text in ["Content-Length: -1", "Content-Length: 0\r\nContent-Length: 0", "Content-Length: 0\r\nTransfer-Encoding: chunked"] {
            var malformed = ShimHTTPDecoder(); XCTAssertThrowsError(try malformed.feed(Data(("POST / HTTP/1.1\r\nHost: localhost\r\n" + text + "\r\n\r\n").utf8)))
        }
        var pipeline = ShimHTTPDecoder(); XCTAssertThrowsError(try pipeline.feed(Data(("GET /healthz HTTP/1.1\r\nHost: localhost\r\n\r\nextra").utf8)))
        for headers in ["Host: evil.example", "Host: localhost\r\nOrigin: https://evil.example"] {
            var hostile = ShimHTTPDecoder()
            let prefix = "POST /fixture/v1/messages HTTP/1.1\r\n" + headers + "\r\nContent-Length: 64000000\r\n\r\n"
            XCTAssertThrowsError(try hostile.feed(Data(prefix.utf8)))
        }
    }
    func testShortRetryLadderAndPermanentVerdictAndEmpty200NoRetry() async throws {
        for (mode, expectedStatus, expectedCalls) in [(ShimFixtureTransport.Mode.rateOnce, 200, 2), (.permanent, 404, 1), (.empty, 200, 1)] {
            let (root, gateway, http) = try fixture(mode); defer { try? FileManager.default.removeItem(at: root) }
            let response = try await gateway.handle(request()), body = try await response.body()
            XCTAssertEqual(response.status, expectedStatus)
            let calls = await http.captured(); XCTAssertEqual(calls.count, expectedCalls)
            if expectedStatus == 200 { var parser = ShimSSEParser(); let frames = try parser.feed(body, final: true); XCTAssertEqual(frames.first?.event, "message_start"); XCTAssertEqual(frames.last?.event, "message_stop") }
        }
    }
    func testTruncationAndInBandErrorCloseBothWiresExplicitly() async throws {
        for mode in [ShimFixtureTransport.Mode.truncated, .partialError] {
            let (root, gateway, _) = try fixture(mode); defer { try? FileManager.default.removeItem(at: root) }
            for responses in [false, true] {
                let response = try await gateway.handle(request(responses)), bytes = try await response.body(); var parser = ShimSSEParser(); let frames = try parser.feed(bytes, final: true)
                XCTAssertTrue(String(decoding: bytes, as: UTF8.self).contains("[uniapi-shim:"))
                XCTAssertEqual(frames.last?.event, responses ? "done" : "message_stop")
                if responses { XCTAssertEqual(frames.dropLast().last?.event, "response.incomplete") }
            }
        }
    }
    func testNativePassthroughDropsLeadingPingAndRepairsThinkingClosure() async throws {
        let (root, gateway, _) = try fixture(.anthropic); defer { try? FileManager.default.removeItem(at: root) }
        let response = try await gateway.handle(request()), bytes = try await response.body(); var parser = ShimSSEParser(); let frames = try parser.feed(bytes, final: true)
        XCTAssertEqual(frames.first?.event, "message_start"); XCTAssertEqual(frames.last?.event, "message_stop")
        let signature = try XCTUnwrap(frames.firstIndex { $0.data["delta"]["type"] == "signature_delta" }); XCTAssertEqual(frames[signature + 1].event, "content_block_stop")
    }
    func testMissingConversationAndReasoningOnlyRejectBeforeProviderCall() async throws {
        let (root, gateway, http) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        for body in [JSONValue.object(["messages": []]), ["input": [["type": "reasoning", "encrypted_content": "opaque"]]]] {
            let response = try await gateway.handle(.init(method: "POST", path: body["messages"].isNull ? "/fixture/v1/responses" : "/fixture/v1/messages", headers: ["host": "localhost"], body: try body.encoded())); XCTAssertEqual(response.status, 400)
        }
        let calls = await http.captured(); XCTAssertTrue(calls.isEmpty)
    }
}
