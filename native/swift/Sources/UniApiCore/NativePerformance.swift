import Foundation
import Darwin

public struct NativeMeasurement: Codable, Sendable {
    public var name: String
    public var elapsedMs: Double
    public var userCPUMs: Double
    public var systemCPUMs: Double
    public var peakResidentBytes: Int64
}

public enum NativePerformance {
    public static func measure<T>(_ name: String, operation: () async throws -> T) async rethrows -> (T, NativeMeasurement) {
        let clock = ContinuousClock(), start = clock.now
        var before = rusage(), after = rusage()
        getrusage(RUSAGE_SELF, &before)
        let result = try await operation()
        getrusage(RUSAGE_SELF, &after)
        let elapsed = start.duration(to: clock.now).components
        func milliseconds(_ value: timeval) -> Double { Double(value.tv_sec) * 1000 + Double(value.tv_usec) / 1000 }
        return (result, NativeMeasurement(name: name,
            elapsedMs: Double(elapsed.seconds) * 1000 + Double(elapsed.attoseconds) / 1e15,
            userCPUMs: milliseconds(after.ru_utime) - milliseconds(before.ru_utime),
            systemCPUMs: milliseconds(after.ru_stime) - milliseconds(before.ru_stime),
            peakResidentBytes: Int64(after.ru_maxrss)))
    }
    public static func percentile(_ values: [Double], _ p: Double) -> Double? {
        guard !values.isEmpty else { return nil }
        let sorted = values.sorted(), index = min(sorted.count - 1, max(0, Int((Double(sorted.count - 1) * p).rounded(.up))))
        return sorted[index]
    }
    public static func directoryBytes(_ url: URL) -> Int64 {
        guard let walker = FileManager.default.enumerator(at: url, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey], options: [.skipsHiddenFiles]) else { return 0 }
        var total: Int64 = 0
        for case let file as URL in walker {
            guard let attributes = try? file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]), attributes.isRegularFile == true, attributes.isSymbolicLink != true else { continue }
            total += Int64(attributes.fileSize ?? 0)
        }
        return total
    }
}

/// Read-only baseline collector. API latency is deliberately reported apart
/// from rendered-page latency; this command cannot prove a faster interface.
public enum NativeWebBaseline {
    public static let routes: [(String, String)] = [
        ("Home", "/api/summary"), ("Speed", "/api/bench/catalog"),
        ("Results", "/api/bench/summary"), ("Prompts", "/api/prompts"),
        ("Arena", "/api/arena/state"), ("Claude Switcher", "/api/switcher/status"),
        ("Codex Switcher", "/api/switcher/codex"), ("Code", "/api/code/threads"),
        ("Statistics", "/api/stats?range=0&source=all"),
        ("Activity", "/api/activity/status"), ("Fan Control", "/api/fans/status"),
        ("Battery", "/api/battery/status"), ("Transcribe", "/api/transcribe/list"),
        ("Jobs", "/api/jobs"), ("Settings", "/api/health")
    ]
    public static func collect(root: URL, samples: Int = 7) async throws -> JSONValue {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 20
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }
        var results: [JSONValue] = []
        for (name, path) in routes {
            var times: [Double] = [], statuses: [Int] = [], bytes: [Int] = [], errors: [String] = []
            for _ in 0..<max(1, samples) {
                var request = URLRequest(url: URL(string: "http://127.0.0.1:8780" + path)!)
                request.cachePolicy = .reloadIgnoringLocalCacheData
                do {
                    let (response, measurement) = try await NativePerformance.measure(name) { try await session.data(for: request) }
                    statuses.append((response.1 as? HTTPURLResponse)?.statusCode ?? 0)
                    times.append(measurement.elapsedMs); bytes.append(response.0.count)
                } catch { errors.append(error.localizedDescription) }
            }
            results.append(["page": .string(name), "route": .string(path), "samplesMs": .array(times.map(JSONValue.number)),
                "firstMs": times.first.map(JSONValue.number) ?? .null,
                "warmMedianMs": NativePerformance.percentile(Array(times.dropFirst()), 0.5).map(JSONValue.number) ?? .null,
                "p95Ms": NativePerformance.percentile(times, 0.95).map(JSONValue.number) ?? .null,
                "statuses": .array(statuses.map { .number(Double($0)) }),
                "responseBytes": .array(bytes.map { .number(Double($0)) }), "errors": .array(errors.map(JSONValue.string))])
        }
        var sizes: JSONObject = [:]
        for relative in ["client/dist", "node_modules", "server/node_modules", "client/node_modules", "shell/build.noindex/UniApi.app", "legacy/swift-app/build.noindex/UniApi.app"] {
            sizes[relative] = .number(Double(NativePerformance.directoryBytes(root.appendingPathComponent(relative))))
        }
        return ["version": 1, "kind": "web-api-baseline", "recordedAt": .string(ISO8601DateFormatter().string(from: Date())),
            "os": .string(ProcessInfo.processInfo.operatingSystemVersionString), "logicalCores": .number(Double(ProcessInfo.processInfo.processorCount)),
            "note": "First request is first observed in this run, not a server cold start. API response time is distinct from rendered-page readiness. Dependency folders are listed separately and must not be summed across symlinks.",
            "routes": .array(results), "logicalFileBytes": .object(sizes)]
    }
}
