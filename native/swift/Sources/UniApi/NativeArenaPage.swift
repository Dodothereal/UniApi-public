import SwiftUI
import AppKit
import UniApiCore
import UniApiPresentation

typealias NativeArenaModel = UniApiPresentation.NativeArenaModel

struct NativeArenaPage: View {
    let runtime: NativeRuntime
    @StateObject private var model: NativeArenaModel
    @State private var tab = "Judge"
    @State private var selected = ""
    @State private var preset = ""
    @State private var rankingMode = "all"
    @State private var editing: JSONValue?
    @State private var composing = false
    @State private var historyOpen = false
    @Environment(\.nativeInterfaceDensity) private var density
    @Environment(\.nativePageActive) private var pageActive
    private static let pageWidth: CGFloat = 1320
    init(runtime: NativeRuntime) { self.runtime = runtime; _model = StateObject(wrappedValue: NativeArenaModel(runtime: runtime)) }
    private var visible: [JSONValue] { model.matches.filter { tab == "History" || $0["id"].string == selected || $0["voted_at"].isNull && ["done", "running", "queued"].contains($0["status"].string) }.sorted { tab == "History" ? $0["created_at"].double > $1["created_at"].double : $0["created_at"].double < $1["created_at"].double } }
    private var pageReadiness: NativePageReadiness {
        if model.failed { return .failed }
        guard model.loaded else { return .pending }
        guard tab == "Ranking" else { return .ready }
        switch model.rankingPhase(for: rankingMode) {
        case .ready: return .ready
        case .failed: return .failed
        case .loading, .pending: return .pending
        }
    }
    var body: some View {
        GeometryReader { viewport in
        let width = min(Self.pageWidth, viewport.size.width) - 2 * density.pageMargin
        // The contestants take what is left of the window, so reading both
        // and giving the verdict needs no page scrolling.
        let stage = max(300, min(760, viewport.size.height - 650))
        let shown = shownMatch
        NativePage(title: "Arena", eyebrow: "Blind head-to-head", maxWidth: Self.pageWidth, readiness: pageReadiness, actions: {
            IconPress(icon: "rotate-cw", help: "Reload") { Task { await model.reload(ranking: tab == "Ranking" ? rankingMode : nil) } }
            Button("New match", nativeIcon: "plus") { compose("") }.buttonStyle(Press(.primary)).disabled(!model.loaded)
        }) {
            if !model.pageError(includeRanking: tab == "Ranking").isEmpty { BenchFailure(message: model.pageError(includeRanking: tab == "Ranking")) }
            if model.loaded { reading(wide: width >= 700) }
            HStack(spacing: 16) {
                Stops(options: ["Judge", "History", "Ranking", "Presets"].map { (value: $0, label: $0) }, selection: tab, spacing: 22) { tab = $0; historyOpen = false }
                    .accessibilityLabel("Arena view")
                Spacer(minLength: 0)
                if let shown { queue(shown) }
            }
            if !model.loaded && tab != "Ranking" {
                if !model.failed { Text("Reading Arena presets and matches").font(Theme.ui(12.5)).foregroundStyle(Theme.muted) }
            } else { switch tab {
            case "Presets": presets
            case "Ranking": rankings(wide: width >= 860)
            case "History": history(shown, stage: stage, wide: width >= 760)
            default: judge(shown, stage: stage)
            } }
        }
        .nativePageTask { await model.begin(runtime: runtime) }
        .nativePageTask(id: "\(tab):\(rankingMode):\(model.readActive):\(model.readGeneration)") { if tab == "Ranking", model.readActive { await model.ranking(rankingMode) } }
        .nativePageActivity(suspended: { model.stop() })
        .sheet(item: Binding(get: { editing.map { NativeArenaPresetItem(value: $0) } }, set: { editing = $0?.value })) { item in NativeArenaPresetEditor(value: item.value) { input in if let saved = await model.call("preset.save", input) { editing = nil; await model.load(); return saved }; return nil } }
        .sheet(isPresented: $composing) {
            NativeArenaNewMatch(model: model, initialPreset: preset) { id in selected = id; tab = "Judge"; historyOpen = false; composing = false }
        }
        }
    }
    private func compose(_ id: String) { preset = id; composing = true }

