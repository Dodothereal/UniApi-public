import Foundation
import Darwin
import UniApiCore

/// Offline corpus comparison. Only an explicitly marked private fixture receives
/// cache writes; source stores remain read-only, exactly as in the app importer.
@main struct MeasureStatistics {
    static func main() async throws {
        guard CommandLine.arguments.count == 3 else { throw NativeFailure("Expected private fixture root and corpus home") }
        let base = URL(fileURLWithPath: CommandLine.arguments[1]).standardizedFileURL.resolvingSymlinksInPath()
        let corpus = URL(fileURLWithPath: CommandLine.arguments[2]).standardizedFileURL.resolvingSymlinksInPath()
        var info = stat()
        guard lstat(base.path, &info) == 0, info.st_uid == getuid(), info.st_mode & 0o077 == 0,
              info.st_mode & S_IFMT == S_IFDIR, corpus.path.hasPrefix(base.path + "/"),
              (try? String(contentsOf: base.appendingPathComponent(".uniapi-performance-fixture"), encoding: .utf8)) == "private corpus comparison\n" else { throw NativeFailure("An owner-only marked private corpus fixture is required") }
        let runtime = try NativeRuntime(paths: NativePaths(root: base.appendingPathComponent("native"), home: corpus))
        let service = NativeStatisticsService.shared(runtime: runtime)
        let (overview, first) = try await NativePerformance.measure("statistics-first-in-process") { try await service.handle("overview") }
        guard overview["warnings"].array.isEmpty else { throw NativeFailure("Corpus comparison refused an incomplete source read") }
        let (_, warm) = try await NativePerformance.measure("statistics-warm-in-process") { try await service.handle("overview") }
        let encoder = JSONEncoder()
        let report: JSONValue = ["schema": 1, "kind": "native-private-corpus-profile", "recordedAt": .string(ISO8601DateFormatter().string(from: Date())),
            "measurements": .array(try [first, warm].map { try JSONValue.decode(encoder.encode($0)) }),
            "warnings": overview["warnings"], "scan": overview["scan"], "summary": overview["derived"]["summary"], "sources": overview["sources"], "responses": overview["derived"]["events"],
            "note": "Private immutable corpus, writes only to its private native cache. Separate process invocations distinguish cold import and persisted cache. OS file caches are not flushed. No UI, provider, agent or hardware operation."]
        print(String(decoding: try report.encoded(pretty: true), as: UTF8.self))
    }
}
