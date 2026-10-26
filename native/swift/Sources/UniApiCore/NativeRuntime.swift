import Foundation

public final class NativeRuntime: @unchecked Sendable {
    public let startedAt = ProcessInfo.processInfo.systemUptime
    public var uptime: Double { max(0, ProcessInfo.processInfo.systemUptime - startedAt) }
    public let paths: NativePaths
    public let db: NativeDatabase
    public let jobs: NativeJobQueue
    public let events: NativeEvents
    public let process: NativeProcess
    public let providers: NativeProviderStore
    public let cache = NativePayloadCache()
    public init(paths: NativePaths) throws {
        self.paths = paths
        try paths.ensureDirectories()
        db = try NativeDatabase(url: paths.database, readOnly: paths.readOnly)
        events = NativeEvents()
        process = NativeProcess()
        providers = NativeProviderStore(paths: paths)
        let localExample = paths.root.appendingPathComponent("providers.example.json")
        let example = FileManager.default.fileExists(atPath: localExample.path) ? localExample : Bundle.main.resourceURL?.appendingPathComponent("providers.example.json")
        try providers.seedIfAbsent(example: example.flatMap { FileManager.default.fileExists(atPath: $0.path) ? $0 : nil })
        jobs = try NativeJobQueue(db: db, paths: paths, events: events)
    }
}
