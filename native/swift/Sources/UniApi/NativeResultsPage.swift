import SwiftUI
import AppKit
import UniApiCore
import UniApiPresentation

/// The scoreboard for a run: who won and by how much, then every pair ranked
/// on the measurement you choose, then the curves behind the numbers.
struct NativeResultsPage: View {
    let runtime: NativeRuntime
    @StateObject private var state: NativeResultsModel
    @State private var showUsage = false
    @State private var showRaw = false
    @Environment(\.nativeInterfaceDensity) private var density
    @Environment(\.nativeReducedMotion) private var reduceMotion
    @AppStorage("uniapi.rank.metric") private var ranking = "ttft"
    init(runtime: NativeRuntime, initialRun: String? = nil) { self.runtime = runtime; _state = StateObject(wrappedValue: NativeResultsModel(runtime: runtime, initialRun: initialRun)) }
    private var cells: [NativeResultCell] { state.payload["cells"].object.map { NativeResultCell(id: $0.key, value: $0.value) }.filter { state.family.isEmpty || $0.value["family"] == .string(state.family) }.sorted {
        let a = $0.ttft ?? .infinity, b = $1.ttft ?? .infinity
        return a == b ? $0.id < $1.id : a < b
    } }
    private var history: Bool { state.payload["aggregation"] == "best" }
    private var runs: [JSONValue] { state.payload["runs"].array }
    private var families: [String] { Array(Set(state.payload["cells"].object.values.map { $0["family"].string })).sorted() }
    private var rawRows: [JSONValue] { state.raw.filter { state.family.isEmpty || BenchmarkMath.family($0["model"].string) == state.family } }
    private var readiness: NativePageReadiness {
        state.busy ? .pending : !state.error.isEmpty ? .failed : state.payload.isNull ? .pending : .ready
    }
    private var scopeLabel: String {
        if state.scope == "all" { return "All-time best" }
        if state.scope == "latest" { return "Latest run" }
        return runs.first { $0["id"].string == state.scope }.map { runStamp($0) + " · " + $0["tier"].string } ?? state.scope
    }
    private var eyebrow: String {
        if state.payload.isNull || runs.isEmpty { return "Benchmark" }
        if history { return "All-time best · " + (runs.count == 1 ? "1 run" : "\(runs.count) runs") }
        guard let run = runs.first(where: { $0["id"].string == state.payload["scope"].string }) else { return scopeLabel }
        return (state.scope == "latest" ? "Latest run · " : "Run · ") + runStamp(run) + " · " + run["tier"].string
    }

    var body: some View {
        GeometryReader { geometry in
        let contentWidth = max(0, min(960, geometry.size.width) - 2 * density.pageMargin)
        NativePage(title: "Results", eyebrow: eyebrow, readiness: readiness, actions: { headerActions }) {
            if !state.error.isEmpty { Notice(text: state.error, tone: .fail).accessibilityLabel("Error: " + state.error) }
            if state.busy || state.payload.isNull {
                if state.error.isEmpty { placeholder(title: "Reading results", muted: true) }
            } else if cells.isEmpty {
                unmeasured
            } else {
                if cells.contains(where: \.browser) { Notice(text: BenchmarkMath.browserNote) }
                if history { ResultsRecords(cells: cells, runs: runs.count, open: state.choose) }
                else if let subject = NativeResultCell.winner(cells)?.0 ?? cells.first {
                    ResultsLead(cell: subject, wins: NativeResultCell.winner(cells)?.1, cells: cells, width: contentWidth).id(subject.id)
                }
                rankingBand(width: contentWidth)
                Band(title: "Curves", spacing: 14) {
                    BenchDisclosure(title: "More views", open: fold(Binding(get: { state.tab == "charts" }, set: { state.chooseTab($0 ? "charts" : "table") })))
                } content: {
                    NativeResultsCharts(cells: cells, rows: state.curves, history: history, more: state.tab == "charts", open: state.choose)
                }
                rawBand
            }
            if !runs.isEmpty { runsBand }
        }
        }
        .nativePageTask { await state.begin(runtime: runtime) }.nativePageActivity(suspended: { state.stop() })
        .sheet(isPresented: $showUsage) { NativeResultsUsage(value: state.usage) }
    }

