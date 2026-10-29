import Foundation

/// All-time spend uses the original timestamp strings for first/last. Only
/// date-window filtering and eligible latency trends need a parsed clock.
struct StatisticsBenchmarkClock {
    let timestamp: Double?
    let latencyMs: Double?

    init(_ row: JSONValue, range: Int, parse: (JSONValue) -> Double? = statisticsTimestamp) {
        if row["test"].string == "latency", row["ok"].bool, !row["run_id"].string.isEmpty,
           case .number(let ms) = row["timing_ms"]["ttft"], ms.isFinite {
            latencyMs = ms
        } else { latencyMs = nil }
        timestamp = range > 0 || latencyMs != nil ? parse(row["ts"]) : nil
    }
}
