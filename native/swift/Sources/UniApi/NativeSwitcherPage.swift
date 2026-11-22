import SwiftUI
import AppKit
import UniApiCore

@MainActor final class NativeSwitcherModel: ObservableObject {
    let service: NativeSwitcherService
    private let runtime: NativeRuntime
    @Published var claude: JSONValue = .null
    @Published var codex: JSONValue = .null
    @Published var error = ""
    @Published var message = ""
    @Published var claudeProbe: JSONValue = .null
    @Published var busy = false
    @Published var jobs: [JSONValue] = []
    @Published var catalogDraft = NativeSwitcherCatalogDraft()
    @Published var selection = NativeSwitcherSelectionDraft()
    @Published var readiness: NativePageReadiness = .pending
    private let lifecycle = BenchmarkPageLifecycle()
    private var readinessPoll: Task<Void, Never>?
    private var generation = UUID()
    var controlsBusy: Bool { busy || runtime.paths.readOnly || NativeSwitcherDisplayPolicies.checksRunning(jobs) }
    init(runtime: NativeRuntime) { self.runtime = runtime; service = .shared(runtime: runtime) }
    func begin(_ runtime: NativeRuntime) async {
        readiness = .pending
        await lifecycle.begin(events: runtime.events, matches: { $0.topic.hasPrefix("switcher.") || $0.topic.hasPrefix("job.") && $0.data["app"] == "switcher" }, initial: { [weak self] in
            guard let self else { return }
            guard await self.lifecycle.perform(read: { try await self.service.start() }, commit: { _ in }, failed: { self.error = $0.localizedDescription; self.readiness = .failed }) else { return }
            await self.reload()
        }, changed: { [weak self] _ in await self?.reload() })
        guard !Task.isCancelled else { return }
        readinessPoll?.cancel(); readinessPoll = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(nanoseconds: 15_000_000_000) } catch { return }
                await self?.reload()
            }
        }
    }
    func stop() { generation = UUID(); lifecycle.stop(); readinessPoll?.cancel(); readinessPoll = nil }
    func reload(force: Bool = false) async {
        guard !busy || force else { return }
        let ticket = UUID(); generation = ticket
        await lifecycle.perform(read: {
            let nextClaude = try await self.service.handle("status")
            try Task.checkCancellation()
            let nextCodex = try await self.service.handle("codexStatus")
            try Task.checkCancellation()
            let nextJobs = try await self.runtime.jobs.list(app: "switcher", limit: 100).map(JSONValue.object)
            return (nextClaude, nextCodex, nextJobs)
        }, commit: { nextClaude, nextCodex, nextJobs in
            guard ticket == self.generation else { return }
            self.claude = nextClaude; self.codex = nextCodex; self.jobs = nextJobs
            self.catalogDraft.accept(nextCodex["catalog"]); self.selection.accept(nextCodex); self.error = ""; self.readiness = .ready
        }, failed: { if ticket == self.generation { self.error = $0.localizedDescription; self.readiness = .failed } })
    }
    @discardableResult func act(_ operation: String, _ input: JSONObject = [:]) async -> Bool {
        let codexOperation = ["codexAction", "codexSelect", "catalog", "verifyCodexTools", "verifyProvider"].contains(operation) || operation == "provider" && input["operation"] == "addModel"
        guard !busy, !codexOperation || !controlsBusy else { return false }; generation = UUID(); busy = true; defer { busy = false }
        do {
            let result = try await service.handle(operation, input: input)
            if operation == "probe" { claudeProbe = result } else if !result["probe"].isNull { claudeProbe = result["probe"] }
            if !result["job"].isNull { jobs.append(result["job"]) }
            if !result["status"].isNull { codex = result["status"]; catalogDraft.accept(codex["catalog"]) }
            selection.acceptCompletedAction(operation, input: input, result: result)
            message = result["message"].string.isEmpty ? result["job"].isNull ? "Saved." : "Verification queued; follow it in Jobs." : result["message"].string
            error = ""; await reload(force: true); return true
        }
        catch {
            let message = error.localizedDescription
            if codexOperation { await reload(force: true) }
            self.error = message; return false
        }
    }
    func copy(_ id: JSONValue) async {
        do { let key = try await service.handle("key", input: ["id": id]); NSPasteboard.general.clearContents(); NSPasteboard.general.setString(key["key"].string, forType: .string) } catch { self.error = error.localizedDescription }
    }
}

struct NativeSwitcherPage: View {
    let runtime: NativeRuntime
    @StateObject private var state: NativeSwitcherModel
    @AppStorage("uniapi.switcher.engine") private var savedEngine = "claude"
    @State private var addProvider = false
    @State private var models: [String: String] = [:]
    @State private var codexQuery = ""
    @State private var workerQuery = ""
    @State private var customModelProviderID = ""
    @State private var customModelID = ""
    @State private var showCodexModels = false
    @State private var emptyCodexSource = "subscription"
    @State private var providerToolsID: String?
    @State private var bridgeOpen = false
    @Namespace private var routeMarker
    @Environment(\.nativeReducedMotion) private var reduceMotion
    private var tab: String { NativeSwitcherDisplayPolicies.engine(savedEngine) }
    init(runtime: NativeRuntime) { self.runtime = runtime; _state = StateObject(wrappedValue: NativeSwitcherModel(runtime: runtime)) }

