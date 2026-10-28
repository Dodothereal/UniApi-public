import Foundation
import XCTest
@testable import UniApiCore

private actor CodexRouterTransport: ShimTransport {
    private var requests: [ShimHTTPRequest] = []
    private let reply: @Sendable (ShimHTTPRequest) async throws -> ShimUpstream
    init(_ reply: @escaping @Sendable (ShimHTTPRequest) async throws -> ShimUpstream = { _ in
        throw NativeFailure("Unexpected transport call in a routing refusal fixture")
    }) { self.reply = reply }
    func open(_ request: ShimHTTPRequest) async throws -> ShimUpstream {
        requests.append(request)
        return try await reply(request)
    }
    func captured() -> [ShimHTTPRequest] { requests }
}

private let codexRouterFixtureToken = String(repeating: "a", count: 64)

private func codexRouterUpstream(_ body: Data, status: Int = 200, headers: [String: String] = ["content-type": "application/json"]) -> ShimUpstream {
    .init(status: status, headers: headers, chunks: AsyncThrowingStream { $0.yield(body); $0.finish() })
}

private final class CodexRouterSignal: @unchecked Sendable {
    private let lock = NSLock()
    private var signalled = false, waiters: [CheckedContinuation<Void, Never>] = []
    var isSignalled: Bool { lock.withLock { signalled } }
    func wait() async {
        await withCheckedContinuation { continuation in
            let ready = lock.withLock { if signalled { return true }; waiters.append(continuation); return false }
            if ready { continuation.resume() }
        }
    }
    func signal() {
        let pending = lock.withLock { () -> [CheckedContinuation<Void, Never>] in
            signalled = true; let pending = waiters; waiters.removeAll(); return pending
        }
        pending.forEach { $0.resume() }
    }
}

// EOF and cancellation are deliberately independent of transport settlement.
private final class CodexRouterHeldUpstream: @unchecked Sendable {
    let cancelled = CodexRouterSignal(), drained = CodexRouterSignal()
    private let chunks: AsyncThrowingStream<Data, Error>
    private let continuation: AsyncThrowingStream<Data, Error>.Continuation
    init() {
        let pair = AsyncThrowingStream<Data, Error>.makeStream()
        chunks = pair.stream; continuation = pair.continuation
    }
    func response(type: String = "text/event-stream") -> ShimUpstream {
        .init(status: 200, headers: ["content-type": type], chunks: chunks,
              cancel: { self.cancel() }, waitForCompletion: { await self.drained.wait() })
    }
    func yield(_ bytes: Data) { continuation.yield(bytes) }
    func finish() { continuation.finish() }
    func cancel() { continuation.finish(throwing: CancellationError()); cancelled.signal() }
    func release() { cancel(); drained.signal() }
}

