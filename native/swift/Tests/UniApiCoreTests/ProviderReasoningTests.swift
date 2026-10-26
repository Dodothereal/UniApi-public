import XCTest
@testable import UniApiCore

final class ProviderReasoningTests: XCTestCase {
    private let model = "deepseek/deepseek-v4.1-flash"
    private func provider() -> JSONValue {
        ["id": "fixture", "base_url": "https://api.commandcode.ai/provider/v1", "api_key": "fixture-key",
         "proxy": ["format": "openai", "model": .string(model), "models": [.string(model), "sibling"]],
         "codex": ["base_url": "http://127.0.0.1:8823/fixture/v1", "models": [.string(model), "sibling"],
                   "responses_verified": true, "tools_verified": true, "efforts": []]]
    }
    private func fixture(_ edit: (inout JSONValue) -> Void = { _ in }) async throws -> (URL, NativeRuntime, NativeShimGateway, ShimFixtureTransport) {
        let http = ShimFixtureTransport(), (root, runtime, _) = try SwitcherFixture.create(transport: http)
        await runtime.jobs.suspendForShutdown()
        var row = provider(); edit(&row)
        try runtime.providers.mutate { $0["providers"] = [row] }
        let gateway = NativeShimGateway(providers: runtime.providers, dependencies: .init(transport: http, heartbeatSeconds: 0))
        return (root, runtime, gateway, http)
    }
    private func send(_ gateway: NativeShimGateway, effort: JSONValue? = nil, responses: Bool = true, selected: String? = nil) async throws -> ShimClientResponse {
        var body: JSONValue = responses ? ["model": .string(selected ?? model), "stream": true, "input": "fixture input"]
            : ["model": .string(selected ?? model), "stream": true, "max_tokens": 64, "messages": [["role": "user", "content": "fixture input"]]]
        if let effort { body[responses ? "reasoning" : "output_config"] = ["effort": effort] }
        return try await gateway.handle(.init(method: "POST", path: responses ? "/fixture/v1/responses" : "/fixture/v1/messages", headers: ["host": "localhost"], body: try body.encoded()))
    }
    func testDocumentedFallbackIsBoundToExactModelEndpointAndFormat() {
        let row = provider()
        for base in ["https://api.commandcode.ai/provider/v1", "https://api.commandcode.ai/provider/v1/", "https://api.commandcode.ai:443/provider/v1", "https://api.commandcode.ai:443/provider/v1/"] {
            var changed = row; changed["base_url"] = .string(base)
            XCTAssertEqual(NativeProviderInfo(changed).efforts(for: model), ["high", "low", "max"])
        }
        XCTAssertEqual(NativeProviderInfo(row).efforts(for: "sibling"), [])
        for base in ["https://other.invalid/provider/v1", "http://api.commandcode.ai/provider/v1", "https://api.commandcode.ai:8443/provider/v1", "https://api.commandcode.ai/other", "https://api.commandcode.ai.evil.invalid/provider/v1", "https://api.commandcode.ai/provider/v1?x=1", "https://api.commandcode.ai/provider/%761", "https://api.commandcode.ai/other/../provider/v1"] {
            var changed = row; changed["base_url"] = .string(base)
            XCTAssertEqual(NativeProviderInfo(changed).efforts(for: model), [], base)
        }
        var changed = row; changed["proxy"]["direct_url"] = "https://other.invalid/v1"
        XCTAssertEqual(NativeProviderInfo(changed).efforts(for: model), [])
        changed = row; changed["proxy"]["format"] = "anthropic"
        XCTAssertEqual(NativeProviderInfo(changed).efforts(for: model), [])
    }
    func testModelDeclarationsOverrideProviderAndDocumentedFallbackWithoutLeakingToSiblings() {
        var row = provider(); row["codex"]["efforts"] = ["low", "high"]
        row["codex"]["model_efforts"][model] = ["max", "max", "invalid", 42]
        XCTAssertEqual(NativeProviderInfo(row).efforts(for: model), ["max"])
        XCTAssertEqual(NativeProviderInfo(row).efforts(for: "sibling"), ["low", "high"])
        for override: JSONValue in [[], "high", 4, [:]] {
            row["codex"]["model_efforts"][model] = override
            XCTAssertEqual(NativeProviderInfo(row).efforts(for: model), [])
        }
    }
    func testNativeCatalogAdvertisesOnlyModelEffortsAndExplicitHighDefault() throws {
        let native: JSONValue = ["models": [["slug": "native", "visibility": "list", "supported_in_api": true, "priority": 0, "multi_agent_version": "v1"]]]
        let rows = try NativeCodexRouteCatalog.augment(native, providers: ["providers": [provider()]], choices: ["providerIds": ["fixture"], "workerModels": []])["models"].array
        let deepseek = try XCTUnwrap(rows.first { $0["slug"] == .string(NativeCodexCatalogStore.id(provider: "fixture", model: model)) })
        XCTAssertEqual(deepseek["supported_reasoning_levels"], [["effort": "high"], ["effort": "low"], ["effort": "max"]])
        XCTAssertEqual(deepseek["default_reasoning_level"], "high")
        let sibling = try XCTUnwrap(rows.first { $0["slug"] == "uniapi/fixture/sibling" })
        XCTAssertEqual(sibling["supported_reasoning_levels"], [["effort": "none"]])
        XCTAssertFalse(String(decoding: try JSONValue.array(rows).encoded(), as: UTF8.self).contains("fixture-key"))
    }
    func testActualResponsesGatewayForwardsEachSupportedEffortToOpenAI() async throws {
        let (root, _, gateway, http) = try await fixture(); defer { try? FileManager.default.removeItem(at: root) }
        for effort in ["low", "high", "max"] {
            let response = try await send(gateway, effort: .string(effort)); XCTAssertEqual(response.status, 200); _ = try await response.body()
        }
        let requests = await http.captured(); XCTAssertEqual(requests.count, 3)
        for (request, effort) in zip(requests, ["low", "high", "max"]) {
            XCTAssertEqual(request.url.absoluteString, "https://api.commandcode.ai/provider/v1/chat/completions")
            let payload = try JSONValue.decode(XCTUnwrap(request.body))
            XCTAssertEqual(payload["model"], .string(model)); XCTAssertEqual(payload["reasoning_effort"], .string(effort))
            XCTAssertNil(payload.object["reasoning"]); XCTAssertNil(payload.object["output_config"])
            XCTAssertEqual(payload["messages"].array.last?["content"], "fixture input")
        }
    }
    func testOmittedAndLegacyNonePreserveProviderDefaultWithoutDisablingThinking() async throws {
        let (root, _, gateway, http) = try await fixture(); defer { try? FileManager.default.removeItem(at: root) }
        for effort in [Optional<JSONValue>.none, .some("none")] {
            let response = try await send(gateway, effort: effort); XCTAssertEqual(response.status, 200); _ = try await response.body()
        }
        let requests = await http.captured(); XCTAssertEqual(requests.count, 2)
        let bodies = try requests.map { try JSONValue.decode(XCTUnwrap($0.body)) }
        XCTAssertEqual(bodies[0], bodies[1]); XCTAssertNil(bodies[0].object["reasoning_effort"]); XCTAssertNil(bodies[0].object["thinking"])
    }
    func testUnsupportedOrMalformedEffortsRefuseBeforeTransportAndExplicitNoneCanBeDeclared() async throws {
        let (root, runtime, gateway, http) = try await fixture(); defer { try? FileManager.default.removeItem(at: root) }
        for effort: JSONValue in ["medium", "xhigh", "max ", 40, true, ["high"]] {
            let response = try await send(gateway, effort: effort); XCTAssertEqual(response.status, 400)
        }
        let sibling = try await send(gateway, effort: "high", selected: "sibling"); XCTAssertEqual(sibling.status, 400)
        let refused = await http.captured(); XCTAssertTrue(refused.isEmpty)
        try runtime.providers.mutate { var rows = $0["providers"]!.array; rows[0]["codex"]["model_efforts"][model] = ["none", "high"]; $0["providers"] = .array(rows) }
        let response = try await send(gateway, effort: "none"); XCTAssertEqual(response.status, 200); _ = try await response.body()
        let sent = await http.captured(); XCTAssertEqual(try JSONValue.decode(XCTUnwrap(sent.last?.body))["reasoning_effort"], "none")
    }
    func testClaudeOutputConfigForKnownOpenAIRouteAndUnknownMessagesCompatibility() async throws {
        let (root, _, gateway, http) = try await fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let known = try await send(gateway, effort: "max", responses: false); XCTAssertEqual(known.status, 200); _ = try await known.body()
        let unknown = try await send(gateway, effort: "high", responses: false, selected: "sibling"); XCTAssertEqual(unknown.status, 200); _ = try await unknown.body()
        let sent = await http.captured(); XCTAssertEqual(sent.count, 2)
        XCTAssertEqual(try JSONValue.decode(XCTUnwrap(sent[0].body))["reasoning_effort"], "max")
        XCTAssertNil(try JSONValue.decode(XCTUnwrap(sent[1].body)).object["reasoning_effort"])
    }
    func testResponsesRouteRecheckRetainsDeclaredCapabilities() async throws {
        let (root, runtime, _, http) = try await fixture { row in
            row["codex"]["efforts"] = ["low", "high"]
            row["codex"]["model_efforts"][self.model] = ["max"]
        }; defer { try? FileManager.default.removeItem(at: root) }
        let operations = NativeProviderOperations(store: runtime.providers, dependencies: .init(transport: http))
        _ = try await operations.handle("registerResponses", input: ["id": "fixture", "model": .string(model)])
        let row = try runtime.providers.document()["providers"]!.array[0]
        XCTAssertEqual(row["codex"]["efforts"], ["low", "high"])
        XCTAssertEqual(row["codex"]["model_efforts"][model], ["max"])
        XCTAssertEqual(row["codex"]["verified_model"], .string(model))
    }
}
