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
        guard let visit = NativeUIReadiness.shared.begin(.stats, trigger: trigger, parent: navigationVisit) else { return }
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
        let contentWidth = max(0, min(1500, geometry.size.width) - 2 * density.pageMargin)
        Group {
            if let model = selectedModel {
                NativeStatsDetailFrame(readiness: measuredReadiness) {
                    HStack {
                        Button { selectedModel = nil } label: { HStack(spacing: 6) { NativeIcon("arrow-left", size: 14); Text("Back to Statistics") } }.buttonStyle(T3Button(.ghost))
                        Spacer()
                        Text("Model statistics").font(Theme.ui(11)).foregroundStyle(Theme.muted)
                    }
                    PageHeader(title: model.split(separator: "/").last.map(String.init) ?? model,
                               subtitle: model.contains("/") ? model : "Usage, activity and history for this model.") { headerActions }
                    pageContents(width: contentWidth)
                }
            } else {
                NativePage(title: "Statistics", subtitle: "Token usage from Claude Code, Codex, Antigravity, Z Code, OpenCode and DeepSeek Harness, with model, project and daily breakdowns.", maxWidth: 1500, readiness: measuredReadiness, actions: { headerActions }) {
                    pageContents(width: contentWidth)
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
    private var headerActions: some View {
        HStack(spacing: 8) {
            if state.busy { HStack(spacing: 5) { StatusDot(color: Theme.accent, size: 5); Text("reading").font(Theme.mono(11)).foregroundStyle(Theme.muted) } }
            if selectedModel == nil {
                T3Segmented(options: [(7, "7 days"), (30, "30 days"), (0, "All time")], selection: range) { range = $0 }
            } else {
                Menu {
                    ForEach([7, 30, 90, 365, 0], id: \.self) { days in Button(days == 0 ? "All time" : days == 365 ? "1 year" : "\(days) days") { detailRange = days } }
                } label: { NativeStatsMenuLabel(title: detailRange == 0 ? "All time" : detailRange == 365 ? "1 year" : "\(detailRange) days") }
                .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
            }
            Button { reload(.refresh, trigger: .refresh) } label: {
                HStack(spacing: 6) { NativeIcon("refresh-cw", size: 12); Text(selectedModel == nil ? "Reload" : "Refresh") }
            }.disabled(state.busy).help("Check for new or changed usage without reparsing unchanged history")
            Menu {
                Button("Rebuild All") { reload(.rebuild, trigger: .rebuild) }
                    .help("Reparse every usage file, including files whose size and modification time stayed the same")
            } label: { NativeIcon("ellipsis", size: 14) }
                .menuStyle(.button).buttonStyle(T3Button(.ghost)).menuIndicator(.hidden)
                .help("Statistics actions")
                .accessibilityLabel("Statistics actions").disabled(state.busy)
            if let model = selectedModel {
                Button { Task { await state.export(model: model, source: source, range: detailRange) } } label: { HStack(spacing: 6) { NativeIcon("download", size: 12); Text("CSV") } }
                    .disabled(current["derived"]["days"].array.isEmpty).help("Export daily CSV")
            }
        }.fixedSize(horizontal: true, vertical: false)
    }
    private var sourceRail: some View {
        ScrollView(.horizontal) {
            T3Segmented(options: [("all", "All apps")] + StatisticsSource.allCases.map { ($0.rawValue, nativeStatsSourceName($0.rawValue)) }, selection: source) { source = $0 }
        }.scrollIndicators(.hidden).fixedSize(horizontal: false, vertical: true)
    }
    private var sourceNote: String {
        ["all": "Each app counted separately, then added together", "claude": "Claude Code transcripts and lifetime cache", "codex": "Codex sessions and archived sessions", "antigravity": "Antigravity app, IDE and ACP conversations", "zcode": "Z Code from z.ai sessions and model usage", "opencode": "OpenCode sessions and their sub-agents", "dsh": "DeepSeek Harness records; streaming uses host-observed arrivals"][source] ?? ""
    }
    private func pageContents(width: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 12) { sourceRail; if selectedModel == nil { Text(sourceNote).font(Theme.ui(11)).foregroundStyle(Theme.muted).fixedSize() } }
                VStack(alignment: .leading, spacing: 8) { sourceRail; if selectedModel == nil { Text(sourceNote).font(Theme.ui(11)).foregroundStyle(Theme.muted) } }
            }
            if !state.error.isEmpty { NativeError(message: state.error) }
            if state.busy {
                NativeStatsProgressLabel(progress: state.readProgress, hasContent: current["loaded"].bool)
            }
            if current["loaded"].bool {
                NativeStatsContents(payload: current, benchmark: currentBenchmark, detail: selectedModel != nil, selectModel: { model in detailRange = range; selectedModel = model }, selectSource: { source = $0 }, availableWidth: width)
                    .id(scope)
            } else if !state.busy && state.error.isEmpty {
                ShimmerText(text: "Reading saved usage…", font: Theme.ui(12))
                    .frame(maxWidth: .infinity).padding(.vertical, 40)
            }
        }
    }
}

