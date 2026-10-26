import XCTest
@testable import UniApiCore

private actor BenchmarkParityTransport: BenchmarkTransport {
    enum Mode { case success, brokenShim, retry, refuse, holdSecond }
    let mode: Mode
    let entered: (@Sendable () -> Void)?
    var requests: [BenchmarkRequest] = []
    var cleanup = false
    init(_ mode: Mode = .success, entered: (@Sendable () -> Void)? = nil) { self.mode = mode; self.entered = entered }
    func execute(_ request: BenchmarkRequest) async throws -> BenchmarkResponse {
        requests.append(request)
        if mode == .holdSecond && requests.count == 2 {
            entered?(); defer { cleanup = true }; try await Task.sleep(nanoseconds: 30_000_000_000)
        }
        func response(_ status: Int, _ value: JSONValue) throws -> BenchmarkResponse { .init(status: status, chunks: [.init(milliseconds: 10, data: try value.encoded())]) }
        if mode == .brokenShim && request.url.host == "127.0.0.1" { return try response(503, ["error": ["message": "shim unavailable"]]) }
        if mode == .refuse { return try response(401, ["error": ["message": "fixture-secret\nrefused"]]) }
        if mode == .retry && requests.count == 1 { return try response(429, ["error": ["message": "temporary fixture-secret\nrate limit"]]) }
        let body = try JSONValue.decode(request.body ?? Data())
        if body["stream"] != true { return try response(200, ["content": [["type": "text", "text": "hi"]], "choices": [["message": ["content": "direct endpoint works"]]]]) }
        let first: JSONValue = ["choices": [["delta": ["content": "first "]]]]
        let last: JSONValue = ["choices": [["delta": ["content": "second"], "finish_reason": "stop"]], "usage": ["prompt_tokens": 100, "completion_tokens": 20]]
        return .init(chunks: [.init(milliseconds: 100, data: Data(("data: " + String(decoding: try first.encoded(), as: UTF8.self) + "\n\n").utf8)), .init(milliseconds: 300, data: Data(("data: " + String(decoding: try last.encoded(), as: UTF8.self) + "\n\ndata: [DONE]\n\n").utf8))], timing: ["t_total": 0.4])
    }
    func captured() -> [BenchmarkRequest] { requests }
    func cleaned() -> Bool { cleanup }
}

