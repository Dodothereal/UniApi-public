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
    @State private var inspected: String?
    @State private var detailRange = 0
    @State private var headerVisit: NativeStatsHeaderVisit?
    @State private var headerReadiness = NativePageReadiness.pending
    @Environment(\.nativePageVisit) private var navigationVisit
    @Environment(\.nativePageActivation) private var activation
    @Environment(\.nativeInterfaceDensity) private var density
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
    private var inspectedRow: JSONValue? {
        guard selectedModel == nil, view == "models", let inspected else { return nil }
        return current["derived"]["models"].array.first { $0["model"].string == inspected }
    }
    var body: some View {
        NativePage(title: selectedModel.map { $0.split(separator: "/").last.map(String.init) ?? $0 } ?? "Statistics", maxWidth: .infinity, readiness: measuredReadiness, scrolls: false,
                   backTitle: "Statistics", back: selectedModel == nil ? nil : { selectedModel = nil },
                   tabs: {
                       if selectedModel == nil {
                           NativeTabs(options: [("usage", "Usage"), ("models", "Models"), ("projects", "Projects"), ("speed", "Speed")], selection: view) { view = $0 }
                       }
                   },
                   actions: { headerActions }) {
            GeometryReader { geometry in
                if selectedModel == nil, view == "models", current["loaded"].bool, !current["derived"]["models"].array.isEmpty {
                    NativeInspectorSplit(open: inspectedRow != nil, width: 340, onClose: { inspected = nil }, main: {
                        VStack(alignment: .leading, spacing: 0) {
                            if !state.error.isEmpty { NativeError(message: state.error).padding(.horizontal, density.pageMargin).padding(.vertical, 8) }
                            NativeStatsModelTable(models: current["derived"]["models"].array, lifetime: current["derived"]["isLifetime"].bool, colors: current["colors"], compact: inspectedRow != nil, selection: $inspected)
                        }
                    }, inspector: {
                        if let row = inspectedRow { modelInspector(row) }
                    })
                } else {
                    NativePane(maxWidth: 1280) {
                        if let model = selectedModel, model.contains("/") { Text(model).font(Theme.mono(Theme.textXs)).foregroundStyle(Theme.muted).textSelection(.enabled) }
                        pageContents(width: max(0, min(1280, geometry.size.width) - 2 * density.pageMargin))
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
    @ViewBuilder private var headerActions: some View {
        if selectedModel == nil {
            T3Segmented(options: [(7, "7d"), (30, "30d"), (0, "All")], selection: range) { range = $0 }
        } else {
            NativeMenuSelectLabel(title: detailRange == 0 ? "All time" : detailRange == 365 ? "1 year" : "\(detailRange) days") {
                ForEach([7, 30, 90, 365, 0], id: \.self) { days in Button(days == 0 ? "All time" : days == 365 ? "1 year" : "\(days) days") { detailRange = days } }
            }.fixedSize()
        }
        NativeMenuSelect(title: "Source", selection: $source,
                         options: [("all", "All apps")] + StatisticsSource.allCases.map { ($0.rawValue, nativeStatsSourceName($0.rawValue)) }, width: 132)
        if let model = selectedModel {
            T3IconButton(system: "download", help: "Export daily CSV") { Task { await state.export(model: model, source: source, range: detailRange) } }
                .disabled(current["derived"]["days"].array.isEmpty)
        }
        T3IconButton(system: "refresh-cw", help: "Read new or changed usage") { reload(.refresh, trigger: .refresh) }.disabled(state.busy)
        NativeIconMenu(help: "Statistics actions") {
            Button("Rebuild all") { reload(.rebuild, trigger: .rebuild) }
                .help("Reparse every usage file, including files whose size and modification time stayed the same")
        }.disabled(state.busy)
    }
    /// A model at a glance; its dated history opens from here.
    private func modelInspector(_ row: JSONValue) -> some View {
        let model = row["model"].string, totals = row["totals"]
        return NativeInspector(title: model.split(separator: "/").last.map(String.init) ?? model, caption: model.contains("/") ? model : "", onClose: { inspected = nil }) {
            VStack(spacing: 0) {
                NativeFact(label: "Tokens", value: nativeStatsCount(nativeStatsGrand(totals)))
                NativeFact(label: "Fresh input", value: nativeStatsCount(totals["input"].double))
                NativeFact(label: "Output", value: nativeStatsCount(totals["output"].double))
                NativeFact(label: "Thinking, inside output", value: nativeStatsCount(totals["thinking"].double))
                NativeFact(label: "Cache reads", value: nativeStatsCount(totals["cacheRead"].double))
                NativeFact(label: "Cache writes", value: nativeStatsCount(totals["cacheWrite"].double))
                if !current["derived"]["isLifetime"].bool { NativeFact(label: "Responses", value: nativeStatsCount(totals["messages"].double)) }
                NativeFact(label: "Sessions", value: "\(row["sessions"].int)")
                NativeFact(label: "Active days", value: "\(row["days"].int)")
            }
            if row["viaProxy"].bool { Text("Served through a gateway, not by Anthropic.").font(Theme.ui(Theme.textXs)).foregroundStyle(Theme.warnFg).fixedSize(horizontal: false, vertical: true) }
            if row["pruned"].bool { Text("Its transcripts were pruned. Totals are kept, dated history is not.").font(Theme.ui(Theme.textXs)).foregroundStyle(Theme.muted).fixedSize(horizontal: false, vertical: true) }
        } actions: {
            Button("History", nativeIcon: "chart-line") { detailRange = range; selectedModel = model }.buttonStyle(T3Button(.primary))
        }
    }
    @ViewBuilder private func pageContents(width: CGFloat) -> some View {
        if !state.error.isEmpty { NativeError(message: state.error) }
        if state.busy { NativeStatsProgressLabel(progress: state.readProgress, hasContent: current["loaded"].bool) }
        if current["loaded"].bool {
            NativeStatsContents(payload: current, benchmark: currentBenchmark, detail: selectedModel != nil, view: selectedModel != nil ? "detail" : view, selectModel: { model in detailRange = range; selectedModel = model }, selectSource: { source = $0 }, availableWidth: width)
                .id(scope)
        } else if !state.busy && state.error.isEmpty {
            ShimmerText(text: "Loading…", font: Theme.ui(12))
        }
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

struct NativeStatsMenuLabel: View {
    let title: String
    var width: CGFloat? = nil
    var body: some View {
        HStack(spacing: 8) { Text(title).lineLimit(1); if width != nil { Spacer(minLength: 0) }; NativeIcon("chevrons-up-down", size: 11).foregroundStyle(Theme.faint) }
            .font(Theme.ui(Theme.textXs, weight: .medium)).foregroundStyle(Theme.ink)
            .padding(.horizontal, 10).frame(height: Theme.control)
            .frame(width: width)
            .background(Theme.field, in: RoundedRectangle(cornerRadius: Theme.radiusMd, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: Theme.radiusMd, style: .continuous).strokeBorder(Theme.input, lineWidth: 1))
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

private struct NativeStatsContents: View {
    let payload: JSONValue, benchmark: JSONValue, detail: Bool
    var view = "usage"
    let selectModel: (String) -> Void
    let selectSource: (String) -> Void
    let availableWidth: CGFloat
    private var d: JSONValue { payload["derived"] }
    private var t: JSONValue { d["summary"]["totals"] }
    var body: some View {
        LazyVStack(alignment: .leading, spacing: 24) {
            if !detail, nativeStatsGrand(t) == 0, t["messages"].double == 0 {
                ForEach(Array(payload["warnings"].array.enumerated()), id: \.offset) { _, warning in NativeError(message: warning.string) }
                NativeEmptyState(title: "No usage recorded", detail: payload["source"].string == "all" ? "Sessions from Claude Code, Codex, Antigravity, Z Code and OpenCode on this Mac are counted here." : "Try another range or source.", icon: "chart-line")
            } else {
            if view == "projects" { NativeStatsProjectBoard(rows: d["projects"].array, all: true) }
            if view == "speed" {
                NativeStatsThroughput(data: d["throughput"], colors: payload["colors"], availableWidth: availableWidth, selectModel: selectModel)
                if payload["source"].string == "all" { NativeStatsBenchmark(data: benchmark) }
            }
            if view == "usage" || view == "detail" { usage }
            }
        }.font(Theme.ui(12)).foregroundStyle(Theme.ink)
            .accessibilityElement(children: .contain)
    }
    @ViewBuilder private var usage: some View {
            if payload["source"].string == "all" {
                let total = max(1, StatisticsSource.allCases.map { nativeStatsGrand(payload["sources"][$0.rawValue]) }.reduce(0, +))
                NativeStack {
                    ForEach(StatisticsSource.allCases.filter { nativeStatsGrand(payload["sources"][$0.rawValue]) > 0 || payload["sources"][$0.rawValue]["messages"].double > 0 }, id: \.rawValue) { s in
                        let value = payload["sources"][s.rawValue]
                        let stream = NativeStatsThroughputPresentation.streamingSource(d["throughput"], source: s.rawValue)
                        let hasUsage = nativeStatsGrand(value) > 0 || value["messages"].double > 0
                        Button { selectSource(s.rawValue) } label: {
                            HStack(alignment: .center, spacing: 16) {
                                Text(nativeStatsSourceName(s.rawValue)).font(Theme.ui(Theme.textSm, weight: .medium)).foregroundStyle(hasUsage ? Theme.ink : Theme.muted).lineLimit(1).frame(width: 136, alignment: .leading)
                                Text(hasUsage ? nativeStatsCount(nativeStatsGrand(value)) : "—").font(Theme.num(Theme.textSm)).foregroundStyle(hasUsage ? Theme.ink : Theme.faint).lineLimit(1).nativeStatsNumberTransition(value.isNull ? nil : nativeStatsGrand(value)).frame(width: 64, alignment: .trailing)
                                NativeTickMeter(fraction: nativeStatsGrand(value) / total, color: Theme.ink, height: 10).frame(minWidth: 60, maxWidth: .infinity)
                                if !detail, availableWidth >= 700 {
                                    Text(hasUsage ? "\(nativeStatsCount(value["output"].double)) out · \(nativeStatsCount(value["cacheRead"].double)) cached" : "").font(Theme.num(Theme.textXs, weight: .regular)).foregroundStyle(Theme.muted).lineLimit(1).frame(width: 170, alignment: .trailing)
                                    Group {
                                        if let rate = NativeStatsThroughputPresentation.rate(stream) { Text(String(format: "%.1f tok/s", rate)).help(NativeStatsRateMetric.streaming.timingDetail(stream)) }
                                        else { Text(hasUsage ? "—" : "").help(NativeStatsThroughputPresentation.missingClockLabel(source: s.rawValue) + ". A streaming rate needs token-arrival timestamps.") }
                                    }.font(Theme.num(Theme.textXs, weight: .regular)).foregroundStyle(Theme.dim).lineLimit(1).frame(width: 84, alignment: .trailing)
                                }
                                NativeIcon("chevron-right", size: 12).foregroundStyle(Theme.faint)
                            }.padding(.vertical, 11).padding(.horizontal, 4).contentShape(Rectangle())
                        }.buttonStyle(.plain).pointingHand().nativeStatsRowHover(radius: 0).accessibilityLabel("Open \(nativeStatsSourceName(s.rawValue)) statistics")
                            .accessibilityValue(hasUsage ? "Streaming tokens per second: " + (NativeStatsThroughputPresentation.rate(stream).map { String(format: "%.1f", $0) } ?? "Unavailable") + ". " + NativeStatsRateMetric.streaming.coverage(stream) : "No recorded usage")
                    }
                }
            }
            if d["isLifetime"].bool { Text("Lifetime totals include Claude's cache. Dated charts use the response records still on disk.").font(Theme.ui(Theme.textXs)).foregroundStyle(Theme.muted) }
            ForEach(Array(payload["warnings"].array.enumerated()), id: \.offset) { _, warning in NativeError(message: warning.string) }
            ForEach(NativeStatsPresentationPolicy.excludedNotices(payload, detail: detail), id: \.source) { notice in
                Text("\(nativeStatsSourceName(notice.source)): \(notice.count) records have no usable usage metadata.").font(Theme.ui(11)).foregroundStyle(Theme.muted)
            }
            NativeReadoutStrip(minCell: 190) {
                NativeStatsValueTile(label: "Tokens processed", value: nativeStatsGrand(t), detail: "\(d["summary"]["models"].int) models\(d["isLifetime"].bool ? " · lifetime" : "")", accent: nativeStatsColor("06b6d4"), format: nativeStatsCount)
                NativeStatsValueTile(label: "Generated output", value: t["output"].double, detail: "\(nativeStatsCount(t["thinking"].double)) reasoning inside output", accent: nativeStatsColor("10b981"), format: nativeStatsCount)
                NativeStatsValueTile(label: detail ? "Cache efficiency" : "Served from cache", value: prompt > 0 ? t["cacheRead"].double * 100 / prompt : nil, unit: "%", detail: "\(nativeStatsCount(t["cacheRead"].double)) of \(nativeStatsCount(prompt)) prompt tokens", accent: nativeStatsColor("a855f7"), format: { String(format: "%.1f", $0) })
                if detail {
                    NativeStatsValueTile(label: "Recorded responses", value: payload["coverage"]["datedTotals"]["messages"].double, detail: "\(d["summary"]["sessions"].int) sessions · \(d["summary"]["projects"].int) projects", format: nativeStatsCount)
                } else { costTile }
            }
            NativeStatsPricing(cost: d["cost"])
            NativeStatsLedger(totals: t)
            if detail { NativeStatsThroughput(data: d["throughput"], colors: payload["colors"], availableWidth: availableWidth, modelDetail: true) }
            if d["days"].array.isEmpty { NativeEmptyState(title: "No dated history in this range", detail: d["isLifetime"].bool ? "Lifetime totals are available, but earlier transcripts are no longer on disk." : "Try another range or source.") }
            else { NativeStatsDaily(data: d, colors: payload["colors"]); if detail { NativeStatsCumulative(days: d["days"].array) } }
            if detail {
                detailTiles
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 32, alignment: .top), count: availableWidth >= 600 ? 2 : 1), alignment: .leading, spacing: 24) {
                    NativeStatsProjectBoard(rows: d["projects"].array, all: detail)
                    NativeStatsHeat(grid: d["heat"].array)
                }
                NativeStatsDrive(summary: payload["datedSummary"])
            } else {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 32, alignment: .top), count: availableWidth >= 600 ? 2 : 1), alignment: .leading, spacing: 24) {
                    NativeStatsHeat(grid: d["heat"].array)
                    NativeStatsDrive(summary: d["summary"])
                }
            }
            if !payload["cache"].isNull { NativeCard {
                NativeChartHeading(title: "Difference from /stats", caption: "Claude's lifetime cache includes repeated content blocks and retained pruned history. Dated charts deduplicate response IDs. Only responses on UTC days after the cache watermark are added to the lifetime baseline.")
                Text("Lifetime \(nativeStatsCount(nativeStatsGrand(payload["cache"]["totals"]))) · raw disk \(nativeStatsCount(payload["scan"]["rawGrand"].double)) · deduplicated disk \(nativeStatsCount(d["onDiskGrand"].double))").font(Theme.num(Theme.textXs, weight: .regular))
                Text("\(payload["scan"]["duplicates"].int) repeated blocks · \(payload["dayMatch"]["matched"].int)/\(payload["dayMatch"]["checked"].int) comparable UTC days agree").font(Theme.num(Theme.textXs, weight: .regular)).foregroundStyle(Theme.muted)
            } }
            // Detail uses an exact model/range-filtered benchmark payload.
            // The unfiltered overview ledger belongs only to All apps.
            if detail {
                if (benchmark["spend"]["calls"].int > 0 || !benchmark["trend"].array.isEmpty) {
                    NativeChartHeading(title: "Benchmarks", caption: "UniApi benchmark records for this exact model and date range, across providers. Separate from coding-app usage.")
                }
                NativeStatsBenchmark(data: benchmark)
            }
            Text("\(Int(t["messages"].double)) responses · \(d["summary"]["sessions"].int) sessions · \(d["summary"]["projects"].int) projects · \(d["summary"]["models"].int) models · \(d["summary"]["activeDays"].int) active days\(span)\(scanFooter)")
                .font(Theme.num(11, weight: .regular)).foregroundStyle(Theme.faint).textSelection(.enabled)
    }
    private var prompt: Double { t["input"].double + t["cacheRead"].double + t["cacheWrite"].double }
    private var costTile: some View {
        NativeStatsValueTile(label: "Estimated API cost", value: d["cost"]["pricedTokens"].double > 0 ? d["cost"]["usd"].double : nil, unit: "USD", detail: costDetail)
    }
    private var costDetail: String {
        let cost = d["cost"]
        if cost.isNull { return "Prices not available yet" }
        if cost["pricedTokens"].double > 0 {
            return cost["unpricedTokens"].double > 0 ? "Partial estimate · unknown costs excluded" : "Based on current API rates"
        }
        return cost["unpricedTokens"].double > 0 ? "Prices missing for this usage" : "No usage recorded yet"
    }
    private var span: String { let first = d["summary"]["first"], last = d["summary"]["last"]; return first.isNull ? "" : " · \(nativeStatsDate(first.double))–\(nativeStatsDate(last.double))" }
    private var scanFooter: String { detail ? "" : " · \(payload["scan"]["files"].int) files, \(nativeStatsCount(payload["scan"]["bytes"].double)) bytes · scan \(payload["scan"]["elapsedMs"].double.formatted(.number.precision(.fractionLength(0)))) ms" }
    private var detailTiles: some View {
        let dated = payload["coverage"]["datedTotals"], messages = dated["messages"].double, days = d["summary"]["activeDays"].double
        return NativeReadoutStrip(minCell: 170) {
            NativeStatsValueTile(label: "Active days", value: days, detail: payload["coverage"]["first"].isNull ? "No dated records" : "First recorded \(nativeStatsDate(payload["coverage"]["first"].double))", format: nativeStatsCount)
            NativeStatsValueTile(label: "Tokens per response", value: messages > 0 ? nativeStatsGrand(dated) / messages : nil, format: nativeStatsCount)
            NativeStatsValueTile(label: "Output per response", value: messages > 0 ? dated["output"].double / messages : nil, format: nativeStatsCount)
            NativeStatsValueTile(label: "Responses / active day", value: days > 0 ? messages / days : nil)
            costTile
        }
    }
}

private struct NativeStatsLedger: View {
    let totals: JSONValue
    private var rows: [(String, String)] { [("Fresh input", "input"), ("Output", "output"), ("Thinking", "thinking"), ("Cache writes", "cacheWrite"), ("Cache reads", "cacheRead")].sorted { totals[$0.1].double > totals[$1.1].double } }
    var body: some View { NativeCard {
        NativeChartHeading(title: "Token kinds", caption: "Five token kinds. Thinking is counted inside output; its share is measured against output.")
        ForEach(Array(rows.enumerated()), id: \.element.1) { index, row in
            let (label, key) = row
            let denominator = key == "thinking" ? totals["output"].double : nativeStatsGrand(totals)
            let color = Theme.series[["input": 0, "output": 1, "thinking": 2, "cacheWrite": 3, "cacheRead": 4][key] ?? 0]
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    RoundedRectangle(cornerRadius: 1).fill(color).frame(width: 2, height: 10).accessibilityHidden(true)
                    Text(label).font(Theme.ui(Theme.textXs, weight: .medium))
                    Spacer(minLength: 8)
                    Text(nativeStatsCount(totals[key].double)).font(Theme.num(Theme.textXs, weight: .medium)).lineLimit(1).nativeStatsNumberTransition(totals[key].double).frame(width: 70, alignment: .trailing)
                    Text((denominator > 0 ? String(format: "%.1f%%", totals[key].double * 100 / denominator) : "—") + (key == "thinking" ? " of output" : "")).font(Theme.num(11, weight: .regular)).foregroundStyle(Theme.muted).frame(width: 96, alignment: .trailing)
                }
                NativeGrowBar(fraction: totals[key].double / max(1, denominator), color: color, delay: Double(index) * 0.06)
            }.help(key == "thinking" ? "Thinking is a subset of generated output; its percentage uses output as the denominator." : totals[key].double.formatted())
        }
    } }
}

