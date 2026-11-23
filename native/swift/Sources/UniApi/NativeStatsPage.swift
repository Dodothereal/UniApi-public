import SwiftUI
import AppKit
import Combine
import UniApiCore
import UniApiPresentation

extension NativeStatsModel {
    func export(model: String, source: String, range: Int) async {
        let panelToken = NativePagePanels.shared.capture()
        do {
            let result = try await service.handle("exportDailyCSV", input: ["model": .string(model), "source": .string(source), "range": .number(Double(range))])
            let panel = NSSavePanel(); panel.nameFieldStringValue = result["filename"].string
            if panel.nativeRunModal(token: panelToken) == .OK, let url = panel.url { try Data(result["text"].string.utf8).write(to: url, options: .atomic) }
        } catch { self.error = error.localizedDescription }
    }
}

/// Keep observing after the manual load returns: its stats.scanned event may
/// own the final read, or may have committed before the scan receipt arrives.
@MainActor private final class NativeStatsHeaderVisit {
    let visit: NativePageVisit
    var admission: NativeStatsRefreshAdmission
    var subscription: AnyCancellable?
    var scope: NativeStatsScope { admission.scope }
    init(visit: NativePageVisit, scope: NativeStatsScope) { self.visit = visit; admission = NativeStatsRefreshAdmission(scope: scope) }
    func stop() { subscription?.cancel(); subscription = nil; admission.cancel() }
}

struct NativeStatsPage: View {
    let runtime: NativeRuntime
    @StateObject private var state: NativeStatsModel
    @AppStorage("uniapi.stats.source") private var source = "all"
    @AppStorage("uniapi.stats.range") private var range = 0
    @State private var readOwner = UUID()
    @State private var selectedModel: String?
    @AppStorage("uniapi.stats.view") private var view = "usage"
    @State private var headerVisit: NativeStatsHeaderVisit?
    @State private var headerReadiness = NativePageReadiness.pending
    @Environment(\.nativePageVisit) private var navigationVisit
    @Environment(\.nativePageActivation) private var activation
    @Environment(\.nativeInterfaceDensity) private var density
    init(runtime: NativeRuntime, model: NativeStatsModel? = nil) { self.runtime = runtime; _state = StateObject(wrappedValue: model ?? NativeStatsModel(runtime: runtime)) }
    private var scope: String { "\(source):\(selectedModel ?? ""):\(range)" }
    private var actualRange: Int { range }
    private var snapshot: NativeStatsSnapshot? { state.snapshot(source: source, range: actualRange, model: selectedModel) }
    private var current: JSONValue { snapshot?.payload ?? .null }
    private var currentBenchmark: JSONValue { snapshot?.benchmark ?? .null }
    private func load(mode: NativeStatsLoadMode = .cached) async {
        // This callback also serves stats.scanned. Its ordinary read must remain
        // eligible to publish the exact generation acknowledged by the header.
        // The table and the app strip stay on the unscoped overview while a model is selected.
        if selectedModel != nil { await state.prefetch(source: source, range: range) }
        await state.load(source: source, range: actualRange, model: selectedModel, mode: mode)
        // A refresh drops every snapshot; Benchmark reads the one for all apps.
        if activeView == "benchmark", source != "all" { await state.prefetch(source: "all", range: range) }
    }
    private var readiness: NativePageReadiness { state.busy ? .pending : !state.error.isEmpty ? .failed : current.isNull || currentBenchmark.isNull ? .pending : .ready }
    private var measuredReadiness: NativePageReadiness {
        guard let headerVisit else { return readiness }
        guard activation.active, headerVisit.scope == NativeStatsScope(source: source, range: actualRange, model: selectedModel),
              headerReadiness == readiness else { return .pending }
        return headerReadiness
    }
    private func endHeaderVisit(reason: NativePageVisitEndReason, outcome: NativePageVisitEnd = .cancelled) {
        guard let headerVisit else { return }
        headerVisit.stop()
        NativeUIReadiness.shared.end(headerVisit.visit, outcome: outcome, reason: reason)
        self.headerVisit = nil; headerReadiness = .pending
    }
    private func updateHeaderVisit(_ observation: NativeStatsHeaderVisit) {
        guard headerVisit === observation else { return }
        switch observation.admission.status {
        case .pending: headerReadiness = .pending
        case .ready: headerReadiness = .ready
        case .failed: headerReadiness = .failed
        case .incomplete: endHeaderVisit(reason: .noAcceptedCommit, outcome: .incomplete); return
        case .cancelled: endHeaderVisit(reason: .replacedRead); return
        }
        NativeUIReadiness.shared.complete(observation.visit, readiness: headerReadiness)
    }
    private func reload(_ mode: NativeStatsLoadMode, trigger: NativePageVisitTrigger) {
        guard NativeUIReadiness.shared.enabled else { Task { await load(mode: mode) }; return }
        endHeaderVisit(reason: .replacedRead)
        guard let visit = NativeUIReadiness.shared.begin(.stats, trigger: trigger, parent: navigationVisit) else {
            // Ending the earlier observation may itself close the recorder.
            // Measurement admission must never consume the user's action.
            Task { await load(mode: mode) }; return
        }
        let observation = NativeStatsHeaderVisit(visit: visit, scope: NativeStatsScope(source: source, range: actualRange, model: selectedModel))
        // This barrier precedes Task scheduling: retained content is not ready
        // for the new visit while load() has yet to set its busy flag.
        headerReadiness = .pending; headerVisit = observation
        Task {
            guard headerVisit === observation, activation.active, !Task.isCancelled else {
                if headerVisit === observation { endHeaderVisit(reason: .inactive) }; return
            }
            observation.subscription = state.$busy.dropFirst().sink { [weak observation] busy in
                guard let observation, headerVisit === observation else { return }
                if busy { observation.admission.readStarted() }
                else {
                    // @Published delivers before assigning busy=false, but the
                    // accepted commit has already assigned both data values.
                    observation.admission.published(payload: state.payload, benchmark: state.benchmark, failed: !state.error.isEmpty)
                }
                updateHeaderVisit(observation)
            }
            await state.load(source: observation.scope.source, range: observation.scope.range, model: observation.scope.model, mode: mode,
                             operationCompleted: { scanID in
                guard headerVisit === observation, !Task.isCancelled else { return }
                observation.admission.operationCompleted(scanID: scanID)
                updateHeaderVisit(observation)
            })
            guard headerVisit === observation else { return }
            guard !Task.isCancelled else { endHeaderVisit(reason: .taskCancelled); return }
            observation.admission.operationReturned()
            updateHeaderVisit(observation)
        }
    }
    private var activeView: String { ["usage", "speed", "benchmark"].contains(view) ? view : "usage" }
    /// The unscoped board for this app and range. While its replacement is
    /// being read, the last complete one stays on screen.
    private var overview: JSONValue {
        if let hit = state.snapshot(source: source, range: range, model: nil) { return hit.payload }
        return state.payload["loaded"].bool && state.payload["model"].isNull ? state.payload : .null
    }
    private var detail: JSONValue { selectedModel.flatMap { state.snapshot(source: source, range: range, model: $0)?.payload } ?? .null }
    /// Benchmark records are not attributed to a coding app.
    private var bench: JSONValue { state.snapshot(source: "all", range: range, model: nil)?.benchmark ?? .null }
    var body: some View {
        NativePage(title: "Statistics", maxWidth: .infinity, readiness: measuredReadiness, scrolls: false,
                   tabs: { NativeTabs(options: [("usage", "Usage"), ("speed", "Speed"), ("benchmark", "Benchmark")], selection: activeView) { view = $0 } },
                   actions: { headerActions }) {
            GeometryReader { geometry in
                let overview = self.overview
                if overview["loaded"].bool {
                    NativeStatsBoard(view: activeView, overview: overview, detail: detail, bench: bench, width: geometry.size.width,
                                     busy: state.busy, error: state.error, progress: state.readProgress, range: range,
                                     source: $source, model: $selectedModel,
                                     export: { model in Task { await state.export(model: model, source: source, range: range) } })
                } else {
                    NativePane(maxWidth: 1280) {
                        if !state.error.isEmpty { NativeError(message: state.error) }
                        if state.busy { NativeStatsProgressLabel(progress: state.readProgress, hasContent: false) }
                        else if state.error.isEmpty { ShimmerText(text: "Loading…", font: Theme.ui(12)) }
                    }
                }
            }
        }
        .environment(\.nativePageVisit, headerVisit?.visit ?? navigationVisit)
        .nativePageTask(id: scope) {
            endHeaderVisit(reason: .scopeChanged)
            await state.begin(runtime: runtime, owner: readOwner) { await load() }
        }
        .task(id: "\(activeView):\(source):\(range)") {
            if activeView == "benchmark", source != "all" { await state.prefetch(source: "all", range: range) }
        }
        .onAppear {
            if !(["all"] + StatisticsSource.allCases.map(\.rawValue)).contains(source) { source = "all" }
            if ![0, 7, 30, 90, 365].contains(range) { range = 0 }
        }
        .onChange(of: source) { _, _ in selectedModel = nil }
        .onChange(of: scope) { _, _ in endHeaderVisit(reason: .scopeChanged) }
        .onDisappear { endHeaderVisit(reason: .disappeared) }
        .nativePageActivity(suspended: { endHeaderVisit(reason: .inactive); state.stop(owner: readOwner) })
    }
    @ViewBuilder private var headerActions: some View {
        if activeView != "benchmark" {
            T3Segmented(options: [(7, "7d"), (30, "30d"), (90, "90d"), (365, "1y"), (0, "All")], selection: range) { range = $0 }
        }
        T3IconButton(system: "refresh-cw", help: "Read new or changed usage") { reload(.refresh, trigger: .refresh) }.disabled(state.busy)
        NativeIconMenu(help: "Statistics actions") {
            Button("Rebuild all") { reload(.rebuild, trigger: .rebuild) }
                .help("Reparse every usage file, including files whose size and modification time stayed the same")
        }.disabled(state.busy)
    }
}