    var body: some View {
        NativePage(title: "Switcher", eyebrow: "Session routing", readiness: state.readiness, actions: {
            IconPress(icon: "rotate-cw", help: "Reload") { Task { await state.reload() } }.disabled(state.busy)
            if tab == "codex" {
                Button("Open Codex", nativeIcon: "external-link") { run("codexAction", ["action": "open"]) }.disabled(state.controlsBusy)
            }
            Button("Add provider", nativeIcon: "plus") { addProvider = true }
                .buttonStyle(Press(.primary)).disabled(tab == "claude" ? state.busy : state.controlsBusy)
        }) {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .firstTextBaseline, spacing: 16) {
                    Stops(options: [("claude", "Claude Code"), ("codex", "Codex")], selection: tab) { savedEngine = $0 }
                    Spacer(minLength: 0)
                    // What the last action did, said once beside the control row so nothing below moves.
                    if !state.message.isEmpty, state.error.isEmpty {
                        Text(state.message).font(Theme.ui(11.5)).foregroundStyle(Theme.muted).lineLimit(1).truncationMode(.tail)
                    }
                }
                if !state.error.isEmpty { Notice(text: state.error, tone: .fail).accessibilityLabel("Error: " + state.error) }
            }
            if tab == "claude" { claude } else { codex }
        }
        .nativePageTask { await state.begin(runtime) }.nativePageActivity(suspended: { state.stop() })
        .sheet(isPresented: $addProvider) { NativeSwitcherProviderForm { values in await state.act("provider", values) } }
    }
    private func run(_ operation: String, _ values: JSONObject = [:]) { Task { _ = await state.act(operation, values) } }

    // ------------------------------------------------------------------
    // Claude Code
    // ------------------------------------------------------------------

    private var claudeSnapshot: JSONValue { state.claude["snapshot"] }
    private var claudeGateway: Bool { !claudeSnapshot["baseUrl"].string.isEmpty }
    @ViewBuilder private var claude: some View {
        VStack(alignment: .leading, spacing: 0) {
            NativeSwitcherStatement(eyebrow: "New Claude Code sessions route to",
                                    name: state.claude.isNull ? "Reading the route" : state.claude["currentName"].string,
                                    settled: !state.claude.isNull)
            NativeSwitcherFact(label: "Model") {
                if claudeSnapshot["model"].string.isEmpty {
                    Text(state.claude.isNull ? "" : claudeGateway ? "Not set" : "Claude Code picks its own").font(Theme.ui(12.5)).foregroundStyle(Theme.muted)
                } else {
                    Text(claudeSnapshot["model"].string).font(Theme.mono(12)).foregroundStyle(Theme.ink).lineLimit(1).truncationMode(.middle).textSelection(.enabled)
                }
            }
            NativeSwitcherFact(label: "Effort") {
                Stops(options: [("", "Default")] + state.claude["efforts"].array.map { ($0.string, $0.string.capitalized) },
                      selection: claudeSnapshot["effort"].string, enabled: !state.busy && !state.claude.isNull) {
                    run("effort", ["effort": $0.isEmpty ? .null : .string($0)])
                }
            }
            NativeSwitcherFact(label: "Base URL") {
                Text(state.claude.isNull ? "" : claudeGateway ? claudeSnapshot["baseUrl"].string : "api.anthropic.com")
                    .font(Theme.mono(12)).foregroundStyle(Theme.dim).lineLimit(1).truncationMode(.middle).textSelection(.enabled)
            }
            NativeSwitcherFact(label: "Shim") { shimLine }
        }
        Band(title: "Providers", spacing: 0) {
            Text("Click a row to route new sessions through it").font(Theme.ui(11.5)).foregroundStyle(Theme.muted).lineLimit(1)
        } content: {
            LedgerHead {
                MicroLabel("Provider").frame(maxWidth: .infinity, alignment: .leading)
                MicroLabel("Wire").frame(width: 84, alignment: .leading)
                MicroLabel("Model").frame(width: 200, alignment: .leading)
                Color.clear.frame(width: 68, height: 1)
            }
            VStack(alignment: .leading, spacing: 0) {
                NativeSwitcherRouteRow(active: !state.claude.isNull && !claudeGateway, marker: routeMarker, label: "Use Anthropic subscription",
                                       action: claudeGateway && !state.busy ? { run("restore") } : nil) {
                    routeIdentity(name: "Anthropic subscription", detail: "No gateway · Claude Code picks its own models", wire: "")
                } trailing: {
                    Color.clear.frame(width: 280, height: 1)
                } below: { EmptyView() }
                ForEach(state.claude["providers"].array, id: \.self["id"]) { provider in providerRow(provider) }
            }
            .animation(reduceMotion ? nil : NativeMotion.marker, value: state.claude["current"])
        }
    }
    private var shimLine: some View {
        let shim = state.claude["shim"], up = shim["ok"] == true, legacy = shim["legacyPresent"] == true
        return HStack(spacing: 10) {
            if state.claude.isNull { Text("Checking").font(Theme.ui(12.5)).foregroundStyle(Theme.muted) }
            else {
                Tag(up ? "Up" : legacy ? "Legacy listener kept" : "Down", tone: up ? Theme.okFg : legacy ? Theme.warnFg : Theme.failFg, dot: true)
                    .help(up ? "Swift listener is available." : legacy ? "The existing legacy listener was preserved." : "Swift listener is unavailable.")
                if up, shim["owned"] == true { Text("started here").font(Theme.ui(11.5)).foregroundStyle(Theme.muted) }
            }
            Spacer(minLength: 8)
            if shim["owned"] == true {
                Button("Stop shim") { run("stopShim") }.buttonStyle(Press(.quiet)).disabled(state.busy).accessibilityLabel("Stop owned shim")
            } else if !state.claude.isNull, !up {
                Button("Start shim", nativeIcon: "play") { run("startShim") }.disabled(state.busy).accessibilityLabel("Start native shim")
            }
        }
    }
    /// `wire` is the detected format, empty for the subscription, nil when undetected.
    private func routeIdentity(name: String, detail: String, wire: String?, caution: Bool = false) -> some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(name).font(Theme.ui(13, weight: .medium)).foregroundStyle(Theme.ink).lineLimit(1)
                Text(detail).font(Theme.ui(11.5)).foregroundStyle(caution ? Theme.warnFg : Theme.muted).lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Group {
                if let wire, !wire.isEmpty { Tag(wire) }
                else { Text(wire == nil ? "not detected" : "native").font(Theme.mono(10.5)).foregroundStyle(Theme.faint) }
            }
            .frame(width: 84, alignment: .leading)
        }
    }
    private func providerRow(_ provider: JSONValue) -> some View {
        let id = provider["id"].string, chosen = chosenModel(provider), wired = !provider["format"].isNull
        let direct = !provider["claudeUrl"].string.hasPrefix("http://127.0.0.1:")
        let stranded = wired && !direct && !state.claude.isNull && state.claude["shim"]["ok"] != true
        let detail = wired ? switcherCount(provider["models"].array.count, "model") + " · " + (direct ? "direct" : stranded ? "needs the shim" : "via shim") : "Benchmark only"
        return NativeSwitcherRouteRow(active: state.claude["current"] == provider["id"], marker: routeMarker, label: "Use " + provider["name"].string,
                                      action: wired && !state.busy ? { run("applyAndProbe", ["id": provider["id"], "model": .string(chosen)]) } : nil) {
            routeIdentity(name: provider["name"].string, detail: detail, wire: wired ? provider["format"].string : nil, caution: stranded)
        } trailing: {
            Group {
                if wired {
                    NativeSwitcherRouteModelControl(models: provider["models"].array.map(\.string), chosen: Binding(get: { chosenModel(provider) }, set: { models[id] = $0 }))
                        .help(chosen).disabled(state.busy)
                } else {
                    Button("Enable") { run("provider", ["operation": "adopt", "id": provider["id"]]) }.disabled(state.busy)
                        .help("Detect the wire format so Claude Code can use this provider")
                }
            }
            .frame(width: 200, alignment: .leading)
            IconPress(icon: "rotate-cw", help: "Refresh models", size: 13) { run("provider", ["operation": "refresh", "id": provider["id"]]) }
                .accessibilityLabel("Refresh models for " + provider["name"].string).disabled(state.busy)
            IconPress(icon: "ellipsis", help: "Provider tools", active: providerToolsID == id) { providerToolsID = id }
                .accessibilityLabel("Tools for " + provider["name"].string)
                .popover(isPresented: Binding(get: { providerToolsID == id }, set: { if !$0 { providerToolsID = nil } })) { providerTools(provider, chosen: chosen) }
        } below: {
            if state.claudeProbe["provider"] == provider["id"] {
                let verdict = state.claudeProbe, working = verdict["ok"] == true && verdict["empty"] != true
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 8) {
                        Tag(working ? "Answered" : "Route check failed", tone: working ? Theme.okFg : Theme.failFg, dot: true)
                        Text(verdict["model"].string + " · " + String(format: "%.1f s", verdict["ms"].double / 1000))
                            .font(Theme.mono(11)).foregroundStyle(Theme.muted).lineLimit(1)
                    }
                    if !verdict["message"].string.isEmpty {
                        Text(verdict["message"].string).font(Theme.ui(11.5)).foregroundStyle(working ? Theme.muted : Theme.failFg)
                            .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(.bottom, 12)
                .help("A text probe checks replies only. Responses and coding tools have separate verification.")
            }
        }
    }
    private func providerTools(_ provider: JSONValue, chosen: String) -> some View {
        let wired = !provider["format"].isNull
        return VStack(alignment: .leading, spacing: 0) {
            Text(provider["name"].string).font(Theme.display(17)).foregroundStyle(Theme.ink).lineLimit(1)
            Text(provider["baseUrl"].string).font(Theme.mono(11)).foregroundStyle(Theme.muted).textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true).padding(.top, 5).padding(.bottom, 12)
            Rule(strong: true)
            if wired {
                NativeSwitcherToolRow(icon: "save", title: "Save model without switching", detail: chosen) {
                    providerToolsID = nil; run("modelAndProbe", ["id": provider["id"], "model": .string(chosen)])
                }.disabled(chosen.isEmpty || state.busy).accessibilityLabel("Save model")
                NativeSwitcherToolRow(icon: "activity", title: "Send a text probe") {
                    providerToolsID = nil; run("probe", ["id": provider["id"], "model": .string(chosen)])
                }.disabled(state.busy).accessibilityLabel("Text probe")
                    .help("A text probe checks replies only. Responses and coding tools have separate verification.")
            }
            NativeSwitcherToolRow(icon: "key-round", title: "Copy API key") {
                providerToolsID = nil; Task { await state.copy(provider["id"]) }
            }.disabled(provider["hasKey"] != true).accessibilityLabel("Copy key for " + provider["name"].string)
            NativeSwitcherToolRow(icon: "trash-2", title: "Remove provider", danger: true, ruled: false) {
                providerToolsID = nil; run("provider", ["operation": "remove", "id": provider["id"]])
            }.disabled(state.busy).accessibilityLabel("Remove " + provider["name"].string)
        }
        .padding(.horizontal, 20).padding(.top, 18).padding(.bottom, 10).frame(width: 340)
        .background(Theme.popover).foregroundStyle(Theme.ink)
    }

    // ------------------------------------------------------------------
    // Codex
    // ------------------------------------------------------------------

    @ViewBuilder private var codex: some View {
        let current = state.codex["current"]
        VStack(alignment: .leading, spacing: 0) {
            NativeSwitcherStatement(eyebrow: "New Codex sessions default to",
                                    name: state.codex.isNull ? "Reading the config" : current["model"].string.isEmpty ? "Codex's own default" : current["model"].string,
                                    settled: !state.codex.isNull, selectable: !current["model"].string.isEmpty)
            NativeSwitcherFact(label: "Source") {
                Text(sourceName(current["source"].string)).font(Theme.ui(12.5)).foregroundStyle(Theme.ink)
            }
            NativeSwitcherFact(label: "Effort") {
                Text(state.codex.isNull ? "" : current["effort"].string.isEmpty ? "Default" : current["effort"].string.capitalized).font(Theme.ui(12.5)).foregroundStyle(Theme.ink)
            }
            NativeSwitcherFact(label: "Codex") {
                if !state.codex.isNull {
                    Tag(state.codex["installed"] == true ? "Installed" : "Not found", tone: state.codex["installed"] == true ? Theme.okFg : nil, dot: true)
                        .help("Tasks that are already open can keep their previous model. Reload Codex after a change when it asks.")
                }
            }
            NativeSwitcherFact(label: "Routing") {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 8) { routingStatus; Spacer(minLength: 8); routingActions }
                    VStack(alignment: .leading, spacing: 8) { routingStatus; routingActions }.padding(.vertical, 8)
                }
            }
        }
        if !state.codex["warnings"].array.isEmpty || nativeEditingIssue != nil {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(Array(state.codex["warnings"].array.enumerated()), id: \.offset) { _, warning in Notice(text: warning.string, tone: .warn) }
                if let issue = nativeEditingIssue, !state.codex.isNull, !state.codex["warnings"].array.contains(.string(issue)) { Notice(text: issue, tone: .warn) }
            }
        }
        defaultSection
        catalogSection
        bridgeSection
    }
    private func sourceName(_ source: String) -> String {
        switch source {
        case "subscription": return "ChatGPT subscription"
        case "web": return "ChatGPT Web"
        case "provider": return "API provider"
        default: return source
        }
    }
    private var routingStatus: some View {
        HStack(spacing: 6) {
            statusTag(state.codex["native"]["connected"], yes: "Connected", no: "Not connected")
            statusTag(state.codex["native"]["running"], yes: "Service ready", no: "Service down")
        }
        .help("UniApi's background service routes API providers and ChatGPT subscription models. Connecting hands off an idle Web route and keeps the selected default, providers and workers.")
    }
    private var routingActions: some View {
        HStack(spacing: 8) {
            Button("Restore direct Codex") { run("codexAction", ["action": "restore"]) }.buttonStyle(Press(.quiet))
                .disabled(state.controlsBusy || state.codex["restoreAvailable"] != true)
            Button("Connect", nativeIcon: "plug") { run("codexAction", ["action": "nativeConnect"]) }
                .disabled(state.controlsBusy || state.codex["native"]["canConnect"] != true)
                .accessibilityLabel("Connect native API routing")
        }
    }
    private func statusTag(_ value: JSONValue, yes: String = "Available", no: String = "Not verified") -> some View {
        Tag(value.isNull ? "Unknown" : value.bool ? yes : no, tone: value == true ? Theme.okFg : nil, dot: true)
    }
    private var nativeEditingIssue: String? {
        if !state.codex["native"]["error"].isNull { return state.codex["native"]["error"].string }
        if state.codex["native"]["running"] != true { return "The UniApi native routing service is unavailable." }
        if state.codex["native"]["accepting"] != true { return "Native routing admission is held. Finish the current connection change before editing." }
        if state.codex["native"]["activeRequests"].int > 0 { return "Native routing is handling a request. Wait before changing its configuration." }
        return nil
    }
    private var codexEditingStatus: JSONValue {
        var value = state.codex
        // Legacy display policy knows a single busy owner. Adapt its read-only
        // view without disguising the optional Web runtime's actual status.
        if value["native"]["connected"] == true { value["bridge"]["busy"] = .bool(nativeEditingIssue != nil) }
        return value
    }
    private var codexCatalogIssue: String? {
        if state.codex["native"]["connected"] == true, let issue = nativeEditingIssue { return issue }
        return NativeSwitcherDisplayPolicies.catalogIssue(codexEditingStatus)
    }
    private func codexSelectionIssue(_ row: JSONValue) -> String? {
        if state.codex["native"]["connected"] == true {
            if let issue = nativeEditingIssue { return issue }
            if row["source"] == "provider", !state.codex["catalog"]["providerIds"].array.contains(row["providerId"]) { return "Add this provider to Models in Codex and save the catalog before setting its default." }
        }
        return NativeSwitcherDisplayPolicies.selectionIssue(codexEditingStatus, model: row)
    }

    // The default: source, model, effort, then one explicit save.
    private var defaultSection: some View {
        Band("Change the default", spacing: 0) {
            OptionRow(title: "Source") {
                Stops(options: [("subscription", "ChatGPT subscription"), ("web", "ChatGPT Web"), ("provider", "API providers")],
                      selection: codexSource, enabled: !state.controlsBusy) { chooseSource($0) }
            }
            OptionRow(title: codexSource == "web" ? "Web model and mode" : "Model", detail: selectedRow.map(modelLabel) ?? "") {
                Button { showCodexModels = true } label: {
                    NativeSwitcherTrigger(text: selectedRow.map { $0["name"].string.isEmpty ? $0["id"].string : $0["name"].string } ?? "Choose model")
                        .frame(maxWidth: 260)
                }
                .buttonStyle(.plain).disabled(state.controlsBusy)
                .popover(isPresented: $showCodexModels) { codexModels }
            }
            if let row = selectedRow {
                if !row["efforts"].array.isEmpty {
                    OptionRow(title: "Reasoning effort", detail: codexSource == "web" ? "Web mode names come from ChatGPT and are separate from native Codex effort." : "") {
                        Pick(title: "Reasoning effort", selection: Binding(get: { selectionEffort }, set: { state.selection.effort = $0 }),
                             options: [(value: "", label: "Default")] + row["efforts"].array.map { (value: $0.string, label: $0.string) }, width: 150)
                            .disabled(state.controlsBusy)
                    }
                }
                HStack(alignment: .center, spacing: 12) {
                    if let issue = codexSelectionIssue(row) {
                        Text(issue).font(Theme.ui(11.5)).foregroundStyle(Theme.warnFg).fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 0)
                    Button("Set as Codex default", nativeIcon: "check") {
                        run("codexSelect", ["source": row["source"], "providerId": row["providerId"], "model": row["id"], "effort": selectionEffort.isEmpty ? .null : .string(selectionEffort)])
                    }
                    .disabled(state.controlsBusy || codexSelectionIssue(row) != nil || NativeSwitcherModelKey(row).matches(state.codex["current"]) && selectionEffort == state.codex["current"]["effort"].string)
                }
                .padding(.top, 14)
            }
        }
    }
    private var codexSource: String { selectedRow?["source"].string ?? emptyCodexSource }
    private func chooseSource(_ source: String) {
        emptyCodexSource = source
        state.selection.choose(availableModels.first { $0.row["source"] == .string(source) && $0.key.matches(state.codex["current"]) }?.row ?? availableModels.first { $0.row["source"] == .string(source) && $0.row["available"] == true }?.row ?? availableModels.first { $0.row["source"] == .string(source) }?.row)
    }
    private var codexModels: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Choose model").font(Theme.display(17)).foregroundStyle(Theme.ink)
            Entry(placeholder: "Search model or provider", text: $codexQuery, icon: "search", autoFocus: true)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    let sourceModels = availableModels.filter { $0.row["source"] == .string(codexSource) }
                    let matching = sourceModels.filter { matches($0.row, codexQuery) }
                    if sourceModels.isEmpty {
                        Blank(icon: "archive", title: codexSource == "web" ? "No ChatGPT Web models detected" : "No models listed",
                              detail: codexSource == "web" ? "Open setup, complete browser sign-in, then reload this page." : "Reload after configuring a compatible source.")
                    } else if matching.isEmpty {
                        Blank(icon: "search", title: "No matching models", detail: "Try a different model or provider name.")
                    }
                    ForEach(matching, id: \.key) { item in
                        let available = item.row["available"] == true
                        NativeSwitcherChoiceRow(selected: state.selection.key == item.key, enabled: !state.controlsBusy && available) {
                            state.selection.choose(item.row); showCodexModels = false
                        } content: {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(item.label).font(Theme.ui(12.5)).foregroundStyle(available ? Theme.ink : Theme.muted)
                                Text(item.row["id"].string).font(Theme.mono(10.5)).foregroundStyle(Theme.muted)
                                if !available {
                                    Text(item.row["reason"].string.isEmpty ? "Unavailable" : item.row["reason"].string)
                                        .font(Theme.ui(11.5)).foregroundStyle(Theme.warnFg).fixedSize(horizontal: false, vertical: true)
                                }
                            }
                            .padding(.vertical, 7)
                        }
                    }
                }
                .padding(.horizontal, 8)
            }
            .frame(height: 300).padding(.horizontal, -8)
        }
        .padding(20).frame(width: 460).background(Theme.popover).foregroundStyle(Theme.ink)
    }

    // The catalog: which providers and which worker models Codex lists.
    private var catalogSection: some View {
        Band(title: "Models in Codex", spacing: 20) {
            HStack(spacing: 10) {
                Text(state.catalogDraft.dirty ? "Unsaved changes" : "Saved").font(Theme.ui(11.5))
                    .foregroundStyle(state.catalogDraft.dirty ? Theme.warnFg : Theme.muted)
                    .accessibilityLabel(state.catalogDraft.dirty ? "Unsaved catalog changes" : "Catalog matches saved settings")
                Button("Save catalog and workers", nativeIcon: "save") { run("catalog", state.catalogDraft.body) }
                    .disabled(state.controlsBusy || !state.catalogDraft.dirty || state.catalogDraft.workers.count > 4 || codexCatalogIssue != nil)
            }
        } content: {
            if let issue = codexCatalogIssue { Notice(text: issue, tone: .warn) }
            catalogProviders
            catalogWorkersList
        }
    }
    private var catalogProviders: some View {
        let providers = state.catalogDraft.visibleProviders(state.codex["catalog"]["providers"].array)
        return VStack(alignment: .leading, spacing: 0) {
            LedgerHead {
                MicroLabel("API providers").frame(maxWidth: .infinity, alignment: .leading)
                MicroLabel(switcherCount(state.catalogDraft.providerIDs.count, "listed", plural: "listed"))
            }
            if providers.isEmpty {
                Blank(icon: "plug", title: "No API providers yet", detail: "Add a provider to set up its API models for Codex.",
                      actionTitle: "Add provider", primary: false) { addProvider = true }
            }
            ForEach(providers, id: \.self["id"]) { provider in
                let listed = state.catalogDraft.providerIDs.contains(provider["id"].string)
                HStack(alignment: .center, spacing: 12) {
                    NativeSwitcherChoiceRow(selected: false, checked: listed, enabled: !state.controlsBusy && (listed || provider["available"] == true), ruled: false) {
                        state.catalogDraft.toggleProvider(provider, models: state.codex["models"].array)
                    } content: {
                        VStack(alignment: .leading, spacing: 3) {
                            HStack(spacing: 8) {
                                Text(provider["name"].string).font(Theme.ui(12.5, weight: .medium)).foregroundStyle(Theme.ink).lineLimit(1)
                                Text(provider["id"].string).font(Theme.mono(10.5)).foregroundStyle(Theme.muted).lineLimit(1)
                            }
                            if !provider["reason"].isNull {
                                Text(provider["reason"].string).font(Theme.ui(11.5)).foregroundStyle(Theme.warnFg).fixedSize(horizontal: false, vertical: true)
                            }
                        }
                        .padding(.vertical, 8)
                    }
                    .accessibilityLabel(provider["name"].string)
                    Button("Check route") { run("verifyProvider", ["id": provider["id"]]) }.buttonStyle(Press(.quiet))
                        .disabled(state.controlsBusy || !state.codex["catalog"]["providers"].array.contains { $0["id"] == provider["id"] })
                }
                .overlay(alignment: .bottom) { Rule() }
            }
        }
    }
    private var catalogWorkersList: some View {
        VStack(alignment: .leading, spacing: 0) {
            LedgerHead {
                MicroLabel("Preferred workers")
                NativeSwitcherSlots(used: state.catalogDraft.workers.count, of: 4)
                Spacer(minLength: 0)
                MicroLabel("\(state.catalogDraft.workers.count) of 4")
                    .accessibilityLabel("\(state.catalogDraft.workers.count) of 4 preferred workers selected")
            }
            .help("One native row is reserved. Select at most four preferred workers; chats that are already open keep their roster until reloaded.")
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .top, spacing: 16) {
                    Entry(placeholder: "Search preferred workers", text: $workerQuery, icon: "search").frame(maxWidth: 300)
                    Spacer(minLength: 0)
                    customModelControls.frame(maxWidth: 420, alignment: .trailing)
                }
                VStack(alignment: .leading, spacing: 10) {
                    Entry(placeholder: "Search preferred workers", text: $workerQuery, icon: "search")
                    customModelControls
                }
            }
            .padding(.vertical, 12)
            Rule()
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(catalogWorkers, id: \.key) { item in
                        let row = item.row
                        let worker = NativeSwitcherCatalogDraft.workerID(row), checked = state.catalogDraft.workers.contains(worker)
                        NativeSwitcherChoiceRow(selected: false, checked: checked,
                                                enabled: !(state.controlsBusy || !checked && (row["workerReserved"] == true || row["available"] != true || state.catalogDraft.workers.count >= 4))) {
                            state.catalogDraft.toggleWorker(row)
                        } content: {
                            VStack(alignment: .leading, spacing: 3) {
                                HStack(spacing: 8) {
                                    Text(modelLabel(row)).font(Theme.ui(12.5, weight: .medium)).foregroundStyle(Theme.ink).lineLimit(1)
                                    if row["workerReserved"] == true { Tag("Reserved") }
                                    Spacer(minLength: 8)
                                    Text(row["id"].string).font(Theme.mono(10.5)).foregroundStyle(Theme.muted).lineLimit(1).truncationMode(.middle)
                                }
                                if row["available"] != true || row["workerReserved"] == true {
                                    Text(row["workerReserved"] == true ? "Included in the reserved native slot." : row["reason"].string)
                                        .font(Theme.ui(11.5)).foregroundStyle(Theme.muted).fixedSize(horizontal: false, vertical: true)
                                }
                            }
                            .padding(.vertical, 7)
                        }
                        .accessibilityLabel(modelLabel(row) + (row["workerReserved"] == true ? " · Reserved" : ""))
                    }
                    if catalogWorkers.isEmpty {
                        Text(workerQuery.isEmpty ? "No models to choose from yet." : "No models match this search.")
                            .font(Theme.ui(12.5)).foregroundStyle(Theme.muted).padding(.vertical, 16)
                    }
                }
                .padding(.horizontal, 8)
            }
            .frame(maxHeight: 288).padding(.horizontal, -8)
            if state.catalogDraft.workers.count >= 4 {
                Text("All four preferred worker slots are full. You can still add a model; remove a worker to select it.")
                    .font(Theme.ui(11.5)).foregroundStyle(Theme.muted).padding(.top, 10)
            }
        }
    }
    private var customModelProviders: [JSONValue] {
        state.codex["catalog"]["providers"].array.filter { $0["available"] == true && state.catalogDraft.providerIDs.contains($0["id"].string) }
    }
    private var customModelProvider: JSONValue? { customModelProviders.first { $0["id"].string == customModelProviderID } ?? customModelProviders.first }
    private var customModelControls: some View {
        HStack(spacing: 8) {
            Pick(title: "Custom model provider",
                 selection: Binding(get: { customModelProvider?["id"].string ?? "" }, set: { customModelProviderID = $0 }),
                 options: customModelProviders.map { (value: $0["id"].string, label: $0["name"].string.isEmpty ? $0["id"].string : $0["name"].string) })
                .disabled(state.controlsBusy || customModelProvider == nil)
                .help(customModelProvider?["id"].string ?? "Select an available API provider above.")
            Entry(placeholder: "Exact custom model ID", text: $customModelID, mono: true, onSubmit: { addCustomModel() })
                .accessibilityLabel("Exact custom model ID").disabled(state.controlsBusy || customModelProvider == nil)
            Button("Add model", nativeIcon: "plus") { addCustomModel() }
                .disabled(state.controlsBusy || customModelProvider == nil || customModelID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
        .help(customModelProviders.isEmpty ? "Select an available API provider above to add a custom model." : "Add a model the provider's list omits, by its exact ID. Save catalog and workers to apply your choices.")
    }
    private func addCustomModel() {
        let model = customModelID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !state.controlsBusy, !model.isEmpty, let provider = customModelProvider else { return }
        let providerID = provider["id"].string
        Task {
            guard await state.act("provider", ["operation": "addModel", "id": .string(providerID), "model": .string(model)]) else { return }
            workerQuery = model
            customModelID = ""
            guard let row = state.codex["models"].array.first(where: { $0["source"] == "provider" && $0["providerId"].string == providerID && $0["id"].string == model }) else {
                state.message = "Model saved, but its refreshed row is unavailable. Reload before selecting it and saving the catalog and workers."
                return
            }
            let worker = NativeSwitcherCatalogDraft.workerID(row)
            if state.catalogDraft.workers.contains(worker) {
                state.message = "Model saved. It is already selected as a preferred worker. Save catalog and workers to apply any pending changes."
            } else if state.catalogDraft.workers.count >= 4 {
                state.message = "Model added. All four preferred worker slots are full; remove one to select this model, then save catalog and workers."
            } else {
                state.catalogDraft.toggleWorker(row)
                state.message = state.catalogDraft.workers.contains(worker) ? "Model added and selected as a preferred worker. Save catalog and workers to apply." : "Model added. Select its provider and model when available, then save catalog and workers."
            }
        }
    }

    // The optional browser bridge: rarely touched, so it stays folded.
    private var bridgeChecks: [(label: String, value: JSONValue)] {
        let bridge = state.codex["bridge"]
        return [("Installed", bridge["installed"]), ("Configured", bridge["configured"]), ("Runtime", bridge["running"]),
                ("Sign-in checked", bridge["signInChecked"]), ("Full coding tools", bridge["toolsVerified"])]
    }
    private var bridgeSection: some View {
        let ready = bridgeChecks.filter { $0.value == true }.count
        return Band(title: "ChatGPT Web bridge", spacing: 16) {
            HStack(spacing: 8) {
                Tag("Optional · \(ready) of \(bridgeChecks.count) ready", tone: ready == bridgeChecks.count ? Theme.okFg : nil)
                Button { withAnimation(reduceMotion ? nil : NativeMotion.toggle) { bridgeOpen.toggle() } } label: {
                    HStack(spacing: 5) {
                        Text(bridgeOpen ? "Hide" : "Show")
                        NativeIcon("chevron-right", size: 11, strokeWidth: 1.75).rotationEffect(.degrees(bridgeOpen ? 90 : 0))
                    }
                }
                .buttonStyle(Press(.quiet)).accessibilityLabel("ChatGPT Web bridge").accessibilityValue(bridgeOpen ? "Expanded" : "Collapsed")
            }
        } content: {
            if bridgeOpen {
                ColumnFlow(minimum: 130, spacing: 24, rowSpacing: 16, maxColumns: 5) {
                    ForEach(bridgeChecks, id: \.label) { check in
                        VStack(alignment: .leading, spacing: 7) {
                            MicroLabel(check.label)
                            statusTag(check.value)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .accessibilityElement(children: .combine)
                    }
                }
                if state.codex["bridge"]["healthDeferred"] == true {
                    Text("Web runtime checks are deferred while native routing is connected. Use Check connection for an explicit check.")
                        .font(Theme.ui(11.5)).foregroundStyle(Theme.muted).fixedSize(horizontal: false, vertical: true)
                }
                if NativeSwitcherDisplayPolicies.checksRunning(state.jobs) {
                    Notice(text: "A Codex verification is queued or running. Follow it in Jobs before starting another check.")
                }
                NativeSwitcherWrap(spacing: 8) {
                    ForEach(["setup", "doctor", "start", "stop", "connect"], id: \.self) { action in
                        Button(bridgeActionTitle(action), nativeIcon: bridgeActionIcon(action)) { run("codexAction", ["action": .string(action)]) }
                            .disabled(state.controlsBusy || action == "stop" && state.codex["bridge"]["canStop"] != true || action == "connect" && (state.codex["native"]["connected"] == true || !state.codex["native"]["error"].isNull || !state.codex["native"]["phase"].isNull))
                    }
                    Button("Verify coding tools", nativeIcon: "shield-check") { run("verifyCodexTools") }
                        .disabled(state.controlsBusy || state.codex["installed"] != true || !state.codex["configError"].isNull || state.codex["bridge"]["mode"] != "full" || state.codex["bridge"]["busy"] != false || state.codex["bridge"]["signInChecked"] != true)
                        .help("Browser text access is separate from full local coding tools. Verification runs one explicit ephemeral tool check and stores evidence for the current bridge configuration.")
                }
            }
        }
    }
    private func bridgeActionTitle(_ action: String) -> String {
        switch action {
        case "setup": return "Open Web GPT"
        case "doctor": return "Check connection"
        case "start": return "Start bridge"
        case "stop": return "Stop bridge"
        default: return "Connect"
        }
    }
    private func bridgeActionIcon(_ action: String) -> String {
        switch action {
        case "setup": return "globe"
        case "doctor": return "search-check"
        case "start": return "play"
        case "stop": return "square"
        default: return "plug"
        }
    }

    private func chosenModel(_ provider: JSONValue) -> String { models[provider["id"].string] ?? (state.claude["current"] == provider["id"] && !state.claude["snapshot"]["model"].string.isEmpty ? state.claude["snapshot"]["model"].string : provider["model"].string) }
    private func modelLabel(_ row: JSONValue) -> String { (row["name"].string.isEmpty ? row["id"].string : row["name"].string) + " · " + (row["source"] == "provider" ? row["providerId"].string : row["source"].string) + (row["custom"] == true ? " · User-added" : "") }
    private var availableModels: [(key: NativeSwitcherModelKey, label: String, row: JSONValue)] { state.codex["models"].array.map { (NativeSwitcherModelKey($0), modelLabel($0), $0) } }
    private func matches(_ row: JSONValue, _ query: String) -> Bool { query.lowercased().split(whereSeparator: \.isWhitespace).allSatisfy { (modelLabel(row) + " " + row["id"].string).lowercased().contains($0) } }
    private var catalogWorkers: [(key: String, row: JSONValue)] { state.catalogDraft.visibleWorkers(state.codex["models"].array).filter { matches($0, workerQuery) }.map { (NativeSwitcherCatalogDraft.workerID($0), $0) } }
    private var selectedRow: JSONValue? { availableModels.first { $0.key == state.selection.key }?.row }
    private var selectionEffort: String { NativeSwitcherSelectionDraft.supportedEffort(selectedRow, state.selection.effort) }
}

private func switcherCount(_ count: Int, _ noun: String, plural: String? = nil) -> String {
    "\(count) " + (count == 1 ? noun : plural ?? noun + "s")
}

/// The page's reading: where new sessions go, set large. It hangs from a rule
/// whose tick carries the signal color because this is the live route.
private struct NativeSwitcherStatement: View {
    let eyebrow: String
    let name: String
    var settled = true
    var selectable = false
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ZStack(alignment: .topLeading) {
                Rule()
                (settled ? Theme.signal : Theme.faint).frame(width: 2, height: 7)
            }
            .frame(height: 7, alignment: .top).padding(.bottom, 12)
            MicroLabel(eyebrow)
            NativeNumberText(text: name, font: Theme.display(34), color: settled ? Theme.ink : Theme.muted)
                .minimumScaleFactor(0.55).padding(.top, 8).padding(.bottom, 18)
                .help(selectable ? name : "")
            Rule(strong: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .ignore).accessibilityLabel(eyebrow).accessibilityValue(name)
        .accessibilityAddTraits(.isHeader)
    }
}

/// One line of the compact ledger under the statement: an engraved key, then
/// its value or control.
private struct NativeSwitcherFact<Value: View>: View {
    let label: String
    @ViewBuilder var value: () -> Value
    var body: some View {
        HStack(alignment: .center, spacing: 16) {
            MicroLabel(label).frame(width: 84, alignment: .leading)
            value().frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxWidth: .infinity, minHeight: 40, alignment: .leading)
        .overlay(alignment: .bottom) { Rule() }
    }
}

/// A provider line. The identity is the switch: one click routes new sessions
/// here. The row's own controls sit beside it rather than inside the button,
/// and the signal tick travels to whichever row is live.
private struct NativeSwitcherRouteRow<Main: View, Trailing: View, Below: View>: View {
    var active: Bool
    var marker: Namespace.ID
    var label: String
    var action: (() -> Void)?
    @ViewBuilder var main: () -> Main
    @ViewBuilder var trailing: () -> Trailing
    @ViewBuilder var below: () -> Below
    @State private var hovering = false
    @Environment(\.nativeReducedMotion) private var reduceMotion

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 12) {
                Button { action?() } label: {
                    main().frame(maxWidth: .infinity, minHeight: 50, alignment: .leading).contentShape(Rectangle())
                }
                .buttonStyle(NativeModelChoiceButtonStyle()).disabled(action == nil).pointingHand(action != nil)
                .accessibilityLabel(label).accessibilityValue(active ? "Active" : "")
                .accessibilityAddTraits(active ? .isSelected : [])
                .onHover { hovering = $0 }
                trailing()
            }
            below()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            RoundedRectangle(cornerRadius: Theme.radiusControl, style: .continuous)
                .fill(active ? Theme.pressed : hovering && action != nil ? Theme.hover : .clear)
                .padding(.horizontal, -8)
        }
        .overlay(alignment: .topLeading) {
            if active {
                Theme.signal.frame(width: 2, height: 14).matchedGeometryEffect(id: "route", in: marker).offset(x: -8, y: 18)
            }
        }
        .overlay(alignment: .bottom) { Rule() }
        .animation(reduceMotion ? nil : NativeMotion.hover, value: hovering)
    }
}

