import XCTest
@testable import UniApiCore

final class ProviderTests: XCTestCase {
    func testKeylessAddPreservesExistingProvidersAndInvalidKeysNeverProbe() async throws {
        let http = ShimFixtureTransport(), (root, runtime, _) = try SwitcherFixture.create(transport: http); defer { try? FileManager.default.removeItem(at: root) }
        let before = try runtime.providers.list(), operations = NativeProviderOperations(store: runtime.providers, dependencies: .init(transport: http, heartbeatSeconds: 0))
        let added = try await operations.handle("add", input: ["name": "Keyless local", "url": "http://fixture.invalid/v1", "key": ""])
        let rows = try runtime.providers.list(), row = try XCTUnwrap(rows.first { $0["id"] == added["id"] })
        XCTAssertEqual(row["api_key"], ""); XCTAssertEqual(rows.first { $0["id"] == "fixture" }, before.first)
        let requests = await http.captured(); XCTAssertFalse(requests.isEmpty)
        for key: JSONValue in [.null, "bad\nheader", .string(String(repeating: "x", count: 16385))] {
            do { _ = try await operations.handle("add", input: ["name": "Invalid", "url": "http://fixture.invalid/v1", "key": key]); XCTFail("Invalid key admitted") } catch {}
        }
        let afterRequests = await http.captured(); XCTAssertEqual(afterRequests.count, requests.count); XCTAssertEqual(try runtime.providers.list(), rows)
    }
    func testVendorErrorShapeOutranksStatusAndOpenAIFields() {
        let body: JSONValue = ["type": "error", "error": ["code": "1113", "type": "rate_limit_error", "message": "Insufficient balance"]]
        XCTAssertEqual(NativeProviderDetection.classify(status: 404, body: body).format, "anthropic")
        XCTAssertEqual(NativeProviderDetection.classify(status: 429, body: ["type": "error", "error": [:]]).format, "anthropic")
        XCTAssertEqual(NativeProviderDetection.classify(status: 404, body: ["error": ["code": "not_found"]]).format, "openai")
        XCTAssertFalse(NativeProviderDetection.chatModel("gpt-image", metadata: ["tags": "Text"]))
        XCTAssertFalse(NativeProviderDetection.chatModel("audio-tts", metadata: ["tags": ["Text"]]))
        XCTAssertTrue(NativeProviderDetection.chatModel("qwen-vision", metadata: [:]))
    }
    func testAdoptRefreshModelRemoveAndCredentialReference() async throws {
        let http = ShimFixtureTransport(.vendorAnthropic), (root, runtime, _) = try SwitcherFixture.create(transport: http); defer { try? FileManager.default.removeItem(at: root) }
        try runtime.providers.mutate { var rows = $0["providers"]!.array; rows[0] = .object(rows[0].object.filter { $0.key != "proxy" }); $0["providers"] = .array(rows) }
        let operations = NativeProviderOperations(store: runtime.providers, dependencies: .init(transport: http, heartbeatSeconds: 0))
        let adopted = try await operations.handle("adopt", input: ["id": "fixture"])
        XCTAssertEqual(adopted["format"], "anthropic"); XCTAssertEqual(adopted["models"], 1); XCTAssertEqual(adopted["dropped_non_chat"], 3)
        let requests = await http.captured(), probe = try XCTUnwrap(requests.first { $0.method == "POST" })
        XCTAssertEqual(try JSONValue.decode(probe.body!)["model"], "api-model")
        _ = try await operations.handle("model", input: ["id": "fixture", "model": "custom-id"])
        let refreshed = try await operations.handle("refresh", input: ["id": "fixture"]); XCTAssertEqual(refreshed["model"], "api-model")
        _ = try await operations.handle("registerWeb")
        let browser = try XCTUnwrap(runtime.providers.list().first { $0["id"] == "chatgpt-web" })
        XCTAssertNil(browser["api_key"]); XCTAssertNil(browser["proxy"]); XCTAssertEqual(browser["credential_ref"], "chatgpt-web")
        do { _ = try await operations.handle("adopt", input: ["id": "chatgpt-web"]); XCTFail("Browser was adopted as an API route") } catch {}
        _ = try await operations.handle("remove", input: ["id": "fixture"]); XCTAssertEqual(try runtime.providers.list().count, 1)
    }
    func testConcurrentProviderEditWinsCASAndIsNotOverwritten() async throws {
        let (root, runtime, _) = try SwitcherFixture.create(); defer { try? FileManager.default.removeItem(at: root) }
        let http = ShimFixtureTransport(beforeModels: { try runtime.providers.mutate { var rows = $0["providers"]!.array; rows[0]["name"] = "External edit"; $0["providers"] = .array(rows) } })
        let operations = NativeProviderOperations(store: runtime.providers, dependencies: .init(transport: http, heartbeatSeconds: 0))
        do { _ = try await operations.handle("refresh", input: ["id": "fixture"]); XCTFail("Concurrent edit overwritten") } catch { XCTAssertTrue(error.localizedDescription.contains("changed")) }
        XCTAssertEqual(try runtime.providers.list()[0]["name"], "External edit")
    }
    func testResponsesAndToolEvidenceStaySeparateAndPublicRecordsDoNotContainKeys() async throws {
        let http = ShimFixtureTransport(.textOnlyProof), (root, runtime, _) = try SwitcherFixture.create(transport: http); defer { try? FileManager.default.removeItem(at: root) }
        let operations = NativeProviderOperations(store: runtime.providers, dependencies: .init(transport: http, heartbeatSeconds: 0))
        let proof = try await operations.handle("registerResponses", input: ["id": "fixture"])
        let requests = await http.captured(); XCTAssertEqual(requests.first { $0.url.path.hasSuffix("/responses") }?.headers["Accept"], "text/event-stream")
        XCTAssertEqual(proof["responses_verified"], true); XCTAssertEqual(proof["tools_verified"], false)
        let info = NativeProviderInfo(.object(try runtime.providers.list()[0])); XCTAssertFalse(info.verified); XCTAssertTrue(info.codexReason.contains("did not emit"))
        XCTAssertFalse(String(decoding: try info.publicValue().encoded(), as: UTF8.self).contains("fixture-key"))
        let notes = NativeProviderInfo.tidyNote("route http://127.0.0.1:8823/fixture/v1/responses answered 402: {\"error\":{\"message\":\"Insufficient balance")
        XCTAssertEqual(notes, "HTTP 402: Insufficient balance")
        let goodHTTP = ShimFixtureTransport(), good = NativeProviderOperations(store: runtime.providers, dependencies: .init(transport: goodHTTP, heartbeatSeconds: 0))
        let valid = try await good.handle("registerResponses", input: ["id": "fixture"]); XCTAssertTrue(valid["tools_verified"].bool)
    }
}