    private func fold(_ flag: Binding<Bool>) -> Binding<Bool> {
        Binding(get: { flag.wrappedValue }, set: { open in
            if reduceMotion { flag.wrappedValue = open } else { withAnimation(.easeOut(duration: 0.18)) { flag.wrappedValue = open } }
        })
    }
    /// The scoreboard at rest: the same readouts the winner fills, reading nothing.
    private var unmeasured: some View {
        let filtered = !state.family.isEmpty && !state.payload["cells"].object.isEmpty
        return VStack(alignment: .leading, spacing: 24) {
            VStack(alignment: .leading, spacing: 6) {
                MicroLabel(filtered ? state.family : scopeLabel)
                Text("Nothing measured").font(Theme.display()).tracking(-0.4).foregroundStyle(Theme.ink).accessibilityAddTraits(.isHeader)
                Text(filtered ? "No pair in this scope belongs to that model family."
                     : runs.isEmpty ? "Arm some pairs on Speed and start a run. The scoreboard fills in as tests finish."
                     : "This scope holds no finished tests. Pick another run above, or start a new one.")
                    .font(Theme.ui(12.5)).foregroundStyle(Theme.muted).fixedSize(horizontal: false, vertical: true)
            }
            ReadoutStrip(minimum: 150) {
                Readout(label: "Output speed", value: "—", unit: "tok/s", size: .hero, color: Theme.faint)
                Readout(label: "First token", value: "—", unit: "ms", size: .hero, color: Theme.faint)
            }
            .accessibilityHidden(true)
            if filtered {
                Button("Show all models", nativeIcon: "list-checks") { state.chooseFamily("") }.buttonStyle(Press(.secondary))
            }
        }
    }
    private func placeholder(title: String, muted: Bool) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            MicroLabel(scopeLabel)
            Text(title).font(Theme.display()).tracking(-0.4).foregroundStyle(muted ? Theme.muted : Theme.ink)
        }
    }

    // ------------------------------------------------------------------
    // Header
    // ------------------------------------------------------------------

    @ViewBuilder private var headerActions: some View {
        IconPress(icon: "refresh-cw", help: "Reload results") { Task { await state.load() } }
        IconPress(icon: "database", help: "Token usage") { Task { await state.loadUsage(); showUsage = true } }
        Menu {
            Button("Summary table in scope") { Task { await state.export(summary: true) } }; Button("Every test row in scope") { Task { await state.export(summary: false) } }
            if state.scope != "all" { Divider(); Button("All-time best summary") { Task { await state.export(summary: true, allRuns: true) } }; Button("All runs: every test row") { Task { await state.export(summary: false, allRuns: true) } } }
        } label: { BenchMenuFace(title: "Export CSV", icon: "upload") }
            .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize().disabled(state.busy || state.payload.isNull)
        Pick(title: scopeLabel, selection: Binding(get: { state.scope }, set: { state.choose($0) }),
             options: [("latest", "Latest run"), ("all", "All-time best")] + runs.map { ($0["id"].string, runStamp($0) + " · " + $0["tier"].string) })
            .help(scopeLabel).accessibilityLabel("Result scope: " + scopeLabel)
        Button("New run", nativeIcon: "play") {
            NotificationCenter.default.post(name: .nativeNavigation, object: NativeDestination.speed)
        }.buttonStyle(Press(.primary))
    }

    // ------------------------------------------------------------------
    // Ranking
    // ------------------------------------------------------------------

    private func rankingBand(width: CGFloat) -> some View {
        Band(title: "Ranking", spacing: 0) {
            HStack(spacing: 8) {
                if width < ResultsLedger.compactBelow {
                    Pick(title: "Rank by", selection: $ranking,
                         options: ResultsColumn.all(browser: cells.contains(where: \.browser), history: history).map { ($0.id, $0.name) })
                }
                if families.count > 1 {
                    Pick(title: "Model family", selection: Binding(get: { state.family }, set: { state.chooseFamily($0) }),
                         options: [("", "All models")] + families.map { ($0, $0) })
                }
            }
        } content: {
            ResultsLedger(cells: cells, history: history, width: width, ranking: $ranking, open: state.choose)
        }
    }

    // ------------------------------------------------------------------
    // Raw rows and runs
    // ------------------------------------------------------------------

    private var rawBand: some View {
        let rows = rawRows
        return Band(title: "Raw measurements", spacing: 0) {
            Text("Failures and transport details").font(Theme.ui(11.5)).foregroundStyle(Theme.muted).lineLimit(1)
            BenchDisclosure(title: showRaw ? "Hide" : "Show", detail: "\(rows.count)", open: fold($showRaw))
        } content: {
            if showRaw {
                if rows.isEmpty { Text("No recorded rows in this scope.").font(Theme.ui(12.5)).foregroundStyle(Theme.muted).padding(.vertical, 20) }
                LazyVStack(spacing: 0) {
                    ForEach(Array(rows.enumerated()), id: \.offset) { _, row in ResultsRawRow(row: row) }
                }
            }
        }
    }
    private var runsBand: some View {
        Band(title: "Runs", spacing: 0) {
            Text(runs.count == 1 ? "1 run" : "\(runs.count) runs").font(Theme.ui(11.5)).foregroundStyle(Theme.muted)
        } content: {
            LazyVStack(spacing: 0) {
                ForEach(runs, id: \.self["id"]) { run in
                    LedgerRow(selected: state.payload["scope"].string == run["id"].string, minHeight: 40, action: { state.choose(run["id"].string) }) {
                        HStack(spacing: 12) {
                            Text(runStamp(run)).font(Theme.mono(12)).foregroundStyle(Theme.ink).lineLimit(1).frame(width: 132, alignment: .leading)
                            Tag(run["tier"].string)
                            Text("\(run["pairs"].array.count) \(run["pairs"].array.count == 1 ? "pair" : "pairs") in \(runDuration(run))")
                                .font(Theme.ui(12.5)).foregroundStyle(Theme.muted).lineLimit(1).layoutPriority(-1)
                            Spacer(minLength: 8)
                            Text("\(run["ok"].int) passed").font(Theme.mono(11)).foregroundStyle(Theme.okFg).lineLimit(1).frame(width: 78, alignment: .trailing)
                            Text("\(run["err"].int) failed").font(Theme.mono(11)).foregroundStyle(run["err"].int == 0 ? Theme.faint : Theme.warnFg).lineLimit(1).frame(width: 70, alignment: .trailing)
                        }
                    }
                    .help("View run \(run["id"].string)")
                }
            }
        }
    }
    private func runStamp(_ run: JSONValue) -> String {
        let started = BenchmarkMath.timestamp(run["started"].string)
        return started.isFinite && started > 0 ? NativeListTimeFormat.stamp(Date(timeIntervalSince1970: started)) : run["id"].string
    }
    private func runDuration(_ run: JSONValue) -> String {
        let started = BenchmarkMath.timestamp(run["started"].string), finished = BenchmarkMath.timestamp(run["finished"].string)
        guard started.isFinite, finished.isFinite, started > 0, finished > 0 else { return NativeListTimeFormat.duration(0) }
        return NativeListTimeFormat.duration(max(0, (finished - started) * 1000))
    }
}

