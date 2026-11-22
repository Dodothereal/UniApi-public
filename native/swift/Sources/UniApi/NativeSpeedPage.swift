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
    @State private var tab = "bench"
    var body: some View {
        NativePage(title: "Speed", readiness: !state.error.isEmpty ? .failed : state.catalog.isNull || state.progress.isNull || state.free.isNull ? .pending : .ready, tabs: {
            NativeTabs(options: [("bench", "Benchmark"), ("free", "Free test")], selection: tab) { tab = $0 }
        }, actions: {
            T3IconButton(system: "refresh-cw", help: "Reload") { Task { await state.reload() } }
            Button { showResults = true } label: { HStack(spacing: 6) { NativeIcon("chart-bar", size: 13); Text("Results") } }.buttonStyle(T3Button(.ghost))
            if tab == "bench" {
                if state.running { Button { Task { await state.cancel() } } label: { HStack(spacing: 6) { NativeIcon("square", size: 11); Text("Stop run") } }.buttonStyle(T3Button(.destructive)) }
                else {
                    Button { Task { await state.run() } } label: {
                        HStack(spacing: 7) { NativeIcon("zap", size: 13); Text("Run " + state.selection["tier"].string); NativeNumberText(text: "\(state.pairs.count)", font: Theme.num(11, weight: .medium), color: Theme.onInk.opacity(0.62)) }
                    }.buttonStyle(T3Button(.primary)).disabled(state.busy || state.freeRunning || state.pairs.isEmpty || !state.issues.isEmpty)
                        .help(state.pairs.isEmpty ? "Include a provider and pick models first" : "Benchmark \(state.pairs.count) models")
                }
            } else if !state.free.isNull {
                if state.freeRunning { Button { Task { await state.cancel() } } label: { HStack(spacing: 6) { NativeIcon("square", size: 11); Text("Stop free test") } }.buttonStyle(T3Button(.destructive)) }
                else { Button { Task { await state.sweep() } } label: { HStack(spacing: 6) { NativeIcon("sparkles", size: 13); Text("Run free test") } }.buttonStyle(T3Button(.primary)).disabled(state.running || state.catalog["providers"].array.isEmpty) }
            }
        }) {
            if !state.error.isEmpty { NativeError(message: state.error) }
            if tab == "bench" {
                ForEach(state.issues, id: \.self) { NativeError(message: $0) }
                NativeSheet {
                    if state.running || state.progress["progress"]["done"].bool || state.progress["interrupted"].bool || !state.progress["job"]["log"].array.isEmpty || state.progress["job"]["status"] == "failed" { progressPanel }
                    NativeSection("Depth") {
                        VStack(alignment: .leading, spacing: 14) {
                            T3Segmented(options: [("quick", "Quick"), ("standard", "Standard"), ("deep", "Deep")], selection: state.selection["tier"].string, enabled: !state.anyRunning) { state.tier($0) }
                            tierSpec
                            if browserSelected { Text(BenchmarkMath.browserNote).font(Theme.ui(12)).foregroundStyle(Theme.muted).fixedSize(horizontal: false, vertical: true) }
                        }
                    }
                    NativeSection("Providers", detail: state.catalog.isNull ? "" : "\(state.pairs.count) models selected. Providers run in parallel, models within one in sequence.") {
                        if state.catalog.isNull { ShimmerText(text: "Reading provider configuration…") }
                        else if state.catalog["providers"].array.isEmpty {
                            NativeEmptyState(title: "No providers yet", detail: "Add a provider in Switcher, then return here to choose models.",
                                             actionTitle: "Add provider in Switcher") {
                                NotificationCenter.default.post(name: .nativeNavigation, object: NativeDestination.switcher)
                            }
                        } else {
                            NativeStack { ForEach(state.catalog["providers"].array, id: \.self["id"]) { provider in providerRow(provider) } }
                        }
                    }
                }
            } else {
                freePanel
            }
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
    /// What the chosen depth measures, as figures rather than a sentence. The
    /// cells keep their place between depths so only the numbers change.
    @ViewBuilder private var tierSpec: some View {
        if let tier = BenchmarkTier.configurations[state.selection["tier"].string] {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 20, alignment: .topLeading)], alignment: .leading, spacing: 12) {
                spec("Latency", "\(tier.latency)", "samples")
                spec("Output", "\(tier.throughput) × \(nativeBenchTokens(Double(tier.output)))", "tokens")
                spec("Input sweep", tier.contexts.map { nativeBenchTokens(Double($0)) }.joined(separator: " · "), "")
                spec("Output cap", tier.maxOutput > 0 && !browserSelected ? nativeBenchTokens(Double(tier.maxOutput)) : "Off", "")
                spec("Context probe", tier.probe ? "Grow, bisect" : "Off", "")
                spec("Vision", browserSelected ? "Off" : "Round trip", "")
            }.accessibilityElement(children: .ignore).accessibilityLabel(description)
        }
    }
    private func spec(_ label: String, _ value: String, _ unit: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label).font(Theme.ui(11)).foregroundStyle(Theme.muted)
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                NativeNumberText(text: value, font: Theme.num(13, weight: .medium), color: value == "Off" ? Theme.faint : Theme.ink)
                if !unit.isEmpty { Text(unit).font(Theme.ui(11)).foregroundStyle(Theme.muted) }
            }
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
    private func providerRow(_ provider: JSONValue) -> some View {
        let id = provider["id"].string, included = state.selection["included"].array.contains(provider["id"]), browser = provider["transport"] == "chatgpt-web"
        let chosen = state.selection["models"][id].array
        return NativeSpeedProviderRow { hovering in
            HStack(spacing: 12) {
                T3Switch(isOn: Binding(get: { included }, set: { _ in state.toggle(id) }), enabled: !state.anyRunning && (!browser || provider["ready"].bool || included)).accessibilityLabel("Include " + provider["name"].string)
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 7) {
                        Text(provider["name"].string).font(Theme.ui(Theme.textSm, weight: .medium)).foregroundStyle(included ? Theme.ink : Theme.muted).lineLimit(1)
                        if browser && !provider["ready"].bool { NativeStatus(text: "Setup needed", tone: .warn) }
                    }
                    Text(browser ? "Browser session" : provider["baseUrl"].string).font(browser ? Theme.ui(12) : Theme.mono(11)).foregroundStyle(Theme.muted).lineLimit(1).truncationMode(.middle)
                }
                Spacer(minLength: 8)
                if !browser {
                    NativeKeyPill(key: provider["maskedKey"].string) { Task { await state.copyKey(id) } }
                    T3IconButton(system: "pencil", help: "Edit provider", size: 13) { Task { if let value = await state.editable(provider) { editor = NativePresentedValue(value: value) } } }
                        .disabled(state.anyRunning).opacity(hovering ? 1 : 0.55)
                }
                Button { picker = NativePresentedValue(value: provider); if !browser && provider["catalog"].array.isEmpty { Task { await state.discover(id) } } } label: {
                    HStack(spacing: 6) { NativeIcon("plus", size: 12); Text(browser ? "Modes" : "Models"); if !chosen.isEmpty { Text("\(chosen.count)").font(Theme.num(11, weight: .medium)).foregroundStyle(Theme.muted) } }
                }.buttonStyle(T3Button()).disabled(state.anyRunning)
            }
            if !provider["catalogError"].isNull { Text(provider["catalogError"].string).font(Theme.ui(12)).foregroundStyle(Theme.warnFg).padding(.leading, 48) }
            if !chosen.isEmpty {
                NativeScrollRail {
                    ForEach(chosen, id: \.self) { model in
                        ModelChip(model: model.string, color: Theme.pairColor(id + "|" + model.string)) { state.models(id, chosen.map(\.string).filter { $0 != model.string }) }.disabled(state.anyRunning)
                    }
                }.padding(.leading, 48).opacity(included ? 1 : 0.55)
            }
        }
    }
    private var runTitle: String { state.progress["interrupted"].bool ? "Interrupted" : state.progress["progress"]["aborted"].bool ? "Stopped" : state.running ? "Running" : state.progress["job"]["status"] == "failed" ? "Failed" : "Last run" }
    private var progressPanel: some View {
        let pairs = state.progress["progress"]["pairs"]
        return NativeSection(runTitle, detail: state.progress["progress"]["run_id"].string) {
            VStack(alignment: .leading, spacing: 14) {
                if state.progress["job"]["status"] == "failed" { NativeError(message: state.progress["job"]["error"].string) }
                if !pairs.object.isEmpty {
                    NativeStack {
                        ForEach(pairs.object.keys.sorted(), id: \.self) { key in
                            let pair = pairs[key], fraction = pair["total"].double > 0 ? pair["done"].double / pair["total"].double : 0
                            VStack(alignment: .leading, spacing: 7) {
                                HStack(spacing: 8) {
                                    RoundedRectangle(cornerRadius: 1).fill(Theme.pairColor(key)).frame(width: 3, height: 12)
                                    Text(pair["model"].string).font(Theme.mono(12)).lineLimit(1)
                                    Text(pair["provider_name"].string).font(Theme.ui(12)).foregroundStyle(Theme.muted).lineLimit(1)
                                    Spacer(minLength: 8)
                                    if !pair["current"].isNull { ShimmerText(text: pair["current"].string).lineLimit(1) }
                                    NativeNumberText(text: "\(pair["done"].int)/\(pair["total"].int)", font: Theme.num(12, weight: .medium))
                                }
                                NativeTickMeter(fraction: fraction, color: Theme.pairColor(key), height: 8)
                            }.padding(.vertical, 10)
                        }
                    }
                } else if state.running { ShimmerText(text: "Starting…") }
                if state.progress["resumeAvailable"].bool {
                    HStack(spacing: 12) {
                        Button("Resume") { Task { await state.resume() } }.buttonStyle(T3Button()).disabled(state.busy)
                        Text("Finished units are saved. Depth and selection stay as they were.").font(Theme.ui(12)).foregroundStyle(Theme.muted)
                    }
                }
                if !state.progress["job"]["log"].array.isEmpty {
                    NativeDisclosure("Log") {
                        ScrollView { Text(state.progress["job"]["log"].array.map(\.string).joined(separator: "\n")).font(Theme.mono(11)).foregroundStyle(Theme.dim).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading).padding(12) }
                            .frame(maxHeight: 240).background(Theme.sunken, in: RoundedRectangle(cornerRadius: Theme.radiusMd, style: .continuous))
                    }
                }
            }
        }
    }
    @ViewBuilder private var freePanel: some View {
        if state.free.isNull {
            if state.error.isEmpty { ShimmerText(text: "Reading the saved report…") }
        } else {
            let report = state.free["report"], rows = BenchmarkPresentation.freeRows(report, query: freeQuery, outcome: freeFilter)
            let working = report["rows"].array.filter { $0["outcome"] == "works" }.count
            NativeReadoutStrip {
                NativeReadout(label: "Working", value: "\(working)", detail: "One eight-token request per Claude route", tone: working > 0 ? Theme.okFg : Theme.ink)
                NativeReadout(label: "Tested", value: "\(report["done"].int)", unit: "of \(report["total"].int)",
                              detail: !state.free["job"].isNull ? (state.free["job"]["progress_text"].string.isEmpty ? "Starting…" : state.free["job"]["progress_text"].string) : report["cancelled"].bool ? "Stopped early, partial results kept" : report["finishedAt"].isNull ? "" : Date(timeIntervalSince1970: report["finishedAt"].double / 1000).formatted(date: .abbreviated, time: .shortened),
                              meter: report["total"].double > 0 ? report["done"].double / report["total"].double : nil, meterColor: state.freeRunning ? Theme.accent : Theme.ink)
                VStack(alignment: .leading, spacing: 9) {
                    Text("Daily").font(Theme.ui(12)).foregroundStyle(Theme.muted)
                    HStack(spacing: 8) {
                        T3Switch(isOn: Binding(get: { state.free["schedule"]["enabled"].bool }, set: { flag in Task { await state.saveSchedule(enabled: flag, time: scheduleTime) } }))
                            .accessibilityLabel("Run free test automatically")
                        T3Field(placeholder: "04:00", text: Binding(get: { scheduleTime }, set: { scheduleTime = $0; scheduleRestored = true }), mono: true, width: 72)
                            .accessibilityLabel("Daily free-test time")
                        if scheduleTime != state.free["schedule"]["time"].string {
                            Button("Save") { Task { await state.saveSchedule(enabled: state.free["schedule"]["enabled"].bool, time: scheduleTime) } }.buttonStyle(T3Button()).disabled(!NativeBenchmarkService.validTime(scheduleTime))
                                .transition(.opacity)
                        }
                    }
                    Text("Catches up after sleep.").font(Theme.ui(11)).foregroundStyle(Theme.muted)
                }
            }
            HStack(spacing: 8) {
                T3Field(placeholder: "Filter by model or provider", text: $freeQuery, mono: true, leadingIcon: "search")
                NativeMenuSelect(title: "Outcome", selection: $freeFilter, options: [("all", "All outcomes")] + BenchmarkPresentation.outcomes.map { ($0, BenchmarkPresentation.outcomeLabel($0)) }, width: 180)
            }
            if rows.isEmpty {
                Text(report["rows"].array.isEmpty ? "No recorded outcomes." : "No matching model or provider.").font(Theme.ui(12)).foregroundStyle(Theme.muted)
            } else {
                // A retained model can already contain a complete sweep. Keep
                // offscreen outcomes out of initial layout and realize them as read.
                LazyVStack(alignment: .leading, spacing: 0, pinnedViews: []) {
                    ForEach(BenchmarkPresentation.outcomes, id: \.self) { outcome in
                        let group = rows.filter { $0["outcome"] == .string(outcome) }
                        if !group.isEmpty {
                            HStack(spacing: 8) {
                                NativeStatus(text: BenchmarkPresentation.outcomeLabel(outcome), tone: outcome == "works" ? .ok : outcome == "failed" ? .fail : .idle)
                                Text("\(group.count)").font(Theme.num(11, weight: .medium)).foregroundStyle(Theme.muted)
                            }.padding(.top, 18).padding(.bottom, 8)
                            ForEach(Array(group.enumerated()), id: \.offset) { _, row in
                                Theme.rule.frame(height: 1)
                                HStack(alignment: .firstTextBaseline, spacing: 12) {
                                    Text(row["model"].string).font(Theme.mono(12)).textSelection(.enabled).lineLimit(1).frame(minWidth: 180, maxWidth: 300, alignment: .leading)
                                    Text(row["provider"].string).font(Theme.ui(12)).foregroundStyle(Theme.dim).lineLimit(1).frame(width: 130, alignment: .leading)
                                    Text(row["message"].string).font(Theme.ui(12)).foregroundStyle(Theme.muted).textSelection(.enabled).lineLimit(2).frame(maxWidth: .infinity, alignment: .leading)
                                    Text(String(format: "%.1f s", row["ms"].double / 1000)).font(Theme.num(12, weight: .regular)).foregroundStyle(Theme.muted)
                                }.padding(.vertical, 8)
                            }
                        }
                    }
                }
            }
        }
    }
}

private struct NativeSpeedProviderRow<Content: View>: View {
    @ViewBuilder var content: (Bool) -> Content
    @State private var hovering = false
    var body: some View {
        VStack(alignment: .leading, spacing: 9) { content(hovering) }
            .padding(.vertical, 12).contentShape(Rectangle())
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
