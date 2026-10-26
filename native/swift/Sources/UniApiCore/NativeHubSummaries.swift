import Foundation

/// Page summaries never schedule inference, hardware changes or usage scans.
/// Injected readers keep integration fixtures completely detached from apps.
public actor NativeHubSummaries {
    private let runtime: NativeRuntime
    private let read: @Sendable (String) async throws -> JSONValue
    public init(runtime: NativeRuntime, transcription: NativeTranscriptionService? = nil, read: (@Sendable (String) async throws -> JSONValue)? = nil) {
        self.runtime = runtime
        if let read { self.read = read; return }
        let transcription = transcription ?? NativeTranscriptionService(runtime: runtime)
        let statistics = NativeStatisticsService.shared(runtime: runtime)
        self.read = { domain in
            switch domain {
            case "switcher": return try await NativeSwitcherService.shared(runtime: runtime).handle("status")
            case "code": return try await NativeCodeService.shared(runtime: runtime).handle("summary")
            case "arena": return try await NativeArenaService.shared(runtime: runtime).handle("summary")
            case "transcribe": return try await transcription.handle("summary")
            case "stats": return statistics.cachedSummary()
            case "bench": return try await NativeBenchmarkService.shared(runtime: runtime).handle("home")
            default: throw NativeFailure("Unknown summary domain")
            }
        }
    }
    public func snapshot(force: Bool = false) async throws -> JSONValue {
        try await runtime.cache.readCurrent("hub:summaries", force: force, load: NativeHubSummaryFanout.loader(read))
    }
    public func badges() async -> JSONValue {
        async let code = read("code"), arena = read("arena")
        var result: JSONValue = [:]
        if let value = try? await code { result["code"] = value["pendingPermissions"] }
        if let value = try? await arena { result["arena"] = value["pendingVotes"] }
        result["jobs"] = (try? runtime.db.query("SELECT COUNT(*) AS n FROM jobs WHERE status IN ('running','queued')").first?["n"]) ?? .null
        return result
    }
}

private enum NativeHubSummaryFanout {
    /// Swift 6.4 -O aborts in TaskGroup::offer for the actor -> escaping cache
    /// loader pattern, even without UI or data. Six explicit tasks retain
    /// parallel reads and avoid that group path; optimized fixtures pin this.
    nonisolated static func loader(_ reader: @escaping @Sendable (String) async throws -> JSONValue) -> @Sendable () async throws -> JSONValue {
        { @Sendable in
            let work = ["switcher", "code", "arena", "transcribe", "stats", "bench"].map { domain in
                (domain, Task<JSONValue, Never> {
                    do { try Task.checkCancellation(); return try await reader(domain) }
                    catch { return ["error": .string(error.localizedDescription)] }
                })
            }
            return await withTaskCancellationHandler {
                var values: JSONObject = [:]
                for (domain, task) in work { values[domain] = await task.value }
                return .object(values)
            } onCancel: {
                for (_, task) in work { task.cancel() }
            }
        }
    }
}
