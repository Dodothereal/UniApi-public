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
    var body: some View {
        GeometryReader { geometry in
        let contentWidth = max(0, min(1500, geometry.size.width) - 2 * density.pageMargin)
        NativePage(title: "Results", subtitle: history ? "Historical records per provider and model, with links to their source runs." : cells.contains(where: \.browser) ? "One run per view. First response is a median; browser text timing and estimated tokens are labeled." : "One run per view. First token is a median; speed is the last successful throughput test.", maxWidth: 1500, readiness: state.busy ? .pending : !state.error.isEmpty ? .failed : state.payload.isNull ? .pending : .ready, actions: { headerActions }) {
            VStack(alignment: .leading, spacing: 20) {
            if !state.error.isEmpty { NativeError(message: state.error) }
            if state.busy || state.payload.isNull {
                if state.error.isEmpty { ShimmerText(text: "Loading matching result scope…", font: Theme.ui(12)) }
            }
            else if cells.isEmpty {
                VStack(spacing: 12) {
                    NativeEmptyState(title: "No results in this scope", detail: "Select models on Speed and start a run.", icon: "chart-bar")
                    Button { NotificationCenter.default.post(name: .nativeNavigation, object: NativeDestination.speed) } label: {
                        HStack(spacing: 6) { NativeIcon("gauge", size: 12); Text("Benchmark") }
                    }.buttonStyle(T3Button(.primary))
                }.frame(maxWidth: .infinity)
            }
            else {
                if history { Text("Speed and first-token records come from individual run summaries; each column can come from a different run. Reliability includes every test, including failures. Gap is measured at the recorded best speed.").font(Theme.ui(12)).foregroundStyle(Theme.muted) }
                if cells.contains(where: \.browser) { Text(BenchmarkMath.browserNote).font(Theme.ui(12)).foregroundStyle(Theme.muted) }
                VStack(alignment: .leading, spacing: 10) {
                    if !history, let award = NativeResultCell.winner(cells) {
                        NativeResultsAward(cell: award.0, wins: award.1).id(award.0.id)
                    }
                    headlineTiles(width: contentWidth)
                }
                HStack(spacing: 16) {
                    T3Segmented(options: [("table", "Table"), ("charts", "Charts")], selection: state.tab) { state.chooseTab($0) }
                    Spacer(minLength: 0)
                    NativeScrollRail {
                        familyButton("", label: "All models")
                        ForEach(Array(Set(state.payload["cells"].object.values.map { $0["family"].string })).sorted(), id: \.self) { family in familyButton(family, label: family) }
                    }
                }
                if state.tab == "charts" { rankingBoard; NativeResultsCharts(cells: cells, rows: state.curves, history: history, open: state.choose) }
                else { NativeResultsComparison(cells: cells, history: history, availableWidth: contentWidth, open: state.choose) }
                DisclosureGroup("Raw measurements, failures and transport details") {
                    ForEach(Array(state.raw.filter { state.family.isEmpty || BenchmarkMath.family($0["model"].string) == state.family }.enumerated()), id: \.offset) { _, row in
                        DisclosureGroup(rawTitle(row)) {
                            Text(String(decoding: (try? row.encoded(pretty: true)) ?? Data(), as: UTF8.self)).font(Theme.mono(10)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                }
            }
            if !state.payload["runs"].array.isEmpty {
                Rectangle().fill(Theme.border).frame(height: 1).padding(.top, 6)
                HStack { Text("Runs").font(Theme.ui(14, weight: .medium)); Spacer(); Text("\(state.payload["runs"].array.count) runs").font(Theme.ui(12)).foregroundStyle(Theme.muted) }
                Card(padding: 0) { LazyVStack(spacing: 0) {
                ForEach(state.payload["runs"].array, id: \.self["id"]) { run in
                    VStack(spacing: 0) {
                        Button { state.choose(run["id"].string) } label: {
                            HStack(spacing: 12) {
                                VStack(alignment: .leading, spacing: 3) {
                                    HStack(spacing: 7) {
                                        Text(runStamp(run)).font(Theme.mono(12)).help(run["id"].string)
                                        Text(run["tier"].string).font(Theme.mono(10)).foregroundStyle(Theme.muted).padding(.horizontal, 6).padding(.vertical, 2).background(Theme.subtle, in: RoundedRectangle(cornerRadius: Theme.radiusSm))
                                    }
                                    Text("\(run["pairs"].array.count) \(run["pairs"].array.count == 1 ? "pair" : "pairs") · took \(runDuration(run))").font(Theme.ui(12)).foregroundStyle(Theme.muted)
                                }
                                Spacer(minLength: 8)
                                StatCount(count: run["ok"].int, label: "ok", color: Theme.okFg)
                                StatCount(count: run["err"].int, label: "failed", color: Theme.failFg)
                                Text(state.payload["scope"].string == run["id"].string ? "Viewing" : "View").font(Theme.ui(12, weight: .medium)).foregroundStyle(state.payload["scope"].string == run["id"].string ? Theme.okFg : Theme.muted).frame(width: 72).padding(.vertical, 5).background(state.payload["scope"].string == run["id"].string ? Theme.okFg.opacity(0.12) : .clear, in: RoundedRectangle(cornerRadius: Theme.radiusSm)).overlay(RoundedRectangle(cornerRadius: Theme.radiusSm).strokeBorder(Theme.border, lineWidth: 1))
                            }.padding(.horizontal, 14).padding(.vertical, 10).contentShape(Rectangle())
                        }.buttonStyle(.plain).pointingHand().help("View run \(run["id"].string)")
                        if run["id"].string != state.payload["runs"].array.last?["id"].string { Rectangle().fill(Theme.border).frame(height: 1) }
                    }
                }
                } }
            }
            }
        }
        }
        .nativePageTask { await state.begin(runtime: runtime) }.nativePageActivity(suspended: { state.stop() })
        .sheet(isPresented: $showUsage) { NativeResultsUsage(value: state.usage) }
    }
    private var headerActions: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 8) { reloadControls; scopeControls }
                .fixedSize(horizontal: true, vertical: false)
            VStack(alignment: .trailing, spacing: 8) { reloadControls; scopeControls }
        }
    }
    private var reloadControls: some View {
        HStack(spacing: 8) {
            Button { Task { await state.load() } } label: { HStack(spacing: 5) { NativeIcon("refresh-cw", size: 12); Text("Reload") } }.buttonStyle(T3Button()).help("Reload results")
            Button { Task { await state.loadUsage(); showUsage = true } } label: { NativeIcon("database", size: 12) }.buttonStyle(T3Button()).help("Token usage").accessibilityLabel("Token usage")
        }.fixedSize(horizontal: true, vertical: false)
    }
    private var scopeControls: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 8) { exportControl; scopeControl }
                .fixedSize(horizontal: true, vertical: false)
            VStack(alignment: .trailing, spacing: 8) { exportControl; scopeControl }
        }
    }
    private var exportControl: some View {
        Menu {
                Button("Summary table in scope") { Task { await state.export(summary: true) } }; Button("Every test row in scope") { Task { await state.export(summary: false) } }
                if state.scope != "all" { Divider(); Button("All-time best summary") { Task { await state.export(summary: true, allRuns: true) } }; Button("All runs: every test row") { Task { await state.export(summary: false, allRuns: true) } } }
        } label: { NativeResultsMenuLabel(title: "Export CSV", icon: "upload") }.menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize().disabled(state.busy || state.payload.isNull)
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
        Button { state.chooseFamily(family) } label: {
            Text(label).font(Theme.mono(11, weight: state.family == family ? .medium : .regular)).foregroundStyle(state.family == family ? Theme.ink : Theme.muted)
                .padding(.horizontal, 10).padding(.vertical, 5)
                .background(state.family == family ? Theme.subtle2 : .clear, in: RoundedRectangle(cornerRadius: Theme.radiusSm))
                .overlay(RoundedRectangle(cornerRadius: Theme.radiusSm).strokeBorder(state.family == family ? Theme.input : Theme.border, lineWidth: 1))
        }.buttonStyle(.plain).pointingHand().accessibilityAddTraits(state.family == family ? .isSelected : [])
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
    private var rankingHeading: some View { NativeChartHeading(title: "Ranking", caption: history ? "Each measurement retains its source run; reliability pools all tests. Browser timing and token rates remain estimated." : "Measured comparisons within this run. Missing observations are omitted from the ranking.") }
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
        return LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: width >= 840 ? 4 : 2)) {
            tile(cells.contains(where: \.browser) ? (history ? "Best response median" : "Fastest first response") : (history ? "Best first-token median" : "Fastest first token"), cell: first, value: first?.ttft, format: nativeBenchMilliseconds, metric: "latency")
            tile(history ? "All-time top speed" : "Top output speed", cell: speed, value: speed?.speed, format: { String(format: "%.2f tok/s", $0) }, metric: "throughput")
            tile("Largest input taken", cell: input, value: input?.input, format: nativeBenchTokens, metric: "context")
            tile(history ? "All-tests reliability" : "Most reliable", cell: reliable, value: reliable?.reliability, format: { String(format: "%.0f%%", $0) }, metric: nil)
        }
    }
    private func tile(_ label: String, cell: NativeResultCell?, value: Double?, format: @escaping (Double) -> String, metric: String?) -> some View {
        Card(padding: 14) {
            VStack(alignment: .leading, spacing: 7) {
                HStack(spacing: 6) { StatusDot(color: cell.map { Theme.pairColor($0.id) } ?? Theme.accent, size: 5); Text(label).font(Theme.ui(12)).foregroundStyle(Theme.muted).lineLimit(1) }
                NativeNumberText(text: value.map { (cell?.estimated == true && (metric == "throughput" || metric == "context") ? "~" : "") + format($0) + (metric == "context" && cell?.capped == false ? "+" : "") } ?? "—", font: Theme.mono(22, weight: .semibold))
                Text(cell.map { $0.short + " on " + $0.value["provider_name"].string } ?? "No data").font(Theme.ui(11.5)).foregroundStyle(Theme.muted).lineLimit(1)
                if let cell, let metric, !cell.source(metric).isEmpty { Button("View source run") { state.choose(cell.source(metric)) }.buttonStyle(.link).font(Theme.ui(10.5)) }
            }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
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
            .lineLimit(1).padding(.horizontal, 11).frame(height: 28)
            .background(Theme.subtle, in: RoundedRectangle(cornerRadius: Theme.radiusMd))
            .overlay(RoundedRectangle(cornerRadius: Theme.radiusMd).strokeBorder(Theme.input, lineWidth: 1))
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
                    }.font(Theme.ui(11, weight: .medium)).foregroundStyle(Theme.muted).padding(.horizontal, 14).padding(.vertical, 10)
                    Rectangle().fill(Theme.border).frame(height: 1).nativeEntrance(.rule)
                    ForEach(Array(cells.enumerated()), id: \.element.id) { index, cell in
                        NativeResultsRow(cell: cell, index: index, open: open).nativeEntrance(.row, delay: 0.08 + Double(index) * 0.045)
                        Divider().overlay(Theme.border)
                    }
                }.frame(width: max(876, availableWidth))
            }.scrollIndicators(.visible)
                .accessibilityHint("Scroll horizontally to inspect all result columns, including Last problem.")
        }
        if availableWidth < 876 { Text("Scroll horizontally to see every column.").font(Theme.ui(11)).foregroundStyle(Theme.muted) }
        }
    }
}