private struct NativeStatsProgressLabel: View {
    @ObservedObject var progress: NativeStatsReadProgress
    let hasContent: Bool
    var body: some View {
        ShimmerText(text: NativeStatsPresentationPolicy.progressText(progress.value), font: Theme.ui(12))
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

func nativeStatsSourceName(_ source: String) -> String { ["all": "All", "claude": "Claude Code", "codex": "Codex", "antigravity": "Antigravity", "zcode": "Z Code", "opencode": "OpenCode", "dsh": "DeepSeek Harness"][source] ?? source }
func nativeStatsGrand(_ value: JSONValue) -> Double { value["input"].double + value["output"].double + value["cacheRead"].double + value["cacheWrite"].double }
func nativeStatsCount(_ value: Double) -> String {
    guard value.isFinite else { return "-" }
    if value >= 1_000_000_000 { return nativeStatsFixed(value / 1_000_000_000, digits: 2) + "B" }
    if value >= 1_000_000 { return nativeStatsFixed(value / 1_000_000, digits: value < 10_000_000 ? 2 : 1) + "M" }
    if value >= 1_000 { return nativeStatsFixed(value / 1_000, digits: value < 10_000 ? 1 : 0) + "k" }
    return value < 0 ? String(format: "%.0f", floor(value + 0.5)) : nativeStatsFixed(value, digits: 0)
}

private func nativeStatsFixed(_ value: Double, digits: Int) -> String {
    // Match toFixed's rounding of the represented binary value. printf uses
    // ties-to-even; multiplying the Double first can introduce a second tie.
    let bits = value.bitPattern, exponentBits = Int((bits >> 52) & 0x7ff)
    let significand = (bits & 0x000f_ffff_ffff_ffff) | (exponentBits == 0 ? 0 : 1 << 52)
    let places: UInt64 = digits == 2 ? 100 : digits == 1 ? 10 : 1
    let scaled = significand * places
    let shift = exponentBits == 0 ? 1074 : 1075 - exponentBits
    guard shift > 0 else { return String(format: "%.*f", digits, value) }
    let rounded: UInt64
    if shift >= 64 { rounded = 0 }
    else {
        let remainder = scaled & ((UInt64(1) << shift) - 1)
        rounded = (scaled >> shift) + (remainder >= UInt64(1) << (shift - 1) ? 1 : 0)
    }
    let whole = String(rounded / places)
    guard digits > 0 else { return whole }
    let fraction = String(rounded % places)
    return whole + "." + String(repeating: "0", count: digits - fraction.count) + fraction
}
func nativeStatsDate(_ ts: Double) -> String { Date(timeIntervalSince1970: ts / 1000).formatted(date: .abbreviated, time: .omitted) }

func nativeStatsMoney(_ usd: Double) -> String { usd > 0 && usd < 0.01 ? "<$0.01" : "$" + usd.formatted(.number.precision(.fractionLength(2))) }

private struct NativeStatsColumn {
    let key: String, title: String, width: CGFloat
}

/// One frame for every Statistics view: the headline is the chart's measure,
/// the table under the chart is its legend, and the side pane describes the
/// selection (the whole range when nothing is selected).
private struct NativeStatsBoard: View {
    let view: String
    let overview: JSONValue, detail: JSONValue, bench: JSONValue
    let width: CGFloat
    let busy: Bool
    let error: String
    let progress: NativeStatsReadProgress
    let range: Int
    @Binding var source: String
    @Binding var model: String?
    let export: (String) -> Void

    @AppStorage("uniapi.stats.measure") private var measure = "all"
    @AppStorage("uniapi.stats.sort") private var sort = "tokens"
    @AppStorage("uniapi.stats.ttft.log") private var logarithmic = true
    @State private var descending = true
    @State private var breakdown = "models"
    @State private var speedGroup = "models"
    @State private var project: String?
    @State private var target: String?
    @State private var chosenMetric: NativeStatsRateMetric?
    @Environment(\.nativeInterfaceDensity) private var density

    private static let paneWidth: CGFloat = 320
    private static let measures = [("all", "Tokens"), ("output", "Output"), ("thinking", "Thinking"), ("messages", "Responses")]
    private var wide: Bool { width >= 920 }
    private var mainWidth: CGFloat { wide ? width - Self.paneWidth - 1 : width }
    private var margin: CGFloat { density.pageMargin }
    private var d: JSONValue { overview["derived"] }
    private var summary: JSONValue { d["summary"] }
    private var lifetime: Bool { d["isLifetime"].bool }
    private var modelRow: JSONValue? { model.flatMap { name in d["models"].array.first { $0["model"].string == name } } }
    private var projectRow: JSONValue? { project.flatMap { path in d["projects"].array.first { $0["path"].string == path } } }
    private var detailLoaded: Bool { model != nil && detail["loaded"].bool && detail["model"].string == model }
    private var totals: JSONValue { projectRow?["totals"] ?? modelRow?["totals"] ?? summary["totals"] }
    private var metric: NativeStatsRateMetric {
        chosenMetric ?? (NativeStatsThroughputPresentation.hasMeasurements(NativeStatsRateMetric.streaming.board(d["throughput"])) ? .streaming : .response)
    }
    private var speedBoard: JSONValue { metric.board(d["throughput"]) }
    private var spend: JSONValue { bench["spend"] }
    private var targetRow: JSONValue? { target.flatMap { key in spend["pairs"].array.first { $0["key"].string == key } } }
    private var empty: Bool {
        view == "benchmark" ? spend["calls"].int == 0 && bench["trend"].array.isEmpty
            : nativeStatsGrand(summary["totals"]) == 0 && summary["totals"]["messages"].double == 0
    }
    private func short(_ model: String) -> String { model.split(separator: "/").last.map(String.init) ?? model }
    private func clear() { model = nil; project = nil; target = nil }

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    notices
                    if empty {
                        if view != "benchmark" { appStrip.padding(.top, 16) }
                        Group {
                            if view == "benchmark" { NativeEmptyState(title: "No benchmark runs yet", detail: "Tokens and first-token latency from Benchmark runs are counted here.", icon: "gauge") }
                            else { NativeEmptyState(title: "No usage recorded", detail: source == "all" ? "Sessions from Claude Code, Codex, Antigravity, Z Code and OpenCode on this Mac are counted here." : "Try another range or app.", icon: "chart-line") }
                        }.padding(.horizontal, margin).padding(.top, 24)
                    } else {
                        hero.padding(.horizontal, margin).padding(.top, 20)
                        if view != "benchmark" { appStrip.padding(.top, 16) }
                        chart.padding(.horizontal, margin).padding(.top, 16)
                        table.padding(.top, 20)
                        if !wide {
                            pane.padding(.top, 24)
                            paneActions
                        }
                    }
                }.padding(.bottom, 32).frame(maxWidth: .infinity, alignment: .topLeading)
            }
            .scrollContentBackground(.hidden)
            .focusable().focusEffectDisabled()
            .onMoveCommand { direction in move(direction == .down ? 1 : direction == .up ? -1 : 0) }
            if wide, !empty {
                VStack(spacing: 0) {
                    ScrollView { pane }.scrollContentBackground(.hidden)
                    paneActions
                }
                .frame(width: Self.paneWidth).frame(maxHeight: .infinity, alignment: .top)
                .overlay(alignment: .leading) { Theme.rule.frame(width: 1) }
            }
        }
        .font(Theme.ui(12)).foregroundStyle(Theme.ink)
        .onExitCommand { clear() }
        .onChange(of: view) { _, _ in project = nil; target = nil }
        .onChange(of: d["models"].array.map { $0["model"].string }) { _, names in
            if let model, !names.contains(model) { self.model = nil }
        }
        .onChange(of: d["projects"].array.map { $0["path"].string }) { _, paths in
            if let project, !paths.contains(project) { self.project = nil }
        }
        .onChange(of: lifetime, initial: true) { _, yes in if yes && sort == "messages" { sort = "tokens" } }
    }

    // MARK: Notices

    @ViewBuilder private var notices: some View {
        let warnings = overview["warnings"].array
        if !error.isEmpty || busy || !warnings.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                if !error.isEmpty { NativeError(message: error) }
                ForEach(Array(warnings.enumerated()), id: \.offset) { _, warning in NativeError(message: warning.string) }
                if busy { NativeStatsProgressLabel(progress: progress, hasContent: true) }
            }.padding(.horizontal, margin).padding(.top, 12)
        }
    }

    // MARK: Headline

    private struct HeroFact: Identifiable { let label: String, value: String; var help = ""; var id: String { label } }

    @ViewBuilder private var hero: some View {
        switch view {
        case "speed":
            let reading = speedGroup == "models" && model != nil
                ? speedBoard["models"].array.first { $0["model"].string == model } ?? .null : speedBoard["summary"]
            heroRow(value: NativeStatsThroughputPresentation.rate(reading).map { String(format: "%.1f", $0) } ?? "—",
                    numeric: NativeStatsThroughputPresentation.rate(reading), unit: "tok/s",
                    facts: [HeroFact(label: "Timed", value: timed(reading), help: metric.coverage(reading)),
                            HeroFact(label: "Output timed", value: reading["outputTokens"].isNull ? "—" : nativeStatsCount(reading["outputTokens"].double))]) {
                measureMenu(metric.shortTitle, options: NativeStatsRateMetric.allCases.map { ($0.rawValue, $0.shortTitle) }) { chosenMetric = NativeStatsRateMetric(rawValue: $0) }
            } trailing: { EmptyView() }
        case "benchmark":
            let row = targetRow ?? spend, tokens = row["input"].double + row["output"].double
            heroRow(value: nativeStatsCount(tokens), numeric: tokens, unit: "",
                    facts: [HeroFact(label: "Calls", value: nativeStatsCount(row["calls"].double))]
                        + (targetRow == nil ? [HeroFact(label: "Runs", value: "\(spend["runs"].int)"), HeroFact(label: "Targets", value: "\(spend["pairs"].array.count)")] : [])
                        + [HeroFact(label: "Estimated", value: row["calls"].double > 0 ? String(format: "%.0f%%", row["estimated"].double * 100 / row["calls"].double) : "—", help: "Share of calls whose token counts were estimated because the provider did not report them")]) {
                Text("Benchmark tokens").lineLimit(1).fixedSize()
            } trailing: {
                T3Segmented(options: [(true, "Log"), (false, "Linear")], selection: logarithmic) { logarithmic = $0 }
                    .help("Scale of the first-token chart")
            }
        default:
            let amount = nativeStatsAmount(totals, measure)
            let prompt = totals["input"].double + totals["cacheRead"].double + totals["cacheWrite"].double
            heroRow(value: nativeStatsCount(amount), numeric: amount, unit: "",
                    facts: [costFact,
                            HeroFact(label: "From cache", value: prompt > 0 ? String(format: "%.1f%%", totals["cacheRead"].double * 100 / prompt) : "—", help: "\(nativeStatsCount(totals["cacheRead"].double)) of \(nativeStatsCount(prompt)) prompt tokens were cache reads")]
                        + (lifetime ? [] : [HeroFact(label: "Responses", value: nativeStatsCount(totals["messages"].double))])
                        + [HeroFact(label: "Sessions", value: "\((projectRow?["sessions"] ?? modelRow?["sessions"] ?? summary["sessions"]).int)")]) {
                measureMenu(Self.measures.first { $0.0 == measure }?.1 ?? "Tokens", options: Self.measures) { measure = $0 }
            } trailing: { EmptyView() }
        }
    }

    private var costFact: HeroFact {
        if project != nil { return HeroFact(label: "Est. cost", value: "—", help: "Cost is estimated per model, not per project") }
        if let model {
            let row = d["cost"]["rows"].array.first { $0["model"].string == model } ?? .null
            return HeroFact(label: "Est. cost", value: row["usd"].isNull ? "—" : nativeStatsMoney(row["usd"].double) + (row["unpricedTokens"].double > 0 ? "+" : ""),
                            help: row["usd"].isNull ? "No current API price is known for this model" : "At current API rates")
        }
        let cost = d["cost"]
        guard cost["pricedTokens"].double > 0 else { return HeroFact(label: "Est. cost", value: "—", help: "No current API price is known for these models") }
        let partial = cost["unpricedTokens"].double > 0
        return HeroFact(label: "Est. cost", value: nativeStatsMoney(cost["usd"].double) + (partial ? "+" : ""),
                        help: partial ? "Partial estimate at current API rates. Models without a known price are excluded." : "At current API rates")
    }
    private func timed(_ reading: JSONValue) -> String {
        guard let timed = NativeStatsThroughputPresentation.count(reading["timedResponses"]),
              let total = NativeStatsThroughputPresentation.count(reading["totalResponses"]) else { return "—" }
        return "\(timed) / \(total)"
    }

    private func measureMenu(_ title: String, options: [(String, String)], select: @escaping (String) -> Void) -> some View {
        Menu {
            ForEach(options, id: \.0) { option in Button(option.1) { select(option.0) } }
        } label: {
            HStack(spacing: 4) { Text(title); NativeIcon("chevrons-up-down", size: 10) }.contentShape(Rectangle())
        }.menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
            .help("Choose what the number and the chart measure").accessibilityLabel("Measure")
    }

    private var scopeName: String? {
        if view == "benchmark" { return targetRow.map { "\(short($0["model"].string)) · \($0["providerName"].string)" } }
        return projectRow?["name"].string ?? model.map(short)
    }

    private func heroRow<Label: View, Trailing: View>(value: String, numeric: Double?, unit: String, facts: [HeroFact],
                                                     @ViewBuilder label: () -> Label, @ViewBuilder trailing: () -> Trailing) -> some View {
        HStack(alignment: .lastTextBaseline, spacing: 28) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 8) {
                    label()
                    if let scopeName {
                        Button(action: clear) {
                            HStack(spacing: 4) { Text(scopeName).font(Theme.mono(11)).lineLimit(1).truncationMode(.middle); NativeIcon("x", size: 10) }
                                .foregroundStyle(Theme.ink).padding(.horizontal, 6).frame(height: 18)
                                .background(Theme.subtle, in: RoundedRectangle(cornerRadius: Theme.radiusSm, style: .continuous))
                        }.buttonStyle(.plain).pointingHand().frame(maxWidth: 240, alignment: .leading)
                            .help("Clear the selection").accessibilityLabel("Clear selection \(scopeName)")
                    }
                }.font(Theme.ui(Theme.textXs, weight: .medium)).foregroundStyle(Theme.muted)
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(value).font(Theme.num(32)).tracking(Theme.tracking(32)).lineLimit(1).fixedSize()
                        .nativeStatsNumberTransition(numeric)
                    if !unit.isEmpty { Text(unit).font(Theme.ui(Theme.textSm, weight: .medium)).foregroundStyle(Theme.muted) }
                }
            }
            ForEach(mainWidth >= 620 ? facts : Array(facts.prefix(2))) { fact in
                VStack(alignment: .leading, spacing: 5) {
                    Text(fact.label).font(Theme.ui(11)).foregroundStyle(Theme.muted).lineLimit(1)
                    Text(fact.value).font(Theme.num(15, weight: .medium)).lineLimit(1).fixedSize()
                }.help(fact.help).accessibilityElement(children: .ignore).accessibilityLabel(fact.label).accessibilityValue(fact.value)
            }
            Spacer(minLength: 0)
            trailing()
        }
    }

    // MARK: Apps

    /// The app filter, with what each app accounts for in this range.
    @ViewBuilder private var appStrip: some View {
        // The apps stay put while a model is selected; only their amounts follow it.
        let all = overview["sources"], sources = detailLoaded ? detail["sources"] : all
        let apps = StatisticsSource.allCases.map(\.rawValue).filter { nativeStatsGrand(all[$0]) > 0 || all[$0]["messages"].double > 0 || $0 == source }
        let total = apps.reduce(0) { $0 + nativeStatsGrand(sources[$1]) }
        if apps.count > 1 || source != "all" {
            NativeScrollRail {
                appCell("all", name: "All apps", value: total, fraction: 1, color: Theme.ink)
                ForEach(apps, id: \.self) { app in
                    appCell(app, name: nativeStatsSourceName(app), value: nativeStatsGrand(sources[app]), fraction: total > 0 ? nativeStatsGrand(sources[app]) / total : 0, color: nativeStatsHarnessColor(app))
                }
            }.padding(.horizontal, max(0, margin - 18))
        }
    }
    private func appCell(_ id: String, name: String, value: Double, fraction: Double, color: Color) -> some View {
        let selected = source == id
        return Button { source = selected ? "all" : id } label: {
            VStack(alignment: .leading, spacing: 7) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(name).font(Theme.ui(Theme.textXs, weight: .medium)).foregroundStyle(selected ? Theme.ink : Theme.dim)
                    Text(nativeStatsCount(value)).font(Theme.num(Theme.textXs, weight: .regular)).foregroundStyle(Theme.muted)
                }.lineLimit(1).fixedSize()
                GeometryReader { geometry in
                    ZStack(alignment: .leading) {
                        Theme.track
                        color.frame(width: max(fraction > 0 ? 2 : 0, geometry.size.width * min(1, fraction)))
                    }
                }.frame(height: 2)
            }
            .padding(.horizontal, 8).padding(.vertical, 7)
            .background(selected ? Theme.raised : .clear, in: RoundedRectangle(cornerRadius: Theme.radiusMd, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: Theme.radiusMd, style: .continuous).strokeBorder(selected ? Theme.input : .clear, lineWidth: 1))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain).pointingHand().nativeStatsRowHover()
        .accessibilityLabel("\(name), \(nativeStatsCount(value)) tokens").accessibilityAddTraits(selected ? [.isSelected] : [])
        .help(id == "all" ? "Every coding app on this Mac" : selected ? "Show every app" : "Show only \(name)")
    }

    // MARK: Chart

    @ViewBuilder private var chart: some View {
        switch view {
        case "speed":
            NativeStatsSpeedChart(board: speedBoard, colors: overview["colors"], metric: metric, group: speedGroup,
                                  isolated: speedGroup == "models" ? model : nil)
        case "benchmark":
            NativeStatsBenchmarkChart(trend: bench["trend"].array, logarithmic: logarithmic, isolated: target)
        default:
            NativeStatsUsageChart(data: d, colors: overview["colors"], measure: measure, isolated: model)
        }
    }

    // MARK: Table

    private func heading(_ column: NativeStatsColumn) -> some View {
        Button { if sort == column.key { descending.toggle() } else { sort = column.key; descending = true } } label: {
            HStack(spacing: 3) { if sort == column.key { NativeIcon(descending ? "arrow-down" : "arrow-up", size: 11) }; Text(column.title) }
                .font(Theme.ui(11, weight: .medium)).foregroundStyle(sort == column.key ? Theme.ink : Theme.muted).contentShape(Rectangle())
        }.buttonStyle(.plain).frame(width: column.width, alignment: .trailing)
            .help("Sort by \(column.title)").accessibilityLabel("Sort by \(column.title)")
            .accessibilityValue(sort == column.key ? descending ? "Descending" : "Ascending" : "Not sorted")
    }
    private func tableHeader<Lead: View>(_ columns: [NativeStatsColumn], sortable: Bool = true, @ViewBuilder lead: () -> Lead) -> some View {
        HStack(spacing: 0) {
            lead()
            Spacer(minLength: 8)
            ForEach(columns, id: \.key) { column in
                if sortable { heading(column) }
                else { Text(column.title).font(Theme.ui(11, weight: .medium)).foregroundStyle(Theme.muted).frame(width: column.width, alignment: .trailing) }
            }
        }.frame(height: 32).padding(.horizontal, margin)
    }
    private func cell(_ text: String, _ column: NativeStatsColumn, strong: Bool) -> some View {
        Text(text).font(Theme.num(Theme.textXs, weight: strong ? .medium : .regular)).foregroundStyle(strong ? Theme.ink : Theme.dim)
            .lineLimit(1).frame(width: column.width, alignment: .trailing)
    }
    private func name(_ text: String, color: Color, help: String = "") -> some View {
        HStack(spacing: 8) {
            RoundedRectangle(cornerRadius: 1).fill(color).frame(width: 3, height: 12).accessibilityHidden(true)
            Text(text).font(Theme.mono(Theme.textXs, weight: .medium)).foregroundStyle(Theme.ink).lineLimit(1).truncationMode(.middle).help(help.isEmpty ? text : help)
        }
    }
    private var meterWidth: CGFloat { mainWidth >= 760 ? 96 : 0 }
    private func emptyRow(_ text: String) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Theme.rule.frame(height: 1)
            Text(text).font(Theme.ui(12)).foregroundStyle(Theme.faint).padding(.vertical, 14)
        }.padding(.horizontal, margin)
    }

    @ViewBuilder private var table: some View {
        switch view {
        case "speed": speedTable
        case "benchmark": targetTable
        default: breakdown == "projects" ? AnyView(projectTable) : AnyView(modelTable)
        }
    }

    private var modelColumns: [NativeStatsColumn] {
        [NativeStatsColumn(key: "tokens", title: "Tokens", width: 76), NativeStatsColumn(key: "output", title: "Output", width: 72)]
            + (!lifetime && mainWidth >= 540 ? [NativeStatsColumn(key: "messages", title: "Responses", width: 84)] : [])
            + (mainWidth >= 620 ? [NativeStatsColumn(key: "cost", title: "Est. cost", width: 80)] : [])
            + (mainWidth >= 700 ? [NativeStatsColumn(key: "speed", title: "tok/s", width: 64)] : [])
    }
    private func sortedModels(costs: [String: Double], speeds: [String: Double]) -> [JSONValue] {
        func value(_ row: JSONValue) -> Double {
            switch sort {
            case "output": return row["totals"]["output"].double
            case "messages": return row["totals"]["messages"].double
            case "cost": return costs[row["model"].string] ?? -1
            case "speed": return speeds[row["model"].string] ?? -1
            default: return nativeStatsGrand(row["totals"])
            }
        }
        return d["models"].array.sorted { a, b in
            let x = value(a), y = value(b)
            return x == y ? a["model"].string < b["model"].string : descending ? x > y : x < y
        }
    }
    private var modelCosts: [String: Double] {
        Dictionary(d["cost"]["rows"].array.compactMap { $0["usd"].isNull ? nil : ($0["model"].string, $0["usd"].double) }, uniquingKeysWith: { first, _ in first })
    }
    private var modelSpeeds: [String: Double] {
        Dictionary(speedBoard["models"].array.compactMap { row in NativeStatsThroughputPresentation.rate(row).map { (row["model"].string, $0) } }, uniquingKeysWith: { first, _ in first })
    }
    private var breakdownSwitch: some View {
        T3Segmented(options: [("models", "Models"), ("projects", "Projects")], selection: breakdown) { breakdown = $0; project = nil }
    }
    private var modelTable: some View {
        let costs = modelCosts, speeds = modelSpeeds, rows = sortedModels(costs: costs, speeds: speeds), columns = modelColumns
        func value(_ row: JSONValue, _ key: String) -> Double? {
            switch key {
            case "output": return row["totals"]["output"].double
            case "messages": return row["totals"]["messages"].double
            case "cost": return costs[row["model"].string]
            case "speed": return speeds[row["model"].string]
            default: return nativeStatsGrand(row["totals"])
            }
        }
        let meterKey = columns.contains { $0.key == sort } ? sort : "tokens"
        let top = max(1e-9, rows.compactMap { value($0, meterKey) }.max() ?? 0)
        return VStack(alignment: .leading, spacing: 0) {
            tableHeader(columns) { breakdownSwitch }
            LazyVStack(spacing: 0) {
                ForEach(rows, id: \.self["model"]) { row in
                    let id = row["model"].string
                    NativeStatsRow(selected: model == id, margin: margin) { project = nil; model = model == id ? nil : id } content: {
                        name(short(id), color: nativeStatsColor(overview["colors"][id].string), help: id).layoutPriority(1)
                        if row["viaProxy"].bool { MonoChip(text: "proxy", color: Theme.warnFg).padding(.leading, 8).help("Served through a gateway, not by Anthropic") }
                        if row["pruned"].bool { MonoChip(text: "pruned").padding(.leading, 8).help("Its transcripts were pruned. Totals are kept, dated history is not.") }
                        Spacer(minLength: 12)
                        if meterWidth > 0 { NativeTickMeter(fraction: (value(row, meterKey) ?? 0) / top, color: Theme.ink, height: 8).frame(width: meterWidth).padding(.trailing, 12) }
                        ForEach(columns, id: \.key) { column in
                            let reading = value(row, column.key)
                            cell(reading.map { column.key == "cost" ? nativeStatsMoney($0) : column.key == "speed" ? String(format: "%.1f", $0) : nativeStatsCount($0) } ?? "—",
                                 column, strong: column.key == sort)
                        }
                    }
                }
                if rows.isEmpty { emptyRow("No models in this range") }
            }
        }
    }
    private var projectTable: some View {
        let columns = [NativeStatsColumn(key: "tokens", title: "Tokens", width: 76), NativeStatsColumn(key: "output", title: "Output", width: 72), NativeStatsColumn(key: "sessions", title: "Sessions", width: 76)]
        func value(_ row: JSONValue, _ key: String) -> Double {
            key == "output" ? row["totals"]["output"].double : key == "sessions" ? row["sessions"].double : nativeStatsGrand(row["totals"])
        }
        let key = columns.contains { $0.key == sort } ? sort : "tokens"
        let rows = d["projects"].array.sorted { a, b in
            let x = value(a, key), y = value(b, key)
            return x == y ? a["path"].string < b["path"].string : descending ? x > y : x < y
        }
        let top = max(1, rows.map { value($0, key) }.max() ?? 0)
        return VStack(alignment: .leading, spacing: 0) {
            tableHeader(columns) { breakdownSwitch }
            LazyVStack(spacing: 0) {
                ForEach(rows, id: \.self["path"]) { row in
                    let id = row["path"].string
                    NativeStatsRow(selected: project == id, margin: margin) { model = nil; project = project == id ? nil : id } content: {
                        name(row["name"].string, color: Theme.pairColor(id), help: id).layoutPriority(1)
                        Spacer(minLength: 12)
                        if meterWidth > 0 { NativeTickMeter(fraction: value(row, key) / top, color: Theme.ink, height: 8).frame(width: meterWidth).padding(.trailing, 12) }
                        ForEach(columns, id: \.key) { column in
                            cell(column.key == "sessions" ? "\(row["sessions"].int)" : nativeStatsCount(value(row, column.key)), column, strong: column.key == key)
                        }
                    }
                }
                if rows.isEmpty { emptyRow("No projects in this range") }
            }
        }
    }

    private var speedRows: [JSONValue] {
        let all = speedBoard[speedGroup].array
        let measured = speedGroup == "models" && metric == .streaming ? NativeStatsThroughputPresentation.measuredRows(all)
            : all.filter { $0["totalResponses"].int > 0 }
        return measured.sorted {
            let a = NativeStatsThroughputPresentation.rate($0) ?? -1, b = NativeStatsThroughputPresentation.rate($1) ?? -1
            return a == b ? $0["model"].string + $0["source"].string < $1["model"].string + $1["source"].string : a > b
        }
    }
    private var speedTable: some View {
        let rows = speedRows, peak = max(1, rows.compactMap { NativeStatsThroughputPresentation.rate($0) }.max() ?? 0)
        let columns = [NativeStatsColumn(key: "speed", title: "tok/s", width: 72), NativeStatsColumn(key: "timed", title: "Timed", width: 96)]
        let unmeasured = speedBoard[speedGroup].array.count - rows.count
        return VStack(alignment: .leading, spacing: 0) {
            tableHeader(columns, sortable: false) {
                T3Segmented(options: [("models", "Models"), ("harnesses", "Apps")], selection: speedGroup) { speedGroup = $0 }
            }
            LazyVStack(spacing: 0) {
                ForEach(rows, id: \.self) { row in
                    let app = speedGroup == "harnesses", id = app ? row["source"].string : row["model"].string
                    NativeStatsRow(selected: app ? source == id : model == id, margin: margin) {
                        if app { source = source == id ? "all" : id } else { project = nil; model = model == id ? nil : id }
                    } content: {
                        name(app ? nativeStatsSourceName(id) : short(id), color: app ? nativeStatsHarnessColor(id) : nativeStatsColor(overview["colors"][id].string), help: app ? "" : id).layoutPriority(1)
                        Spacer(minLength: 12)
                        if meterWidth > 0 { NativeTickMeter(fraction: (NativeStatsThroughputPresentation.rate(row) ?? 0) / peak, color: Theme.ink, height: 8).frame(width: meterWidth).padding(.trailing, 12) }
                        cell(NativeStatsThroughputPresentation.rate(row).map { String(format: "%.1f", $0) } ?? "—", columns[0], strong: true)
                        cell(timed(row), columns[1], strong: false)
                    }.help(metric.timingDetail(row))
                }
                if rows.isEmpty { emptyRow(metric == .streaming ? "These responses have token totals but no streaming clock. Response average uses elapsed response time instead." : "No timed responses in this range") }
                else if unmeasured > 0, metric == .streaming { emptyRow("\(unmeasured) more without a usable streaming clock") }
            }
        }
    }

    private var targetRows: [JSONValue] {
        spend["pairs"].array.sorted {
            let a = $0["input"].double + $0["output"].double, b = $1["input"].double + $1["output"].double
            return a == b ? $0["key"].string < $1["key"].string : a > b
        }
    }
    private var targetTable: some View {
        let rows = targetRows, top = max(1, rows.map { $0["input"].double + $0["output"].double }.max() ?? 0)
        let columns = [NativeStatsColumn(key: "input", title: "Input", width: 76), NativeStatsColumn(key: "output", title: "Output", width: 72), NativeStatsColumn(key: "calls", title: "Calls", width: 64)]
        return VStack(alignment: .leading, spacing: 0) {
            tableHeader(columns, sortable: false) { Text("Targets").font(Theme.ui(11, weight: .medium)).foregroundStyle(Theme.muted) }
            LazyVStack(spacing: 0) {
                ForEach(rows, id: \.self["key"]) { row in
                    let id = row["key"].string
                    NativeStatsRow(selected: target == id, margin: margin) { target = target == id ? nil : id } content: {
                        name(short(row["model"].string), color: Theme.pairColor(id), help: row["model"].string).layoutPriority(1)
                        Text(row["providerName"].string).font(Theme.ui(Theme.textXs)).foregroundStyle(Theme.muted).lineLimit(1).padding(.leading, 10)
                        Spacer(minLength: 12)
                        if meterWidth > 0 { NativeTickMeter(fraction: (row["input"].double + row["output"].double) / top, color: Theme.ink, height: 8).frame(width: meterWidth).padding(.trailing, 12) }
                        cell(nativeStatsCount(row["input"].double), columns[0], strong: true)
                        cell(nativeStatsCount(row["output"].double), columns[1], strong: false)
                        cell("\(row["calls"].int)", columns[2], strong: false)
                    }
                }
                if rows.isEmpty { emptyRow("No benchmark tokens recorded") }
            }
        }
    }

    private func move(_ step: Int) {
        guard step != 0 else { return }
        func next(_ ids: [String], _ current: String?) -> String? {
            guard let current, let index = ids.firstIndex(of: current) else { return step > 0 ? ids.first : nil }
            return ids.indices.contains(index + step) ? ids[index + step] : current
        }
        switch view {
        case "benchmark": if let id = next(targetRows.map { $0["key"].string }, target) { target = id }
        case "speed":
            guard speedGroup == "models" else { return }
            if let id = next(speedRows.map { $0["model"].string }, model) { model = id }
        default:
            if breakdown == "projects" {
                if let id = next(d["projects"].array.map { $0["path"].string }, project) { project = id }
            } else if let id = next(sortedModels(costs: modelCosts, speeds: modelSpeeds).map { $0["model"].string }, model) { model = id }
        }
    }

    // MARK: Pane

    private var rangeName: String { [7: "Last 7 days", 30: "Last 30 days", 90: "Last 90 days", 365: "Last year"][range] ?? "All time" }
    private func section<Content: View>(_ title: String, @ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).font(Theme.ui(11, weight: .medium)).foregroundStyle(Theme.muted).accessibilityAddTraits(.isHeader)
            content()
        }
        .padding(.horizontal, wide ? 16 : margin).padding(.vertical, 14).frame(maxWidth: .infinity, alignment: .leading)
        .overlay(alignment: .top) { Theme.rule.frame(height: 1) }
    }
    private func fact(_ label: String, _ value: String, mono: Bool = false) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(label).font(Theme.ui(Theme.textXs)).foregroundStyle(Theme.dim).lineLimit(1)
            Spacer(minLength: 8)
            Text(value).font(mono ? Theme.mono(11) : Theme.num(Theme.textXs, weight: .medium)).foregroundStyle(Theme.ink).lineLimit(1).truncationMode(.middle).textSelection(.enabled)
        }
    }
    private func note(_ text: String, tone: Color = Theme.muted) -> some View {
        Text(text).font(Theme.ui(11)).foregroundStyle(tone).fixedSize(horizontal: false, vertical: true)
    }

    @ViewBuilder private var pane: some View {
        VStack(alignment: .leading, spacing: 0) {
            paneHeader
            if view == "benchmark" { benchmarkPane } else {
                if view == "speed" { speedSection }
                tokensSection
                let heat = model == nil ? d["heat"].array : detailLoaded ? detail["derived"]["heat"].array : []
                if project == nil, !heat.isEmpty { section("Hours") { NativeStatsHeat(grid: heat) } }
                activitySection
                if detailLoaded, !detail["derived"]["projects"].array.isEmpty { modelProjects }
                if project == nil, model == nil || detailLoaded {
                    section("Prices") { NativeStatsPricing(cost: detailLoaded ? detail["derived"]["cost"] : d["cost"]) }
                }
                notes
            }
        }.frame(maxWidth: .infinity, alignment: .topLeading)
    }
    private var paneHeader: some View {
        let selected = view == "benchmark" ? target != nil : model != nil || project != nil
        let title: String = view == "benchmark" ? targetRow.map { short($0["model"].string) } ?? "All targets"
            : projectRow?["name"].string ?? model.map(short) ?? (source == "all" ? "All apps" : nativeStatsSourceName(source))
        let first = summary["first"], last = summary["last"]
        let caption: String = view == "benchmark" ? targetRow?["providerName"].string ?? "Every benchmark run"
            : projectRow?["path"].string ?? (model.map { $0.contains("/") ? $0 : rangeName } ?? rangeName + (first.isNull ? "" : " · \(nativeStatsDate(first.double)) – \(nativeStatsDate(last.double))"))
        return HStack(alignment: .center, spacing: 8) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(selected ? Theme.mono(Theme.textSm, weight: .semibold) : Theme.ui(Theme.textSm, weight: .semibold)).lineLimit(1).truncationMode(.middle)
                    .accessibilityAddTraits(.isHeader)
                Text(caption).font(Theme.ui(11)).foregroundStyle(Theme.muted).lineLimit(1).truncationMode(.middle).help(caption)
            }
            Spacer(minLength: 8)
            if selected { T3IconButton(system: "x", help: "Clear the selection", size: 13, action: clear) }
        }.padding(.leading, wide ? 16 : margin).padding(.trailing, wide ? 10 : margin).padding(.vertical, 14)
    }
    private var tokensSection: some View {
        let rows: [(String, String, Int)] = [("Cache reads", "cacheRead", 4), ("Cache writes", "cacheWrite", 3), ("Fresh input", "input", 0), ("Output", "output", 1), ("Thinking, inside output", "thinking", 2)]
        let grand = nativeStatsGrand(totals)
        return section("Tokens") {
            ForEach(rows, id: \.1) { label, key, tone in
                let denominator = key == "thinking" ? totals["output"].double : grand
                VStack(alignment: .leading, spacing: 5) {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(label).font(Theme.ui(Theme.textXs)).foregroundStyle(Theme.dim).lineLimit(1)
                        Spacer(minLength: 8)
                        Text(nativeStatsCount(totals[key].double)).font(Theme.num(Theme.textXs, weight: .medium)).nativeStatsNumberTransition(totals[key].double)
                        Text(denominator > 0 ? String(format: "%.1f%%", totals[key].double * 100 / denominator) : "—").font(Theme.num(11, weight: .regular)).foregroundStyle(Theme.muted).frame(width: 46, alignment: .trailing)
                    }
                    NativeGrowBar(fraction: totals[key].double / max(1, denominator), color: Theme.series[tone], height: 3, entrance: false)
                }.help(key == "thinking" ? "Thinking is part of generated output; its share is measured against output." : totals[key].double.formatted())
            }
        }
    }
    private var speedSection: some View {
        let reading = speedGroup == "models" && model != nil ? speedBoard["models"].array.first { $0["model"].string == model } ?? .null : speedBoard["summary"]
        return section(metric.title) {
            fact("Speed", NativeStatsThroughputPresentation.rate(reading).map { String(format: "%.1f tok/s", $0) } ?? "—")
            fact("Responses timed", timed(reading))
            fact("Output timed", reading["outputTokens"].isNull ? "—" : nativeStatsCount(reading["outputTokens"].double))
            fact("Time measured", reading["durationMs"].double > 0 ? Duration.seconds(reading["durationMs"].double / 1000).formatted(.units(allowed: [.hours, .minutes, .seconds], width: .narrow)) : "—")
            note(metric.caption)
        }
    }
    private var activitySection: some View {
        let s: JSONValue = model == nil ? summary : detailLoaded ? detail["datedSummary"] : .null
        return section("Activity") {
            if let row = projectRow {
                fact("Sessions", "\(row["sessions"].int)")
            } else if s.isNull, let row = modelRow {
                fact("Sessions", "\(row["sessions"].int)"); fact("Active days", "\(row["days"].int)")
            } else {
                if !lifetime || model != nil { fact("Responses", nativeStatsCount(s["totals"]["messages"].double)) }
                fact("Sessions", "\(s["sessions"].int)")
                fact("Projects", "\(s["projects"].int)")
                if model == nil { fact("Models", "\(s["models"].int)") }
                fact("Active days", "\(s["activeDays"].int)")
                if s["sidechainMessages"].int > 0 { fact("Subagent turns", "\(s["sidechainMessages"].int) · \(nativeStatsCount(s["sidechainTokens"].double))") }
                if s["proxyMessages"].int > 0 { fact("Through a gateway", "\(s["proxyMessages"].int)") }
                if s["totals"]["webSearch"].int > 0 { fact("Web searches", "\(s["totals"]["webSearch"].int)") }
                if s["totals"]["webFetch"].int > 0 { fact("Page fetches", "\(s["totals"]["webFetch"].int)") }
                let efforts = s["effort"].object.filter { $0.key != "not recorded" && $0.value.double > 0 }
                if efforts.count > 1 || efforts.keys.first.map({ $0 != "default" }) == true {
                    ForEach(efforts.keys.sorted(), id: \.self) { key in fact("Effort \(key)", "\(efforts[key]?.int ?? 0)") }
                }
            }
        }
    }
    private var modelProjects: some View {
        let rows = detail["derived"]["projects"].array, top = max(1, rows.map { nativeStatsGrand($0["totals"]) }.max() ?? 0)
        return section("Projects") {
            ForEach(Array(rows.prefix(6).enumerated()), id: \.offset) { _, row in
                VStack(alignment: .leading, spacing: 5) {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(row["name"].string).font(Theme.mono(11, weight: .medium)).lineLimit(1).truncationMode(.middle).help(row["path"].string)
                        Spacer(minLength: 8)
                        Text(nativeStatsCount(nativeStatsGrand(row["totals"]))).font(Theme.num(Theme.textXs, weight: .medium))
                    }
                    NativeGrowBar(fraction: nativeStatsGrand(row["totals"]) / top, color: Theme.pairColor(row["path"].string), height: 3, entrance: false)
                }
            }
            if rows.count > 6 { note("\(rows.count - 6) more") }
        }
    }
    @ViewBuilder private var notes: some View {
        let payload = detailLoaded ? detail : overview
        let excluded = NativeStatsPresentationPolicy.excludedNotices(payload, detail: detailLoaded)
        let scan = overview["scan"], cache = overview["cache"]
        section(cache.isNull || model != nil || project != nil ? "Records" : "Compared with /stats") {
            if lifetime { note("Lifetime totals include Claude's cache. The chart uses the response records still on disk.") }
            if let row = modelRow, row["viaProxy"].bool { note("Served through a gateway, not by Anthropic.", tone: Theme.warnFg) }
            if let row = modelRow, row["pruned"].bool { note("Its transcripts were pruned. Totals are kept, dated history is not.") }
            ForEach(excluded, id: \.source) { notice in note("\(nativeStatsSourceName(notice.source)): \(notice.count) records have no usable usage metadata.") }
            if !cache.isNull, model == nil, project == nil {
                fact("Lifetime", nativeStatsCount(nativeStatsGrand(cache["totals"])))
                fact("Raw on disk", nativeStatsCount(scan["rawGrand"].double))
                fact("De-duplicated on disk", nativeStatsCount(d["onDiskGrand"].double))
                fact("Repeated blocks", "\(scan["duplicates"].int)")
                fact("UTC days that agree", "\(overview["dayMatch"]["matched"].int) / \(overview["dayMatch"]["checked"].int)")
            }
            note("\(scan["files"].int) files · \(nativeStatsCount(scan["bytes"].double)) bytes · read in \(scan["elapsedMs"].double.formatted(.number.precision(.fractionLength(0)))) ms", tone: Theme.faint)
        }
    }
    @ViewBuilder private var benchmarkPane: some View {
        let row = targetRow ?? spend
        section("Tokens") {
            fact("Input", nativeStatsCount(row["input"].double))
            fact("Cached, inside input", nativeStatsCount(row["cached"].double))
            fact("Output", nativeStatsCount(row["output"].double))
            fact("Reasoning, inside output", nativeStatsCount(row["reasoning"].double))
        }
        section("Calls") {
            fact("Calls", "\(row["calls"].int)")
            fact("With estimated counts", "\(row["estimated"].int)")
            if targetRow == nil { fact("Runs", "\(spend["runs"].int)"); fact("Targets", "\(spend["pairs"].array.count)") }
            else { fact("Provider", row["provider"].string, mono: true); fact("Model", row["model"].string, mono: true) }
        }
        section("Records") {
            note("Tokens UniApi's own measuring sent through each provider. They are not part of coding-app usage.")
            note("The chart is the median successful first-token latency per run. A rising line is a provider getting slower.")
        }
    }
    @ViewBuilder private var paneActions: some View {
        if view != "benchmark", let model {
            HStack(spacing: 8) {
                Button("Export daily CSV", nativeIcon: "download") { export(model) }.buttonStyle(T3Button(.outline))
                    .disabled(d["days"].array.isEmpty)
            }
            .padding(.horizontal, wide ? 16 : margin).padding(.vertical, 12).frame(maxWidth: .infinity, alignment: .trailing)
            .overlay(alignment: .top) { Theme.rule.frame(height: 1) }
        }
    }
}