/// A choice in a list: selected rows carry the signal tick, checked rows a
/// filled box. A disabled choice keeps its explanation readable.
struct NativeSwitcherChoiceRow<Content: View>: View {
    var selected: Bool
    var checked: Bool? = nil
    var enabled = true
    var ruled = true
    var action: () -> Void
    @ViewBuilder var content: () -> Content
    @State private var hovering = false
    @Environment(\.nativeReducedMotion) private var reduceMotion

    var body: some View {
        Button(action: action) {
            HStack(alignment: .center, spacing: 10) {
                if let checked {
                    NativeIcon(checked ? "square-check" : "square", size: 14, strokeWidth: 1.75)
                        .foregroundStyle(checked ? Theme.ink : enabled ? Theme.muted : Theme.faint)
                }
                content().frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxWidth: .infinity, minHeight: 34, alignment: .leading)
            .background {
                RoundedRectangle(cornerRadius: Theme.radiusControl, style: .continuous)
                    .fill(selected ? Theme.pressed : hovering && enabled ? Theme.hover : .clear)
                    .padding(.horizontal, -8)
            }
            .overlay(alignment: .leading) { if selected { Theme.signal.frame(width: 2, height: 14).offset(x: -8) } }
            .overlay(alignment: .bottom) { if ruled { Rule() } }
            .contentShape(Rectangle())
        }
        .buttonStyle(NativeModelChoiceButtonStyle()).disabled(!enabled).pointingHand(enabled)
        .onHover { hovering = $0 }
        .animation(reduceMotion ? nil : NativeMotion.hover, value: hovering)
        .accessibilityValue(checked.map { $0 ? "Selected" : "Not selected" } ?? "")
        .accessibilityAddTraits(selected || checked == true ? [.isSelected] : [])
    }
}

