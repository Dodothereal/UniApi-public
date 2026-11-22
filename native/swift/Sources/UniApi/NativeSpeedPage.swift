import SwiftUI
import AppKit
import UniApiCore
import UniApiPresentation

/// Arming an instrument: the selection is the reading, Start run is the one
/// action, and a started run turns the head of the page into a live meter.
struct NativeSpeedPage: View {
    let runtime: NativeRuntime
    @StateObject private var state: NativeSpeedModel
    @State private var readOwner = UUID()
    @State private var picker: NativePresentedValue?
    @State private var scheduleTime = "04:00"
    @State private var scheduleRestored = false
    @State private var freeFilter = "all"
    @State private var freeQuery = ""
    @State private var editor: NativePresentedValue?
    @State private var showPairs = false
    @State private var showLog = false
    @State private var showReport = false
    @Environment(\.nativeReducedMotion) private var reduceMotion
    init(runtime: NativeRuntime, model: NativeSpeedModel? = nil) { self.runtime = runtime; _state = StateObject(wrappedValue: model ?? NativeSpeedModel(runtime: runtime)) }

    private var providers: [JSONValue] { state.catalog["providers"].array }
    private var browserSelected: Bool { providers.contains { $0["transport"] == "chatgpt-web" && state.selection["included"].array.contains($0["id"]) } }
    private var tierName: String { state.selection["tier"].string }
    private var hasRun: Bool { state.running || state.progress["progress"]["done"].bool || state.progress["interrupted"].bool }
    private var log: [JSONValue] { state.progress["job"]["log"].array }
    private var readiness: NativePageReadiness {
        !state.error.isEmpty ? .failed : state.catalog.isNull || state.progress.isNull || state.free.isNull ? .pending : .ready
    }

    var body: some View {
        NativePage(title: "Speed", eyebrow: "Benchmark", readiness: readiness, actions: { headerActions }) {
            if !state.error.isEmpty { failure(state.error) }
            if state.running { liveHead } else { armedHead }
            ForEach(state.issues, id: \.self) { failure($0) }
            if browserSelected { Notice(text: BenchmarkMath.browserNote) }
            if hasRun || !log.isEmpty { runBand }
            providersBand
            freeBand
        }
        .nativePageTask {
            await state.begin(runtime: runtime, owner: readOwner)
            if !Task.isCancelled, !scheduleRestored, !state.free["schedule"].isNull {
                scheduleTime = state.free["schedule"]["time"].string; scheduleRestored = true
            }
        }
        .nativePageActivity(suspended: { state.stopListening(owner: readOwner) })
        .sheet(item: $picker) { item in
            NativeSpeedModelPicker(provider: providers.first { $0["id"] == item.value["id"] } ?? item.value,
                                   chosen: state.selection["models"][item.value["id"].string].array.map(\.string),
                                   discovering: state.discovering.contains(item.value["id"].string),
                                   change: { state.models(item.value["id"].string, $0) },
                                   refresh: { Task { await state.discover(item.value["id"].string) } })
        }
        .sheet(item: $editor) { item in NativeSpeedProviderEditor(provider: item.value, save: { name, base, key in await state.update(item.value, name: name, base: base, key: key) }) }
    }

    private func failure(_ message: String) -> some View {
        Notice(text: message, tone: .fail).accessibilityLabel("Error: " + message)
    }
    private func fold(_ flag: Binding<Bool>) -> Binding<Bool> {
        Binding(get: { flag.wrappedValue }, set: { open in
            if reduceMotion { flag.wrappedValue = open } else { withAnimation(.easeOut(duration: 0.18)) { flag.wrappedValue = open } }
        })
    }

    // ------------------------------------------------------------------
    // Header
    // ------------------------------------------------------------------

    @ViewBuilder private var headerActions: some View {
        IconPress(icon: "rotate-cw", help: "Reload") { Task { await state.reload() } }
        Button("Results", nativeIcon: "chart-bar") {
            NotificationCenter.default.post(name: .nativeNavigation, object: NativeDestination.results)
        }.buttonStyle(Press(.secondary))
        if state.running {
            Button("Stop run", nativeIcon: "square") { Task { await state.cancel() } }.buttonStyle(Press(.danger))
        } else {
            Button("Start " + tierName + " run", nativeIcon: "play") { Task { await state.run() } }
                .buttonStyle(Press(.primary))
                .disabled(state.busy || state.freeRunning || state.pairs.isEmpty || !state.issues.isEmpty)
        }
    }

    // ------------------------------------------------------------------
    // Armed: the selection is the reading
    // ------------------------------------------------------------------

