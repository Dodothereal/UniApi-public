import Foundation
import XCTest
@testable import UniApiCore

private actor CodexManagerHTTP: ShimTransport {
    private var requests: [ShimHTTPRequest] = []
    private var accepting = true, active = 0, webBusy = false, webRunning = true
    private var resumeFails = false
    private let instance = UUID().uuidString
    private var lease: String?
    func configure(active: Int = 0, webBusy: Bool = false, webRunning: Bool = true, resumeFails: Bool = false) {
        self.active = active; self.webBusy = webBusy; self.webRunning = webRunning; self.resumeFails = resumeFails
    }
    func captured() -> [ShimHTTPRequest] { requests }
    func reset() { requests = [] }
    func open(_ request: ShimHTTPRequest) async throws -> ShimUpstream {
        requests.append(request)
        func reply(_ value: JSONValue, status: Int = 200) throws -> ShimUpstream {
            let bytes = try value.encoded()
            return .init(status: status, chunks: AsyncThrowingStream { $0.yield(bytes); $0.finish() })
        }
        if request.url.port == 8823 {
            if request.url.path == "/healthz" { return try reply(["ok": true, "service": "uniapi-shim", "runtime": "swift"]) }
            let operation = request.url.lastPathComponent
            if operation == "drain" || operation == "resume" {
                let body = try JSONValue.decode(request.body ?? Data())
                guard case .string(let requested) = body["lease"], UUID(uuidString: requested) != nil else { throw NativeFailure("Missing fixture request lease") }
                guard lease == nil || lease == requested else { return try reply(["error": "fixture lease conflict"], status: 409) }
                if operation == "drain" { lease = requested; accepting = false }
                else {
                    if resumeFails { return try reply(["error": "fixture refusal"], status: 503) }
                    lease = nil; accepting = true
                }
            }
            return try reply(["service": "uniapi-shim", "runtime": "swift", "nativeVersion": 1, "accepting": .bool(accepting),
                              "activeRequests": .number(Double(active)), "pid": 1234, "instance": .string(instance), "lease": lease.map(JSONValue.string) ?? .null])
        }
        if request.url.path == "/healthz" {
            return try reply(["service": "codex-chatgpt-web", "status": webRunning ? "ok" : "offline", "mode": "full", "version": "5.0.4",
                              "active_http_turns": .number(webBusy ? 1 : 0), "active_browser_turns": 0,
                              "uniapi_catalog_version": 1, "uniapi_catalog_protocol": "compatibility-v1"])
        }
        if request.url.path == "/admin/drain" { return try reply(["accepting_turns": false, "active_http_turns": .number(webBusy ? 1 : 0), "active_browser_turns": 0]) }
        if request.url.path == "/admin/resume" { return try reply(["accepting_turns": true]) }
        if request.url.path == "/uniapi/v1/models" { return try reply(["data": []]) }
        throw NativeFailure("Unexpected fixture HTTP route")
    }
}

private final class CodexManagerCommands: @unchecked Sendable {
    enum Mode: Equatable, Sendable { case normal, resetDefault, failAfterDisconnect, leaveForeignRoute, changeCatalog }
    private let lock = NSLock()
    private var commands: [[String]] = []
    let paths: NativePaths, mode: Mode
    init(paths: NativePaths, mode: Mode) { self.paths = paths; self.mode = mode }
    func captured() -> [[String]] { lock.withLock { commands } }
    func run(_ command: NativeSwitcherCommand) throws -> String {
        lock.withLock { commands.append(command.arguments) }
        guard command.arguments == ["route", "disconnect"] else { throw NativeFailure("Unexpected fixture CLI action") }
        let config = SwitcherDisk.codexHome(paths).appendingPathComponent("config.toml")
        var text = try NativeTOML.patchTransport(SwitcherDisk.text(config), values: ["openai_base_url": mode == .leaveForeignRoute ? "https://foreign.invalid/v1" : .null])
        if mode == .resetDefault { text = try NativeTOML.patchDefaults(text, values: ["model": .null, "model_reasoning_effort": .null]) }
        try NativeFile.writeAtomic(Data(text.utf8), to: config)
        let cache = SwitcherDisk.codexHome(paths).appendingPathComponent("models_cache.json")
        if FileManager.default.fileExists(atPath: cache.path) { try FileManager.default.removeItem(at: cache) }
        if mode == .changeCatalog {
            let native = NativeCodexRouteStore(paths: paths)
            try native.catalog.write(["providerIds": [], "workerModels": ["native-worker"]])
        }
        if mode == .failAfterDisconnect { throw NativeFailure("Fixture disconnect acknowledgement lost") }
        return "disconnected"
    }
}