/// Every model the selected apps used, one sortable row each.
private struct NativeStatsModelTable: View {
    let models: [JSONValue], lifetime: Bool, colors: JSONValue
    /// Beside an open inspector: the meter and the columns the inspector repeats are dropped.
    var compact = false
    @Binding var selection: String?
    @AppStorage("uniapi.stats.metric") private var sort = "tokens"
    @State private var descending = true
    @Environment(\.nativeInterfaceDensity) private var density
    private func value(_ row: JSONValue, _ key: String) -> Double {
        switch key {
        case "output": return row["totals"]["output"].double
        case "messages": return row["totals"]["messages"].double
        case "sessions": return row["sessions"].double
        case "days": return row["days"].double
        default: return nativeStatsGrand(row["totals"])
        }
    }
    private var columns: [(key: String, title: String, width: CGFloat)] {
        [("tokens", "Tokens", 92), ("output", "Output", 84)] + (lifetime ? [] : [("messages", "Responses", 92)]) + (compact ? [] : [("sessions", "Sessions", 80), ("days", "Days", 60)])
    }
    private var sorted: [JSONValue] {
        models.sorted { a, b in
            if sort == "model" { return descending ? a["model"].string > b["model"].string : a["model"].string < b["model"].string }
            return descending ? value(a, sort) > value(b, sort) : value(a, sort) < value(b, sort)
        }
    }
    var body: some View {
        let rows = sorted, top = max(1, models.map { value($0, sort == "model" ? "tokens" : sort) }.max() ?? 0)
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 0) {
                heading("model", "Model").frame(maxWidth: .infinity, alignment: .leading)
                if !compact { Color.clear.frame(width: 132) }
                ForEach(columns, id: \.key) { column in heading(column.key, column.title).frame(width: column.width, alignment: .trailing) }
                Color.clear.frame(width: 24)
            }.frame(height: 32).padding(.horizontal, density.pageMargin)
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(rows, id: \.self["model"]) { row in
                        let model = row["model"].string
                        NativeStatsModelRow(selected: selection == model) {
                            selection = selection == model ? nil : model
                        } content: {
                            HStack(spacing: 0) {
                                HStack(spacing: 8) {
                                    RoundedRectangle(cornerRadius: 1).fill(nativeStatsColor(colors[model].string)).frame(width: 2, height: 12).accessibilityHidden(true)
                                    Text(model).font(Theme.mono(Theme.textXs, weight: .medium)).foregroundStyle(Theme.ink).lineLimit(1).truncationMode(.middle).help(model)
                                    if row["viaProxy"].bool { MonoChip(text: "proxy", color: Theme.warnFg) }
                                    if row["pruned"].bool { MonoChip(text: "pruned") }
                                }.frame(maxWidth: .infinity, alignment: .leading)
                                if !compact { NativeTickMeter(fraction: value(row, sort == "model" ? "tokens" : sort) / top, color: Theme.ink, height: 8).frame(width: 108).padding(.horizontal, 12) }
                                ForEach(columns, id: \.key) { column in
                                    Text(column.key == "sessions" || column.key == "days" ? "\(Int(value(row, column.key)))" : nativeStatsCount(value(row, column.key)))
                                        .font(Theme.num(Theme.textXs, weight: column.key == sort ? .medium : .regular))
                                        .foregroundStyle(column.key == sort ? Theme.ink : Theme.dim).frame(width: column.width, alignment: .trailing)
                                }
                                NativeIcon("chevron-right", size: 12).foregroundStyle(selection == model ? Theme.ink : Theme.faint).frame(width: 24, alignment: .trailing).accessibilityHidden(true)
                            }
                        }
                    }
                    if rows.isEmpty {
                        Theme.rule.frame(height: 1)
                        Text("No models in this range").font(Theme.ui(12)).foregroundStyle(Theme.faint).frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 16)
                    }
                }.padding(.horizontal, density.pageMargin).padding(.bottom, 32)
            }
            .scrollContentBackground(.hidden)
            .focusable().focusEffectDisabled()
            .onMoveCommand { direction in
                guard let index = rows.firstIndex(where: { $0["model"].string == selection }) else { return }
                let next = direction == .down ? index + 1 : direction == .up ? index - 1 : index
                if next != index, rows.indices.contains(next) { selection = rows[next]["model"].string }
            }
        }
        .onChange(of: lifetime, initial: true) { _, yes in if yes && sort == "messages" { sort = "tokens" } }
    }
    private func heading(_ key: String, _ title: String) -> some View {
        Button { if sort == key { descending.toggle() } else { sort = key; descending = key != "model" } } label: {
            HStack(spacing: 4) { Text(title); if sort == key { NativeIcon(descending ? "arrow-down" : "arrow-up", size: 12) } }
                .font(Theme.ui(11, weight: .medium)).foregroundStyle(sort == key ? Theme.ink : Theme.muted).contentShape(Rectangle())
        }.buttonStyle(.plain).help("Sort by \(title)").accessibilityLabel("Sort by \(title)")
            .accessibilityValue(sort == key ? descending ? "Descending" : "Ascending" : "Not sorted")
    }
}