    private var armedDetail: String {
        if state.catalog.isNull { return "Reading provider configuration" }
        if state.pairs.isEmpty { return providers.isEmpty ? "No provider is configured yet" : "Switch a provider on and pick its models below" }
        let armed = Set(state.pairs.map { $0["provider"].string }).count
        return armed == 1 ? "One provider, its models in turn" : "\(armed) providers in parallel, each one's models in turn"
    }
    private var armedGroups: [[String]] {
        state.selection["included"].array.map { id in state.selection["models"][id.string].array.map { id.string + "|" + $0.string } }.filter { !$0.isEmpty }
    }
    private var armedReading: some View {
        VStack(alignment: .leading, spacing: 4) {
            MicroLabel("Armed")
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                NativeNumberText(text: "\(state.pairs.count)", font: Theme.readout(54), color: state.pairs.isEmpty ? Theme.faint : Theme.ink)
                MicroLabel(state.pairs.count == 1 ? "pair" : "pairs", size: 11)
            }
            if !state.pairs.isEmpty && state.pairs.count <= 120 { SpeedArmedTicks(groups: armedGroups).padding(.top, 2).padding(.bottom, 6) }
            Text(armedDetail).font(Theme.ui(12.5)).foregroundStyle(Theme.muted).lineLimit(1)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Armed").accessibilityValue("\(state.pairs.count) pairs. " + armedDetail)
    }
    private var depthControl: some View {
        VStack(alignment: .leading, spacing: 6) {
            MicroLabel("Depth")
            Stops(options: [("quick", "Quick"), ("standard", "Standard"), ("deep", "Deep")], selection: tierName, enabled: !state.anyRunning) { state.tier($0) }
        }
    }
    private var armedHead: some View {
        VStack(alignment: .leading, spacing: 24) {
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .bottom, spacing: 32) { armedReading; Spacer(minLength: 0); depthControl }
                VStack(alignment: .leading, spacing: 18) { armedReading; depthControl }
            }
            if let tier = BenchmarkTier.configurations[tierName] { SpeedDepthStrip(tier: tier, browser: browserSelected) }
        }
    }

    // ------------------------------------------------------------------
    // Running: the page head is a live meter
    // ------------------------------------------------------------------

    private var runPairs: [SpeedRunPair] {
        let progress = state.progress["progress"], reported = progress["pairs"].object, job = state.progress["job"]
        var keys: [String] = []
        if job["params"]["run_id"] == progress["run_id"] {
            keys = job["params"]["pairs"].array.map { $0["provider"].string + "|" + $0["model"].string }
        }
        for key in reported.keys.sorted() where !keys.contains(key) { keys.append(key) }
        return keys.map { key in
            if let pair = reported[key] {
                return SpeedRunPair(id: key, model: pair["model"].string, provider: pair["provider_name"].string,
                                    done: pair["done"].int, total: pair["total"].int,
                                    current: pair["current"].isNull ? nil : pair["current"].string, reported: true)
            }
            let parts = key.split(separator: "|", maxSplits: 1).map(String.init)
            let name = providers.first { $0["id"].string == parts.first }?["name"].string ?? parts.first ?? ""
            return SpeedRunPair(id: key, model: parts.count > 1 ? parts[1] : key, provider: name, done: 0, total: 0, current: nil, reported: false)
        }
    }
    private var liveHead: some View {
        let pairs = runPairs, fraction = SpeedRunPair.fraction(pairs)
        let finished = pairs.filter(\.finished).count, tests = pairs.reduce(0) { $0 + $1.done }
        let queued = state.progress["job"]["status"] == "queued" || pairs.allSatisfy { !$0.reported }
        let tier = state.progress["progress"]["tier"].string
        return VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .bottom, spacing: 32) {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 7) {
                        NativeStatusDot(color: Theme.signal, size: 6, pulse: true)
                        MicroLabel(queued ? "Starting" : tier.isEmpty ? "Running" : "Running " + tier, color: Theme.ink)
                    }
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        NativeNumberText(text: String(Int((fraction * 100).rounded(.down))), font: Theme.readout(54))
                        MicroLabel("percent", size: 11)
                    }
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Run progress").accessibilityValue("\(Int((fraction * 100).rounded(.down))) percent")
                Spacer(minLength: 0)
                Readout(label: "Pairs done", value: "\(finished)", unit: "of \(pairs.count)", size: .medium, ruled: false)
                    .frame(width: 124)
                Readout(label: "Tests done", value: "\(tests)", size: .medium, ruled: false).frame(width: 96)
            }
            BenchMeter(fraction: fraction, live: true, divisions: SpeedRunPair.divisions(pairs.count))
            Text(state.progress["progress"]["run_id"].string.isEmpty ? "Starting the benchmark engine" : state.progress["progress"]["run_id"].string)
                .font(Theme.mono(10.5)).foregroundStyle(Theme.muted).lineLimit(1).textSelection(.enabled)
        }
    }

    // ------------------------------------------------------------------
    // The run: pairs completing, the last result, the log
    // ------------------------------------------------------------------

    private var runState: (title: String, tag: String, tone: Color) {
        if state.progress["job"]["status"] == "failed" { return ("Run failed", "failed", Theme.failFg) }
        if state.progress["interrupted"].bool { return ("Run interrupted", "interrupted", Theme.warnFg) }
        if state.progress["progress"]["aborted"].bool { return ("Run stopped", "stopped", Theme.warnFg) }
        return ("Last run", "finished", Theme.okFg)
    }
    private var runBand: some View {
        let pairs = runPairs
        return Band(title: state.running ? "Pairs" : runState.title, spacing: 0) {
            HStack(spacing: 2) {
                if !log.isEmpty { BenchDisclosure(title: "Log", detail: "\(log.count)", open: fold($showLog)) }
                if !state.running && !pairs.isEmpty { BenchDisclosure(title: "Pairs", detail: "\(pairs.count)", open: fold($showPairs)) }
            }
        } content: {
            if state.progress["job"]["status"] == "failed" { failure(state.progress["job"]["error"].string).padding(.top, 10) }
            if !state.running && hasRun { runSummary(pairs) }
            if (state.running || showPairs) && !pairs.isEmpty { SpeedPairLedger(pairs: pairs, running: state.running) }
            if state.running && pairs.isEmpty {
                Text("Starting the benchmark engine").font(Theme.ui(12.5)).foregroundStyle(Theme.muted).padding(.vertical, 20)
            }
            if showLog && !log.isEmpty {
                Well(padding: 12) {
                    ScrollView {
                        Text(log.map(\.string).joined(separator: "\n")).font(Theme.mono(11)).foregroundStyle(Theme.dim)
                            .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                    }.frame(maxHeight: 240)
                }.padding(.top, 12)
            }
        }
    }
    private func runSummary(_ pairs: [SpeedRunPair]) -> some View {
        let fraction = SpeedRunPair.fraction(pairs), tests = pairs.reduce(0) { $0 + $1.done }
        let finished = pairs.filter(\.finished).count, clean = runState.tag == "finished"
        return VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                Tag(runState.tag, tone: runState.tone, dot: true)
                Text(state.progress["progress"]["run_id"].string).font(Theme.mono(11.5)).foregroundStyle(Theme.dim)
                    .lineLimit(1).truncationMode(.middle).textSelection(.enabled)
                Spacer(minLength: 8)
                Text("\(finished) of \(pairs.count) pairs").font(Theme.mono(11)).foregroundStyle(Theme.muted).lineLimit(1)
                Text(tests == 1 ? "1 test" : "\(tests) tests").font(Theme.mono(11)).foregroundStyle(Theme.muted).lineLimit(1)
                if state.progress["resumeAvailable"].bool {
                    Button("Resume saved run", nativeIcon: "play") { Task { await state.resume() } }
                        .buttonStyle(Press(.secondary)).disabled(state.busy)
                        .help("Completed test units are saved. Resume keeps this run's original depth and selection.")
                }
            }
            .frame(minHeight: 36)
            if !clean { BenchMeter(fraction: fraction, color: runState.tone, divisions: SpeedRunPair.divisions(pairs.count)) }
            if state.progress["resumeAvailable"].bool {
                Text("Completed tests are saved. Resume keeps the original depth and selection.")
                    .font(Theme.ui(11.5)).foregroundStyle(Theme.muted)
            }
        }
        .padding(.bottom, clean ? 0 : 10)
        .overlay(alignment: .bottom) { Rule() }
    }

    // ------------------------------------------------------------------
    // Providers
    // ------------------------------------------------------------------

    private var providersBand: some View {
        Band(title: "Providers", spacing: 0) {
            Text(state.catalog.isNull ? "Reading" : "\(providers.count) configured").font(Theme.ui(11.5)).foregroundStyle(Theme.muted)
        } content: {
            if state.catalog.isNull {
                if state.error.isEmpty { Text("Reading provider configuration").font(Theme.ui(12.5)).foregroundStyle(Theme.muted).padding(.vertical, 20) }
            } else if providers.isEmpty {
                LedgerHead { SpeedProviderRow.heads }
                Blank(icon: "server", title: "No providers yet", detail: "Add a provider in Switcher, then return here to choose models.",
                      actionTitle: "Add provider in Switcher", primary: false) {
                    NotificationCenter.default.post(name: .nativeNavigation, object: NativeDestination.switcher)
                }
            } else {
                LedgerHead { SpeedProviderRow.heads }
                ForEach(providers, id: \.self["id"]) { provider in providerRow(provider) }
            }
        }
    }
    private func providerRow(_ provider: JSONValue) -> some View {
        let id = provider["id"].string, browser = provider["transport"] == "chatgpt-web"
        let included = state.selection["included"].array.contains(provider["id"])
        let models = state.selection["models"][id].array.map(\.string)
        return SpeedProviderRow(provider: provider, included: included, models: models, locked: state.anyRunning,
            toggle: { state.toggle(id) },
            pick: { picker = NativePresentedValue(value: provider); if !browser && provider["catalog"].array.isEmpty { Task { await state.discover(id) } } },
            edit: { Task { if let value = await state.editable(provider) { editor = NativePresentedValue(value: value) } } },
            copyKey: { Task { await state.copyKey(id) } },
            remove: { model in state.models(id, models.filter { $0 != model }) })
    }

    // ------------------------------------------------------------------
    // Free test
    // ------------------------------------------------------------------

    private var freeBand: some View {
        Band(title: "Free test", spacing: 0) {
            if state.freeRunning {
                Button("Stop free test", nativeIcon: "square") { Task { await state.cancel() } }.buttonStyle(Press(.danger))
            } else {
                Button("Run free test", nativeIcon: "sparkles") { Task { await state.sweep() } }
                    .buttonStyle(Press(.secondary)).disabled(state.running || providers.isEmpty || state.free.isNull)
                    .help("One eight-token request per configured Claude route. Rate limits get one retry; entitlement refusals remain distinct from temporary limits.")
            }
        } content: {
            if state.free.isNull {
                if state.error.isEmpty { Text("Reading the saved report and schedule").font(Theme.ui(12.5)).foregroundStyle(Theme.muted).padding(.vertical, 20) }
            } else {
                freeContent
            }
        }
    }
    @ViewBuilder private var freeContent: some View {
        let report = state.free["report"], all = report["rows"].array
        let working = all.filter { $0["outcome"] == "works" }.count
        let stamp = report["finishedAt"].isNull ? "" : Date(timeIntervalSince1970: report["finishedAt"].double / 1000).formatted(date: .abbreviated, time: .shortened)
        ReadoutStrip(minimum: 150) {
            Readout(label: "Working", value: report.isNull ? "--" : "\(working)", unit: working == 1 ? "route" : "routes", size: .medium,
                    tint: working > 0 ? Theme.ok : nil, color: report.isNull ? Theme.faint : Theme.ink)
            Readout(label: "Tested", value: report.isNull ? "--" : "\(report["done"].int)", unit: report.isNull ? "" : "of \(report["total"].int)", size: .medium,
                    color: report.isNull ? Theme.faint : Theme.ink)
            Readout(label: "Last sweep", value: report.isNull ? "never" : report["cancelled"].bool ? "stopped" : report["finishedAt"].isNull ? "running" : "complete",
                    detail: report["cancelled"].bool ? "Stopped early; partial results kept" : stamp, size: .medium,
                    color: report.isNull ? Theme.faint : Theme.ink)
        }
        .padding(.top, 14).padding(.bottom, 18)
        if !state.free["job"].isNull {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 7) {
                    NativeStatusDot(color: Theme.signal, size: 6, pulse: true)
                    Text(state.free["job"]["progress_text"].string.isEmpty ? "Starting the sweep" : state.free["job"]["progress_text"].string)
                        .font(Theme.mono(11)).foregroundStyle(Theme.dim).lineLimit(1)
                }
                BenchMeter(fraction: report["total"].double > 0 ? report["done"].double / report["total"].double : 0, live: true)
            }.padding(.bottom, 14)
        }
        Rule()
        OptionRow(title: "Run it every day", detail: "Catches up after sleep; switching it on starts with the next daily slot.") {
            HStack(spacing: 8) {
                Entry(placeholder: "04:00", text: Binding(get: { scheduleTime }, set: { scheduleTime = $0; scheduleRestored = true }), mono: true, width: 72)
                    .accessibilityLabel("Daily free-test time")
                Button("Save time") { Task { await state.saveSchedule(enabled: state.free["schedule"]["enabled"].bool, time: scheduleTime) } }
                    .buttonStyle(Press(.secondary)).disabled(!NativeBenchmarkService.validTime(scheduleTime))
                Flip(isOn: Binding(get: { state.free["schedule"]["enabled"].bool }, set: { flag in Task { await state.saveSchedule(enabled: flag, time: scheduleTime) } }))
                    .accessibilityLabel("Run free test automatically")
            }
        }
        HStack(spacing: 12) {
            Text("Report").font(Theme.ui(13, weight: .medium)).foregroundStyle(Theme.ink)
            Text(all.isEmpty ? "No recorded model outcomes yet" : "\(all.count) recorded " + (all.count == 1 ? "outcome" : "outcomes"))
                .font(Theme.ui(12.5)).foregroundStyle(Theme.muted).lineLimit(1)
            Spacer(minLength: 8)
            if !all.isEmpty { BenchDisclosure(title: showReport ? "Hide" : "Show", open: fold($showReport)) }
        }
        .frame(minHeight: 44).overlay(alignment: .bottom) { Rule() }
        if showReport && !all.isEmpty {
            SpeedFreeReport(report: report, query: $freeQuery, filter: $freeFilter)
        }
    }
}

