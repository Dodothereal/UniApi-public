import SwiftUI
import AppKit
import UniApiCore
import UniApiPresentation

/// One measure of a benchmark target. The headline, the table order and the
/// tick scale all follow the chosen one.
private enum NativeResultsMeasure: String, CaseIterable {
    case ttft, decode, context, reliability, gap

    var lowerIsBetter: Bool { self == .ttft || self == .gap }
    func title(browser: Bool) -> String {
        switch self {
        case .ttft: return browser ? "First response" : "First token"
        case .decode: return "Output speed"
        case .context: return "Largest input"
        case .reliability: return "Reliability"
        case .gap: return "Worst pause"
        }
    }
    func column(browser: Bool, history: Bool) -> String {
        switch self {
        case .ttft: return browser ? "First response" : "First token"
        case .decode: return browser ? "Output speed" : history ? "Best speed" : "Decode"
        case .context: return "Max input"
        case .reliability: return "Reliability"
        case .gap: return history ? "Gap at best" : "Gap p95"
        }
    }
    var width: CGFloat {
        switch self { case .ttft: return 96; case .decode: return 100; case .context: return 78; case .reliability: return 84; case .gap: return 78 }
    }
    /// The run a best-of-history figure came from.
    var source: String {
        switch self { case .ttft: return "latency"; case .decode, .gap: return "throughput"; case .context: return "context"; case .reliability: return "" }
    }
    func value(_ cell: NativeResultCell) -> Double? {
        switch self { case .ttft: return cell.ttft; case .decode: return cell.speed; case .context: return cell.input; case .reliability: return cell.reliability; case .gap: return cell.gap }
    }
    /// The figure and its unit, kept apart so the headline can set them differently.
    func parts(_ cell: NativeResultCell) -> (String, String) {
        guard let value = value(cell) else { return ("—", "") }
        switch self {
        case .ttft, .gap:
            let text = nativeBenchMilliseconds(value)
            guard let space = text.lastIndex(of: " ") else { return (text, "") }
            return (String(text[..<space]), String(text[text.index(after: space)...]))
        case .decode: return ((cell.estimated ? "~" : "") + String(format: "%.1f", value), "tok/s")
        case .context: return ((cell.estimated ? "~" : "") + nativeBenchTokens(value) + (cell.capped ? "" : "+"), "tokens")
        case .reliability: return (String(format: "%.0f%%", value), "")
        }
    }
    func text(_ cell: NativeResultCell) -> String {
        let parts = parts(cell)
        return parts.1.isEmpty || self == .context ? parts.0 : parts.0 + " " + parts.1
    }
    func leader(_ cells: [NativeResultCell]) -> NativeResultCell? {
        let measured = cells.filter { value($0) != nil }
        return lowerIsBetter ? measured.min { value($0)! < value($1)! } : measured.max { value($0)! < value($1)! }
    }
}

struct NativeResultsPage: View {
    @Environment(\.nativeHostTabs) private var host
    let runtime: NativeRuntime
    @StateObject private var state: NativeResultsModel
    @Environment(\.nativeInterfaceDensity) private var density
    @AppStorage("uniapi.rank.metric") private var ranking = "ttft"
    @State private var showRuns = false
    @State private var selected: String?
    init(runtime: NativeRuntime, initialRun: String? = nil) { self.runtime = runtime; _state = StateObject(wrappedValue: NativeResultsModel(runtime: runtime, initialRun: initialRun)) }

    private var margin: CGFloat { density.pageMargin }
    private var measure: NativeResultsMeasure { NativeResultsMeasure(rawValue: ranking) ?? .ttft }
    private var history: Bool { state.payload["aggregation"] == "best" }
    private var families: [String] { Array(Set(state.payload["cells"].object.values.map { $0["family"].string })).sorted() }
    /// Targets in scope, best first on the chosen measure.
    private var cells: [NativeResultCell] {
        let measure = self.measure
        return state.payload["cells"].object.map { NativeResultCell(id: $0.key, value: $0.value) }
            .filter { state.family.isEmpty || $0.value["family"] == .string(state.family) }
            .sorted {
                guard let a = measure.value($0) else { return false }
                guard let b = measure.value($1) else { return true }
                return a == b ? $0.id < $1.id : measure.lowerIsBetter ? a < b : a > b
            }
    }
    private var browser: Bool { state.payload["cells"].object.values.contains { $0["transport"] == "browser" } }