// ======================================================================
// MARK: - Shared between Speed and Results
// ======================================================================

/// A quiet control that opens the panel beneath it; the chevron turns.
struct BenchDisclosure: View {
    var title: String
    var detail: String = ""
    @Binding var open: Bool
    @Environment(\.nativeReducedMotion) private var reduceMotion
    var body: some View {
        Button { open.toggle() } label: {
            HStack(spacing: 6) {
                Text(title)
                if !detail.isEmpty { Text(detail).font(Theme.mono(10.5)).foregroundStyle(Theme.muted) }
                NativeIcon("chevron-right", size: 12, strokeWidth: 1.75).rotationEffect(.degrees(open ? 90 : 0))
                    .animation(reduceMotion ? nil : NativeMotion.hover, value: open)
            }
        }
        .buttonStyle(Press(.quiet))
        .accessibilityLabel(title + (detail.isEmpty ? "" : ", " + detail)).accessibilityValue(open ? "Expanded" : "Collapsed")
    }
}

/// The face of a menu that runs commands, drawn like a secondary `Press`.
struct BenchMenuFace: View {
    let title: String
    var icon: String? = nil
    @State private var hovering = false
    @Environment(\.isEnabled) private var enabled
    var body: some View {
        HStack(spacing: 6) {
            if let icon { NativeIcon(icon, size: 14) }
            Text(title).lineLimit(1)
            NativeIcon("chevron-down", size: 12, strokeWidth: 1.75).foregroundStyle(Theme.muted)
        }
        .font(Theme.ui(12.5, weight: .medium)).foregroundStyle(Theme.ink)
        .padding(.horizontal, 12).frame(height: 28)
        .background(RoundedRectangle(cornerRadius: Theme.radiusControl, style: .continuous).fill(hovering ? Theme.hover : .clear))
        .overlay(RoundedRectangle(cornerRadius: Theme.radiusControl, style: .continuous).strokeBorder(Theme.ruleStrong, lineWidth: 1))
        .alignmentGuide(.firstTextBaseline) { _ in 28 * 0.64 }
        .alignmentGuide(.lastTextBaseline) { _ in 28 * 0.64 }
        .contentShape(Rectangle())
        .opacity(enabled ? 1 : 0.4)
        .onHover { hovering = $0 && enabled }
        .pointingHand(enabled)
    }
}

/// Progress as an instrument: a square bar over a tick for every division,
/// with the signal needle at the live edge while something is running.
struct BenchMeter: View {
    var fraction: Double
    var color: Color = Theme.ink
    var live = false
    var divisions = 20
    @Environment(\.nativeReducedMotion) private var reduceMotion
    @Environment(\.nativeMotionVisible) private var visible
    var body: some View {
        let value = NativeMotion.fraction(fraction)
        VStack(spacing: 4) {
            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    Rectangle().fill(Theme.track)
                    Rectangle().fill(color).frame(width: geometry.size.width * value)
                }
                .overlay(alignment: .leading) {
                    if live { Theme.signal.frame(width: 2, height: 16).offset(x: max(0, geometry.size.width * value - 1)) }
                }
                .animation(reduceMotion || !visible ? nil : NativeMotion.barUpdate, value: value)
            }
            .frame(height: 6)
            TickScale(divisions: divisions, major: 5, minorHeight: 3, majorHeight: 6).fill(Theme.faint).frame(height: 6)
        }
        .padding(.top, live ? 5 : 0)
        .accessibilityHidden(true)
    }
}

// ======================================================================
// MARK: - Cells and formats
// ======================================================================

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
    var lastProblem: String {
        guard !value["last_error"].isNull else { return "" }
        let problem = value["last_error"], test = problem["test"].string
        let label = browser && problem["class"].string == "auth" ? "browser sign-in required" : problem["class"].string.replacingOccurrences(of: "_", with: " ")
        return label + (test.isEmpty ? "" : " (" + test + ")")
    }
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
func nativeBenchSpeed(_ value: Double) -> String { String(format: value >= 100 ? "%.0f" : "%.1f", value) }

