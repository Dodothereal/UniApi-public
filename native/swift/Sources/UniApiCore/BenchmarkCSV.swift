import Foundation

/// The retained web export is a public data contract. Keep provenance and
/// unavailable browser fields even when an older ledger contains guesses.
public enum BenchmarkCSV {
    public static let summaryColumns = ["scope", "provider", "provider_name", "model", "family", "ttft_median_ms", "ttft_min_ms", "ttft_max_ms", "ttft_samples", "decode_tps", "gap_p95_ms", "largest_input_tokens", "largest_input_is_ceiling", "reliability_pct", "tests_ok", "tests_failed", "last_error_class", "first_token_source_run", "speed_and_gap_source_run", "max_input_source_run", "runs_tested", "transport", "latency_measurement", "token_counts_estimated", "max_output_supported", "prefill_supported", "measurement_note"]
    public static let rawColumns = ["run_id", "tier", "ts", "ts_end", "provider", "provider_name", "model", "target", "test", "ok", "http_code", "attempts", "error_class", "error_excerpt", "ctx_tokens", "max_tokens", "ttft_ms", "first_content_ms", "total_ms", "gen_ms", "tokens_in", "tokens_out", "tokens_reasoning", "tokens_cached", "tokens_in_estimated", "tokens_out_estimated", "decode_tps", "prefill_tps", "gap_p50_ms", "gap_p95_ms", "gap_max_ms", "stream_events", "non_stream", "finish_reason", "transport", "latency_measurement", "max_output_supported", "prefill_supported", "measurement_note"]
    public static let browserNote = "Browser latency measures first visible text; output speed measures estimated visible updates. ChatGPT buffering can inflate these rates. Compare first response and total completion time. Token counts are estimated; output cannot be capped. Max-output and prefill-rate measurements are unavailable."

    public static func field(_ text: String) -> String {
        var value = text
        // CSV quoting protects delimiters, not spreadsheet evaluation.
        if let first = value.first, "=+-@".contains(first), Double(value.trimmingCharacters(in: .whitespacesAndNewlines)) == nil { value = "'" + value }
        return value.contains(where: { ",\"\n\r".contains($0) }) ? "\"" + value.replacingOccurrences(of: "\"", with: "\"\"") + "\"" : value
    }
    public static func line(_ values: [JSONValue]) -> String {
        values.map { value -> String in
            let text: String
            switch value {
            case .bool(let flag): text = flag ? "yes" : "no"
            case .number(let number): text = format(number)
            case .string(let string): text = string
            default: text = ""
            }
            return field(text)
        }.joined(separator: ",") + "\n"
    }
    public static func summary(_ summary: JSONValue, label: String? = nil) -> String {
        let scope = label ?? (summary["scope"] == "all" ? "All-time best" : "Run " + summary["scope"].string)
        var output = line(summaryColumns.map(JSONValue.string))
        for key in summary["cells"].object.keys.sorted() {
            let cell = summary["cells"][key], browser = cell["transport"] == "browser"
            let total = cell["ok_count"].double + cell["err_count"].double, input = BenchmarkFold.largestInput(cell)
            let capped = !cell["max_context"]["min_fail"].isNull || cell["ctx"].object.contains { size, point in
                !point["ok"].bool && input != nil && (Double(size) ?? 0) > input!
            }
            let sources = cell["history"]["sources"]
            output += line([.string(scope), cell["provider"], cell["provider_name"], cell["model"], cell["family"], cell["latency"]["ttft_med_ms"], cell["latency"]["ttft_min_ms"], cell["latency"]["ttft_max_ms"], cell["latency"]["n"].isNull ? 0 : cell["latency"]["n"], cell["throughput"]["decode_tps"], cell["throughput"]["gap_p95_ms"], BenchmarkMath.optional(input), .bool(capped), total > 0 ? .number(cell["ok_count"].double * 100 / total) : .null, cell["ok_count"], cell["err_count"], cell["last_error"]["class"].isNull ? "" : cell["last_error"]["class"], sources["latency"], sources["throughput"], sources["context"], cell["history"]["runs"].isNull ? 1 : cell["history"]["runs"], cell["transport"].string.isEmpty ? "api" : cell["transport"], browser ? "first_visible_text" : "first_token", browser ? true : cell["tokens_estimated"], browser ? false : .null, browser ? false : .null, note(cell, browser: browser)])
        }
        return output
    }
    public static func raw(_ rows: [JSONValue]) -> String {
        var output = line(rawColumns.map(JSONValue.string))
        for row in rows {
            let browser = row["transport"] == "browser", request = row["req"], timing = row["timing_ms"], tokens = row["tokens"], speed = row["tps"], stream = row["stream_stats"]
            let rawNote: JSONValue
            if case .string = row["measurement_note"] { rawNote = row["measurement_note"] } else { rawNote = .string(browser ? browserNote : "") }
            output += line([row["run_id"], row["tier"], row["ts"], row["ts_end"], row["provider"], row["provider_name"], row["model"], row["target"], row["test"], row["ok"], row["http_code"], row["attempts"], row["error_class"], row["error_excerpt"], request["ctx_tokens"], browser ? .null : request["max_tokens"], timing["ttft"], timing["first_content"], timing["total"], timing["gen"], tokens["in"], tokens["out"], browser ? .null : tokens["reasoning"], browser ? .null : tokens["cached"], browser ? true : tokens["in_est"], browser ? true : tokens["out_est"], speed["decode"], browser ? .null : speed["prefill"], stream["gap_p50_ms"], stream["gap_p95_ms"], stream["gap_max_ms"], stream["events"], stream["non_stream"], row["finish_reason"], browser ? "browser" : "api", browser ? "first_visible_text" : "first_token", browser ? false : .null, browser ? false : .null, rawNote])
        }
        return output
    }
    private static func note(_ value: JSONValue, browser: Bool) -> JSONValue {
        .string(value["measurement_note"].string.isEmpty ? browser ? browserNote : "" : value["measurement_note"].string)
    }
    private static func format(_ value: Double) -> String {
        guard value.isFinite else { return "" }
        if value == 0 { return "0" }
        if abs(value) >= 1e21 { return String(value).replacingOccurrences(of: ".0e", with: "e") }
        if value == value.rounded() { return String(format: "%.0f", locale: Locale(identifier: "en_US_POSIX"), value) }
        let magnitude = abs(value), sixteenths = magnitude * 16
        // JS toFixed chooses the larger magnitude at exact decimal ties;
        // printf uses ties-to-even. At three places a binary-exact tie must
        // be an odd multiple of 1/16 (the factors of five cancel).
        let tie = sixteenths == sixteenths.rounded() && sixteenths.truncatingRemainder(dividingBy: 2) == 1
        return (value < 0 ? "-" : "") + String(format: "%.3f", locale: Locale(identifier: "en_US_POSIX"), tie ? magnitude.nextUp : magnitude)
    }
}