private struct NativeStatsProgressLabel: View {
    @ObservedObject var progress: NativeStatsReadProgress
    let hasContent: Bool
    var body: some View {
        ShimmerText(text: NativeStatsPresentationPolicy.progressText(progress.value), font: Theme.ui(12))
            .frame(maxWidth: .infinity).padding(.vertical, hasContent ? 6 : 40)
    }
}

struct NativeStatsMenuLabel: View {
    let title: String
    var width: CGFloat? = nil
    var body: some View {
        HStack(spacing: 8) { Text(title).lineLimit(1); if width != nil { Spacer(minLength: 0) }; NativeIcon("chevron-down", size: 10) }
            .font(Theme.ui(12, weight: .medium)).foregroundStyle(Theme.dim)
            .padding(.horizontal, 11).padding(.vertical, 6)
            .frame(width: width)
            .background(Theme.subtle, in: RoundedRectangle(cornerRadius: Theme.radiusMd))
            .overlay(RoundedRectangle(cornerRadius: Theme.radiusMd).strokeBorder(Theme.input, lineWidth: 1))
    }
}

// The detail's Back row precedes its title, inside the same scrolling flow as
// the web ModelStatsPage; readiness still belongs to this page visit.
private struct NativeStatsDetailFrame<Content: View>: View {
    let readiness: NativePageReadiness
    @ViewBuilder var content: () -> Content
    @Environment(\.nativePageVisit) private var visit
    @Environment(\.nativeInterfaceDensity) private var density
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: density.pageGap) { content() }
                .padding(.horizontal, density.pageMargin).padding(.top, density.pageGap).padding(.bottom, 44)
                .frame(maxWidth: 1500, alignment: .leading).frame(maxWidth: .infinity)
                .nativeEntrance(.page)
        }.scrollContentBackground(.hidden).background(Theme.bg).foregroundStyle(Theme.ink)
            .font(Theme.ui(13)).buttonStyle(T3Button(.outline)).tint(Theme.accent).nativeMotionVisibility()
            .background(alignment: .topLeading) {
                if let visit, NativeUIReadiness.shared.enabled { NativeReadinessProbe(visit: visit, readiness: readiness).frame(width: 1, height: 1).allowsHitTesting(false).accessibilityHidden(true) }
            }
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