/// A formatted reading split into its numerals and its unit, for a `Readout`.
private func benchParts(_ text: String) -> (value: String, unit: String) {
    let parts = text.split(separator: " ", maxSplits: 1).map(String.init)
    return (parts.first ?? text, parts.count > 1 ? parts[1] : "")
}
private func benchOrdinal(_ rank: Int) -> String {
    let tail = rank % 100
    if (11...13).contains(tail) { return "\(rank)th" }
    switch rank % 10 { case 1: return "\(rank)st"; case 2: return "\(rank)nd"; case 3: return "\(rank)rd"; default: return "\(rank)th" }
}

/// Opens the run a record came from.
private struct ResultsRunLink: View {
    var title = "View run"
    let action: () -> Void
    @State private var hovering = false
    var body: some View {
        Button(action: action) {
            Text(title).font(Theme.ui(11.5)).underline().foregroundStyle(hovering ? Theme.ink : Theme.muted).lineLimit(1)
        }
        .buttonStyle(.plain).pointingHand().onHover { hovering = $0 }
    }
}

// ======================================================================
// MARK: - The lead
// ======================================================================

/// The pair that won this run, named, with its two headline readings set
/// large and the rest of its sheet beneath on the same four columns.
private struct ResultsLead: View {
    let cell: NativeResultCell, wins: Int?, cells: [NativeResultCell], width: CGFloat
    private var color: Color { Theme.pairColor(cell.id) }
    private var provider: String { cell.value["provider_name"].string }
    private func place(lower: Bool = false, _ value: (NativeResultCell) -> Double?) -> String {
        let measured = cells.compactMap(value)
        guard measured.count > 1, let own = value(cell) else { return "" }
        return benchOrdinal(measured.filter { lower ? $0 < own : $0 > own }.count + 1) + " of \(measured.count)"
    }
    private var name: some View {
        VStack(alignment: .leading, spacing: 0) {
            ZStack(alignment: .topLeading) { Rule(); color.frame(width: 2, height: 7) }
                .frame(height: 7, alignment: .top).padding(.bottom, 9)
            MicroLabel(wins.map { "Winner · leads \($0) of 4" } ?? "Measured")
            Text(cell.short).font(Theme.display()).tracking(-0.4).foregroundStyle(Theme.ink)
                .lineLimit(1).minimumScaleFactor(0.6).padding(.top, 10)
            Text(provider + (cell.browser ? " · Browser, estimated tokens" : cell.short == cell.value["model"].string ? "" : " · " + cell.value["model"].string))
                .font(Theme.mono(11.5)).foregroundStyle(Theme.muted).lineLimit(1).truncationMode(.middle).padding(.top, 6)
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(wins.map { "Winner: \(cell.value["model"].string) on \(provider), \($0) of 4 headline categories" } ?? "\(cell.value["model"].string) on \(provider)")
        .help(wins.map { "\(cell.value["model"].string) on \(provider) took \($0) of the 4 headline categories in this scope" } ?? cell.value["model"].string)
    }
    private var speed: some View {
        Readout(label: "Output speed", value: cell.speed.map { (cell.estimated ? "~" : "") + nativeBenchSpeed($0) } ?? "—", unit: cell.speed == nil ? "" : "tok/s",
                detail: place { $0.speed }, size: .hero, tint: color, color: cell.speed == nil ? Theme.faint : Theme.ink)
    }
    private var first: some View {
        let parts = benchParts(nativeBenchReading(cell.ttft, format: nativeBenchMilliseconds))
        return Readout(label: cell.browser ? "First response" : "First token", value: parts.value, unit: parts.unit,
                       detail: place(lower: true) { $0.ttft }, size: .hero, tint: color, color: cell.ttft == nil ? Theme.faint : Theme.ink)
    }
    var body: some View {
        let column = max(0, (width - 72) / 4)
        VStack(alignment: .leading, spacing: 26) {
            if width >= 760 {
                HStack(alignment: .top, spacing: 24) {
                    name.frame(width: column * 2 + 24, alignment: .topLeading)
                    speed.frame(width: column, alignment: .topLeading)
                    first.frame(width: column, alignment: .topLeading)
                }
            } else {
                VStack(alignment: .leading, spacing: 22) {
                    name
                    HStack(alignment: .top, spacing: 24) { speed; first }
                }
            }
            ReadoutStrip(minimum: 108) {
                Readout(label: "Largest input", value: cell.input.map { (cell.estimated ? "~" : "") + nativeBenchTokens($0) + (cell.capped ? "" : "+") } ?? "—",
                        unit: cell.input == nil ? "" : "tokens", detail: place { $0.input }, size: .medium, color: cell.input == nil ? Theme.faint : Theme.ink)
                Readout(label: "Pause p95", value: benchParts(nativeBenchReading(cell.gap, format: nativeBenchMilliseconds)).value,
                        unit: benchParts(nativeBenchReading(cell.gap, format: nativeBenchMilliseconds)).unit,
                        detail: place(lower: true) { $0.gap }, size: .medium, color: cell.gap == nil ? Theme.faint : Theme.ink)
                Readout(label: "Reliability", value: cell.reliability.map { String(format: "%.0f", $0) } ?? "—", unit: cell.reliability == nil ? "" : "%",
                        detail: place { $0.reliability }, size: .medium,
                        tint: (cell.reliability ?? 100) >= 90 ? nil : (cell.reliability ?? 0) >= 60 ? Theme.warn : Theme.fail)
                Readout(label: "Tests", value: "\(cell.value["ok_count"].int)", unit: "passed",
                        detail: cell.value["err_count"].int == 0 ? "None failed" : "\(cell.value["err_count"].int) failed · " + cell.lastProblem, size: .medium)
            }
        }
    }
}

/// All-time scope has no single winner: each record names its own holder.
private struct ResultsRecords: View {
    let cells: [NativeResultCell], runs: Int
    let open: (String) -> Void
    private var browser: Bool { cells.contains(where: \.browser) }
    private func record(_ label: String, holder: NativeResultCell?, value: String, unit: String, metric: String?) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Readout(label: label, value: holder == nil ? "—" : value, unit: holder == nil ? "" : unit,
                    detail: holder.map { $0.short + " on " + $0.value["provider_name"].string } ?? "No data", size: .large,
                    tint: holder.map { Theme.pairColor($0.id) }, color: holder == nil ? Theme.faint : Theme.ink)
            if let holder, let metric, !holder.source(metric).isEmpty {
                ResultsRunLink(title: "View source run") { open(holder.source(metric)) }
            }
        }
    }
    var body: some View {
        let first = cells.filter { $0.ttft != nil }.min { $0.ttft! < $1.ttft! }, speed = cells.filter { $0.speed != nil }.max { $0.speed! < $1.speed! }
        let input = cells.filter { $0.input != nil }.max { $0.input! < $1.input! }, reliable = cells.filter { $0.reliability != nil }.max { $0.reliability! < $1.reliability! }
        let latency = benchParts(nativeBenchReading(first?.ttft, format: nativeBenchMilliseconds))
        VStack(alignment: .leading, spacing: 24) {
            VStack(alignment: .leading, spacing: 6) {
                MicroLabel("Record holders")
                Text(runs == 1 ? "Records from 1 run" : "Records across \(runs) runs").font(Theme.display()).tracking(-0.4).foregroundStyle(Theme.ink)
                    .accessibilityAddTraits(.isHeader)
                Text("Each record can come from a different run. Reliability pools every test, failures included.")
                    .font(Theme.ui(12.5)).foregroundStyle(Theme.muted).lineLimit(2)
                    .help("Speed and first-token records come from individual run summaries; each column can come from a different run. Reliability includes every test, including failures. Gap is measured at the recorded best speed.")
            }
            ReadoutStrip(minimum: 180) {
                record(browser ? "Best response median" : "Best first-token median", holder: first, value: latency.value, unit: latency.unit, metric: "latency")
                record("All-time top speed", holder: speed, value: (speed?.estimated == true ? "~" : "") + nativeBenchSpeed(speed?.speed ?? 0), unit: "tok/s", metric: "throughput")
                record("Largest input taken", holder: input, value: (input?.estimated == true ? "~" : "") + nativeBenchTokens(input?.input ?? 0) + (input?.capped == false ? "+" : ""), unit: "tokens", metric: "context")
                record("All-tests reliability", holder: reliable, value: String(format: "%.0f", reliable?.reliability ?? 0), unit: "%", metric: nil)
            }
        }
    }
}