// ======================================================================
// MARK: - Depth
// ======================================================================

/// What the chosen depth measures, as readings instead of a sentence. The
/// numerals roll when the depth changes.
private struct SpeedDepthStrip: View {
    let tier: BenchmarkTier
    let browser: Bool
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ReadoutStrip(minimum: 132) {
                Readout(label: "Latency", value: "\(tier.latency)", unit: tier.latency == 1 ? "sample" : "samples", size: .medium)
                Readout(label: "Output", value: "\(tier.output)", unit: "tokens",
                        detail: tier.throughput == 1 ? "One speed test" : "\(tier.throughput) speed tests", size: .medium)
                Readout(label: "Input sweep", value: "\(tier.contexts.count)", unit: "sizes",
                        detail: (tier.contexts.first.map { nativeBenchTokens(Double($0)) } ?? "-") + " to " + (tier.contexts.last.map { nativeBenchTokens(Double($0)) } ?? "-") + " tokens", size: .medium)
                Readout(label: "Longest answer", value: tier.maxOutput > 0 ? "\(tier.maxOutput)" : "off", unit: tier.maxOutput > 0 ? "tokens" : "",
                        detail: tier.maxOutput > 0 ? "Output cap test" : "Not at this depth", size: .medium,
                        color: tier.maxOutput > 0 ? Theme.ink : Theme.faint)
                Readout(label: "Context probe", value: tier.probe ? "on" : "off", detail: tier.probe ? "Grow, then bisect" : "Not at this depth",
                        size: .medium, color: tier.probe ? Theme.ink : Theme.faint)
            }
            Text(browser ? "Browser modes skip the output cap and vision tests." : "Vision-capable models also get an image round-trip.")
                .font(Theme.ui(11.5)).foregroundStyle(Theme.muted)
        }
    }
}