final class CodexNativeRouterTests: XCTestCase {
    private struct Fixture {
        let root: URL, paths: NativePaths, catalog: NativeCodexCatalogStore, gateway: NativeShimGateway
    }
    private let alias = "uniapi/router%2Ffixture%25/vendor%2Fmodel%3Afree"
    private let rawModel = "vendor/model:free"
    private var nativeHeaders: [String: String] {
        ["host": "localhost:8823", "authorization": "Bearer incoming-native-oauth",
         "content-type": "application/json", "accept": "text/event-stream",
         "chatgpt-account-id": "incoming-account", "openai-organization": "incoming-organization",
         "openai-project": "incoming-project", "openai-beta": "responses=experimental",
         "originator": "codex_cli_rs", "session-id": "incoming-session", "x-codex-turn-id": "incoming-turn",
         "cookie": "session=incoming-cookie", "proxy-authorization": "Bearer incoming-proxy",
         "x-api-key": "incoming-api-key", "x-forwarded-host": "authority.invalid",
         "connection": "keep-alive, x-openai-private", "x-openai-private": "connection-secret"]
    }
    private func provider() -> JSONValue {
        ["id": "router/fixture%", "name": "Router fixture", "base_url": "https://router-provider.invalid/v1",
         "api_key": "private-router-provider-key",
         "proxy": ["format": "openai", "model": "default-do-not-use", "models": ["vendor/model:free", "vendor/model"],
                   "model_context_tokens": ["vendor/model:free": 1048576]],
         "codex": ["base_url": "http://127.0.0.1:8823/router%2Ffixture%25/v1", "models": ["vendor/model:free", "vendor/model"],
                   "responses_verified": true, "tools_verified": true, "efforts": ["low", "high"]]]
    }
    private func fixture(_ transport: any ShimTransport, provider row: JSONValue? = nil, selected: Bool = true) throws -> Fixture {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("codex-router-" + UUID().uuidString)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let paths = NativePaths(root: root, home: root.appendingPathComponent("private-home"))
        try NativeFile.writeAtomic(try JSONValue.object(["requireClientKey": true, "providers": [row ?? provider()]]).encoded(), to: paths.providers)
        let catalog = NativeCodexCatalogStore(bridgeHome: paths.data.appendingPathComponent("codex/native-route"), providersFile: paths.providers)
        try NativeFile.writeAtomic(Data(codexRouterFixtureToken.utf8), to: NativeCodexControlSecret.file(paths, purpose: .routing))
        try catalog.write(selected ? ["providerIds": ["router/fixture%"], "workerModels": [.string(alias)]] : ["providerIds": [], "workerModels": []])
        let gateway = NativeShimGateway(providers: NativeProviderStore(paths: paths),
                                       dependencies: .init(transport: transport, retryBackoff: [], heartbeatSeconds: 0), paths: paths)
        return Fixture(root: root, paths: paths, catalog: catalog, gateway: gateway)
    }
    private func request(_ path: String = "/_uniapi/codex/v1/responses", method: String = "POST", body: Data = Data(), headers: [String: String]? = nil) -> ShimClientRequest {
        var fields = headers ?? nativeHeaders; fields["content-length"] = String(body.count)
        return .init(method: method, path: path.replacingOccurrences(of: "/_uniapi/codex/v1", with: "/_uniapi/codex/" + codexRouterFixtureToken + "/v1"), headers: fields, body: body)
    }
    private func input(_ model: String, stream: Bool = false) throws -> Data {
        try JSONValue.object(["model": .string(model), "stream": .bool(stream), "input": [["role": "user", "content": "private fixture prompt"]]]).encoded()
    }
    private func nativeCatalog() -> JSONValue {
        ["catalog_revision": "from-upstream", "models": [
            ["slug": "native-anchor", "display_name": "Native anchor", "priority": 0, "visibility": "list",
             "supported_in_api": true, "multi_agent_version": "v2", "supported_reasoning_levels": [["effort": "high"]],
             "model_messages": ["native_only": true], "native_extra": ["keep": 42]],
            ["slug": "chatgpt-web/high", "visibility": "list"], ["slug": "uniapi/stale/model", "visibility": "list"]]]
    }
    private func providerReply() throws -> Data {
        try JSONValue.object(["id": "provider-reply", "choices": [["message": ["role": "assistant", "content": "provider answer"], "finish_reason": "stop"]],
                              "usage": ["prompt_tokens": 2, "completion_tokens": 3]]).encoded()
    }
    private func eventually(_ condition: @escaping @Sendable () -> Bool) async throws {
        let deadline = ProcessInfo.processInfo.systemUptime + 2
        while !condition() {
            guard ProcessInfo.processInfo.systemUptime < deadline else { throw NativeFailure("Private router fixture did not reach its expected cleanup phase") }
            try await Task.sleep(nanoseconds: 1_000_000)
        }
    }

