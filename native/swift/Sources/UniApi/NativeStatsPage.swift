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

/// The last complete reading of this view (the overview, or one model). While
/// another range or source is being read the page keeps showing it, so numbers
/// roll to the new scope instead of the page emptying. Readiness never uses it.
@MainActor private final class NativeStatsRetained {
    private var model: String?
    private var value: NativeStatsSnapshot?
    func resolve(_ current: NativeStatsSnapshot?, model: String?, failed: Bool) -> NativeStatsSnapshot? {
        if let current, current.payload["loaded"].bool { self.model = model; value = current; return current }
        return !failed && self.model == model ? value : nil
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
    @State private var detailRange = 0
    @State private var headerVisit: NativeStatsHeaderVisit?
    @State private var headerReadiness = NativePageReadiness.pending
    @Environment(\.nativePageVisit) private var navigationVisit
    @Environment(\.nativePageActivation) private var activation
    @Environment(\.nativeInterfaceDensity) private var density
    @State private var retained = NativeStatsRetained()
    init(runtime: NativeRuntime, model: NativeStatsModel? = nil) { self.runtime = runtime; _state = StateObject(wrappedValue: model ?? NativeStatsModel(runtime: runtime)) }
    private var scope: String { "\(source):\(selectedModel ?? ""):\(selectedModel == nil ? range : detailRange)" }
    private var actualRange: Int { selectedModel == nil ? range : detailRange }
    private var snapshot: NativeStatsSnapshot? { state.snapshot(source: source, range: actualRange, model: selectedModel) }
    private var current: JSONValue { snapshot?.payload ?? .null }
    private var currentBenchmark: JSONValue { snapshot?.benchmark ?? .null }
    private func load(mode: NativeStatsLoadMode = .cached) async {
        // This callback also serves stats.scanned. Its ordinary read must remain
        // eligible to publish the exact generation acknowledged by the header.
        await state.load(source: source, range: actualRange, model: selectedModel, mode: mode)
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
    var body: some View {
        GeometryReader { geometry in
            let compact = min(960, geometry.size.width) - 2 * density.pageMargin < 640
            let shown = retained.resolve(snapshot, model: selectedModel, failed: !state.error.isEmpty)
            Group {
                if let model = selectedModel {
                    NativePage(title: model.split(separator: "/").last.map(String.init) ?? model,
                               eyebrow: model.contains("/") ? model : "Model statistics",
                               readiness: measuredReadiness, backTitle: "Back to Statistics", back: { selectedModel = nil },
                               actions: { headerActions }) {
                        pageContents(shown, compact: compact)
                    }
                } else {
                    NativePage(title: "Statistics", eyebrow: "Token usage", readiness: measuredReadiness, actions: { headerActions }) {
                        pageContents(shown, compact: compact)
                    }
                }
            }
        }
        .environment(\.nativePageVisit, headerVisit?.visit ?? navigationVisit)
        .nativePageTask(id: scope) {
            endHeaderVisit(reason: .scopeChanged)
            await state.begin(runtime: runtime, owner: readOwner) { await load() }
        }
        .onAppear {
            if !(["all"] + StatisticsSource.allCases.map(\.rawValue)).contains(source) { source = "all" }
            if ![0, 7, 30].contains(range) { range = 0 }
        }
        .onChange(of: scope) { _, _ in endHeaderVisit(reason: .scopeChanged) }
        .onDisappear { endHeaderVisit(reason: .disappeared) }
        .nativePageActivity(suspended: { endHeaderVisit(reason: .inactive); state.stop(owner: readOwner) })
    }

    // One primary per view: Reload on the overview, the export on a model.
    @ViewBuilder private var headerActions: some View {
        Menu {
            Button("Rebuild All") { reload(.rebuild, trigger: .rebuild) }
                .help("Reparse every usage file, including files whose size and modification time stayed the same")
        } label: { NativeStatsMenuGlyph() }
            .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
            .help("Statistics actions")
            .accessibilityLabel("Statistics actions").disabled(state.busy)
        if let model = selectedModel {
            Button("Refresh", nativeIcon: "refresh-cw") { reload(.refresh, trigger: .refresh) }
                .buttonStyle(Press(.secondary))
                .disabled(state.busy).help("Check for new or changed usage without reparsing unchanged history")
            Button("Export CSV", nativeIcon: "download") { Task { await state.export(model: model, source: source, range: detailRange) } }
                .buttonStyle(Press(.primary))
                .disabled(current["derived"]["days"].array.isEmpty).help("Export daily CSV")
        } else {
            Button("Reload", nativeIcon: "refresh-cw") { reload(.refresh, trigger: .refresh) }
                .buttonStyle(Press(.primary))
                .disabled(state.busy).help("Check for new or changed usage without reparsing unchanged history")
        }
    }

    private var sourceOptions: [(value: String, label: String)] {
        [(value: "all", label: "All apps")] + StatisticsSource.allCases.map { (value: $0.rawValue, label: nativeStatsSourceName($0.rawValue)) }
    }
    private var rangeOptions: [(value: Int, label: String)] {
        selectedModel == nil
            ? [(value: 7, label: "7 days"), (value: 30, label: "30 days"), (value: 0, label: "All time")]
            : [7, 30, 90, 365, 0].map { (value: $0, label: $0 == 0 ? "All time" : $0 == 365 ? "1 year" : "\($0) days") }
    }
    private var rangeSelection: Binding<Int> {
        selectedModel == nil ? $range : $detailRange
    }
    private var sourceNote: String {
        ["all": "Each app counted separately, then added together", "claude": "Claude Code transcripts and lifetime cache", "codex": "Codex sessions and archived sessions", "antigravity": "Antigravity app, IDE and ACP conversations", "zcode": "Z Code from z.ai sessions and model usage", "opencode": "OpenCode sessions and their sub-agents", "dsh": "DeepSeek Harness records; streaming uses host-observed arrivals"][source] ?? ""
    }
    /// Which app and which span: the two questions every reading below answers.
    /// Stops while they fit, the same choices as menus when they do not.
    private var scopeControls: some View {
        let sourceStops = Stops(options: sourceOptions, selection: source) { source = $0 }
        let rangeStops = Stops(options: rangeOptions, selection: rangeSelection.wrappedValue) { rangeSelection.wrappedValue = $0 }
        let sourcePick = Pick(title: "App", selection: $source, options: sourceOptions)
        return ViewThatFits(in: .horizontal) {
            HStack(spacing: 24) { sourceStops; Spacer(minLength: 0); rangeStops }
            HStack(spacing: 12) { sourcePick; Spacer(minLength: 0); rangeStops }
            HStack(spacing: 12) { sourcePick; Spacer(minLength: 0); Pick(title: "Range", selection: rangeSelection, options: rangeOptions) }
        }
        .help(sourceNote)
    }
    @ViewBuilder private func pageContents(_ shown: NativeStatsSnapshot?, compact: Bool) -> some View {
        scopeControls
        if !state.error.isEmpty { Notice(text: state.error, tone: .fail).accessibilityLabel("Error: " + state.error) }
        if let shown {
            NativeStatsContents(payload: shown.payload, benchmark: shown.benchmark, detail: selectedModel != nil, compact: compact,
                                progress: state.busy ? state.readProgress : nil,
                                selectModel: { model in detailRange = range; selectedModel = model }, selectSource: { source = $0 })
        } else if state.busy {
            NativeStatsProgressLabel(progress: state.readProgress).padding(.vertical, 12)
        } else if state.error.isEmpty {
            Text("Reading saved usage").font(Theme.ui(12.5)).foregroundStyle(Theme.muted).padding(.vertical, 12)
        }
    }
}

/// The scan's own words for where it is. It observes the progress object
/// itself, so a file counter never re-evaluates the page.
private struct NativeStatsProgressLabel: View {
    @ObservedObject var progress: NativeStatsReadProgress
    var body: some View {
        HStack(spacing: 7) {
            Theme.signal.frame(width: 2, height: 9)
            Text(NativeStatsPresentationPolicy.progressText(progress.value).replacingOccurrences(of: "…", with: ""))
                .font(Theme.ui(11.5)).foregroundStyle(Theme.muted).monospacedDigit().lineLimit(1)
        }
        .accessibilityElement(children: .combine)
    }
}

private struct NativeStatsMenuGlyph: View {
    @State private var hovering = false
    @Environment(\.isEnabled) private var enabled
    var body: some View {
        NativeIcon("ellipsis", size: 14, strokeWidth: 1.75)
            .foregroundStyle(hovering ? Theme.ink : Theme.muted)
            .frame(width: 28, height: 28)
            .background(RoundedRectangle(cornerRadius: Theme.radiusControl, style: .continuous).fill(hovering ? Theme.hover : .clear))
            .contentShape(Rectangle())
            .opacity(enabled ? 1 : 0.4)
            .onHover { hovering = $0 && enabled }
    }
}

func nativeStatsSourceName(_ source: String) -> String { ["all": "All apps", "claude": "Claude Code", "codex": "Codex", "antigravity": "Antigravity", "zcode": "Z Code", "opencode": "OpenCode", "dsh": "DeepSeek Harness"][source] ?? source }
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

/// The five token kinds, in the order a request spends them. Each keeps one
/// series hue on the tape, in its column and on the cache readout.
private enum NativeStatsKind: String, CaseIterable {
    case input, output, thinking, cacheWrite, cacheRead
    var label: String {
        switch self {
        case .input: return "Fresh input"; case .output: return "Output"; case .thinking: return "Thinking"
        case .cacheWrite: return "Cache writes"; case .cacheRead: return "Cache reads"
        }
    }
    var color: Color {
        switch self {
        case .input: return Theme.pairPalette[0]; case .output: return Theme.pairPalette[2]; case .thinking: return Theme.pairPalette[4]
        case .cacheWrite: return Theme.pairPalette[3]; case .cacheRead: return Theme.pairPalette[6]
        }
    }
}

private func nativeStatsPercent(_ part: Double, of whole: Double) -> String {
    whole > 0 ? String(format: "%.1f%%", part * 100 / whole) : "--"
}
private func nativeStatsWhole(_ value: Double) -> String {
    value.isFinite ? value.formatted(.number.locale(Locale(identifier: "en_US")).precision(.fractionLength(0))) : "--"
}
func nativeStatsMoney(_ value: Double) -> String {
    value > 0 && value < 0.01 ? "<$0.01"
        : "$" + value.formatted(.number.locale(Locale(identifier: "en_US")).precision(.fractionLength(2)))
}
private func nativeStatsPlural(_ count: Int, _ noun: String) -> String { "\(nativeStatsWhole(Double(count))) " + (count == 1 ? noun : noun + "s") }

private struct NativeStatsContents: View {
    let payload: JSONValue, benchmark: JSONValue, detail: Bool, compact: Bool
    let progress: NativeStatsReadProgress?
    let selectModel: (String) -> Void
    let selectSource: (String) -> Void
    @Environment(\.nativeInterfaceDensity) private var density
    private var d: JSONValue { payload["derived"] }
    private var t: JSONValue { d["summary"]["totals"] }
    private var vacant: Bool {
        nativeStatsGrand(t) <= 0 && t["messages"].double <= 0 && d["days"].array.isEmpty && d["models"].array.isEmpty && d["projects"].array.isEmpty
    }
    private var showsBenchmarks: Bool {
        (detail || payload["source"].string == "all") && (benchmark["spend"]["calls"].int > 0 || !benchmark["trend"].array.isEmpty)
    }
    var body: some View {
        // Eager on purpose: sections this unequal make a lazy stack re-estimate
        // and re-place itself without end at some scroll offsets.
        VStack(alignment: .leading, spacing: density.pageGap) {
            ForEach(Array(payload["warnings"].array.enumerated()), id: \.offset) { _, warning in
                Notice(text: warning.string, tone: .warn).accessibilityLabel("Error: " + warning.string)
            }
            NativeStatsHero(totals: t, summary: d["summary"], lifetime: d["isLifetime"].bool, progress: progress)
            if vacant {
                // Nothing in this scope: one statement, then the apps being watched,
                // instead of a column of empty sections.
                Blank(icon: "chart-bar", title: detail ? "This model has no usage here" : (payload["source"].string == "all" ? "Waiting for a first response" : "This app has no usage here"),
                      detail: payload["source"].string == "all" && !detail
                          ? "Responses from the coding apps below are counted as soon as one is on disk. A wider range may hold older usage."
                          : "Try a wider range or another app.")
                if payload["source"].string == "all" {
                    NativeStatsSourceBoard(sources: payload["sources"], throughput: d["throughput"], detail: detail, select: selectSource)
                }
            } else {
                readings
                if detail { perResponse; NativeStatsPricing(cost: d["cost"], compact: compact) }
                if d["days"].array.isEmpty {
                    NativeStatsBand("Per day") {
                        Blank(icon: "chart-bar", title: "No dated history in this range",
                              detail: d["isLifetime"].bool ? "Lifetime totals are available, but earlier transcripts are no longer on disk." : "Try another range or source.")
                    }
                } else {
                    NativeStatsDaily(data: d, colors: payload["colors"])
                    if detail { NativeStatsCumulative(days: d["days"].array) }
                }
                if !detail {
                    NativeStatsModelBoard(models: d["models"].array, lifetime: d["isLifetime"].bool, colors: payload["colors"],
                                          cost: d["cost"], compact: compact, select: selectModel)
                }
                ColumnFlow(minimum: 340, spacing: 32, rowSpacing: density.pageGap, maxColumns: 2) {
                    if payload["source"].string == "all" {
                        NativeStatsSourceBoard(sources: payload["sources"], throughput: d["throughput"], detail: detail, select: selectSource)
                    }
                    NativeStatsProjectBoard(rows: d["projects"].array, all: detail)
                    NativeStatsHeat(grid: d["heat"].array)
                    NativeStatsDrive(summary: detail ? payload["datedSummary"] : d["summary"])
                }
                NativeStatsThroughput(data: d["throughput"], colors: payload["colors"], compact: compact, modelDetail: detail,
                                      selectModel: detail ? nil : selectModel)
            }
            // Detail uses an exact model/range-filtered benchmark payload.
            // The unfiltered overview ledger belongs only to All apps.
            if showsBenchmarks { NativeStatsBenchmark(data: benchmark, detail: detail, compact: compact) }
            if !payload["cache"].isNull { reconciliation }
            footer
        }
        .accessibilityElement(children: .contain)
    }

    private var prompt: Double { t["input"].double + t["cacheRead"].double + t["cacheWrite"].double }
    private var costReading: some View {
        NativeStatsReadout(label: "Estimated API cost", value: d["cost"]["pricedTokens"].double > 0 ? d["cost"]["usd"].double : nil, unit: "USD", detail: costDetail)
    }
    private var cacheReading: some View {
        NativeStatsReadout(label: detail ? "Cache efficiency" : "Served from cache", value: prompt > 0 ? t["cacheRead"].double * 100 / prompt : nil, unit: "%",
                           detail: "\(nativeStatsCount(t["cacheRead"].double)) of \(nativeStatsCount(prompt)) prompt tokens",
                           tint: NativeStatsKind.cacheRead.color, format: { String(format: "%.1f", $0) })
    }
    private var costDetail: String {
        let cost = d["cost"]
        if cost.isNull { return "Prices not available yet" }
        if cost["pricedTokens"].double > 0 {
            return cost["unpricedTokens"].double > 0 ? "Partial estimate · unknown costs excluded" : "Based on current API rates"
        }
        return cost["unpricedTokens"].double > 0 ? "Prices missing for this usage" : "No usage recorded yet"
    }
    // Four across, or two and two: never three with one left over.
    private var readings: some View {
        ViewThatFits(in: .horizontal) {
            readings(columns: 4)
            readings(columns: 2)
        }
    }
    private func readings(columns: Int) -> some View {
        let summary = d["summary"]
        return ColumnFlow(minimum: 170, spacing: 24, rowSpacing: 22, maxColumns: columns) {
            costReading
            if detail {
                NativeStatsReadout(label: "Recorded responses", value: payload["coverage"]["datedTotals"]["messages"].double,
                                   detail: nativeStatsPlural(summary["sessions"].int, "session") + " · " + nativeStatsPlural(summary["projects"].int, "project"),
                                   format: nativeStatsWhole)
                NativeStatsReadout(label: "Active days", value: summary["activeDays"].double,
                                   detail: payload["coverage"]["first"].isNull ? "No dated records" : "First recorded \(nativeStatsDate(payload["coverage"]["first"].double))",
                                   format: nativeStatsWhole)
            } else {
                NativeStatsReadout(label: "Responses", value: t["messages"].double,
                                   detail: nativeStatsPlural(summary["sessions"].int, "session"), format: nativeStatsWhole)
                NativeStatsReadout(label: "Models", value: summary["models"].double,
                                   detail: nativeStatsPlural(summary["projects"].int, "project"), format: nativeStatsWhole)
            }
            cacheReading
        }
    }
    @ViewBuilder private var perResponse: some View {
        let dated = payload["coverage"]["datedTotals"], messages = dated["messages"].double, days = d["summary"]["activeDays"].double
        ReadoutStrip(minimum: 170) {
            NativeStatsReadout(label: "Tokens per response", value: messages > 0 ? nativeStatsGrand(dated) / messages : nil, size: .medium, format: nativeStatsCount)
            NativeStatsReadout(label: "Output per response", value: messages > 0 ? dated["output"].double / messages : nil, size: .medium, format: nativeStatsCount)
            NativeStatsReadout(label: "Responses per active day", value: days > 0 ? messages / days : nil, size: .medium)
        }
    }
    private var reconciliation: some View {
        NativeStatsBand("Against /stats", hint: "Lifetime history and de-duplicated disk records measure different things") {
            VStack(alignment: .leading, spacing: 14) {
                ReadoutStrip(minimum: 170) {
                    NativeStatsReadout(label: "Lifetime", value: nativeStatsGrand(payload["cache"]["totals"]), unit: "tokens", size: .medium, format: nativeStatsCount)
                    NativeStatsReadout(label: "Raw disk", value: payload["scan"]["rawGrand"].double, unit: "tokens", size: .medium, format: nativeStatsCount)
                    NativeStatsReadout(label: "De-duplicated disk", value: d["onDiskGrand"].double, unit: "tokens", size: .medium, format: nativeStatsCount)
                }
                Text("\(payload["scan"]["duplicates"].int) repeated blocks; \(payload["dayMatch"]["matched"].int)/\(payload["dayMatch"]["checked"].int) comparable UTC days agree.")
                    .font(Theme.ui(11.5)).foregroundStyle(Theme.muted).textSelection(.enabled)
                NativeStatsDisclosure(title: "How these totals differ") {
                    Text("Claude's lifetime cache includes repeated content blocks and retained pruned history. Dated charts deduplicate response IDs. Only responses on UTC days after the cache watermark are added to the lifetime baseline.")
                        .font(Theme.ui(12.5)).foregroundStyle(Theme.dim).lineSpacing(2)
                        .fixedSize(horizontal: false, vertical: true).frame(maxWidth: 620, alignment: .leading)
                }
            }
        }
    }
    @ViewBuilder private var footer: some View {
        let excluded = NativeStatsPresentationPolicy.excludedNotices(payload, detail: detail)
        if !excluded.isEmpty || !detail {
            VStack(alignment: .leading, spacing: 5) {
                ForEach(excluded, id: \.source) { notice in
                    Text("\(nativeStatsSourceName(notice.source)): \(notice.count) records have no usable usage metadata.")
                        .font(Theme.ui(11.5)).foregroundStyle(Theme.muted)
                }
                if !detail {
                    Text("\(payload["scan"]["files"].int) files · \(nativeStatsCount(payload["scan"]["bytes"].double)) bytes · scan \(payload["scan"]["elapsedMs"].double.formatted(.number.precision(.fractionLength(0)))) ms")
                        .font(Theme.mono(10.5)).foregroundStyle(Theme.faint).textSelection(.enabled)
                }
            }
        }
    }
}

/// The reading the page exists for, and what it is made of.
private struct NativeStatsHero: View {
    let totals: JSONValue, summary: JSONValue, lifetime: Bool
    let progress: NativeStatsReadProgress?
    private var grand: Double { nativeStatsGrand(totals) }
    private var span: String {
        let first = summary["first"], last = summary["last"]
        var parts: [String] = []
        if !first.isNull { parts.append("\(nativeStatsDate(first.double)) to \(nativeStatsDate(last.double))") }
        if summary["activeDays"].int > 0 { parts.append(nativeStatsPlural(summary["activeDays"].int, "active day")) }
        return parts.isEmpty ? "No usage recorded in this range" : parts.joined(separator: " · ")
    }
    private var parts: [NativeStatsTape.Part] {
        let thinking = min(totals["thinking"].double, totals["output"].double)
        return [
            .init(id: "input", value: totals["input"].double, color: NativeStatsKind.input.color),
            .init(id: "output", value: totals["output"].double - thinking, color: NativeStatsKind.output.color),
            .init(id: "thinking", value: thinking, color: NativeStatsKind.thinking.color),
            .init(id: "cacheWrite", value: totals["cacheWrite"].double, color: NativeStatsKind.cacheWrite.color),
            .init(id: "cacheRead", value: totals["cacheRead"].double, color: NativeStatsKind.cacheRead.color),
        ]
    }
    private func kinds(columns: Int) -> some View {
        ColumnFlow(minimum: 128, spacing: 24, rowSpacing: 14, maxColumns: columns) {
            ForEach(NativeStatsKind.allCases, id: \.self) { kind in
                NativeStatsKindReading(kind: kind, totals: totals)
            }
        }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .center, spacing: 12) {
                MicroLabel(lifetime ? "Tokens processed · lifetime" : "Tokens processed")
                Spacer(minLength: 8)
                if let progress { NativeStatsProgressLabel(progress: progress) }
            }
            .frame(height: 16)
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(nativeStatsCount(grand)).font(Theme.readout(54)).monospacedDigit().lineLimit(1)
                    .foregroundStyle(grand > 0 ? Theme.ink : Theme.faint)
                    .nativeStatsNumberTransition(grand)
                MicroLabel("tokens", size: 11)
            }
            .padding(.top, 2)
            .accessibilityElement(children: .ignore).accessibilityLabel("Tokens processed")
            .accessibilityValue(nativeStatsCount(grand) + " tokens")
            Text(span).font(Theme.ui(12.5)).foregroundStyle(Theme.muted).lineLimit(1).padding(.top, 2)
            if lifetime {
                Text("Includes Claude's lifetime cache. Charts, responses, projects and speed use the records still on disk; pruned history cannot be rebuilt.")
                    .font(Theme.ui(11.5)).foregroundStyle(Theme.muted).fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 4)
            }
            NativeStatsTape(parts: parts).padding(.top, 22)
            // Five across, or three and two: never four with one left over.
            ViewThatFits(in: .horizontal) {
                kinds(columns: 5)
                kinds(columns: 3)
            }
            .padding(.top, 14)
        }
    }
}