private struct NativeStatsModelRow<Content: View>: View {
    let selected: Bool
    let action: () -> Void
    @ViewBuilder var content: () -> Content
    @State private var hovering = false
    var body: some View {
        VStack(spacing: 0) {
            Theme.rule.frame(height: 1)
            Button(action: action) { content().frame(minHeight: 40).contentShape(Rectangle()) }.buttonStyle(.plain)
        }
        .background(selected ? Theme.raised : hovering ? Theme.subtle : .clear)
        .overlay(alignment: .leading) { Theme.accent.frame(width: 2).opacity(selected ? 1 : 0).offset(x: -8) }
        .onHover { hovering = $0 }
        .accessibilityAddTraits(selected ? [.isSelected] : [])
    }
}

private struct NativeStatsProjectBoard: View {
    let rows: [JSONValue], all: Bool
    var body: some View { NativeCard {
        NativeChartHeading(title: "Projects", caption: !all && rows.count > 8 ? "Top 8 of \(rows.count) working directories." : "Working directories recorded by the selected apps.")
        ForEach(Array((all ? rows : Array(rows.prefix(8))).enumerated()), id: \.offset) { _, row in VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 8) { Text(row["name"].string).font(Theme.mono(Theme.textXs, weight: .medium)).lineLimit(1).help(row["path"].string); Spacer(minLength: 2); Text("\(row["sessions"].int) sessions").font(Theme.ui(10.5)).foregroundStyle(Theme.muted); Text(nativeStatsCount(nativeStatsGrand(row["totals"]))).font(Theme.mono(12, weight: .medium)) }
            NativeGrowBar(fraction: nativeStatsGrand(row["totals"]) / max(1, rows.map { nativeStatsGrand($0["totals"]) }.max() ?? 0), color: Theme.pairColor(row["path"].string))
        }.padding(.vertical, 7) }
        if !all && rows.count > 8 { Text("\(rows.count - 8) more").font(Theme.ui(Theme.textXs)).foregroundStyle(Theme.faint) }
    }.frame(maxWidth: .infinity) }
}

