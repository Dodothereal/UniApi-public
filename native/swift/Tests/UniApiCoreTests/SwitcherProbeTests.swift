import XCTest
@testable import UniApiCore

private actor SwitcherProbeTransport: ShimTransport {
    enum Reply { case works, empty, whitespace, refused, network, cancelled }
    let reply: Reply
    let fallback = ShimFixtureTransport()
    var requests: [ShimHTTPRequest] = []
    init(_ reply: Reply) { self.reply = reply }
    func open(_ request: ShimHTTPRequest) async throws -> ShimUpstream {
        requests.append(request)
        guard request.url.path.hasSuffix("/messages") else { return try await fallback.open(request) }
        if reply == .network { throw NativeFailure("fixture-secret must not escape") }
        if reply == .cancelled { throw CancellationError() }
        let payload: JSONValue = reply == .refused ? ["error": ["message": "402 fixture-key Insufficient balance"]] : ["content": reply == .empty ? [] : [["type": "text", "text": reply == .whitespace ? " \n\t" : "hi"]]]
        let bytes = try payload.encoded()
        return .init(status: reply == .refused ? 402 : 200, headers: [:], chunks: AsyncThrowingStream { $0.yield(bytes); $0.finish() })
    }
    func probes() -> [ShimHTTPRequest] { requests.filter { $0.url.path.hasSuffix("/messages") } }
}

