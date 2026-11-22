import SwiftUI
import AppKit
import UniApiCore
import UniApiPresentation

struct NativeResultsPage: View {
    let runtime: NativeRuntime
    @StateObject private var state: NativeResultsModel
    @State private var showUsage = false
    @Environment(\.nativeInterfaceDensity) private var density
    @AppStorage("uniapi.rank.metric") private var ranking = "ttft"
    init(runtime: NativeRuntime, initialRun: String? = nil) { self.runtime = runtime; _state = StateObject(wrappedValue: NativeResultsModel(runtime: runtime, initialRun: initialRun)) }
    private var cells: [NativeResultCell] { state.payload["cells"].object.map { NativeResultCell(id: $0.key, value: $0.value) }.filter { state.family.isEmpty || $0.value["family"] == .string(state.family) }.sorted {
        let a = $0.ttft ?? .infinity, b = $1.ttft ?? .infinity
        return a == b ? $0.id < $1.id : a < b
    } }
    private var history: Bool { state.payload["aggregation"] == "best" }
    @State private var showRuns = false
    private var families: [String] { Array(Set(state.payload["cells"].object.values.map { $0["family"].string })).sorted() }
    var body: some View {
        GeometryReader { geometry in
        let contentWidth = max(0, min(Theme.contentWidth, geometry.size.width) - 2 * density.pageMargin)
        NativePage(title: "Results", readiness: state.busy ? .pending : !state.error.isEmpty ? .failed : state.payload.isNull ? .pending : .ready, tabs: {
            NativeTabs(options: [("table", "Table"), ("charts", "Charts"), ("runs", "Runs")], selection: showRuns ? "runs" : state.tab,
                       counts: ["runs": state.payload["runs"].array.count]) { tab in
                if tab == "runs" { showRuns = true } else { showRuns = false; state.chooseTab(tab) }
            }
        }, actions: { headerActions }) {
            if !state.error.isEmpty { NativeError(message: state.error) }
            if state.busy || state.payload.isNull {
                if state.error.isEmpty { ShimmerText(text: "Loading…", font: Theme.ui(12)) }
            }
            else if showRuns { runList }
            else if cells.isEmpty {
                NativeEmptyState(title: "No results in this scope", detail: "Select models on Speed and start a run.", icon: "chart-bar",
                                 actionTitle: "Benchmark", actionIcon: "gauge") {
                    NotificationCenter.default.post(name: .nativeNavigation, object: NativeDestination.speed)
                }
            }
            else {
                VStack(alignment: .leading, spacing: 12) {
                    headlineTiles(width: contentWidth)
                    HStack(alignment: .center, spacing: 14) {
                        if !history, let award = NativeResultCell.winner(cells) {
                            NativeResultsAward(cell: award.0, wins: award.1).id(award.0.id).fixedSize(horizontal: true, vertical: false)
                        }
                        if history { Text("Each figure can come from a different run. Reliability counts every test.").font(Theme.ui(12)).foregroundStyle(Theme.muted).lineLimit(2) }
                        Spacer(minLength: 0)
                        if families.count > 1 {
                            NativeScrollRail {
                                familyButton("", label: "All")
                                ForEach(families, id: \.self) { family in familyButton(family, label: family) }
                            }
                        }
                    }
                    if cells.contains(where: \.browser) { Text(BenchmarkMath.browserNote).font(Theme.ui(12)).foregroundStyle(Theme.muted) }
                }
                if state.tab == "charts" { rankingBoard; NativeResultsCharts(cells: cells, rows: state.curves, history: history, open: state.choose) }
                else { NativeResultsComparison(cells: cells, history: history, availableWidth: contentWidth, open: state.choose) }
                let raw = state.raw.filter { state.family.isEmpty || BenchmarkMath.family($0["model"].string) == state.family }
                if !raw.isEmpty {
                    NativeDisclosure("Raw measurements", detail: "\(raw.count)") {
                        LazyVStack(alignment: .leading, spacing: 0) {
                            ForEach(Array(raw.enumerated()), id: \.offset) { _, row in
                                NativeDisclosure(rawTitle(row), tone: row["ok"].bool ? Theme.dim : Theme.failFg) {
                                    Text(String(decoding: (try? row.encoded(pretty: true)) ?? Data(), as: UTF8.self)).font(Theme.mono(10)).foregroundStyle(Theme.dim).textSelection(.enabled)
                                        .frame(maxWidth: .infinity, alignment: .leading).padding(12)
                                        .background(Theme.sunken, in: RoundedRectangle(cornerRadius: Theme.radiusMd, style: .continuous))
                                }
                            }
                        }
                    }
                }
            }
        }
        }
        .nativePageTask { await state.begin(runtime: runtime) }.nativePageActivity(suspended: { state.stop() })
        .sheet(isPresented: $showUsage) { NativeResultsUsage(value: state.usage) }
    }
    @ViewBuilder private var runList: some View {
        let runs = state.payload["runs"].array
        if runs.isEmpty {
            NativeEmptyState(title: "No runs", detail: "Select models on Speed and start a run.", icon: "chart-bar", actionTitle: "Benchmark", actionIcon: "gauge") {
                NotificationCenter.default.post(name: .nativeNavigation, object: NativeDestination.speed)
            }
        } else {
            Card(padding: 0) { LazyVStack(spacing: 0) {
                ForEach(Array(runs.enumerated()), id: \.element["id"]) { index, run in
                    if index > 0 { Theme.rule.frame(height: 1) }
                    NativeResultsRunRow(stamp: runStamp(run), tier: run["tier"].string, pairs: run["pairs"].array.count, duration: runDuration(run),
                                        ok: run["ok"].int, failed: run["err"].int, viewing: state.payload["scope"].string == run["id"].string, id: run["id"].string) {
                        state.choose(run["id"].string); showRuns = false
                    }
                }
            } }
        }
    }
    private var headerActions: some View {
        HStack(spacing: 6) {
            scopeControl
            exportControl
            T3IconButton(system: "database", help: "Token usage") { Task { await state.loadUsage(); showUsage = true } }
            T3IconButton(system: "refresh-cw", help: "Reload results") { Task { await state.load() } }
        }.fixedSize(horizontal: true, vertical: false)
    }
    private var exportControl: some View {
        Menu {
                Button("Summary table in scope") { Task { await state.export(summary: true) } }; Button("Every test row in scope") { Task { await state.export(summary: false) } }
                if state.scope != "all" { Divider(); Button("All-time best summary") { Task { await state.export(summary: true, allRuns: true) } }; Button("All runs: every test row") { Task { await state.export(summary: false, allRuns: true) } } }
        } label: { NativeIcon("upload", size: 15).foregroundStyle(Theme.muted).frame(width: Theme.control, height: Theme.control).contentShape(Rectangle()) }
            .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize().disabled(state.busy || state.payload.isNull)
            .help("Export CSV").accessibilityLabel("Export CSV")
    }
    private var scopeControl: some View {
        Menu {
                Button("Latest run") { state.choose("latest") }; Button("All-time best") { state.choose("all") }; Divider()
                ForEach(state.payload["runs"].array, id: \.self["id"]) { run in Button(runStamp(run) + " · " + run["tier"].string) { state.choose(run["id"].string) }.help(run["id"].string) }
        } label: { NativeResultsMenuLabel(title: scopeLabel, maximumTextWidth: 170) }
            .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
            .help(scopeLabel).accessibilityLabel("Result scope: " + scopeLabel)
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
    private var rankingBoard: some View {
        let lower = ["ttft", "gap"].contains(ranking)
        let measured = cells.filter { rankingValue($0) != nil }.sorted {
            let a = rankingValue($0)!, b = rankingValue($1)!
            return a == b ? $0.id < $1.id : lower ? a < b : a > b
        }
        return NativeCard {
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .top, spacing: 16) { rankingHeading; Spacer(minLength: 8); rankingOptions }
                VStack(alignment: .leading, spacing: 10) { rankingHeading; rankingOptions }
            }
            NativeRankingChart(rows: measured.map { cell in
                NativeRankEntry(id: cell.id, title: cell.short, detail: cell.value["provider_name"].string, value: rankingValue(cell), low: ranking == "ttft" ? BenchmarkMath.number(cell.value["latency"]["ttft_min_ms"]) : nil, high: ranking == "ttft" ? BenchmarkMath.number(cell.value["latency"]["ttft_max_ms"]) : nil, color: Theme.pairColor(cell.id))
            }, lowerIsBetter: lower, fixedMaximum: ranking == "reliability" ? 100 : nil, format: { value in
                ["ttft", "gap"].contains(ranking) ? nativeBenchMilliseconds(value) : ranking == "decode" ? String(format: "%.2f tok/s", value) : ranking == "reliability" ? String(format: "%.0f%%", value) : nativeBenchTokens(value)
            })
            if history {
                NativeScrollRail { ForEach(measured) { cell in
                    let metric = ranking == "ttft" ? "latency" : ranking == "context" ? "context" : "throughput"
                    if ranking != "reliability", !cell.source(metric).isEmpty { Button(cell.short + ": View run") { state.choose(cell.source(metric)) }.buttonStyle(.link).font(Theme.ui(10)) }
                } }
            }
        }
    }
    private var rankingHeading: some View { NativeChartHeading(title: "Ranking") }
    private var rankingOptions: some View { T3Segmented(options: [("ttft", cells.contains(where: \.browser) ? "First response" : "First token"), ("decode", "Output speed"), ("context", "Max input"), ("reliability", "Reliability"), ("gap", "Worst pause")], selection: ranking) { ranking = $0 } }
    private func rankingValue(_ cell: NativeResultCell) -> Double? {
        switch ranking { case "decode": return cell.speed; case "context": return cell.input; case "reliability": return cell.reliability; case "gap": return cell.gap; default: return cell.ttft }
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
        [row["provider_name"].string, row["model"].string, row["test"].string, row["ok"].bool ? "ok" : row["error_class"].string].joined(separator: " · ")
    }
    private func headlineTiles(width: CGFloat) -> some View {
        let first = cells.filter { $0.ttft != nil }.min { $0.ttft! < $1.ttft! }, speed = cells.filter { $0.speed != nil }.max { $0.speed! < $1.speed! }, input = cells.filter { $0.input != nil }.max { $0.input! < $1.input! }, reliable = cells.filter { $0.reliability != nil }.max { $0.reliability! < $1.reliability! }
        return NativeReadoutStrip(minCell: 190) {
            tile(cells.contains(where: \.browser) ? "First response" : "First token", cell: first, value: first?.ttft, format: nativeBenchMilliseconds, metric: "latency")
            tile("Output speed", cell: speed, value: speed?.speed, format: { String(format: "%.1f", $0) }, unit: "tok/s", metric: "throughput")
            tile("Largest input", cell: input, value: input?.input, format: nativeBenchTokens, unit: "tokens", metric: "context")
            tile("Reliability", cell: reliable, value: reliable?.reliability, format: { String(format: "%.0f%%", $0) }, metric: nil)
        }
    }
    private func tile(_ label: String, cell: NativeResultCell?, value: Double?, format: @escaping (Double) -> String, unit: String = "", metric: String?) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(label).font(Theme.ui(Theme.textXs, weight: .medium)).foregroundStyle(Theme.muted).lineLimit(1)
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                NativeNumberText(text: value.map { (cell?.estimated == true && (metric == "throughput" || metric == "context") ? "~" : "") + format($0) + (metric == "context" && cell?.capped == false ? "+" : "") } ?? "—", font: Theme.num(26))
                    .tracking(Theme.tracking(26))
                if !unit.isEmpty, value != nil { Text(unit).font(Theme.ui(Theme.textXs, weight: .medium)).foregroundStyle(Theme.muted) }
            }.padding(.top, 10)
            HStack(spacing: 6) {
                if let cell { RoundedRectangle(cornerRadius: 1).fill(Theme.pairColor(cell.id)).frame(width: 3, height: 11) }
                Text(cell?.short ?? "No data").font(Theme.mono(11)).foregroundStyle(Theme.dim).lineLimit(1).truncationMode(.middle)
            }.padding(.top, 8).help(cell.map { $0.value["model"].string + " on " + $0.value["provider_name"].string } ?? "")
            HStack(spacing: 8) {
                Text(cell?.value["provider_name"].string ?? "").font(Theme.ui(11)).foregroundStyle(Theme.muted).lineLimit(1)
                if let cell, let metric, !cell.source(metric).isEmpty { Button("View run") { state.choose(cell.source(metric)) }.buttonStyle(.link).font(Theme.ui(11)).pointingHand() }
            }.padding(.top, 3)
        }.padding(16 * density.cardScale).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

