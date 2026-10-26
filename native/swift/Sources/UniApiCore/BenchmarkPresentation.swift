import Foundation

private final class BenchmarkPageCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    func cancel() { lock.lock(); cancelled = true; lock.unlock() }
    var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return cancelled }
}

/// Shared by the actual Speed, Results and Switcher models. Events received
/// during first load are retained; every later load commits only its latest
/// request in the current visible lifetime.
@MainActor public final class BenchmarkPageLifecycle {
    private var lifetime: UInt64 = 0, request: UInt64 = 0
    private var active = false, initializing = false
    private var pending: [NativeEvent] = []
    private var listener: Task<Void, Never>?
    private var subscriptionTask: Task<AsyncStream<NativeEvent>, Never>?
    private var preparation: (@MainActor () async -> Bool)?
    private var preparationTask: Task<Bool, Never>?
    private var prepared = true, preparationAttempt: UInt64 = 0
    private var ownerCancellation: BenchmarkPageCancellation?
    public init() {}
    public func begin(events: NativeEvents, matches: @escaping @Sendable (NativeEvent) -> Bool,
                      prepare: (@MainActor () async -> Bool)? = nil,
                      initial: @escaping @MainActor () async -> Void,
                      changed: @escaping @MainActor (NativeEvent) async -> Void) async {
        stop(); active = true; initializing = true; preparation = prepare; prepared = prepare == nil
        let own = lifetime, cancellation = BenchmarkPageCancellation(); ownerCancellation = cancellation
        subscriptionTask = Task { await events.stream() }
        await withTaskCancellationHandler(operation: {
            await beginCurrent(events: events, matches: matches, initial: initial, changed: changed, own: own)
        }, onCancel: { cancellation.cancel() })
        if cancellation.isCancelled, own == lifetime { stop() }
    }
    private func beginCurrent(events: NativeEvents, matches: @escaping @Sendable (NativeEvent) -> Bool,
        initial: @escaping @MainActor () async -> Void, changed: @escaping @MainActor (NativeEvent) async -> Void,
        own: UInt64) async {
        guard let subscriptionTask else { return }
        let stream = await subscriptionTask.value
        guard current(own), !Task.isCancelled else { if current(own) { stop() }; return }
        listener = Task { [weak self] in
            for await event in stream {
                guard !Task.isCancelled, let self, self.current(own) else { return }
                guard matches(event) else { continue }
                if self.initializing { self.pending.append(event); self.pending = Array(self.pending.suffix(256)) }
                else { await changed(event) }
            }
        }
        if await ready() { await initial() }
        guard current(own), !Task.isCancelled else { if current(own) { stop() }; return }
        // Keep buffering while dispatching so newer events cannot overtake a
        // queued start/reset followed by a queued completion.
        while !pending.isEmpty, current(own), !Task.isCancelled {
            let batch = pending; pending.removeAll()
            for event in batch { guard current(own), !Task.isCancelled else { return }; await changed(event) }
        }
        if current(own) { initializing = false }
    }
    /// Preference restoration has its own lifetime, independent of replaceable
    /// payload reads. Reloads join it before capturing their selected scope.
    public func ready() async -> Bool {
        guard current(lifetime), !Task.isCancelled else { return false }
        let subscribedLifetime = lifetime
        if let subscriptionTask { _ = await subscriptionTask.value }
        guard current(subscribedLifetime), !Task.isCancelled else { return false }
        if prepared { return true }
        let own = lifetime, attempt: UInt64, task: Task<Bool, Never>
        if let preparationTask { task = preparationTask; attempt = preparationAttempt }
        else {
            preparationAttempt &+= 1; attempt = preparationAttempt
            let action = preparation
            task = Task { await action?() ?? true }; preparationTask = task
        }
        let accepted = await task.value
        guard current(own), !Task.isCancelled else { return false }
        if attempt == preparationAttempt {
            preparationTask = nil
            if accepted { prepared = true; preparation = nil }
        }
        return accepted
    }
    /// Used only by begin's preparation closure: no reload request ticket can
    /// supersede the one-time settings read. Failed reads remain retryable.
    @discardableResult public func restore<Output>(read: @MainActor () async throws -> Output,
        commit: @MainActor (Output) -> Void, failed: @MainActor (Error) -> Void) async -> Bool {
        guard current(lifetime), !Task.isCancelled else { return false }
        let own = lifetime
        do {
            let value = try await read()
            guard current(own), !Task.isCancelled else { return false }
            commit(value); return true
        } catch {
            guard current(own), !Task.isCancelled else { return false }
            failed(error); return false
        }
    }
    @discardableResult public func perform<Output>(read: @MainActor () async throws -> Output,
        commit: @MainActor (Output) -> Void, failed: @MainActor (Error) -> Void) async -> Bool {
        guard await ready() else { return false }
        request &+= 1; let own = lifetime, ticket = request
        do {
            let value = try await read()
            guard current(own), ticket == request, !Task.isCancelled else { return false }
            commit(value); return true
        } catch {
            guard current(own), ticket == request, !Task.isCancelled else { return false }
            failed(error); return true
        }
    }
    public func invalidate() { request &+= 1 }
    public func stop() {
        active = false; lifetime &+= 1; request &+= 1; initializing = false
        pending.removeAll(); listener?.cancel(); listener = nil
        subscriptionTask?.cancel(); subscriptionTask = nil
        preparationTask?.cancel(); preparationTask = nil; preparation = nil; prepared = true
        ownerCancellation?.cancel(); ownerCancellation = nil
    }
    private func current(_ value: UInt64) -> Bool { active && value == lifetime && ownerCancellation?.isCancelled != true }
}

