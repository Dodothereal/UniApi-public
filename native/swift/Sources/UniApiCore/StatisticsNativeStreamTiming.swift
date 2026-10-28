import Foundation

/// Timing is supplemental metadata, never a second source of token totals.
/// Keep admitted observations independently of the bounded transport journal so
/// reparsing a growing transcript does not discard earlier measured clocks.
enum StatisticsNativeStreamTiming {
    // Retain a bounded tail even before the matching transcript is imported.
    // This is optional measurement metadata, not permanent usage accounting.
    static let retentionLimit = 65_536

    static func applying(_ observation: NativeCodexStreamTimingObservation, to usage: StatisticsUsage) -> StatisticsUsage? {
        guard usage.source == "codex", usage.id == "codex:" + observation.responseID,
              usage.model == observation.model,
              usage.output == Double(observation.outputTokens),
              usage.thinking == Double(observation.reasoningTokens),
              observation.outputTokens > 0, observation.reasoningTokens >= 0,
              observation.reasoningTokens < observation.outputTokens,
              observation.streamOutputTokens == observation.outputTokens - observation.reasoningTokens,
              observation.durationMs.isFinite, observation.durationMs > 0, observation.durationMs <= 86_400_000,
              observation.completedAt.isFinite, observation.completedAt > 0,
              observation.timingSource == "uniapi-host-sse-clock" else { return nil }
        var result = usage
        result.streamDurationMs = observation.durationMs
        result.streamOutputTokens = Double(observation.streamOutputTokens)
        result.streamTiming = observation.timingSource
        return result
    }

    static func stored(_ runtime: NativeRuntime) throws -> [String: NativeCodexStreamTimingObservation] {
        var result: [String: NativeCodexStreamTimingObservation] = [:]
        // A read-only installation can predate this additive metadata table.
        guard try !runtime.db.query("SELECT name FROM sqlite_master WHERE type='table' AND name='stats_native_stream_timing'").isEmpty else { return result }
        try runtime.db.forEachValueRow("SELECT record_id,observation FROM stats_native_stream_timing WHERE length(record_id)<=300 AND length(observation)<=4096 ORDER BY completed_at DESC,record_id ASC LIMIT \(retentionLimit)", columns: { _ in }) { row in
            guard row.count == 2, let data = row[1].string.data(using: .utf8), data.count <= 4096,
                  let observation = try? JSONDecoder().decode(NativeCodexStreamTimingObservation.self, from: data),
                  observation.valid, row[0].string == "codex:" + observation.responseID else { return }
            result[row[0].string] = observation
        }
        return result
    }

    static func save(_ observations: [String: NativeCodexStreamTimingObservation], runtime: NativeRuntime, limit: Int = retentionLimit) throws {
        guard !runtime.paths.readOnly, !observations.isEmpty else { return }
        guard (1...retentionLimit).contains(limit) else { throw NativeFailure("Invalid timing retention bound") }
        try runtime.db.transaction {
            for (id, observation) in observations {
                guard observation.valid, id == "codex:" + observation.responseID else { continue }
                let data = try JSONEncoder().encode(observation)
                guard data.count <= 4096 else { continue }
                try runtime.db.execute("INSERT OR REPLACE INTO stats_native_stream_timing(record_id,observation,completed_at) VALUES(?,?,?)",
                                       [.string(id), .string(String(decoding: data, as: UTF8.self)), .number(observation.completedAt)])
            }
            try runtime.db.execute("DELETE FROM stats_native_stream_timing WHERE record_id NOT IN (SELECT record_id FROM stats_native_stream_timing ORDER BY completed_at DESC,record_id ASC LIMIT \(limit))")
        }
    }

    static func bounded(_ observations: [String: NativeCodexStreamTimingObservation], limit: Int = retentionLimit) -> [String: NativeCodexStreamTimingObservation] {
        guard observations.count > limit else { return observations }
        return Dictionary(uniqueKeysWithValues: observations.sorted {
            $0.value.completedAt == $1.value.completedAt ? $0.key < $1.key : $0.value.completedAt > $1.value.completedAt
        }.prefix(limit).map { ($0.key, $0.value) })
    }
}
