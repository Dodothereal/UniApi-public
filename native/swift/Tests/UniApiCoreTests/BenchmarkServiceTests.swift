import XCTest
import Darwin
@testable import UniApiCore

private actor BenchmarkFixtureHTTP: BenchmarkTransport {
    enum Mode { case normal, quirks, fallback, browserIncomplete, contextLimit, denied, limitedOnce, checkpoint, outputCap }
    let mode: Mode
    var requests: [BenchmarkRequest] = []
    var active: [String: Int] = [:], maximum: [String: Int] = [:]
    var blocked = false
    var overallMaximum = 0
    var began: (@Sendable () -> Void)?
    init(_ mode: Mode = .normal, began: (@Sendable () -> Void)? = nil) { self.mode = mode; self.began = began }
    func execute(_ request: BenchmarkRequest) async throws -> BenchmarkResponse {
        requests.append(request); let sequence = requests.count, host = request.url.host ?? "fixture"
        active[host, default: 0] += 1; maximum[host] = max(maximum[host] ?? 0, active[host]!)
        overallMaximum = max(overallMaximum, active.values.reduce(0, +))
        defer { active[host, default: 1] -= 1 }
        try await Task.sleep(nanoseconds: 1_000_000)
        if request.url.path.hasSuffix("/models") {
            let value: JSONValue = ["data": [["id": "fixture-model", "context_length": 65536], ["id": "browser-mode", "available": true, "name": "Browser mode"], ["id": "unavailable", "available": false, "reason": "fixture unavailable"]]]
            return .init(chunks: [.init(milliseconds: 1, data: try value.encoded())])
        }
        let body = try JSONValue.decode(request.body ?? Data())
        func failure(_ status: Int, _ text: String) -> BenchmarkResponse { .init(status: status, chunks: [.init(milliseconds: 1, data: Data(text.utf8))]) }
        if mode == .denied { return failure(429, "model_requires_purchase: locked") }
        if mode == .limitedOnce && sequence == 1 { return failure(429, "temporary rate limit") }
        if request.url.path.hasSuffix("/messages") { let value: JSONValue = ["content": [["type": "text", "text": "hi"]]]; return .init(chunks: [.init(milliseconds: 50, data: try value.encoded())]) }
        if body["stream"] == false && (body["max_tokens"] == 8 || body["max_completion_tokens"] == 8) {
            let value: JSONValue = ["choices": [["message": ["content": "hi"]]]]
            return .init(chunks: [.init(milliseconds: 50, data: try value.encoded())])
        }
        if mode == .quirks {
            if !body["stream_options"].isNull { return failure(400, "stream_options unsupported") }
            if !body["max_tokens"].isNull { return failure(400, "max_completion_tokens required; max_tokens unsupported") }
            if !body["temperature"].isNull { return failure(400, "temperature unsupported") }
        }
        if mode == .fallback && body["model"] == "qwen3.8-max" { return failure(402, "Insufficient balance") }
        if mode == .outputCap && body["max_tokens"].int > 512 { return failure(400, "max_tokens must be at most 512") }
        let content = body["messages"].array.first?["content"].string ?? ""
        if mode == .contextLimit && Double(content.count) * 0.22 > 20_000 { return failure(400, "maximum context length exceeded") }
        if mode == .checkpoint && sequence == 3 && !blocked { blocked = true; began?(); try await Task.sleep(nanoseconds: 30_000_000_000) }
        let input = max(1, Double(content.count) * 0.22)
        let first: JSONValue = ["choices": [["delta": ["content": "first "]]]]
        let last: JSONValue = ["choices": [["delta": ["content": "second third fourth"], "finish_reason": "stop"]], "usage": ["prompt_tokens": .number(input), "completion_tokens": 20, "completion_tokens_details": ["reasoning_tokens": 5], "prompt_tokens_details": ["cached_tokens": 3]], "uniapi": ["observed_browser_mode": "fixture", "estimated_usage": true, "cookie": "must-not-persist"]]
        return .init(chunks: [.init(milliseconds: 100, data: Data(("data: " + String(decoding: try first.encoded(), as: UTF8.self) + "\n\n").utf8)), .init(milliseconds: 300, data: Data(("data: " + String(decoding: try last.encoded(), as: UTF8.self) + (mode == .browserIncomplete ? "\n\n" : "\n\ndata: [DONE]\n\n")).utf8))], timing: ["t_total": 0.4])
    }
    func captured() -> [BenchmarkRequest] { requests }
    func maximumConcurrency() -> [String: Int] { maximum }
    func overallConcurrency() -> Int { overallMaximum }
}