    // ---- reading ---------------------------------------------------------
    private func reading(wide: Bool) -> some View {
        let waiting = model.matches.filter { $0["status"].string == "done" && $0["voted_at"].isNull }.count
        let running = model.matches.filter { ["queued", "running"].contains($0["status"].string) }.count
        let judged = model.matches.filter { ["ranked", "all_bad"].contains($0["verdict"].string) }.count
        let pool = model.state["contestants"].array.count
        let eligible = pool - model.state["excluded"].array.count
        return ReadoutStrip(minimum: 132) {
            Readout(label: wide ? "Waiting for a verdict" : "To judge", value: String(waiting), unit: waiting == 1 ? "match" : "matches", size: .hero,
                    tint: waiting > 0 ? Theme.signal : nil)
            Readout(label: "Running", value: String(running), unit: running == 1 ? "match" : "matches",
                    detail: running == 0 ? "Nothing in the background" : "Results arrive here when they finish",
                    tint: running > 0 ? Theme.signal : nil, color: running == 0 ? Theme.faint : Theme.ink)
            Readout(label: "Judged", value: String(judged), unit: judged == 1 ? "verdict" : "verdicts",
                    detail: "\(model.matches.count) \(model.matches.count == 1 ? "match" : "matches") played")
            Readout(label: "Pool", value: String(max(0, eligible)), unit: eligible == 1 ? "model" : "models",
                    detail: pool == 0 ? "Add a provider in Switcher first" : eligible == pool ? "Every model can be drawn" : "\(pool - eligible) kept out of random draws",
                    color: eligible <= 0 ? Theme.faint : Theme.ink)
        }
    }