    var body: some View {
        NativePage(title: "Results", maxWidth: .infinity, readiness: state.busy ? .pending : !state.error.isEmpty ? .failed : state.payload.isNull ? .pending : .ready, scrolls: false, tabs: {
            NativeTabs(options: [("table", "Results"), ("charts", "Charts"), ("runs", "Runs")], selection: showRuns ? "runs" : state.tab,
                       counts: ["runs": state.payload["runs"].array.count]) { tab in
                if tab == "runs" { showRuns = true } else { showRuns = false; state.chooseTab(tab) }
                host?.select(tab)
            }
            .nativeHostedView(["table", "charts", "runs"]) { tab in
                if tab == "runs" { showRuns = true } else { showRuns = false; if state.tab != tab { state.chooseTab(tab) } }
            }
        }, actions: { headerActions }) {
            GeometryReader { geometry in content(width: geometry.size.width) }
        }
        .nativePageTask { await state.begin(runtime: runtime) }.nativePageActivity(suspended: { state.stop() })
        // Usage covers every run. Each row a run adds changes that run's counts here.
        .task(id: state.payload["runs"]) {
            if !state.payload.isNull { await state.loadUsage() }
        }
        .onChange(of: state.payload["scope"].string) { selected = nil }
        .onChange(of: state.family) { selected = nil }
    }

    @ViewBuilder private func content(width: CGFloat) -> some View {
        let cells = self.cells
        if state.busy || state.payload.isNull || (cells.isEmpty && !showRuns) || (showRuns && state.payload["runs"].array.isEmpty) {
            NativePane(maxWidth: 1280) {
                if !state.error.isEmpty { NativeError(message: state.error) }
                if state.busy || state.payload.isNull {
                    if state.error.isEmpty { ShimmerText(text: "Loading…", font: Theme.ui(12)) }
                } else {
                    NativeEmptyState(title: showRuns ? "No runs" : "No results in this scope", detail: "Pick models on Run and start one.", icon: "chart-bar",
                                     actionTitle: "Run", actionIcon: "gauge") {
                        if let host { host.select("bench") } else { NotificationCenter.default.post(name: .nativeNavigation, object: NativeDestination.speed) }
                    }
                }
            }
        } else {
            let mainWidth = NativeBoard<EmptyView, EmptyView, EmptyView>.mainWidth(width)
            let chosen = cells.first { $0.id == selected }
            NativeBoard(width: width, onMove: showRuns ? nil : { move($0, in: cells) }) {
                if !state.error.isEmpty { NativeError(message: state.error).padding(.horizontal, margin).padding(.top, 16) }
                if showRuns { runList }
                else {
                    hero(cells: cells, chosen: chosen, mainWidth: mainWidth).padding(.horizontal, margin).padding(.top, 20)
                    if families.count > 1 {
                        NativeScrollRail {
                            familyButton("", label: "All")
                            ForEach(families, id: \.self) { family in familyButton(family, label: family) }
                        }.padding(.horizontal, max(0, margin - 10)).padding(.top, 16)
                    }
                    if state.tab == "charts" {
                        NativeResultsCharts(cells: cells, rows: state.curves, history: history, margin: margin, focus: chosen?.id)
                    } else {
                        table(cells: cells, mainWidth: mainWidth).padding(.top, 16)
                    }
                }
            } pane: {
                VStack(alignment: .leading, spacing: 0) {
                    if let chosen, !showRuns { targetPane(chosen) } else { scopePane(cells) }
                }
            } actions: { paneActions }
            .onExitCommand { selected = nil }
        }
    }

    private func move(_ step: Int, in cells: [NativeResultCell]) {
        guard step != 0, !cells.isEmpty else { return }
        let index = selected.flatMap { id in cells.firstIndex { $0.id == id } }
        selected = cells[min(cells.count - 1, max(0, (index ?? (step > 0 ? -1 : cells.count)) + step))].id
    }