final class BenchmarkServiceTests: XCTestCase {
    private func fixture(_ http: BenchmarkFixtureHTTP = BenchmarkFixtureHTTP(), providers: [JSONValue]? = nil,
                         bridge: (@Sendable (NativePaths) throws -> BenchmarkConnection)? = nil) throws -> (URL, NativeRuntime, NativeBenchmarkService) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("benchmark-" + UUID().uuidString)
        let runtime = try NativeRuntime(paths: NativePaths(root: root, home: root.appendingPathComponent("fixture-home")))
        let configured = providers ?? [["id": "fixture", "name": "Fixture", "base_url": "https://fixture.invalid/v1", "api_key": "fixture-key", "proxy": ["format": "openai", "models": ["fixture-model"]]]]
        try NativeFile.writeAtomic(try JSONValue.object(["settings": ["request_delay_s": 0], "providers": .array(configured)]).encoded(), to: runtime.paths.providers)
        let dependencies = BenchmarkDependencies(transport: http, now: { Date(timeIntervalSince1970: 1_791_626_400) }, sleep: { _ in try Task.checkCancellation() }, bridge: bridge, legacySelection: { _ in nil }, notify: { _, _ in }, schedulingEnabled: false)
        return (root, runtime, NativeBenchmarkService(runtime: runtime, dependencies: dependencies))
    }
    private func wait(_ runtime: NativeRuntime, _ job: JSONValue) async throws -> JSONValue {
        for _ in 0..<2000 {
            if let row = try await runtime.jobs.get(job["id"].string), !["running", "queued"].contains(row["status"]?.string ?? "") { return .object(row) }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        throw NativeFailure("Fixture job did not settle")
    }
    private func run(_ service: NativeBenchmarkService, tier: String = "quick", model: String = "fixture-model", provider: String = "fixture", resume: String? = nil) async throws -> JSONValue {
        var value: JSONObject = ["tier": .string(tier), "pairs": [["provider": .string(provider), "model": .string(model)]]]
        if let resume { value["resumeRun"] = .string(resume) }
        return try await service.handle("run", input: value)
    }
    func testQuickBatteryPersistsProgressBothHistoriesUsageAndPreferences() async throws {
        let (root, runtime, service) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        _ = try await service.handle("saveSelection", input: ["included": ["fixture"], "models": ["fixture": ["fixture-model"]], "tier": "quick"])
        let selected = try await service.handle("selection"); XCTAssertEqual(selected["tier"], "quick")
        let accepted = try await run(service), job = try await wait(runtime, accepted["job"])
        XCTAssertEqual(job["status"], "done")
        let summary = try await service.handle("summary", input: ["scope": accepted["run_id"]])
        XCTAssertEqual(summary["rows"], 5); XCTAssertEqual(summary["cells"]["fixture|fixture-model"]["throughput"]["decode_tps"], 95)
        let raw = try await service.handle("rows", input: ["scope": accepted["run_id"]]); XCTAssertEqual(raw.array.filter { $0["test"] == "context" }.count, 3)
        let progress = try await service.handle("progress"); XCTAssertTrue(progress["progress"]["done"].bool); XCTAssertEqual(progress["progress"]["pairs"]["fixture|fixture-model"]["done"], 5)
        try NativeFile.writeAtomic(try raw.array[0].encoded() + Data("\n".utf8), to: runtime.paths.data.appendingPathComponent("results.jsonl"))
        let usage = try await service.handle("usage"); XCTAssertEqual(usage["calls"], 5); XCTAssertEqual(usage["output"], 100); XCTAssertEqual(usage["reasoning"], 25); XCTAssertEqual(usage["cached"], 15)
        let restarted = NativeBenchmarkService(runtime: runtime, dependencies: BenchmarkDependencies(transport: BenchmarkFixtureHTTP(), legacySelection: { _ in nil }, notify: { _, _ in }, schedulingEnabled: false))
        let restored = try await restarted.handle("selection"); XCTAssertEqual(restored, selected)
    }
    func testQuirksAndFallbackAreRecordedWithoutChangingProvider() async throws {
        let http = BenchmarkFixtureHTTP(.quirks), (root, runtime, service) = try fixture(http); defer { try? FileManager.default.removeItem(at: root) }
        let accepted = try await run(service); let settled1 = try await wait(runtime, accepted["job"]); XCTAssertEqual(settled1["status"], "done")
        let quirks = try NativeFile.readJSON(runtime.paths.bench.appendingPathComponent("state/quirks.json"))["fixture|fixture-model"]
        XCTAssertTrue(quirks["no_stream_options"].bool); XCTAssertTrue(quirks["use_mct"].bool); XCTAssertTrue(quirks["no_temperature"].bool)
        let requests = await http.captured(); XCTAssertEqual(requests.count, 8)
        let body = try JSONValue.decode(requests.last!.body!); XCTAssertTrue(body["temperature"].isNull); XCTAssertFalse(body["max_completion_tokens"].isNull)
        let fallbackHTTP = BenchmarkFixtureHTTP(.fallback), (otherRoot, otherRuntime, other) = try fixture(fallbackHTTP); defer { try? FileManager.default.removeItem(at: otherRoot) }
        try NativeFile.writeAtomic(try JSONValue.object(["fixture": ["ids": ["qwen3.8-max", "qwen3.8-max-free"]]]).encoded(), to: otherRuntime.paths.data.appendingPathComponent("models.json"))
        let fallback = try await run(other, model: "qwen3.8-max"); let settled2 = try await wait(otherRuntime, fallback["job"]); XCTAssertEqual(settled2["status"], "done")
        let rows = try await other.handle("rows"); XCTAssertEqual(rows.array.count, 6); XCTAssertTrue(rows.array.allSatisfy { $0["provider"] == "fixture" }); XCTAssertEqual(rows.array.filter { $0["ok"].bool }.first?["model"], "qwen3.8-max-free")
    }
    func testDeepContextProbePersistsEveryBoundAndSummary() async throws {
        let (root, runtime, service) = try fixture(BenchmarkFixtureHTTP(.contextLimit)); defer { try? FileManager.default.removeItem(at: root) }
        let accepted = try await run(service, tier: "deep"); let settled3 = try await wait(runtime, accepted["job"]); XCTAssertEqual(settled3["status"], "done")
        let rows = try await service.handle("rows"), summary = try XCTUnwrap(rows.array.first { $0["test"] == "max_context" })
        XCTAssertGreaterThan(summary["extra"]["max_ok_requested"].int, 16384); XCTAssertLessThanOrEqual(summary["extra"]["max_ok_requested"].int, 20000)
        XCTAssertGreaterThan(summary["extra"]["min_fail_requested"].int, summary["extra"]["max_ok_requested"].int)
        XCTAssertGreaterThan(rows.array.filter { $0["test"] == "context_probe" }.count, 1)
        XCTAssertFalse(summary["extra"]["inconclusive"].bool)
    }
    func testBrowserCapabilityNeverUsesProviderEditableURLOrTrainsCalibration() async throws {
        let http = BenchmarkFixtureHTTP(), browser: JSONValue = ["id": "browser", "name": "Browser", "transport": "chatgpt-web", "base_url": "https://must-not-receive.invalid", "models": ["browser-mode"]]
        let (root, runtime, service) = try fixture(http, providers: [browser], bridge: { _ in .init(baseURL: URL(string: "http://127.0.0.1:17841/uniapi/v1")!, key: "private-fixture-capability") }); defer { try? FileManager.default.removeItem(at: root) }
        _ = try await service.handle("discover", input: ["provider": "browser"])
        let catalog = try await service.handle("catalog"), provider = catalog["providers"].array[0]
        XCTAssertEqual(provider["maskedKey"], ""); XCTAssertFalse(provider["hasKey"].bool); XCTAssertFalse(provider["capabilities"]["maxOutput"].bool)
        let accepted = try await run(service, model: "browser-mode", provider: "browser"); let settled4 = try await wait(runtime, accepted["job"]); XCTAssertEqual(settled4["status"], "done")
        let rows = try await service.handle("rows"); XCTAssertEqual(rows.array.count, 5)
        XCTAssertTrue(rows.array.allSatisfy { $0["tokens"]["in_est"].bool && $0["tokens"]["out_est"].bool && $0["tps"]["prefill"].isNull && $0["req"]["max_tokens"].isNull && $0["tokens"]["reasoning"].isNull })
        XCTAssertFalse(rows.array.contains { $0["test"] == "maxout" || $0["test"] == "vision" })
        let calibration = try NativeFile.readJSON(runtime.paths.bench.appendingPathComponent("state/calib.json")); XCTAssertTrue(calibration.object.isEmpty)
        for request in await http.captured() {
            XCTAssertEqual(request.url.host, "127.0.0.1")
            if let data = request.body { let body = try JSONValue.decode(data); XCTAssertTrue(body["max_tokens"].isNull); XCTAssertTrue(body["temperature"].isNull) }
        }
        let ledger = try String(contentsOf: runtime.paths.bench.appendingPathComponent("results/results.jsonl"), encoding: .utf8)
        XCTAssertFalse(ledger.contains("private-fixture-capability")); XCTAssertFalse(ledger.contains("must-not-persist"))
        do { _ = try await service.handle("key", input: ["provider": "browser"]); XCTFail("private browser key exposed") } catch {}
    }
    func testIncompleteBrowserStreamStopsWithoutRetryOrFallback() async throws {
        let http = BenchmarkFixtureHTTP(.browserIncomplete), browser: JSONValue = ["id": "browser", "name": "Browser", "transport": "chatgpt-web", "models": ["browser-mode"]]
        let (root, runtime, service) = try fixture(http, providers: [browser], bridge: { _ in .init(baseURL: URL(string: "http://127.0.0.1:17841/uniapi/v1")!, key: "fixture") }); defer { try? FileManager.default.removeItem(at: root) }
        _ = try await service.handle("discover", input: ["provider": "browser"])
        let accepted = try await run(service, model: "browser-mode", provider: "browser"); _ = try await wait(runtime, accepted["job"])
        let rows = try await service.handle("rows"), requests = await http.captured()
        XCTAssertEqual(rows.array.count, 1); XCTAssertEqual(requests.count, 2); XCTAssertEqual(rows.array[0]["error_class"], "incomplete_stream"); XCTAssertFalse(rows.array[0]["ok"].bool)
    }
    func testFreeTestStructuralCutoffAndRateRetryAndParallelProviders() async throws {
        let http = BenchmarkFixtureHTTP(.denied), ids = (0..<55).map { JSONValue.string("model-\($0)") }
        let providers: [JSONValue] = [["id": "fixture", "name": "Fixture", "base_url": "https://fixture.invalid/v1", "api_key": "fixture", "proxy": ["format": "openai", "models": .array(ids)]]]
        let (root, runtime, service) = try fixture(http, providers: providers); defer { try? FileManager.default.removeItem(at: root) }
        let accepted = try await service.handle("freeTest"); let settled5 = try await wait(runtime, accepted["job"]); XCTAssertEqual(settled5["status"], "done")
        let report = try await service.handle("freeTestReport"), requests = await http.captured()
        XCTAssertEqual(requests.count, 40); XCTAssertEqual(report["report"]["done"], 55); XCTAssertEqual(report["report"]["rows"].array.filter { $0["outcome"] == "skipped" }.count, 15)
        let limits = BenchmarkFixtureHTTP(.limitedOnce), (secondRoot, secondRuntime, second) = try fixture(limits); defer { try? FileManager.default.removeItem(at: secondRoot) }
        let retry = try await second.handle("freeTest"); _ = try await wait(secondRuntime, retry["job"])
        let outcomes = try await second.handle("freeTestReport"), retried = await limits.captured(); XCTAssertEqual(retried.count, 2); XCTAssertEqual(outcomes["report"]["rows"].array.first?["outcome"], "works")
        XCTAssertTrue(retried.allSatisfy { $0.url.host == "127.0.0.1" && $0.url.path == "/fixture/v1/messages" && $0.timeout == 15 })
        let anthropic: JSONValue = ["id": "fixture", "base_url": "https://anthropic.fixture.invalid", "api_key": "fixture-key", "proxy": ["format": "anthropic", "models": ["fixture-model"]]]
        let nativeHTTP = BenchmarkFixtureHTTP(), (thirdRoot, thirdRuntime, third) = try fixture(nativeHTTP, providers: [anthropic]); defer { try? FileManager.default.removeItem(at: thirdRoot) }
        let nativeProbe = try await third.handle("freeTest"); _ = try await wait(thirdRuntime, nativeProbe["job"])
        let nativeRequests = await nativeHTTP.captured(); XCTAssertEqual(nativeRequests.first?.url.host, "127.0.0.1"); XCTAssertEqual(nativeRequests.first?.url.path, "/fixture/v1/messages")
        let nativeReport = try await third.handle("freeTestReport"); XCTAssertEqual(nativeReport["report"]["rows"].array.first?["outcome"], "works")
    }
    func testCancellationCheckpointAndExplicitResumeSkipPaidUnits() async throws {
        let began = expectation(description: "third fixture request began"), http = BenchmarkFixtureHTTP(.checkpoint, began: { began.fulfill() })
        let (root, runtime, service) = try fixture(http); defer { try? FileManager.default.removeItem(at: root) }
        let accepted = try await run(service); await fulfillment(of: [began], timeout: 3)
        _ = try await service.handle("stop", input: ["jobId": accepted["job"]["id"]])
        let settled6 = try await wait(runtime, accepted["job"]); XCTAssertEqual(settled6["status"], "cancelled")
        let before = try await service.handle("rows"); XCTAssertEqual(before.array.count, 2)
        let progress = try await service.handle("progress"); XCTAssertTrue(progress["resumeAvailable"].bool)
        var interrupted = progress["progress"]; interrupted["done"] = false; interrupted["aborted"] = false
        try NativeFile.writeAtomic(try interrupted.encoded(), to: runtime.paths.bench.appendingPathComponent("state/progress.json"))
        let recovered = try await service.handle("progress"); XCTAssertTrue(recovered["interrupted"].bool); XCTAssertTrue(recovered["resumeAvailable"].bool)
        let resumed = try await service.handle("resume", input: ["run_id": accepted["run_id"]]); let settled7 = try await wait(runtime, resumed["job"]); XCTAssertEqual(settled7["status"], "done")
        let after = try await service.handle("rows"), requests = await http.captured(); XCTAssertEqual(after.array.count, 5); XCTAssertEqual(requests.count, 6)
        XCTAssertEqual(Set(after.array.map { $0["unit_id"].string }).count, 5)
    }
    func testProviderModelsRunSequentiallyAndDifferentProvidersOverlapSafely() async throws {
        let http = BenchmarkFixtureHTTP(), providers: [JSONValue] = ["one", "two"].map { id in ["id": .string(id), "name": .string(id), "base_url": .string("https://\(id).fixture.invalid/v1"), "api_key": "fixture", "proxy": ["format": "openai", "models": ["m1", "m2"]]] }
        let (root, runtime, service) = try fixture(http, providers: providers); defer { try? FileManager.default.removeItem(at: root) }
        let accepted = try await service.handle("run", input: ["tier": "quick", "pairs": [["provider": "one", "model": "m1"], ["provider": "one", "model": "m2"], ["provider": "two", "model": "m1"]]])
        _ = try await wait(runtime, accepted["job"])
        let maximum = await http.maximumConcurrency(), rows = try await service.handle("rows")
        XCTAssertEqual(maximum["one.fixture.invalid"], 1); XCTAssertEqual(maximum["two.fixture.invalid"], 1); XCTAssertEqual(rows.array.count, 15)
        let parallel = await http.overallConcurrency(); XCTAssertGreaterThan(parallel, 1)
    }
    func testScheduleValidationCatchupAndEnablingSkipsPastSlot() async throws {
        XCTAssertTrue(NativeBenchmarkService.validTime("04:00")); XCTAssertFalse(NativeBenchmarkService.validTime("24:00")); XCTAssertFalse(NativeBenchmarkService.validTime("4:00"))
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let now = Date(timeIntervalSince1970: 1_791_626_400), enabled: JSONValue = ["enabled": true, "time": "04:00", "lastRun": .null]
        XCTAssertTrue(NativeBenchmarkService.scheduleDue(enabled, now: now, calendar: calendar))
        let (root, _, service) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let saved = try await service.handle("saveSchedule", input: ["enabled": true, "time": "04:00"])
        XCTAssertFalse(NativeBenchmarkService.scheduleDue(saved, now: now, calendar: calendar))
    }
    func testPrivateResolverOnlyUsesFixtureHomeAndRefusesNonloopback() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString), paths = NativePaths(root: root, home: root)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent(".codex-chatgpt-web/config.json"), key = String(repeating: "fixture", count: 8)
        try NativeFile.writeAtomic(try JSONValue.object(["host": "127.0.0.1", "port": 17841, "uniapiInferenceToken": .string(key)]).encoded(), to: file)
        let connection = try BenchmarkPrivateBridge.resolve(paths); XCTAssertEqual(connection.key, key); XCTAssertEqual(connection.baseURL.host, "127.0.0.1")
        try NativeFile.writeAtomic(try JSONValue.object(["host": "remote.invalid", "port": 17841, "uniapiInferenceToken": .string(key)]).encoded(), to: file)
        XCTAssertThrowsError(try BenchmarkPrivateBridge.resolve(paths))
    }
    func testDeepBrowserBoundsRemainEstimatedAndExcludeSyntheticSummaryFromUsage() async throws {
        let http = BenchmarkFixtureHTTP(.contextLimit), browser: JSONValue = ["id": "browser", "transport": "chatgpt-web", "models": ["browser-mode"]]
        let (root, runtime, service) = try fixture(http, providers: [browser], bridge: { _ in .init(baseURL: URL(string: "http://127.0.0.1:17841/uniapi/v1")!, key: "fixture-capability") }); defer { try? FileManager.default.removeItem(at: root) }
        _ = try await service.handle("discover", input: ["provider": "browser"])
        let accepted = try await run(service, tier: "deep", model: "browser-mode", provider: "browser"), settled = try await wait(runtime, accepted["job"])
        XCTAssertEqual(settled["status"], "done")
        let rows = try await service.handle("rows"), bounds = try XCTUnwrap(rows.array.first { $0["test"] == "max_context" })
        XCTAssertTrue(bounds["tokens"]["in_est"].bool); XCTAssertTrue(bounds["tokens"]["out_est"].bool)
        XCTAssertEqual(bounds["extra"]["context_measurement"], "browser_accepted_input"); XCTAssertTrue(bounds["extra"]["measured_prompt_tokens"].isNull)
        XCTAssertFalse(rows.array.contains { $0["test"] == "maxout" || $0["test"] == "vision" })
        let usage = try await service.handle("usage"); XCTAssertEqual(usage["calls"].int, rows.array.count - 1)
        let curves = try await service.handle("curves", input: ["scope": accepted["run_id"]]); XCTAssertEqual(curves.array.count, 1); XCTAssertEqual(curves.array[0]["test"], "throughput")
    }
    func testVisionAndMaximumOutputCapAdaptation() async throws {
        let http = BenchmarkFixtureHTTP(.outputCap), (root, runtime, service) = try fixture(http); defer { try? FileManager.default.removeItem(at: root) }
        let accepted = try await run(service, tier: "standard", model: "fixture-vision"), settled = try await wait(runtime, accepted["job"])
        XCTAssertEqual(settled["status"], "done")
        let rows = try await service.handle("rows"), maxout = try XCTUnwrap(rows.array.first { $0["test"] == "maxout" && $0["ok"].bool })
        XCTAssertEqual(maxout["extra"]["requested_cap"], 4096); XCTAssertEqual(maxout["extra"]["allowed_cap"], 512)
        let vision = try XCTUnwrap(rows.array.first { $0["test"] == "vision" }); XCTAssertTrue(vision["ok"].bool)
        let bodies = try await http.captured().compactMap { try $0.body.map(JSONValue.decode) }
        XCTAssertTrue(bodies.contains { $0["messages"].array.first?["content"].array.last?["image_url"]["url"].string.hasPrefix("data:image/png;base64,") == true })
    }
    func testProviderEditPreservesRoutesAndBrowserCredentialsCannotBeEdited() async throws {
        let (root, runtime, service) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let original = try runtime.providers.list()[0]
        _ = try await service.handle("updateProvider", input: ["provider": "fixture", "name": "New fixture", "baseUrl": "https://new.fixture.invalid/v1/", "apiKey": "new-fixture-key"])
        let changed = try runtime.providers.list()[0]
        XCTAssertEqual(changed["proxy"], original["proxy"]); XCTAssertEqual(changed["base_url"], "https://new.fixture.invalid/v1"); XCTAssertEqual(changed["api_key"], "new-fixture-key")
        let browser: JSONValue = ["id": "browser", "transport": "chatgpt-web", "models": ["browser-mode"]]
        try runtime.providers.mutate { $0["providers"] = [browser] }
        do { _ = try await service.handle("updateProvider", input: ["provider": "browser", "name": "Browser", "baseUrl": "https://fixture.invalid", "apiKey": "leak"]); XCTFail("browser credential replaced") } catch {}
        XCTAssertTrue(try runtime.providers.list()[0]["api_key"]?.isNull ?? true)
    }
    func testBenchLedgerRejectsFIFOWithoutWaitingForAReader() async throws {
        let (root, runtime, _) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let file = runtime.paths.bench.appendingPathComponent("results/results.jsonl")
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        XCTAssertEqual(mkfifo(file.path, 0o600), 0)
        let store = BenchmarkStore(paths: runtime.paths)
        do { try await store.append(["id": "fixture"]); XCTFail("FIFO ledger accepted") } catch {}
        do { _ = try await store.rows(); XCTFail("FIFO history accepted") } catch {}
        let config = runtime.paths.bench.appendingPathComponent("state/fixture.json")
        try FileManager.default.createDirectory(at: config.deletingLastPathComponent(), withIntermediateDirectories: true)
        XCTAssertEqual(mkfifo(config.path, 0o600), 0)
        let unavailable = await store.state("fixture", fallback: "unavailable"); XCTAssertEqual(unavailable, "unavailable")
    }
}