final class CodexNativeManagerTests: XCTestCase {
    private struct Fixture {
        let root: URL, runtime: NativeRuntime, manager: NativeCodexManager, http: CodexManagerHTTP, commands: CodexManagerCommands
        var store: NativeCodexRouteStore { .init(paths: runtime.paths) }
        var config: URL { SwitcherDisk.codexHome(runtime.paths).appendingPathComponent("config.toml") }
        var bridgeCatalog: NativeCodexCatalogStore { .init(bridgeHome: SwitcherDisk.bridgeHome(runtime.paths), providersFile: runtime.paths.providers) }
    }
    private let alias = "uniapi/fixture/api-model"
    private var choices: JSONValue { ["providerIds": ["fixture"], "workerModels": ["native-worker", .string(alias)]] }
    private func fixture(web: Bool = true, mode: CodexManagerCommands.Mode = .normal) throws -> Fixture {
        let (root, runtime, originalIO) = try SwitcherFixture.create(integrated: web)
        let http = CodexManagerHTTP(), commands = CodexManagerCommands(paths: runtime.paths, mode: mode)
        var io = originalIO; io.http = .init(transport: http, retryBackoff: [], heartbeatSeconds: 0)
        io.run = { command, _ in try commands.run(command) }
        let manager = NativeCodexManager(runtime: runtime, io: io)
        _ = try NativeCodexControlSecret.load(runtime.paths, create: true)
        let f = Fixture(root: root, runtime: runtime, manager: manager, http: http, commands: commands)
        try f.bridgeCatalog.write(choices)
        let text = try NativeTOML.patchDefaults(SwitcherDisk.text(f.config), values: ["model": .string(alias), "model_reasoning_effort": "high"])
        try NativeFile.writeAtomic(Data(text.utf8), to: f.config)
        return f
    }
    private func document(_ f: Fixture) throws -> JSONObject { try NativeTOML.parse(SwitcherDisk.text(f.config)) }
    private func assertNoReconnect(_ f: Fixture, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertFalse(f.commands.captured().contains { $0 == ["route", "connect"] }, file: file, line: line)
    }

    func testWebHandoffPreservesDefaultEffortMembershipAndProviderBytes() async throws {
        let f = try fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        let before = try document(f), providers = try SwitcherDisk.read(f.runtime.paths.providers), membership = try SwitcherDisk.read(f.bridgeCatalog.file)
        let result = try await f.manager.action("nativeConnect"), after = try document(f)
        XCTAssertEqual(result["ok"], true); XCTAssertEqual(result["status"]["native"]["connected"], true)
        XCTAssertEqual(result["status"]["native"]["accepting"], true)
        XCTAssertEqual(after["model"], before["model"]); XCTAssertEqual(after["model_reasoning_effort"], before["model_reasoning_effort"])
        XCTAssertEqual(after["hooks"], before["hooks"])
        XCTAssertEqual(after["openai_base_url"], .string(try f.store.baseURL()))
        XCTAssertEqual(try f.store.catalog.read(), choices)
        XCTAssertEqual(try SwitcherDisk.read(f.bridgeCatalog.file), membership)
        XCTAssertEqual(try SwitcherDisk.read(f.runtime.paths.providers), providers)
        XCTAssertFalse(FileManager.default.fileExists(atPath: f.runtime.paths.data.appendingPathComponent("codex/defaults-journal.json").path))
        XCTAssertTrue(result["status"]["models"].array.contains { $0["id"] == "native-worker" })
        let calls = await f.http.captured(), mutations = calls.filter { $0.method == "POST" }.map { $0.url.path }
        XCTAssertEqual(mutations, ["/_uniapi/codex/control/drain", "/admin/drain", "/admin/resume", "/_uniapi/codex/control/resume"])
        XCTAssertEqual(f.commands.captured(), [["route", "disconnect"]]); assertNoReconnect(f)
    }

    func testNativeStatusCatalogAndSelectionHaveNoWebRequestsOrCLIRequirement() async throws {
        let f = try fixture(web: false); defer { try? FileManager.default.removeItem(at: f.root) }
        _ = try await f.manager.action("nativeConnect")
        try FileManager.default.removeItem(at: SwitcherDisk.bridgeHome(f.runtime.paths).appendingPathComponent("config.json"))
        await f.http.reset()
        let status = try await f.manager.status()
        XCTAssertEqual(status["catalog"]["owner"], "native"); XCTAssertEqual(status["catalog"]["supported"], true)
        XCTAssertEqual(status["bridge"]["healthDeferred"], true); XCTAssertTrue(status["bridge"]["running"].isNull)
        _ = try await f.manager.configureCatalog(["providerIds": ["fixture"], "workerModels": [.string(alias)]])
        let selected = try await f.manager.select(["source": "provider", "providerId": "fixture", "model": "api-model", "effort": "high"])
        XCTAssertEqual(selected["status"]["native"]["accepting"], true)
        let document = try document(f)
        XCTAssertEqual(document["model"], .string(alias)); XCTAssertNil(document["model_provider"])
        XCTAssertEqual(try f.store.catalog.read()["workerModels"], [.string(alias)])
        let calls = await f.http.captured()
        XCTAssertTrue(calls.allSatisfy { $0.url.port == 8823 }); XCTAssertTrue(f.commands.captured().isEmpty)
        XCTAssertEqual(calls.filter { $0.url.lastPathComponent == "drain" }.count, 2)
    }

