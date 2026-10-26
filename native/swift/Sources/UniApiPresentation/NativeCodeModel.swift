import Foundation
import Combine
import UniApiCore

protocol NativeCodeModelService: Sendable {
    func handle(_ operation: String, input: JSONObject) async throws -> JSONValue
}
extension NativeCodeService: NativeCodeModelService {}

@MainActor package final class NativeCodeModel: ObservableObject {
    private let service: any NativeCodeModelService
    @Published package var projects: [JSONValue] = []
    @Published package var threads: [JSONValue] = []
    @Published package var routes: [JSONValue] = []
    @Published package var detail: JSONValue = .null
    @Published package var events: [JSONValue] = []
    @Published package var pending: [JSONValue] = []
    @Published package var error = ""
    @Published package var loaded = false
    @Published package private(set) var detailLoading = false
    @Published package var live = CodeLiveState()
    @Published package var gitRevision = 0
    private var listener: Task<Void, Never>?
    private var listenerLifetime = UUID()
    private var active = true
    private var generation = 0, streamRevision = 0, loadedThread = ""
    private var completedHistoryThread = ""
    private struct PermissionChange { let revision: Int; let value: JSONValue? }
    private var permissionRevision = 0
    private var permissionChanges: [String: PermissionChange] = [:]
    package convenience init(runtime: NativeRuntime) { self.init(service: NativeCodeService.shared(runtime: runtime)) }
    init(service: any NativeCodeModelService) { self.service = service }
    package func hasHistory(for thread: String) -> Bool { !thread.isEmpty && completedHistoryThread == thread }
    @discardableResult package func load(project: String, thread: String) async -> Bool {
        // A service read may finish after cancellation; an abandoned page must
        // stop before requesting the next batch of its history.
        guard active, !Task.isCancelled else { return false }
        if loadedThread != thread { loadedThread = thread; completedHistoryThread = ""; detail = .null; events = []; live = CodeLiveState(); pending = []; permissionChanges.removeAll(); streamRevision += 1 }
        generation += 1; let own = generation
        // A live metadata event can identify a thread before its history has
        // arrived. Only a completed, generation-owned history read is ready.
        detailLoading = !thread.isEmpty && completedHistoryThread != thread
        if detailLoading { error = "" }
        defer { if own == generation { detailLoading = false } }
        let revision = streamRevision
        let permissionsAtStart = permissionRevision
        do {
            let routes = try await service.handle("routes", input: [:])["routes"].array
            guard !Task.isCancelled, own == generation else { return false }
            let projects = try await service.handle("projects", input: [:]).array
            guard !Task.isCancelled, own == generation else { return false }
            let validProject = CodeProjectSelection.resolve(project, projects: projects)
            let threads: [JSONValue]
            if validProject.isEmpty { threads = [] } else { threads = try await service.handle("threads", input: ["project": .string(validProject)]).array }
            guard !Task.isCancelled, own == generation else { return false }
            self.projects = projects; self.threads = threads
            var detail: JSONValue = .null, events: [JSONValue] = []
            if !thread.isEmpty && threads.contains(where: { $0["id"].string == thread }) {
                detail = try await service.handle("thread", input: ["id": .string(thread)])
                guard !Task.isCancelled, own == generation else { return false }
                events = detail["events"].array
                var more = detail["more"].bool
                while more, let seq = events.last?["seq"] {
                    guard !Task.isCancelled, own == generation else { return false }
                    let next = try await service.handle("thread", input: ["id": .string(thread), "after": seq])
                    guard !Task.isCancelled, own == generation else { return false }
                    events += next["events"].array; more = next["more"].bool
                }
            }
            if own == generation && !Task.isCancelled {
                self.routes = routes; self.projects = projects; self.threads = threads; self.detail = detail
                var merged = Dictionary(events.map { ($0["seq"].int, $0) }, uniquingKeysWith: { _, new in new })
                for event in self.events { merged[event["seq"].int] = event }; self.events = merged.values.sorted { $0["seq"].int < $1["seq"].int }
                var permissions = detail["pending"].array
                // The first history page's permission snapshot can predate a
                // live addition/resolution while later pages are still held.
                for (id, change) in permissionChanges.sorted(by: { $0.value.revision < $1.value.revision }) where change.revision > permissionsAtStart {
                    if let value = change.value {
                        if let index = permissions.firstIndex(where: { $0["id"].string == id }) { permissions[index] = value }
                        else { permissions.append(value) }
                    } else { permissions.removeAll { $0["id"].string == id } }
                }
                self.pending = permissions; permissionChanges.removeAll(keepingCapacity: true)
                self.completedHistoryThread = detail["thread"]["id"].string == thread ? thread : ""
                if revision == streamRevision { self.live = CodeLiveState(json: detail["live"]) }
                self.loaded = true; self.error = ""; return true
            }
        } catch { if own == generation && !Task.isCancelled { self.error = error.localizedDescription } }
        return false
    }
    package func listen(runtime: NativeRuntime, project: @escaping @MainActor () -> String, thread: @escaping @MainActor () -> String) async {
        await listen(events: runtime.events, project: project, thread: thread)
    }
    func listen(events: NativeEvents, project: @escaping @MainActor () -> String, thread: @escaping @MainActor () -> String) async {
        listener?.cancel(); active = true
        let own = UUID(); listenerLifetime = own
        let events = await events.stream()
        guard own == listenerLifetime, !Task.isCancelled else { return }
        listener = Task { [weak self] in
            for await e in events {
                guard !Task.isCancelled, let self, own == self.listenerLifetime else { break }
                if e.topic == "code.stream", e.data["threadId"].string == thread() {
                    self.streamRevision += 1; self.live.apply(e.data["event"], parent: e.data["parent_tool_use_id"])
                } else if e.topic == "code.event", e.data["threadId"].string == thread() {
                    let event = e.data["event"]
                    if ["tool_result", "result"].contains(event["type"].string) { self.gitRevision &+= 1 }
                    if !self.events.contains(where: { $0["seq"] == event["seq"] }) { self.events.append(event); self.events.sort { $0["seq"].int < $1["seq"].int } }
                    if ["result", "error"].contains(event["type"].string) { self.streamRevision += 1; self.live = CodeLiveState() }
                } else if e.topic == "code.thread" {
                    if let i = self.threads.firstIndex(where: { $0["id"] == e.data["id"] }) { self.threads[i] = e.data }
                    else if e.data["project_id"].string == project() { self.threads.insert(e.data, at: 0) }
                    if e.data["id"].string == thread() { self.detail["thread"] = e.data }
                } else if e.topic == "code.permission", e.data["threadId"].string == thread() {
                    if !self.pending.contains(where: { $0["id"] == e.data["id"] }) {
                        self.pending.append(e.data); self.permissionRevision += 1
                        self.permissionChanges[e.data["id"].string] = PermissionChange(revision: self.permissionRevision, value: e.data)
                    }
                } else if e.topic == "code.permission.resolved", e.data["threadId"].string == thread() {
                    self.pending.removeAll { $0["id"] == e.data["id"] }; self.permissionRevision += 1
                    self.permissionChanges[e.data["id"].string] = PermissionChange(revision: self.permissionRevision, value: nil)
                }
                else if e.topic == "code.thread.deleted" { self.threads.removeAll { $0["id"] == e.data["id"] } }
                else if ["code.projects", "code.agents", "code.options", "switcher.changed"].contains(e.topic) { await self.load(project: project(), thread: thread()) }
            }
        }
    }
    package func stop() { active = false; detailLoading = false; listenerLifetime = UUID(); listener?.cancel(); listener = nil; generation += 1 }
    package func call(_ op: String, _ input: JSONObject = [:]) async -> JSONValue? { do { let value = try await service.handle(op, input: input); error = ""; return value } catch { self.error = error.localizedDescription; return nil } }
}