private struct NativeResultsRunRow: View {
    let stamp: String, tier: String, pairs: Int, duration: String, ok: Int, failed: Int, viewing: Bool, id: String
    let action: () -> Void
    @State private var hovering = false
    var body: some View {
        Button(action: action) {
            HStack(spacing: 14) {
                Text(stamp).font(Theme.num(13, weight: .medium)).foregroundStyle(Theme.ink).frame(width: 150, alignment: .leading)
                MonoChip(text: tier).frame(width: 84, alignment: .leading)
                Text("\(pairs) \(pairs == 1 ? "pair" : "pairs")").font(Theme.ui(12)).foregroundStyle(Theme.dim).frame(width: 70, alignment: .leading)
                Text(duration).font(Theme.num(12, weight: .regular)).foregroundStyle(Theme.muted).frame(width: 80, alignment: .leading)
                Spacer(minLength: 8)
                StatCount(count: ok, label: "ok", color: Theme.okFg)
                StatCount(count: failed, label: "failed", color: Theme.failFg)
                Group {
                    if viewing { NativeStatus(text: "Viewing", tone: .ok) }
                    else { HStack(spacing: 5) { Text("View"); NativeIcon("arrow-right", size: 12).offset(x: hovering ? 3 : 0) }.font(Theme.ui(12, weight: .medium)).foregroundStyle(hovering ? Theme.ink : Theme.faint) }
                }.frame(width: 76, alignment: .trailing)
            }.padding(.horizontal, 16).frame(minHeight: 44).contentShape(Rectangle()).nativeRowHover(hovering, selected: viewing)
        }.buttonStyle(.plain).pointingHand().onHover { hovering = $0 }.help("View run " + id)
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

private struct NativeResultsComparison: View {
    let cells: [NativeResultCell], history: Bool, availableWidth: CGFloat, open: (String) -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
        Card(padding: 0) {
            ScrollView(.horizontal) {
                VStack(spacing: 0) {
                    HStack(spacing: 16) {
                        Text("Model").frame(minWidth: 150, maxWidth: .infinity, alignment: .leading)
                        Text(cells.contains(where: \.browser) ? "First response" : "First token").frame(width: 96, alignment: .leading)
                        Text(cells.contains(where: \.browser) ? "Output speed" : history ? "Best run speed" : "Decode").frame(width: 106, alignment: .leading)
                        Text("Max input").frame(width: 84, alignment: .leading)
                        Text(history ? "Gap at best speed" : "Gap p95").frame(width: 80, alignment: .leading)
                        Text("Reliability").frame(width: 106, alignment: .leading)
                        Text("Last problem").frame(minWidth: 130, maxWidth: .infinity, alignment: .leading)
                    }.font(Theme.ui(11, weight: .medium)).foregroundStyle(Theme.muted).padding(.horizontal, 16).frame(height: 34)
                    Theme.border.frame(height: 1).nativeEntrance(.rule)
                    ForEach(Array(cells.enumerated()), id: \.element.id) { index, cell in
                        if index > 0 { Theme.rule.frame(height: 1) }
                        NativeResultsRow(cell: cell, index: index, open: open).nativeEntrance(.row, delay: 0.05 + Double(index) * NativeMotion.stagger)
                    }
                }.frame(width: max(876, availableWidth))
            }.scrollIndicators(.visible)
                .accessibilityHint("Scroll horizontally to inspect all result columns, including Last problem.")
        }
        }
    }
}