// ======================================================================
// MARK: - The ranking ledger
// ======================================================================

private struct ResultsColumn: Identifiable {
    let id: String, title: String, name: String, width: CGFloat, lower: Bool, help: String
    static func all(browser: Bool, history: Bool) -> [ResultsColumn] {
        [
            .init(id: "ttft", title: browser ? "First reply" : "First token", name: browser ? "First response" : "First token", width: 92, lower: true,
                  help: browser ? "Time to first visible text; lower is better." : history ? "Best run median; lower is better." : "Median of the latency samples, with their range; lower is better."),
            .init(id: "decode", title: "Tok/s", name: "Output speed", width: 72, lower: false,
                  help: browser ? "Estimated from visible text updates." : history ? "Best recorded generation speed in tokens per second." : "Generation-phase tokens per second from the last successful output test."),
            .init(id: "context", title: "Max input", name: "Max input", width: 76, lower: false,
                  help: "Largest accepted prompt. A plus means no larger prompt has failed yet."),
            .init(id: "gap", title: "Pause p95", name: "Worst pause", width: 78, lower: true,
                  help: history ? "Streaming pause p95 at the recorded best speed; lower is better." : "95th percentile gap between stream events; lower is better."),
            .init(id: "reliability", title: "Reliability", name: "Reliability", width: 88, lower: false,
                  help: "Successful tests divided by all tests in this scope."),
        ]
    }
    func value(_ cell: NativeResultCell) -> Double? {
        switch id { case "decode": return cell.speed; case "context": return cell.input; case "reliability": return cell.reliability; case "gap": return cell.gap; default: return cell.ttft }
    }
    func text(_ cell: NativeResultCell) -> String {
        switch id {
        case "decode": return nativeBenchReading(cell.speed) { (cell.estimated ? "~" : "") + String(format: "%.1f", $0) }
        case "context": return nativeBenchReading(cell.input) { (cell.estimated ? "~" : "") + nativeBenchTokens($0) + (cell.capped ? "" : "+") }
        case "reliability": return nativeBenchReading(cell.reliability) { String(format: "%.0f%%", $0) }
        case "gap": return nativeBenchReading(cell.gap, format: nativeBenchMilliseconds)
        default: return nativeBenchReading(cell.ttft, format: nativeBenchMilliseconds)
        }
    }
    func detail(_ cell: NativeResultCell) -> String {
        switch id {
        case "decode": return cell.browser ? "visible" : ""
        case "gap": return cell.browser ? "text updates" : ""
        case "reliability": return "\(cell.value["ok_count"].int)/\(cell.value["ok_count"].int + cell.value["err_count"].int)"
        case "ttft":
            if cell.browser { return "visible text" }
            guard cell.value["latency"]["n"].int > 1, let low = BenchmarkMath.number(cell.value["latency"]["ttft_min_ms"]),
                  let high = BenchmarkMath.number(cell.value["latency"]["ttft_max_ms"]) else { return "" }
            return high < 1000 ? String(format: "%.0f–%.0f", low, high) : String(format: "%.1f–%.1f s", low / 1000, high / 1000)
        default: return ""
        }
    }
    func source(_ cell: NativeResultCell) -> String {
        switch id { case "ttft": return cell.source("latency"); case "decode": return cell.source("throughput"); case "context": return cell.source("context"); default: return "" }
    }
}