/// One action in a provider's tools popover.
private struct NativeSwitcherToolRow: View {
    let icon: String
    let title: String
    var detail = ""
    var danger = false
    var ruled = true
    let action: () -> Void
    @Environment(\.isEnabled) private var enabled
    var body: some View {
        LedgerRow(minHeight: 38, ruled: ruled, action: action) {
            HStack(spacing: 10) {
                NativeIcon(icon, size: 14, strokeWidth: 1.75).foregroundStyle(danger ? Theme.failFg : Theme.muted)
                Text(title).font(Theme.ui(12.5)).foregroundStyle(danger ? Theme.failFg : Theme.ink).lineLimit(1)
                Spacer(minLength: 8)
                if !detail.isEmpty {
                    Text(detail).font(Theme.mono(10.5)).foregroundStyle(Theme.muted).lineLimit(1).truncationMode(.middle).frame(maxWidth: 120, alignment: .trailing)
                }
            }
        }
        .opacity(enabled ? 1 : 0.4)
    }
}

/// A value that opens a chooser: the same face as `Pick`, for popovers.
struct NativeSwitcherTrigger: View {
    var text: String
    var mono = false
    var fill = false
    @State private var hovering = false
    @Environment(\.isEnabled) private var enabled
    var body: some View {
        HStack(spacing: 8) {
            Text(text).font(mono ? Theme.mono(11.5) : Theme.ui(12.5)).lineLimit(1).truncationMode(.middle)
            if fill { Spacer(minLength: 0) }
            NativeIcon("chevrons-up-down", size: 12, strokeWidth: 1.75).foregroundStyle(Theme.muted)
        }
        .foregroundStyle(Theme.ink).padding(.horizontal, 10).frame(maxWidth: fill ? .infinity : nil).frame(height: 28)
        .background(hovering ? Theme.hover : .clear, in: RoundedRectangle(cornerRadius: Theme.radiusControl, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Theme.radiusControl, style: .continuous).strokeBorder(Theme.ruleStrong, lineWidth: 1))
        .contentShape(Rectangle()).opacity(enabled ? 1 : 0.4)
        .onHover { hovering = $0 && enabled }.pointingHand(enabled)
    }
}