private struct NativeResultsRow: View {
    let cell: NativeResultCell, index: Int, open: (String) -> Void
    @State private var hovering = false
    @Environment(\.nativeReducedMotion) private var reduceMotion
    var body: some View {
        HStack(alignment: .center, spacing: 16) {
            HStack(spacing: 9) { RoundedRectangle(cornerRadius: 1).fill(Theme.pairColor(cell.id)).frame(width: 3, height: 24); VStack(alignment: .leading, spacing: 2) { Text(cell.short).font(Theme.mono(12)).lineLimit(1).help(cell.value["model"].string); Text(cell.value["provider_name"].string + (cell.browser ? " · browser, estimated tokens" : "")).font(Theme.ui(11)).foregroundStyle(Theme.muted).lineLimit(1) } }.frame(minWidth: 150, maxWidth: .infinity, alignment: .leading)
            reading(nativeBenchReading(cell.ttft, format: nativeBenchMilliseconds), column: 0, source: cell.source("latency"), detail: cell.browser ? "visible text" : cell.value["latency"]["n"].int > 1 ? "\(nativeBenchReading(BenchmarkMath.number(cell.value["latency"]["ttft_min_ms"]), format: nativeBenchMilliseconds)) – \(nativeBenchReading(BenchmarkMath.number(cell.value["latency"]["ttft_max_ms"]), format: nativeBenchMilliseconds))" : "")
            reading(nativeBenchReading(cell.speed, format: { (cell.estimated ? "~" : "") + String(format: "%.2f tok/s", $0) }), column: 1, source: cell.source("throughput"), detail: cell.browser ? "visible updates" : "")
            reading(nativeBenchReading(cell.input, format: { (cell.estimated ? "~" : "") + nativeBenchTokens($0) + (cell.capped ? "" : "+") }), column: 2, source: cell.source("context"))
            reading(nativeBenchReading(cell.gap, format: nativeBenchMilliseconds), column: 3, detail: cell.browser ? "text updates" : "")
            reliability
            Text(lastProblem).font(Theme.ui(11)).foregroundStyle(cell.value["last_error"].isNull ? Theme.muted : Theme.warnFg).lineLimit(2).frame(minWidth: 130, maxWidth: .infinity, alignment: .leading).fixedSize(horizontal: false, vertical: true).help(lastProblem)
        }.padding(.horizontal, 16).padding(.vertical, 10).nativeRowHover(hovering)
        .onHover { hovering = $0 }.animation(reduceMotion ? nil : NativeMotion.hover, value: hovering)
    }
    private var lastProblem: String {
        guard !cell.value["last_error"].isNull else { return "" }
        let problem = cell.value["last_error"], test = problem["test"].string
        let label = cell.browser && problem["class"].string == "auth" ? "browser sign-in required" : problem["class"].string.replacingOccurrences(of: "_", with: " ")
        return label + (test.isEmpty ? "" : " (" + test + ")")
    }
    private var reliability: some View {
        HStack(spacing: 6) {
            StatusDot(color: (cell.reliability ?? 0) >= 90 ? Theme.okFg : (cell.reliability ?? 0) >= 60 ? Theme.warnFg : Theme.failFg, size: 6)
            NativeNumberText(text: nativeBenchReading(cell.reliability, format: { String(format: "%.0f%%", $0) }), font: Theme.num(12, weight: .medium), delay: 0.2 + Double(index) * NativeMotion.stagger)
            Text("\(cell.value["ok_count"].int)/\(cell.value["ok_count"].int + cell.value["err_count"].int)").font(Theme.num(10.5, weight: .regular)).foregroundStyle(Theme.muted).lineLimit(1).minimumScaleFactor(0.8)
        }.frame(width: 106, alignment: .leading)
    }
    private func reading(_ text: String, column: Int, source: String = "", detail: String = "") -> some View {
        VStack(alignment: .leading, spacing: 2) { NativeNumberText(text: text, font: Theme.num(12, weight: .medium), delay: 0.1 + Double(index) * NativeMotion.stagger + Double(column) * 0.03); if !detail.isEmpty { Text(detail).font(Theme.num(10.5, weight: .regular)).foregroundStyle(Theme.muted) }; if !source.isEmpty { Button("View run") { open(source) }.buttonStyle(.link).font(Theme.ui(11)).pointingHand() } }.frame(width: CGFloat([96, 106, 84, 80, 106][column]), alignment: .leading)
    }
}