private struct NativeStatsHeat: View {
    let grid: [JSONValue]
    private var maximum: Double { grid.flatMap(\.array).map(\.double).max() ?? 0 }
    var body: some View { NativeCard {
        NativeChartHeading(title: "Hours", caption: "Responses by local weekday and hour, brightest at your busiest hour.")
        VStack(spacing: 3) {
        ForEach(0..<min(7, grid.count), id: \.self) { day in HStack(spacing: 3) { Text(["Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun"][day]).frame(width: 35); ForEach(0..<24, id: \.self) { hour in let value = grid[day].array.count > hour ? grid[day].array[hour].double : 0; RoundedRectangle(cornerRadius: 2).fill(value > 0 ? Theme.accent.opacity(0.2 + 0.8 * value / max(1, maximum)) : Theme.track).frame(minWidth: 5, maxWidth: .infinity, minHeight: 12, maxHeight: 12).help("\(["Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday", "Sunday"][day]) \(hour):00: \(Int(value)) responses").accessibilityLabel("Day \(day + 1), hour \(hour), \(Int(value)) responses") } } }
        }
        HStack { Text("00"); Spacer(); Text("06"); Spacer(); Text("12"); Spacer(); Text("18"); Spacer(); Text("23") }.font(Theme.mono(10)).foregroundStyle(Theme.muted)
        let hours = (0..<24).map { hour in grid.reduce(0) { $0 + ($1.array.count > hour ? $1.array[hour].double : 0) } }, best = hours.enumerated().max { $0.element < $1.element }
        Text("\(maximum > 0 ? "Busiest hour: \(best?.offset ?? 0):00" : "No dated activity") · intensity 0–\(Int(maximum)) responses").foregroundStyle(Theme.muted)
    }.frame(maxWidth: .infinity) }
}

private struct NativeStatsDrive: View {
    let summary: JSONValue
    var body: some View { NativeCard {
        NativeChartHeading(title: "Sessions")
        ForEach(summary["effort"].object.keys.sorted(), id: \.self) { key in HStack { Text("Effort \(key)"); Spacer(); Text(summary["effort"][key].string).font(Theme.mono(12)) } }
        fact("Subagent turns", value: summary["sidechainMessages"].int, detail: "\(nativeStatsCount(summary["sidechainTokens"].double)) tokens")
        fact("Through the proxy", value: summary["proxyMessages"].int, detail: "Claude responses from a gateway model")
        fact("Web searches", value: summary["totals"]["webSearch"].int, detail: "Reported server-side searches")
        fact("Page fetches", value: summary["totals"]["webFetch"].int, detail: "Reported server-side fetches")
    } }
    private func fact(_ title: String, value: Int, detail: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(title).font(Theme.ui(Theme.textXs, weight: .medium)); Text(detail).font(Theme.ui(11)).foregroundStyle(Theme.muted).lineLimit(1)
            Spacer(); Text("\(value)").font(Theme.num(Theme.textXs, weight: .medium)).foregroundStyle(value == 0 ? Theme.faint : Theme.ink)
        }
    }
}