/// The armed selection as a ruler: one tick per pair in the color it keeps on
/// Results, grouped by provider.
private struct SpeedArmedTicks: View {
    let groups: [[String]]
    @Environment(\.nativeReducedMotion) private var reduceMotion
    var body: some View {
        HStack(spacing: 8) {
            ForEach(Array(groups.enumerated()), id: \.offset) { _, group in
                HStack(spacing: 3) {
                    ForEach(group, id: \.self) { pair in Theme.pairColor(pair).frame(width: 2, height: 10) }
                }
            }
        }
        .frame(height: 10)
        .animation(reduceMotion ? nil : NativeMotion.toggle, value: groups)
        .accessibilityHidden(true)
    }
}

// ======================================================================
// MARK: - Run ledger
// ======================================================================

private struct SpeedRunPair: Identifiable {
    let id: String, model: String, provider: String
    let done: Int, total: Int
    let current: String?
    let reported: Bool
    var finished: Bool { total > 0 && done >= total }
    var fraction: Double { total > 0 ? min(1, Double(done) / Double(total)) : 0 }
    /// Every armed pair weighs the same, so the meter cannot run backwards
    /// when a provider reaches its next model.
    static func fraction(_ pairs: [SpeedRunPair]) -> Double {
        pairs.isEmpty ? 0 : pairs.reduce(0) { $0 + $1.fraction } / Double(pairs.count)
    }
    static func divisions(_ count: Int) -> Int { count >= 2 && count <= 60 ? count : 20 }
}