private struct NativeResultsRow: View {
    let cell: NativeResultCell, index: Int, open: (String) -> Void
    @State private var hovering = false
    @Environment(\.nativeReducedMotion) private var reduceMotion
    var body: some View {
        HStack(alignment: .center, spacing: 16) {
            HStack(spacing: 8) { StatusDot(color: Theme.pairColor(cell.id), size: 7); VStack(alignment: .leading, spacing: 2) { Text(cell.short).font(Theme.mono(12)).lineLimit(1).help(cell.value["model"].string); Text(cell.value["provider_name"].string).font(Theme.ui(10.5)).foregroundStyle(Theme.muted); if cell.browser { Text("Browser · estimated tokens").font(Theme.ui(11)).foregroundStyle(Theme.muted) } } }.frame(minWidth: 150, maxWidth: .infinity, alignment: .leading)
            reading(nativeBenchReading(cell.ttft, format: nativeBenchMilliseconds), column: 0, source: cell.source("latency"), detail: cell.browser ? "visible text" : cell.value["latency"]["n"].int > 1 ? "\(nativeBenchReading(BenchmarkMath.number(cell.value["latency"]["ttft_min_ms"]), format: nativeBenchMilliseconds)) – \(nativeBenchReading(BenchmarkMath.number(cell.value["latency"]["ttft_max_ms"]), format: nativeBenchMilliseconds))" : "")
            reading(nativeBenchReading(cell.speed, format: { (cell.estimated ? "~" : "") + String(format: "%.2f tok/s", $0) }), column: 1, source: cell.source("throughput"), detail: cell.browser ? "visible updates" : "")
            reading(nativeBenchReading(cell.input, format: { (cell.estimated ? "~" : "") + nativeBenchTokens($0) + (cell.capped ? "" : "+") }), column: 2, source: cell.source("context"))
            reading(nativeBenchReading(cell.gap, format: nativeBenchMilliseconds), column: 3, detail: cell.browser ? "text updates" : "")
            reliability
            Text(lastProblem).font(Theme.ui(11)).foregroundStyle(cell.value["last_error"].isNull ? Theme.muted : Theme.warnFg).lineLimit(2).frame(minWidth: 130, maxWidth: .infinity, alignment: .leading).fixedSize(horizontal: false, vertical: true).help(lastProblem)
        }.padding(.horizontal, 14).padding(.vertical, 9).background(hovering ? Theme.subtle : .clear)
        .overlay(alignment: .leading) { Rectangle().fill(Theme.pairColor(cell.id)).frame(width: 2).opacity(hovering ? 1 : 0) }
        .onHover { hovering = $0 }.animation(reduceMotion ? nil : .easeOut(duration: 0.14), value: hovering)
    }
    private var lastProblem: String {
        guard !cell.value["last_error"].isNull else { return "none" }
        let problem = cell.value["last_error"], test = problem["test"].string
        let label = cell.browser && problem["class"].string == "auth" ? "browser sign-in required" : problem["class"].string.replacingOccurrences(of: "_", with: " ")
        return label + (test.isEmpty ? "" : " (" + test + ")")
    }
    private var reliability: some View {
        HStack(spacing: 6) {
            StatusDot(color: (cell.reliability ?? 0) >= 90 ? Theme.okFg : (cell.reliability ?? 0) >= 60 ? Theme.warnFg : Theme.failFg, size: 6)
            NativeNumberText(text: nativeBenchReading(cell.reliability, format: { String(format: "%.0f%%", $0) }), font: Theme.mono(12), delay: 0.31 + Double(index) * 0.045)
            Text("\(cell.value["ok_count"].int)/\(cell.value["ok_count"].int + cell.value["err_count"].int)").font(Theme.mono(9.5)).foregroundStyle(Theme.muted).lineLimit(1).minimumScaleFactor(0.8)
        }.frame(width: 106, alignment: .leading)
    }
    private func reading(_ text: String, column: Int, source: String = "", detail: String = "") -> some View {
        VStack(alignment: .leading, spacing: 2) { NativeNumberText(text: text, font: Theme.mono(12), delay: 0.17 + Double(index) * 0.045 + Double(column) * 0.035); if !detail.isEmpty { Text(detail).font(Theme.mono(9.5)).foregroundStyle(Theme.muted) }; if !source.isEmpty { Button("View run") { open(source) }.buttonStyle(.link).font(Theme.ui(10.5)) } }.frame(width: CGFloat([96, 106, 84, 80, 106][column]), alignment: .leading)
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
            Text("Winner").font(Theme.ui(11, weight: .medium)).foregroundStyle(Theme.dim)
            Text("\(wins)/4").font(Theme.mono(10)).foregroundStyle(Theme.ink)
        }
        .padding(.horizontal, 8).frame(height: 28)
        .background(Theme.pairColor(cell.id).opacity(0.09), in: RoundedRectangle(cornerRadius: Theme.radiusSm))
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
        VStack(alignment: .leading, spacing: 15) {
            HStack { Text("Benchmark token usage").font(Theme.ui(18, weight: .semibold)); Spacer(); Button("Done") { dismiss() }.keyboardShortcut(.cancelAction) }
            Text("Across both result histories, including failed calls with reported usage. Reasoning is inside output; cached tokens are inside input.").font(Theme.ui(12)).foregroundStyle(Theme.muted)
            HStack { NativeValueTile(label: "Input", value: value["input"].double, format: NativeNumberFormat.compact); NativeValueTile(label: "Output", value: value["output"].double, format: NativeNumberFormat.compact); NativeValueTile(label: "Cached", value: value["cached"].double, format: NativeNumberFormat.compact); NativeValueTile(label: "Estimated calls", value: value["estimated"].double) }
            ScrollView { ForEach(Array(value["pairs"].array.enumerated()), id: \.offset) { _, pair in HStack { Text(pair["provider_name"].string + " · " + pair["model"].string).font(Theme.mono(11)); Spacer(); Text("\(NativeNumberFormat.compact(pair["input"].double)) in / \(NativeNumberFormat.compact(pair["output"].double)) out · \(pair["calls"].int) calls").font(Theme.mono(11)) } } }
        }.padding(20).frame(width: 1000, height: 620).background(Theme.bg).foregroundStyle(Theme.ink)
    }
}
