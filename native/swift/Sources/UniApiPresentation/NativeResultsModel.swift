import Combine
import AppKit
import UniApiCore

@MainActor package final class NativeResultsModel: ObservableObject {
    let service: any NativeBenchmarkModelService
    @Published package var payload: JSONValue = .null
    @Published package var raw: [JSONValue] = []
    @Published package var curves: [JSONValue] = []
    @Published package var usage: JSONValue = .null
    @Published package var scope = "latest"
    @Published package var family = ""
    @Published package var tab = "table"
    @Published package var error = ""
    @Published package var busy = false
    private var request = 0, newest = ""
    private let lifecycle = BenchmarkPageLifecycle()
    private var preferenceEdits = BenchmarkPreferenceEdits()
    private var preferencesRestored = false
    private var observedJob = "", observedJobStart: Double = 0
    private var reconciledRunStarts = Set<String>()
    private var lastScopeChoice: Double = 0
    private var explicitRun: String?
    private let readOnly: Bool
    package convenience init(runtime: NativeRuntime, initialRun: String?) {
        self.init(service: NativeBenchmarkService.shared(runtime: runtime), readOnly: runtime.paths.readOnly, initialRun: initialRun)
    }
    init(service: any NativeBenchmarkModelService, readOnly: Bool, initialRun: String?) {
        self.service = service; explicitRun = initialRun; self.readOnly = readOnly
    }
    package func begin(runtime: NativeRuntime) async { await begin(events: runtime.events) }
    func begin(events: NativeEvents) async {
        let openingRun = explicitRun
        await lifecycle.begin(events: events, matches: { ["bench.started", "bench.row", "bench.finished"].contains($0.topic) }, prepare: { [weak self] in
            guard let self else { return false }
            let restorePreferences = !self.preferencesRestored
            return await self.lifecycle.restore(read: {
                let saved = restorePreferences ? try await self.service.handle("resultsState", input: [:]) : .null
                try Task.checkCancellation()
                return (saved, try await self.service.handle("progress", input: [:]))
            }, commit: { saved, progress in
                let job = progress["job"], id = job["id"].string
                let started = max(job["created_at"].double, job["started_at"].double)
                let newStart = id != self.observedJob || started != self.observedJobStart
                self.observedJob = id; self.observedJobStart = started
                if !job["params"]["run_id"].string.isEmpty { self.reconciledRunStarts.insert(job["params"]["run_id"].string) }
                if restorePreferences {
                    var base = saved; if let openingRun { base["scope"] = .string(openingRun) }
                    let restored = self.preferenceEdits.restoring(base)
                    self.scope = restored["scope"].string.isEmpty ? "latest" : restored["scope"].string; self.family = restored["family"].string; self.tab = restored["tab"].string.isEmpty ? "table" : restored["tab"].string
                    self.newest = self.preferenceEdits.contains("scope") ? "" : saved["newestRun"].string
                    self.preferencesRestored = true
                } else if newStart, !id.isEmpty, !job["params"]["run_id"].string.isEmpty,
                          started > self.lastScopeChoice, self.explicitRun == nil {
                    // Starts missed while stopped are visible before their first row.
                    // Reconcile that metadata without reapplying saved view choices.
                    self.lifecycle.invalidate(); self.request += 1
                    self.scope = "latest"; self.family = ""; self.newest = ""
                    self.payload = .null; self.raw = []; self.curves = []
                }
            }, failed: { self.error = $0.localizedDescription })
        }, initial: { [weak self] in await self?.load() }, changed: { [weak self] event in
            guard let self else { return }
            if event.topic == "bench.started", !event.data["run_id"].string.isEmpty { self.reconciledRunStarts.insert(event.data["run_id"].string) }
            if event.topic == "bench.started", event.timestamp > self.lastScopeChoice { self.lifecycle.invalidate(); self.request += 1; self.scope = "latest"; self.family = ""; self.explicitRun = nil; self.payload = .null; self.raw = []; self.curves = [] }
            await self.load()
        })
    }
    package func stop() { lifecycle.stop(); request += 1 }
    package func load() async {
        guard await lifecycle.ready() else { return }
        // Keep stable view identities during live updates so entrances play on
        // scope changes while real values transition in place as rows arrive.
        request += 1; let own = request, chosen = scope; busy = payload.isNull
        await lifecycle.perform(read: {
            let summary = try await self.service.handle("summary", input: ["scope": .string(chosen)])
            try Task.checkCancellation()
            let rows = try await self.service.handle("rows", input: ["scope": summary["scope"], "limit": 2000])
            try Task.checkCancellation()
            let arrival = try await self.service.handle("curves", input: ["scope": summary["scope"]])
            return (summary, rows, arrival)
        }, commit: { summary, rows, arrival in
            guard own == self.request else { return }
            let latest = summary["runs"].array.first?["id"].string ?? ""
            // A known start was already reconciled against the user's choice.
            // Its first result row is not another start that can override it.
            if self.explicitRun == nil, !self.newest.isEmpty, !latest.isEmpty, self.newest != latest, !self.reconciledRunStarts.contains(latest), chosen != "latest" {
                self.newest = latest; self.scope = "latest"; self.family = ""; self.payload = .null; self.raw = []; self.curves = []; Task { await self.load() }; return
            }
            self.payload = summary; self.raw = rows.array; self.curves = arrival.array
            self.family = BenchmarkPresentation.family(self.family, summary: summary)
            if !latest.isEmpty { self.newest = latest }; self.error = ""; self.busy = false; self.persist()
        }, failed: { self.error = $0.localizedDescription; self.busy = false })
    }
    package func choose(_ run: String) {
        lifecycle.invalidate(); request += 1
        preferenceEdits.set("scope", .string(run)); lastScopeChoice = Date().timeIntervalSince1970 * 1000
        scope = run; newest = ""; explicitRun = run == "latest" || run == "all" ? nil : run; payload = .null; raw = []; curves = []; persist(); Task { await load() }
    }
    package func chooseFamily(_ value: String) { preferenceEdits.set("family", .string(value)); family = value; persist() }
    package func chooseTab(_ value: String) { preferenceEdits.set("tab", .string(value)); tab = value; persist() }
    package func persist() {
        guard !readOnly else { return }
        Task {
            guard await lifecycle.ready() else { return }
            let saved: JSONObject = ["scope": .string(scope), "family": .string(family), "tab": .string(tab), "newestRun": .string(newest)]
            do { _ = try await service.handle("saveResultsState", input: saved) } catch { self.error = error.localizedDescription }
        }
    }
    package func loadUsage() async { do { usage = try await service.handle("usage", input: [:]) } catch { self.error = error.localizedDescription } }
    package func export(summary: Bool, allRuns: Bool = false) async {
        guard !busy, !payload.isNull else { return }
        let panelToken = NativePagePanels.shared.capture()
        do {
            let value = try await service.handle("export", input: ["scope": allRuns ? "all" : payload["scope"], "summary": .bool(summary), "label": .string(allRuns || scope == "all" ? "All-time best" : scope == "latest" ? "Latest run" : "Run " + scope)])
            let panel = NSSavePanel(); panel.nameFieldStringValue = value["filename"].string
            if panel.nativeRunModal(token: panelToken) == .OK, let url = panel.url { try Data(value["text"].string.utf8).write(to: url, options: .atomic) }
        } catch { self.error = error.localizedDescription }
    }
}