private struct NativeStatsContents: View {
    let payload: JSONValue, benchmark: JSONValue, detail: Bool
    let selectModel: (String) -> Void
    let selectSource: (String) -> Void
    let availableWidth: CGFloat
    private var d: JSONValue { payload["derived"] }
    private var t: JSONValue { d["summary"]["totals"] }
    var body: some View {
        LazyVStack(alignment: .leading, spacing: 14) {
            if payload["source"].string == "all" {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), alignment: .top), count: availableWidth >= 700 ? 3 : 2), spacing: 10) {
                    ForEach(StatisticsSource.allCases, id: \.rawValue) { s in
                        let value = payload["sources"][s.rawValue]
                        let stream = NativeStatsThroughputPresentation.streamingSource(d["throughput"], source: s.rawValue)
                        let hasUsage = nativeStatsGrand(value) > 0 || value["messages"].double > 0
                        Button { selectSource(s.rawValue) } label: {
                            Card(padding: 14) {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(nativeStatsSourceName(s.rawValue)).font(Theme.ui(12, weight: .medium)).fixedSize(horizontal: false, vertical: true)
                                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                                        Text(value.isNull ? "—" : nativeStatsCount(nativeStatsGrand(value))).font(Theme.mono(18, weight: .semibold)).monospacedDigit().lineLimit(1).nativeStatsNumberTransition(value.isNull ? nil : nativeStatsGrand(value))
                                        Text(value.isNull ? "No recorded usage" : "tokens").font(Theme.ui(10)).foregroundStyle(Theme.muted)
                                    }
                                    if !detail, !value.isNull {
                                        if hasUsage {
                                            Text("\(nativeStatsCount(value["output"].double)) output · \(nativeStatsCount(value["cacheRead"].double)) cached").font(Theme.ui(10.5)).foregroundStyle(Theme.muted)
                                            if let rate = NativeStatsThroughputPresentation.rate(stream) {
                                                Text(String(format: "%.1f streaming tokens/s", rate)).font(Theme.mono(11)).foregroundStyle(Theme.dim)
                                                    .help(NativeStatsRateMetric.streaming.timingDetail(stream))
                                            } else {
                                                Text(NativeStatsThroughputPresentation.missingClockLabel(source: s.rawValue))
                                                    .font(Theme.ui(10.5)).foregroundStyle(Theme.muted)
                                                    .help("Token totals are available. A streaming rate needs token-arrival timestamps; elapsed tool and response time cannot replace them.")
                                            }
                                        } else {
                                            // Match the populated tile's two detail lines.
                                            Text("No recorded usage").font(Theme.ui(10.5)).foregroundStyle(Theme.muted)
                                                .frame(minHeight: 30, alignment: .topLeading)
                                        }
                                    }
                                }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                            }
                        }.buttonStyle(.plain).pointingHand().nativeStatsRowHover(radius: Theme.radius, overlay: true).accessibilityLabel("Open \(nativeStatsSourceName(s.rawValue)) statistics")
                            .accessibilityValue(hasUsage ? "Streaming tokens per second: " + (NativeStatsThroughputPresentation.rate(stream).map { String(format: "%.1f", $0) } ?? "Unavailable") + ". " + NativeStatsRateMetric.streaming.coverage(stream) : "No recorded usage")
                    }
                }
            }
            if d["isLifetime"].bool { Text("Lifetime token totals include Claude's cache. Dated charts, responses, projects and speed use available response records; pruned history cannot be reconstructed.").font(Theme.ui(12)).foregroundStyle(Theme.muted) }
            ForEach(Array(payload["warnings"].array.enumerated()), id: \.offset) { _, warning in NativeError(message: warning.string) }
            ForEach(NativeStatsPresentationPolicy.excludedNotices(payload, detail: detail), id: \.source) { notice in
                Text("\(nativeStatsSourceName(notice.source)): \(notice.count) records have no usable usage metadata.").font(Theme.ui(11)).foregroundStyle(Theme.muted)
            }
            LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: availableWidth >= 600 ? 4 : 2), spacing: 10) {
                NativeStatsValueTile(label: "Tokens processed", value: nativeStatsGrand(t), detail: "Read + written across \(d["summary"]["models"].int) models\(d["isLifetime"].bool ? " · lifetime" : "")", accent: nativeStatsColor("06b6d4"), format: nativeStatsCount)
                NativeStatsValueTile(label: "Generated output", value: t["output"].double, detail: "\(nativeStatsCount(t["thinking"].double)) reasoning (inside output)", accent: nativeStatsColor("10b981"), format: nativeStatsCount)
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
            if !detail { NativeStatsThroughput(data: d["throughput"], colors: payload["colors"], availableWidth: availableWidth, selectModel: selectModel) }
            if detail {
                detailTiles
                costTile
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), alignment: .top), count: availableWidth >= 600 ? 2 : 1), alignment: .leading, spacing: 14) {
                    NativeStatsProjectBoard(rows: d["projects"].array, all: detail)
                    NativeStatsHeat(grid: d["heat"].array)
                }
                NativeStatsDrive(summary: payload["datedSummary"])
            } else {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), alignment: .top), count: availableWidth >= 600 ? 2 : 1), alignment: .leading, spacing: 14) {
                    NativeStatsModelBoard(models: d["models"].array, lifetime: d["isLifetime"].bool, colors: payload["colors"], select: selectModel)
                    NativeStatsProjectBoard(rows: d["projects"].array, all: detail)
                    NativeStatsHeat(grid: d["heat"].array)
                    NativeStatsDrive(summary: d["summary"])
                }
            }
            if !payload["cache"].isNull { NativeCard {
                NativeChartHeading(title: "Why this disagrees with /stats", caption: "Lifetime history and de-duplicated on-disk records measure different things.")
                Text("Lifetime \(nativeStatsCount(nativeStatsGrand(payload["cache"]["totals"]))) · raw disk \(nativeStatsCount(payload["scan"]["rawGrand"].double)) · deduplicated disk \(nativeStatsCount(d["onDiskGrand"].double))")
                Text("\(payload["scan"]["duplicates"].int) repeated blocks; \(payload["dayMatch"]["matched"].int)/\(payload["dayMatch"]["checked"].int) comparable UTC days agree.")
                DisclosureGroup("How these totals differ") { Text("Claude's lifetime cache includes repeated content blocks and retained pruned history. Dated charts deduplicate response IDs. Only responses on UTC days after the cache watermark are added to the lifetime baseline.") }
            } }
            // Detail uses an exact model/range-filtered benchmark payload.
            // The unfiltered overview ledger belongs only to All apps.
            if detail || payload["source"].string == "all" {
                if detail && (benchmark["spend"]["calls"].int > 0 || !benchmark["trend"].array.isEmpty) {
                    Rectangle().fill(Theme.border).frame(height: 1).padding(.top, 6)
                    NativeChartHeading(title: "Benchmarks for this model", caption: "UniApi benchmark records for this exact model and date range, across providers. Separate from coding-app usage.")
                }
                NativeStatsBenchmark(data: benchmark)
            }
            Text("\(Int(t["messages"].double)) responses · \(d["summary"]["sessions"].int) sessions · \(d["summary"]["projects"].int) projects · \(d["summary"]["models"].int) models · \(d["summary"]["activeDays"].int) active days\(span)\(scanFooter)")
                .font(Theme.ui(11)).foregroundStyle(Theme.muted).textSelection(.enabled)
        }.font(Theme.ui(12)).foregroundStyle(Theme.ink)
            .accessibilityElement(children: .contain)
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
        return LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: availableWidth >= 600 ? 4 : 2), spacing: 10) {
            NativeStatsValueTile(label: "Active days", value: days, detail: payload["coverage"]["first"].isNull ? "No dated records" : "First recorded \(nativeStatsDate(payload["coverage"]["first"].double))", format: nativeStatsCount)
            NativeStatsValueTile(label: "Tokens per response", value: messages > 0 ? nativeStatsGrand(dated) / messages : nil, format: nativeStatsCount)
            NativeStatsValueTile(label: "Output per response", value: messages > 0 ? dated["output"].double / messages : nil, format: nativeStatsCount)
            NativeStatsValueTile(label: "Responses / active day", value: days > 0 ? messages / days : nil)
        }
    }
}

