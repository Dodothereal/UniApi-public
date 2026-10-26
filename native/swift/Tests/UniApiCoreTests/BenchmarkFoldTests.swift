import XCTest
@testable import UniApiCore

final class BenchmarkFoldTests: XCTestCase {
    private func row(_ run: String, _ test: String, _ stamp: String, ok: Bool = true, timing: JSONValue = [:], speed: JSONValue = [:], context: Int? = nil, extra: JSONValue = [:]) -> JSONValue {
        ["id": .string(UUID().uuidString), "run_id": .string(run), "provider": "fixture", "provider_name": "Fixture", "model": "vendor/model-free", "test": .string(test), "ts": .string(stamp), "ok": .bool(ok), "timing_ms": timing, "tps": speed, "req": ["ctx_tokens": context.map { .number(Double($0)) } ?? .null], "tokens": ["in": 10, "out": 20, "cached": 3, "reasoning": 5], "stream_stats": ["gap_p95_ms": run == "old" ? 11 : 99], "error_class": ok ? .null : "ctx_limit", "extra": extra]
    }
    func testCanonicalIdentityIncludesWholeRowAndDualHistoryChronology() {
        let curve: JSONValue = .array((0..<100).map { _ in [0, 0] as JSONValue })
        var old = row("old", "throughput", "2026-10-10T10:00:00Z"); old["id"] = .null; old["curve"] = curve
        var new = old; new["provider"] = "other"; new["ts"] = "2026-10-11T10:00:00Z"
        let rows = BenchmarkFold.orderedUnique([new, old, old])
        XCTAssertEqual(rows.count, 2); XCTAssertEqual(rows.first?["provider"], "fixture")
    }
    func testLatestSuccessfulThroughputAndRecentNearestRankLatency() {
        var rows = (0..<9).map { row("r", "latency", String(format: "2026-10-10T10:00:%02dZ", $0), timing: ["ttft": .number(Double($0 * 100))]) }
        rows += [row("r", "throughput", "2026-10-10T10:00:10Z", speed: ["decode": 20]), row("r", "throughput", "2026-10-10T10:00:11Z", ok: false, speed: ["decode": 999])]
        let cell = BenchmarkFold.cells(rows)["fixture|vendor/model-free"]!
        XCTAssertEqual(cell["latency"]["n"], 7); XCTAssertEqual(cell["latency"]["ttft_med_ms"], 500)
        XCTAssertEqual(cell["throughput"]["decode_tps"], 20); XCTAssertEqual(cell["err_count"], 1)
        XCTAssertEqual(BenchmarkMath.percentile([100, 300], 50), 100) // Python's nearest-even rank.
    }
    func testBestRecordsKeepWholeSourceRunAndPoolReliability() {
        let rows = [row("old", "latency", "2026-10-10T10:00:00Z", timing: ["ttft": 100]), row("old", "throughput", "2026-10-10T10:00:01Z", speed: ["decode": 80]), row("old", "context", "2026-10-10T10:00:02Z", context: 4096), row("new", "latency", "2026-10-11T10:00:00Z", timing: ["ttft": 300]), row("new", "throughput", "2026-10-11T10:00:01Z", speed: ["decode": 40]), row("new", "context", "2026-10-11T10:00:02Z", context: 16384), row("new", "context", "2026-10-11T10:00:03Z", ok: false, context: 32768)]
        let summary = BenchmarkFold.summary(rows), cell = summary["cells"]["fixture|vendor/model-free"]
        XCTAssertEqual(cell["history"]["sources"]["latency"], "old"); XCTAssertEqual(cell["history"]["sources"]["throughput"], "old"); XCTAssertEqual(cell["history"]["sources"]["context"], "new")
        XCTAssertEqual(cell["throughput"]["gap_p95_ms"], 11); XCTAssertEqual(cell["ctx_bounds"]["min_fail"], 32768)
        XCTAssertEqual(cell["ok_count"], 6); XCTAssertEqual(cell["err_count"], 1)
        XCTAssertTrue(BenchmarkFold.csv(rows, summary: summary).contains(",old,old,new,2,api,"))
    }
    func testEqualRecordPrefersNewerAndLatestScopeDoesNotCombineRuns() {
        let old = row("old", "latency", "2026-10-10T10:00:00Z", timing: ["ttft": 100]), new = row("new", "latency", "2026-10-11T10:00:00Z", timing: ["ttft": 100])
        XCTAssertEqual(BenchmarkFold.summary([new, old])["cells"]["fixture|vendor/model-free"]["history"]["sources"]["latency"], "new")
        let latest = BenchmarkFold.summary([new, old], scope: "latest")
        XCTAssertEqual(latest["scope"], "new"); XCTAssertEqual(latest["rows"], 1); XCTAssertEqual(latest["aggregation"], "run")
        let fields = BenchmarkFold.csv([new], summary: latest).split(separator: "\n")[1].split(separator: ",", omittingEmptySubsequences: false)
        XCTAssertEqual(Array(fields[17...19]), ["", "", ""]) // Single-run exports use scope, not fabricated record-source metadata.
    }
    func testFamilySuffixesAndUsageSubsetsAndCSVQuotes() {
        XCTAssertEqual(BenchmarkMath.family("vendor/DeepSeek-v4-Flash-0731-free"), "deepseekv4flash")
        XCTAssertEqual(BenchmarkMath.family("qwen-3.8-max"), BenchmarkMath.family("qwen3.8-max-free"))
        var r = row("r", "latency", "2026-10-10T10:00:00Z"); r["model"] = "quoted,\"model"; r["tokens"]["out_est"] = true
        var summary = row("r", "max_context", "2026-10-10T10:00:01Z"); summary["tokens"] = [:]
        let usage = BenchmarkFold.usage([r, r, summary]); XCTAssertEqual(usage["input"], 10); XCTAssertEqual(usage["output"], 20); XCTAssertEqual(usage["cached"], 3); XCTAssertEqual(usage["reasoning"], 5); XCTAssertEqual(usage["calls"], 1); XCTAssertEqual(usage["estimated"], 1)
        XCTAssertTrue(BenchmarkFold.csv([r]).contains("\"quoted,\"\"model\""))
    }
    func testBrowserCellKeepsEstimatedProvenanceAcrossHistoricalFold() {
        var r = row("r", "latency", "2026-10-10T10:00:00Z", timing: ["ttft": 100]); r["transport"] = "browser"
        let cell = BenchmarkFold.summary([r])["cells"]["fixture|vendor/model-free"]
        XCTAssertEqual(cell["transport"], "browser"); XCTAssertTrue(cell["tokens_estimated"].bool); XCTAssertTrue(cell["measurement_note"].string.contains("Buffering"))
    }
}
