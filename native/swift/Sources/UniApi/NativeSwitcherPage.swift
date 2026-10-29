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
    private var tab: String { NativeSwitcherDisplayPolicies.engine(savedEngine) }
    init(runtime: NativeRuntime) { self.runtime = runtime; _state = StateObject(wrappedValue: NativeSwitcherModel(runtime: runtime)) }
    var body: some View {
        NativePage(title: tab == "claude" ? "Claude Code" : "Codex", subtitle: tab == "claude" ? "What new Claude Code sessions talk to. Sessions already open keep their old route." : "Providers and models for Codex desktop and new CLI sessions.", readiness: state.readiness, actions: {
            HStack(spacing: 8) {
                if tab == "claude" { NativeStatusDot(color: state.claude["shim"]["ok"] == true ? Theme.okFg : Theme.muted) }
                Button { Task { await state.reload() } } label: { HStack(spacing: 6) { NativeIcon("rotate-cw", size: 12); Text("Reload") } }.disabled(state.busy)
                if tab == "codex" { Button { run("codexAction", ["action": "open"]) } label: { HStack(spacing: 6) { NativeIcon("external-link", size: 12); Text("Open Codex") } }.disabled(state.controlsBusy) }
            }
        }) {
            T3Segmented(options: [("claude", "Claude Code"), ("codex", "Codex")], selection: tab) { savedEngine = $0 }
            if !state.error.isEmpty { NativeError(message: state.error) }
            if !state.message.isEmpty { Text(state.message).font(Theme.ui(12)).foregroundStyle(Theme.muted).textSelection(.enabled) }
            if state.claude.isNull || state.codex.isNull { ShimmerText(text: "Reading native configuration…") }
            else if tab == "claude" { claude }
            else { codex }
        }
        .nativePageTask { await state.begin(runtime) }.nativePageActivity(suspended: { state.stop() })
        .sheet(isPresented: $addProvider) { NativeSwitcherProviderForm { values in await state.act("provider", values) } }
    }
    private func run(_ operation: String, _ values: JSONObject = [:]) { Task { _ = await state.act(operation, values) } }
    private var claude: some View {
        VStack(alignment: .leading, spacing: 24) {
            NativeCard {
                HStack(spacing: 14) {
                    NativeIcon(state.claude["snapshot"]["baseUrl"].string.isEmpty ? "sparkle" : "git-branch", size: 17)
                        .foregroundStyle(Theme.accent).frame(width: 40, height: 40)
                        .background(Theme.accent.opacity(0.16), in: RoundedRectangle(cornerRadius: Theme.radiusMd))
                    VStack(alignment: .leading, spacing: 5) {
                        Text(state.claude["currentName"].string).font(Theme.ui(18, weight: .semibold))
                        Text(state.claude["snapshot"]["model"].string.isEmpty ? "No gateway · Claude Code picks its own models" : state.claude["snapshot"]["model"].string).font(Theme.ui(12.5)).foregroundStyle(Theme.muted)
                    }
                    Spacer(minLength: 8)
                    if !state.claude["snapshot"]["baseUrl"].string.isEmpty {
                        Button("Restore subscription") { run("restore") }.disabled(state.busy)
                    }
                }
            }
            VStack(alignment: .leading, spacing: 20) {
                SettingRow(title: "Model", desc: "Gateways need an explicit model ID; the subscription uses its own default.") {
                    Text(state.claude["snapshot"]["model"].string.isEmpty ? "not set" : state.claude["snapshot"]["model"].string).font(Theme.mono(12)).foregroundStyle(Theme.muted).lineLimit(1).frame(maxWidth: 240, alignment: .trailing)
                }
                SettingRow(title: "Thinking effort", desc: "Applies to new Claude sessions.") {
                    T3Segmented(options: [("", "Default")] + state.claude["efforts"].array.map { ($0.string, $0.string.capitalized) }, selection: state.claude["snapshot"]["effort"].string, enabled: !state.busy) { run("effort", ["effort": $0.isEmpty ? .null : .string($0)]) }
                }
                SettingRow(title: "Base URL", desc: "An empty base URL uses the real Anthropic API.") {
                    Text(state.claude["snapshot"]["baseUrl"].string.isEmpty ? "api.anthropic.com" : state.claude["snapshot"]["baseUrl"].string).font(Theme.mono(12)).foregroundStyle(Theme.muted).lineLimit(1).frame(maxWidth: 240, alignment: .trailing)
                }
            }
            Rectangle().fill(Theme.border).frame(height: 1)
            VStack(alignment: .leading, spacing: 12) {
                SectionLabel(text: "Providers") {
                    Button { addProvider = true } label: { HStack(spacing: 6) { NativeIcon("plus", size: 12); Text("Add provider") } }.disabled(state.busy)
                }
                Text("API providers can also serve Claude Code. Use switches to it; Enable auto-detects the wire format of one that is benchmark-only.").font(Theme.ui(12.5)).foregroundStyle(Theme.muted)
                Card(padding: 0) {
                    NativeSwitcherListRow(active: state.claude["snapshot"]["baseUrl"].string.isEmpty) {
                        HStack(spacing: 11) {
                            NativeIcon("sparkle", size: 15).foregroundStyle(Theme.muted).frame(width: 30)
                            VStack(alignment: .leading, spacing: 4) {
                                Text("Anthropic subscription").font(Theme.ui(14, weight: .medium))
                                Text("No gateway · Claude Code picks its own models").font(Theme.ui(12.5)).foregroundStyle(Theme.muted)
                            }
                            Spacer()
                            if state.claude["snapshot"]["baseUrl"].string.isEmpty { activeBadge }
                        }
                    }
                    ForEach(state.claude["providers"].array, id: \.self["id"]) { provider in
                        Rectangle().fill(Theme.border).frame(height: 1)
                        providerRow(provider)
                    }
                }
                if state.claude["providers"].array.contains(where: { !$0["format"].isNull }) {
                    Text("Text probes check replies only. Responses and coding tools have separate verification.").font(Theme.ui(11)).foregroundStyle(Theme.muted)
                }
            }
            Rectangle().fill(Theme.border).frame(height: 1)
            SettingRow(title: "Translation shim", desc: state.claude["shim"]["ok"] == true ? "Swift listener is available." : state.claude["shim"]["legacyPresent"] == true ? "The existing legacy listener was preserved." : "Swift listener is unavailable.") {
                HStack(spacing: 8) {
                    StatusDot(color: state.claude["shim"]["ok"] == true ? Theme.okFg : Theme.muted, size: 7)
                    if state.claude["shim"]["owned"] == true { Button("Stop owned shim") { run("stopShim") }.disabled(state.busy) }
                    else if state.claude["shim"]["ok"] != true { Button("Start native shim") { run("startShim") }.disabled(state.busy) }
                }
            }
        }
    }
    private var activeBadge: some View {
        HStack(spacing: 5) { NativeIcon("check", size: 12); Text("Active") }.font(Theme.ui(11.5, weight: .medium)).foregroundStyle(Theme.okFg).frame(width: 78, alignment: .trailing)
    }
    private func providerRow(_ provider: JSONValue) -> some View {
        let id = provider["id"].string, chosen = chosenModel(provider)
        return NativeSwitcherListRow(active: state.claude["current"] == provider["id"]) {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 11) {
                    providerIdentity(provider).fixedSize(horizontal: true, vertical: false)
                    Spacer(minLength: 8)
                    providerRowActions(provider, id: id, chosen: chosen)
                }
                VStack(alignment: .leading, spacing: 10) {
                    providerIdentity(provider)
                    HStack { Spacer(minLength: 0); providerRowActions(provider, id: id, chosen: chosen) }
                }
            }
            if state.claudeProbe["provider"] == provider["id"] {
                let verdict = state.claudeProbe, working = verdict["ok"] == true && verdict["empty"] != true
                HStack(alignment: .top) { StatusDot(color: working ? Theme.okFg : Theme.failFg, size: 6); Text(verdict["model"].string + " · " + (working ? "Answered" : "Route check failed") + " · " + String(format: "%.1f s", verdict["ms"].double / 1000)).font(Theme.mono(11)); Spacer() }
                Text(verdict["message"].string).font(Theme.ui(12)).foregroundStyle(working ? Theme.muted : Theme.failFg).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
            }
        }
    }
    private func providerIdentity(_ provider: JSONValue) -> some View {
        HStack(spacing: 11) {
            NativeIcon(provider["directUrl"].isNull ? "git-branch" : "external-link", size: 15).foregroundStyle(state.claude["current"] == provider["id"] ? Theme.accent : Theme.muted).frame(width: 30)
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 7) {
                        Text(provider["name"].string).font(Theme.ui(14, weight: .medium))
                        if !provider["format"].isNull { Text(provider["format"].string).font(Theme.mono(11)).foregroundStyle(provider["format"] == "anthropic" ? Theme.okFg : Theme.warnFg) }
                    }
                    Text(provider["format"].isNull ? "Benchmark-only · not wired for Claude Code yet" : "\(provider["models"].array.count) models · " + (provider["directUrl"].isNull ? "via shim" : "direct")).font(Theme.ui(12.5)).foregroundStyle(Theme.muted)
                }
        }
    }
    private func providerRowActions(_ provider: JSONValue, id: String, chosen: String) -> some View {
                HStack(spacing: 8) {
                    if !provider["format"].isNull {
                        NativeSwitcherRouteModelControl(models: provider["models"].array.map(\.string), chosen: Binding(get: { chosenModel(provider) }, set: { models[id] = $0 })).frame(width: 190).help(chosen).disabled(state.busy)
                    } else { Color.clear.frame(width: 190, height: 1) }
                    Group {
                        if provider["format"].isNull { Button("Enable") { run("provider", ["operation": "adopt", "id": provider["id"]]) } }
                        else { Button("Use") { run("applyAndProbe", ["id": provider["id"], "model": .string(chosen)]) }.buttonStyle(T3Button(.primary)) }
                    }.frame(width: 78, alignment: .trailing).disabled(state.busy)
                    Button { run("provider", ["operation": "refresh", "id": provider["id"]]) } label: { NativeIcon("rotate-cw", size: 13) }.buttonStyle(T3Button(.ghost)).help("Refresh models").accessibilityLabel("Refresh models for " + provider["name"].string).frame(width: 28).disabled(state.busy)
                    Button { providerToolsID = id } label: { NativeIcon("ellipsis", size: 13) }
                        .buttonStyle(T3Button(.ghost)).help("Provider tools").accessibilityLabel("Tools for " + provider["name"].string)
                        .popover(isPresented: Binding(get: { providerToolsID == id }, set: { if !$0 { providerToolsID = nil } })) { providerTools(provider, chosen: chosen) }
                }
    }
    private func providerTools(_ provider: JSONValue, chosen: String) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(provider["name"].string).font(Theme.ui(14, weight: .medium))
            Text(provider["baseUrl"].string).font(Theme.mono(11)).foregroundStyle(Theme.muted).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                if !provider["format"].isNull {
                    Button("Save model") { run("modelAndProbe", ["id": provider["id"], "model": .string(chosen)]) }.buttonStyle(T3Button(.ghost)).disabled(chosen.isEmpty || state.busy)
                    Button("Text probe") { run("probe", ["id": provider["id"], "model": .string(chosen)]) }.buttonStyle(T3Button(.ghost)).disabled(state.busy)
                }
                Button { Task { await state.copy(provider["id"]) } } label: { NativeIcon("key-round", size: 12) }.buttonStyle(T3Button(.ghost)).help("Copy key").accessibilityLabel("Copy key for " + provider["name"].string).disabled(provider["hasKey"] != true)
                Button { run("provider", ["operation": "remove", "id": provider["id"]]) } label: { NativeIcon("trash-2", size: 12) }.buttonStyle(T3Button(.ghost)).foregroundStyle(Theme.failFg).help("Remove provider").accessibilityLabel("Remove " + provider["name"].string).disabled(state.busy)
            }
        }.padding(16).frame(width: 370).background(Theme.bg).foregroundStyle(Theme.ink)
    }
    private var codex: some View {
        VStack(alignment: .leading, spacing: 24) {
            NativeCard {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 5) {
                        Text("Default in config").font(Theme.ui(11.5)).foregroundStyle(Theme.muted)
                        Text(state.codex["current"]["model"].string.isEmpty ? "Native model default" : state.codex["current"]["model"].string).font(Theme.ui(18, weight: .semibold)).textSelection(.enabled)
                        Text([state.codex["current"]["source"].string, state.codex["current"]["effort"].string.isEmpty ? "default effort" : state.codex["current"]["effort"].string].filter { !$0.isEmpty }.joined(separator: " · ")).font(Theme.ui(12.5)).foregroundStyle(Theme.muted)
                    }
                    Spacer()
                    Text(state.codex["installed"] == true ? "Codex installed" : "Codex not found").font(Theme.ui(11)).foregroundStyle(Theme.muted).padding(.horizontal, 7).padding(.vertical, 4).background(Theme.subtle, in: RoundedRectangle(cornerRadius: 5))
                }
                Text("Already-open tasks can keep their previous model. Reload Codex after a change when requested.").font(Theme.ui(11.5)).foregroundStyle(Theme.muted)
            }
            ForEach(Array(state.codex["warnings"].array.enumerated()), id: \.offset) { _, warning in HStack(alignment: .top, spacing: 8) { NativeIcon("triangle-alert", size: 13); Text(warning.string) }.font(Theme.ui(12)).foregroundStyle(Theme.warnFg).fixedSize(horizontal: false, vertical: true) }
            nativeRoutingSection
            catalogSection
            Rectangle().fill(Theme.border).frame(height: 1)
            defaultSection
            Rectangle().fill(Theme.border).frame(height: 1)
            bridgeSection
        }
    }
    private var nativeRoutingSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionLabel("UniApi native API routing")
            NativeCard {
                Text("Use API providers and ChatGPT subscription models with UniApi's background service. Codex Web GPT is optional.").font(Theme.ui(12.5)).foregroundStyle(Theme.muted)
                HStack(spacing: 18) {
                    readiness("Connected", state.codex["native"]["connected"])
                    readiness("Service ready", state.codex["native"]["running"])
                }
                if let issue = nativeEditingIssue { Text(issue).font(Theme.ui(12)).foregroundStyle(Theme.warnFg) }
                NativeScrollRail {
                    Button("Connect native API routing") { run("codexAction", ["action": "nativeConnect"]) }.buttonStyle(T3Button(.primary))
                        .disabled(state.controlsBusy || state.codex["native"]["canConnect"] != true)
                    Button("Restore direct Codex") { run("codexAction", ["action": "restore"]) }
                        .disabled(state.controlsBusy || state.codex["restoreAvailable"] != true)
                }
                Text("Connecting hands off an idle Web route and keeps the selected default, providers and workers. Reload Codex when requested.").font(Theme.ui(11.5)).foregroundStyle(Theme.muted)
            }
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
        VStack(alignment: .leading, spacing: 16) {
            SectionLabel("Models in Codex")
            Text("Keep native and API models in one picker, with Web models when the optional bridge is connected. One native row is reserved; select at most four preferred workers. Existing chats retain their current roster until reloaded.").font(Theme.ui(12.5)).foregroundStyle(Theme.muted)
            VStack(alignment: .leading, spacing: 8) {
                let providers = state.catalogDraft.visibleProviders(state.codex["catalog"]["providers"].array)
                HStack {
                    Text("API providers").font(Theme.ui(14, weight: .medium))
                    Spacer()
                    Button { addProvider = true } label: { HStack(spacing: 6) { NativeIcon("plus", size: 12); Text("Add provider") } }
                        .disabled(state.controlsBusy)
                }
                if providers.isEmpty {
                    Text("Add a provider to set up its API models for Codex.").font(Theme.ui(12.5)).foregroundStyle(Theme.muted)
                }
                ForEach(providers, id: \.self["id"]) { provider in
                    HStack(alignment: .top, spacing: 8) {
                        NativeSwitcherCheckRow(title: provider["name"].string, detail: provider["id"].string, checked: state.catalogDraft.providerIDs.contains(provider["id"].string)) { state.catalogDraft.toggleProvider(provider, models: state.codex["models"].array) }
                            .disabled(state.controlsBusy || !state.catalogDraft.providerIDs.contains(provider["id"].string) && provider["available"] != true)
                        Button("Check route") { run("verifyProvider", ["id": provider["id"]]) }.disabled(state.controlsBusy || !state.codex["catalog"]["providers"].array.contains { $0["id"] == provider["id"] }).padding(.top, 7)
                    }
                    if !provider["reason"].isNull { Text(provider["reason"].string).font(Theme.ui(11)).foregroundStyle(Theme.warnFg).padding(.leading, 38) }
                }
            }
            VStack(alignment: .leading, spacing: 10) {
                HStack { Text("Preferred worker models").font(Theme.ui(14, weight: .medium)); Spacer(); Text("\(state.catalogDraft.workers.count) / 4").font(Theme.mono(12)).foregroundStyle(Theme.muted) }
                customModelControls
                T3Field(placeholder: "Search preferred workers", text: $workerQuery)
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 4) {
                        ForEach(catalogWorkers, id: \.key) { item in
                            let row = item.row
                            let worker = NativeSwitcherCatalogDraft.workerID(row), checked = state.catalogDraft.workers.contains(worker)
                            NativeSwitcherCheckRow(title: modelLabel(row) + (row["workerReserved"] == true ? " · Reserved" : ""), detail: row["id"].string, checked: checked) { state.catalogDraft.toggleWorker(row) }
                                .disabled(state.controlsBusy || !checked && (row["workerReserved"] == true || row["available"] != true || state.catalogDraft.workers.count >= 4))
                            if row["available"] != true || row["workerReserved"] == true { Text(row["workerReserved"] == true ? "Included in the reserved native slot." : row["reason"].string).font(Theme.ui(11)).foregroundStyle(Theme.muted).padding(.leading, 38) }
                        }
                    }
                }.frame(maxHeight: 288)
            }
            if state.catalogDraft.workers.count >= 4 { Text("All four preferred worker slots are full. You can still add a model; remove a worker to select it.").font(Theme.ui(11)).foregroundStyle(Theme.muted) }
            if let issue = codexCatalogIssue { Text(issue).font(Theme.ui(11)).foregroundStyle(Theme.warnFg) }
            HStack(spacing: 12) {
                Button("Save catalog and workers") { run("catalog", state.catalogDraft.body) }.buttonStyle(T3Button(.primary)).disabled(state.controlsBusy || !state.catalogDraft.dirty || state.catalogDraft.workers.count > 4 || codexCatalogIssue != nil)
                Text(state.catalogDraft.dirty ? "Unsaved catalog changes" : "Catalog matches saved settings").font(Theme.ui(11.5)).foregroundStyle(Theme.muted)
            }
        }
    }
    private var customModelProviders: [JSONValue] {
        state.codex["catalog"]["providers"].array.filter { $0["available"] == true && state.catalogDraft.providerIDs.contains($0["id"].string) }
    }
    private var customModelProvider: JSONValue? { customModelProviders.first { $0["id"].string == customModelProviderID } ?? customModelProviders.first }
    private var customModelControls: some View {
        VStack(alignment: .leading, spacing: 8) {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 8) {
                    customModelProviderMenu.frame(width: 190)
                    customModelField.frame(minWidth: 180)
                }
                VStack(alignment: .leading, spacing: 8) {
                    customModelProviderMenu
                    customModelField
                }
            }
            HStack(alignment: .top, spacing: 10) {
                customModelAddButton.fixedSize()
                Text(customModelProviders.isEmpty ? "Select an available API provider above to add a custom model." : "Add a model omitted by the provider's model list using its exact ID. Save catalog and workers to apply your choices.")
                    .font(Theme.ui(11)).foregroundStyle(Theme.muted).fixedSize(horizontal: false, vertical: true)
            }
        }
    }
    private var customModelProviderMenu: some View {
        let provider = customModelProvider
        return Menu {
            ForEach(customModelProviders, id: \.self["id"]) { provider in
                Button(provider["name"].string.isEmpty ? provider["id"].string : provider["name"].string) { customModelProviderID = provider["id"].string }
            }
        } label: {
            HStack(spacing: 6) {
                Text(provider.map { $0["name"].string.isEmpty ? $0["id"].string : $0["name"].string } ?? "Choose API provider").lineLimit(1)
                Spacer(minLength: 0)
                NativeIcon("chevron-down", size: 12).foregroundStyle(Theme.muted)
            }.font(Theme.ui(12, weight: .medium)).foregroundStyle(Theme.dim).padding(.horizontal, 11).frame(height: 30)
                .background(Theme.subtle, in: RoundedRectangle(cornerRadius: Theme.radiusMd))
                .overlay { RoundedRectangle(cornerRadius: Theme.radiusMd).strokeBorder(Theme.input, lineWidth: 1) }
        }.menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).disabled(state.controlsBusy || provider == nil)
            .accessibilityLabel("Custom model provider").help(provider?["id"].string ?? "Select an available API provider above.")
    }
    private var customModelField: some View {
        T3Field(placeholder: "Exact custom model ID", text: $customModelID, mono: true)
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
    private var defaultSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            SectionLabel("Model source")
            NativeSwitcherSourceRow(spacing: 8) {
                sourceButton("subscription", title: "ChatGPT subscription", detail: "Native Codex models")
                sourceButton("web", title: "ChatGPT Web", detail: "Browser session")
                sourceButton("provider", title: "API providers", detail: "Compatible routes")
            }
            SettingRow(title: codexSource == "web" ? "Web model and mode" : "Model", desc: "Choose a model, then save to change the default.") {
                Button { showCodexModels = true } label: { HStack(spacing: 8) { Text(selectedRow.map { $0["name"].string.isEmpty ? $0["id"].string : $0["name"].string } ?? "Choose model").lineLimit(1); NativeIcon("chevron-down", size: 12) } }.frame(maxWidth: 280).disabled(state.controlsBusy)
                    .popover(isPresented: $showCodexModels) { codexModels }
            }
            if let row = selectedRow {
                Text(modelLabel(row)).font(Theme.mono(11.5)).foregroundStyle(Theme.muted).textSelection(.enabled)
                if !row["efforts"].array.isEmpty {
                    SettingRow(title: "Reasoning effort", desc: codexSource == "web" ? "Web modes are separate from native Codex effort." : "Applies to the selected model.") {
                        Menu {
                            Button("Default") { state.selection.effort = "" }
                            ForEach(row["efforts"].array.map(\.string), id: \.self) { effort in Button(effort) { state.selection.effort = effort } }
                        } label: {
                            HStack(spacing: 6) { Text(selectionEffort.isEmpty ? "Default" : selectionEffort).lineLimit(1); Spacer(minLength: 0); NativeIcon("chevron-down", size: 12).foregroundStyle(Theme.muted) }
                                .font(Theme.ui(12, weight: .medium)).foregroundStyle(Theme.dim).padding(.horizontal, 11).frame(width: 150, height: 30)
                                .background(Theme.subtle, in: RoundedRectangle(cornerRadius: Theme.radiusMd))
                                .overlay { RoundedRectangle(cornerRadius: Theme.radiusMd).strokeBorder(Theme.input, lineWidth: 1) }
                        }.menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize().disabled(state.controlsBusy)
                    }
                }
                if codexSource == "web" { Text("Web mode names come from ChatGPT. They are separate from native Codex reasoning effort.").font(Theme.ui(11.5)).foregroundStyle(Theme.muted) }
                if let issue = codexSelectionIssue(row) { Text(issue).font(Theme.ui(12)).foregroundStyle(Theme.warnFg) }
                Button { run("codexSelect", ["source": row["source"], "providerId": row["providerId"], "model": row["id"], "effort": selectionEffort.isEmpty ? .null : .string(selectionEffort)]) } label: { HStack(spacing: 6) { NativeIcon("check", size: 12); Text("Set as Codex default") } }.buttonStyle(T3Button(.primary)).disabled(state.controlsBusy || codexSelectionIssue(row) != nil || NativeSwitcherModelKey(row).matches(state.codex["current"]) && selectionEffort == state.codex["current"]["effort"].string)
            }
        }
    }
    private var codexSource: String { selectedRow?["source"].string ?? emptyCodexSource }
    private func sourceButton(_ source: String, title: String, detail: String) -> some View {
        Button {
            emptyCodexSource = source
            state.selection.choose(availableModels.first { $0.row["source"] == .string(source) && $0.key.matches(state.codex["current"]) }?.row ?? availableModels.first { $0.row["source"] == .string(source) && $0.row["available"] == true }?.row ?? availableModels.first { $0.row["source"] == .string(source) }?.row)
        } label: {
            VStack(alignment: .leading, spacing: 5) { Text(title).font(Theme.ui(12.5, weight: .medium)); Text(detail).font(Theme.ui(11.5)).foregroundStyle(Theme.muted) }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading).padding(.horizontal, 12).padding(.vertical, 10)
                .background(codexSource == source ? Theme.accent.opacity(0.09) : Theme.surface, in: RoundedRectangle(cornerRadius: Theme.radiusMd))
                .overlay { RoundedRectangle(cornerRadius: Theme.radiusMd).strokeBorder(codexSource == source ? Theme.accent.opacity(0.45) : Theme.border, lineWidth: 1) }
        }.buttonStyle(.plain).pointingHand().disabled(state.controlsBusy).accessibilityAddTraits(codexSource == source ? [.isSelected] : [])
    }
    private var codexModels: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Choose model").font(Theme.ui(16, weight: .semibold))
            T3Field(placeholder: "Search model or provider", text: $codexQuery)
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
    private var bridgeSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionLabel("ChatGPT Web bridge")
            NativeCard {
                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], alignment: .leading, spacing: 12) {
                    readiness("Installed", state.codex["bridge"]["installed"]); readiness("Configured", state.codex["bridge"]["configured"]); readiness("Runtime", state.codex["bridge"]["running"]); readiness("Sign-in checked", state.codex["bridge"]["signInChecked"]); readiness("Full coding tools", state.codex["bridge"]["toolsVerified"])
                }
                if state.codex["bridge"]["healthDeferred"] == true { Text("Web runtime checks are deferred while native routing is connected. Use Check connection for an explicit check.").font(Theme.ui(11.5)).foregroundStyle(Theme.muted) }
                NativeScrollRail {
                    ForEach(["setup", "doctor", "start", "stop", "connect", "restore"], id: \.self) { action in
                        Button { run("codexAction", ["action": .string(action)]) } label: {
                            HStack(spacing: 6) { NativeIcon(action == "setup" ? "globe" : action == "doctor" ? "search-check" : action == "start" ? "play" : action == "stop" ? "square" : action == "connect" ? "plug" : "unplug", size: 12); Text(action == "setup" ? "Open Web GPT" : action == "doctor" ? "Check connection" : action == "start" ? "Start bridge" : action == "stop" ? "Stop bridge" : action == "connect" ? "Connect" : "Restore direct Codex") }
                        }.disabled(state.controlsBusy || action == "restore" && state.codex["restoreAvailable"] != true || action == "stop" && state.codex["bridge"]["canStop"] != true || action == "connect" && (state.codex["native"]["connected"] == true || !state.codex["native"]["error"].isNull || !state.codex["native"]["phase"].isNull))
                    }
                }
                Text("Browser text access is separate from full local coding tools. Verification runs one explicit ephemeral tool check and stores evidence for the current bridge configuration.").font(Theme.ui(12)).foregroundStyle(Theme.muted)
                if NativeSwitcherDisplayPolicies.checksRunning(state.jobs) { Text("A Codex verification is queued or running. Follow it in Jobs before starting another check.").font(Theme.ui(12)).foregroundStyle(Theme.muted) }
                Button("Verify coding tools") { run("verifyCodexTools") }.disabled(state.controlsBusy || state.codex["installed"] != true || !state.codex["configError"].isNull || state.codex["bridge"]["mode"] != "full" || state.codex["bridge"]["busy"] != false || state.codex["bridge"]["signInChecked"] != true)
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
    private func readiness(_ label: String, _ value: JSONValue) -> some View { HStack { Text(label).font(Theme.ui(12)); Spacer(); Text(value.isNull ? "Unknown" : value.bool ? "Available" : "Not verified").font(Theme.mono(11)).foregroundStyle(value == true ? Theme.okFg : Theme.muted) } }
}