    // ---- judge and history -----------------------------------------------
    /// The match on screen: the queue's current one, or the one opened from History.
    private var shownMatch: JSONValue? {
        guard model.loaded, !visible.isEmpty else { return nil }
        switch tab {
        case "Judge": return model.matches.first(where: { $0["id"].string == selected }) ?? visible.first
        case "History": return historyOpen ? model.matches.first(where: { $0["id"].string == selected }) : nil
        default: return nil
        }
    }
    @ViewBuilder private func judge(_ shown: JSONValue?, stage: CGFloat) -> some View {
        if let shown { open(shown, stage: stage) }
        else {
            Band("Queue", spacing: 0) {
                Blank(icon: "swords", title: "Nothing to judge", detail: "Start a match. Contestants run in the background and wait here for your verdict.",
                      actionTitle: "New match", primary: false) { compose("") }
            }
        }
    }
    @ViewBuilder private func history(_ shown: JSONValue?, stage: CGFloat, wide: Bool) -> some View {
        if let shown { open(shown, stage: stage) }
        else if visible.isEmpty {
            Band("History", spacing: 0) {
                historyHead(wide: wide)
                Blank(icon: "swords", title: "No matches yet", detail: "Start a match. Contestants run in the background and wait here for your verdict.",
                      actionTitle: "New match", primary: false) { compose("") }
            }
        } else {
            Band(title: "History", spacing: 0) {
                Text("\(visible.count) \(visible.count == 1 ? "match" : "matches"), newest first").font(Theme.mono(10.5)).foregroundStyle(Theme.muted).fixedSize()
            } content: {
                historyHead(wide: wide)
                LazyVStack(spacing: 0) {
                    ForEach(visible, id: \.self["id"]) { match in
                        ArenaHistoryRow(match: match, wide: wide) { selected = match["id"].string; historyOpen = true }
                    }
                }
            }
        }
    }
    private func historyHead(wide: Bool) -> some View {
        LedgerHead {
            MicroLabel("Started").frame(width: 116, alignment: .leading)
            MicroLabel("Task")
            Spacer(minLength: 0)
            MicroLabel("Field").frame(width: 84, alignment: .leading)
            if wide { MicroLabel("Winner").frame(width: 230, alignment: .leading) }
            MicroLabel("Verdict").frame(width: 96, alignment: .trailing)
        }
    }
    /// Delete removes the current row before its success callback, so the
    /// next match is settled while the current one is still listed.
    private func nextID(after match: JSONValue) -> String {
        ArenaPresentationPolicy.nextMatchID(in: visible, after: match["id"].string, history: tab == "History") ?? ""
    }
    private func open(_ match: JSONValue, stage: CGFloat) -> some View {
        let nextID = nextID(after: match)
        return NativeArenaMatch(runtime: runtime, model: model, match: match, stage: stage) { selected = nextID }
            .id(match["id"].string).frame(minWidth: 0, maxWidth: .infinity)
    }
    /// Where this match sits among the others, and the way to another one.
    private func queue(_ match: JSONValue) -> some View {
        let index = visible.firstIndex(where: { $0["id"] == match["id"] }) ?? 0
        let nextID = nextID(after: match)
        return HStack(spacing: 12) {
            if tab == "History" {
                Button("All matches", nativeIcon: "arrow-left") { historyOpen = false }.buttonStyle(Press(.quiet))
            } else if visible.count > 1, visible.count <= 40 {
                ArenaQueueTicks(matches: visible, current: match["id"].string) { selected = $0 }
            }
            matchPicker(match, index: index)
            HStack(spacing: 2) {
                IconPress(icon: "chevron-left", help: "Previous match") {
                    selected = visible[(index - 1 + visible.count) % visible.count]["id"].string
                }
                IconPress(icon: "chevron-right", help: "Next match") { selected = nextID }
            }.disabled(visible.count < 2)
        }
    }
    private func matchPicker(_ current: JSONValue, index: Int) -> some View {
        Menu {
            ForEach(Array(visible.enumerated()), id: \.element["id"]) { position, match in
                Button {
                    selected = match["id"].string
                } label: {
                    Text("\(position + 1). \(match["mode"].string) · \(matchStatus(match)) · \(String(match["prompt"].string.prefix(100)))")
                }.help(match["prompt"].string)
                    .accessibilityLabel("Match \(position + 1). \(match["prompt"].string)")
                    .accessibilityValue("\(match["mode"].string). \(matchStatus(match))")
                    .accessibilityAddTraits(match["id"] == current["id"] ? [.isSelected] : [])
            }
        } label: {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                MicroLabel("Match")
                NativeNumberText(text: String(index + 1), font: Theme.readout(17), color: Theme.ink)
                MicroLabel("of \(visible.count)")
                NativeIcon("chevrons-up-down", size: 11, strokeWidth: 1.75).foregroundStyle(Theme.muted)
            }.accessibilityElement(children: .ignore).frame(height: 28).contentShape(Rectangle())
        }.menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize().pointingHand()
            .accessibilityLabel("Selected match")
            .accessibilityValue("\(index + 1) of \(visible.count). \(current["mode"].string), \(current["slots"].array.count) contestants, \(matchStatus(current)). \(current["prompt"].string)")
            .help("Jump to another match")
    }
    private func matchStatus(_ match: JSONValue) -> String {
        (match["verdict"].isNull ? match["status"].string : match["verdict"].string).replacingOccurrences(of: "_", with: " ")
    }

    // ---- presets ---------------------------------------------------------
    private var presets: some View {
        let groups = ArenaPresentationPolicy.presetGroups(model.state["presets"].array)
        return Band(title: "Presets", spacing: 0) {
            Button("New preset", nativeIcon: "plus") { editing = [:] }
        } content: {
            if model.state["presets"].array.isEmpty {
                Blank(icon: "file-text", title: "No presets", detail: "Write one and it is one click away on every new match.",
                      actionTitle: "New preset", primary: false) { editing = [:] }
            }
            ForEach(Array(groups.enumerated()), id: \.element.id) { index, group in
                LedgerHead {
                    MicroLabel(group.title).accessibilityAddTraits(.isHeader)
                    Spacer(minLength: 0)
                    MicroLabel(String(group.presets.count), color: Theme.faint)
                }.padding(.top, index == 0 ? 0 : 20)
                ForEach(group.presets, id: \.self["id"]) { p in
                    ArenaPresetRow(preset: p, use: { compose(p["id"].string) }, edit: { editing = p }, delete: {
                        if NativeArenaConfirm("Delete preset “\(p["title"].string)”?", detail: "Deleted built-in presets will stay deleted.") { Task { _ = await model.call("preset.delete", ["id": p["id"]]); await model.load() } }
                    })
                }
            }
        }
    }

    // ---- ranking ---------------------------------------------------------
    @ViewBuilder private func rankings(wide: Bool) -> some View {
        let hasContent = model.rankingHasContent(for: rankingMode)
        let phase = model.rankingPhase(for: rankingMode)
        Band(title: "Standings", spacing: 0) {
            if phase == .loading && hasContent { Text("Refreshing").font(Theme.mono(10.5)).foregroundStyle(Theme.muted).fixedSize() }
            Stops(options: [("all", "All"), ("random", "Random"), ("chosen", "Chosen")], selection: rankingMode) { rankingMode = $0 }.accessibilityLabel("Ranking scope")
        } content: {
            if hasContent {
                standingsHead(wide: wide)
                if model.standings.isEmpty {
                    Blank(icon: "trophy", title: "No verdicts yet", detail: "Judge a match or sync the shared ledger.")
                }
                ForEach(Array(model.standings.enumerated()), id: \.offset) { index, row in
                    ArenaStandingRow(rank: index + 1, row: row, fraction: fraction(row), wide: wide)
                }
            } else if phase == .failed {
                Blank(icon: "trophy", title: "Ranking unavailable", detail: "Reload to retry this scope.", actionTitle: "Reload", actionIcon: "rotate-cw", primary: false) {
                    Task { await model.reload(ranking: rankingMode) }
                }
            } else { Text("Reading ranking and shared ledger").font(Theme.ui(12.5)).foregroundStyle(Theme.muted).padding(.vertical, 12) }
        }
        if hasContent {
            Band(title: "Shared ledger", spacing: 16) {
                if model.ledger["git"].bool {
                    HStack(spacing: 8) {
                        Button("Sync", nativeIcon: "refresh-cw") { Task { await model.share("ledger.sync", mode: rankingMode) } }
                        Button("Publish", nativeIcon: "upload") { if NativeArenaConfirm("Publish Arena verdict files?", detail: "This pushes new immutable results to the arena-results branch of the configured remote.") { Task { await model.share("ledger.publish", mode: rankingMode) } } }
                    }.disabled(model.busy)
                }
            } content: {
                ReadoutStrip(minimum: 130) {
                    Readout(label: "Recent records", value: String(model.recent.count), size: .medium)
                    Readout(label: "Verdict files", value: String(model.ledger["files"].int), size: .medium)
                    Readout(label: "Unpublished", value: String(model.ledger["unpublished"].int), size: .medium,
                            color: model.ledger["unpublished"].int == 0 ? Theme.faint : Theme.ink)
                    Readout(label: "New upstream", value: String(model.ledger["behind"].int), size: .medium,
                            color: model.ledger["behind"].int == 0 ? Theme.faint : Theme.ink)
                }
                Text(model.ledger["remote"].string.isEmpty ? "Results stay on this machine without a Git remote." : model.ledger["remote"].string)
                    .font(Theme.mono(11)).foregroundStyle(Theme.muted).textSelection(.enabled)
                if !model.output.isEmpty {
                    Well(padding: 12) { Text(model.output).font(Theme.mono(11)).foregroundStyle(Theme.dim).textSelection(.enabled) }
                }
            }
            Band("Recent verdicts", spacing: 0) {
                if model.recent.isEmpty { Text("None recorded yet").font(Theme.ui(12.5)).foregroundStyle(Theme.muted).padding(.vertical, 12) }
                else if pageActive { TimelineView(.periodic(from: .now, by: 30)) { clock in recentVerdicts(at: clock.date) } }
                else { recentVerdicts(at: Date()) }
            }
        }
    }
    private func standingsHead(wide: Bool) -> some View {
        LedgerHead {
            MicroLabel("#").frame(width: 28, alignment: .leading)
            MicroLabel("Contestant")
            Spacer(minLength: 0)
            if wide {
                TickScale(divisions: 20, major: 5, minorHeight: 3, majorHeight: 6).fill(Theme.faint)
                    .frame(width: 150, height: 6).accessibilityHidden(true)
            }
            MicroLabel("Elo").frame(width: 52, alignment: .trailing)
                .help("Pairwise Elo, K=32 shared across multi-way matches. All-bad is a draw; failures affect reliability, not rating.")
            if wide {
                MicroLabel("W · L · D").frame(width: 88, alignment: .trailing)
                MicroLabel("Played").frame(width: 60, alignment: .trailing)
                MicroLabel("Firsts").frame(width: 48, alignment: .trailing)
                MicroLabel("Failed").frame(width: 48, alignment: .trailing)
                MicroLabel("Avg time").frame(width: 68, alignment: .trailing)
                MicroLabel("Steps").frame(width: 44, alignment: .trailing)
            }
        }
    }
    private func recentVerdicts(at now: Date) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(model.recent.enumerated()), id: \.offset) { _, record in
                LedgerRow(minHeight: 64) {
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(alignment: .firstTextBaseline, spacing: 12) {
                            Text(record["prompt"].string).font(Theme.ui(13)).foregroundStyle(Theme.ink).lineLimit(1)
                                .frame(maxWidth: .infinity, alignment: .leading)
                            Text(ArenaPresentationPolicy.recentVerdictMetadata(record, now: now)).font(Theme.mono(10.5)).foregroundStyle(Theme.muted)
                                .lineLimit(1).layoutPriority(1)
                        }
                        Text(record["contestants"].array.sorted { ($0["rank"].isNull ? 99 : $0["rank"].int) < ($1["rank"].isNull ? 99 : $1["rank"].int) }.map { "\($0["route"].string) · \($0["model"].string)\($0["status"].string == "failed" ? " (failed)" : "")" }.joined(separator: " > "))
                            .font(Theme.mono(11)).foregroundStyle(Theme.dim).lineLimit(2).textSelection(.enabled)
                    }.padding(.vertical, 10)
                }
            }
        }
    }
    private func fraction(_ row: JSONValue) -> Double { let floor = min(1000, model.standings.map { $0["elo"].double }.min() ?? 1000), peak = model.standings.map { $0["elo"].double }.max() ?? 1000; return (row["elo"].double - floor + 50) / max(1, peak - floor + 50) }
}

