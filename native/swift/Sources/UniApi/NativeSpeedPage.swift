import SwiftUI
import AppKit
import UniApiCore
import UniApiPresentation

struct NativeSpeedPage: View {
    let runtime: NativeRuntime
    @StateObject private var state: NativeSpeedModel
    @State private var readOwner = UUID()
    @State private var picker: NativePresentedValue?
    @State private var showResults = false
    @State private var scheduleTime = "04:00"
    @State private var scheduleRestored = false
    @State private var freeFilter = "all"
    @State private var freeQuery = ""
    @State private var editor: NativePresentedValue?
    init(runtime: NativeRuntime, model: NativeSpeedModel? = nil) { self.runtime = runtime; _state = StateObject(wrappedValue: model ?? NativeSpeedModel(runtime: runtime)) }
    private var browserSelected: Bool { state.catalog["providers"].array.contains { $0["transport"] == "chatgpt-web" && state.selection["included"].array.contains($0["id"]) } }
    var body: some View {
        NativePage(title: "Benchmark", subtitle: "Measure first-token latency, decode speed, context ceilings and reliability against every provider you enable.", readiness: !state.error.isEmpty ? .failed : state.catalog.isNull || state.progress.isNull || state.free.isNull ? .pending : .ready, actions: {
            HStack(spacing: 8) {
                Button { Task { await state.reload() } } label: { HStack(spacing: 6) { NativeIcon("rotate-cw", size: 12); Text("Reload") } }
                Button { showResults = true } label: { HStack(spacing: 6) { NativeIcon("chart-bar", size: 12); Text("Results") } }
            }
        }) {
            if !state.error.isEmpty { NativeError(message: state.error) }
            VStack(alignment: .leading, spacing: 20) {
                SettingRow(title: "Depth", desc: description, descVariants: BenchmarkTier.names.map(tierDescription)) {
                    T3Segmented(options: [("quick", "Quick"), ("standard", "Standard"), ("deep", "Deep")], selection: state.selection["tier"].string, enabled: !state.anyRunning) { state.tier($0) }
                }
                SettingRow(title: "Selection", desc: "Providers run in parallel; models inside one provider run in sequence so a shared rate limit cannot skew the numbers.") { NativeNumberText(text: "\(state.pairs.count) models", font: Theme.mono(12)) }
            }
            if browserSelected { Text(BenchmarkMath.browserNote).font(Theme.ui(12)).foregroundStyle(Theme.muted).fixedSize(horizontal: false, vertical: true) }
            Rectangle().fill(Theme.border).frame(height: 1)
            VStack(alignment: .leading, spacing: 12) {
                SectionLabel(text: "Providers") { Text(state.catalog.isNull ? "Reading…" : "\(state.catalog["providers"].array.count) configured").font(Theme.ui(12)).foregroundStyle(Theme.muted) }
                if state.catalog.isNull { ShimmerText(text: "Reading provider configuration…") }
                else if state.catalog["providers"].array.isEmpty {
                    NativeEmptyState(title: "No providers yet", detail: "Add a provider in Switcher, then return here to choose models.")
                    Button { NotificationCenter.default.post(name: .nativeNavigation, object: NativeDestination.switcher) } label: {
                        HStack(spacing: 6) { NativeIcon("plus", size: 12); Text("Add provider in Switcher") }
                    }.buttonStyle(T3Button())
                }
                VStack(spacing: 2) { ForEach(state.catalog["providers"].array, id: \.self["id"]) { provider in providerRow(provider) } }.padding(.horizontal, -8)
            }
            HStack {
                if state.running { Button { Task { await state.cancel() } } label: { HStack(spacing: 6) { NativeIcon("square", size: 12); Text("Stop run") } }.buttonStyle(T3Button(.destructive)) }
                else { Button { Task { await state.run() } } label: { HStack(spacing: 6) { NativeIcon("zap", size: 14); Text("Start " + state.selection["tier"].string + " run") } }.buttonStyle(T3Button(.primary)).disabled(state.busy || state.freeRunning || state.pairs.isEmpty || !state.issues.isEmpty) }
                Spacer()
                NativeNumberText(text: "\(state.pairs.count) selected", font: Theme.mono(11), color: Theme.muted)
            }
            ForEach(state.issues, id: \.self) { NativeError(message: $0) }
            if state.running || state.progress["progress"]["done"].bool || state.progress["interrupted"].bool { progressPanel }
            if !state.progress["job"]["log"].array.isEmpty { DisclosureGroup("Persistent run log") { ScrollView { Text(state.progress["job"]["log"].array.map(\.string).joined(separator: "\n")).font(Theme.mono(11)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }.frame(maxHeight: 240) } }
            if state.progress["job"]["status"] == "failed" { NativeError(message: state.progress["job"]["error"].string) }
            Rectangle().fill(Theme.border).frame(height: 1)
            freePanel
        }
        .nativePageTask {
            await state.begin(runtime: runtime, owner: readOwner)
            if !Task.isCancelled, !scheduleRestored, !state.free["schedule"].isNull {
                scheduleTime = state.free["schedule"]["time"].string; scheduleRestored = true
            }
        }
        .nativePageActivity(suspended: { state.stopListening(owner: readOwner) })
        .sheet(item: $picker) { item in
            NativeSpeedModelPicker(provider: state.catalog["providers"].array.first { $0["id"] == item.value["id"] } ?? item.value,
                                   chosen: state.selection["models"][item.value["id"].string].array.map(\.string),
                                   discovering: state.discovering.contains(item.value["id"].string),
                                   change: { state.models(item.value["id"].string, $0) },
                                   refresh: { Task { await state.discover(item.value["id"].string) } })
        }
        .sheet(isPresented: $showResults) { NativeResultsPage(runtime: runtime).frame(width: 1250, height: 800) }
        .sheet(item: $editor) { item in NativeSpeedProviderEditor(provider: item.value, save: { name, base, key in await state.update(item.value, name: name, base: base, key: key) }) }
    }
    private var description: String { tierDescription(state.selection["tier"].string) }
    private func tierDescription(_ name: String) -> String {
        guard let tier = BenchmarkTier.configurations[name] else { return "Choose a depth." }
        return "\(tier.latency) latency samples, \(tier.throughput) output tests at \(tier.output) tokens, input sweep \(tier.contexts.map(String.init).joined(separator: "/"))"
            + (tier.maxOutput > 0 ? ", maximum output \(tier.maxOutput)" : "") + (tier.probe ? ", grow/bisect context probes." : ".")
            + (browserSelected ? " Browser modes skip output-cap and vision tests." : " Vision-capable selections get an image round-trip.")
    }
    private func providerRow(_ provider: JSONValue) -> some View {
        let id = provider["id"].string, included = state.selection["included"].array.contains(provider["id"]), browser = provider["transport"] == "chatgpt-web"
        return NativeSpeedProviderRow {
            HStack(spacing: 10) {
                NativeIcon(browser ? "globe" : "server", size: 13).foregroundStyle(included ? Theme.ink : Theme.muted).frame(width: 18)
                    .overlay(alignment: .bottomTrailing) { StatusDot(color: browser && !provider["ready"].bool ? Theme.warnFg : included ? Theme.okFg : Theme.muted, size: 5).offset(x: 3, y: 3) }
                VStack(alignment: .leading, spacing: 4) {
                    Text(provider["name"].string).font(Theme.ui(14, weight: .medium)).foregroundStyle(included ? Theme.ink : Theme.muted)
                    Text(browser ? "\(state.selection["models"][id].array.count) modes · " + (provider["ready"].bool ? "Ready for browser tests" : "Setup needed") : (state.selection["models"][id].array.isEmpty ? "" : "\(state.selection["models"][id].array.count) models · ") + provider["baseUrl"].string).font(Theme.ui(12.5)).foregroundStyle(Theme.muted).lineLimit(1)
                }
                Spacer()
                if browser { Text("Browser session").font(Theme.ui(11.5)).foregroundStyle(Theme.muted) }
                else {
                    NativeKeyPill(key: provider["maskedKey"].string) { Task { await state.copyKey(id) } }
                    Button { Task { if let value = await state.editable(provider) { editor = NativePresentedValue(value: value) } } } label: { NativeIcon("pencil", size: 12) }.buttonStyle(T3Button(.ghost)).help("Edit provider").accessibilityLabel("Edit provider").disabled(state.anyRunning)
                }
                Button { picker = NativePresentedValue(value: provider); if !browser && provider["catalog"].array.isEmpty { Task { await state.discover(id) } } } label: { HStack(spacing: 6) { NativeIcon("grid-2x2", size: 12); Text(browser ? "Modes" : "Models") } }.buttonStyle(T3Button()).disabled(state.anyRunning)
                T3Switch(isOn: Binding(get: { included }, set: { _ in state.toggle(id) }), enabled: !state.anyRunning && (!browser || provider["ready"].bool || included)).accessibilityLabel("Include " + provider["name"].string)
            }
            if !provider["catalogError"].isNull { Text(provider["catalogError"].string).font(Theme.ui(12)).foregroundStyle(Theme.warnFg).padding(.leading, 28) }
            NativeScrollRail {
                ForEach(state.selection["models"][id].array, id: \.self) { model in
                    ModelChip(model: model.string, color: Theme.pairColor(id + "|" + model.string)) { state.models(id, state.selection["models"][id].array.map(\.string).filter { $0 != model.string }) }.disabled(state.anyRunning)
                }
            }.padding(.leading, 28)
        }
    }
    private var progressPanel: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionLabel(text: state.progress["interrupted"].bool ? "Run interrupted" : state.progress["progress"]["aborted"].bool ? "Run stopped" : state.running ? "Run in progress" : "Run finished") {
                Text(state.progress["progress"]["run_id"].string).font(Theme.mono(11)).foregroundStyle(Theme.muted)
            }
            NativeCard {
            ForEach(state.progress["progress"]["pairs"].object.keys.sorted(), id: \.self) { key in
                let pair = state.progress["progress"]["pairs"][key]
                VStack(alignment: .leading, spacing: 5) {
                    HStack(spacing: 8) { StatusDot(color: Theme.pairColor(key), size: 7); Text(pair["model"].string).font(Theme.mono(12)); Text(pair["provider_name"].string).font(Theme.ui(12)).foregroundStyle(Theme.muted); Spacer(); NativeNumberText(text: "\(pair["done"].int)/\(pair["total"].int)", font: Theme.mono(11)) }
                    CapsuleBar(fraction: pair["total"].double > 0 ? pair["done"].double / pair["total"].double : 0, color: Theme.pairColor(key))
                    if !pair["current"].isNull { ShimmerText(text: pair["current"].string) }
                }
            }
            if state.progress["progress"]["pairs"].object.isEmpty { ShimmerText(text: "Starting the native benchmark engine…") }
            if state.progress["resumeAvailable"].bool {
                Text("Completed test units are saved. Resume keeps this run's original depth and selection.").font(Theme.ui(12)).foregroundStyle(Theme.muted)
                Button("Resume saved run") { Task { await state.resume() } }.buttonStyle(T3Button()).disabled(state.busy)
            }
            }
        }
    }
    private var freePanel: some View {
        VStack(alignment: .leading, spacing: 14) {
            SectionLabel("Free test")
            Text("One eight-token request per configured Claude route. Rate limits get one retry; entitlement refusals remain distinct from temporary limits.").font(Theme.ui(12)).foregroundStyle(Theme.muted)
            if state.free.isNull {
                if state.error.isEmpty { ShimmerText(text: "Reading the saved report and schedule…") }
            } else {
            HStack {
                if state.freeRunning { Button { Task { await state.cancel() } } label: { HStack(spacing: 6) { NativeIcon("square", size: 12); Text("Stop free test") } }.buttonStyle(T3Button(.destructive)) }
                else { Button { Task { await state.sweep() } } label: { HStack(spacing: 6) { NativeIcon("sparkles", size: 14); Text("Run free test") } }.buttonStyle(T3Button(.primary)).disabled(state.running) }
                Spacer()
                Text("\(state.free["report"]["done"].int)/\(state.free["report"]["total"].int)").font(Theme.mono(11))
            }
            SettingRow(title: "Run it automatically", desc: "Catches up after sleep; enabling begins with the next daily slot.") {
                HStack {
                    T3Field(placeholder: "04:00", text: Binding(get: { scheduleTime }, set: { scheduleTime = $0; scheduleRestored = true }), mono: true, width: 80)
                        .accessibilityLabel("Daily free-test time")
                    T3Switch(isOn: Binding(get: { state.free["schedule"]["enabled"].bool }, set: { flag in Task { await state.saveSchedule(enabled: flag, time: scheduleTime) } }))
                        .accessibilityLabel("Run free test automatically")
                    Button("Save time") { Task { await state.saveSchedule(enabled: state.free["schedule"]["enabled"].bool, time: scheduleTime) } }.buttonStyle(T3Button()).disabled(!NativeBenchmarkService.validTime(scheduleTime))
                }
            }
            let report = state.free["report"], rows = BenchmarkPresentation.freeRows(report, query: freeQuery, outcome: freeFilter)
            HStack {
                Text("\(report["rows"].array.filter { $0["outcome"] == "works" }.count) working · \(report["done"].int)/\(report["total"].int) tested" + (report["cancelled"].bool ? " · stopped early; partial results retained" : report["finishedAt"].isNull ? "" : " · completed")).font(Theme.ui(12)).foregroundStyle(Theme.muted)
                Spacer()
                if !report["finishedAt"].isNull { Text(Date(timeIntervalSince1970: report["finishedAt"].double / 1000).formatted(date: .abbreviated, time: .shortened)).font(Theme.ui(11)).foregroundStyle(Theme.muted) }
            }
            if !state.free["job"].isNull { ShimmerText(text: state.free["job"]["progress_text"].string.isEmpty ? "Starting the sweep…" : state.free["job"]["progress_text"].string) }
            Card(padding: 14) { VStack(alignment: .leading, spacing: 12) {
            HStack {
                T3Field(placeholder: "Filter by model or provider", text: $freeQuery, mono: true, leadingIcon: "search")
                Menu {
                    Button("All outcomes") { freeFilter = "all" }
                    ForEach(BenchmarkPresentation.outcomes, id: \.self) { outcome in Button(BenchmarkPresentation.outcomeLabel(outcome)) { freeFilter = outcome } }
                } label: {
                    HStack(spacing: 6) { Text(freeFilter == "all" ? "All outcomes" : BenchmarkPresentation.outcomeLabel(freeFilter)).lineLimit(1); Spacer(minLength: 0); NativeIcon("chevron-down", size: 12).foregroundStyle(Theme.muted) }
                        .font(Theme.ui(12, weight: .medium)).foregroundStyle(Theme.dim).padding(.horizontal, 11).frame(width: 180, height: 30)
                        .background(Theme.subtle, in: RoundedRectangle(cornerRadius: Theme.radiusMd))
                        .overlay { RoundedRectangle(cornerRadius: Theme.radiusMd).strokeBorder(Theme.input, lineWidth: 1) }
                }.menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
            }
            ScrollView {
                // A retained model can already contain a complete sweep. Keep
                // offscreen outcomes out of initial layout and realize them as read.
                LazyVStack(alignment: .leading, spacing: 14) {
                    ForEach(BenchmarkPresentation.outcomes, id: \.self) { outcome in
                        let group = rows.filter { $0["outcome"] == .string(outcome) }
                        if !group.isEmpty {
                            Text(BenchmarkPresentation.outcomeLabel(outcome) + " · \(group.count)").font(Theme.ui(12, weight: .semibold)).foregroundStyle(outcome == "works" ? Theme.okFg : outcome == "failed" ? Theme.failFg : Theme.muted)
                            ForEach(Array(group.enumerated()), id: \.offset) { _, row in
                                VStack(alignment: .leading, spacing: 4) {
                                    HStack(alignment: .top) { Text(row["model"].string).font(Theme.mono(11)).textSelection(.enabled); Spacer(); Text(String(format: "%.1fs", row["ms"].double / 1000)).font(Theme.mono(10)).foregroundStyle(Theme.muted) }
                                    Text(row["provider"].string + (row["message"].string.isEmpty ? "" : " · " + row["message"].string)).font(Theme.ui(11)).foregroundStyle(Theme.muted).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                                }.padding(.vertical, 4)
                            }
                        }
                    }
                    if rows.isEmpty { Text(report["rows"].array.isEmpty ? "No recorded model outcomes yet." : "No matching model or provider.").font(Theme.ui(12)).foregroundStyle(Theme.muted) }
                }.frame(maxWidth: .infinity, alignment: .leading)
            }.frame(maxHeight: 420)
            } }
            }
        }
    }
}

