import Foundation

/// Retain the payload as well as its timestamp so remounting a page never
/// produces an empty frame merely because its last request was recent.
public actor NativePayloadCache {
    private struct Entry { let value: JSONValue; let stored: ContinuousClock.Instant }
    private var entries: [String: Entry] = [:]
    private struct Pending { let id: UUID; let generation: UInt64; let task: Task<JSONValue, Error> }
    private var pending: [String: Pending] = [:]
    private var generations: [String: UInt64] = [:]
    private let clock = ContinuousClock()
    private let capacity: Int
    public init(capacity: Int = 128) { self.capacity = max(1, capacity) }
    public func peek(_ key: String) -> JSONValue? { entries[key]?.value }
    public func invalidate(_ prefix: String) {
        for key in Set(entries.keys).union(pending.keys).union(generations.keys) where key.hasPrefix(prefix) {
            generations[key, default: 0] &+= 1
            pending.removeValue(forKey: key)?.task.cancel()
        }
        entries = entries.filter { !$0.key.hasPrefix(prefix) }
    }
    /// A live snapshot reader follows an invalidation to the new generation.
    /// This is opt-in: ordinary reads still report obsolete work as cancelled.
    /// In particular, a cached Statistics publication can invalidate Home while
    /// its first fanout is suspended; that is a refresh, not a failed domain.
    public func readCurrent(_ key: String, freshness: Duration = .seconds(30), force: Bool = false, load: @escaping @Sendable () async throws -> JSONValue) async throws -> JSONValue {
        var requireFresh = force
        while true {
            try Task.checkCancellation()
            let generation = generations[key, default: 0]
            do {
                let value = try await read(key, freshness: freshness, force: requireFresh, load: load)
                try Task.checkCancellation()
                return value
            } catch let error as CancellationError {
                try Task.checkCancellation()
                guard generations[key, default: 0] != generation else { throw error }
                // Another reader may already have published the fresh value.
                requireFresh = false
            }
        }
    }
    public func read(_ key: String, freshness: Duration = .seconds(30), force: Bool = false, load: @escaping @Sendable () async throws -> JSONValue) async throws -> JSONValue {
        if !force, let entry = entries[key], entry.stored.duration(to: clock.now) < freshness { return entry.value }
        let generation = generations[key, default: 0]
        if let flight = pending[key] {
            let value = try await flight.task.value
            guard generations[key, default: 0] == flight.generation else { throw CancellationError() }
            return value
        }
        let id = UUID()
        let task = Task { let result = try await load(); try Task.checkCancellation(); return result }
        pending[key] = Pending(id: id, generation: generation, task: task)
        do {
            let value = try await task.value
            guard generations[key, default: 0] == generation else { throw CancellationError() }
            entries[key] = Entry(value: value, stored: clock.now)
            if pending[key]?.id == id { pending.removeValue(forKey: key) }
            while entries.count > capacity, let oldest = entries.min(by: { $0.value.stored < $1.value.stored })?.key { entries.removeValue(forKey: oldest) }
            return value
        } catch { if pending[key]?.id == id { pending.removeValue(forKey: key) }; throw error }
    }
}