private typealias NativeStatsRow<Content: View> = NativeBoardRow<Content>

/// Responses by local weekday and hour.
private struct NativeStatsHeat: View {
    let grid: [JSONValue]
    private var maximum: Double { grid.flatMap(\.array).map(\.double).max() ?? 0 }
    var body: some View {
        let peak = maximum
        VStack(alignment: .leading, spacing: 6) {
            VStack(spacing: 2) {
                ForEach(0..<min(7, grid.count), id: \.self) { day in
                    HStack(spacing: 2) {
                        Text(["Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun"][day]).font(Theme.ui(10)).foregroundStyle(Theme.muted).frame(width: 26, alignment: .leading)
                        ForEach(0..<24, id: \.self) { hour in
                            let value = grid[day].array.count > hour ? grid[day].array[hour].double : 0
                            RoundedRectangle(cornerRadius: 1.5).fill(value > 0 ? Theme.accent.opacity(0.2 + 0.8 * value / max(1, peak)) : Theme.track)
                                .frame(maxWidth: .infinity, minHeight: 10, maxHeight: 10)
                                .help("\(["Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday", "Sunday"][day]) \(hour):00 · \(Int(value)) responses")
                                .accessibilityLabel("Day \(day + 1), hour \(hour), \(Int(value)) responses")
                        }
                    }
                }
            }
            HStack { Text("00"); Spacer(); Text("06"); Spacer(); Text("12"); Spacer(); Text("18"); Spacer(); Text("23") }
                .font(Theme.mono(9)).foregroundStyle(Theme.faint).padding(.leading, 28)
            let hours = (0..<24).map { hour in grid.reduce(0) { $0 + ($1.array.count > hour ? $1.array[hour].double : 0) } }
            if peak > 0, let best = hours.enumerated().max(by: { $0.element < $1.element }) {
                Text("Busiest at \(best.offset):00").font(Theme.ui(11)).foregroundStyle(Theme.muted)
            }
        }
    }
}