/// The queue drawn as a ruler: one tick per match, tall when it is ready for
/// a verdict, and a signal tick that slides to the one on screen.
private struct ArenaQueueTicks: View {
    let matches: [JSONValue]
    let current: String
    let select: (String) -> Void
    @Environment(\.nativeReducedMotion) private var reduceMotion
    private let step: CGFloat = 10
    var body: some View {
        let index = matches.firstIndex { $0["id"].string == current } ?? 0
        HStack(spacing: 0) {
            ForEach(Array(matches.enumerated()), id: \.element["id"]) { position, match in
                let ready = match["status"].string == "done"
                Button { select(match["id"].string) } label: {
                    (ready ? Theme.dim : Theme.faint)
                        .frame(width: 1, height: ready ? 10 : 5).opacity(position == index ? 0 : 1)
                        .frame(width: step, height: 18, alignment: .top).contentShape(Rectangle())
                }.buttonStyle(.plain).pointingHand()
                    .help("\(position + 1). " + String(match["prompt"].string.prefix(100)))
            }
        }
        .overlay(alignment: .top) { Rule(strong: true) }
        .overlay(alignment: .topLeading) {
            Theme.signal.frame(width: 2, height: 14).offset(x: CGFloat(index) * step + (step - 2) / 2)
                .animation(reduceMotion ? nil : NativeMotion.marker, value: index).allowsHitTesting(false)
        }
        .accessibilityHidden(true)
    }
}