/// Edits accepted while a saved preference read is suspended overlay only their
/// own fields/provider choices. Restoring a tier must not erase another saved
/// provider, and a user returning to a default value still counts as an edit.
public struct BenchmarkPreferenceEdits: Sendable {
    private var fields: JSONObject = [:]
    private var models: JSONObject = [:]
    private var included: [String: Bool] = [:]
    public init() {}
    public mutating func set(_ field: String, _ value: JSONValue) { fields[field] = value }
    public func contains(_ field: String) -> Bool { fields[field] != nil }
    public mutating func include(_ provider: String, _ enabled: Bool) { included[provider] = enabled }
    public mutating func selectModels(_ provider: String, _ values: JSONValue) { models[provider] = values }
    public func restoring(_ saved: JSONValue) -> JSONValue {
        var value = saved
        for (key, edit) in fields { value[key] = edit }
        if !models.isEmpty {
            var choices = value["models"]
            for (provider, edit) in models { choices[provider] = edit }; value["models"] = choices
        }
        if !included.isEmpty {
            var providers = value["included"].array
            for provider in included.keys.sorted() {
                if included[provider] == true { if !providers.contains(.string(provider)) { providers.append(.string(provider)) } }
                else { providers.removeAll { $0 == .string(provider) } }
            }
            value["included"] = .array(providers)
        }
        return value
    }
}

public enum BenchmarkPresentation {
    public static func family(_ requested: String, summary: JSONValue) -> String {
        requested.isEmpty || summary["cells"].object.values.contains(where: { $0["family"] == .string(requested) }) ? requested : ""
    }
    public static let outcomes = ["works", "limited", "empty", "missing", "denied", "timeout", "failed", "skipped"]
    public static func freeRows(_ report: JSONValue, query: String, outcome: String = "all") -> [JSONValue] {
        let terms = query.lowercased().split(whereSeparator: \.isWhitespace)
        return report["rows"].array.filter { row in
            let text = (row["model"].string + " " + row["provider"].string).lowercased()
            return (outcome == "all" || row["outcome"] == .string(outcome)) && terms.allSatisfy { text.contains($0) }
        }
    }
    public static func outcomeLabel(_ outcome: String) -> String {
        ["works": "Free and working", "limited": "Out of allowance", "empty": "Answered empty", "missing": "Not on this provider", "denied": "Key not entitled", "timeout": "Never answered", "failed": "Failed", "skipped": "Not tested"][outcome] ?? outcome
    }
}