    // MARK: - Headline

    private func hero(cells: [NativeResultCell], chosen: NativeResultCell?, mainWidth: CGFloat) -> some View {
        let measure = self.measure, shown = chosen ?? measure.leader(cells)
        let parts = shown.map(measure.parts) ?? ("—", "")
        // With nothing selected each figure is the best in scope and can belong to a different target.
        let facts = [NativeResultsMeasure.ttft, .decode, .context, .reliability].filter { $0 != measure }.compactMap { other -> NativeHeroFact? in
            guard let cell = chosen ?? other.leader(cells) else { return nil }
            return NativeHeroFact(label: other.title(browser: browser), value: other.text(cell),
                                  help: chosen == nil ? cell.value["model"].string + " on " + cell.value["provider_name"].string : "")
        }
        return NativeHero(value: parts.0, numeric: shown.flatMap(measure.value), unit: parts.1, facts: facts,
                          maxFacts: mainWidth >= 700 ? 3 : mainWidth >= 520 ? 2 : 0) {
            Menu {
                ForEach(NativeResultsMeasure.allCases, id: \.self) { option in Button(option.title(browser: browser)) { ranking = option.rawValue } }
            } label: {
                HStack(spacing: 4) { Text(measure.title(browser: browser)); NativeIcon("chevrons-up-down", size: 10) }.contentShape(Rectangle())
            }.menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize().frame(height: 18)
                .help("Choose what the number, the order and the scale measure").accessibilityLabel("Measure")
            if let chosen {
                Button { selected = nil } label: {
                    HStack(spacing: 4) { Text(chosen.short).font(Theme.mono(11)).lineLimit(1).truncationMode(.middle); NativeIcon("x", size: 10) }
                        .foregroundStyle(Theme.ink).padding(.horizontal, 6).frame(height: 18)
                        .background(Theme.subtle, in: RoundedRectangle(cornerRadius: Theme.radiusSm, style: .continuous))
                }.buttonStyle(.plain).pointingHand().frame(maxWidth: 240, alignment: .leading)
                    .help("Clear the selection").accessibilityLabel("Clear selection \(chosen.short)")
            } else if let shown {
                HStack(spacing: 5) {
                    RoundedRectangle(cornerRadius: 1).fill(Theme.pairColor(shown.id)).frame(width: 3, height: 10)
                    Text(shown.short).font(Theme.mono(11)).foregroundStyle(Theme.dim).lineLimit(1).truncationMode(.middle)
                }.help(shown.value["model"].string + " on " + shown.value["provider_name"].string)
            }
        } trailing: { EmptyView() }
    }

    private func familyButton(_ family: String, label: String) -> some View {
        let selected = state.family == family
        return Button { state.chooseFamily(family) } label: {
            Text(label).font(Theme.mono(11, weight: selected ? .medium : .regular)).foregroundStyle(selected ? Theme.ink : Theme.muted)
                .padding(.horizontal, 9).frame(height: Theme.controlXs)
                .background(selected ? Theme.raised : .clear, in: RoundedRectangle(cornerRadius: Theme.radiusSm, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: Theme.radiusSm, style: .continuous).strokeBorder(selected ? Theme.input : .clear, lineWidth: 1))
                .contentShape(Rectangle())
        }.buttonStyle(.plain).pointingHand().accessibilityAddTraits(selected ? .isSelected : [])
    }

    // MARK: - Table

    private func columns(_ mainWidth: CGFloat) -> [NativeResultsMeasure] {
        let all: [NativeResultsMeasure] = [.ttft, .decode, .context, .gap, .reliability]
        if mainWidth >= 640 { return all }
        // The chosen measure always keeps its column.
        return all.filter { $0 == measure || $0 == .ttft || $0 == .reliability }
    }