private struct SpeedPairLedger: View {
    let pairs: [SpeedRunPair]
    let running: Bool
    var body: some View {
        // One decision for the whole ledger, so every row keeps the same columns.
        ViewThatFits(in: .horizontal) {
            ledger(wide: true)
            ledger(wide: false)
        }
    }
    private func ledger(wide: Bool) -> some View {
        let nowWidth: CGFloat = wide ? 208 : 96, barWidth: CGFloat = wide ? 108 : 84
        return VStack(spacing: 0) {
            LedgerHead {
                MicroLabel("Model").frame(idealWidth: wide ? 280 : 120, maxWidth: .infinity, alignment: .leading)
                MicroLabel("Now").frame(width: nowWidth, alignment: .leading)
                MicroLabel("Progress").frame(width: barWidth, alignment: .leading)
                MicroLabel("Tests").frame(width: 48, alignment: .trailing)
            }
            ForEach(pairs) { pair in
                LedgerRow(minHeight: 36) {
                    HStack(spacing: 12) {
                        HStack(spacing: 9) {
                            Theme.pairColor(pair.id).frame(width: 2, height: 12)
                            Text(pair.model).font(Theme.mono(12)).foregroundStyle(pair.reported ? Theme.ink : Theme.muted).lineLimit(1).truncationMode(.middle)
                            if wide { Text(pair.provider).font(Theme.ui(11.5)).foregroundStyle(Theme.muted).lineLimit(1).layoutPriority(-1) }
                        }
                        .frame(idealWidth: wide ? 280 : 120, maxWidth: .infinity, alignment: .leading)
                        .help(pair.model + " on " + pair.provider)
                        now(pair).frame(width: nowWidth, alignment: .leading)
                        Scale(fraction: pair.fraction, color: Theme.pairColor(pair.id)).frame(width: barWidth)
                        NativeNumberText(text: pair.reported ? "\(pair.done)/\(pair.total)" : "-", font: Theme.mono(11), color: pair.reported ? Theme.ink : Theme.faint)
                            .frame(width: 48, alignment: .trailing)
                    }
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(pair.model + " on " + pair.provider)
                .accessibilityValue(pair.reported ? "\(pair.done) of \(pair.total) tests" + (pair.current.map { ", " + $0 } ?? "") : "waiting")
            }
        }
    }
    @ViewBuilder private func now(_ pair: SpeedRunPair) -> some View {
        if let current = pair.current, running {
            HStack(spacing: 6) {
                Theme.signal.frame(width: 2, height: 10)
                Text(current).font(Theme.mono(11)).foregroundStyle(Theme.ink).lineLimit(1).help(current)
            }
        } else if pair.finished {
            HStack(spacing: 6) {
                NativeIcon("check", size: 11, strokeWidth: 2).foregroundStyle(Theme.okFg)
                Text("done").font(Theme.mono(11)).foregroundStyle(Theme.muted)
            }
        } else {
            Text(!pair.reported ? (running ? "waiting" : "not started") : running ? "between tests" : "incomplete")
                .font(Theme.mono(11)).foregroundStyle(Theme.faint)
        }
    }
}

// ======================================================================
// MARK: - Provider row
// ======================================================================

/// One provider: its arming switch, what it will measure and where to change it.
private struct SpeedProviderRow: View {
    let provider: JSONValue
    let included: Bool
    let models: [String]
    let locked: Bool
    let toggle: () -> Void, pick: () -> Void, edit: () -> Void, copyKey: () -> Void
    let remove: (String) -> Void
    private static let lead: CGFloat = 46

