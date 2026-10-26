import XCTest
@testable import UniApiCore

final class SwitcherTests: XCTestCase {
    private func wait(_ runtime: NativeRuntime, _ id: String) async throws -> JSONValue {
        for _ in 0..<500 { if let row = try await runtime.jobs.get(id), !["queued", "running"].contains(row["status"]?.string ?? "") { return .object(row) }; try await Task.sleep(nanoseconds: 2_000_000) }; throw NativeFailure("Fixture job did not settle")
    }
    func testClaudeApplyRestoreParkedModelAndUnrelatedSettings() async throws {
        let (root, runtime, io) = try SwitcherFixture.create(); defer { try? FileManager.default.removeItem(at: root) }
        let service = NativeSwitcherService(runtime: runtime, io: io)
        _ = try await service.handle("apply", input: ["id": "fixture"])
        let store = NativeClaudeSettingsStore(paths: runtime.paths), applied = try store.read()
        XCTAssertEqual(applied["model"], "api-model"); XCTAssertEqual(applied["permissions"]["allow"], ["Read"]); XCTAssertEqual(applied["env"]["UNRELATED"], "keep")
        _ = try await service.handle("effort", input: ["effort": "max"]); _ = try await service.handle("restore")
        let restored = try store.read(); XCTAssertEqual(restored["model"], "opus[1m]"); XCTAssertEqual(restored["effort"], "max"); XCTAssertTrue(restored["env"]["ANTHROPIC_BASE_URL"].isNull)
    }
    func testStatusNeverRunsProofAndTextAccessIsNotToolReadiness() async throws {
        let http = ShimFixtureTransport(), commands = SwitcherFixtureCommands(), (root, runtime, io) = try SwitcherFixture.create(transport: http, commands: commands); defer { try? FileManager.default.removeItem(at: root) }
        let service = NativeSwitcherService(runtime: runtime, io: io); try await service.start(); try await runtime.jobs.recover()
        let status = try await service.handle("codexStatus"), count = await commands.proofs()
        XCTAssertEqual(count, 0); XCTAssertEqual(status["bridge"]["toolsVerified"], false)
        XCTAssertEqual(status["models"].array.first { $0["source"] == "web" && $0["id"] == "chatgpt-web/high" }?["available"], false)
        let calls = await http.captured(); XCTAssertTrue(calls.allSatisfy { $0.method == "GET" })
        let probe = try await service.handle("probe", input: ["id": "fixture"]); XCTAssertTrue(probe["ok"].bool); XCTAssertEqual(probe["toolsVerified"], false)
    }
    func testFullProofRequiresFileAndFinalAcknowledgementAndBindsConfigHash() async throws {
        let commands = SwitcherFixtureCommands(), (root, runtime, io) = try SwitcherFixture.create(commands: commands); defer { try? FileManager.default.removeItem(at: root) }
        let service = NativeSwitcherService(runtime: runtime, io: io)
        let accepted = try await service.handle("verifyCodexTools"), job = try await wait(runtime, accepted["job"]["id"].string); XCTAssertEqual(job["status"], "done")
        let status = try await service.handle("codexStatus"); XCTAssertEqual(status["bridge"]["toolsVerified"], true)
        let argv = await commands.captured(); XCTAssertTrue(argv[0].arguments.contains("--ephemeral")); XCTAssertTrue(argv[0].arguments.contains("model_providers.uniapi_web_verification.stream_max_retries=0"))
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(at: runtime.paths.tmp, includingPropertiesForKeys: nil).isEmpty)
        let configFile = runtime.paths.home.appendingPathComponent(".codex-chatgpt-web/config.json"); var config = try NativeFile.readJSON(configFile); config["extra"] = "changed"; try NativeFile.writeAtomic(try config.encoded(), to: configFile)
        let stale = try await service.handle("codexStatus"); XCTAssertEqual(stale["bridge"]["toolsVerified"], false)
        let failedCommands = SwitcherFixtureCommands(proofWorks: false), (secondRoot, secondRuntime, secondIO) = try SwitcherFixture.create(commands: failedCommands); defer { try? FileManager.default.removeItem(at: secondRoot) }
        let other = NativeSwitcherService(runtime: secondRuntime, io: secondIO), failed = try await other.handle("verifyCodexTools"), result = try await wait(secondRuntime, failed["job"]["id"].string)
        XCTAssertEqual(result["status"], "failed"); XCTAssertFalse(FileManager.default.fileExists(atPath: secondRuntime.paths.data.appendingPathComponent("codex/web-verification.json").path))
    }
    func testCatalogCapacityReservedAnchorAndBusyDrainCompensation() async throws {
        let http = ShimFixtureTransport(), (root, runtime, io) = try SwitcherFixture.create(transport: http); defer { try? FileManager.default.removeItem(at: root) }
        let service = NativeSwitcherService(runtime: runtime, io: io)
        do { _ = try await service.handle("catalog", input: ["providerIds": ["fixture"], "workerModels": ["native-anchor"]]); XCTFail("Reserved anchor selected") } catch {}
        let id = NativeCodexCatalogStore.id(provider: "fixture", model: "api-model")
        await http.configure(busy: true)
        do { _ = try await service.handle("catalog", input: ["providerIds": ["fixture"], "workerModels": [.string(id)]]); XCTFail("Busy catalog write") } catch {}
        let calls = await http.captured(); XCTAssertTrue(calls.contains { $0.url.path == "/admin/resume" })
        await http.configure(busy: false)
        _ = try await service.handle("catalog", input: ["providerIds": ["fixture"], "workerModels": ["native-worker", .string(id)]])
        _ = try await service.handle("codexSelect", input: ["source": "provider", "providerId": "fixture", "model": "api-model", "effort": "high"])
        let parsed = try NativeTOML.parse(SwitcherDisk.text(runtime.paths.home.appendingPathComponent(".codex/config.toml")))
        XCTAssertEqual(parsed["model"], .string(id)); XCTAssertNil(parsed["model_provider"]); XCTAssertEqual(parsed["openai_base_url"], "http://127.0.0.1:17841/v1")
        do { _ = try await service.handle("catalog", input: ["providerIds": [], "workerModels": []]); XCTFail("Active default provider removed") } catch {}
        XCTAssertThrowsError(try NativeCodexCatalogStore.validate(["providerIds": [], "workerModels": ["a", "b", "c", "d", "e"]]))
    }
    func testNativeAdvertisedEffortAndManagedProviderRestorePreserveHooks() async throws {
        let (root, runtime, io) = try SwitcherFixture.create(integrated: false); defer { try? FileManager.default.removeItem(at: root) }
        let service = NativeSwitcherService(runtime: runtime, io: io)
        _ = try await service.handle("codexSelect", input: ["source": "subscription", "model": "native-anchor", "effort": "ultra"])
        do { _ = try await service.handle("codexSelect", input: ["source": "subscription", "model": "native-anchor", "effort": "max"]); XCTFail("Unadvertised effort saved") } catch {}
        _ = try await service.handle("codexSelect", input: ["source": "provider", "providerId": "fixture", "model": "api-model", "effort": "high"])
        let file = runtime.paths.home.appendingPathComponent(".codex/config.toml"), before = try NativeTOML.parse(SwitcherDisk.text(file)); XCTAssertEqual(before["model_provider"], "uniapi_managed")
        _ = try await service.handle("codexAction", input: ["action": "restore"])
        let restored = try NativeTOML.parse(SwitcherDisk.text(file)); XCTAssertEqual(restored["model"], "native-anchor"); XCTAssertEqual(restored["hooks"]?["command"], "preserve"); XCTAssertNil(restored["model_provider"])
    }
    func testCatalogCanonicalIDsAndCrossConfigurationRefusal() throws {
        let id = NativeCodexCatalogStore.id(provider: "a/b", model: "模型 /model%")
        XCTAssertEqual(NativeCodexCatalogStore.parseID(id)?.provider, "a/b"); XCTAssertEqual(NativeCodexCatalogStore.parseID(id)?.model, "模型 /model%")
        XCTAssertNil(NativeCodexCatalogStore.parseID("uniapi/a%2fb/model"))
        let (root, runtime, _) = try SwitcherFixture.create(); defer { try? FileManager.default.removeItem(at: root) }
        let store = NativeCodexCatalogStore(bridgeHome: runtime.paths.home.appendingPathComponent(".codex-chatgpt-web"), providersFile: runtime.paths.providers)
        try NativeFile.writeAtomic(try JSONValue.object(["version": 1, "providersFile": .string(root.appendingPathComponent("other.json").path), "providerIds": [], "workerModels": []]).encoded(), to: store.file)
        XCTAssertThrowsError(try store.write(["providerIds": [], "workerModels": []]))
    }
    func testConfigurationChangeDuringProofCannotCreateAReceipt() async throws {
        let commands = SwitcherFixtureCommands(), (root, runtime, originalIO) = try SwitcherFixture.create(commands: commands); defer { try? FileManager.default.removeItem(at: root) }
        let configFile = runtime.paths.home.appendingPathComponent(".codex-chatgpt-web/config.json")
        var io = originalIO
        io.prove = { command, env, directory in
            let result = try await commands.prove(command, env, directory)
            var config = try NativeFile.readJSON(configFile); config["changedDuringProof"] = true; try NativeFile.writeAtomic(try config.encoded(), to: configFile); return result
        }
        let service = NativeSwitcherService(runtime: runtime, io: io), accepted = try await service.handle("verifyCodexTools")
        let job = try await wait(runtime, accepted["job"]["id"].string)
        XCTAssertEqual(job["status"], "failed"); XCTAssertFalse(FileManager.default.fileExists(atPath: runtime.paths.data.appendingPathComponent("codex/web-verification.json").path))
    }
    func testReadOnlyProbeAndOtherActionsNeverReachTransport() async throws {
        let http = ShimFixtureTransport(), (root, runtime, io) = try SwitcherFixture.create(transport: http); defer { try? FileManager.default.removeItem(at: root) }
        let readOnly = try NativeRuntime(paths: NativePaths(root: root, home: runtime.paths.home, readOnly: true))
        let service = NativeSwitcherService(runtime: readOnly, io: io)
        for operation in ["probe", "apply", "restore", "model", "effort", "provider", "codexSelect", "catalog", "codexAction", "verifyCodexTools", "verifyProvider", "startShim", "stopShim"] {
            do { _ = try await service.handle(operation, input: ["id": "fixture", "model": "api-model"]); XCTFail("Read-only action accepted: " + operation) } catch { XCTAssertTrue(error.localizedDescription.contains("read-only")) }
        }
        let requests = await http.captured(); XCTAssertTrue(requests.isEmpty)
        await service.shutdown()
    }
    func testLegacyShimCannotMakeAPIModelsSelectableOrWriteCodexDefaults() async throws {
        let http = ShimFixtureTransport(), (root, runtime, io) = try SwitcherFixture.create(transport: http, integrated: false); defer { try? FileManager.default.removeItem(at: root) }
        await http.configure(nativeShim: false)
        let service = NativeSwitcherService(runtime: runtime, io: io), file = runtime.paths.home.appendingPathComponent(".codex/config.toml"), before = try SwitcherDisk.read(file)
        let status = try await service.handle("codexStatus")
        XCTAssertEqual(status["nativeShimReady"], false); XCTAssertEqual(status["models"].array.first { $0["source"] == "provider" }?["available"], false)
        do { _ = try await service.handle("codexSelect", input: ["source": "provider", "providerId": "fixture", "model": "api-model"]); XCTFail("Legacy runtime selected") } catch {}
        XCTAssertEqual(try SwitcherDisk.read(file), before)
    }
}