    private func table(cells: [NativeResultCell], mainWidth: CGFloat) -> some View {
        let measure = self.measure, columns = columns(mainWidth)
        let meterWidth: CGFloat = mainWidth >= 760 ? 96 : 0
        let readings = cells.compactMap(measure.value)
        let best = measure.lowerIsBetter ? readings.min() ?? 0 : readings.max() ?? 0
        let winner = history ? nil : NativeResultCell.winner(cells)?.0.id
        return VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 0) {
                Text("Model").frame(maxWidth: .infinity, alignment: .leading)
                ForEach(columns, id: \.self) { column in
                    Button { ranking = column.rawValue } label: {
                        HStack(spacing: 3) {
                            if column == measure { NativeIcon(column.lowerIsBetter ? "arrow-up" : "arrow-down", size: 10) }
                            Text(column.column(browser: browser, history: history)).lineLimit(1)
                        }.foregroundStyle(column == measure ? Theme.ink : Theme.muted)
                            .frame(width: column.width, alignment: .trailing).contentShape(Rectangle())
                    }.buttonStyle(.plain).pointingHand()
                        .help("Order by " + column.title(browser: browser).lowercased())
                        .accessibilityAddTraits(column == measure ? .isSelected : [])
                }
            }.font(Theme.ui(11, weight: .medium)).foregroundStyle(Theme.muted).frame(height: 36).padding(.horizontal, margin)
            LazyVStack(spacing: 0) {
                ForEach(Array(cells.enumerated()), id: \.element.id) { index, cell in
                    NativeBoardRow(selected: selected == cell.id, margin: margin, height: 44) { selected = selected == cell.id ? nil : cell.id } content: {
                        HStack(spacing: 9) {
                            RoundedRectangle(cornerRadius: 1).fill(Theme.pairColor(cell.id)).frame(width: 3, height: 24)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(cell.short).font(Theme.mono(12)).foregroundStyle(Theme.ink).lineLimit(1).truncationMode(.middle)
                                Text(cell.value["provider_name"].string + (cell.browser ? " · browser" : "")).font(Theme.ui(11)).foregroundStyle(Theme.muted).lineLimit(1)
                            }
                            if winner == cell.id {
                                NativeIcon("trophy", size: 12).foregroundStyle(Theme.accent)
                                    .help("Best on the most headline measures in this run").accessibilityLabel("Leads this run")
                            }
                            if !cell.value["last_error"].isNull {
                                NativeIcon("triangle-alert", size: 12).foregroundStyle(Theme.warnFg)
                                    .help(Self.problem(cell)).accessibilityLabel("Last problem: " + Self.problem(cell))
                            }
                        }.help(cell.value["model"].string).layoutPriority(1)
                        Spacer(minLength: 12)
                        if meterWidth > 0 {
                            NativeTickMeter(fraction: fraction(measure.value(cell), best: best, lower: measure.lowerIsBetter), color: Theme.ink, height: 8)
                                .frame(width: meterWidth).padding(.trailing, 4)
                        }
                        ForEach(columns, id: \.self) { column in
                            Text(column.text(cell)).font(Theme.num(Theme.textSm, weight: column == measure ? .semibold : .regular))
                                .foregroundStyle(column == .reliability && (cell.reliability ?? 100) < 90 ? Theme.warnFg : column == measure ? Theme.ink : Theme.dim)
                                .lineLimit(1).frame(width: column.width, alignment: .trailing)
                        }
                    }.nativeEntrance(.row, delay: 0.03 + Double(min(index, 12)) * NativeMotion.stagger)
                }
            }
            Theme.rule.frame(height: 1).padding(.horizontal, margin)
        }
    }
    /// Share of the best reading. For a time, the shortest fills the scale.
    private func fraction(_ value: Double?, best: Double, lower: Bool) -> Double {
        guard let value, value > 0, best > 0 else { return 0 }
        return min(1, lower ? best / value : value / best)
    }

    // MARK: - Runs

    private var runList: some View {
        let runs = state.payload["runs"].array, viewing = state.payload["scope"].string
        return VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 14) {
                Text("Started").frame(width: 150, alignment: .leading)
                Text("Depth").frame(width: 84, alignment: .leading)
                Text("Targets").frame(width: 70, alignment: .leading)
                Text("Took").frame(maxWidth: .infinity, alignment: .leading)
                Text("Passed").frame(width: 60, alignment: .trailing)
                Text("Failed").frame(width: 60, alignment: .trailing)
            }.font(Theme.ui(11, weight: .medium)).foregroundStyle(Theme.muted).frame(height: 36).padding(.horizontal, margin).padding(.top, 8)
            LazyVStack(spacing: 0) {
                ForEach(Array(runs.enumerated()), id: \.element["id"]) { index, run in
                    let id = run["id"].string
                    NativeBoardRow(selected: viewing == id, margin: margin, height: 40) { state.choose(id); showRuns = false; host?.select(state.tab) } content: {
                        HStack(spacing: 14) {
                            Text(runStamp(run)).font(Theme.num(Theme.textSm, weight: .medium)).foregroundStyle(Theme.ink).frame(width: 150, alignment: .leading)
                            Text(run["tier"].string).font(Theme.mono(11)).foregroundStyle(Theme.dim).frame(width: 84, alignment: .leading)
                            Text("\(run["pairs"].array.count)").font(Theme.num(Theme.textSm, weight: .regular)).foregroundStyle(Theme.dim).frame(width: 70, alignment: .leading)
                            Text(runDuration(run)).font(Theme.num(Theme.textSm, weight: .regular)).foregroundStyle(Theme.muted).frame(maxWidth: .infinity, alignment: .leading)
                            Text("\(run["ok"].int)").font(Theme.num(Theme.textSm, weight: .regular)).foregroundStyle(Theme.ink).frame(width: 60, alignment: .trailing)
                            Text("\(run["err"].int)").font(Theme.num(Theme.textSm, weight: .regular)).foregroundStyle(run["err"].int > 0 ? Theme.failFg : Theme.faint).frame(width: 60, alignment: .trailing)
                        }
                    }.help("Open the results of run " + id).nativeEntrance(.row, delay: 0.03 + Double(min(index, 12)) * NativeMotion.stagger)
                }
            }
            Theme.rule.frame(height: 1).padding(.horizontal, margin)
        }
    }

    // MARK: - Pane

    private func paneHeader(_ title: String, _ caption: String, mono: Bool = false, clear: (() -> Void)? = nil) -> some View {
        HStack(alignment: .top, spacing: 8) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(mono ? Theme.mono(12, weight: .medium) : Theme.ui(Theme.textSm, weight: .semibold)).lineLimit(1).truncationMode(.middle)
                if !caption.isEmpty { Text(caption).font(Theme.ui(11)).foregroundStyle(Theme.muted).lineLimit(2) }
            }
            Spacer(minLength: 0)
            if let clear { T3IconButton(system: "x", help: "Clear the selection", size: 13, action: clear) }
        }.padding(.horizontal, 16).padding(.vertical, 14).frame(minHeight: 56, alignment: .top)
    }

    /// The run or history the page is showing.
    @ViewBuilder private func scopePane(_ cells: [NativeResultCell]) -> some View {
        let runs = state.payload["runs"].array, run = runs.first { $0["id"].string == state.payload["scope"].string }
        paneHeader(history ? "All-time best" : run.map(runStamp) ?? scopeLabel,
                   history ? "\(runs.count) \(runs.count == 1 ? "run" : "runs")" : run.map { $0["tier"].string + " · " + runDuration($0) } ?? "")
        NativePaneSection(title: "Tests") {
            NativePaneFact(label: "Targets", value: "\(cells.count)")
            NativePaneFact(label: "Passed", value: "\(cells.reduce(0) { $0 + $1.value["ok_count"].int })")
            let failed = cells.reduce(0) { $0 + $1.value["err_count"].int }
            NativePaneFact(label: "Failed", value: "\(failed)", tone: failed > 0 ? Theme.failFg : Theme.ink)
        }
        if !history, let award = NativeResultCell.winner(cells) {
            NativePaneSection(title: "Leads \(award.1) of 4 measures") {
                NativePaneFact(label: award.0.value["provider_name"].string, value: award.0.short, mono: true)
            }
        }
        if !state.usage.isNull {
            NativePaneSection(title: "Tokens spent, every run") {
                NativePaneFact(label: "Input", value: NativeNumberFormat.compact(state.usage["input"].double))
                NativePaneFact(label: "Cached, inside input", value: NativeNumberFormat.compact(state.usage["cached"].double))
                NativePaneFact(label: "Output", value: NativeNumberFormat.compact(state.usage["output"].double))
                NativePaneFact(label: "Calls with estimated counts", value: NativeNumberFormat.compact(state.usage["estimated"].double))
            }
        }
        if history || cells.contains(where: \.browser) {
            NativePaneSection(title: "Records") {
                if history { note("Each figure can come from a different run. Reliability counts every test.") }
                if cells.contains(where: \.browser) { note(BenchmarkMath.browserNote) }
            }
        }
        rawSection(state.raw.filter { state.family.isEmpty || BenchmarkMath.family($0["model"].string) == state.family })
    }

    /// One target: every measure with its spread, and where it failed.
    @ViewBuilder private func targetPane(_ cell: NativeResultCell) -> some View {
        let latency = cell.value["latency"]
        paneHeader(cell.short, cell.value["provider_name"].string + (cell.browser ? " · browser, estimated tokens" : ""), mono: true) { selected = nil }
        NativePaneSection(title: browser ? "First response" : "First token") {
            NativePaneFact(label: "Median", value: nativeBenchReading(cell.ttft, format: nativeBenchMilliseconds))
            if latency["n"].int > 1 {
                NativePaneFact(label: "Fastest", value: nativeBenchReading(BenchmarkMath.number(latency["ttft_min_ms"]), format: nativeBenchMilliseconds))
                NativePaneFact(label: "Slowest", value: nativeBenchReading(BenchmarkMath.number(latency["ttft_max_ms"]), format: nativeBenchMilliseconds))
                NativePaneFact(label: "Samples", value: "\(latency["n"].int)")
            }
            sourceLink(cell, "latency")
        }
        NativePaneSection(title: "Output") {
            NativePaneFact(label: "Speed", value: NativeResultsMeasure.decode.text(cell))
            NativePaneFact(label: history ? "Pause p95 at best speed" : "Pause p95", value: nativeBenchReading(cell.gap, format: nativeBenchMilliseconds))
            if let longest = BenchmarkMath.number(cell.value["maxout"]["generated"]) {
                NativePaneFact(label: "Longest answer", value: NativeNumberFormat.compact(longest) + " tokens")
            }
            sourceLink(cell, "throughput")
        }
        NativePaneSection(title: "Input") {
            NativePaneFact(label: "Largest accepted", value: NativeResultsMeasure.context.text(cell))
            NativePaneFact(label: "Limit", value: cell.input == nil ? "—" : cell.capped ? "Found" : "Not reached")
            sourceLink(cell, "context")
        }
        NativePaneSection(title: "Reliability") {
            NativePaneFact(label: "Passed", value: "\(cell.value["ok_count"].int) of \(cell.value["ok_count"].int + cell.value["err_count"].int)",
                           tone: (cell.reliability ?? 100) < 90 ? Theme.warnFg : Theme.ink)
            if !cell.value["last_error"].isNull { NativePaneFact(label: "Last problem", value: Self.problem(cell), tone: Theme.warnFg) }
        }
        if let spent = state.usage["pairs"].array.first(where: { $0["provider"].string + "|" + $0["model"].string == cell.id }) {
            NativePaneSection(title: "Tokens spent, every run") {
                NativePaneFact(label: "Input", value: NativeNumberFormat.compact(spent["input"].double))
                NativePaneFact(label: "Output", value: NativeNumberFormat.compact(spent["output"].double))
                NativePaneFact(label: "Calls", value: "\(spent["calls"].int)")
            }
        }
        rawSection(state.raw.filter { $0["provider"].string + "|" + $0["model"].string == cell.id })
    }

    private func note(_ text: String) -> some View {
        Text(text).font(Theme.ui(11)).foregroundStyle(Theme.muted).lineSpacing(2).fixedSize(horizontal: false, vertical: true)
    }
    @ViewBuilder private func sourceLink(_ cell: NativeResultCell, _ metric: String) -> some View {
        if history, !cell.source(metric).isEmpty {
            Button("Open the run it comes from") { state.choose(cell.source(metric)) }.buttonStyle(.link).font(Theme.ui(11)).pointingHand()
        }
    }
    @ViewBuilder private func rawSection(_ rows: [JSONValue]) -> some View {
        if !rows.isEmpty {
            NativePaneSection(title: "") {
                NativeDisclosure("Raw measurements", detail: "\(rows.count)") {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                            NativeDisclosure(rawTitle(row), tone: row["ok"].bool ? Theme.dim : Theme.failFg) {
                                Text(String(decoding: (try? row.encoded(pretty: true)) ?? Data(), as: UTF8.self)).font(Theme.mono(10)).foregroundStyle(Theme.dim).textSelection(.enabled)
                                    .frame(maxWidth: .infinity, alignment: .leading).padding(10)
                                    .background(Theme.sunken, in: RoundedRectangle(cornerRadius: Theme.radiusSm, style: .continuous))
                            }
                        }
                    }
                }
            }
        }
    }
    private static func problem(_ cell: NativeResultCell) -> String {
        guard !cell.value["last_error"].isNull else { return "" }
        let problem = cell.value["last_error"], test = problem["test"].string
        let label = cell.browser && problem["class"].string == "auth" ? "browser sign-in required" : problem["class"].string.replacingOccurrences(of: "_", with: " ")
        return label + (test.isEmpty ? "" : " (" + test + ")")
    }

    private var paneActions: some View {
        HStack(spacing: 8) {
            Menu {
                Button("Summary table in scope") { Task { await state.export(summary: true) } }
                Button("Every test row in scope") { Task { await state.export(summary: false) } }
                if state.scope != "all" {
                    Divider()
                    Button("All-time best summary") { Task { await state.export(summary: true, allRuns: true) } }
                    Button("All runs: every test row") { Task { await state.export(summary: false, allRuns: true) } }
                }
            } label: { NativeResultsMenuLabel(title: "Export CSV", icon: "download") }
                .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize().disabled(state.busy || state.payload.isNull)
                .accessibilityLabel("Export CSV")
            Spacer(minLength: 0)
        }.padding(.horizontal, 16).padding(.vertical, 10).overlay(alignment: .top) { Theme.rule.frame(height: 1) }
    }

    // MARK: - Bar

    private var headerActions: some View {
        HStack(spacing: 6) {
            scopeControl
            T3IconButton(system: "refresh-cw", help: "Reload results") { Task { await state.load() } }
        }.fixedSize(horizontal: true, vertical: false)
    }
    private var scopeControl: some View {
        Menu {
                Button("Latest run") { state.choose("latest") }; Button("All-time best") { state.choose("all") }; Divider()
                ForEach(state.payload["runs"].array, id: \.self["id"]) { run in Button(runStamp(run) + " · " + run["tier"].string) { state.choose(run["id"].string) }.help(run["id"].string) }
        } label: { NativeResultsMenuLabel(title: scopeLabel, maximumTextWidth: 170) }
            .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
            .help(scopeLabel).accessibilityLabel("Result scope: " + scopeLabel)
    }
    private var scopeLabel: String { state.scope == "all" ? "All-time best" : state.scope == "latest" ? "Latest run" : state.scope }
    private func runStamp(_ run: JSONValue) -> String {
        let started = BenchmarkMath.timestamp(run["started"].string)
        return started.isFinite && started > 0 ? NativeListTimeFormat.stamp(Date(timeIntervalSince1970: started)) : run["id"].string
    }
    private func runDuration(_ run: JSONValue) -> String {
        let started = BenchmarkMath.timestamp(run["started"].string), finished = BenchmarkMath.timestamp(run["finished"].string)
        guard started.isFinite, finished.isFinite, started > 0, finished > 0 else { return NativeListTimeFormat.duration(0) }
        return NativeListTimeFormat.duration(max(0, (finished - started) * 1000))
    }
    private func rawTitle(_ row: JSONValue) -> String {
        [row["model"].string, row["test"].string, row["ok"].bool ? "ok" : row["error_class"].string].joined(separator: " · ")
    }
}

