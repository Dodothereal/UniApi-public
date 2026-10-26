import Foundation
import UniApiCore

package enum NativeStatsRateMetric: String, CaseIterable, Hashable, Sendable {
    case streaming, response

    package var title: String { self == .streaming ? "Streaming tokens/s" : "Response average tokens/s" }
    package var shortTitle: String { self == .streaming ? "Streaming" : "Response average" }
    package var durationName: String { self == .streaming ? "streaming seconds" : "response seconds" }
    package var emptyTitle: String { self == .streaming ? "Streaming timing unavailable" : "Response timing unavailable" }
    package var caption: String {
        self == .streaming
            ? "Output tokens ÷ matched streaming duration. Excludes request latency and tool waits. Antigravity uses reported stream duration; DeepSeek Harness uses host-observed arrivals, affected by transport buffering. These are not server decode measurements. Historical Codex/Claude records without streaming clocks remain unavailable."
            : "Output tokens ÷ elapsed response time, including request latency. Transcript-derived timings may be estimated. This secondary measure is not streaming speed."
    }

    package func board(_ throughput: JSONValue) -> JSONValue {
        // An older payload can have response timing without any streaming clocks.
        self == .streaming ? throughput["streaming"] : throughput
    }

    package func coverage(_ speed: JSONValue) -> String {
        guard let timed = NativeStatsThroughputPresentation.count(speed["timedResponses"]),
              let total = NativeStatsThroughputPresentation.count(speed["totalResponses"]), timed <= total else { return emptyTitle }
        let estimated = NativeStatsThroughputPresentation.count(speed["estimatedResponses"]) ?? 0
        if self == .streaming {
            return "\(timed) / \(total) streaming-timed · \(total - timed) unknown"
                + (estimated > 0 ? " · \(estimated) estimated" : "")
        }
        return "\(timed) / \(total) timed" + (estimated > 0 ? " · \(estimated) estimated" : "")
    }

    package func timingDetail(_ speed: JSONValue) -> String {
        guard NativeStatsThroughputPresentation.rate(speed) != nil else {
            let knownCoverage = coverage(speed)
            return emptyTitle + (knownCoverage == emptyTitle ? "" : ". " + knownCoverage) + ". " + caption
        }
        let output = String(format: "%.0f", speed["outputTokens"].double)
        let duration = String(format: "%.1f", speed["durationMs"].double / 1000)
        return "\(output) output tokens over \(duration) \(durationName). \(coverage(speed)). " + caption
    }
}

package enum NativeStatsThroughputPresentation {
    package static func rate(_ speed: JSONValue) -> Double? {
        guard case .number(let value) = speed["avgTps"], value.isFinite, value >= 0 else { return nil }
        return value
    }

    package static func count(_ value: JSONValue) -> Int? {
        guard case .number(let number) = value, number.isFinite, number >= 0 else { return nil }
        return Int(exactly: number)
    }

    package static func streamingSource(_ throughput: JSONValue, source: String) -> JSONValue {
        throughput["streaming"]["harnesses"].array.first { $0["source"].string == source } ?? .null
    }
}