private struct NativeSpeedProviderRow<Content: View>: View {
    @ViewBuilder var content: () -> Content
    @State private var hovering = false
    var body: some View {
        VStack(alignment: .leading, spacing: 8) { content() }
            .padding(.horizontal, 8).padding(.vertical, 9)
            .background(hovering ? Theme.subtle : .clear, in: RoundedRectangle(cornerRadius: Theme.radiusMd))
            .onHover { hovering = $0 }
    }
}

private struct NativeSpeedProviderEditor: View {
    let provider: JSONValue
    let save: (String, String, String) async -> Bool
    @Environment(\.dismiss) private var dismiss
    @State private var name: String
    @State private var base: String
    @State private var key: String
    @State private var saving = false
    @State private var failed = false
    init(provider: JSONValue, save: @escaping (String, String, String) async -> Bool) {
        self.provider = provider; self.save = save
        _name = State(initialValue: provider["name"].string); _base = State(initialValue: provider["baseUrl"].string); _key = State(initialValue: provider["apiKey"].string)
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Edit provider").font(Theme.ui(18, weight: .semibold))
            T3Field(placeholder: "Name", text: $name)
            T3Field(placeholder: "Base URL", text: $base, mono: true)
            T3Field(placeholder: "Free API key", text: $key, mono: true)
            Text("Updates the shared provider configuration. Existing model and route settings are preserved.").font(Theme.ui(12)).foregroundStyle(Theme.muted)
            if failed { NativeError(message: "Provider could not be saved. Check the name, endpoint and key, and finish any active benchmark first.") }
            HStack {
                Button("Cancel") { dismiss() }.buttonStyle(T3Button(.outline)).keyboardShortcut(.cancelAction)
                Spacer()
                Button(saving ? "Saving…" : "Save") {
                    saving = true
                    Task { if await save(name, base, key) { dismiss() } else { failed = true }; saving = false }
                }.buttonStyle(T3Button(.primary)).disabled(saving || name.isEmpty || base.isEmpty)
            }
        }.padding(20).frame(width: 630).background(Theme.bg).foregroundStyle(Theme.ink)
    }
}