    func testNativeOnlyPollingDoesNotProbeConfiguredButUnavailableOptionalWeb() async throws {
        let f = try fixture(web: false); defer { try? FileManager.default.removeItem(at: f.root) }
        _ = try await f.manager.action("nativeConnect"); await f.http.reset()
        await f.http.configure(webRunning: false)
        for _ in 0..<3 { _ = try await f.manager.status() }
        let calls = await f.http.captured(); XCTAssertTrue(calls.allSatisfy { $0.url.port == 8823 })
        await f.http.reset(); _ = try await f.manager.action("doctor")
        let checked = await f.http.captured()
        XCTAssertTrue(checked.contains { $0.url.port == 17841 && $0.url.path == "/healthz" })
        XCTAssertFalse(checked.contains { $0.url.path == "/uniapi/v1/models" })
    }

    func testBusyNativeDrainRefusesBeforeDisconnectOrConfigurationWrites() async throws {
        let f = try fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        let before = try SwitcherDisk.read(f.config)
        await f.http.configure(active: 1)
        do { _ = try await f.manager.action("nativeConnect"); XCTFail("Busy native route accepted") } catch {}
        XCTAssertEqual(try SwitcherDisk.read(f.config), before); XCTAssertTrue(f.commands.captured().isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: f.store.journalPath.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: f.store.catalog.file.path))
        let calls = await f.http.captured(); XCTAssertTrue(calls.contains { $0.url.path == "/_uniapi/codex/control/resume" })
    }

    func testBusyWebDrainResumesBothOwnersAndDoesNotDisconnect() async throws {
        let f = try fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        let before = try SwitcherDisk.read(f.config)
        await f.http.configure(webBusy: true)
        do { _ = try await f.manager.action("nativeConnect"); XCTFail("Busy Web handoff accepted") } catch {}
        XCTAssertEqual(try SwitcherDisk.read(f.config), before); XCTAssertTrue(f.commands.captured().isEmpty)
        let calls = await f.http.captured()
        XCTAssertTrue(calls.contains { $0.url.path == "/admin/resume" })
        XCTAssertTrue(calls.contains { $0.url.path == "/_uniapi/codex/control/resume" })
    }

    func testBusyNativeSelectionAndCatalogKeepExistingDefaultsAndMembership() async throws {
        let f = try fixture(web: false); defer { try? FileManager.default.removeItem(at: f.root) }
        _ = try await f.manager.action("nativeConnect")
        let before = try SwitcherDisk.read(f.config), membership = try SwitcherDisk.read(f.store.catalog.file)
        await f.http.configure(active: 1)
        do { _ = try await f.manager.select(["source": "subscription", "model": "native-worker", "effort": "max"]); XCTFail("Busy default changed") } catch {}
        do { _ = try await f.manager.configureCatalog(["providerIds": ["fixture"], "workerModels": [.string(alias)]]); XCTFail("Busy catalog changed") } catch {}
        XCTAssertEqual(try SwitcherDisk.read(f.config), before)
        XCTAssertEqual(try SwitcherDisk.read(f.store.catalog.file), membership)
        XCTAssertTrue(f.commands.captured().isEmpty)
    }

    func testResumeFailureDoesNotRollBackConnectedNativeOwnerOrReconnectWeb() async throws {
        let f = try fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        await f.http.configure(resumeFails: true)
        do { _ = try await f.manager.action("nativeConnect"); XCTFail("Uncertain admission reported success") } catch {}
        XCTAssertEqual(try f.store.status()["connected"], true)
        XCTAssertEqual(try document(f)["openai_base_url"], .string(try f.store.baseURL()))
        XCTAssertEqual(try document(f)["model"], .string(alias))
        XCTAssertEqual(try f.store.catalog.read(), choices)
        assertNoReconnect(f)
    }

    func testUnexpectedDefaultResetRefusesWithoutRepairOrAutomaticReconnect() async throws {
        let f = try fixture(mode: .resetDefault); defer { try? FileManager.default.removeItem(at: f.root) }
        do { _ = try await f.manager.action("nativeConnect"); XCTFail("Cross-journal default reset accepted") }
        catch { XCTAssertTrue(error.localizedDescription.contains("changed Codex defaults")) }
        XCTAssertNil(try document(f)["model"])
        XCTAssertFalse(FileManager.default.fileExists(atPath: f.store.journalPath.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: f.store.catalog.file.path))
        assertNoReconnect(f)
    }

    func testUncertainDisconnectNeverReconnectsOrClaimsNativeOwnership() async throws {
        let f = try fixture(mode: .failAfterDisconnect); defer { try? FileManager.default.removeItem(at: f.root) }
        do { _ = try await f.manager.action("nativeConnect"); XCTFail("Lost acknowledgement accepted") } catch {}
        XCTAssertNil(try document(f)["openai_base_url"]); XCTAssertEqual(try document(f)["model"], .string(alias))
        XCTAssertEqual(try f.store.status()["connected"], false); assertNoReconnect(f)
        XCTAssertFalse(FileManager.default.fileExists(atPath: f.store.catalog.file.path))
    }

    func testForeignTransportAndConcurrentNativeCatalogEditsArePreserved() async throws {
        for mode in [CodexManagerCommands.Mode.leaveForeignRoute, .changeCatalog] {
            let f = try fixture(mode: mode); defer { try? FileManager.default.removeItem(at: f.root) }
            do { _ = try await f.manager.action("nativeConnect"); XCTFail("Conflicting handoff accepted") } catch {}
            XCTAssertEqual(try f.store.status()["connected"], false); assertNoReconnect(f)
            if mode == .leaveForeignRoute { XCTAssertEqual(try document(f)["openai_base_url"], "https://foreign.invalid/v1") }
            else { XCTAssertEqual(try f.store.catalog.read(), ["providerIds": [], "workerModels": ["native-worker"]]) }
        }
    }

    func testWebWorkerOrWebDefaultRequiresExplicitChoiceBeforeDisconnect() async throws {
        for webDefault in [false, true] {
            let f = try fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
            if webDefault {
                let text = try NativeTOML.patchDefaults(SwitcherDisk.text(f.config), values: ["model": "chatgpt-web/high"])
                try NativeFile.writeAtomic(Data(text.utf8), to: f.config)
            } else { try f.bridgeCatalog.write(["providerIds": ["fixture"], "workerModels": ["chatgpt-web/high"]]) }
            let before = try SwitcherDisk.read(f.config)
            do { _ = try await f.manager.action("nativeConnect"); XCTFail("Unsupported Web selection silently migrated") } catch {}
            XCTAssertEqual(try SwitcherDisk.read(f.config), before); XCTAssertTrue(f.commands.captured().isEmpty)
        }
    }

    func testWebConnectCannotOverrideNativeOwnerAndRestoreReleasesRouteAndDefaults() async throws {
        let f = try fixture(web: false); defer { try? FileManager.default.removeItem(at: f.root) }
        _ = try await f.manager.action("nativeConnect")
        let before = try SwitcherDisk.read(f.config)
        do { _ = try await f.manager.action("connect"); XCTFail("Web overrode native owner") } catch {}
        XCTAssertEqual(try SwitcherDisk.read(f.config), before); XCTAssertTrue(f.commands.captured().isEmpty)
        _ = try await f.manager.select(["source": "subscription", "model": "native-worker", "effort": "max"])
        let restored = try await f.manager.action("restore"), document = try document(f)
        XCTAssertEqual(restored["status"]["native"]["connected"], false)
        XCTAssertNil(document["openai_base_url"]); XCTAssertNil(document["model"])
        XCTAssertEqual(document["hooks"]?["command"], "preserve")
        XCTAssertFalse(FileManager.default.fileExists(atPath: f.store.journalPath.path)); assertNoReconnect(f)
    }

    func testExternalDefaultEditBlocksRestoreBeforeReleasingRoute() async throws {
        let f = try fixture(web: false); defer { try? FileManager.default.removeItem(at: f.root) }
        _ = try await f.manager.action("nativeConnect")
        _ = try await f.manager.select(["source": "subscription", "model": "native-worker", "effort": "max"])
        let text = try NativeTOML.patchDefaults(SwitcherDisk.text(f.config), values: ["model": "operator-new-default"])
        try NativeFile.writeAtomic(Data(text.utf8), to: f.config)
        let before = try SwitcherDisk.read(f.config)
        do { _ = try await f.manager.action("restore"); XCTFail("External default overwritten") } catch {}
        XCTAssertEqual(try SwitcherDisk.read(f.config), before)
        XCTAssertEqual(try f.store.status()["connected"], true)
    }
}
