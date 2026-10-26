import XCTest
@testable import UniApiCore

final class SwitcherCustomModelsTests: XCTestCase {
    private let slug = "glm-5.3-uncensored:free"

    func testAddingUnadvertisedModelPreservesCredentialsProofDefaultsAndOtherProvidersWithoutRequests() async throws {
        let http = ShimFixtureTransport(), (root, runtime, _) = try SwitcherFixture.create(transport: http)
        defer { try? FileManager.default.removeItem(at: root) }
        try runtime.providers.mutate { document in
            var other = document["providers"]!.array[0]; other["id"] = "other"
            document["providers"] = .array(document["providers"]!.array + [other]); document["unrelated"] = ["keep": true]
        }
        let before = try runtime.providers.document()
        let config = root.appendingPathComponent("fixture-home/.codex/config.toml"), configBytes = try Data(contentsOf: config)
        let operations = NativeProviderOperations(store: runtime.providers, dependencies: .init(transport: http))
        _ = try await operations.handle("addModel", input: ["id": "fixture", "model": .string(slug)])
        var expected = before, rows = expected["providers"]!.array
        rows[0]["proxy"]["custom_models"] = [.string(slug)]
        rows[0]["codex"]["models"] = ["api-model", .string(slug)]; expected["providers"] = .array(rows)
        XCTAssertEqual(try runtime.providers.document(), expected)
        XCTAssertEqual(try Data(contentsOf: config), configBytes)
        let requests = await http.captured(); XCTAssertTrue(requests.isEmpty)
    }

    func testCustomModelAppearsInStatusPreferredWorkersAndSharedCodexDefault() async throws {
        let (root, runtime, io) = try SwitcherFixture.create(); defer { try? FileManager.default.removeItem(at: root) }
        let service = NativeSwitcherService(runtime: runtime, io: io)
        _ = try await service.handle("provider", input: ["operation": "addModel", "id": "fixture", "model": .string(slug)])
        let status = try await service.handle("codexStatus")
        let row = try XCTUnwrap(status["models"].array.first { $0["source"] == "provider" && $0["id"] == .string(slug) })
        XCTAssertEqual(row["providerId"], "fixture"); XCTAssertEqual(row["custom"], true); XCTAssertEqual(row["available"], true)
        let alias = NativeCodexCatalogStore.id(provider: "fixture", model: slug)
        XCTAssertEqual(alias, "uniapi/fixture/glm-5.3-uncensored%3Afree"); XCTAssertEqual(row["catalogId"], .string(alias))
        var draft = NativeSwitcherCatalogDraft(); draft.accept(status["catalog"])
        draft.toggleProvider(try XCTUnwrap(status["catalog"]["providers"].array.first), models: status["models"].array)
        draft.toggleWorker(row); XCTAssertEqual(draft.workers, [alias])
        _ = try await service.handle("catalog", input: draft.body)
        let saved = try await service.codex.catalog.read(); XCTAssertEqual(saved["workerModels"], [.string(alias)])
        let result = try await service.handle("codexSelect", input: ["source": "provider", "providerId": "fixture", "model": .string(slug)])
        XCTAssertEqual(result["ok"], true)
        let config = try NativeTOML.parse(SwitcherDisk.text(root.appendingPathComponent("fixture-home/.codex/config.toml")))
        XCTAssertEqual(config["model"], .string(alias)); XCTAssertEqual(config["openai_base_url"], "http://127.0.0.1:17841/v1")
        XCTAssertNil(config["model_provider"])
    }

    func testRefreshAndExplicitRouteRecheckRetainCustomModelAndChosenDefault() async throws {
        let http = ShimFixtureTransport(), (root, runtime, _) = try SwitcherFixture.create(transport: http)
        defer { try? FileManager.default.removeItem(at: root) }
        let operations = NativeProviderOperations(store: runtime.providers, dependencies: .init(transport: http, heartbeatSeconds: 0))
        _ = try await operations.handle("addModel", input: ["id": "fixture", "model": .string(slug)])
        _ = try await operations.handle("model", input: ["id": "fixture", "model": .string(slug)])
        _ = try await operations.handle("refresh", input: ["id": "fixture"])
        var row = try XCTUnwrap(runtime.providers.list().first)
        XCTAssertEqual(row["proxy"]?["models"], ["api-model"])
        XCTAssertEqual(NativeProviderInfo(.object(row)).models, ["api-model", slug])
        XCTAssertEqual(row["proxy"]?["model"], .string(slug))
        _ = try await operations.handle("registerResponses", input: ["id": "fixture", "model": .string(slug)])
        row = try XCTUnwrap(runtime.providers.list().first)
        XCTAssertEqual(row["proxy"]?["custom_models"], [.string(slug)])
        XCTAssertEqual(row["codex"]?["models"], ["api-model", .string(slug)])
        XCTAssertEqual(row["codex"]?["verified_model"], .string(slug))
        XCTAssertEqual(row["codex"]?["tools_verified"], true)
    }

