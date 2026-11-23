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
            message = result["message"].string.isEmpty ? result["job"].isNull ? "Saved." : "Verification queued." : result["message"].string
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
    /// The provider picked on the route line before it is applied. Nil follows the route in use.
    @State private var draftRoute: String?
    @State private var inspectedProvider: String?
    private var tab: String { NativeSwitcherDisplayPolicies.engine(savedEngine) }
    init(runtime: NativeRuntime) { self.runtime = runtime; _state = StateObject(wrappedValue: NativeSwitcherModel(runtime: runtime)) }
    var body: some View {
        NativePage(title: "Switcher", maxWidth: .infinity, readiness: state.readiness, scrolls: false, tabs: {
            NativeTabs(options: [("claude", "Claude Code"), ("codex", "Codex")], selection: tab) { savedEngine = $0; inspectedProvider = nil }
        }, actions: {
            T3IconButton(system: "refresh-cw", help: "Reload") { Task { await state.reload() } }.disabled(state.busy)
            NativeIconMenu {
                if tab == "claude" {
                    Button("Restore Anthropic subscription") { draftRoute = nil; run("restore") }.disabled(claudeDirect)
                    if state.claude["shim"]["owned"] == true { Button("Stop translation listener") { run("stopShim") } }
                } else {
                    Button("Open Codex") { run("codexAction", ["action": "open"]) }
                    Button("Restore direct Codex") { run("codexAction", ["action": "restore"]) }.disabled(state.codex["restoreAvailable"] != true)
                }
            }.disabled(tab == "claude" ? state.busy : state.controlsBusy)
            Button("Add provider", nativeIcon: "plus") { addProvider = true }.buttonStyle(T3Button(.primary)).disabled(tab == "claude" ? state.busy : state.controlsBusy)
        }) {
            if state.claude.isNull || state.codex.isNull { NativePane(maxWidth: 900, centered: false) { notices; ShimmerText(text: "Loading…") } }
            else if tab == "claude" { claude }
            else { codex }
        }
        .nativePageTask { await state.begin(runtime) }.nativePageActivity(suspended: { state.stop() })
        .sheet(isPresented: $addProvider) { NativeSwitcherProviderForm { values in await state.act("provider", values) } }
    }
    private func run(_ operation: String, _ values: JSONObject = [:]) { Task { _ = await state.act(operation, values) } }
    @ViewBuilder private var notices: some View {
        if !state.error.isEmpty { NativeError(message: state.error) }
        if !state.message.isEmpty { Text(state.message).font(Theme.ui(12)).foregroundStyle(Theme.dim).textSelection(.enabled).fixedSize(horizontal: false, vertical: true) }
    }

    // MARK: Claude Code
    private var claudeDirect: Bool { state.claude["snapshot"]["baseUrl"].string.isEmpty }
    private var claudeCurrentID: String { claudeDirect ? "" : state.claude["current"].string }
    private var routeID: String { draftRoute ?? claudeCurrentID }
    private var routedProvider: JSONValue? { state.claude["providers"].array.first { $0["id"].string == routeID && !$0["format"].isNull } }
    private var inspectedProviderRow: JSONValue? { inspectedProvider.flatMap { id in state.claude["providers"].array.first { $0["id"].string == id } } }
    private var claudeRouteChanged: Bool {
        guard routedProvider != nil else { return draftRoute != nil && !claudeDirect }
        if routeID != claudeCurrentID { return true }
        guard let picked = models[routeID] else { return false }
        return picked != state.claude["snapshot"]["model"].string
    }
    private func applyClaudeRoute() {
        if let provider = routedProvider { run("applyAndProbe", ["id": provider["id"], "model": .string(chosenModel(provider))]) }
        else { run("restore") }
    }
    private var claude: some View {
        let providers = state.claude["providers"].array
        let effort = state.claude["snapshot"]["effort"].string
        return NativeInspectorSplit(open: inspectedProviderRow != nil, width: 340, onClose: { inspectedProvider = nil }, main: {
            NativePane(maxWidth: 900, centered: false) {
                notices
                VStack(alignment: .leading, spacing: 8) {
                    NativeRouteLine(tool: "Claude Code", stops: {
                        NativeMenuSelectLabel(title: draftRoute == nil ? state.claude["currentName"].string : routedProvider?["name"].string ?? "Anthropic subscription", width: 196) {
                            Button("Anthropic subscription") { draftRoute = "" }
                            ForEach(providers.filter { !$0["format"].isNull }, id: \.self["id"]) { provider in
                                Button(provider["name"].string) { draftRoute = provider["id"].string }
                            }
                        }.disabled(state.busy).accessibilityLabel("Route for new sessions")
                        NativeRouteArrow()
                        if let provider = routedProvider {
                            NativeSwitcherRouteModelControl(models: provider["models"].array.map(\.string), chosen: Binding(get: { chosenModel(provider) }, set: { models[provider["id"].string] = $0 }))
                                .frame(width: 210).help(chosenModel(provider)).disabled(state.busy)
                        } else {
                            Text("Its own models").font(Theme.ui(Theme.textSm)).foregroundStyle(Theme.muted).frame(height: 30)
                        }
                        NativeRouteArrow()
                        NativeMenuSelectLabel(title: effort.isEmpty ? "Default effort" : effort.capitalized + " effort", width: 140) {
                            Button("Default") { run("effort", ["effort": .null]) }
                            ForEach(state.claude["efforts"].array.map(\.string), id: \.self) { value in
                                Button(value.capitalized) { run("effort", ["effort": .string(value)]) }
                            }
                        }.disabled(state.busy).accessibilityLabel("Thinking effort")
                    }, action: {
                        if claudeRouteChanged { Button("Apply", nativeIcon: "check") { applyClaudeRoute() }.buttonStyle(T3Button(.primary)).disabled(state.busy) }
                        else { activeBadge }
                    })
                    HStack(spacing: 10) {
                        Text(claudeDirect ? "api.anthropic.com" : state.claude["snapshot"]["baseUrl"].string).font(Theme.mono(Theme.textXs)).foregroundStyle(Theme.muted).lineLimit(1).truncationMode(.middle).textSelection(.enabled)
                        Text("New sessions only").font(Theme.ui(Theme.textXs)).foregroundStyle(Theme.faint).fixedSize()
                            .help("Open sessions keep the route they started with.")
                    }.padding(.leading, 14)
                    if !state.claudeProbe.isNull, inspectedProviderRow == nil { probeVerdict.padding(.leading, 14).padding(.top, 4) }
                }
                if state.claude["shim"]["ok"] != true {
                    NativeSetup(steps: [NativeSetupStep(
                        id: "shim", title: "Start the translation listener",
                        detail: state.claude["shim"]["legacyPresent"] == true ? "A legacy listener is running in its place." : "Providers that do not speak the Anthropic format are reached through it.",
                        done: false, enabled: !state.busy, actionTitle: "Start", actionIcon: "play", action: { run("startShim") })])
                }
                VStack(alignment: .leading, spacing: 0) {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text("Providers").font(Theme.ui(Theme.textSm, weight: .semibold)).accessibilityAddTraits(.isHeader)
                        Text("\(providers.count)").font(Theme.num(Theme.textXs, weight: .regular)).foregroundStyle(Theme.faint)
                    }.padding(.bottom, 10)
                    if providers.isEmpty {
                        NativeEmptyState(title: "No providers", detail: "A provider's models can be routed to Claude Code and Codex.", icon: "server")
                    } else {
                        Theme.rule.frame(height: 1)
                        ForEach(providers, id: \.self["id"]) { provider in
                            let id = provider["id"].string
                            NativeSwitcherProviderRow(provider: provider, inUse: claudeCurrentID == id, selected: inspectedProvider == id) { inspectedProvider = inspectedProvider == id ? nil : id }
                            Theme.rule.frame(height: 1)
                        }
                    }
                }
            }
        }, inspector: {
            if let provider = inspectedProviderRow { providerInspector(provider) }
        })
    }
    private var activeBadge: some View {
        HStack(spacing: 5) { NativeIcon("check", size: 12); Text("In use") }.font(Theme.ui(Theme.textXs, weight: .medium)).foregroundStyle(Theme.accent).frame(height: 30)
    }
    private var probeVerdict: some View {
        let verdict = state.claudeProbe, working = verdict["ok"] == true && verdict["empty"] != true
        return VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                NativeStatus(text: working ? "Answered" : "Route check failed", tone: working ? .ok : .fail)
                Text(verdict["model"].string + " · " + String(format: "%.1f s", verdict["ms"].double / 1000)).font(Theme.mono(11)).foregroundStyle(Theme.muted).lineLimit(1)
            }
            Text(verdict["message"].string).font(Theme.ui(12)).foregroundStyle(working ? Theme.muted : Theme.failFg).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
        }
    }
    private func providerInspector(_ provider: JSONValue) -> some View {
        let id = provider["id"].string, enabled = !provider["format"].isNull, chosen = chosenModel(provider)
        let inUse = claudeCurrentID == id && chosen == state.claude["snapshot"]["model"].string
        return NativeInspector(title: provider["name"].string, caption: provider["baseUrl"].string, icon: "server", onClose: { inspectedProvider = nil }) {
            VStack(alignment: .leading, spacing: 0) {
                NativeFact(label: "Format", value: enabled ? provider["format"].string : "Not detected", mono: enabled)
                if enabled { NativeFact(label: "Reached", value: provider["directUrl"].isNull ? "Through the translation listener" : "Directly") }
                NativeFact(label: "Models", value: "\(provider["models"].array.count)")
                NativeFact(label: "Key", value: provider["hasKey"] == true ? "Saved" : "None")
                if enabled {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Model").font(Theme.ui(Theme.textXs)).foregroundStyle(Theme.muted)
                        NativeSwitcherRouteModelControl(models: provider["models"].array.map(\.string), chosen: Binding(get: { chosenModel(provider) }, set: { models[id] = $0 }))
                            .help(chosen).disabled(state.busy)
                        HStack(spacing: 8) {
                            Button("Save as default") { run("modelAndProbe", ["id": provider["id"], "model": .string(chosen)]) }.disabled(chosen.isEmpty || state.busy)
                            Button("Text probe") { run("probe", ["id": provider["id"], "model": .string(chosen)]) }.disabled(state.busy)
                        }
                    }.padding(.top, 16)
                } else {
                    Text("Used for benchmarks only. Enabling detects its wire format so tools can be routed to it.").font(Theme.ui(Theme.textXs)).foregroundStyle(Theme.muted)
                        .fixedSize(horizontal: false, vertical: true).padding(.top, 14)
                }
                if state.claudeProbe["provider"] == provider["id"] { probeVerdict.padding(.top, 16) }
            }
        } actions: {
            HStack(spacing: 8) {
                if enabled {
                    Button(inUse ? "In use" : "Use for Claude Code") { draftRoute = nil; run("applyAndProbe", ["id": provider["id"], "model": .string(chosen)]) }
                        .buttonStyle(T3Button(.primary)).disabled(state.busy || inUse)
                } else {
                    Button("Enable") { run("provider", ["operation": "adopt", "id": provider["id"]]) }.buttonStyle(T3Button(.primary)).disabled(state.busy)
                }
                Spacer(minLength: 0)
                T3IconButton(system: "refresh-cw", help: "Refresh models") { run("provider", ["operation": "refresh", "id": provider["id"]]) }.disabled(state.busy)
                T3IconButton(system: "key-round", help: "Copy key") { Task { await state.copy(provider["id"]) } }.disabled(provider["hasKey"] != true)
                T3IconButton(system: "trash-2", help: "Remove provider") { inspectedProvider = nil; run("provider", ["operation": "remove", "id": provider["id"]]) }.disabled(state.busy)
            }
        }
    }

    // MARK: Codex
    private var codex: some View {
        let current = state.codex["current"], native = state.codex["native"]
        return NativePane(maxWidth: 900, centered: false) {
            notices
            VStack(alignment: .leading, spacing: 8) {
                NativeRouteLine(tool: "Codex", stops: {
                    NativeMenuSelectLabel(title: codexSource == "web" ? "ChatGPT Web" : codexSource == "provider" ? "API providers" : "ChatGPT subscription", width: 196) {
                        Button("ChatGPT subscription") { chooseCodexSource("subscription") }
                        Button("ChatGPT Web") { chooseCodexSource("web") }
                        Button("API providers") { chooseCodexSource("provider") }
                    }.disabled(state.controlsBusy).accessibilityLabel("Model source")
                    NativeRouteArrow()
                    Button { showCodexModels = true } label: {
                        HStack(spacing: 6) {
                            Text(selectedRow.map { $0["name"].string.isEmpty ? $0["id"].string : $0["name"].string } ?? "Choose model").font(Theme.mono(11.5)).lineLimit(1).truncationMode(.middle)
                            Spacer(minLength: 0)
                            NativeIcon("chevrons-up-down", size: 12).foregroundStyle(Theme.faint)
                        }
                    }
                    .frame(width: 210).disabled(state.controlsBusy).accessibilityLabel(codexSource == "web" ? "Web model and mode" : "Model")
                    .popover(isPresented: $showCodexModels) { codexModels }
                    if let row = selectedRow, !row["efforts"].array.isEmpty {
                        NativeRouteArrow()
                        NativeMenuSelectLabel(title: selectionEffort.isEmpty ? "Default effort" : selectionEffort, width: 140) {
                            Button("Default") { state.selection.effort = "" }
                            ForEach(row["efforts"].array.map(\.string), id: \.self) { effort in Button(effort) { state.selection.effort = effort } }
                        }.disabled(state.controlsBusy).accessibilityLabel(codexSource == "web" ? "Web mode" : "Reasoning effort")
                    }
                }, action: {
                    if let row = selectedRow {
                        if NativeSwitcherModelKey(row).matches(current) && selectionEffort == current["effort"].string { activeBadge }
                        else {
                            Button("Set default", nativeIcon: "check") { run("codexSelect", ["source": row["source"], "providerId": row["providerId"], "model": row["id"], "effort": selectionEffort.isEmpty ? .null : .string(selectionEffort)]) }
                                .buttonStyle(T3Button(.primary)).disabled(state.controlsBusy || codexSelectionIssue(row) != nil)
                        }
                    }
                })
                Text([current["model"].string.isEmpty ? "Codex default" : current["model"].string, current["source"].string, current["effort"].string.isEmpty ? "default effort" : current["effort"].string].filter { !$0.isEmpty }.joined(separator: " · "))
                    .font(Theme.mono(Theme.textXs)).foregroundStyle(Theme.muted).lineLimit(1).truncationMode(.middle).textSelection(.enabled).padding(.leading, 14)
                    .help("Open tasks can keep their previous model. Reload Codex after a change when asked.")
                Group {
                    if state.codex["installed"] != true { Text("Codex not found") }
                    ForEach(Array(state.codex["warnings"].array.enumerated()), id: \.offset) { _, warning in Text(warning.string) }
                    if let row = selectedRow, let issue = codexSelectionIssue(row) { Text(issue) }
                }.font(Theme.ui(12)).foregroundStyle(Theme.warnFg).fixedSize(horizontal: false, vertical: true).padding(.leading, 14)
            }
            if native["connected"] != true {
                NativeSetup(steps: [NativeSetupStep(
                    id: "connect", title: "Connect Codex to UniApi routing",
                    detail: !native["error"].isNull ? native["error"].string : native["running"] != true ? "The routing service is not running." : "API providers and ChatGPT subscription models are then routed through the background service.",
                    done: false, enabled: !state.controlsBusy && native["canConnect"] == true, actionTitle: "Connect", actionIcon: "plug", action: { run("codexAction", ["action": "nativeConnect"]) })])
            } else if let issue = nativeEditingIssue {
                Text(issue).font(Theme.ui(12)).foregroundStyle(Theme.warnFg).fixedSize(horizontal: false, vertical: true)
            }
            catalogSection
            bridgeSection
        }
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
    private var catalogSection: some View {
        NativeSection("Models in Codex", detail: state.catalogDraft.dirty ? "Unsaved changes" : "", trailing: {
            Button("Save", nativeIcon: "check") { run("catalog", state.catalogDraft.body) }.buttonStyle(T3Button(.primary)).disabled(state.controlsBusy || !state.catalogDraft.dirty || state.catalogDraft.workers.count > 4 || codexCatalogIssue != nil)
                .help("Save catalog and workers")
        }) {
            if let issue = codexCatalogIssue { Text(issue).font(Theme.ui(12)).foregroundStyle(Theme.warnFg).fixedSize(horizontal: false, vertical: true) }
            VStack(alignment: .leading, spacing: 6) {
                let providers = state.catalogDraft.visibleProviders(state.codex["catalog"]["providers"].array)
                // One cause that holds every provider back is said once, not under each row.
                let reasons = providers.map { $0["reason"].string }
                let shared = providers.count > 1 && !reasons[0].isEmpty && Set(reasons).count == 1 ? reasons[0] : ""
                Text("API providers").font(Theme.ui(Theme.textXs, weight: .medium)).foregroundStyle(Theme.muted)
                if !shared.isEmpty { Text(shared).font(Theme.ui(11)).foregroundStyle(Theme.warnFg).fixedSize(horizontal: false, vertical: true) }
                if providers.isEmpty {
                    Text("No providers. Add one to offer its models in Codex.").font(Theme.ui(12)).foregroundStyle(Theme.faint)
                }
                ForEach(providers, id: \.self["id"]) { provider in
                    HStack(alignment: .top, spacing: 8) {
                        NativeSwitcherCheckRow(title: provider["name"].string, detail: provider["id"].string, checked: state.catalogDraft.providerIDs.contains(provider["id"].string)) { state.catalogDraft.toggleProvider(provider, models: state.codex["models"].array) }
                            .disabled(state.controlsBusy || !state.catalogDraft.providerIDs.contains(provider["id"].string) && provider["available"] != true)
                        Button("Check route") { run("verifyProvider", ["id": provider["id"]]) }.buttonStyle(T3Button(.ghost)).disabled(state.controlsBusy || !state.codex["catalog"]["providers"].array.contains { $0["id"] == provider["id"] }).padding(.top, 4)
                    }
                    if !provider["reason"].isNull, provider["reason"].string != shared { Text(provider["reason"].string).font(Theme.ui(11)).foregroundStyle(Theme.warnFg).padding(.leading, 34) }
                }
            }
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text("Preferred workers").font(Theme.ui(Theme.textXs, weight: .medium)).foregroundStyle(Theme.muted)
                    Text("\(state.catalogDraft.workers.count)/4").font(Theme.num(Theme.textXs, weight: .medium)).foregroundStyle(state.catalogDraft.workers.count >= 4 ? Theme.warnFg : Theme.ink)
                        .help("One native row is reserved. Pick up to four workers. Open chats keep their roster until reloaded.")
                    Spacer()
                }
                T3Field(placeholder: "Filter models", text: $workerQuery, leadingIcon: "search")
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(catalogWorkers, id: \.key) { item in
                            let row = item.row
                            let worker = NativeSwitcherCatalogDraft.workerID(row), checked = state.catalogDraft.workers.contains(worker)
                            NativeSwitcherCheckRow(title: modelLabel(row) + (row["workerReserved"] == true ? " · Reserved" : ""), detail: row["workerReserved"] == true ? "Included in the reserved native slot" : row["available"] != true && !row["reason"].string.isEmpty ? row["reason"].string : row["id"].string, checked: checked) { state.catalogDraft.toggleWorker(row) }
                                .disabled(state.controlsBusy || !checked && (row["workerReserved"] == true || row["available"] != true || state.catalogDraft.workers.count >= 4))
                        }
                    }
                }.frame(maxHeight: 288)
                customModelControls
            }
        }
    }
    private var customModelProviders: [JSONValue] {
        state.codex["catalog"]["providers"].array.filter { $0["available"] == true && state.catalogDraft.providerIDs.contains($0["id"].string) }
    }
    private var customModelProvider: JSONValue? { customModelProviders.first { $0["id"].string == customModelProviderID } ?? customModelProviders.first }
    private var customModelControls: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 8) {
                customModelProviderMenu
                customModelField.frame(minWidth: 180)
                customModelAddButton.fixedSize()
            }
            VStack(alignment: .leading, spacing: 8) {
                customModelProviderMenu
                customModelField
                customModelAddButton.fixedSize()
            }
        }.help(customModelProviders.isEmpty ? "Tick an available API provider above to add a model by ID." : "Adds a model the provider's list omits, by its exact ID.")
    }
    private var customModelProviderMenu: some View {
        let provider = customModelProvider
        return NativeMenuSelectLabel(title: provider.map { $0["name"].string.isEmpty ? $0["id"].string : $0["name"].string } ?? "Provider", width: 170) {
            ForEach(customModelProviders, id: \.self["id"]) { provider in
                Button(provider["name"].string.isEmpty ? provider["id"].string : provider["name"].string) { customModelProviderID = provider["id"].string }
            }
        }.disabled(state.controlsBusy || provider == nil).accessibilityLabel("Custom model provider")
    }
    private var customModelField: some View {
        T3Field(placeholder: "Exact model ID", text: $customModelID, mono: true)
            .accessibilityLabel("Exact custom model ID").disabled(state.controlsBusy || customModelProvider == nil)
            .onSubmit { addCustomModel() }
    }
    private var customModelAddButton: some View {
        Button { addCustomModel() } label: { HStack(spacing: 6) { NativeIcon("plus", size: 12); Text("Add model") } }
            .buttonStyle(T3Button(.outline)).disabled(state.controlsBusy || customModelProvider == nil || customModelID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
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
    private var codexSource: String { selectedRow?["source"].string ?? emptyCodexSource }
    private func chooseCodexSource(_ source: String) {
        emptyCodexSource = source
        state.selection.choose(availableModels.first { $0.row["source"] == .string(source) && $0.key.matches(state.codex["current"]) }?.row ?? availableModels.first { $0.row["source"] == .string(source) && $0.row["available"] == true }?.row ?? availableModels.first { $0.row["source"] == .string(source) }?.row)
    }
    private var codexModels: some View {
        VStack(alignment: .leading, spacing: 12) {
            T3Field(placeholder: "Search model or provider", text: $codexQuery, leadingIcon: "search")
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    let sourceModels = availableModels.filter { $0.row["source"] == .string(codexSource) }
                    let matching = sourceModels.filter { matches($0.row, codexQuery) }
                    if sourceModels.isEmpty {
                        NativeEmptyState(title: codexSource == "web" ? "No ChatGPT Web models detected" : "No models listed", detail: codexSource == "web" ? "Open setup, complete browser sign-in, then reload this page." : "Reload after configuring a compatible source.")
                    } else if matching.isEmpty {
                        NativeEmptyState(title: "No matching models", detail: "Try a different model or provider name.")
                    }
                    ForEach(matching, id: \.key) { item in
                        Button { state.selection.choose(item.row); showCodexModels = false } label: {
                            HStack(alignment: .top, spacing: 10) {
                                NativeIcon(state.selection.key == item.key ? "circle-dot" : "circle", size: 14).foregroundStyle(state.selection.key == item.key ? Theme.okFg : Theme.muted)
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(item.label).font(Theme.ui(12.5)).foregroundStyle(item.row["available"] == true ? Theme.ink : Theme.muted)
                                    Text(item.row["id"].string).font(Theme.mono(11)).foregroundStyle(Theme.muted)
                                    if item.row["available"] != true { Text(item.row["reason"].string.isEmpty ? "Unavailable" : item.row["reason"].string).font(Theme.ui(11.5)).foregroundStyle(Theme.warnFg).fixedSize(horizontal: false, vertical: true) }
                                }
                                Spacer(minLength: 0)
                            }.padding(10).background(state.selection.key == item.key ? Theme.subtle : .clear, in: RoundedRectangle(cornerRadius: Theme.radiusSm))
                        }.buttonStyle(NativeModelChoiceButtonStyle()).pointingHand(!state.controlsBusy && item.row["available"] == true).disabled(state.controlsBusy || item.row["available"] != true).accessibilityAddTraits(state.selection.key == item.key ? [.isSelected] : [])
                    }
                }
            }.frame(height: 300)
        }.padding(16).frame(width: 460).background(Theme.bg).foregroundStyle(Theme.ink)
    }
    private var bridgeSteps: [NativeSetupStep] {
        let bridge = state.codex["bridge"], native = state.codex["native"], busy = state.controlsBusy
        func step(_ id: String, _ title: String, _ value: JSONValue, _ actionTitle: String, _ icon: String, enabled: Bool = true, _ operation: String, _ values: JSONObject = [:]) -> NativeSetupStep {
            NativeSetupStep(id: id, title: title, detail: value.isNull ? "Not checked" : "", done: value == true, enabled: enabled && !busy, actionTitle: actionTitle, actionIcon: icon, action: { run(operation, values) })
        }
        // Connect needs a running runtime with verified tools, so it is last;
        // "configured" only means bridge settings exist, not that Codex uses them.
        return [
            step("installed", "Install and configure the bridge", bridge["installed"] == true ? bridge["configured"] : bridge["installed"], "Open Web GPT", "globe", "codexAction", ["action": "setup"]),
            step("running", "Start the runtime", bridge["running"], "Start", "play", "codexAction", ["action": "start"]),
            step("signin", "Sign in to ChatGPT in the browser", bridge["signInChecked"], "Open Web GPT", "globe", "codexAction", ["action": "setup"]),
            step("tools", "Verify coding tools", bridge["toolsVerified"], "Verify", "shield-check",
                 enabled: state.codex["installed"] == true && state.codex["configError"].isNull && bridge["mode"] == "full" && bridge["busy"] == false && bridge["signInChecked"] == true, "verifyCodexTools"),
            step("integrated", "Point Codex at the bridge", bridge["integrated"], "Connect", "plug",
                 enabled: !(native["connected"] == true || !native["error"].isNull || !native["phase"].isNull), "codexAction", ["action": "connect"])
        ]
    }
    private var bridgeSection: some View {
        let bridge = state.codex["bridge"], native = state.codex["native"], steps = bridgeSteps
        return NativeDisclosure("ChatGPT Web bridge") {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    if steps.allSatisfy(\.done) { NativeStatus(text: "Ready", tone: .ok) }
                    else { Text("Optional. Routes Codex through a ChatGPT browser session.").font(Theme.ui(Theme.textXs)).foregroundStyle(Theme.muted) }
                    Spacer(minLength: 8)
                    NativeIconMenu(help: "Bridge actions") {
                        Button("Open Web GPT") { run("codexAction", ["action": "setup"]) }
                        Button("Check connection") { run("codexAction", ["action": "doctor"]) }
                        Button("Start") { run("codexAction", ["action": "start"]) }
                        Button("Stop") { run("codexAction", ["action": "stop"]) }.disabled(bridge["canStop"] != true)
                        Button("Connect") { run("codexAction", ["action": "connect"]) }.disabled(native["connected"] == true || !native["error"].isNull || !native["phase"].isNull)
                        Button("Restore direct Codex") { run("codexAction", ["action": "restore"]) }.disabled(state.codex["restoreAvailable"] != true)
                    }.disabled(state.controlsBusy)
                }
                if bridge["healthDeferred"] == true { Text("Checks are paused while native routing is connected. Check connection runs one now.").font(Theme.ui(Theme.textXs)).foregroundStyle(Theme.muted) }
                if !steps.allSatisfy(\.done) { NativeSetup(steps: steps) }
                if NativeSwitcherDisplayPolicies.checksRunning(state.jobs) { Text("A verification is running.").font(Theme.ui(Theme.textXs)).foregroundStyle(Theme.muted) }
            }
        }
    }
    private func chosenModel(_ provider: JSONValue) -> String { models[provider["id"].string] ?? (state.claude["current"] == provider["id"] && !state.claude["snapshot"]["model"].string.isEmpty ? state.claude["snapshot"]["model"].string : provider["model"].string) }
    private func modelLabel(_ row: JSONValue) -> String { (row["name"].string.isEmpty ? row["id"].string : row["name"].string) + " · " + (row["source"] == "provider" ? row["providerId"].string : row["source"].string) + (row["custom"] == true ? " · User-added" : "") }
    private var availableModels: [(key: NativeSwitcherModelKey, label: String, row: JSONValue)] { state.codex["models"].array.map { (NativeSwitcherModelKey($0), modelLabel($0), $0) } }
    private func matches(_ row: JSONValue, _ query: String) -> Bool { query.lowercased().split(whereSeparator: \.isWhitespace).allSatisfy { (modelLabel(row) + " " + row["id"].string).lowercased().contains($0) } }
    private var filteredModels: [(key: NativeSwitcherModelKey, label: String, row: JSONValue)] { availableModels.filter { $0.key == state.selection.key || matches($0.row, codexQuery) } }
    private var catalogWorkers: [(key: String, row: JSONValue)] { state.catalogDraft.visibleWorkers(state.codex["models"].array).filter { matches($0, workerQuery) }.map { (NativeSwitcherCatalogDraft.workerID($0), $0) } }
    private var selectedRow: JSONValue? { availableModels.first { $0.key == state.selection.key }?.row }
    private var selectionEffort: String { NativeSwitcherSelectionDraft.supportedEffort(selectedRow, state.selection.effort) }
}

