import Foundation
import Combine
import UniApiCore

package protocol NativeStatsModelService: Sendable {
    func handle(_ operation: String, input: JSONObject) async throws -> JSONValue
}

extension NativeStatisticsService: NativeStatsModelService {}

package struct NativeStatsScope: Hashable, Sendable {
    package var source: String
    package var range: Int
    package var model: String?
    package init(source: String, range: Int, model: String? = nil) {
        self.source = source; self.range = range; self.model = model
    }
}

package struct NativeStatsSnapshot: Sendable {
    package let payload: JSONValue
    package let benchmark: JSONValue
}

/// A successful forced scan and its visible publication can arrive in either
/// order: stats.scanned may replace the manual read before its receipt returns.
/// Only a new coherent publication with that exact scan identity is admissible.
package struct NativeStatsRefreshAdmission {
    package enum Status: Equatable { case pending, ready, failed, incomplete, cancelled }
    package let scope: NativeStatsScope
    package private(set) var status: Status = .pending
    private var scanID: String?
    private var returned = false, busy = false, publicationFailed = false
    private var publication: NativeStatsSnapshot?
    package init(scope: NativeStatsScope) { self.scope = scope }
    package mutating func readStarted() {
        guard status != .cancelled, status != .incomplete else { return }
        busy = true; publication = nil; publicationFailed = false; status = .pending
    }
    package mutating func published(payload: JSONValue, benchmark: JSONValue, failed: Bool) {
        guard status != .cancelled, status != .incomplete, busy else { return }
        busy = false; publicationFailed = failed
        publication = NativeStatsSnapshot(payload: payload, benchmark: benchmark)
        reconcile()
    }
    package mutating func operationCompleted(scanID: String) {
        guard status != .cancelled, status != .incomplete, !scanID.isEmpty else { return }
        self.scanID = scanID; reconcile()
    }
    package mutating func operationReturned() { returned = true; reconcile() }
    package mutating func cancel() { publication = nil; status = .cancelled }
    private mutating func reconcile() {
        guard status != .cancelled, status != .incomplete else { return }
        guard let scanID else {
            status = returned ? publicationFailed ? .failed : .incomplete : .pending
            return
        }
        guard !busy else { status = .pending; return }
        if publicationFailed { status = .failed; return }
        guard let publication else { status = .pending; return }
        let payload = publication.payload
        guard payload["loaded"].bool, !publication.benchmark.isNull else { status = .incomplete; return }
        guard payload["source"].string == scope.source, payload["range"].int == scope.range,
              scope.model == nil ? payload["model"].isNull : payload["model"].string == scope.model else {
            status = .cancelled; return
        }
        let publishedID = payload["scan"]["scanId"].string
        // Detail responses currently have no scan identity. Never infer one
        // from retained data or a progress event belonging to another read.
        guard !publishedID.isEmpty else { status = .incomplete; return }
        status = publishedID == scanID ? .ready : .pending
    }
}

package enum NativeStatsLoadMode: Sendable {
    case cached, refresh, rebuild

    var operation: String? {
        switch self {
        case .cached: nil
        case .refresh: "refresh"
        case .rebuild: "rescan"
        }
    }
}

/// File progress belongs to its small reading label, not the chart hierarchy.
@MainActor package final class NativeStatsReadProgress: ObservableObject {
    @Published package var value: JSONValue = [:]
    package init() {}
}