private struct NativeResultsAward: View {
    let cell: NativeResultCell, wins: Int
    @Environment(\.nativeReducedMotion) private var reduceMotion
    @Environment(\.nativeMotionVisible) private var visible
    @State private var appeared = false
    @State private var finished = false
    @State private var sweep: CGFloat = -0.6
    private var status: some View {
        HStack(spacing: 6) {
            NativeIcon("trophy", size: 12).foregroundStyle(Theme.pairColor(cell.id))
                .offset(y: appeared || reduceMotion ? 0 : -3)
            Text("Leads \(wins) of 4").font(Theme.ui(11, weight: .medium)).foregroundStyle(Theme.ink)
        }
        .padding(.horizontal, 9).frame(height: Theme.controlXs)
        .background(Theme.pairColor(cell.id).opacity(0.1), in: RoundedRectangle(cornerRadius: Theme.radiusSm, style: .continuous))
        .overlay {
            if !reduceMotion && visible && !finished {
                GeometryReader { geometry in
                    LinearGradient(colors: [.clear, Theme.pairColor(cell.id).opacity(0.3), .clear], startPoint: .leading, endPoint: .trailing)
                        .frame(width: max(30, geometry.size.width * 0.45))
                        .offset(x: geometry.size.width * sweep)
                }.clipShape(RoundedRectangle(cornerRadius: Theme.radiusSm)).allowsHitTesting(false)
            }
        }
        .fixedSize(horizontal: true, vertical: false)
    }
    private var model: some View {
        Text(cell.short).font(Theme.mono(12, weight: .medium)).lineLimit(1)
    }
    private var provider: some View {
        Text(cell.value["provider_name"].string).font(Theme.ui(11)).foregroundStyle(Theme.muted).lineLimit(1)
    }
    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 10) { status; model; provider }
                .fixedSize(horizontal: true, vertical: false)
            HStack(alignment: .center, spacing: 10) {
                status
                VStack(alignment: .leading, spacing: 2) { model; provider }
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .opacity(appeared || reduceMotion ? 1 : 0)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Winner: \(cell.value["model"].string) on \(cell.value["provider_name"].string), \(wins) of 4 headline categories")
        .help("\(cell.value["model"].string) on \(cell.value["provider_name"].string) took \(wins) of the 4 headline categories in this scope")
        .task(id: cell.id + "\(reduceMotion):\(visible)") {
            if reduceMotion || !visible { NativeMotion.withoutAnimation { appeared = true; finished = true }; return }
            guard !finished else { return }
            withAnimation(.easeOut(duration: 0.4).delay(0.05)) { appeared = true }
            withAnimation(.easeInOut(duration: 1.15).delay(0.15)) { sweep = 1.2 }
            do { try await Task.sleep(nanoseconds: 1_400_000_000); NativeMotion.withoutAnimation { finished = true } } catch {}
        }
    }
}