private struct NativeResultsMenuLabel: View {
    let title: String
    var icon: String? = nil
    var maximumTextWidth: CGFloat? = nil
    var body: some View {
        HStack(spacing: 5) {
            if let icon { NativeIcon(icon, size: 12) }
            Text(title).lineLimit(1).truncationMode(.middle)
                .frame(maxWidth: maximumTextWidth, alignment: .leading)
            if icon == nil { NativeIcon("chevron-down", size: 12) }
        }.font(Theme.ui(12, weight: .medium)).foregroundStyle(Theme.dim)
            .lineLimit(1).padding(.horizontal, 10).frame(height: Theme.control)
            .background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.radiusMd, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: Theme.radiusMd, style: .continuous).strokeBorder(Theme.input, lineWidth: 1))
            .alignmentGuide(.firstTextBaseline) { _ in 18 }
            .alignmentGuide(.lastTextBaseline) { _ in 18 }
    }
}

struct NativeResultCell: Identifiable {
    var id: String, value: JSONValue
    var short: String { value["model"].string.split(separator: "/").last.map(String.init) ?? value["model"].string }
    var browser: Bool { value["transport"] == "browser" }
    var estimated: Bool { browser || value["tokens_estimated"].bool }
    var ttft: Double? { BenchmarkMath.number(value["latency"]["ttft_med_ms"]) }
    var speed: Double? { BenchmarkMath.number(value["throughput"]["decode_tps"]) }
    var input: Double? { BenchmarkFold.largestInput(value) }
    var gap: Double? { BenchmarkMath.number(value["throughput"]["gap_p95_ms"]) }
    var reliability: Double? { let total = value["ok_count"].double + value["err_count"].double; return total > 0 ? value["ok_count"].double * 100 / total : nil }
    var capped: Bool { !value["max_context"]["min_fail"].isNull || value["ctx"].object.contains { !$0.value["ok"].bool && ($0.key.doubleValue ?? 0) > (input ?? 0) } }
    func source(_ metric: String) -> String { value["history"]["sources"][metric].string }
    static func winner(_ cells: [NativeResultCell]) -> (NativeResultCell, Int)? {
        guard cells.count > 1 else { return nil }
        let leaders = [cells.filter { $0.ttft != nil }.min { $0.ttft! < $1.ttft! }, cells.filter { $0.speed != nil }.max { $0.speed! < $1.speed! }, cells.filter { $0.input != nil }.max { $0.input! < $1.input! }, cells.filter { $0.reliability != nil }.max { $0.reliability! < $1.reliability! }].compactMap { $0 }
        let counts = Dictionary(grouping: leaders, by: \.id).mapValues(\.count)
        guard let winner = cells.max(by: { a, b in let av = counts[a.id] ?? 0, bv = counts[b.id] ?? 0; if av != bv { return av < bv }; if a.reliability != b.reliability { return (a.reliability ?? 0) < (b.reliability ?? 0) }; return (a.ttft ?? .greatestFiniteMagnitude) > (b.ttft ?? .greatestFiniteMagnitude) }), let count = counts[winner.id] else { return nil }
        return (winner, count)
    }
}

private extension String { var doubleValue: Double? { Double(self) } }
func nativeBenchMilliseconds(_ value: Double) -> String { value >= 1000 ? String(format: value >= 10_000 ? "%.0f s" : "%.1f s", value / 1000) : String(format: "%.0f ms", value) }
func nativeBenchTokens(_ value: Double) -> String {
    guard value.isFinite else { return "—" }
    if value >= 1_000_000 { return String(format: "%.2fM", value / 1_000_000) }
    if value >= 1000 { return String(format: "%.0fk", floor(value / 1000 + 0.5)) }
    return String(format: "%.0f", floor(value + 0.5))
}
func nativeBenchReading(_ value: Double?, format: (Double) -> String = NativeNumberFormat.compact) -> String { value.map(format) ?? "—" }