private struct NativeSpeedModelPicker: View {
    let provider: JSONValue, chosen: [String], discovering: Bool
    let change: ([String]) -> Void, refresh: () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    private var browser: Bool { provider["transport"] == "chatgpt-web" }
    private var entries: [JSONValue] { provider["catalog"].array.filter { row in query.lowercased().split(whereSeparator: \.isWhitespace).allSatisfy { term in (row["id"].string + " " + row["name"].string).lowercased().contains(term) } } }
    private var custom: String? { BenchmarkPickerPolicy.customModel(provider: provider, query: query) }

    var body: some View {
        let matching = entries
        return VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top, spacing: 10) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Pick models").font(Theme.ui(16, weight: .semibold)).frame(minHeight: 24, alignment: .leading).accessibilityAddTraits(.isHeader)
                    Text(provider["name"].string).font(Theme.ui(12)).foregroundStyle(Theme.muted).lineSpacing(4)
                        .fixedSize(horizontal: false, vertical: true).frame(minHeight: 18, alignment: .leading)
                }.frame(maxWidth: .infinity, alignment: .leading)
                HStack(spacing: 8) {
                    Button(action: refresh) {
                        HStack(spacing: 6) { NativeIcon("rotate-cw", size: 12); Text(discovering ? "Fetching…" : "Refresh") }
                    }.buttonStyle(T3Button()).disabled(discovering)
                    Button("Done") { dismiss() }.buttonStyle(T3Button(.primary)).keyboardShortcut(.cancelAction)
                    T3IconButton(system: "xmark", help: "Close model picker") { dismiss() }
                }.fixedSize(horizontal: true, vertical: false)
            }.padding(16)
            VStack(alignment: .leading, spacing: 10) {
                if !provider["catalogError"].string.isEmpty {
                    Text(provider["catalogError"].string).font(Theme.ui(12)).foregroundStyle(Theme.warnFg)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if browser {
                    Text("Only discovered ChatGPT modes can be selected. Refresh after changing the browser sign-in.")
                        .font(Theme.ui(12)).foregroundStyle(Theme.muted).fixedSize(horizontal: false, vertical: true)
                }
                T3Field(placeholder: "Search models - every word must match", text: $query, mono: true, leadingIcon: "search", autoFocus: true)
                    .onSubmit { if let custom { toggleCustom(custom) } }
                ScrollView {
                    if provider["catalog"].array.isEmpty && custom == nil {
                        VStack(spacing: 0) {
                            if discovering { ShimmerText(text: "Fetching model catalog…") }
                            else { NativeEmptyState(title: "No catalog yet", detail: browser ? "Complete ChatGPT Web setup in Switcher, then refresh the available modes." : (provider["capabilities"]["arbitraryModels"] == false ? "Refresh the catalog to fetch this provider's models." : "Refresh the catalog to fetch this provider's models, or enter a custom model ID.")) }
                        }.frame(maxWidth: .infinity).frame(height: 300)
                    } else {
                        LazyVStack(alignment: .leading, spacing: 1) {
                            if let custom {
                                choice(id: custom, label: "add \"" + custom + "\"", context: .null,
                                       available: true, reason: "", action: { toggleCustom(custom) })
                            }
                            if matching.isEmpty && custom == nil {
                                Text("No " + (browser ? "mode" : "model ID") + " matches “" + query + "”.")
                                    .font(Theme.ui(12)).foregroundStyle(Theme.muted).padding(.vertical, 24).frame(maxWidth: .infinity)
                            }
                            ForEach(Array(matching.prefix(300)), id: \.self["id"]) { entry in
                                let id = entry["id"].string, available = entry["available"] != false
                                choice(id: id, label: entry["name"].string.isEmpty ? id : entry["name"].string,
                                       context: entry["context"], available: available,
                                       reason: entry["reason"].string.isEmpty && !available ? "Unavailable" : entry["reason"].string,
                                       action: { change(BenchmarkPickerPolicy.toggling(id, in: chosen)) })
                            }
                            if matching.count > 300 {
                                Text("\(matching.count - 300) more - type to narrow the list")
                                    .font(Theme.ui(11.5)).foregroundStyle(Theme.muted).padding(.vertical, 12).frame(maxWidth: .infinity)
                            }
                        }.padding(.horizontal, 2).padding(.vertical, 4)
                    }
                }.frame(height: 300)
            }.padding(.horizontal, 16).padding(.bottom, 16)
            if !provider["catalog"].array.isEmpty || !chosen.isEmpty {
                Rectangle().fill(Theme.border).frame(height: 1)
                HStack(spacing: 8) {
                    let count = provider["catalog"].array.count
                    Text("\(count) " + (browser ? (count == 1 ? "mode" : "modes") : (count == 1 ? "model" : "models")) + " in catalog")
                        .font(Theme.ui(12)).foregroundStyle(Theme.muted)
                    Spacer(minLength: 0)
                    // Keep the native bulk actions without another outlined toolbar.
                    Button("Select matching") { change(BenchmarkPickerPolicy.selectingMatches(matching, in: chosen)) }
                        .buttonStyle(T3Button(.ghost)).disabled(matching.allSatisfy { $0["available"] == false })
                        .help("Select all available search matches, including those beyond the first300 displayed.")
                    Button("None") { change([]) }.buttonStyle(T3Button(.ghost)).disabled(chosen.isEmpty)
                    Text("\(chosen.count) selected").font(Theme.ui(12, weight: .medium)).foregroundStyle(Theme.ink)
                }.padding(.horizontal, 16).padding(.vertical, 12)
            }
        }.frame(width: 540).fixedSize(horizontal: false, vertical: true)
            .background(Theme.popover).foregroundStyle(Theme.ink)
    }
    private func toggleCustom(_ model: String) {
        change(BenchmarkPickerPolicy.toggling(model, in: chosen)); query = ""
    }
    private func choice(id: String, label: String, context: JSONValue, available: Bool,
                        reason: String, action: @escaping () -> Void) -> some View {
        NativeSpeedModelChoiceRow(id: id, label: label,
                                  context: context.isNull ? nil : (browser ? "~" : "") + NativeNumberFormat.compact(context.double) + " ctx",
                                  selected: chosen.contains(id), available: available, reason: reason, action: action)
    }
}

