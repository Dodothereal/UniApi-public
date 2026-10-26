import Foundation
import Combine
import UniApiCore

@MainActor package final class NativeArenaModel: ObservableObject {
    private let service: any NativeArenaModelService
    @Published package var state: JSONValue = .null
    @Published package var matches: [JSONValue] = []
    @Published package var standings: [JSONValue] = []
    @Published package var ledger: JSONValue = .null
    @Published package var recent: [JSONValue] = []
    @Published package private(set) var rankingLoadedMode: String? = nil
    @Published package private(set) var rankingLoadingMode: String? = nil
    @Published private var rankingFailureMode: String? = nil
    @Published package var live: [String: JSONValue] = [:]
    @Published package var transcripts: [String: [JSONValue]] = [:]
    @Published package var output = ""
    @Published package private(set) var busy = false
    @Published package private(set) var readActive = false
    @Published package private(set) var readGeneration: UInt64 = 0
    @Published private var stateLoaded = false
    @Published private var matchesLoaded = false
    @Published private var commandError = ""
    @Published private var readErrors: [String: String] = [:]
    @Published private var contentErrors: [String: String] = [:]
    package struct ContentOwner: Equatable {
        fileprivate let id: UUID
        fileprivate let lifetime: UUID
        fileprivate let slot: String
        fileprivate let tab: String
    }
    private var contentOwners: [String: ContentOwner] = [:]
    package var loaded: Bool { stateLoaded && matchesLoaded }
    package var failed: Bool { readErrors["state"] != nil || readErrors["matches"] != nil }
    package enum RankingPhase: Equatable { case pending, loading, ready, failed }
    package func rankingHasContent(for mode: String) -> Bool { rankingLoadedMode == mode }
    package func rankingPhase(for mode: String) -> RankingPhase {
        if rankingLoadingMode == mode { return .loading }
        if rankingFailureMode == mode, readErrors["ranking"] != nil { return .failed }
        return rankingHasContent(for: mode) ? .ready : .pending
    }
    package var error: String { pageError(includeRanking: true) }
    package func pageError(includeRanking: Bool) -> String {
        if !commandError.isEmpty { return commandError }
        return readErrors.filter { includeRanking || $0.key != "ranking" }.sorted { $0.key < $1.key }.first?.value ?? ""
    }

    private let reads = NativePageReadScope()
    private var lifetime = UUID()
    private var listener: Task<Void, Never>?
    private var pendingReads: [String: (id: UUID, task: Task<JSONValue?, Never>)] = [:]
    private var sharing = 0
    private var rankingChoice = 0
    private var rankingMode = "all"
    private var revision = 0
    private struct Change { let revision: Int; let topic: String; let value: JSONValue }
    private var matchChanges: [String: Change] = [:]
    private var slotChanges: [String: Change] = [:]
    private var liveChanges: [String: Change] = [:]
    private var presetChange: Change?
    private var streamEvents: [String: [Int: Change]] = [:]
    private var requestedTranscripts = Set<String>()
    private var transcriptRequests: [String: UUID] = [:]
    private static let readOperations: Set<String> = ["state", "presets", "matches", "match", "events", "files", "preview", "ranking", "ledger.status", "ledger.records", "summary"]

    package convenience init(runtime: NativeRuntime) { self.init(service: NativeArenaService.shared(runtime: runtime)) }
    init(service: any NativeArenaModelService) { self.service = service; reads.suspend() }

    package func begin(runtime: NativeRuntime) async { await begin(events: runtime.events) }
    func begin(events: NativeEvents) async {
        guard !Task.isCancelled else { return }
        stop(); reads.resume()
        let owner = lifetime
        await withTaskCancellationHandler(operation: {
            guard !Task.isCancelled, lifetime == owner, reads.active else { return }
            // Register before the first service await. The listener keeps draining
            // while reads are held, so streamed changes can reconcile their replies.
            let stream = await events.stream()
            let task = Task { [weak self] in
                for await event in stream {
                    guard let self, !Task.isCancelled, self.lifetime == owner, self.readActive else { break }
                    self.receive(event, owner: owner)
                }
            }
            guard !Task.isCancelled, lifetime == owner, reads.active else { task.cancel(); return }
            listener = task; readActive = true
            await load()
            // The model owns the listener after initial reads finish. Activity
            // suspension stops it synchronously, without task-end cleanup.
        }, onCancel: { [weak self] in
            Task { @MainActor in self?.stop(owner: owner) }
        })
    }
    package func stop() {
        readActive = false; readGeneration &+= 1; lifetime = UUID(); reads.suspend()
        rankingLoadingMode = nil
        listener?.cancel(); listener = nil
        let pending = pendingReads.values.map(\.task); pendingReads.removeAll()
        pending.forEach { $0.cancel() }
        requestedTranscripts.removeAll(); transcriptRequests.removeAll()
        streamEvents.removeAll(); matchChanges.removeAll(); slotChanges.removeAll()
        liveChanges.removeAll(); presetChange = nil
        contentOwners.removeAll(); contentErrors.removeAll()
    }
    private func stop(owner: UUID) { if lifetime == owner { stop() } }
    private func accepts(_ ticket: NativePageReadScope.Ticket, parent: NativePageReadScope.Ticket? = nil) -> Bool {
        readActive && reads.accepts(ticket) && (parent.map { reads.accepts($0) } ?? true)
    }
    private func check(_ ticket: NativePageReadScope.Ticket) throws {
        guard accepts(ticket) else { throw CancellationError() }
    }
    package func beginContent(_ slot: String, tab: String) -> ContentOwner? {
        guard readActive, !Task.isCancelled else { return nil }
        if let previous = contentOwners[slot] { endContent(previous) }
        guard ["Files", "Transcript"].contains(tab) else { return nil }
        let owner = ContentOwner(id: UUID(), lifetime: lifetime, slot: slot, tab: tab)
        contentOwners[slot] = owner; return owner
    }
    package func endContent(_ owner: ContentOwner) {
        guard contentOwners[owner.slot] == owner else { return }
        contentOwners.removeValue(forKey: owner.slot); contentErrors.removeValue(forKey: owner.slot)
        let lane = owner.tab == "Transcript" ? "transcript:" + owner.slot : "call:files:" + owner.slot + ":"
        reads.invalidate(lane); pendingReads[lane]?.task.cancel()
        if owner.tab == "Transcript" {
            requestedTranscripts.remove(owner.slot); transcriptRequests.removeValue(forKey: owner.slot)
            streamEvents.removeValue(forKey: owner.slot)
        }
    }
    package func contentError(_ slot: String, tab: String) -> String {
        guard contentOwners[slot]?.tab == tab else { return "" }
        return contentErrors[slot] ?? ""
    }
    private func accepts(_ owner: ContentOwner) -> Bool {
        readActive && !Task.isCancelled && owner.lifetime == lifetime && contentOwners[owner.slot] == owner
    }

    private func read(_ lane: String, parent: NativePageReadScope.Ticket? = nil,
                      contentRead: Bool = false, content: ContentOwner? = nil,
                      operation: @escaping @MainActor (NativePageReadScope.Ticket) async throws -> JSONValue,
                      commit: @escaping @MainActor (JSONValue) -> Void = { _ in }) async -> JSONValue? {
        guard readActive, parent.map({ reads.accepts($0) }) ?? !Task.isCancelled,
              let ticket = reads.begin(lane) else { return nil }
        let id = UUID()
        pendingReads[lane]?.task.cancel()
        let task = Task { [weak self] () -> JSONValue? in
            guard let self, self.accepts(ticket, parent: parent), content.map({ self.accepts($0) }) ?? true else { return nil }
            do {
                let value = try await operation(ticket)
                guard self.accepts(ticket, parent: parent), content.map({ self.accepts($0) }) ?? true else { return nil }
                commit(value)
                if contentRead { if let content { self.contentErrors.removeValue(forKey: content.slot) } }
                else { self.readErrors.removeValue(forKey: lane) }
                return value
            } catch {
                guard self.accepts(ticket, parent: parent), content.map({ self.accepts($0) }) ?? true,
                      !(error is CancellationError) else { return nil }
                // A content failure belongs only to the currently mounted slot
                // tab. Background cache reads have no visible error owner.
                if contentRead { if let content { self.contentErrors[content.slot] = error.localizedDescription } }
                else { self.readErrors[lane] = error.localizedDescription }
                return nil
            }
        }
        pendingReads[lane] = (id, task)
        let value = await withTaskCancellationHandler(operation: { await task.value }, onCancel: { task.cancel() })
        if pendingReads[lane]?.id == id { pendingReads.removeValue(forKey: lane) }
        return value
    }
    private func readState(parent: NativePageReadScope.Ticket? = nil) async {
        let start = revision
        _ = await read("state", parent: parent, operation: { ticket in
            try self.check(ticket)
            let value = try await self.service.handle("state", input: [:])
            try self.check(ticket); return value
        }, commit: { value in
            var next = value
            if let change = self.presetChange, change.revision > start { next["presets"] = change.value }
            self.state = next; self.stateLoaded = true
        })
    }
    package func load() async {
        guard readActive, let batch = reads.begin("load") else { return }
        let start = revision
        await readState(parent: batch)
        guard accepts(batch) else { return }
        _ = await read("matches", parent: batch, operation: { ticket in
            try self.check(ticket)
            let value = try await self.service.handle("matches", input: ["view": "all", "limit": 500])
            try self.check(ticket); return value
        }, commit: { value in
            var next = value.array
            let changes = Array(self.matchChanges.values) + Array(self.slotChanges.values)
            for change in changes.filter({ $0.revision > start }).sorted(by: { $0.revision < $1.revision }) {
                self.apply(change, to: &next)
            }
            self.matches = next; self.matchesLoaded = true
            for match in next { for (id, snapshot) in match["live"].object where (self.liveChanges[id]?.revision ?? 0) <= start { self.live[id] = snapshot } }
        })
    }
    package func reload(ranking mode: String?) async {
        guard readActive, let batch = reads.begin("reload") else { return }
        let choice = rankingChoice
        await load()
        guard accepts(batch), choice == rankingChoice, let mode else { return }
        await ranking(mode)
    }
    package func ranking(_ mode: String) async {
        guard !Task.isCancelled else { return }
        rankingMode = mode; rankingChoice += 1
        let choice = rankingChoice, owner = lifetime
        if readActive { rankingLoadingMode = mode; rankingFailureMode = nil }
        let value = await read("ranking", operation: { ticket in
            try self.check(ticket)
            let ranking = try await self.service.handle("ranking", input: ["mode": .string(mode)])
            try self.check(ticket)
            let recent = try await self.service.handle("ledger.records", input: [:])
            try self.check(ticket)
            return ["ranking": ranking, "recent": recent]
        }, commit: { value in
            self.standings = value["ranking"]["standings"].array
            self.ledger = value["ranking"]["ledger"]; self.recent = value["recent"].array
            self.rankingLoadedMode = mode
        })
        // Only the current request may settle its indicator; cancelled reads
        // already retain their existing ticket and error-publication rules.
        guard lifetime == owner, rankingChoice == choice else { return }
        rankingLoadingMode = nil
        if readActive, !Task.isCancelled, value == nil, readErrors["ranking"] != nil { rankingFailureMode = mode }
    }
    package func transcript(_ id: String, content owner: ContentOwner? = nil) async {
        guard readActive, !Task.isCancelled, owner.map({ accepts($0) && $0.slot == id && $0.tab == "Transcript" }) ?? true else { return }
        let content = owner ?? contentOwners[id].flatMap { $0.tab == "Transcript" ? $0 : nil }
        requestedTranscripts.insert(id)
        let request = UUID(); transcriptRequests[id] = request
        let start = revision
        _ = await read("transcript:" + id, contentRead: true, content: content, operation: { ticket in
            var events: [Int: JSONValue] = [:], after = 0
            while true {
                try self.check(ticket)
                let page = try await self.service.handle("events", input: ["id": .string(id), "after": .number(Double(after))]).array
                try self.check(ticket)
                for event in page { events[event["seq"].int] = event }
                guard page.count == 5000, let last = page.last else { break }
                guard last["seq"].int > after else { throw NativeFailure("Arena transcript pagination did not advance") }
                after = last["seq"].int
            }
            return .array(events.values.sorted { $0["seq"].int < $1["seq"].int })
        }, commit: { value in
            var merged = Dictionary(value.array.map { ($0["seq"].int, $0) }, uniquingKeysWith: { _, new in new })
            for event in self.transcripts[id] ?? [] where merged[event["seq"].int] == nil { merged[event["seq"].int] = event }
            // Stored events are immutable. A reveal read may contain identities
            // that an overlapping live frame deliberately redacts; history wins
            // duplicate sequences while live-only tail events are retained.
            for (seq, change) in self.streamEvents[id] ?? [:] where change.revision > start && merged[seq] == nil { merged[seq] = change.value }
            self.transcripts[id] = merged.values.sorted { $0["seq"].int < $1["seq"].int }
        })
        if transcriptRequests[id] == request {
            transcriptRequests.removeValue(forKey: id); requestedTranscripts.remove(id)
            streamEvents.removeValue(forKey: id)
        }
    }

    package func call(_ op: String, _ input: JSONObject = [:], content owner: ContentOwner? = nil) async -> JSONValue? {
        if Self.readOperations.contains(op) {
            guard owner.map({ accepts($0) && $0.slot == input["id"]?.string && $0.tab == "Files" && op == "files" }) ?? true else { return nil }
            let isContent = ["files", "preview", "events"].contains(op)
            return await read("call:" + op + ":" + (input["id"]?.string ?? "") + ":" + (input["path"]?.string ?? ""), contentRead: isContent, content: owner, operation: { ticket in
                try self.check(ticket)
                let result = try await self.service.handle(op, input: input)
                try self.check(ticket); return result
            })
        }
        // A dispatched mutation belongs to the model/service, not a replaceable
        // page reader. Departure must not discard its result or cancel its work.
        let service = self.service
        let command = Task { try await service.handle(op, input: input) }
        do {
            let result = try await command.value
            reconcileCommand(op, input: input, result: result)
            commandError = ""; return result
        } catch { commandError = error.localizedDescription; return nil }
    }
    package func performMatchAction(_ op: String, id: JSONValue, input: JSONObject = [:], after: (@MainActor () -> Void)? = nil) async -> Bool {
        var body = input; body["id"] = id
        guard await call(op, body) != nil else { return false }
        await load()
        after?()
        return true
    }
    package func share(_ op: String, mode: String) async {
        sharing += 1; busy = true
        defer { sharing -= 1; busy = sharing > 0 }
        let choice = rankingChoice, owner = lifetime
        if let result = await call(op) { output = result["output"].string }
        guard readActive, lifetime == owner, !Task.isCancelled else { return }
        await ranking(choice == rankingChoice ? mode : rankingMode)
    }
    private func reconcileCommand(_ op: String, input: JSONObject, result: JSONValue) {
        switch op {
        case "settings":
            reads.invalidate("state"); pendingReads["state"]?.task.cancel()
            state = result; stateLoaded = true; readErrors.removeValue(forKey: "state")
        case "preset.save":
            var presets = state["presets"].array
            if let index = presets.firstIndex(where: { $0["id"] == result["id"] }) { presets[index] = result } else { presets.append(result) }
            revision += 1; state["presets"] = .array(presets)
            presetChange = Change(revision: revision, topic: "arena.presets", value: .array(presets))
        case "preset.delete":
            revision += 1; state["presets"] = .array(state["presets"].array.filter { $0["id"] != input["id"] })
            presetChange = Change(revision: revision, topic: "arena.presets", value: state["presets"])
        case "match.create", "rerun", "vote", "skip":
            revision += 1
            let change = Change(revision: revision, topic: "arena.match", value: result)
            matchChanges[result["id"].string] = change; apply(change, to: &matches)
        case "delete": deleteMatch(input["id"] ?? .null)
        default: break
        }
    }
    private func receive(_ event: NativeEvent, owner: UUID) {
        guard readActive, lifetime == owner else { return }
        revision += 1
        let change = Change(revision: revision, topic: event.topic, value: event.data)
        switch event.topic {
        case "arena.match":
            matchChanges[event.data["id"].string] = change; apply(change, to: &matches)
            if event.data["revealed"].bool {
                for slot in event.data["slots"].array {
                    let id = slot["id"].string
                    if transcripts[id] != nil || requestedTranscripts.contains(id) {
                        Task { [weak self] in guard let self, self.lifetime == owner, self.readActive else { return }; await self.transcript(id) }
                    }
                }
            }
            scheduleState(owner: owner)
        case "arena.match.deleted": deleteMatch(event.data["id"]); scheduleState(owner: owner)
        case "arena.slot": slotChanges[event.data["id"].string] = change; apply(change, to: &matches)
        case "arena.slot.live": liveChanges[event.data["slotId"].string] = change; live[event.data["slotId"].string] = event.data
        case "arena.slot.event":
            let id = event.data["slotId"].string, value = event.data["event"], seq = value["seq"].int
            guard requestedTranscripts.contains(id) || transcripts[id] != nil else { return }
            if requestedTranscripts.contains(id) { streamEvents[id, default: [:]][seq] = Change(revision: revision, topic: event.topic, value: value) }
            if let current = transcripts[id] {
                var merged = Dictionary(current.map { ($0["seq"].int, $0) }, uniquingKeysWith: { _, new in new })
                if merged[seq] == nil { merged[seq] = value }
                transcripts[id] = merged.values.sorted { $0["seq"].int < $1["seq"].int }
            }
        case "arena.presets": presetChange = change; state["presets"] = event.data
        default: break
        }
    }
    private func scheduleState(owner: UUID) {
        reads.invalidate("state"); pendingReads["state"]?.task.cancel()
        Task { [weak self] in guard let self, self.lifetime == owner, self.readActive else { return }; await self.readState() }
    }
    private func deleteMatch(_ id: JSONValue) {
        revision += 1
        let value: JSONValue = ["id": id]
        matchChanges[id.string] = Change(revision: revision, topic: "arena.match.deleted", value: value)
        let slots = matches.first { $0["id"] == id }?["slots"].array ?? []
        matches.removeAll { $0["id"] == id }
        for slot in slots {
            let key = slot["id"].string, lane = "transcript:" + key
            if let owner = contentOwners[key] { endContent(owner) }
            reads.invalidate(lane); pendingReads[lane]?.task.cancel()
            transcripts.removeValue(forKey: key); streamEvents.removeValue(forKey: key)
            requestedTranscripts.remove(key); transcriptRequests.removeValue(forKey: key); live.removeValue(forKey: key)
        }
    }
    private func apply(_ change: Change, to values: inout [JSONValue]) {
        switch change.topic {
        case "arena.match":
            if let i = values.firstIndex(where: { $0["id"] == change.value["id"] }) { values[i] = change.value } else { values.insert(change.value, at: 0) }
        case "arena.match.deleted": values.removeAll { $0["id"] == change.value["id"] }
        case "arena.slot":
            for index in values.indices {
                var slots = values[index]["slots"].array
                if let i = slots.firstIndex(where: { $0["id"] == change.value["id"] }) { slots[i] = change.value; values[index]["slots"] = .array(slots); break }
            }
        default: break
        }
    }
}
