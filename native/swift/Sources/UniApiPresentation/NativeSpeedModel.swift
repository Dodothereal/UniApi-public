import Combine
import AppKit
import UniApiCore

@MainActor package final class NativeSpeedModel: ObservableObject {
    let service: any NativeBenchmarkModelService
    @Published package var catalog: JSONValue = .null
    @Published package var selection: JSONValue = ["included": [], "models": [:], "tier": "standard"]
    @Published package var progress: JSONValue = .null
    @Published package var free: JSONValue = .null
    @Published package var error = ""
    @Published package var busy = false
    @Published package var discovering = Set<String>()
    private let lifecycle = BenchmarkPageLifecycle()
    private var pageOwner: UUID?
    private var preferenceEdits = BenchmarkPreferenceEdits()
    private var preferencesRestored = false
    package convenience init(runtime: NativeRuntime) { self.init(service: NativeBenchmarkService.shared(runtime: runtime)) }
    init(service: any NativeBenchmarkModelService) { self.service = service }
    package var running: Bool { ["queued", "running"].contains(progress["job"]["status"].string) }
    package var freeRunning: Bool { ["queued", "running"].contains(free["job"]["status"].string) }
    package var anyRunning: Bool { running || freeRunning }
    package var pairs: [JSONValue] { selection["included"].array.flatMap { id in selection["models"][id.string].array.map { ["provider": id, "model": $0] as JSONValue } } }
    package var issues: [String] {
        pairs.compactMap { pair in
            guard let provider = catalog["providers"].array.first(where: { $0["id"] == pair["provider"] }), provider["transport"] == "chatgpt-web" else { return nil }
            if !provider["ready"].bool { return provider["name"].string + ": " + provider["readinessReason"].string }
            guard let model = provider["catalog"].array.first(where: { $0["id"] == pair["model"] }), model["available"] != false else { return provider["name"].string + ": choose an available discovered browser mode" }
            return nil
        }
    }
    package func begin(runtime: NativeRuntime, owner: UUID? = nil) async { await begin(events: runtime.events, owner: owner) }
    func begin(events: NativeEvents, owner: UUID? = nil) async {
        pageOwner = owner ?? UUID()
        await lifecycle.begin(events: events, matches: { $0.topic.hasPrefix("bench.") || $0.topic.hasPrefix("job.") && $0.data["app"] == "bench" }, prepare: { [weak self] in
            guard let self else { return false }
            // Returning to this model refreshes payloads without replacing edits.
            // Only an accepted first restore survives a cancelled page lifetime.
            if self.preferencesRestored { return true }
            return await self.lifecycle.restore(read: { try await self.service.start(); try Task.checkCancellation(); return try await self.service.handle("selection", input: [:]) }, commit: { self.selection = self.preferenceEdits.restoring($0); self.preferencesRestored = true }, failed: { self.error = $0.localizedDescription })
        }, initial: { [weak self] in await self?.reload() }, changed: { [weak self] _ in await self?.reload() })
    }
    package func stopListening(owner: UUID? = nil) {
        guard owner == nil || owner == pageOwner else { return }
        pageOwner = nil; lifecycle.stop()
    }
    package func reload() async {
        guard await lifecycle.ready() else { return }
        await lifecycle.perform(read: {
            let catalog = try await self.service.handle("catalog", input: [:]); try Task.checkCancellation()
            let progress = try await self.service.handle("progress", input: [:]); try Task.checkCancellation()
            return (catalog, progress, try await self.service.handle("freeTestReport", input: [:]))
        }, commit: { catalog, progress, free in
            self.catalog = catalog; self.progress = progress; self.free = free; self.error = ""
        }, failed: { self.error = $0.localizedDescription })
    }
    package func persist() {
        Task { guard await lifecycle.ready() else { return }; let value = selection; do { _ = try await service.handle("saveSelection", input: value.object) } catch { self.error = error.localizedDescription } }
    }
    package func tier(_ value: String) { preferenceEdits.set("tier", .string(value)); selection["tier"] = .string(value); persist() }
    package func toggle(_ id: String) {
        var included = selection["included"].array
        if included.contains(.string(id)) { included.removeAll { $0 == .string(id) } } else { included.append(.string(id)) }
        preferenceEdits.include(id, included.contains(.string(id)))
        selection["included"] = .array(included); persist()
    }
    package func models(_ id: String, _ models: [String]) {
        var choices = selection["models"]; choices[id] = .array(Array(Set(models)).sorted().map(JSONValue.string)); selection["models"] = choices
        preferenceEdits.selectModels(id, choices[id])
        if !models.isEmpty && !selection["included"].array.contains(.string(id)) { var included = selection["included"].array; included.append(.string(id)); selection["included"] = .array(included) }
        if !models.isEmpty { preferenceEdits.include(id, true) }
        persist()
    }
    package func discover(_ id: String) async {
        discovering.insert(id); defer { discovering.remove(id) }
        do { let result = try await service.handle("discover", input: ["provider": .string(id)]); await reload(); if !result["error"].isNull { error = result["error"].string } }
        catch { self.error = error.localizedDescription }
    }
    package func run() async {
        busy = true; defer { busy = false }
        do { _ = try await service.handle("run", input: ["tier": selection["tier"], "pairs": .array(pairs), "notify": true]); await reload() }
        catch { self.error = error.localizedDescription }
    }
    package func cancel() async { do { _ = try await service.handle("stop", input: [:]); await reload() } catch { self.error = error.localizedDescription } }
    package func resume() async {
        busy = true; defer { busy = false }
        do { _ = try await service.handle("resume", input: ["run_id": progress["progress"]["run_id"]]); await reload() }
        catch { self.error = error.localizedDescription }
    }
    package func editable(_ provider: JSONValue) async -> JSONValue? {
        do { var value = provider; value["apiKey"] = try await service.handle("key", input: ["provider": provider["id"]])["key"]; return value }
        catch { self.error = error.localizedDescription; return nil }
    }
    package func update(_ provider: JSONValue, name: String, base: String, key: String) async -> Bool {
        do { _ = try await service.handle("updateProvider", input: ["provider": provider["id"], "name": .string(name), "baseUrl": .string(base), "apiKey": .string(key)]); await reload(); return true }
        catch { self.error = error.localizedDescription; return false }
    }
    package func sweep() async { do { _ = try await service.handle("freeTest", input: [:]); await reload() } catch { self.error = error.localizedDescription } }
    package func saveSchedule(enabled: Bool, time: String) async {
        do { _ = try await service.handle("saveSchedule", input: ["enabled": .bool(enabled), "time": .string(time)]); await reload() }
        catch { self.error = error.localizedDescription }
    }
    package func copyKey(_ id: String) async {
        do { let value = try await service.handle("key", input: ["provider": .string(id)]); NSPasteboard.general.clearContents(); NSPasteboard.general.setString(value["key"].string, forType: .string) }
        catch { self.error = error.localizedDescription }
    }
}