    @ViewBuilder static var heads: some View {
        MicroLabel("Arm").frame(width: lead, alignment: .leading)
        MicroLabel("Provider").frame(maxWidth: .infinity, alignment: .leading)
    }
    private var id: String { provider["id"].string }
    private var browser: Bool { provider["transport"] == "chatgpt-web" }
    private var ready: Bool { provider["ready"].bool }
    private var name: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(provider["name"].string).font(Theme.ui(13, weight: .medium)).foregroundStyle(included ? Theme.ink : Theme.muted).lineLimit(1)
            Text(browser ? (ready ? "Browser session, ready for tests" : "Browser session, setup needed") : provider["baseUrl"].string)
                .font(browser ? Theme.ui(11.5) : Theme.mono(10.5))
                .foregroundStyle(browser && !ready ? Theme.warnFg : Theme.muted).lineLimit(1).truncationMode(.middle)
        }
    }
    private var count: some View {
        HStack(alignment: .firstTextBaseline, spacing: 4) {
            NativeNumberText(text: "\(models.count)", font: Theme.readout(17), color: included && !models.isEmpty ? Theme.ink : Theme.faint)
            MicroLabel(browser ? (models.count == 1 ? "mode" : "modes") : (models.count == 1 ? "model" : "models"))
        }
        .frame(minWidth: 70, alignment: .trailing)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(models.count) " + (browser ? "modes" : "models") + " selected")
    }
    private var arm: some View {
        Flip(isOn: Binding(get: { included }, set: { _ in toggle() }), enabled: !locked && (!browser || ready || included))
            .accessibilityLabel("Include " + provider["name"].string)
            .frame(width: Self.lead, alignment: .leading)
    }
    @ViewBuilder private var credentials: some View {
        if !browser {
            NativeKeyPill(key: provider["maskedKey"].string, onCopy: copyKey)
            IconPress(icon: "pencil", help: "Edit provider", size: 13, action: edit).disabled(locked)
        }
    }
    private var pickButton: some View {
        Button(browser ? "Modes" : "Models", nativeIcon: "list-checks", action: pick).buttonStyle(Press(.secondary)).disabled(locked)
    }
    var body: some View {
        LedgerRow(minHeight: 52) {
            VStack(alignment: .leading, spacing: 9) {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 12) {
                        HStack(spacing: 0) { arm; name }
                        Spacer(minLength: 12)
                        credentials; count; pickButton
                    }
                    VStack(alignment: .leading, spacing: 9) {
                        HStack(spacing: 12) {
                            HStack(spacing: 0) { arm; name }
                            Spacer(minLength: 8)
                            count; pickButton
                        }
                        if !browser { HStack(spacing: 8) { credentials }.padding(.leading, Self.lead) }
                    }
                }
                if !provider["catalogError"].isNull {
                    Text(provider["catalogError"].string).font(Theme.ui(11.5)).foregroundStyle(Theme.warnFg)
                        .fixedSize(horizontal: false, vertical: true).padding(.leading, Self.lead)
                }
                if !models.isEmpty {
                    NativeScrollRail {
                        ForEach(models, id: \.self) { model in
                            ModelChip(model: model, color: Theme.pairColor(id + "|" + model)) { remove(model) }.disabled(locked)
                        }
                    }
                    .padding(.leading, Self.lead - 10)
                    .opacity(included ? 1 : 0.5)
                }
            }
            .padding(.vertical, 10)
        }
    }
}

// ======================================================================
// MARK: - Free test report
// ======================================================================

