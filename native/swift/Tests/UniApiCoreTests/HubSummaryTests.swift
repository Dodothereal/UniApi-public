import XCTest
@testable import UniApiCore

final class HubSummaryTests: XCTestCase {
    private func runtime() throws -> NativeRuntime {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return try NativeRuntime(paths: NativePaths(root: root, home: root))
    }
    func testSummaryReadsCoalesceAndIsolateAReportedDomainFailure() async throws {
        let runtime = try runtime(), counter = HubReaderFixture()
        let service = NativeHubSummaries(runtime: runtime, read: { try await counter.read($0) })
        async let first = service.snapshot(), second = service.snapshot()
        let a = try await first, b = try await second
        XCTAssertEqual(a, b)
        XCTAssertEqual(a["code"]["pendingPermissions"], 3)
        XCTAssertEqual(a["arena"]["error"], "fixture unavailable")
        let count = await counter.calls; XCTAssertEqual(count, 6)
        let badges = await service.badges(); XCTAssertEqual(badges["code"], 3); XCTAssertTrue(badges["arena"].isNull)
        XCTAssertEqual(badges["jobs"], 0)
    }
    func testRunIndexMatchesFullHistoryIncludingIDlessCurveDifferences() async throws {
        let runtime = try runtime(), store = BenchmarkStore(paths: runtime.paths)
        let first: JSONValue = ["run_id": "one", "provider": "p", "model": "model", "tier": "quick", "ts": "2026-10-10T10:00:00Z", "ok": true, "test": "throughput", "tokens": ["in": 1, "out": 2], "curve": [[0, 1]]]
        var different = first; different["curve"] = [[0, 2]]
        let file = runtime.paths.data.appendingPathComponent("results.jsonl")
        try NativeFile.writeAtomic(Data([first, first, different].map { String(decoding: try! $0.encoded(), as: UTF8.self) }.joined(separator: "\n").utf8), to: file)
        let full = BenchmarkFold.summary(try await store.rows())["runs"].array
        let index = try await store.runHistory()
        XCTAssertEqual(index, full); XCTAssertEqual(index.first?["ok"], 2)
        let service = NativeBenchmarkService(runtime: runtime, dependencies: .init(transport: HubNoTransport(), schedulingEnabled: false))
        let home = try await service.handle("home")
        XCTAssertEqual(home["lastRun"]["ok"], 2)
        XCTAssertEqual(home["planned"], 0)
        XCTAssertFalse(home["running"].bool)
    }
}
private actor HubReaderFixture {
    var calls = 0
    func read(_ domain: String) throws -> JSONValue {
        calls += 1
        if domain == "arena" { throw NativeFailure("fixture unavailable") }
        return domain == "code" ? ["pendingPermissions": 3] : ["loaded": false]
    }
}
private struct HubNoTransport: BenchmarkTransport {
    func execute(_ request: BenchmarkRequest) async throws -> BenchmarkResponse { XCTFail("Home attempted inference"); throw NativeFailure("No transport in summary fixture") }
}