final class BenchmarkParityTests: XCTestCase {
    private func fixture(_ http: BenchmarkParityTransport, providers: [JSONValue]? = nil) throws -> (URL, NativeRuntime, NativeBenchmarkService) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("benchmark-parity-" + UUID().uuidString)
        let runtime = try NativeRuntime(paths: NativePaths(root: root, home: root.appendingPathComponent("fixture-home")))
        let provider: JSONValue = ["id": "fixture", "name": "Fixture", "base_url": "https://upstream.fixture.invalid", "api_key": "fixture-secret", "proxy": ["format": "openai", "models": ["one", "two"], "model": "one"]]
        try NativeFile.writeAtomic(try JSONValue.object(["providers": .array(providers ?? [provider]), "settings": ["request_delay_s": 0]]).encoded(), to: runtime.paths.providers)
        return (root, runtime, NativeBenchmarkService(runtime: runtime, dependencies: .init(transport: http, sleep: { _ in try Task.checkCancellation() }, legacySelection: { _ in nil }, notify: { _, _ in }, schedulingEnabled: false)))
    }
    private func wait(_ runtime: NativeRuntime, _ id: String) async throws -> JSONValue {
        for _ in 0..<1000 { if let row = try await runtime.jobs.get(id), !["queued", "running"].contains(row["status"]?.string ?? "") { return .object(row) }; try await Task.sleep(nanoseconds: 2_000_000) }
        throw NativeFailure("Fixture job did not drain")
    }
    func testFreeTestUsesActualClaudeRouteEvenWhenDirectUpstreamWorks() async throws {
        let http = BenchmarkParityTransport(.brokenShim), (root, runtime, service) = try fixture(http); defer { try? FileManager.default.removeItem(at: root) }
        let accepted = try await service.handle("freeTest"), job = try await wait(runtime, accepted["job"]["id"].string)
        XCTAssertEqual(job["status"], "done")
        let report = try await service.handle("freeTestReport"), requests = await http.captured()
        XCTAssertEqual(requests.count, 2); XCTAssertTrue(report["report"]["rows"].array.allSatisfy { $0["outcome"] == "failed" })
        for request in requests {
            XCTAssertEqual(request.url.absoluteString, "http://127.0.0.1:8823/fixture/v1/messages"); XCTAssertEqual(request.timeout, 15)
            XCTAssertEqual(request.headers["x-api-key"], "fixture-secret"); XCTAssertEqual(request.headers["anthropic-version"], "2023-06-01")
            let body = try JSONValue.decode(request.body!); XCTAssertEqual(body["max_tokens"], 8); XCTAssertEqual(body["messages"].array.first?["content"], "Say hi.")
        }
    }
    func testFreeTestDirectRouteAndKeylessShimPreserveActualWireAndDisabledSkip() async throws {
        let rows: [JSONValue] = [
            ["id": "direct", "base_url": "https://unused.fixture.invalid", "api_key": "fixture-secret", "proxy": ["format": "anthropic", "direct_url": "https://direct.fixture.invalid/v1", "models": ["one"]]],
            ["id": "keyless", "base_url": "https://unused.fixture.invalid", "api_key": "", "proxy": ["format": "openai", "models": ["one"]]],
            ["id": "disabled", "base_url": "https://unused.fixture.invalid", "api_key": "fixture-secret", "disabled": true, "proxy": ["format": "openai", "models": ["one"]]]]
        let http = BenchmarkParityTransport(), (root, runtime, service) = try fixture(http, providers: rows); defer { try? FileManager.default.removeItem(at: root) }
        let accepted = try await service.handle("freeTest"); _ = try await wait(runtime, accepted["job"]["id"].string)
        let requests = await http.captured(), report = try await service.handle("freeTestReport")
        XCTAssertEqual(requests.count, 2)
        XCTAssertEqual(requests.first { $0.url.host == "direct.fixture.invalid" }?.url.path, "/v1/messages")
        XCTAssertEqual(requests.first { $0.url.host == "127.0.0.1" }?.headers["x-api-key"], "shim")
        XCTAssertEqual(report["report"]["rows"].array.first { $0["provider"] == "disabled" }?["outcome"], "skipped")
    }
    func testFreeTestInvalidRouteAndEmptyModelBecomePerModelFailuresWhileHealthyProviderCompletes() async throws {
        let providers: [JSONValue] = [
            ["id": "malformed", "api_key": "fixture-secret", "proxy": ["format": "anthropic", "direct_url": "not-a-url", "models": ["one", "two"]]],
            ["id": "empty-model", "api_key": "", "proxy": ["format": "anthropic", "direct_url": "https://empty.fixture.invalid", "models": [""]]],
            ["id": "healthy", "api_key": "", "proxy": ["format": "anthropic", "direct_url": "https://healthy.fixture.invalid", "models": ["good"]]]]
        let http = BenchmarkParityTransport(), (root, runtime, service) = try fixture(http, providers: providers)
        defer { try? FileManager.default.removeItem(at: root) }
        let accepted = try await service.handle("freeTest"), job = try await wait(runtime, accepted["job"]["id"].string)
        let report = try await service.handle("freeTestReport")["report"], rows = report["rows"].array, calls = await http.captured()
        XCTAssertEqual(job["status"], "done"); XCTAssertEqual(report["cancelled"], false)
        XCTAssertEqual(report["total"], 4); XCTAssertEqual(report["done"], 4); XCTAssertEqual(rows.count, 4)
        XCTAssertFalse(report["finishedAt"].isNull)
        XCTAssertEqual(Set(rows.filter { $0["provider"] == "malformed" }.map { $0["model"].string }), ["one", "two"])
        XCTAssertTrue(rows.filter { $0["provider"] != "healthy" }.allSatisfy { $0["outcome"] == "failed" && !$0["message"].string.isEmpty })
        XCTAssertEqual(rows.first { $0["provider"] == "healthy" }?["outcome"], "works")
        XCTAssertEqual(calls.count, 1); XCTAssertEqual(calls.first?.url.host, "healthy.fixture.invalid")
        XCTAssertFalse(String(decoding: try report.encoded(), as: UTF8.self).contains("fixture-secret"))
    }
    func testFreeTestCancellationRetainsPartialReportAndAwaitsHeldRouteCleanup() async throws {
        let entered = expectation(description: "second route held"), http = BenchmarkParityTransport(.holdSecond, entered: { entered.fulfill() })
        let (root, runtime, service) = try fixture(http); defer { try? FileManager.default.removeItem(at: root) }
        let accepted = try await service.handle("freeTest"); await fulfillment(of: [entered], timeout: 2)
        _ = try await service.handle("stop", input: ["jobId": accepted["job"]["id"]])
        let job = try await wait(runtime, accepted["job"]["id"].string), cleaned = await http.cleaned(), report = try await service.handle("freeTestReport")
        XCTAssertEqual(job["status"], "cancelled"); XCTAssertTrue(cleaned); XCTAssertTrue(report["report"]["cancelled"].bool); XCTAssertEqual(report["report"]["done"], 1)
    }
    func testPersistentRunDiagnosticsRetainSuccessRefusalRetryAndRedaction() async throws {
        for mode in [BenchmarkParityTransport.Mode.success, .refuse, .retry] {
            let http = BenchmarkParityTransport(mode), (root, runtime, service) = try fixture(http); defer { try? FileManager.default.removeItem(at: root) }
            let accepted = try await service.handle("run", input: ["tier": "quick", "pairs": [["provider": "fixture", "model": "one"]]])
            let job = try await wait(runtime, accepted["job"]["id"].string), text = job["log"].array.map(\.string).joined(separator: "\n")
            XCTAssertEqual(job["status"], "done"); XCTAssertTrue(text.contains("Starting fixture / one")); XCTAssertTrue(text.contains("finished: 5 recorded tests")); XCTAssertFalse(text.contains("fixture-secret"))
            XCTAssertTrue(job["log"].array.allSatisfy { !$0.string.contains("\n") && $0.string.count <= 300 })
            if mode == .refuse { XCTAssertTrue(text.contains("auth HTTP 401")); XCTAssertTrue(text.contains("<redacted>")) }
            if mode == .retry { XCTAssertTrue(text.contains("Retry fixture / one")) }
            let progress = try await service.handle("progress"); XCTAssertEqual(progress["job"]["status"], "done"); XCTAssertEqual(progress["job"]["log"], job["log"])
        }
    }
    func testRunCancellationWritesFinalDiagnosticAfterOwnedCleanup() async throws {
        let entered = expectation(description: "benchmark request held"), http = BenchmarkParityTransport(.holdSecond, entered: { entered.fulfill() })
        let (root, runtime, service) = try fixture(http); defer { try? FileManager.default.removeItem(at: root) }
        let accepted = try await service.handle("run", input: ["tier": "quick", "pairs": [["provider": "fixture", "model": "one"]]])
        await fulfillment(of: [entered], timeout: 2); _ = try await service.handle("stop", input: ["jobId": accepted["job"]["id"]])
        let job = try await wait(runtime, accepted["job"]["id"].string), cleanup = await http.cleaned()
        XCTAssertEqual(job["status"], "cancelled"); XCTAssertTrue(cleanup); XCTAssertTrue(job["log"].array.contains { $0.string.contains("cancelled; completed units") })
    }
    func testConflictingDuplicateLedgerIDsPreferCurrentAcrossFullHistoryAndWarmCache() async throws {
        let http = BenchmarkParityTransport(), (root, runtime, _) = try fixture(http); defer { try? FileManager.default.removeItem(at: root) }
        let store = BenchmarkStore(paths: runtime.paths)
        let legacy: JSONValue = ["id": "same", "run_id": "r", "provider": "fixture", "model": "one", "ts": "2026-10-14T10:00:00Z", "test": "latency", "ok": false, "error_class": "auth"]
        var current = legacy; current["ok"] = true; current["timing_ms"] = ["ttft": 123]
        for reverse in [false, true] {
            let files = [(runtime.paths.bench.appendingPathComponent("results/results.jsonl"), current), (runtime.paths.data.appendingPathComponent("results.jsonl"), legacy)]
            for (file, row) in reverse ? Array(files.reversed()) : files { try NativeFile.writeAtomic(try row.encoded() + Data("\n".utf8), to: file) }
            let rows = try await store.rows(), history = try await store.runHistory(), warm = try await store.rows()
            XCTAssertEqual(rows, [current]); XCTAssertEqual(warm, rows); XCTAssertEqual(history.first?["ok"], 1); XCTAssertEqual(history.first?["err"], 0)
        }
    }
    func testExportsRetainAllFamiliesAndScopeSpecificSafeFileNames() async throws {
        let http = BenchmarkParityTransport(), (root, runtime, service) = try fixture(http); defer { try? FileManager.default.removeItem(at: root) }
        let rows: [JSONValue] = [["id": "a", "run_id": "r/unsafe", "provider": "fixture", "model": "alpha", "test": "latency", "ok": true, "timing_ms": ["ttft": 10]], ["id": "b", "run_id": "r/unsafe", "provider": "fixture", "model": "beta", "test": "latency", "ok": false]]
        try NativeFile.writeAtomic(rows.reduce(into: Data()) { $0.append((try! $1.encoded()) + Data("\n".utf8)) }, to: runtime.paths.data.appendingPathComponent("results.jsonl"))
        let scoped = try await service.handle("export", input: ["scope": "r/unsafe", "summary": true, "family": "alpha"])
        XCTAssertEqual(scoped["filename"], "uniapi-r-unsafe-summary.csv"); XCTAssertTrue(scoped["text"].string.contains(",alpha,")); XCTAssertTrue(scoped["text"].string.contains(",beta,"))
        let all = try await service.handle("export", input: ["scope": "all", "summary": false]); XCTAssertEqual(all["filename"], "uniapi-all-runs-raw.csv")
        XCTAssertTrue(all["text"].string.hasPrefix(BenchmarkCSV.rawColumns.joined(separator: ",") + "\n"))
        XCTAssertEqual(all["text"].string.split(separator: "\n").count, 3)
        let filtered = try await service.handle("export", input: ["scope": "all", "summary": true, "family": "alpha", "filterFamily": true]); XCTAssertFalse(filtered["text"].string.contains(",beta,"))
    }
}