private struct NativeStatsLedger: View {
    let totals: JSONValue
    private var rows: [(String, String)] { [("Fresh input", "input"), ("Output", "output"), ("Thinking (inside output)", "thinking"), ("Cache writes", "cacheWrite"), ("Cache reads", "cacheRead")].sorted { totals[$0.1].double > totals[$1.1].double } }
    var body: some View { NativeCard {
        NativeChartHeading(title: "Where the tokens go", caption: "Five token kinds. Thinking is counted inside output; its share is measured against output.")
        ForEach(Array(rows.enumerated()), id: \.element.1) { index, row in
            let (label, key) = row
            let denominator = key == "thinking" ? totals["output"].double : nativeStatsGrand(totals)
            let color = nativeStatsColor(["input": "3b82f6", "output": "10b981", "thinking": "f59e0b", "cacheWrite": "a855f7", "cacheRead": "06b6d4"][key] ?? "06b6d4")
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    StatusDot(color: color, size: 6)
                    Text(label).font(Theme.ui(12.5, weight: .medium))
                    Spacer(minLength: 8)
                    Text(nativeStatsCount(totals[key].double)).font(Theme.mono(12, weight: .medium)).monospacedDigit().lineLimit(1).nativeStatsNumberTransition(totals[key].double).frame(width: 70, alignment: .trailing)
                    Text((denominator > 0 ? String(format: "%.1f%%", totals[key].double * 100 / denominator) : "—") + (key == "thinking" ? " of output" : "")).font(Theme.mono(10)).foregroundStyle(Theme.muted).frame(width: 96, alignment: .trailing)
                }
                NativeGrowBar(fraction: totals[key].double / max(1, denominator), color: color, delay: Double(index) * 0.06)
            }.help(key == "thinking" ? "Thinking is a subset of generated output; its percentage uses output as the denominator." : totals[key].double.formatted())
        }
    } }
}