private struct NativeSpeedModelChoiceRow: View {
    let id: String, label: String, context: String?
    let selected: Bool, available: Bool
    let reason: String
    let action: () -> Void
    @State private var hovering = false
    @Environment(\.nativeReducedMotion) private var reduceMotion

    var body: some View {
        Button(action: action) {
            HStack(alignment: .top, spacing: 10) {
                ZStack {
                    RoundedRectangle(cornerRadius: 3).fill(selected ? Theme.accent : .clear)
                        .overlay(RoundedRectangle(cornerRadius: 3).strokeBorder(selected ? Theme.accent : Theme.muted.opacity(0.6), lineWidth: 1))
                    if selected { NativeIcon("check", size: 9, strokeWidth: 3).foregroundStyle(Theme.onAccent) }
                }.frame(width: 13, height: 13).padding(.top, 2.5).accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 3) {
                    Text(label).font(Theme.mono(12)).foregroundStyle(!available ? Theme.muted : selected ? Theme.ink : Theme.dim)
                        .lineLimit(1).truncationMode(.tail).frame(maxWidth: .infinity, minHeight: 18, alignment: .leading)
                    if !reason.isEmpty { Text(reason).font(Theme.ui(11.5)).foregroundStyle(Theme.warnFg).lineSpacing(3).fixedSize(horizontal: false, vertical: true).frame(minHeight: 17, alignment: .leading) }
                }
                if let context { MonoChip(text: context).fixedSize() }
            }.padding(.horizontal, 10).padding(.vertical, 7)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(hovering && available ? Theme.subtle2 : selected ? Theme.subtle : .clear, in: RoundedRectangle(cornerRadius: Theme.radiusSm))
                .contentShape(Rectangle())
        }.buttonStyle(NativeModelChoiceButtonStyle()).pointingHand(available).disabled(!available)
            .accessibilityLabel(label == id ? id : label + ", " + id).accessibilityHint(reason).help(id)
            .accessibilityAddTraits(selected ? [.isSelected] : [])
            .onHover { hovering = $0 && available }
            .onChange(of: available) { if !available { hovering = false } }
            .animation(reduceMotion ? nil : NativeMotion.hover, value: hovering)
    }
}