final class SwitcherProbeTests: XCTestCase {
    func testProbeCancellationIsNotReportedAsAProviderFailureVerdict() async throws {
        let (root, runtime, baseIO) = try SwitcherFixture.create(); defer { try? FileManager.default.removeItem(at: root) }
        var io = baseIO; io.http = .init(transport: SwitcherProbeTransport(.cancelled), heartbeatSeconds: 0)
        let service = NativeSwitcherService(runtime: runtime, io: io)
        do { _ = try await service.handle("probe", input: ["id": "fixture", "model": "api-model"]); XCTFail("Cancellation became a provider verdict") }
        catch is CancellationError {} catch { XCTFail("Unexpected error: \(error)") }
    }
    func testInvalidDirectRouteKeepsSavedApplyAndModelResultsWithFailedVerdictAndNoInference() async throws {
        let (root, runtime, baseIO) = try SwitcherFixture.create(); defer { try? FileManager.default.removeItem(at: root) }
        try runtime.providers.mutate { document in
            var providers = document["providers"]!.array
            providers[0]["proxy"]["direct_url"] = "not-a-url"
            document["providers"] = .array(providers)
        }
        let transport = SwitcherProbeTransport(.works); var io = baseIO; io.http = .init(transport: transport, heartbeatSeconds: 0)
        let service = NativeSwitcherService(runtime: runtime, io: io)
        for operation in ["applyAndProbe", "modelAndProbe"] {
            let result = try await service.handle(operation, input: ["id": "fixture", "model": .string(operation + "-model")])
            let settings = try NativeClaudeSettingsStore(paths: runtime.paths).read()
            XCTAssertEqual(result["saved"], true); XCTAssertEqual(result["probe"]["ok"], false)
            XCTAssertEqual(result["probe"]["toolsVerified"], false); XCTAssertEqual(result["probe"]["empty"], false)
            XCTAssertEqual(result["probe"]["provider"], "fixture"); XCTAssertEqual(result["probe"]["model"], .string(operation + "-model"))
            XCTAssertFalse(result["probe"]["message"].string.isEmpty)
            XCTAssertEqual(settings["model"], .string(operation + "-model")); XCTAssertEqual(settings["env"]["ANTHROPIC_BASE_URL"], "not-a-url")
        }
        let probes = await transport.probes(); XCTAssertTrue(probes.isEmpty)
        XCTAssertThrowsError(try NativeClaudeTextProbe.request(NativeProviderInfo(["id": "invalid", "proxy": ["format": "anthropic", "direct_url": "not-a-url"]]), model: "model", timeout: 15))
    }
    func testExplicitUseSavesVisibleModelAndProbesOnceWithSeparateVerdict() async throws {
        for reply in [SwitcherProbeTransport.Reply.works, .empty, .whitespace, .refused, .network] {
            let (root, runtime, baseIO) = try SwitcherFixture.create(); defer { try? FileManager.default.removeItem(at: root) }
            let http = SwitcherProbeTransport(reply); var io = baseIO; io.http = .init(transport: http, heartbeatSeconds: 0)
            let service = NativeSwitcherService(runtime: runtime, io: io)
            let result = try await service.handle("applyAndProbe", input: ["id": "fixture", "model": "visible-custom"])
            let settings = try NativeClaudeSettingsStore(paths: runtime.paths).read(), probes = await http.probes()
            XCTAssertEqual(settings["model"], "visible-custom"); XCTAssertEqual(result["saved"], true); XCTAssertEqual(probes.count, 1)
            XCTAssertEqual(result["probe"]["provider"], "fixture"); XCTAssertEqual(result["probe"]["model"], "visible-custom"); XCTAssertEqual(result["probe"]["toolsVerified"], false)
            XCTAssertEqual(probes.first?.timeout, 45); XCTAssertEqual(try JSONValue.decode(probes.first!.body!)["max_tokens"], 8)
            if reply == .works { XCTAssertEqual(result["probe"]["ok"], true); XCTAssertEqual(result["probe"]["empty"], false) }
            if reply == .empty || reply == .whitespace { XCTAssertEqual(result["probe"]["ok"], true); XCTAssertEqual(result["probe"]["empty"], true) }
            if reply == .refused { XCTAssertEqual(result["probe"]["ok"], false); XCTAssertTrue(result["probe"]["message"].string.contains("Insufficient balance")); XCTAssertFalse(result["probe"]["message"].string.contains("fixture-key")) }
            if reply == .network { XCTAssertEqual(result["probe"]["ok"], false); XCTAssertFalse(result["probe"]["message"].string.contains("fixture-secret")) }
        }
    }
    func testModelSaveChecksOnlyActiveProviderAndStatusNeverProbes() async throws {
        let (root, runtime, io) = try SwitcherFixture.create(); defer { try? FileManager.default.removeItem(at: root) }
        let service = NativeSwitcherService(runtime: runtime, io: io)
        let inactive = try await service.handle("modelAndProbe", input: ["id": "fixture", "model": "inactive-model"])
        XCTAssertTrue(inactive["probe"].isNull)
        _ = try await service.handle("status"); _ = try await service.handle("codexStatus")
        _ = try await service.handle("apply", input: ["id": "fixture"])
        let active = try await service.handle("modelAndProbe", input: ["id": "fixture", "model": "active-model"])
        XCTAssertEqual(active["probe"]["model"], "active-model")
        let http = try XCTUnwrap(io.http.transport as? ShimFixtureTransport), calls = await http.captured()
        XCTAssertEqual(calls.filter { $0.url.path.hasSuffix("/messages") }.count, 1)
    }
    func testReadOnlyCompoundActionsRefuseBeforeAnyRouteOrConfigurationIO() async throws {
        let http = ShimFixtureTransport(), (root, runtime, io) = try SwitcherFixture.create(transport: http); defer { try? FileManager.default.removeItem(at: root) }
        let settingsFile = NativeClaudeSettingsStore(paths: runtime.paths).file, before = try Data(contentsOf: settingsFile), providers = try Data(contentsOf: runtime.paths.providers)
        let ro = try NativeRuntime(paths: NativePaths(root: root, home: runtime.paths.home, readOnly: true)), service = NativeSwitcherService(runtime: ro, io: io)
        for action in ["applyAndProbe", "modelAndProbe"] {
            do { _ = try await service.handle(action, input: ["id": "fixture", "model": "api-model"]); XCTFail("Read-only action admitted") } catch {}
        }
        let calls = await http.captured(); XCTAssertTrue(calls.isEmpty); XCTAssertEqual(try Data(contentsOf: settingsFile), before); XCTAssertEqual(try Data(contentsOf: runtime.paths.providers), providers)
    }
}