private struct NativeSwitcherProviderRow: View {
    let provider: JSONValue, inUse: Bool, selected: Bool
    let action: () -> Void
    @State private var hovering = false
    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Text(provider["name"].string).font(Theme.ui(Theme.textSm, weight: .medium)).lineLimit(1)
                if !provider["format"].isNull { MonoChip(text: provider["format"].string, color: provider["format"] == "anthropic" ? Theme.muted : Theme.warnFg) }
                Spacer(minLength: 8)
                if inUse { HStack(spacing: 5) { NativeIcon("check", size: 12); Text("In use") }.font(Theme.ui(Theme.textXs, weight: .medium)).foregroundStyle(Theme.accent) }
                Text(provider["format"].isNull ? "Not enabled" : "\(provider["models"].array.count) models").font(Theme.num(Theme.textXs, weight: .regular)).foregroundStyle(Theme.muted)
                    .frame(width: 96, alignment: .trailing)
                NativeIcon("chevron-right", size: 13).foregroundStyle(Theme.faint).accessibilityHidden(true)
            }
            .padding(.horizontal, 10).frame(height: 42).nativeRowHover(hovering, selected: selected).contentShape(Rectangle())
        }
        .buttonStyle(.plain).pointingHand().onHover { hovering = $0 }
        .accessibilityAddTraits(selected ? [.isSelected] : [])
    }
}