private struct NativeResultsUsage: View {
    let value: JSONValue
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack { Text("Token usage").font(Theme.ui(Theme.textBase, weight: .semibold)); Spacer(); Button("Done") { dismiss() }.buttonStyle(T3Button(.primary)).keyboardShortcut(.cancelAction) }
            NativeReadoutStrip {
                NativeReadout(label: "Input", value: NativeNumberFormat.compact(value["input"].double), detail: "Includes cached")
                NativeReadout(label: "Output", value: NativeNumberFormat.compact(value["output"].double), detail: "Includes reasoning")
                NativeReadout(label: "Cached", value: NativeNumberFormat.compact(value["cached"].double))
                NativeReadout(label: "Estimated calls", value: NativeNumberFormat.compact(value["estimated"].double), detail: "Both histories, failed calls included")
            }
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(Array(value["pairs"].array.enumerated()), id: \.offset) { index, pair in
                        if index > 0 { Theme.rule.frame(height: 1) }
                        HStack(spacing: 14) {
                            Text(pair["model"].string).font(Theme.mono(12)).lineLimit(1).frame(maxWidth: .infinity, alignment: .leading)
                            Text(pair["provider_name"].string).font(Theme.ui(12)).foregroundStyle(Theme.muted).lineLimit(1).frame(width: 180, alignment: .leading)
                            Text(NativeNumberFormat.compact(pair["input"].double) + " in").font(Theme.num(12, weight: .regular)).frame(width: 90, alignment: .trailing)
                            Text(NativeNumberFormat.compact(pair["output"].double) + " out").font(Theme.num(12, weight: .regular)).frame(width: 90, alignment: .trailing)
                            Text("\(pair["calls"].int) calls").font(Theme.num(12, weight: .regular)).foregroundStyle(Theme.muted).frame(width: 80, alignment: .trailing)
                        }.frame(height: 34)
                    }
                }
            }
        }.padding(24).frame(width: 900, height: 600).background(Theme.bg).foregroundStyle(Theme.ink)
    }
}