/// Worker slots drawn as ticks: filled for a taken slot.
private struct NativeSwitcherSlots: View {
    let used: Int
    let of: Int
    var body: some View {
        HStack(spacing: 3) {
            ForEach(0..<of, id: \.self) { index in
                (index < used ? Theme.ink : Theme.faint).frame(width: 2, height: 9)
            }
        }
        .accessibilityHidden(true)
    }
}

/// Buttons in reading order that wrap onto the next line when the page narrows.
private struct NativeSwitcherWrap: Layout {
    var spacing: CGFloat = 8
    private func lines(_ width: CGFloat, _ subviews: Subviews) -> [(range: Range<Int>, height: CGFloat)] {
        var result: [(range: Range<Int>, height: CGFloat)] = []
        var start = 0, x: CGFloat = 0, height: CGFloat = 0
        for (index, view) in subviews.enumerated() {
            let size = view.sizeThatFits(.unspecified)
            if index > start, x + size.width > width {
                result.append((start..<index, height)); start = index; x = 0; height = 0
            }
            x += size.width + spacing; height = max(height, size.height)
        }
        if start < subviews.count { result.append((start..<subviews.count, height)) }
        return result
    }
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width.flatMap { $0.isFinite ? $0 : nil } ?? subviews.reduce(0) { $0 + $1.sizeThatFits(.unspecified).width + spacing }
        let rows = lines(width, subviews)
        return CGSize(width: width, height: rows.reduce(0) { $0 + $1.height } + spacing * CGFloat(max(0, rows.count - 1)))
    }
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for row in lines(bounds.width, subviews) {
            var x = bounds.minX
            for index in row.range {
                let size = subviews[index].sizeThatFits(.unspecified)
                subviews[index].place(at: CGPoint(x: x, y: y + (row.height - size.height) / 2), anchor: .topLeading, proposal: ProposedViewSize(size))
                x += size.width + spacing
            }
            y += row.height + spacing
        }
    }
}