private struct NativeStatsModelBoard: View {
    let models: [JSONValue], lifetime: Bool, colors: JSONValue, select: (String) -> Void
    @AppStorage("uniapi.stats.metric") private var metric = "tokens"
    private func value(_ row: JSONValue) -> Double { metric == "tokens" ? nativeStatsGrand(row["totals"]) : row["totals"][metric == "output" ? "output" : "messages"].double }
    var body: some View { NativeCard {
        NativeChartHeading(title: "Models", caption: lifetime ? "\(models.count) served lifetime · pruned transcripts retain their totals." : "\(models.count) served this window.")
        T3Segmented(options: [("tokens", "Tokens"), ("output", "Output")] + (lifetime ? [] : [("messages", "Responses")]), selection: metric) { metric = $0 }
        ForEach(Array(models.sorted { value($0) > value($1) }.enumerated()), id: \.offset) { index, row in
            Button { select(row["model"].string) } label: {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(String(format: "%02d", index + 1)).font(Theme.mono(10)).foregroundStyle(Theme.muted).frame(width: 18)
                        Text(row["model"].string).font(Theme.mono(12, weight: .medium)).fixedSize(horizontal: false, vertical: true).help(row["model"].string)
                        if row["viaProxy"].bool { Text("proxy").font(Theme.mono(9)).foregroundStyle(Theme.warnFg) }
                        if row["pruned"].bool { Text("pruned").font(Theme.mono(9)).foregroundStyle(Theme.muted) }
                        Spacer(minLength: 2)
                        Text("\(row["days"].int)d · \(row["sessions"].int) sessions").font(Theme.ui(10.5)).foregroundStyle(Theme.muted)
                        Text(nativeStatsCount(value(row))).font(Theme.mono(12, weight: .medium))
                        NativeIcon("arrow-up-right", size: 11).foregroundStyle(Theme.muted)
                    }
                    NativeGrowBar(fraction: value(row) / max(1, models.map(value).max() ?? 0), color: nativeStatsColor(colors[row["model"].string].string))
                }
                .padding(.horizontal, 8).padding(.vertical, 7).contentShape(Rectangle())
            }.buttonStyle(.plain).pointingHand().help("Open full history for \(row["model"].string)")
        }
    }.onChange(of: lifetime) { _, yes in if yes && metric == "messages" { metric = "tokens" } }.onAppear { if lifetime && metric == "messages" { metric = "tokens" } } }
}

private struct NativeStatsProjectBoard: View {
    let rows: [JSONValue], all: Bool
    var body: some View { NativeCard {
        NativeChartHeading(title: "Projects", caption: !all && rows.count > 8 ? "Top 8 of \(rows.count) working directories." : "Working directories recorded by the selected apps.")
        ForEach(Array((all ? rows : Array(rows.prefix(8))).enumerated()), id: \.offset) { index, row in VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 8) { Text(String(format: "%02d", index + 1)).font(Theme.mono(10)).foregroundStyle(Theme.muted).frame(width: 18); Text(row["name"].string).font(Theme.mono(12, weight: .medium)).lineLimit(1).help(row["path"].string); Spacer(minLength: 2); Text("\(row["sessions"].int) sessions").font(Theme.ui(10.5)).foregroundStyle(Theme.muted); Text(nativeStatsCount(nativeStatsGrand(row["totals"]))).font(Theme.mono(12, weight: .medium)) }
            NativeGrowBar(fraction: nativeStatsGrand(row["totals"]) / max(1, rows.map { nativeStatsGrand($0["totals"]) }.max() ?? 0), color: Theme.pairColor(row["path"].string))
        }.padding(.horizontal, 8).padding(.vertical, 7) }
        if !all && rows.count > 8 { Text("\(rows.count - 8) more projects").foregroundStyle(Theme.muted) }
    }.frame(maxWidth: .infinity) }
}

private struct NativeStatsHeat: View {
    let grid: [JSONValue]
    private var maximum: Double { grid.flatMap(\.array).map(\.double).max() ?? 0 }
    var body: some View { NativeCard {
        NativeChartHeading(title: "When you work", caption: "Responses by local weekday and hour, brightest at your busiest hour.")
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
        NativeChartHeading(title: "How you drive it", caption: "Thinking effort, subagents and server-side tools - the settings behind the numbers above.")
        ForEach(summary["effort"].object.keys.sorted(), id: \.self) { key in HStack { Text("Effort \(key)"); Spacer(); Text(summary["effort"][key].string).font(Theme.mono(12)) } }
        Rectangle().fill(Theme.border).frame(height: 1)
        fact("Subagent turns", value: summary["sidechainMessages"].int, detail: "\(nativeStatsCount(summary["sidechainTokens"].double)) tokens")
        fact("Through the proxy", value: summary["proxyMessages"].int, detail: "Claude responses from a gateway model")
        fact("Web searches", value: summary["totals"]["webSearch"].int, detail: "Reported server-side searches")
        fact("Page fetches", value: summary["totals"]["webFetch"].int, detail: "Reported server-side fetches")
    } }
    private func fact(_ title: String, value: Int, detail: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) { Text(title).font(Theme.ui(12.5, weight: .medium)); Text(detail).font(Theme.ui(10.5)).foregroundStyle(Theme.muted) }
            Spacer(); Text("\(value)").font(Theme.mono(14, weight: .medium)).foregroundStyle(value == 0 ? Theme.muted : Theme.ink)
        }
    }
}