private struct NativeStatsKindReading: View {
    let kind: NativeStatsKind, totals: JSONValue
    var body: some View {
        let value = totals[kind.rawValue].double
        let share = kind == .thinking ? nativeStatsPercent(value, of: totals["output"].double) + " of output"
            : nativeStatsPercent(value, of: nativeStatsGrand(totals))
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                NativeSeriesTick(color: kind.color, height: 9)
                MicroLabel(kind.label)
            }
            let count = Text(nativeStatsCount(value)).font(Theme.readout(17)).monospacedDigit().foregroundStyle(value > 0 ? Theme.ink : Theme.faint)
                .lineLimit(1).fixedSize().nativeStatsNumberTransition(value)
            let part = Text(share).font(Theme.mono(10.5)).foregroundStyle(Theme.muted).lineLimit(1).fixedSize()
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .firstTextBaseline, spacing: 6) { count; part }
                VStack(alignment: .leading, spacing: 2) { count; part }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .help(kind == .thinking ? "Thinking is a subset of generated output; its percentage uses output as the denominator." : value.formatted())
        .accessibilityElement(children: .ignore).accessibilityLabel(kind.label)
        .accessibilityValue(nativeStatsCount(value) + " tokens, " + share)
    }
}

/// The per-model ledger. A row is the way into that model's own page; the
/// rates behind the cost column stay folded beneath it.
private struct NativeStatsModelBoard: View {
    let models: [JSONValue], lifetime: Bool, colors: JSONValue, cost: JSONValue, compact: Bool, select: (String) -> Void
    @AppStorage("uniapi.stats.metric") private var metric = "tokens"
    private func value(_ row: JSONValue) -> Double { metric == "tokens" ? nativeStatsGrand(row["totals"]) : row["totals"][metric == "output" ? "output" : "messages"].double }
    private var barWidth: CGFloat { compact ? 64 : 200 }
    private func price(_ row: JSONValue) -> String {
        guard !row.isNull, !row["usd"].isNull else { return "--" }
        return nativeStatsMoney(row["usd"].double)
    }
    var body: some View {
        let ranked = models.sorted { value($0) > value($1) }
        let peak = max(1, ranked.first.map(value) ?? 0)
        let prices = Dictionary(cost["rows"].array.map { ($0["model"].string, $0) }, uniquingKeysWith: { first, _ in first })
        NativeStatsBand(title: "Models", hint: lifetime ? "Lifetime totals; pruned transcripts keep theirs" : "", spacing: 0) {
            Stops(options: [("tokens", "Tokens"), ("output", "Output")] + (lifetime ? [] : [("messages", "Responses")]), selection: metric) { metric = $0 }
        } content: {
            LedgerHead {
                Color.clear.frame(width: 18, height: 1)
                MicroLabel("Model").frame(maxWidth: .infinity, alignment: .leading).padding(.leading, 15)
                Color.clear.frame(width: barWidth, height: 1)
                if !compact {
                    MicroLabel("Days").frame(width: 40, alignment: .trailing)
                    MicroLabel("Sessions").frame(width: 76, alignment: .trailing)
                }
                MicroLabel("Est. cost").frame(width: 72, alignment: .trailing)
                MicroLabel(metric == "tokens" ? "Tokens" : metric == "output" ? "Output" : "Responses").frame(width: 84, alignment: .trailing)
                Color.clear.frame(width: 12, height: 1)
            }
            .padding(.top, 6)
            if ranked.isEmpty {
                Blank(icon: "layers", title: "No models in this range", detail: "Models appear here once a response is recorded.")
            }
            ForEach(Array(ranked.enumerated()), id: \.offset) { index, row in
                let name = row["model"].string, priced = prices[name] ?? .null
                LedgerRow(action: { select(name) }) {
                    HStack(spacing: 12) {
                        Text(String(format: "%02d", index + 1)).font(Theme.mono(10.5)).foregroundStyle(Theme.faint).frame(width: 18, alignment: .leading)
                        NativeSeriesTick(color: nativeStatsColor(colors[name].string))
                        HStack(spacing: 6) {
                            Text(name).font(Theme.mono(12)).foregroundStyle(Theme.ink).lineLimit(1).truncationMode(.middle)
                            if row["viaProxy"].bool { Tag("proxy", tone: Theme.warnFg) }
                            if row["pruned"].bool { Tag("pruned") }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        Scale(fraction: value(row) / peak, color: nativeStatsColor(colors[name].string)).frame(width: barWidth)
                        if !compact {
                            Text("\(row["days"].int)").font(Theme.mono(11.5)).foregroundStyle(Theme.dim).frame(width: 40, alignment: .trailing)
                            Text("\(row["sessions"].int)").font(Theme.mono(11.5)).foregroundStyle(Theme.dim).frame(width: 76, alignment: .trailing)
                        }
                        Text(price(priced)).font(Theme.mono(11.5)).monospacedDigit()
                            .foregroundStyle(priced["usd"].isNull ? Theme.faint : Theme.dim).frame(width: 72, alignment: .trailing)
                        Text(nativeStatsCount(value(row))).font(Theme.readout(17)).monospacedDigit().foregroundStyle(Theme.ink)
                            .nativeStatsNumberTransition(value(row)).frame(width: 84, alignment: .trailing)
                        NativeIcon("arrow-up-right", size: 12, strokeWidth: 1.75).foregroundStyle(Theme.muted)
                    }
                }
                .help("Open full history for \(name)")
            }
            NativeStatsPricing(cost: cost, compact: compact).padding(.top, 10)
        }
        .onChange(of: lifetime) { _, yes in if yes && metric == "messages" { metric = "tokens" } }
        .onAppear { if lifetime && metric == "messages" { metric = "tokens" } }
    }
}

/// Each app's share of the total. A row narrows the whole page to that app.
private struct NativeStatsSourceBoard: View {
    let sources: JSONValue, throughput: JSONValue, detail: Bool, select: (String) -> Void
    var body: some View {
        let peak = max(1, StatisticsSource.allCases.map { nativeStatsGrand(sources[$0.rawValue]) }.max() ?? 0)
        NativeStatsBand("Apps", spacing: 0) {
            LedgerHead {
                MicroLabel("App").frame(maxWidth: .infinity, alignment: .leading).padding(.leading, 15)
                Color.clear.frame(width: 72, height: 1)
                if !detail { MicroLabel("Tok/s").frame(width: 56, alignment: .trailing) }
                MicroLabel("Tokens").frame(width: 64, alignment: .trailing)
            }
            .padding(.top, 6)
            ForEach(StatisticsSource.allCases, id: \.rawValue) { s in
                NativeStatsSourceRow(source: s.rawValue, value: sources[s.rawValue], peak: peak, detail: detail,
                                     stream: NativeStatsThroughputPresentation.streamingSource(throughput, source: s.rawValue),
                                     select: select)
            }
        }
    }
}

private struct NativeStatsSourceRow: View {
    let source: String, value: JSONValue, peak: Double, detail: Bool, stream: JSONValue
    let select: (String) -> Void
    private var name: String { nativeStatsSourceName(source) }
    private var grand: Double { nativeStatsGrand(value) }
    private var hasUsage: Bool { grand > 0 || value["messages"].double > 0 }
    private var rate: Double? { hasUsage ? NativeStatsThroughputPresentation.rate(stream) : nil }
    private var rateText: String { rate.map { String(format: "%.1f", $0) } ?? "--" }
    private var explanation: String {
        guard hasUsage else { return "No recorded usage" }
        let split = "\(nativeStatsCount(value["output"].double)) output · \(nativeStatsCount(value["cacheRead"].double)) cached. "
        guard rate != nil else {
            return split + NativeStatsThroughputPresentation.missingClockLabel(source: source)
                + ". A streaming rate needs token-arrival timestamps; elapsed tool and response time cannot replace them."
        }
        return split + NativeStatsRateMetric.streaming.timingDetail(stream)
    }
    private var spoken: String {
        guard hasUsage else { return "No recorded usage" }
        return "Streaming tokens per second: " + (rate == nil ? "Unavailable" : rateText) + ". " + NativeStatsRateMetric.streaming.coverage(stream)
    }
    var body: some View {
        LedgerRow(action: { select(source) }) {
            HStack(spacing: 12) {
                NativeSeriesTick(color: hasUsage ? nativeStatsHarnessColor(source) : Theme.track)
                Text(name).font(Theme.ui(13)).foregroundStyle(hasUsage ? Theme.ink : Theme.muted).lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Scale(fraction: grand / peak, color: nativeStatsHarnessColor(source)).frame(width: 72)
                if !detail {
                    Text(rateText).font(Theme.mono(11.5)).monospacedDigit()
                        .foregroundStyle(rate == nil ? Theme.faint : Theme.dim).frame(width: 56, alignment: .trailing)
                }
                Text(value.isNull ? "--" : nativeStatsCount(grand)).font(Theme.readout(17)).monospacedDigit()
                    .foregroundStyle(hasUsage ? Theme.ink : Theme.faint)
                    .nativeStatsNumberTransition(value.isNull ? nil : grand)
                    .frame(width: 64, alignment: .trailing)
            }
        }
        .help(explanation)
        .accessibilityLabel("Open \(name) statistics")
        .accessibilityValue(spoken)
    }
}

private struct NativeStatsProjectBoard: View {
    let rows: [JSONValue], all: Bool
    @State private var showsAll = false
    var body: some View {
        let shown = all || showsAll ? rows : Array(rows.prefix(8))
        let peak = max(1, rows.map { nativeStatsGrand($0["totals"]) }.max() ?? 0)
        NativeStatsBand("Projects", spacing: 0) {
            LedgerHead {
                MicroLabel("Working directory").frame(maxWidth: .infinity, alignment: .leading)
                Color.clear.frame(width: 72, height: 1)
                MicroLabel("Sessions").frame(width: 84, alignment: .trailing)
                MicroLabel("Tokens").frame(width: 64, alignment: .trailing)
            }
            .padding(.top, 6)
            if rows.isEmpty {
                Blank(icon: "folder", title: "No projects in this range", detail: "Working directories recorded by the selected apps appear here.")
            }
            ForEach(Array(shown.enumerated()), id: \.offset) { _, row in
                LedgerRow {
                    HStack(spacing: 12) {
                        Text(row["name"].string).font(Theme.mono(12)).foregroundStyle(Theme.ink).lineLimit(1).truncationMode(.middle)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        Scale(fraction: nativeStatsGrand(row["totals"]) / peak).frame(width: 72)
                        Text("\(row["sessions"].int)").font(Theme.mono(11.5)).monospacedDigit().foregroundStyle(Theme.dim).frame(width: 84, alignment: .trailing)
                        Text(nativeStatsCount(nativeStatsGrand(row["totals"]))).font(Theme.readout(17)).monospacedDigit().foregroundStyle(Theme.ink)
                            .nativeStatsNumberTransition(nativeStatsGrand(row["totals"])).frame(width: 64, alignment: .trailing)
                    }
                }
                .help(row["path"].string)
            }
            if !all && rows.count > 8 {
                Button(showsAll ? "Show the top 8" : "Show all \(rows.count) projects") { showsAll.toggle() }
                    .buttonStyle(Press(.quiet)).padding(.leading, -8).padding(.top, 6)
            }
        }
    }
}

/// Responses by weekday and hour, on an hour rule. Ink density is the count.
private struct NativeStatsHeat: View {
    let grid: [JSONValue]
    private var maximum: Double { grid.flatMap(\.array).map(\.double).max() ?? 0 }
    private let days = ["Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun"]
    private let names = ["Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday", "Sunday"]
    var body: some View {
        let peak = maximum
        let hours = (0..<24).map { hour in grid.reduce(0) { $0 + ($1.array.count > hour ? $1.array[hour].double : 0) } }
        let best = hours.enumerated().max { $0.element < $1.element }
        NativeStatsBand("Rhythm", hint: "Responses by local weekday and hour") {
            VStack(alignment: .leading, spacing: 0) {
                VStack(spacing: 2) {
                    ForEach(0..<min(7, grid.count), id: \.self) { day in
                        HStack(spacing: 2) {
                            MicroLabel(days[day]).frame(width: 34, alignment: .leading)
                            ForEach(0..<24, id: \.self) { hour in
                                let value = grid[day].array.count > hour ? grid[day].array[hour].double : 0
                                Rectangle().fill(value > 0 ? Theme.ink.opacity(0.14 + 0.86 * value / max(1, peak)) : Theme.track)
                                    .frame(minWidth: 5, maxWidth: .infinity, minHeight: 15, maxHeight: 15)
                                    .help("\(names[day]) \(hour):00: \(Int(value)) responses")
                                    .accessibilityLabel("Day \(day + 1), hour \(hour), \(Int(value)) responses")
                            }
                        }
                    }
                }
                VStack(spacing: 3) {
                    TickScale(divisions: 24, major: 6, minorHeight: 3, majorHeight: 6).fill(Theme.faint).frame(height: 6)
                    HStack(spacing: 0) {
                        Text("00").frame(maxWidth: .infinity, alignment: .leading)
                        Text("06").frame(maxWidth: .infinity, alignment: .leading)
                        Text("12").frame(maxWidth: .infinity, alignment: .leading)
                        Text("18").frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .font(Theme.mono(10.5)).foregroundStyle(Theme.faint)
                }
                .padding(.leading, 36).padding(.top, 5).accessibilityHidden(true)
                Text(peak > 0 ? "Busiest hour \(String(format: "%02d", best?.offset ?? 0)):00 · fullest cell holds \(Int(peak)) responses" : "No dated activity")
                    .font(Theme.ui(11.5)).foregroundStyle(Theme.muted).padding(.top, 10)
            }
        }
    }
}

private struct NativeStatsDrive: View {
    let summary: JSONValue
    var body: some View {
        let efforts = summary["effort"].object.keys.sorted()
        let total = max(1, efforts.reduce(0) { $0 + summary["effort"][$1].double })
        NativeStatsBand("How you drive it", spacing: 0) {
            ForEach(efforts, id: \.self) { key in
                LedgerRow(minHeight: 28) {
                    HStack(spacing: 12) {
                        Text("Effort " + (key.isEmpty ? "unset" : key)).font(Theme.ui(12.5)).foregroundStyle(Theme.ink).lineLimit(1)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        Scale(fraction: summary["effort"][key].double / total).frame(width: 72)
                        Text(nativeStatsWhole(summary["effort"][key].double)).font(Theme.mono(12)).monospacedDigit().foregroundStyle(Theme.ink)
                            .frame(width: 64, alignment: .trailing)
                    }
                }
            }
            fact("Subagent turns", value: summary["sidechainMessages"].int, detail: "\(nativeStatsCount(summary["sidechainTokens"].double)) tokens")
            fact("Through the proxy", value: summary["proxyMessages"].int, detail: "Claude responses from a gateway model")
            fact("Web searches", value: summary["totals"]["webSearch"].int, detail: "Reported server-side searches")
            fact("Page fetches", value: summary["totals"]["webFetch"].int, detail: "Reported server-side fetches")
        }
    }
    private func fact(_ title: String, value: Int, detail: String) -> some View {
        LedgerRow(minHeight: 28) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(title).font(Theme.ui(12.5)).foregroundStyle(Theme.ink).lineLimit(1).fixedSize()
                Text(detail).font(Theme.ui(11.5)).foregroundStyle(Theme.muted).lineLimit(1)
                Spacer(minLength: 8)
                Text(nativeStatsWhole(Double(value))).font(Theme.mono(12)).monospacedDigit().foregroundStyle(value == 0 ? Theme.faint : Theme.ink)
            }
        }
    }
}