private struct SpeedFreeReport: View {
    let report: JSONValue
    @Binding var query: String
    @Binding var filter: String
    private func tone(_ outcome: String) -> Color {
        outcome == "works" ? Theme.okFg : outcome == "failed" ? Theme.failFg : Theme.muted
    }
    var body: some View {
        let rows = BenchmarkPresentation.freeRows(report, query: query, outcome: filter)
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Entry(placeholder: "Filter by model or provider", text: $query, mono: true, icon: "search")
                Pick(title: "Outcome", selection: $filter,
                     options: [("all", "All outcomes")] + BenchmarkPresentation.outcomes.map { ($0, BenchmarkPresentation.outcomeLabel($0)) }, width: 190)
            }
            .padding(.vertical, 12)
            LedgerHead {
                MicroLabel("Model").frame(maxWidth: .infinity, alignment: .leading)
                MicroLabel("Answered").frame(width: 80, alignment: .trailing)
            }
            // A retained model can already hold a complete sweep. Offscreen
            // outcomes stay out of the first layout and are realized as read.
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(BenchmarkPresentation.outcomes, id: \.self) { outcome in
                    let group = rows.filter { $0["outcome"] == .string(outcome) }
                    if !group.isEmpty {
                        HStack(spacing: 8) {
                            MicroLabel(BenchmarkPresentation.outcomeLabel(outcome), color: tone(outcome))
                            Text("\(group.count)").font(Theme.mono(10.5)).foregroundStyle(Theme.muted)
                        }
                        .frame(height: 30, alignment: .bottom).padding(.bottom, 6)
                        .accessibilityElement(children: .combine).accessibilityAddTraits(.isHeader)
                        ForEach(Array(group.enumerated()), id: \.offset) { _, row in line(row) }
                    }
                }
                if rows.isEmpty {
                    Text("No matching model or provider.").font(Theme.ui(12.5)).foregroundStyle(Theme.muted).padding(.vertical, 20)
                }
            }
        }
    }
    private func line(_ row: JSONValue) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(row["model"].string).font(Theme.mono(11.5)).foregroundStyle(Theme.ink).textSelection(.enabled)
                Text(row["provider"].string + (row["message"].string.isEmpty ? "" : " · " + row["message"].string))
                    .font(Theme.ui(11.5)).foregroundStyle(Theme.muted).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Text(String(format: "%.1f s", row["ms"].double / 1000)).font(Theme.mono(11)).foregroundStyle(Theme.dim)
                .frame(width: 80, alignment: .trailing)
        }
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, minHeight: 36, alignment: .leading)
        .overlay(alignment: .bottom) { Rule() }
    }
}