    func testDuplicateCustomModelIsIdempotentAndDoesNotLeakCredentials() async throws {
        let http = ShimFixtureTransport(), (root, runtime, _) = try SwitcherFixture.create(transport: http)
        defer { try? FileManager.default.removeItem(at: root) }
        let operations = NativeProviderOperations(store: runtime.providers, dependencies: .init(transport: http))
        _ = try await operations.handle("addModel", input: ["id": "fixture", "model": .string(slug)])
        let first = try Data(contentsOf: runtime.paths.providers)
        _ = try await operations.handle("addModel", input: ["id": "fixture", "model": .string(slug)])
        XCTAssertEqual(try Data(contentsOf: runtime.paths.providers), first)
        let info = NativeProviderInfo(.object(try XCTUnwrap(runtime.providers.list().first)))
        XCTAssertEqual(info.customModels, [slug]); XCTAssertEqual(info.models, ["api-model", slug])
        let exported = String(decoding: try info.publicValue().encoded(), as: UTF8.self)
        XCTAssertFalse(exported.contains("fixture-key")); XCTAssertTrue(exported.contains(slug))
        let requests = await http.captured(); XCTAssertTrue(requests.isEmpty)
    }

    func testInvalidOrForeignCustomModelsRefuseWithoutWritesOrProbes() async throws {
        let http = ShimFixtureTransport(), (root, runtime, _) = try SwitcherFixture.create(transport: http)
        defer { try? FileManager.default.removeItem(at: root) }
        let operations = NativeProviderOperations(store: runtime.providers, dependencies: .init(transport: http))
        _ = try await operations.handle("registerWeb")
        let before = try Data(contentsOf: runtime.paths.providers)
        for id: JSONValue in [.null, 42, "", " ", " bad", "bad ", "bad\nmodel", "bad\u{7f}", .string(String(repeating: "x", count: 1025)), .string(String(repeating: "\u{10400}", count: 513)), .string(String(repeating: ":", count: 400))] {
            do { _ = try await operations.handle("addModel", input: ["id": "fixture", "model": id]); XCTFail("Malformed model admitted") } catch {}
        }
        for id in ["missing", "chatgpt-web"] {
            do { _ = try await operations.handle("addModel", input: ["id": .string(id), "model": .string(slug)]); XCTFail("Foreign provider admitted") } catch {}
        }
        do { _ = try await operations.handle("addModel", input: ["id": "fixture", "model": .string(slug), "extra": true]); XCTFail("Unexpected fields admitted") } catch {}
        XCTAssertEqual(try Data(contentsOf: runtime.paths.providers), before)
        let requests = await http.captured(); XCTAssertTrue(requests.isEmpty)
    }

    func testCustomModelNeverPromotesAnUnverifiedOrDisabledRoute() async throws {
        let (root, runtime, io) = try SwitcherFixture.create(); defer { try? FileManager.default.removeItem(at: root) }
        try runtime.providers.mutate { document in var rows = document["providers"]!.array; rows[0]["codex"]["responses_verified"] = false; rows[0]["codex"]["tools_verified"] = false; document["providers"] = .array(rows) }
        let service = NativeSwitcherService(runtime: runtime, io: io)
        _ = try await service.handle("provider", input: ["operation": "addModel", "id": "fixture", "model": .string(slug)])
        let status = try await service.handle("codexStatus"), row = try XCTUnwrap(status["models"].array.first { $0["id"] == .string(slug) })
        XCTAssertEqual(row["available"], false)
        do { _ = try await service.handle("catalog", input: ["providerIds": ["fixture"], "workerModels": [row["catalogId"]]]); XCTFail("Unverified worker published") } catch {}
        try runtime.providers.mutate { document in var rows = document["providers"]!.array; rows[0]["disabled"] = true; document["providers"] = .array(rows) }
        let before = try Data(contentsOf: runtime.paths.providers)
        do { _ = try await service.handle("provider", input: ["operation": "addModel", "id": "fixture", "model": "another"]); XCTFail("Disabled route admitted") } catch {}
        XCTAssertEqual(try Data(contentsOf: runtime.paths.providers), before)
    }

    func testCustomModelCapacityReadOnlyAndMalformedRegistrationRemainBounded() async throws {
        let (root, runtime, _) = try SwitcherFixture.create(); defer { try? FileManager.default.removeItem(at: root) }
        let operations = NativeProviderOperations(store: runtime.providers)
        try runtime.providers.mutate { document in var rows = document["providers"]!.array; rows[0]["proxy"]["custom_models"] = .array((0..<NativeProviderInfo.customModelLimit).map { .string("custom-\($0)") }); document["providers"] = .array(rows) }
        var before = try Data(contentsOf: runtime.paths.providers)
        do { _ = try await operations.handle("addModel", input: ["id": "fixture", "model": .string(slug)]); XCTFail("Custom model bound exceeded") } catch {}
        XCTAssertEqual(try Data(contentsOf: runtime.paths.providers), before)
        let readOnly = NativeProviderOperations(store: NativeProviderStore(paths: .init(root: root, home: runtime.paths.home, readOnly: true)))
        do { _ = try await readOnly.handle("addModel", input: ["id": "fixture", "model": "custom-0"]); XCTFail("Read-only write admitted") } catch {}
        XCTAssertEqual(try Data(contentsOf: runtime.paths.providers), before)
        try runtime.providers.mutate { document in var rows = document["providers"]!.array; rows[0]["proxy"]["custom_models"] = []; rows[0]["codex"]["models"] = "malformed"; document["providers"] = .array(rows) }
        before = try Data(contentsOf: runtime.paths.providers)
        do { _ = try await operations.handle("addModel", input: ["id": "fixture", "model": .string(slug)]); XCTFail("Malformed registration repaired implicitly") } catch {}
        XCTAssertEqual(try Data(contentsOf: runtime.paths.providers), before)
    }
}