    func testModelsUsesFixedNativeHostAuthAndExactQueryThenAugmentsUpstreamCatalog() async throws {
        let bytes = try nativeCatalog().encoded(), transport = CodexRouterTransport { _ in codexRouterUpstream(bytes) }
        let f = try fixture(transport)
        let query = "client_version=0.134.0&cursor=a%2Fb%2Bc&cursor=second&empty="
        let response = try await f.gateway.handle(request("/_uniapi/codex/v1/models?" + query, method: "GET"))
        XCTAssertEqual(response.status, 200)
        let value = try JSONValue.decode(await response.body()), calls = await transport.captured()
        XCTAssertEqual(calls.count, 1)
        let outbound = try XCTUnwrap(calls.first)
        XCTAssertEqual(outbound.url.absoluteString, "https://chatgpt.com/backend-api/codex/models?" + query)
        XCTAssertEqual(outbound.method, "GET"); XCTAssertNil(outbound.body)
        XCTAssertTrue(outbound.bypassSystemProxy)
        XCTAssertEqual(outbound.headers["authorization"], "Bearer incoming-native-oauth")
        XCTAssertEqual(outbound.headers["chatgpt-account-id"], "incoming-account")
        XCTAssertEqual(outbound.headers["x-codex-turn-id"], "incoming-turn")
        for key in ["host", "content-length", "cookie", "proxy-authorization", "x-api-key", "x-forwarded-host", "connection", "x-openai-private"] {
            XCTAssertNil(outbound.headers[key], "Native request leaked \(key)")
        }
        XCTAssertEqual(value["catalog_revision"], "from-upstream")
        XCTAssertEqual(value["models"].array.map { $0["slug"].string }, ["native-anchor", alias, "uniapi/router%2Ffixture%25/vendor%2Fmodel"])
        let native = try XCTUnwrap(value["models"].array.first), free = try XCTUnwrap(value["models"].array.first { $0["slug"] == .string(alias) })
        XCTAssertEqual(native["native_extra"], ["keep": 42]); XCTAssertEqual(native["model_messages"], ["native_only": true])
        XCTAssertEqual(free["context_window"], 1048576); XCTAssertEqual(free["max_context_window"], 1048576)
        XCTAssertEqual(free["auto_compact_token_limit"], 943718); XCTAssertEqual(free["effective_context_window_percent"], 90)
        XCTAssertEqual(free["multi_agent_version"], "v1"); XCTAssertEqual(free["model_messages"], .null)
        XCTAssertEqual(free["supported_reasoning_levels"], [["effort": "low", "description": "low"], ["effort": "high", "description": "high"]])
        XCTAssertEqual(value["models"].array.last?["context_window"], 128000)
        let published = String(decoding: try value.encoded(), as: UTF8.self)
        for secret in ["private-router-provider-key", "incoming-native-oauth", "incoming-account", "incoming-cookie"] { XCTAssertFalse(published.contains(secret)) }
        XCTAssertEqual(f.gateway.activeRequests, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: f.paths.home.appendingPathComponent(".codex").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: f.paths.home.appendingPathComponent(".codex-chatgpt-web").path))
    }
    func testPrivatePathCapabilityAndExactBrowserPerimeterRefuseBeforeTransport() async throws {
        let transport = CodexRouterTransport(), f = try fixture(transport)
        let bytes = try input(alias)
        var origin = nativeHeaders; origin["origin"] = "http://127.0.0.1:9999"
        var lookalike = nativeHeaders; lookalike["origin"] = "http://localhost:8823/path"
        var site = nativeHeaders; site["sec-fetch-site"] = "same-site"
        var cross = nativeHeaders; cross["sec-fetch-site"] = "cross-site"
        var opaque = nativeHeaders; opaque["sec-fetch-mode"] = "no-cors"
        for fields in [origin, lookalike, site, cross, opaque] {
            let reply = try await f.gateway.handle(request(body: bytes, headers: fields))
            XCTAssertEqual(reply.status, 400); _ = try await reply.body()
        }
        for token in ["", "unknown", String(repeating: "b", count: 64)] {
            let path = "/_uniapi/codex/" + token + "/v1/responses"
            let reply = try await f.gateway.handle(.init(method: "POST", path: path, headers: nativeHeaders, body: bytes))
            XCTAssertNotEqual(reply.status, 200); _ = try await reply.body()
        }
        let calls = await transport.captured(); XCTAssertTrue(calls.isEmpty)
        let encoded = try NativeCodexRouteStore(paths: f.paths).status().encoded()
        XCTAssertFalse(String(decoding: encoded, as: UTF8.self).contains(codexRouterFixtureToken))
    }

    func testModelsDerivesClientVersionOnlyFromRecognizedCodexAgent() async throws {
        let bytes = try nativeCatalog().encoded(), transport = CodexRouterTransport { _ in codexRouterUpstream(bytes) }
        let f = try fixture(transport)
        for (agent, expected) in [("codex_cli_rs/0.134.0 (Mac OS)", "0.134.0"), ("unrecognized/9.9.9", "")] {
            var headers = nativeHeaders; headers["user-agent"] = agent
            let response = try await f.gateway.handle(request("/_uniapi/codex/v1/models?cursor=retain", method: "GET", headers: headers))
            XCTAssertEqual(response.status, 200); _ = try await response.body()
            let calls = await transport.captured(), call = try XCTUnwrap(calls.last)
            let query = URLComponents(url: call.url, resolvingAgainstBaseURL: false)?.queryItems ?? []
            XCTAssertEqual(query.first { $0.name == "cursor" }?.value, "retain")
            XCTAssertEqual(query.filter { $0.name == "client_version" }.compactMap(\.value), expected.isEmpty ? [] : [expected])
        }
    }

    func testAPIResponsesDecodeAliasAndUseOnlyProviderCredentialsIncludingWithoutIncomingOAuth() async throws {
        let bytes = try providerReply(), transport = CodexRouterTransport { _ in codexRouterUpstream(bytes) }
        let f = try fixture(transport)
        for headers in [nativeHeaders, ["host": "localhost", "content-type": "application/json"]] {
            let response = try await f.gateway.handle(request(body: input(alias), headers: headers))
            XCTAssertEqual(response.status, 200)
            let value = try JSONValue.decode(await response.body())
            XCTAssertTrue(value["id"].string.hasPrefix("uniapi_response_"))
            XCTAssertTrue(String(decoding: try value.encoded(), as: UTF8.self).contains("provider answer"))
        }
        let calls = await transport.captured(); XCTAssertEqual(calls.count, 2)
        for outbound in calls {
            XCTAssertEqual(outbound.url.absoluteString, "https://router-provider.invalid/v1/chat/completions")
            XCTAssertEqual(outbound.method, "POST")
            let body = try JSONValue.decode(XCTUnwrap(outbound.body))
            XCTAssertEqual(body["model"], .string(rawModel)); XCTAssertEqual(body["messages"].array.first?["content"], "private fixture prompt")
            let headers = outbound.headers.reduce(into: [String: String]()) { $0[$1.key.lowercased()] = $1.value }
            XCTAssertEqual(headers["authorization"], "Bearer private-router-provider-key")
            XCTAssertEqual(Set(headers.keys), Set(["content-type", "user-agent", "authorization", "accept"]))
            let wire = outbound.url.absoluteString + outbound.headers.description + String(decoding: try XCTUnwrap(outbound.body), as: UTF8.self)
            for secret in ["incoming-native-oauth", "incoming-cookie", "incoming-account", "incoming-organization", "incoming-project", "incoming-proxy", "incoming-api-key", "incoming-session", "incoming-turn", "connection-secret"] {
                XCTAssertFalse(wire.contains(secret), "Provider request leaked \(secret)")
            }
        }
        XCTAssertEqual(f.gateway.activeRequests, 0)
    }

    func testNativeHistoryRetainsOriginalBytesAndAuthorityAcrossNativeEndpoints() async throws {
        let reply = Data("{\"opaque_native_reply\":true}".utf8), transport = CodexRouterTransport { _ in codexRouterUpstream(reply) }
        let f = try fixture(transport)
        let original = Data("""
         { "previous_response_id" : "resp_native", "model" : "native-anchor", "input" : [
           {"type":"reasoning","id":"rs_native","encrypted_content":"native-ciphertext"},
           {"type":"compaction","encrypted_content":"opaque-native-checkpoint"},
           {"type":"item_reference","id":"native-item"},
           {"type":"function_call_output","call_id":"native-call","output":[{"type":"encrypted_content","data":"native-output"}]}
         ], "store" : false }

        """.utf8)
        for endpoint in ["responses", "responses/compact", "alpha/search"] {
            let response = try await f.gateway.handle(request("/_uniapi/codex/v1/" + endpoint + "?cursor=native%2Fcursor", body: original))
            XCTAssertEqual(response.status, 200)
            let received = try await response.body(); XCTAssertEqual(received, reply)
            let calls = await transport.captured(), outbound = try XCTUnwrap(calls.last)
            XCTAssertEqual(outbound.url.absoluteString, "https://chatgpt.com/backend-api/codex/" + endpoint + "?cursor=native%2Fcursor")
            XCTAssertEqual(outbound.method, "POST"); XCTAssertEqual(outbound.body, original)
            XCTAssertEqual(outbound.headers["authorization"], "Bearer incoming-native-oauth")
            XCTAssertEqual(outbound.headers["chatgpt-account-id"], "incoming-account")
            XCTAssertNil(outbound.headers["content-length"]); XCTAssertNil(outbound.headers["cookie"])
        }
        let calls = await transport.captured(); XCTAssertEqual(calls.count, 3)
        XCTAssertEqual(f.gateway.activeRequests, 0)
    }

    func testUnchangedZstdNativeHistoryForwardsEncodedBytesAndEncoding() async throws {
        let reply = Data("{}".utf8), transport = CodexRouterTransport { _ in codexRouterUpstream(reply) }, f = try fixture(transport)
        let plain = Data(" {\"model\":\"native\",\"previous_response_id\":\"resp_native\",\"input\":[{\"type\":\"reasoning\",\"encrypted_content\":\"native-ciphertext\"},{\"type\":\"item_reference\",\"id\":\"native-item\"}]}\n".utf8)
        // A single-segment Zstandard frame with a raw final block. This fixture
        // does not invoke production decoding to manufacture its expected bytes.
        guard plain.count < 256 else { throw NativeFailure("Raw zstd fixture exceeds its one-byte content size") }
        let block = (plain.count << 3) | 1
        let encoded = Data([0x28, 0xb5, 0x2f, 0xfd, 0x20, UInt8(plain.count), UInt8(block & 255), UInt8((block >> 8) & 255), UInt8((block >> 16) & 255)]) + plain
        var headers = nativeHeaders; headers["content-encoding"] = "zstd"
        let response = try await f.gateway.handle(request(body: encoded, headers: headers))
        XCTAssertEqual(response.status, 200); _ = try await response.body()
        let calls = await transport.captured(), outbound = try XCTUnwrap(calls.first)
        XCTAssertEqual(calls.count, 1); XCTAssertEqual(outbound.body, encoded)
        XCTAssertEqual(outbound.headers["content-encoding"], "zstd")
        XCTAssertEqual(outbound.url.absoluteString, "https://chatgpt.com/backend-api/codex/responses")
    }

    func testMalformedUnknownAndBrowserAliasesFailWithoutAnyNetworkFallback() async throws {
        let transport = CodexRouterTransport(), f = try fixture(transport)
        for model in ["uniapi/", "uniapi//model", "uniapi/router%2ffixture%25/vendor%2Fmodel%3Afree", "uniapi/router%2Ffixture%25/%ZZ",
                      "uniapi/router%2Ffixture%25/missing", "uniapi/unknown/vendor%2Fmodel%3Afree", "chatgpt-web/high"] {
            let response = try await f.gateway.handle(request(body: input(model)))
            XCTAssertEqual(response.status, 400, "Unexpected routing for \(model)"); _ = try await response.body()
        }
        let calls = await transport.captured(); XCTAssertTrue(calls.isEmpty)
        XCTAssertEqual(f.gateway.activeRequests, 0)
    }

    func testDisabledUnverifiedAndUnselectedProviderAliasesFailBeforeTransport() async throws {
        var disabled = provider(); disabled["disabled"] = true
        var codexDisabled = provider(); codexDisabled["codex"]["enabled"] = false
        var unverified = provider(); unverified["codex"]["tools_verified"] = false
        var foreign = provider(); foreign["codex"]["base_url"] = "https://authority.invalid/v1"
        for row in [disabled, codexDisabled, unverified, foreign] {
            let transport = CodexRouterTransport(), f = try fixture(transport, provider: row)
            let response = try await f.gateway.handle(request(body: input(alias)))
            XCTAssertEqual(response.status, 400); _ = try await response.body()
            let calls = await transport.captured(); XCTAssertTrue(calls.isEmpty)
        }
        let transport = CodexRouterTransport(), f = try fixture(transport, selected: false)
        let response = try await f.gateway.handle(request(body: input(alias)))
        XCTAssertEqual(response.status, 400); _ = try await response.body()
        let calls = await transport.captured(); XCTAssertTrue(calls.isEmpty)
    }

    func testProviderKeyAndCatalogMembershipAreReadAgainForEveryRequest() async throws {
        let bytes = try providerReply(), transport = CodexRouterTransport { _ in codexRouterUpstream(bytes) }, f = try fixture(transport)
        let first = try await f.gateway.handle(request(body: input(alias)))
        XCTAssertEqual(first.status, 200); _ = try await first.body()
        var changed = provider(); changed["api_key"] = "replacement-router-key"
        try NativeFile.writeAtomic(try JSONValue.object(["requireClientKey": true, "providers": [changed]]).encoded(), to: f.paths.providers)
        let second = try await f.gateway.handle(request(body: input(alias)))
        XCTAssertEqual(second.status, 200); _ = try await second.body()
        try f.catalog.write(["providerIds": [], "workerModels": []])
        let refused = try await f.gateway.handle(request(body: input(alias)))
        XCTAssertEqual(refused.status, 400); _ = try await refused.body()
        let calls = await transport.captured(); XCTAssertEqual(calls.count, 2)
        XCTAssertEqual(calls.first?.headers["Authorization"], "Bearer private-router-provider-key")
        XCTAssertEqual(calls.last?.headers["Authorization"], "Bearer replacement-router-key")
    }

    func testMissingNativeBearerReturns401WithoutOpeningTransport() async throws {
        let transport = CodexRouterTransport(), f = try fixture(transport)
        for authorization in ["", "Bearer ", "Basic fixture"] {
            var headers = nativeHeaders
            if authorization.isEmpty { headers.removeValue(forKey: "authorization") } else { headers["authorization"] = authorization }
            for endpoint in ["models", "responses", "responses/compact", "alpha/search"] {
                let response = try await f.gateway.handle(request("/_uniapi/codex/v1/" + endpoint, method: endpoint == "models" ? "GET" : "POST", body: endpoint == "models" ? Data() : input("native-anchor"), headers: headers))
                XCTAssertEqual(response.status, 401, endpoint); _ = try await response.body()
            }
        }
        let calls = await transport.captured(); XCTAssertTrue(calls.isEmpty)
    }

    func testEncodedAbsoluteAndFragmentTargetsCannotBecomeRoutingAuthority() async throws {
        let transport = CodexRouterTransport(), f = try fixture(transport)
        let targets = [
            "/_uniapi/codex/v1/%72esponses", "/_uniapi/codex/v1/responses%2Fcompact",
            "/_uniapi/codex/v1/responses/..%2Fmodels", "/_uniapi/codex/v1/responses/%2F%2Fauthority.invalid",
            "/_uniapi/codex/v1/responses%3Furl=https%3A%2F%2Fauthority.invalid",
            "/_uniapi/codex/v1/responses?url=https://authority.invalid#fragment",
            "https://authority.invalid/_uniapi/codex/v1/responses", "//authority.invalid/_uniapi/codex/v1/responses"]
        for target in targets {
            let response = try await f.gateway.handle(request(target, body: input("native-anchor")))
            XCTAssertTrue((400..<500).contains(response.status), target); _ = try await response.body()
        }
        let calls = await transport.captured(); XCTAssertTrue(calls.isEmpty)
    }

    func testQueryURLRemainsDataOnFixedNativeHostAndCannotSelectProvider() async throws {
        let bytes = Data("{}".utf8), transport = CodexRouterTransport { _ in codexRouterUpstream(bytes) }, f = try fixture(transport)
        let query = "url=https%3A%2F%2Fauthority.invalid%2Fresponses&model=uniapi%2Funknown%2Fmodel&host=authority.invalid"
        let response = try await f.gateway.handle(request("/_uniapi/codex/v1/responses?" + query, body: input("native-anchor")))
        XCTAssertEqual(response.status, 200); _ = try await response.body()
        let calls = await transport.captured(); XCTAssertEqual(calls.count, 1)
        XCTAssertEqual(calls.first?.url.absoluteString, "https://chatgpt.com/backend-api/codex/responses?" + query)
    }

    func testInvalidEncodingAndCrossBackendHistoryFailBeforeAnyTransport() async throws {
        let transport = CodexRouterTransport(), f = try fixture(transport)
        var gzip = nativeHeaders; gzip["content-encoding"] = "gzip"
        var zstd = nativeHeaders; zstd["content-encoding"] = "zstd"
        let badBodies: [JSONValue] = [
            ["model": .string(alias), "input": "complete text", "previous_response_id": "native-response"],
            ["model": .string(alias), "input": [["type": "item_reference", "id": "native-item"]]],
            ["model": .string(alias), "input": [["type": "agent_message", "content": [["type": "encrypted_content", "data": "opaque"]]]]],
            ["model": "native-anchor", "input": "complete text", "previous_response_id": "uniapi_response_foreign"]]
        var inputs = try badBodies.map { request(body: try $0.encoded()) }
        inputs.append(request(body: try input("native-anchor"), headers: gzip))
        inputs.append(request(body: Data([0x28, 0xb5, 0x2f]), headers: zstd))
        inputs.append(request(body: Data("[]".utf8)))
        for incoming in inputs {
            let response = try await f.gateway.handle(incoming)
            XCTAssertEqual(response.status, 400); _ = try await response.body()
        }
        let calls = await transport.captured(); XCTAssertTrue(calls.isEmpty)
    }

    func testNativeErrorsAndRedirectsRelayOnceWithOnlyAllowedResponseHeaders() async throws {
        let body = Data("opaque upstream status".utf8)
        for status in [302, 401, 429, 503] {
            let transport = CodexRouterTransport { _ in
                codexRouterUpstream(body, status: status, headers: ["content-type": "text/plain", "retry-after": "5", "x-request-id": "request-fixture",
                    "x-codex-turn-id": "turn-fixture", "x-ratelimit-remaining": "0", "set-cookie": "private-cookie",
                    "location": "https://authority.invalid/redirect", "authorization": "Bearer private-response-token", "x-codex-invalid": "line\nbreak"])
            }
            let f = try fixture(transport)
            let response = try await f.gateway.handle(request(body: input("native-anchor")))
            XCTAssertEqual(response.status, status)
            XCTAssertEqual(response.headers, ["content-type": "text/plain", "retry-after": "5", "x-request-id": "request-fixture", "x-codex-turn-id": "turn-fixture", "x-ratelimit-remaining": "0"])
            let bytes = try await response.body(); XCTAssertEqual(bytes, body)
            let calls = await transport.captured(); XCTAssertEqual(calls.count, 1)
            XCTAssertEqual(calls.first?.url.host, "chatgpt.com")
            XCTAssertEqual(f.gateway.activeRequests, 0)
        }
    }

    func testNativeStreamCancellationKeepsRequestActiveUntilTransportSettles() async throws {
        let upstream = CodexRouterHeldUpstream(), transport = CodexRouterTransport { _ in upstream.response() }
        let f = try fixture(transport); defer { upstream.release() }
        let response = try await f.gateway.handle(request(body: input("native-anchor", stream: true)))
        XCTAssertEqual(response.status, 200); XCTAssertEqual(f.gateway.activeRequests, 1)
        response.cancel(); response.cancel()
        try await eventually { upstream.cancelled.isSignalled }
        XCTAssertEqual(f.gateway.activeRequests, 1)
        upstream.drained.signal(); await response.waitForCompletion()
        XCTAssertEqual(f.gateway.activeRequests, 0)
    }

    func testProviderStreamCancellationDrainsTranslationAndProvenanceWrapper() async throws {
        let upstream = CodexRouterHeldUpstream(), transport = CodexRouterTransport { _ in upstream.response() }
        let f = try fixture(transport); defer { upstream.release() }
        let response = try await f.gateway.handle(request(body: input(alias, stream: true)))
        XCTAssertEqual(response.status, 200); XCTAssertEqual(f.gateway.activeRequests, 1)
        response.cancel(); response.cancel()
        try await eventually { upstream.cancelled.isSignalled }
        XCTAssertEqual(f.gateway.activeRequests, 1)
        upstream.drained.signal(); await response.waitForCompletion()
        XCTAssertEqual(f.gateway.activeRequests, 0)
        let calls = await transport.captured(); XCTAssertEqual(calls.count, 1)
        XCTAssertEqual(calls.first?.url.host, "router-provider.invalid")
    }

    func testNativeCompletedProducerKeepsUnreadClientCountedUntilConsumption() async throws {
        let upstream = CodexRouterHeldUpstream(), transport = CodexRouterTransport { _ in upstream.response() }
        let f = try fixture(transport); defer { upstream.release() }
        let bytes = Data("data: {\"type\":\"response.completed\"}\n\ndata: [DONE]\n\n".utf8)
        let response = try await f.gateway.handle(request(body: input("native-anchor", stream: true)))
        upstream.yield(bytes); upstream.finish(); upstream.drained.signal(); await response.waitForCompletion()
        XCTAssertEqual(f.gateway.activeRequests, 1)
        let received = try await response.body(); XCTAssertEqual(received, bytes)
        XCTAssertEqual(f.gateway.activeRequests, 0)
        response.cancel(); response.cancel(); XCTAssertEqual(f.gateway.activeRequests, 0)
    }

    func testModelsWaitsForUpstreamSettlementBeforeReturningAugmentedResponse() async throws {
        let upstream = CodexRouterHeldUpstream(), transport = CodexRouterTransport { _ in upstream.response(type: "application/json") }
        let f = try fixture(transport), returned = CodexRouterSignal(); defer { upstream.release() }
        upstream.yield(try nativeCatalog().encoded()); upstream.finish()
        let incoming = request("/_uniapi/codex/v1/models", method: "GET")
        let pending = Task { let response = try await f.gateway.handle(incoming); returned.signal(); return response }
        try await eventually { upstream.cancelled.isSignalled }
        XCTAssertFalse(returned.isSignalled); XCTAssertEqual(f.gateway.activeRequests, 1)
        upstream.drained.signal()
        let response = try await pending.value
        XCTAssertEqual(response.status, 200); XCTAssertEqual(f.gateway.activeRequests, 1)
        _ = try await response.body(); XCTAssertEqual(f.gateway.activeRequests, 0)
    }

    func testNativeResetIsToleratedOnlyAfterExactTerminatorAcrossChunkBoundaries() async throws {
        let cases: [([String], Bool)] = [
            (["data: [DO", "NE]\r\n\n"], true), (["data: [DONE]"], true),
            (["data: [DONE]", " trailing-text\n\n"], false),
            (["data: {\"text\":\"data: [DONE]\"}\n\n"], false),
            (["data: [DON"], false), (["data: {\"type\":\"response.completed\"}\n\n"], false)]
        for (parts, succeeds) in cases {
            let transport = CodexRouterTransport { _ in
                .init(status: 200, headers: ["content-type": "text/event-stream"], chunks: AsyncThrowingStream { continuation in
                    for part in parts { continuation.yield(Data(part.utf8)) }
                    continuation.finish(throwing: NativeFailure("Synthetic native connection reset"))
                })
            }
            let f = try fixture(transport), response = try await f.gateway.handle(request(body: input("native-anchor", stream: true)))
            XCTAssertEqual(response.status, 200)
            do {
                let bytes = try await response.body()
                XCTAssertTrue(succeeds, "Accepted reset after \(parts)")
                XCTAssertEqual(bytes, Data(parts.joined().utf8))
            } catch { XCTAssertFalse(succeeds, "Rejected completed terminator: \(error)") }
            await response.waitForCompletion(); XCTAssertEqual(f.gateway.activeRequests, 0)
        }
    }
}
