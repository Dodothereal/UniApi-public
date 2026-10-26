import Foundation
import CryptoKit
@testable import UniApiCore

/// Offline code profiler: saved ledger reads only, no runtime, UI, provider,
/// process launch or hardware service. Payloads never enter the report.
@main struct MeasureBenchmarkCache {
    static func main() async throws {
        guard CommandLine.arguments.count == 2 else { throw NativeFailure("Expected a ledger fixture root") }
        let root = URL(fileURLWithPath: CommandLine.arguments[1])
        let paths = NativePaths(root: root, home: root, readOnly: true)
        let uncached = BenchmarkStore(paths: paths, cacheByteLimit: 0)
        let cached = BenchmarkStore(paths: paths)
        var measurements: [NativeMeasurement] = [], reference: [JSONValue] = []
        for iteration in 0..<4 {
            let (rows, measurement) = try await NativePerformance.measure("uncached-\(iteration)") { try await uncached.rows() }
            if iteration == 0 { reference = rows }
            guard rows == reference else { throw NativeFailure("Ledger changed during profile") }
            measurements.append(measurement)
            let (next, warm) = try await NativePerformance.measure(iteration == 0 ? "bounded-cache-cold" : "bounded-cache-warm-\(iteration)") { try await cached.rows() }
            guard next == reference else { throw NativeFailure("Cached rows differ from the uncached reference") }
            measurements.append(warm)
        }
        let encoder = JSONEncoder()
        let digest = SHA256.hash(data: try JSONValue.array(reference).encoded())
        let report: JSONValue = ["schema": 1, "kind": "offline-benchmark-ledger-cache", "rows": .number(Double(reference.count)),
            "rowSHA256": .string(NativeHex.encode(digest)),
            "measurements": .array(try measurements.map { try JSONValue.decode(encoder.encode($0)) }),
            "note": "Alternating uncached/cached reads of the same unchanged saved ledgers; equality checked on every read. Core file/parse/dedup time only. Cold means fresh in-process row cache; OS caches are not flushed. Peak RSS is process cumulative, not a per-cache allocation. No app, runtime, provider or hardware operation."]
        print(String(decoding: try report.encoded(pretty: true), as: UTF8.self))
    }
}