/// Owned by one shell/runtime. Revisiting a tab keeps its last complete scope,
/// while explicit Reload awaits metadata refresh and Rebuild All reparses history.
@MainActor package final class NativeStatsModel: ObservableObject {
    package let service: any NativeStatsModelService
    @Published package var payload: JSONValue = .null
    @Published package var benchmark: JSONValue = .null
    @Published package var error = ""
    @Published package var busy = false
    package let readProgress = NativeStatsReadProgress()
    @Published private var snapshotRevision: UInt64 = 0
    private let lifecycle = BenchmarkPageLifecycle()
    private let clock: () -> TimeInterval
    private let day: () -> Date
    private var request: UInt64 = 0
    private var pageOwner: UUID?
    private var epoch: UInt64 = 0
    private struct Entry {
        var value: NativeStatsSnapshot
        var time: TimeInterval
        var epoch: UInt64
        var id: UUID
        var day: Date
    }
    private final class Flight: @unchecked Sendable {
        let id = UUID(), epoch: UInt64, day: Date
        let task: Task<NativeStatsSnapshot, Error>
        private let lock = NSLock()
        private var owners: [UUID: Bool] = [:]
        private var cancelled = false
        init(epoch: UInt64, day: Date, task: Task<NativeStatsSnapshot, Error>) { self.epoch = epoch; self.day = day; self.task = task }
        func add(_ owner: UUID, visible: Bool) -> Bool {
            lock.lock(); defer { lock.unlock() }
            guard !cancelled else { return false }
            owners[owner] = visible; return true
        }
        func release(_ owner: UUID) {
            lock.lock(); owners[owner] = nil
            let cancel = owners.isEmpty && !cancelled
            if cancel { cancelled = true }
            lock.unlock()
            if cancel { task.cancel() }
        }
        var ownerCount: Int { lock.lock(); defer { lock.unlock() }; return owners.count }
        func stop(discard: Bool) {
            lock.lock()
            owners = discard ? [:] : owners.filter { !$0.value }
            let cancel = owners.isEmpty && !cancelled
            if cancel { cancelled = true }
            lock.unlock()
            if cancel { task.cancel() }
        }
    }
    private var snapshots: [NativeStatsScope: Entry] = [:]
    private var recent: [NativeStatsScope] = []
    private var flights: [NativeStatsScope: Flight] = [:]
    // Invalidating a scope replaces its joinable flight, but its earlier readers
    // still belong to this shell and must remain reachable during teardown.
    private var activeFlights: [UUID: Flight] = [:]
    private let capacity = 12
    var pendingReaderCount: Int { activeFlights.values.reduce(0) { $0 + $1.ownerCount } }

    package convenience init(runtime: NativeRuntime) {
        self.init(service: NativeStatisticsService.shared(runtime: runtime))
    }
    init(service: any NativeStatsModelService, clock: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }, day: @escaping () -> Date = { Calendar.current.startOfDay(for: Date()) }) {
        self.service = service; self.clock = clock; self.day = day
    }

    package func snapshot(source: String, range: Int, model: String?) -> NativeStatsSnapshot? {
        let scope = NativeStatsScope(source: source, range: range, model: model)
        if let cached = snapshots[scope] { return cached.value }
        if payload["loaded"].bool, payload["source"].string == source,
           payload["range"].int == range,
           model == nil ? payload["model"].isNull : payload["model"].string == model {
            return NativeStatsSnapshot(payload: payload, benchmark: benchmark)
        }
        return nil
    }

    package func invalidateSnapshots() { epoch &+= 1 }

    /// Only reads: no listener, poller, preference write or inference is started.
    /// A concurrent visible read joins this same scope's in-flight request.
    package func prefetch(source: String, range: Int) async {
        do { _ = try await fetch(NativeStatsScope(source: source, range: range), visible: false) }
        catch { /* The visible page retries and presents its own read error. */ }
    }

    package func load(source: String, range: Int, model: String?, mode: NativeStatsLoadMode = .cached,
                      operationCompleted: (@MainActor (String) -> Void)? = nil) async {
        if mode.operation != nil { invalidateSnapshots() }
        request &+= 1; let own = request
        // The retained payload can outlive a read; its file counter cannot.
        readProgress.value = ["phase": "loading"]; busy = true
        let scope = NativeStatsScope(source: source, range: range, model: model)
        await lifecycle.perform(read: {
            guard own == self.request else { throw CancellationError() }
            if let operation = mode.operation {
                let result = try await self.service.handle(operation, input: [:])
                // The scan's event read may already own the visible request.
                // Its successful operation receipt remains useful independently
                // of whether this older request is still allowed to commit.
                if let operationCompleted {
                    let scanID = result["scan"]["scanId"].string
                    if result["ok"].bool, !scanID.isEmpty { operationCompleted(scanID) }
                }
                guard own == self.request else { throw CancellationError() }
                try Task.checkCancellation()
                // Never reuse a request begun before the completed forced scan.
                self.invalidateSnapshots()
                self.readProgress.value = ["phase": "loading"]
            }
            try Task.checkCancellation()
            return try await self.fetch(scope, visible: true, visibleRequest: own)
        }, commit: { value in
            guard own == self.request else { return }
            self.payload = value.payload; self.benchmark = value.benchmark
            self.error = ""; self.busy = false
        }, failed: { error in
            guard own == self.request else { return }
            self.error = error.localizedDescription; self.busy = false
        })
    }

    package func begin(runtime: NativeRuntime, owner: UUID? = nil, changed: @escaping @MainActor () async -> Void) async {
        await begin(events: runtime.events, owner: owner, changed: changed)
    }
    func begin(events: NativeEvents, owner: UUID? = nil, changed: @escaping @MainActor () async -> Void) async {
        // Retire button tasks from the old page before subscription can suspend.
        request &+= 1
        readProgress.value = ["phase": "loading"]
        for flight in activeFlights.values { flight.stop(discard: false) }
        pageOwner = owner ?? UUID()
        await lifecycle.begin(events: events,
            matches: { ["stats.progress", "stats.scanned", "stats.failed"].contains($0.topic) },
            initial: changed, changed: { [weak self] event in
                guard let self else { return }
                if event.topic == "stats.progress" { self.readProgress.value = event.data }
                else if event.topic == "stats.failed" { self.error = event.data.string; self.busy = false }
                else { self.invalidateSnapshots(); await changed() }
            })
    }
    package func stop(owner: UUID? = nil, discard: Bool = false) {
        guard owner == nil || owner == pageOwner else { return }
        lifecycle.stop(); request &+= 1; busy = false
        readProgress.value = ["phase": "loading"]
        pageOwner = nil
        for flight in activeFlights.values { flight.stop(discard: discard) }
    }

    private func fetch(_ scope: NativeStatsScope, visible: Bool, visibleRequest: UInt64? = nil) async throws -> NativeStatsSnapshot {
        while true {
            try Task.checkCancellation()
            guard visibleRequest == nil || visibleRequest == request else { throw CancellationError() }
            if let hit = snapshots[scope], hit.epoch == epoch, hit.day == day(),
               clock() >= hit.time, clock() - hit.time < 30 {
                touch(scope); return hit.value
            }
            let flight: Flight, owner = UUID()
            let currentDay = day()
            if let existing = flights[scope], existing.epoch == epoch, existing.day == currentDay,
               existing.add(owner, visible: visible) { flight = existing }
            else {
                let service = service
                let task = Task(priority: visible ? .userInitiated : .utility) {
                    try Task.checkCancellation()
                    var input: JSONObject = ["source": .string(scope.source), "range": .number(Double(scope.range))]
                    if let model = scope.model { input["model"] = .string(model) }
                    let response = try await service.handle(scope.model == nil ? "overview" : "model", input: input)
                    try Task.checkCancellation()
                    guard response["loaded"].bool else { throw NativeFailure("Usage data has not finished loading.") }
                    guard response["source"].string == scope.source, response["range"].int == scope.range,
                          scope.model == nil ? response["model"].isNull : response["model"].string == scope.model else {
                        throw NativeFailure("Usage response does not match the requested scope.")
                    }
                    let bench: JSONValue
                    if scope.model != nil { bench = response["bench"] }
                    else if scope.source == "all" { bench = try await service.handle("bench", input: [:]) }
                    else { bench = [:] }
                    try Task.checkCancellation()
                    return NativeStatsSnapshot(payload: response, benchmark: bench)
                }
                flight = Flight(epoch: epoch, day: currentDay, task: task)
                _ = flight.add(owner, visible: visible); flights[scope] = flight
                activeFlights[flight.id] = flight
            }
            defer { flight.release(owner) }
            do {
                let value = try await withTaskCancellationHandler(operation: { try await flight.task.value }, onCancel: { flight.release(owner) })
                if flights[scope]?.id == flight.id { flights[scope] = nil }
                activeFlights[flight.id] = nil
                try Task.checkCancellation()
                guard visibleRequest == nil || visibleRequest == request else { throw CancellationError() }
                guard flight.epoch == epoch, flight.day == day() else { continue }
                if snapshots[scope]?.id != flight.id {
                    snapshots[scope] = Entry(value: value, time: clock(), epoch: epoch, id: flight.id, day: flight.day)
                    touch(scope)
                    while recent.count > capacity { snapshots[recent.removeFirst()] = nil }
                    snapshotRevision &+= 1
                }
                return value
            } catch {
                if flights[scope]?.id == flight.id { flights[scope] = nil }
                activeFlights[flight.id] = nil
                throw error
            }
        }
    }
    private func touch(_ scope: NativeStatsScope) {
        recent.removeAll { $0 == scope }; recent.append(scope)
    }
}
