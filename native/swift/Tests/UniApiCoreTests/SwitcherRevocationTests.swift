import XCTest
@testable import UniApiCore

final class SwitcherRevocationTests: XCTestCase {
    func testDisconnectedDisabledProvidersCannotBeSelectedOrChangeConfig() async throws {
        for (scope, key, value) in [("", "disabled", JSONValue.bool(true)), ("", "enabled", .bool(false)),
                                    ("proxy", "disabled", .bool(true)), ("proxy", "enabled", .bool(false)),
                                    ("codex", "disabled", .bool(true)), ("codex", "enabled", .bool(false))] {
            let (root, runtime, io) = try SwitcherFixture.create(integrated: false); defer { try? FileManager.default.removeItem(at: root) }
            try runtime.providers.mutate { document in
                var provider = document["providers"]!.array[0]
                if scope.isEmpty { provider[key] = value } else { provider[scope][key] = value }
                document["providers"] = [provider]
            }
            let service = NativeSwitcherService(runtime: runtime, io: io), file = runtime.paths.home.appendingPathComponent(".codex/config.toml"), before = try SwitcherDisk.read(file)
            let status = try await service.handle("codexStatus")
            XCTAssertEqual(status["catalog"]["providers"].array[0]["available"], false)
            XCTAssertEqual(status["models"].array.first { $0["source"] == "provider" }?["available"], false)
            do { _ = try await service.handle("codexSelect", input: ["source": "provider", "providerId": "fixture", "model": "api-model"]); XCTFail("Revoked provider selected") } catch {}
            XCTAssertEqual(try SwitcherDisk.read(file), before)
        }
    }
    func testEnabledDisconnectedProviderStillSelectsItsManagedResponsesRoute() async throws {
        let (root, runtime, io) = try SwitcherFixture.create(integrated: false); defer { try? FileManager.default.removeItem(at: root) }
        let service = NativeSwitcherService(runtime: runtime, io: io), status = try await service.handle("codexStatus")
        XCTAssertEqual(status["models"].array.first { $0["source"] == "provider" }?["available"], true)
        _ = try await service.handle("codexSelect", input: ["source": "provider", "providerId": "fixture", "model": "api-model"])
        let config = try NativeTOML.parse(SwitcherDisk.text(runtime.paths.home.appendingPathComponent(".codex/config.toml")))
        XCTAssertEqual(config["model_provider"], "uniapi_managed"); XCTAssertEqual(config["model_providers"]?["uniapi_managed"]["wire_api"], "responses")
    }
}