// ======================================================================
// MARK: - Sheets
// ======================================================================

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
    private func field(_ label: String, _ entry: Entry) -> some View {
        VStack(alignment: .leading, spacing: 6) { MicroLabel(label); entry.accessibilityLabel(label) }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 16) {
                Text("Edit provider").font(Theme.display(17)).foregroundStyle(Theme.ink).accessibilityAddTraits(.isHeader)
                field("Name", Entry(placeholder: "Name", text: $name))
                field("Base URL", Entry(placeholder: "Base URL", text: $base, mono: true))
                field("API key", Entry(placeholder: "Free API key", text: $key, mono: true))
                Text("Updates the shared provider configuration. Model and route settings are kept.")
                    .font(Theme.ui(11.5)).foregroundStyle(Theme.muted).fixedSize(horizontal: false, vertical: true)
                if failed {
                    Notice(text: "Provider could not be saved. Check the name, endpoint and key, and finish any active benchmark first.", tone: .fail)
                        .accessibilityLabel("Error: Provider could not be saved. Check the name, endpoint and key, and finish any active benchmark first.")
                }
            }
            .padding(20)
            Rule()
            HStack(spacing: 8) {
                Spacer(minLength: 0)
                Button("Cancel") { dismiss() }.buttonStyle(Press(.secondary)).keyboardShortcut(.cancelAction)
                Button(saving ? "Saving" : "Save") {
                    saving = true
                    Task { if await save(name, base, key) { dismiss() } else { failed = true }; saving = false }
                }.buttonStyle(Press(.primary)).disabled(saving || name.isEmpty || base.isEmpty)
            }
            .padding(.horizontal, 20).padding(.vertical, 12)
        }
        .frame(width: 480).background(Theme.popover).foregroundStyle(Theme.ink)
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
    private var noun: String { browser ? "mode" : "model" }

    var body: some View {
        let matching = entries
        return VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Text(browser ? "Pick modes" : "Pick models").font(Theme.display(17)).foregroundStyle(Theme.ink).accessibilityAddTraits(.isHeader)
                    Text(provider["name"].string).font(Theme.ui(12.5)).foregroundStyle(Theme.muted).lineLimit(1)
                    Spacer(minLength: 8)
                    HStack(alignment: .firstTextBaseline, spacing: 4) {
                        NativeNumberText(text: "\(chosen.count)", font: Theme.readout(17))
                        MicroLabel("selected")
                    }
                    .accessibilityElement(children: .ignore).accessibilityLabel("\(chosen.count) selected")
                }
                if !provider["catalogError"].string.isEmpty { Notice(text: provider["catalogError"].string, tone: .warn) }
                if browser {
                    Text("Only discovered ChatGPT modes can be selected. Refresh after changing the browser sign-in.")
                        .font(Theme.ui(11.5)).foregroundStyle(Theme.muted).fixedSize(horizontal: false, vertical: true)
                }
                Entry(placeholder: "Search models - every word must match", text: $query, mono: true, icon: "search", autoFocus: true,
                      onSubmit: { if let custom { toggleCustom(custom) } })
            }
            .padding(.horizontal, 20).padding(.top, 20).padding(.bottom, 12)
            Rule()
            ScrollView {
                if provider["catalog"].array.isEmpty && custom == nil {
                    VStack(alignment: .leading, spacing: 0) {
                        if discovering { Text("Fetching the model catalog").font(Theme.ui(12.5)).foregroundStyle(Theme.muted).padding(.vertical, 20) }
                        else { Blank(icon: "list-checks", title: "No catalog yet", detail: browser ? "Complete ChatGPT Web setup in Switcher, then refresh the available modes." : (provider["capabilities"]["arbitraryModels"] == false ? "Refresh the catalog to fetch this provider's models." : "Refresh the catalog to fetch this provider's models, or enter a custom model ID.")) }
                    }.padding(.horizontal, 20).frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        if let custom {
                            choice(id: custom, label: "add \"" + custom + "\"", context: .null,
                                   available: true, reason: "", action: { toggleCustom(custom) })
                        }
                        if matching.isEmpty && custom == nil {
                            Text("No " + (browser ? "mode" : "model ID") + " matches “" + query + "”.")
                                .font(Theme.ui(12.5)).foregroundStyle(Theme.muted).padding(.vertical, 20).padding(.horizontal, 8)
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
                                .font(Theme.ui(11.5)).foregroundStyle(Theme.muted).padding(.vertical, 12).padding(.horizontal, 8)
                        }
                    }.padding(.horizontal, 12).padding(.vertical, 6)
                }
            }.frame(height: 320)
            Rule()
            HStack(spacing: 8) {
                let count = provider["catalog"].array.count
                Text("\(count) " + (count == 1 ? noun : noun + "s") + " in catalog").font(Theme.ui(11.5)).foregroundStyle(Theme.muted).lineLimit(1)
                Spacer(minLength: 8)
                // Bulk actions stay quiet; the sheet has one primary.
                Button("Select matching") { change(BenchmarkPickerPolicy.selectingMatches(matching, in: chosen)) }
                    .buttonStyle(Press(.quiet)).disabled(matching.isEmpty || matching.allSatisfy { $0["available"] == false })
                    .help("Select all available search matches, including those beyond the first 300 displayed.")
                Button("None") { change([]) }.buttonStyle(Press(.quiet)).disabled(chosen.isEmpty)
                Button(discovering ? "Fetching" : "Refresh", nativeIcon: "rotate-cw", action: refresh).buttonStyle(Press(.secondary)).disabled(discovering)
                Button("Done") { dismiss() }.buttonStyle(Press(.primary)).keyboardShortcut(.cancelAction)
            }
            .padding(.horizontal, 20).padding(.vertical, 12)
        }
        .frame(width: 560).fixedSize(horizontal: false, vertical: true)
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
                    RoundedRectangle(cornerRadius: 3, style: .continuous).fill(selected ? Theme.ink : .clear)
                        .overlay(RoundedRectangle(cornerRadius: 3, style: .continuous).strokeBorder(selected ? Theme.ink : Theme.ruleStrong, lineWidth: 1))
                    if selected { NativeIcon("check", size: 9, strokeWidth: 3).foregroundStyle(Theme.onInk) }
                }.frame(width: 13, height: 13).padding(.top, 2.5).accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 3) {
                    Text(label).font(Theme.mono(12)).foregroundStyle(!available ? Theme.muted : selected ? Theme.ink : Theme.dim)
                        .lineLimit(1).truncationMode(.tail).frame(maxWidth: .infinity, minHeight: 18, alignment: .leading)
                    if !reason.isEmpty { Text(reason).font(Theme.ui(11.5)).foregroundStyle(Theme.warnFg).lineSpacing(3).fixedSize(horizontal: false, vertical: true).frame(minHeight: 17, alignment: .leading) }
                }
                if let context { Tag(context).fixedSize() }
            }.padding(.horizontal, 8).padding(.vertical, 6)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(hovering && available ? Theme.hover : .clear, in: RoundedRectangle(cornerRadius: Theme.radiusControl, style: .continuous))
                .contentShape(Rectangle())
        }.buttonStyle(NativeModelChoiceButtonStyle()).pointingHand(available).disabled(!available)
            .accessibilityLabel(label == id ? id : label + ", " + id).accessibilityHint(reason).help(id)
            .accessibilityAddTraits(selected ? [.isSelected] : [])
            .onHover { hovering = $0 && available }
            .onChange(of: available) { if !available { hovering = false } }
            .animation(reduceMotion ? nil : NativeMotion.hover, value: hovering)
    }
}