private struct NativeSwitcherRouteModelControl: View {
    let models: [String]
    @Binding var chosen: String
    @State private var open = false
    @State private var query = ""
    var body: some View {
        Button { query = ""; open = true } label: {
            NativeSwitcherTrigger(text: chosen.isEmpty ? "pick model" : chosen, mono: true, fill: true)
        }
        .buttonStyle(.plain)
        .popover(isPresented: $open) {
            VStack(alignment: .leading, spacing: 12) {
                Text("Choose model").font(Theme.display(17)).foregroundStyle(Theme.ink)
                Entry(placeholder: "Search or enter model ID", text: $query, mono: true, icon: "search", autoFocus: true, onSubmit: { commitQuery() })
                    .accessibilityLabel("Search or enter model ID")
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        let custom = query.trimmingCharacters(in: .whitespacesAndNewlines)
                        if !custom.isEmpty && !models.contains(custom) {
                            NativeSwitcherChoiceRow(selected: false) { chosen = custom; open = false } content: {
                                HStack(spacing: 8) {
                                    NativeIcon("plus", size: 13, strokeWidth: 1.75).foregroundStyle(Theme.muted)
                                    Text("Use custom model: " + custom).font(Theme.ui(12.5)).lineLimit(1).truncationMode(.middle)
                                }
                            }
                        }
                        ForEach(NativeSwitcherDisplayPolicies.matchingModels(models, query: query), id: \.self) { model in
                            NativeSwitcherChoiceRow(selected: model == chosen) { chosen = model; open = false } content: {
                                Text(model).font(Theme.mono(12)).foregroundStyle(Theme.ink).lineLimit(1).truncationMode(.middle)
                            }
                        }
                        if models.isEmpty {
                            Text("No model list yet. Refresh the provider or enter a custom model ID.")
                                .font(Theme.ui(12.5)).foregroundStyle(Theme.muted).padding(.vertical, 14)
                        }
                    }
                    .padding(.horizontal, 8)
                }
                .frame(height: 300).padding(.horizontal, -8)
                HStack(spacing: 12) {
                    Text("Applied when you click the provider's row.").font(Theme.ui(11.5)).foregroundStyle(Theme.muted)
                    Spacer(minLength: 0)
                    Button("Done") { if query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { open = false } else { commitQuery() } }
                        .buttonStyle(Press(.primary))
                }
            }
            .padding(20).frame(width: 440).background(Theme.popover).foregroundStyle(Theme.ink)
        }
    }
    private func commitQuery() {
        if let model = NativeSwitcherDisplayPolicies.claudeSubmitChoice(models: models, query: query) { chosen = model; open = false }
    }
}