private struct NativeSwitcherCheckRow: View {
    let title: String, detail: String
    let checked: Bool
    let action: () -> Void
    @State private var hovering = false
    var body: some View {
        Button(action: action) {
            HStack(alignment: .top, spacing: 12) {
                NativeIcon(checked ? "square-check" : "square", size: 14).foregroundStyle(checked ? Theme.accent : Theme.muted).padding(.top, 2)
                VStack(alignment: .leading, spacing: 4) {
                    Text(title).font(Theme.ui(Theme.textXs, weight: .medium)).fixedSize(horizontal: false, vertical: true)
                    Text(detail).font(Theme.mono(11)).foregroundStyle(Theme.muted).fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }.frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 8).padding(.vertical, 7)
                .background(hovering ? Theme.subtle : .clear, in: RoundedRectangle(cornerRadius: Theme.radiusSm, style: .continuous))
                .contentShape(Rectangle())
        }.buttonStyle(.plain).pointingHand().onHover { hovering = $0 }.accessibilityLabel(title).accessibilityValue(checked ? "Selected" : "Not selected").accessibilityAddTraits(checked ? [.isSelected] : [])
    }
}

private struct NativeSwitcherRouteModelControl: View {
    let models: [String]
    @Binding var chosen: String
    @State private var open = false
    @State private var query = ""
    var body: some View {
        Button { query = ""; open = true } label: {
            HStack(spacing: 6) { Text(chosen.isEmpty ? "Choose model" : chosen).font(Theme.mono(11.5)).lineLimit(1).truncationMode(.middle); Spacer(minLength: 0); NativeIcon("chevrons-up-down", size: 12).foregroundStyle(Theme.faint) }
        }.popover(isPresented: $open) {
            VStack(alignment: .leading, spacing: 12) {
                T3Field(placeholder: "Search or enter model ID", text: $query, mono: true)
                    .accessibilityLabel("Search or enter model ID")
                    .onSubmit { commitQuery() }
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        let custom = query.trimmingCharacters(in: .whitespacesAndNewlines)
                        if !custom.isEmpty && !models.contains(custom) { Button("Use custom model: " + custom) { chosen = custom; open = false }.buttonStyle(T3Button(.ghost)) }
                        ForEach(NativeSwitcherDisplayPolicies.matchingModels(models, query: query), id: \.self) { model in
                            Button { chosen = model; open = false } label: {
                                HStack(spacing: 10) { NativeIcon(model == chosen ? "circle-dot" : "circle", size: 14).foregroundStyle(model == chosen ? Theme.okFg : Theme.muted); Text(model).font(Theme.mono(12)); Spacer(minLength: 0) }
                                    .padding(9).background(model == chosen ? Theme.subtle : .clear, in: RoundedRectangle(cornerRadius: Theme.radiusSm))
                            }.buttonStyle(.plain).pointingHand()
                        }
                        if models.isEmpty { Text("No model list yet. Refresh the provider or enter a custom model ID.").font(Theme.ui(12)).foregroundStyle(Theme.muted) }
                    }
                }.frame(height: 300)
                HStack { Spacer(); Button("Done") { if query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { open = false } else { commitQuery() } }.buttonStyle(T3Button(.primary)) }
            }.padding(16).frame(width: 450).background(Theme.bg).foregroundStyle(Theme.ink)
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
        VStack(alignment: .leading, spacing: 14) {
            Text("Add provider").font(Theme.ui(Theme.textBase, weight: .semibold)); T3Field(placeholder: "Name", text: $name); T3Field(placeholder: "Base URL", text: $url, mono: true); T3Field(placeholder: "API key", text: $key, mono: true)
            Text("Adding lists the provider's models and detects its wire format.").font(Theme.ui(Theme.textXs)).foregroundStyle(Theme.muted)
            if failed { NativeError(message: "The provider could not be added. The reason is shown on the Switcher page.") }
            HStack(spacing: 8) { Spacer(); Button("Cancel") { dismiss() }.buttonStyle(T3Button(.ghost)).keyboardShortcut(.cancelAction); Button(busy ? "Detecting…" : "Add provider") { busy = true; Task { let ok = await save(["operation": "add", "name": .string(name), "url": .string(url), "key": .string(key)]); busy = false; if ok { dismiss() } else { failed = true } } }.buttonStyle(T3Button(.primary)).disabled(busy || name.isEmpty || url.isEmpty).keyboardShortcut(.defaultAction) }
        }.padding(20).frame(width: 480).background(Theme.bg).foregroundStyle(Theme.ink)
    }
}