private struct ArenaHistoryRow: View {
    let match: JSONValue
    let wide: Bool
    let open: () -> Void
    private var status: String { (match["verdict"].isNull ? match["status"].string : match["verdict"].string).replacingOccurrences(of: "_", with: " ") }
    private var started: String {
        let date = Date(timeIntervalSince1970: match["created_at"].double / 1000)
        return date.formatted(.dateTime.day().month(.abbreviated)) + ", " + date.formatted(.dateTime.hour(.twoDigits(amPM: .omitted)).minute(.twoDigits))
    }
    private var winner: String {
        guard match["verdict"].string == "ranked", let first = match["ranking"].array.first?.int,
              let slot = match["slots"].array.first(where: { $0["idx"].int == first }) else { return "" }
        return slot["model"].string
    }
    @ViewBuilder private var tag: some View {
        switch status {
        case "running": Tag("running", tone: Theme.signal, dot: true)
        case "done": Tag("to judge", tone: Theme.ink)
        case "all bad": Tag("all bad", tone: Theme.warnFg)
        case "failed": Tag("failed", tone: Theme.failFg)
        default: Tag(status)
        }
    }
    var body: some View {
        LedgerRow(minHeight: 40, action: open) {
            HStack(spacing: 12) {
                Text(started).font(Theme.mono(11)).foregroundStyle(Theme.muted).lineLimit(1).frame(width: 116, alignment: .leading)
                Text(match["prompt"].string.replacingOccurrences(of: "\n", with: " ")).font(Theme.ui(13)).foregroundStyle(Theme.ink).lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Text("\(match["mode"].string) · \(match["slots"].array.count)").font(Theme.mono(11)).foregroundStyle(Theme.muted).lineLimit(1)
                    .frame(width: 84, alignment: .leading)
                if wide {
                    Text(winner).font(Theme.mono(11)).foregroundStyle(Theme.dim).lineLimit(1).truncationMode(.middle)
                        .frame(width: 230, alignment: .leading)
                }
                tag.frame(width: 96, alignment: .trailing)
            }
        }
        .accessibilityLabel(match["prompt"].string)
        .accessibilityValue("\(match["mode"].string), \(match["slots"].array.count) contestants, \(status)" + (winner.isEmpty ? "" : ", won by " + winner))
    }
}

