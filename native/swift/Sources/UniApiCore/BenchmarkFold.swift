import Foundation
import CryptoKit

public enum BenchmarkFold {
    public static func orderedUnique(_ rows: [JSONValue]) -> [JSONValue] {
        var seen = Set<String>()
        return rows.filter { row in
            guard case .object = row else { return false }
            let id = row["id"].string
            let key = id.isEmpty ? NativeHex.encode(SHA256.hash(data: (try? row.encoded()) ?? Data())) : id
            return seen.insert(key).inserted
        }.sorted {
            let a = BenchmarkMath.timestamp($0["ts"].string), b = BenchmarkMath.timestamp($1["ts"].string)
            if a != b { return a < b }
            let ae = BenchmarkMath.timestamp($0["ts_end"].string), be = BenchmarkMath.timestamp($1["ts_end"].string)
            return ae == be ? $0["id"].string < $1["id"].string : ae < be
        }
    }
    public static func largestInput(_ cell: JSONValue) -> Double? {
        let sizes = cell["ctx"].object.compactMap { key, value -> Double? in value["ok"].bool ? Double(key) : nil }
        return (sizes + [BenchmarkMath.number(cell["max_context"]["max_ok"])].compactMap { $0 }).max()
    }
    public static func cells(_ rows: [JSONValue]) -> JSONObject {
        var cells: JSONObject = [:], ttfts: [String: [Double]] = [:]
        for row in rows {
            let model = row["model"].string.isEmpty ? row["target"].string : row["model"].string, provider = row["provider"].string
            guard !model.isEmpty, !provider.isEmpty else { continue }
            let key = provider + "|" + model
            var cell = cells[key] ?? ["provider": .string(provider), "provider_name": row["provider_name"].isNull ? .string(provider) : row["provider_name"], "target": row["target"], "model": .string(model), "family": .string(BenchmarkMath.family(model)), "ok_count": 0, "err_count": 0, "last_error": .null, "latency": .null, "throughput": .null, "ctx": [:], "maxout": .null, "max_context": .null, "vision": .null]
            cell["last_ts"] = row["ts_end"].isNull ? row["ts"] : row["ts_end"]
            let count = row["ok"].bool ? "ok_count" : "err_count"; cell[count] = .number(cell[count].double + 1)
            if !row["ok"].bool { cell["last_error"] = ["class": row["error_class"], "excerpt": .string(String(row["error_excerpt"].string.prefix(200))), "test": row["test"], "ts": row["ts"]] }
            let timing = row["timing_ms"], speed = row["tps"], tokens = row["tokens"], extra = row["extra"]
            switch row["test"].string {
            case "latency":
                if row["ok"].bool, let value = BenchmarkMath.number(timing["ttft"]) { ttfts[key, default: []].append(value); ttfts[key] = Array(ttfts[key]!.suffix(7)) }
            case "throughput":
                if row["ok"].bool { cell["throughput"] = ["decode_tps": speed["decode"], "ttft_ms": timing["ttft"], "out_tokens": tokens["out"], "gap_p95_ms": row["stream_stats"]["gap_p95_ms"], "run_id": row["id"], "source_run_id": row["run_id"], "ts": row["ts"]] }
            case "context", "context_probe":
                let size = row["req"]["ctx_tokens"].int
                if size > 0 { var points = cell["ctx"]; points[String(size)] = ["ok": row["ok"], "ttft_ms": timing["ttft"], "prefill_tps": speed["prefill"], "in_tokens": tokens["in"], "in_est": tokens["in_est"], "error_class": row["error_class"], "ts": row["ts"], "probe": .bool(row["test"] == "context_probe")]; cell["ctx"] = points }
            case "maxout": cell["maxout"] = ["requested": extra["requested_cap"], "allowed_cap": extra["allowed_cap"], "generated": tokens["out"], "out_est": tokens["out_est"], "finish_reason": row["finish_reason"], "timed_out": row["timed_out"], "ok": row["ok"], "decode_tps": speed["decode"], "error_class": row["error_class"], "ts": row["ts"], "source_run_id": row["run_id"]]
            case "max_context": cell["max_context"] = ["max_ok": extra["max_ok_requested"], "min_fail": extra["min_fail_requested"], "measured_tokens": extra["measured_prompt_tokens"], "probes": extra["probes"], "inconclusive": extra["inconclusive"], "ts": row["ts"]]
            case "vision": cell["vision"] = ["ok": row["ok"], "ttft_ms": timing["ttft"], "reply": row["content_head"], "error_class": row["error_class"], "ts": row["ts"]]
            default: break
            }
            if row["transport"] == "browser" { cell["transport"] = "browser"; cell["tokens_estimated"] = true; cell["measurement_note"] = .string(BenchmarkMath.browserNote) }
            cells[key] = cell
        }
        for key in cells.keys {
            var cell = cells[key]!
            if let values = ttfts[key], !values.isEmpty { cell["latency"] = ["ttft_med_ms": BenchmarkMath.optional(BenchmarkMath.percentile(values, 50)), "ttft_min_ms": BenchmarkMath.optional(values.min()), "ttft_max_ms": BenchmarkMath.optional(values.max()), "n": .number(Double(values.count))] }
            let points = cell["ctx"].object
            cell["ctx_bounds"] = ["max_ok": BenchmarkMath.optional(points.compactMap { $0.value["ok"].bool ? Double($0.key) : nil }.max()), "min_fail": BenchmarkMath.optional(points.compactMap { !$0.value["ok"].bool && $0.value["error_class"] == "ctx_limit" ? Double($0.key) : nil }.min())]
            cells[key] = cell
        }
        return cells
    }
    public static func bestAcrossRuns(_ runs: [String: JSONObject]) -> JSONObject {
        var candidates: [String: [(String, JSONValue)]] = [:]
        for (run, cells) in runs { for (key, cell) in cells { candidates[key, default: []].append((run, cell)) } }
        var result: JSONObject = [:]
        for (key, choices) in candidates {
            let choices = choices.sorted { a, b in let at = BenchmarkMath.timestamp(a.1["last_ts"].string), bt = BenchmarkMath.timestamp(b.1["last_ts"].string); return at == bt ? a.0 < b.0 : at < bt }
            var combined = choices.last!.1, sources: JSONValue = [:]
            combined["ok_count"] = .number(choices.reduce(0) { $0 + $1.1["ok_count"].double })
            combined["err_count"] = .number(choices.reduce(0) { $0 + $1.1["err_count"].double })
            combined["last_error"] = choices.map { $0.1["last_error"] }.filter { !$0.isNull }.max { BenchmarkMath.timestamp($0["ts"].string) < BenchmarkMath.timestamp($1["ts"].string) } ?? .null
            func choose(_ metric: String, fields: [String], lower: Bool = false, value: (JSONValue) -> Double?) {
                let valid = choices.filter { value($0.1) != nil }
                let winner = valid.max { a, b in
                    let av = value(a.1)!, bv = value(b.1)!
                    if av == bv { return BenchmarkMath.timestamp(a.1["last_ts"].string) < BenchmarkMath.timestamp(b.1["last_ts"].string) || (a.1["last_ts"] == b.1["last_ts"] && a.0 < b.0) }
                    return lower ? av > bv : av < bv
                }
                for field in fields { combined[field] = winner?.1[field] ?? (field == "ctx" ? [:] : .null) }
                sources[metric] = winner.map { .string($0.0) } ?? .null
            }
            choose("latency", fields: ["latency"], lower: true) { BenchmarkMath.number($0["latency"]["ttft_med_ms"]) }
            choose("throughput", fields: ["throughput"]) { BenchmarkMath.number($0["throughput"]["decode_tps"]) }
            choose("context", fields: ["ctx", "max_context", "ctx_bounds"], value: largestInput)
            combined["history"] = ["runs": .number(Double(choices.count)), "sources": sources]
            if choices.contains(where: { $0.1["transport"] == "browser" }) { combined["transport"] = "browser"; combined["tokens_estimated"] = true; combined["measurement_note"] = .string(BenchmarkMath.browserNote) }
            result[key] = combined
        }
        return result
    }
    public static func summary(_ input: [JSONValue], scope: String = "all") -> JSONValue {
        let rows: [JSONValue] = orderedUnique(input)
        let groups: [String: [JSONValue]] = Dictionary(grouping: rows) { row in
            let run = row["run_id"].string; return run.isEmpty ? "unknown" : run
        }
        let runs = runHistory(rows)
        let actual = scope == "latest" ? runs.first?["id"].string ?? "all" : scope
        let selected = actual == "all" ? rows : groups[actual] ?? []
        let folded = actual == "all" ? bestAcrossRuns(groups.mapValues(cells)) : cells(selected)
        return ["runs": .array(runs), "cells": .object(folded), "rows": .number(Double(selected.count)), "aggregation": .string(actual == "all" ? "best" : "run"), "scope": .string(actual)]
    }
    public static func runHistory(_ rows: [JSONValue]) -> [JSONValue] {
        let groups = Dictionary(grouping: rows) { $0["run_id"].string.isEmpty ? "unknown" : $0["run_id"].string }
        var runs: [JSONValue] = []
        for (id, records) in groups {
            let endings: [String] = records.map { $0["ts_end"].isNull ? $0["ts"].string : $0["ts_end"].string }
            let pairNames: [String] = records.map { $0["provider"].string + "|" + $0["model"].string }
            let pairs: [JSONValue] = Set(pairNames).sorted().map(JSONValue.string)
            let successes: Int = records.filter { $0["ok"].bool }.count
            let failures: Int = records.count - successes
            let entry: JSONObject = ["id": .string(id), "tier": records.first?["tier"] ?? .null,
                "started": records.first?["ts"] ?? .null, "finished": endings.max().map(JSONValue.string) ?? .null,
                "ok": .number(Double(successes)), "err": .number(Double(failures)), "pairs": .array(pairs)]
            runs.append(.object(entry))
        }
        runs.sort { BenchmarkMath.timestamp($0["started"].string) > BenchmarkMath.timestamp($1["started"].string) }
        return runs
    }
    public static func usage(_ rows: [JSONValue]) -> JSONValue {
        var totals: JSONValue = ["input": 0, "output": 0, "reasoning": 0, "cached": 0, "calls": 0, "estimated": 0], pairs: JSONObject = [:]
        for row in orderedUnique(rows) {
            // Context-bound summaries are synthetic records, not billed calls.
            guard row["tokens"]["in"].double > 0 || row["tokens"]["out"].double > 0 else { continue }
            let key = row["provider"].string + "|" + row["model"].string
            var pair = pairs[key] ?? ["provider": row["provider"], "provider_name": row["provider_name"], "model": row["model"], "input": 0, "output": 0, "reasoning": 0, "cached": 0, "calls": 0, "estimated": 0]
            let fields = ["input": row["tokens"]["in"].double, "output": row["tokens"]["out"].double, "reasoning": row["tokens"]["reasoning"].double, "cached": row["tokens"]["cached"].double, "calls": 1, "estimated": row["tokens"]["in_est"].bool || row["tokens"]["out_est"].bool ? 1 : 0]
            for (field, value) in fields { totals[field] = .number(totals[field].double + value); pair[field] = .number(pair[field].double + value) }
            pairs[key] = pair
        }
        totals["pairs"] = .array(pairs.values.sorted { $0["input"].double + $0["output"].double > $1["input"].double + $1["output"].double })
        return totals
    }
    public static func csv(_ rows: [JSONValue], summary: JSONValue? = nil, label: String? = nil) -> String {
        if let summary { return BenchmarkCSV.summary(summary, label: label) }
        return BenchmarkCSV.raw(rows)
    }
}
