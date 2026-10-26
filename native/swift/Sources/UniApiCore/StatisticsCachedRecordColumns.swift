import Foundation

/// Resolve the cache schema once per statement. Older read-only caches can lack
/// newer columns; missing values retain the dictionary reader's null defaults.
struct StatisticsCachedRecordColumns {
    private enum Field: Int {
        case path, id, source, ts, model, project, session, sidechain, effort
        case input, output, thinking, cacheWrite, cacheRead, webSearch, webFetch
        case rawDay, duration, timing, streamDuration, streamOutput, streamTiming
    }
    private let indices: [Int]

    init(_ names: [String]) {
        var positions: [String: Int] = [:]
        // The old dictionary reader keeps the last column with a repeated name.
        for (index, name) in names.enumerated() { positions[name] = index }
        indices = ["path", "msg_id", "source", "ts", "model", "project", "session", "sidechain", "effort",
                   "input", "output", "thinking", "cache_write", "cache_read", "web_search", "web_fetch",
                   "raw_day", "duration_ms", "timing", "stream_duration_ms", "stream_output_tokens", "stream_timing"].map { positions[$0] ?? -1 }
    }

    @inline(__always) private func value(_ field: Field, in values: [JSONValue]) -> JSONValue {
        let index = indices[field.rawValue]
        return index >= 0 && index < values.count ? values[index] : .null
    }

    func path(in values: [JSONValue]) -> String { value(.path, in: values).string }

    func usage(in values: [JSONValue]) -> StatisticsUsage {
        var e = StatisticsUsage(id: value(.id, in: values).string, source: value(.source, in: values).string,
                                ts: value(.ts, in: values).double, model: value(.model, in: values).string)
        e.project = value(.project, in: values).string
        e.session = value(.session, in: values).string
        e.sidechain = value(.sidechain, in: values).int == 1
        e.effort = value(.effort, in: values).string
        e.input = value(.input, in: values).double
        e.output = value(.output, in: values).double
        e.thinking = value(.thinking, in: values).double
        e.cacheWrite = value(.cacheWrite, in: values).double
        e.cacheRead = value(.cacheRead, in: values).double
        e.webSearch = value(.webSearch, in: values).double
        e.webFetch = value(.webFetch, in: values).double
        e.rawDay = value(.rawDay, in: values).string
        let duration = value(.duration, in: values), timing = value(.timing, in: values)
        e.durationMs = duration.isNull ? nil : duration.double
        e.timing = timing.isNull ? nil : timing.string
        let streamDuration = value(.streamDuration, in: values), streamOutput = value(.streamOutput, in: values), streamTiming = value(.streamTiming, in: values)
        e.streamDurationMs = streamDuration.isNull ? nil : streamDuration.double
        e.streamOutputTokens = streamOutput.isNull ? nil : streamOutput.double
        e.streamTiming = streamTiming.isNull ? nil : streamTiming.string
        return e
    }
}