/// One contestant in the standings. Wide pages read across one line; narrow
/// pages keep rank, name, bar and rating and fold the record beneath.
private struct ArenaStandingRow: View {
    let rank: Int
    let row: JSONValue
    let fraction: Double
    let wide: Bool
    private var detail: ArenaStandingDetail { ArenaStandingDetail(row) }
    private var color: Color { Theme.pairColor(row["key"].string) }
    private var record: String { "\(row["wins"].int) · \(row["losses"].int) · \(row["draws"].int)" }
    private var steps: String { row["avg_turns"].isNull ? "—" : String(Int(row["avg_turns"].double.rounded())) }
    private var name: some View {
        HStack(spacing: 10) {
            color.frame(width: 2, height: 22)
            VStack(alignment: .leading, spacing: 2) {
                Text(row["model"].string).font(Theme.mono(12, weight: .medium)).foregroundStyle(Theme.ink).lineLimit(1).truncationMode(.middle)
                Text(row["route"].string).font(Theme.ui(11.5)).foregroundStyle(Theme.muted).lineLimit(1)
            }
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
    private func cell(_ text: String, _ width: CGFloat, dim: Bool = false) -> some View {
        Text(text).font(Theme.mono(11)).foregroundStyle(dim ? Theme.faint : Theme.dim).lineLimit(1).frame(width: width, alignment: .trailing)
    }
    var body: some View {
        LedgerRow(minHeight: wide ? 48 : 72) {
            if wide {
                HStack(spacing: 12) {
                    Text(String(rank)).font(Theme.readout(17)).foregroundStyle(rank == 1 ? Theme.ink : Theme.muted).frame(width: 28, alignment: .leading)
                    name
                    Scale(fraction: fraction, color: color).frame(width: 150)
                    NativeNumberText(text: String(row["elo"].int), font: Theme.readout(17), color: Theme.ink).frame(width: 52, alignment: .trailing)
                    cell(record, 88)
                    cell(String(row["matches"].int), 60)
                    cell(String(detail.firsts), 48, dim: detail.firsts == 0)
                    Text(String(detail.failures)).font(Theme.mono(11)).foregroundStyle(detail.failures == 0 ? Theme.faint : Theme.warnFg)
                        .frame(width: 48, alignment: .trailing)
                    cell(NativeArenaDuration(row["avg_duration_ms"].double), 68)
                    cell(steps, 44)
                }
            } else {
                VStack(alignment: .leading, spacing: 7) {
                    HStack(spacing: 12) {
                        Text(String(rank)).font(Theme.readout(17)).foregroundStyle(rank == 1 ? Theme.ink : Theme.muted).frame(width: 28, alignment: .leading)
                        name
                        NativeNumberText(text: String(row["elo"].int), font: Theme.readout(17), color: Theme.ink).frame(width: 52, alignment: .trailing)
                    }
                    Scale(fraction: fraction, color: color).padding(.leading, 40)
                    Text("\(row["wins"].int)W \(row["losses"].int)L \(row["draws"].int)D · \(row["failures"].int) failed · \(row["matches"].int) matches · \(detail.firstPlaceLabel) · \(NativeArenaDuration(row["avg_duration_ms"].double)) · \(steps) steps")
                        .font(Theme.mono(10.5)).foregroundStyle(Theme.muted).lineLimit(1).padding(.leading, 40)
                }.padding(.vertical, 10)
            }
        }
        .help(detail.accessibilitySummary)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(rank). \(row["route"].string) · \(row["model"].string)")
        .accessibilityValue("Elo \(row["elo"].int). \(row["wins"].int) wins, \(row["losses"].int) losses, \(row["draws"].int) draws. " + detail.accessibilitySummary)
    }
}

/// A saved task. The row starts a match with it; edit and delete sit outside
/// the row's button.
private struct ArenaPresetRow: View {
    let preset: JSONValue
    let use: () -> Void
    let edit: () -> Void
    let delete: () -> Void
    @State private var hovering = false
    @Environment(\.nativeReducedMotion) private var reduceMotion
    var body: some View {
        HStack(spacing: 12) {
            Button(action: use) {
                HStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 8) {
                            Text(preset["title"].string).font(Theme.ui(13, weight: .medium)).foregroundStyle(Theme.ink).lineLimit(1)
                            if preset["builtin"].bool { Tag("built-in").fixedSize() }
                        }
                        Text(preset["prompt"].string.replacingOccurrences(of: "\n", with: " ")).font(Theme.ui(12.5)).foregroundStyle(Theme.muted).lineLimit(1)
                    }.frame(maxWidth: .infinity, alignment: .leading)
                    HStack(spacing: 5) {
                        Text("New match"); NativeIcon("arrow-right", size: 12, strokeWidth: 1.75)
                    }.font(Theme.ui(11.5, weight: .medium)).foregroundStyle(Theme.ink).opacity(hovering ? 1 : 0).fixedSize()
                }
                .frame(maxWidth: .infinity, minHeight: 52, alignment: .leading).contentShape(Rectangle())
            }.buttonStyle(.plain).pointingHand()
                .accessibilityLabel("New match with this prompt").accessibilityValue(preset["title"].string)
                .help("New match with this prompt")
            HStack(spacing: 2) {
                IconPress(icon: "pencil", help: "Edit", action: edit)
                IconPress(icon: "trash-2", help: "Delete", action: delete)
            }.fixedSize()
        }
        .background {
            RoundedRectangle(cornerRadius: Theme.radiusControl, style: .continuous)
                .fill(hovering ? Theme.hover : .clear).padding(.horizontal, -8)
        }
        .overlay(alignment: .bottom) { Rule() }
        .onHover { hovering = $0 }
        .animation(reduceMotion ? nil : NativeMotion.hover, value: hovering)
    }
}

