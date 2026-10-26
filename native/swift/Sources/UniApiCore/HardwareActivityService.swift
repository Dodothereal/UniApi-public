import Foundation

public struct NativeActivityIO: Sendable {
    public var sample: @Sendable () async throws -> JSONValue
    public var terminate: @Sendable (JSONValue) async throws -> JSONValue
    public var now: @Sendable () -> Double
    public init(sample: @escaping @Sendable () async throws -> JSONValue = { try await NativeActivitySystem.sample() }, terminate: @escaping @Sendable (JSONValue) async throws -> JSONValue = { try await NativeActivitySystem.terminate($0) }, now: @escaping @Sendable () -> Double = { Date().timeIntervalSince1970 * 1000 }) {
        self.sample = sample; self.terminate = terminate; self.now = now
    }
}

/// Demand-only telemetry. Leaving Activity cancels its view's poll loop;
/// the service itself creates no background sampler or job.
public actor NativeActivityService {
    private let io: NativeActivityIO
    private let readOnly: Bool
    private var previous: JSONValue = .null
    private var snapshot: JSONValue = .null
    private var error: JSONValue = .null
    private var lastRead: Double = -.infinity
    private var flight: (id: UUID, task: Task<JSONValue, Never>)?
    private var acting = false
    public init(io: NativeActivityIO = .init(), readOnly: Bool = false) { self.io = io; self.readOnly = readOnly }
    public func handle(_ operation: String, input: JSONObject = [:]) async throws -> JSONValue {
        switch operation {
        case "status": return await refresh(force: (input["force"] ?? false).bool)
        case "summary": return ["supported": true, "installed": true]
        case "terminate":
            guard !readOnly else { throw NativeFailure("This runtime is read-only") }
            let action = try NativeActivityFold.action(.object(input))
            guard !acting else { throw NativeFailure("Another quit request is in progress") }
            acting = true; defer { acting = false }
            let fresh = await refresh(force: true)
            guard fresh["error"].isNull, !fresh["snapshot"].isNull else { throw NativeFailure("Live readings are unavailable; refresh before quitting") }
            let groups = fresh["snapshot"]["groups"].array
            let group = groups.first { $0["id"] == action["id"] }
            let process = action["process"].bool ? groups.flatMap { $0["processes"].array }.first { $0["id"] == action["id"] } : nil
            guard group != nil || process != nil else { throw NativeFailure("The app or process exited or restarted; select it again") }
            let selected = process ?? group!
            if !selected["protectedReason"].isNull { throw NativeFailure(selected["protectedReason"].string) }
            let application = process == nil && group?["kind"].string == "app"
            let members = process.map { [$0] } ?? (application && action["mode"].string == "quit" ? group!["processes"].array.filter { $0["id"] == group!["rootId"] } : group!["processes"].array)
            let request: JSONValue = ["mode": action["mode"], "application": .bool(application), "targets": .array(members.map { ["pid": $0["pid"], "started": $0["started"]] })]
            let result = try await io.terminate(request)
            lastRead = -.infinity
            return result
        default: throw NativeFailure("Unknown Activity operation: \(operation)")
        }
    }
    private func refresh(force: Bool) async -> JSONValue {
        while let pending = flight {
            let result = await pending.task.value
            if !force { return result }
            if flight?.id == pending.id { flight = nil }
        }
        if !force && io.now() - lastRead < 750 { return status() }
        let id = UUID(), task = Task { await self.read() }; flight = (id, task)
        let value = await task.value; if flight?.id == id { flight = nil }
        return value
    }
    private func read() async -> JSONValue {
        do {
            let raw = try await io.sample()
            snapshot = try NativeActivityFold.snapshot(raw, previous: previous)
            previous = raw; error = .null
        } catch { self.error = .string(error.localizedDescription) }
        lastRead = io.now()
        return status()
    }
    private func status() -> JSONValue { ["supported": true, "installed": true, "snapshot": snapshot, "error": error] }
}