/// Measure wrapped labels at their actual column width, then give every choice
/// the tallest natural height. ScrollView's unbounded height is never reused as
/// a frame, and choosing a source does not change the geometry of its siblings.
private struct NativeSwitcherSourceRow: Layout {
    let spacing: CGFloat
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard !subviews.isEmpty else { return .zero }
        let gaps = spacing * CGFloat(subviews.count - 1)
        let natural = subviews.map { $0.sizeThatFits(.unspecified).width }.max() ?? 0
        let width = proposal.width.flatMap { $0.isFinite ? $0 : nil } ?? natural * CGFloat(subviews.count) + gaps
        let column = max(0, (width - gaps) / CGFloat(subviews.count))
        let height = subviews.map { $0.sizeThatFits(.init(width: column, height: nil)).height }.max() ?? 0
        return CGSize(width: max(0, width), height: height)
    }
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard !subviews.isEmpty else { return }
        let column = max(0, (bounds.width - spacing * CGFloat(subviews.count - 1)) / CGFloat(subviews.count))
        for (index, view) in subviews.enumerated() {
            view.place(at: CGPoint(x: bounds.minX + CGFloat(index) * (column + spacing), y: bounds.minY),
                       anchor: .topLeading, proposal: .init(width: column, height: bounds.height))
        }
    }
}