private struct NativeArenaPresetItem: Identifiable { let value: JSONValue; var id: String { value["id"].string } }
private struct NativeArenaPresetEditor: View {
    let value: JSONValue
    let save: (JSONObject) async -> JSONValue?
    @Environment(\.dismiss) private var dismiss
    @State private var title = ""
    @State private var category = "custom"
    @State private var prompt = ""
    @State private var busy = false
    @State private var restoredID: JSONValue?
    var body: some View {
        BenchSheet(eyebrow: value["id"].isNull ? "New preset" : "Edit preset", title: title, editing: $title,
                   placeholder: "Name this task", titleLabel: "Title", focusTitle: value["id"].isNull, width: 650, height: 520) {
            VStack(alignment: .leading, spacing: 16) {
                HStack(spacing: 12) {
                    MicroLabel("Category")
                    Entry(placeholder: "Category", text: $category, width: 200).accessibilityLabel("Category")
                }
                BenchEditor(text: $prompt, placeholder: "The task. Say what the judge should be shown at the end.", label: "Preset prompt")
            }
        } note: {
            Text("Every contestant receives this verbatim in an empty folder.")
        } actions: {
            Button("Cancel") { dismiss() }.buttonStyle(Press(.quiet)).keyboardShortcut(.cancelAction)
            Button("Save", action: submit).buttonStyle(Press(.primary)).keyboardShortcut(.defaultAction)
                .disabled(busy || title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
        .task(id: value["id"]) {
            guard restoredID != value["id"] else { return }
            restoredID = value["id"]
            title = value["title"].string
            category = value["category"].string.isEmpty ? "custom" : value["category"].string
            prompt = value["prompt"].string
        }
    }
    private func submit() {
        guard !busy, !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        var input: JSONObject = ["title": .string(title), "category": .string(category), "prompt": .string(prompt)]
        if !value["id"].isNull { input["id"] = value["id"] }
        busy = true
        Task { if await save(input) != nil { dismiss() }; busy = false }
    }
}

@MainActor func NativeArenaConfirm(_ title: String, detail: String = "") -> Bool { let alert = NSAlert(); alert.messageText = title; alert.informativeText = detail; alert.addButton(withTitle: "Continue"); alert.addButton(withTitle: "Cancel"); return alert.nativeRunModal() == .alertFirstButtonReturn }
func NativeArenaDuration(_ ms: Double) -> String { guard ms > 0, ms.isFinite else { return "—" }; let seconds = Int(ms / 1000); return seconds >= 60 ? "\(seconds / 60)m \(seconds % 60)s" : "\(seconds)s" }