/// Every pair on one ledger. A column head is also the ranking control: the
/// signal marker slides to it, the rows re-rank and the bars sweep.
private struct ResultsLedger: View {
    static let compactBelow: CGFloat = 720
    let cells: [NativeResultCell], history: Bool, width: CGFloat
    @Binding var ranking: String
    let open: (String) -> Void
    @Namespace private var marker
    @Environment(\.nativeReducedMotion) private var reduceMotion
    @Environment(\.nativeMotionVisible) private var visible

    private var compact: Bool { width < Self.compactBelow }
    var body: some View {
        let columns = ResultsColumn.all(browser: cells.contains(where: \.browser), history: history)
        let chosen = columns.first { $0.id == ranking } ?? columns[0]
        let measured = cells.filter { chosen.value($0) != nil }.sorted {
            let a = chosen.value($0)!, b = chosen.value($1)!
            return a == b ? $0.id < $1.id : chosen.lower ? a < b : a > b
        }
        let ordered = measured + cells.filter { chosen.value($0) == nil }
        let values = measured.compactMap(chosen.value).filter(\.isFinite)
        let reference = chosen.id == "reliability" ? 100 : (chosen.lower ? values.min() : values.max()) ?? 1
        var leaders: [String: String] = [:]
        for column in columns {
            let scored = cells.filter { column.value($0) != nil }
            leaders[column.id] = (column.lower ? scored.min { column.value($0)! < column.value($1)! } : scored.max { column.value($0)! < column.value($1)! })?.id
        }
        return VStack(spacing: 0) {
            LedgerHead {
                MicroLabel("#").frame(width: 20, alignment: .leading)
                MicroLabel("Model").frame(maxWidth: .infinity, alignment: .leading)
                if compact {
                    MicroLabel(chosen.title, color: Theme.ink).frame(width: 96 + 12 + chosen.width, alignment: .trailing)
                } else {
                    Color.clear.frame(width: 132, height: 1)
                    ForEach(columns) { column in head(column, chosen: column.id == chosen.id) }
                }
            }
            ForEach(Array(ordered.enumerated()), id: \.element.id) { index, cell in
                ResultsLedgerRow(cell: cell, rank: index < measured.count ? index + 1 : nil, columns: compact ? [chosen] : columns, chosen: chosen,
                                 reference: reference, leaders: leaders, compact: compact, others: compact ? columns.filter { $0.id != chosen.id } : [], open: open)
            }
        }
        .animation(reduceMotion || !visible ? nil : NativeMotion.segmented, value: ordered.map(\.id))
    }
    private func head(_ column: ResultsColumn, chosen: Bool) -> some View {
        Button { ranking = column.id } label: {
            MicroLabel(column.title, color: chosen ? Theme.ink : Theme.muted)
                .frame(width: column.width, height: 24, alignment: .trailing)
                .overlay(alignment: .bottomTrailing) {
                    if chosen { Theme.signal.frame(width: 28, height: 2).matchedGeometryEffect(id: "rank", in: marker) }
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain).pointingHand()
        .accessibilityLabel("Rank by " + column.name).accessibilityAddTraits(chosen ? [.isSelected] : [])
        .help(column.help)
        .animation(reduceMotion || !visible ? nil : NativeMotion.segmented, value: ranking)
    }
}

private struct ResultsLedgerRow: View {
    let cell: NativeResultCell, rank: Int?
    let columns: [ResultsColumn], chosen: ResultsColumn
    let reference: Double
    let leaders: [String: String]
    let compact: Bool
    let others: [ResultsColumn]
    let open: (String) -> Void
    private var color: Color { Theme.pairColor(cell.id) }
    private func fraction(_ value: Double) -> Double {
        guard reference.isFinite, reference >= 0, value.isFinite, value >= 0 else { return 0 }
        if chosen.lower { return value == 0 ? 1 : NativeMotion.fraction(reference / value) }
        return reference > 0 ? NativeMotion.fraction(value / reference) : 0
    }
    private var spread: ClosedRange<Double>? {
        guard chosen.id == "ttft", let low = BenchmarkMath.number(cell.value["latency"]["ttft_min_ms"]),
              let high = BenchmarkMath.number(cell.value["latency"]["ttft_max_ms"]), low.isFinite, high.isFinite, high > low else { return nil }
        let a = fraction(low), b = fraction(high)
        return min(a, b)...max(a, b)
    }
    private var subtitle: String {
        let provider = cell.value["provider_name"].string + (cell.browser ? " · Browser" : "")
        return compact ? provider + " · " + others.map { $0.text(cell) + ($0.id == "decode" && $0.value(cell) != nil ? " tok/s" : "") }.joined(separator: " · ") : provider
    }
    var body: some View {
        LedgerRow(minHeight: 44) {
            HStack(alignment: .center, spacing: 12) {
                Text(rank.map { String(format: "%02d", $0) } ?? "--").font(Theme.mono(10.5)).foregroundStyle(rank == nil ? Theme.faint : Theme.muted)
                    .frame(width: 20, alignment: .leading)
                HStack(spacing: 9) {
                    color.frame(width: 2, height: 24)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(cell.short).font(Theme.mono(12, weight: .medium)).foregroundStyle(Theme.ink).lineLimit(1).truncationMode(.middle)
                            .help(cell.value["model"].string)
                        Text(subtitle).font(Theme.ui(11.5)).foregroundStyle(Theme.muted).lineLimit(1)
                        if !cell.lastProblem.isEmpty {
                            Text(cell.lastProblem).font(Theme.ui(11.5)).foregroundStyle(Theme.warnFg).lineLimit(1).help("Last problem: " + cell.lastProblem)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                Scale(fraction: chosen.value(cell).map(fraction) ?? 0, color: color, spread: spread).frame(width: compact ? 96 : 132)
                ForEach(columns) { column in reading(column) }
            }
            .padding(.vertical, 7)
        }
        .accessibilityElement(children: .contain)
    }
    private func reading(_ column: ResultsColumn) -> some View {
        let text = column.text(cell), detail = column.detail(cell), source = column.source(cell)
        let leads = leaders[column.id] == cell.id, missing = column.value(cell) == nil
        let plain = leads || column.id == chosen.id ? Theme.ink : Theme.dim
        let tone: Color = column.id == "reliability" && !missing
            ? ((cell.reliability ?? 0) >= 90 ? plain : (cell.reliability ?? 0) >= 60 ? Theme.warnFg : Theme.failFg)
            : missing ? Theme.faint : plain
        return VStack(alignment: .trailing, spacing: 2) {
            NativeNumberText(text: text, font: Theme.mono(12, weight: leads && !missing ? .semibold : .regular), color: tone)
            if !detail.isEmpty { Text(detail).font(Theme.mono(10.5)).foregroundStyle(Theme.muted).lineLimit(1) }
            if !source.isEmpty { ResultsRunLink { open(source) } }
        }
        .frame(width: column.width, alignment: .trailing)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(column.name).accessibilityValue(text + (detail.isEmpty ? "" : ", " + detail))
    }
}

// ======================================================================
// MARK: - Raw rows
// ======================================================================

private struct ResultsRawRow: View {
    let row: JSONValue
    @State private var open = false
    @Environment(\.nativeReducedMotion) private var reduceMotion
    private var title: String {
        [row["provider_name"].string, row["model"].string, row["test"].string, row["ok"].bool ? "ok" : row["error_class"].string].joined(separator: " · ")
    }
    private var test: String {
        let size = row["req"]["ctx_tokens"].double
        return row["test"].string + (size > 0 ? " " + nativeBenchTokens(size) : "")
    }
    /// The two numbers a measurement exists for, so the list reads without opening rows.
    private var reading: String {
        let first = row["timing_ms"]["ttft"].double, speed = row["tps"]["decode"].double
        return [first > 0 ? nativeBenchMilliseconds(first) : "", speed > 0 ? nativeBenchSpeed(speed) + " tok/s" : ""]
            .filter { !$0.isEmpty }.joined(separator: " · ")
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            LedgerRow(minHeight: 32, ruled: !open, action: { open.toggle() }) {
                HStack(spacing: 10) {
                    NativeIcon("chevron-right", size: 11, strokeWidth: 1.75).foregroundStyle(Theme.muted)
                        .rotationEffect(.degrees(open ? 90 : 0)).animation(reduceMotion ? nil : NativeMotion.hover, value: open)
                    Text(row["model"].string).font(Theme.mono(11.5)).foregroundStyle(Theme.ink).lineLimit(1).truncationMode(.middle)
                    Text(row["provider_name"].string).font(Theme.ui(11.5)).foregroundStyle(Theme.muted).lineLimit(1).layoutPriority(-1)
                    Spacer(minLength: 8)
                    Text(test).font(Theme.mono(11)).foregroundStyle(Theme.dim).lineLimit(1).frame(width: 96, alignment: .leading)
                    Text(reading).font(Theme.mono(11)).foregroundStyle(Theme.ink).lineLimit(1).frame(width: 150, alignment: .trailing)
                    Text(row["ok"].bool ? "ok" : row["error_class"].string.replacingOccurrences(of: "_", with: " "))
                        .font(Theme.mono(11)).foregroundStyle(row["ok"].bool ? Theme.okFg : Theme.warnFg).lineLimit(1)
                        .frame(width: 76, alignment: .trailing)
                }
            }
            .accessibilityLabel(title).accessibilityValue(open ? "Expanded" : "Collapsed")
            if open {
                Well(padding: 12) {
                    Text(String(decoding: (try? row.encoded(pretty: true)) ?? Data(), as: UTF8.self)).font(Theme.mono(10.5)).foregroundStyle(Theme.dim)
                        .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(.bottom, 10)
                .overlay(alignment: .bottom) { Rule() }
            }
        }
    }
}

// ======================================================================
// MARK: - Token usage sheet
// ======================================================================

private struct NativeResultsUsage: View {
    let value: JSONValue
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        let pairs = value["pairs"].array
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 20) {
                VStack(alignment: .leading, spacing: 5) {
                    Text("Benchmark token usage").font(Theme.display(17)).foregroundStyle(Theme.ink).accessibilityAddTraits(.isHeader)
                    Text("Both result histories, failed calls with reported usage included. Reasoning counts inside output, cached inside input.")
                        .font(Theme.ui(11.5)).foregroundStyle(Theme.muted).fixedSize(horizontal: false, vertical: true)
                }
                ReadoutStrip(minimum: 130) {
                    Readout(label: "Input", value: NativeNumberFormat.compact(value["input"].double), unit: "tokens", size: .large)
                    Readout(label: "Output", value: NativeNumberFormat.compact(value["output"].double), unit: "tokens", size: .large)
                    Readout(label: "Cached", value: NativeNumberFormat.compact(value["cached"].double), unit: "tokens", size: .large)
                    Readout(label: "Estimated calls", value: NativeNumberFormat.decimal(value["estimated"].double),
                            unit: "of " + NativeNumberFormat.decimal(value["calls"].double), size: .large)
                }
                VStack(spacing: 0) {
                    LedgerHead {
                        MicroLabel("Model").frame(maxWidth: .infinity, alignment: .leading)
                        MicroLabel("Input").frame(width: 76, alignment: .trailing)
                        MicroLabel("Output").frame(width: 76, alignment: .trailing)
                        MicroLabel("Calls").frame(width: 56, alignment: .trailing)
                    }
                    ScrollView {
                        LazyVStack(spacing: 0) {
                            ForEach(Array(pairs.enumerated()), id: \.offset) { _, pair in
                                HStack(spacing: 12) {
                                    HStack(spacing: 9) {
                                        Theme.pairColor(pair["provider"].string + "|" + pair["model"].string).frame(width: 2, height: 12)
                                        Text(pair["model"].string).font(Theme.mono(11.5)).foregroundStyle(Theme.ink).lineLimit(1).truncationMode(.middle)
                                        Text(pair["provider_name"].string).font(Theme.ui(11.5)).foregroundStyle(Theme.muted).lineLimit(1).layoutPriority(-1)
                                    }
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    Text(NativeNumberFormat.compact(pair["input"].double)).frame(width: 76, alignment: .trailing)
                                    Text(NativeNumberFormat.compact(pair["output"].double)).frame(width: 76, alignment: .trailing)
                                    Text("\(pair["calls"].int)").frame(width: 56, alignment: .trailing)
                                }
                                .font(Theme.mono(11.5)).monospacedDigit().foregroundStyle(Theme.dim)
                                .frame(minHeight: 32).overlay(alignment: .bottom) { Rule() }
                            }
                            if pairs.isEmpty {
                                Text("No reported usage yet.").font(Theme.ui(12.5)).foregroundStyle(Theme.muted)
                                    .frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 20)
                            }
                        }
                    }
                }
            }
            .padding(.horizontal, 20).padding(.top, 20)
            Rule()
            HStack(spacing: 8) {
                Text(pairs.count == 1 ? "1 pair" : "\(pairs.count) pairs").font(Theme.ui(11.5)).foregroundStyle(Theme.muted)
                Spacer(minLength: 0)
                Button("Done") { dismiss() }.buttonStyle(Press(.primary)).keyboardShortcut(.cancelAction)
            }
            .padding(.horizontal, 20).padding(.vertical, 12)
        }
        .frame(width: 720, height: 600).background(Theme.popover).foregroundStyle(Theme.ink)
    }
}