private struct NativeSwitcherListRow<Content: View>: View {
    var active = false
    @ViewBuilder var content: () -> Content
    @State private var hovering = false
    var body: some View {
        VStack(alignment: .leading, spacing: 10) { content() }
            .padding(.horizontal, 14).padding(.vertical, 11)
            .background(active ? Theme.accent.opacity(0.09) : hovering ? Theme.subtle : .clear)
            .onHover { hovering = $0 }
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
                    Text(title).font(Theme.ui(12.5, weight: .medium)).fixedSize(horizontal: false, vertical: true)
                    Text(detail).font(Theme.ui(11.5)).foregroundStyle(Theme.muted).fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }.frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 12).padding(.vertical, 10)
                .background(hovering ? Theme.subtle2 : checked ? Theme.subtle : .clear, in: RoundedRectangle(cornerRadius: Theme.radiusSm))
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
            HStack(spacing: 6) { Text(chosen.isEmpty ? "pick model" : chosen).font(Theme.mono(11.5)).lineLimit(1); Spacer(minLength: 0); NativeIcon("chevron-down", size: 12) }
        }.popover(isPresented: $open) {
            VStack(alignment: .leading, spacing: 12) {
                Text("Choose model").font(Theme.ui(16, weight: .semibold))
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
                HStack { Text("Use or Save model applies this choice.").font(Theme.ui(11)).foregroundStyle(Theme.muted); Spacer(); Button("Done") { if query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { open = false } else { commitQuery() } }.buttonStyle(T3Button(.primary)) }
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
            Text("Add API provider").font(Theme.ui(18, weight: .semibold)); T3Field(placeholder: "Name", text: $name); T3Field(placeholder: "Base URL", text: $url, mono: true); T3Field(placeholder: "Free API key", text: $key, mono: true)
            Text("This explicitly discovers models and detects the provider format. Browser session credentials stay in Codex Web GPT.").font(Theme.ui(12)).foregroundStyle(Theme.muted)
            if failed { NativeError(message: "Provider could not be added; inspect the Switcher message and retry explicitly.") }
            HStack { Button("Cancel") { dismiss() }.buttonStyle(T3Button(.outline)).keyboardShortcut(.cancelAction); Spacer(); Button(busy ? "Detecting…" : "Add and detect") { busy = true; Task { let ok = await save(["operation": "add", "name": .string(name), "url": .string(url), "key": .string(key)]); busy = false; if ok { dismiss() } else { failed = true } } }.buttonStyle(T3Button(.primary)).disabled(busy || name.isEmpty || url.isEmpty) }
        }.padding(20).frame(width: 650).background(Theme.bg).foregroundStyle(Theme.ink)
    }
}