private struct NativeSwitcherProviderForm: View {
    let save: (JSONObject) async -> Bool
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var url = ""
    @State private var key = ""
    @State private var busy = false
    @State private var failed = false
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Add API provider").font(Theme.display(17)).foregroundStyle(Theme.ink).accessibilityAddTraits(.isHeader)
            TickRule(span: 60).padding(.top, 14).padding(.bottom, 20)
            VStack(alignment: .leading, spacing: 16) {
                field("Name") { Entry(placeholder: "Name", text: $name, autoFocus: true) }
                field("Base URL") { Entry(placeholder: "https://api.example.com/v1", text: $url, mono: true).accessibilityLabel("Base URL") }
                field("API key") { Entry(placeholder: "May be empty", text: $key, mono: true).accessibilityLabel("Free API key") }
            }
            Text("Adding discovers the models and detects the wire format. Browser session credentials stay in Codex Web GPT.")
                .font(Theme.ui(11.5)).foregroundStyle(Theme.muted).fixedSize(horizontal: false, vertical: true).padding(.top, 14)
            if failed {
                Notice(text: "Provider could not be added; inspect the Switcher message and retry explicitly.", tone: .fail)
                    .accessibilityLabel("Error: Provider could not be added; inspect the Switcher message and retry explicitly.").padding(.top, 14)
            }
            HStack(spacing: 8) {
                Spacer(minLength: 0)
                Button("Cancel") { dismiss() }.buttonStyle(Press(.secondary)).keyboardShortcut(.cancelAction)
                Button(busy ? "Detecting" : "Add and detect") {
                    busy = true
                    Task {
                        let ok = await save(["operation": "add", "name": .string(name), "url": .string(url), "key": .string(key)])
                        busy = false
                        if ok { dismiss() } else { failed = true }
                    }
                }
                .buttonStyle(Press(.primary)).disabled(busy || name.isEmpty || url.isEmpty)
            }
            .padding(.top, 24)
        }
        .padding(24).frame(width: 520).background(Theme.canvas).foregroundStyle(Theme.ink)
    }
    private func field<Control: View>(_ label: String, @ViewBuilder control: () -> Control) -> some View {
        VStack(alignment: .leading, spacing: 6) { MicroLabel(label); control() }
    }
}
