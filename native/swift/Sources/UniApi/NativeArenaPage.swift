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
    @Environment(\.nativeInterfaceDensity) private var density
    @Environment(\.nativePageActive) private var pageActive
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
    private var waiting: Int { model.matches.filter { $0["voted_at"].isNull && $0["status"].string == "done" }.count }
    var body: some View {
        GeometryReader { viewport in
        // Keep room for the rail and two minimum-width contestant columns.
        let showsRail = viewport.size.width >= 900
        NativePage(title: "Arena", readiness: pageReadiness, scrolls: false, tabs: {
            NativeTabs(options: ["Judge", "Ranking", "Presets", "History"].map { (value: $0, label: $0) }, selection: tab, counts: ["Judge": waiting]) { tab = $0 }
                .accessibilityLabel("Arena view")
        }, actions: {
            T3IconButton(system: "refresh-cw", help: "Reload") { Task { await model.reload(ranking: tab == "Ranking" ? rankingMode : nil) } }
            if tab == "Presets" { Button("New preset", nativeIcon: "plus") { editing = [:] }.buttonStyle(T3Button(.outline)) }
            if tab == "New match" { Button("Cancel") { tab = "Judge" }.buttonStyle(T3Button(.ghost)) }
            else { Button("New match", nativeIcon: "plus") { preset = ""; tab = "New match" }.buttonStyle(T3Button(.primary)) }
        }) {
            VStack(alignment: .leading, spacing: 0) {
            if !model.pageError(includeRanking: tab == "Ranking").isEmpty {
                NativeError(message: model.pageError(includeRanking: tab == "Ranking")).padding(.horizontal, density.pageMargin).padding(.top, 16)
            }
            if !model.loaded && tab != "Ranking" {
                if !model.failed { ShimmerText(text: "Loading…").padding(.horizontal, density.pageMargin).padding(.top, density.pageGap) }
            } else { switch tab {
            case "New match": NativePane(maxWidth: Theme.sheetWidth) { NativeArenaNewMatch(model: model, initialPreset: preset) { id in selected = id; tab = "Judge" } }
            case "Presets": NativePane(maxWidth: Theme.sheetWidth) { presets }
            case "Ranking": NativePane { rankings }
            default:
                if visible.isEmpty {
                    EmptyState(icon: "swords", title: tab == "Judge" ? "Nothing to judge" : "No matches",
                               detail: "A match gives several models the same task. They run in the background and wait here for your ranking.",
                               actionTitle: "New match") { preset = ""; tab = "New match" }
                        .padding(.horizontal, density.pageMargin).padding(.top, density.pageGap)
                } else {
                    HStack(alignment: .top, spacing: 0) {
                        if showsRail {
                            matchRail.frame(width: 264).background(Theme.sunken.opacity(0.5))
                            Theme.border.frame(width: 1)
                        }
                        VStack(alignment: .leading, spacing: 0) {
                            if !showsRail {
                                compactMatchPicker.padding(.horizontal, density.pageMargin).padding(.vertical, 10)
                                Theme.rule.frame(height: 1)
                            }
                            if let match = model.matches.first(where: { $0["id"].string == selected }) ?? visible.first {
                                // Delete removes the current row before its success callback.
                                let nextID = ArenaPresentationPolicy.nextMatchID(in: visible, after: match["id"].string, history: tab == "History") ?? ""
                                NativeArenaMatch(runtime: runtime, model: model, match: match) { selected = nextID }.id(match["id"].string).frame(minWidth: 0, maxWidth: .infinity)
                            }
                        }
                    }
                }
            } }
            }
        }
        .nativePageTask { await model.begin(runtime: runtime) }
        .nativePageTask(id: "\(tab):\(rankingMode):\(model.readActive):\(model.readGeneration)") { if tab == "Ranking", model.readActive { await model.ranking(rankingMode) } }
        .nativePageActivity(suspended: { model.stop() })
        .sheet(item: Binding(get: { editing.map { NativeArenaPresetItem(value: $0) } }, set: { editing = $0?.value })) { item in NativeArenaPresetEditor(value: item.value) { input in if let saved = await model.call("preset.save", input) { editing = nil; await model.load(); return saved }; return nil } }
        }
    }
    private var compactMatchPicker: some View {
        let current = model.matches.first(where: { $0["id"].string == selected }) ?? visible.first
        let index = visible.firstIndex(where: { $0["id"] == current?["id"] }) ?? 0
        return Menu {
            ForEach(Array(visible.enumerated()), id: \.element["id"]) { position, match in
                Button {
                    selected = match["id"].string
                } label: {
                    Text("\(position + 1). \(match["mode"].string) · \(matchStatus(match)) · \(String(match["prompt"].string.prefix(100)))")
                }.help(match["prompt"].string)
                    .accessibilityLabel("Match \(position + 1). \(match["prompt"].string)")
                    .accessibilityValue("\(match["mode"].string). \(matchStatus(match))")
                    .accessibilityAddTraits(match["id"] == current?["id"] ? [.isSelected] : [])
            }
        } label: {
            HStack(spacing: 10) {
                Text("\(index + 1)/\(visible.count)").font(Theme.num(11, weight: .medium)).foregroundStyle(Theme.muted)
                    .fixedSize(horizontal: true, vertical: false)
                Text(current?["prompt"].string ?? "Choose a match").font(Theme.ui(12.5)).lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Text(current.map { "\($0["mode"].string) · \($0["slots"].array.count) · \(matchStatus($0))" } ?? "")
                    .font(Theme.mono(10.5)).foregroundStyle(Theme.muted).fixedSize(horizontal: true, vertical: false)
                NativeIcon("chevrons-up-down", size: 12).foregroundStyle(Theme.faint)
            }.accessibilityElement(children: .ignore)
                .padding(.horizontal, 12).frame(height: Theme.controlLg).foregroundStyle(Theme.ink)
                .background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.radiusMd, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: Theme.radiusMd, style: .continuous).strokeBorder(Theme.border, lineWidth: 1))
        }.menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden)
            .accessibilityLabel("Selected match")
            .accessibilityValue("\(index + 1) of \(visible.count). \(current.map { "\($0["mode"].string), \($0["slots"].array.count) contestants, \(matchStatus($0))" } ?? ""). \(current?["prompt"].string ?? "")")
            .help(current?["prompt"].string ?? "Choose a match")
    }
    private func matchStatus(_ match: JSONValue) -> String {
        (match["verdict"].isNull ? match["status"].string : match["verdict"].string).replacingOccurrences(of: "_", with: " ")
    }
    private var matchRail: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                ForEach(Array(visible.enumerated()), id: \.offset) { index, match in
                    NativeArenaMatchRow(match: match, viewed: match["id"].string == (selected.isEmpty ? visible.first?["id"].string : selected)) { selected = match["id"].string }
                }
            }
        }
    }
    private var presets: some View { VStack(alignment: .leading, spacing: density.sectionGap) {
        if model.state["presets"].array.isEmpty {
            EmptyState(icon: "file-text", title: "No presets", detail: "A preset is a saved task you can start a match from.", actionTitle: "New preset") { editing = [:] }
        }
        ForEach(ArenaPresentationPolicy.presetGroups(model.state["presets"].array)) { group in
            NativeSection(group.title.prefix(1).uppercased() + group.title.dropFirst(), detail: "\(group.presets.count)") {
                NativeStack {
                    ForEach(Array(group.presets.enumerated()), id: \.element["id"]) { index, p in
                        PresetRow(preset: p, use: { preset = p["id"].string; tab = "New match" }, edit: { editing = p }, delete: {
                            if NativeArenaConfirm("Delete preset “\(p["title"].string)”?", detail: "Deleted built-in presets will stay deleted.") { Task { _ = await model.call("preset.delete", ["id": p["id"]]); await model.load() } }
                        })
                    }
                }
            }
        }
    } }
    private struct PresetRow: View {
        let preset: JSONValue
        let use: () -> Void
        let edit: () -> Void
        let delete: () -> Void
        @State private var hovering = false
        @Environment(\.nativeReducedMotion) private var reduceMotion
        var body: some View {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 8) {
                        Text(preset["title"].string).font(Theme.ui(Theme.textSm, weight: .medium)).foregroundStyle(Theme.ink)
                            .fixedSize(horizontal: false, vertical: true)
                        if preset["builtin"].bool { MonoChip(text: "built-in").fixedSize() }
                    }
                    Text(preset["prompt"].string).font(Theme.ui(12)).foregroundStyle(Theme.muted).lineSpacing(2).lineLimit(2)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }.frame(maxWidth: .infinity, alignment: .leading)
                HStack(spacing: 2) {
                    PresetAction(icon: "play", title: "New match with this prompt", action: use)
                    PresetAction(icon: "pencil", title: "Edit", action: edit)
                    PresetAction(icon: "trash-2", title: "Delete", action: delete)
                }.fixedSize().opacity(hovering ? 1 : 0.45)
            }.padding(.vertical, 10).contentShape(Rectangle())
                .onHover { hovering = $0 }.animation(reduceMotion ? nil : NativeMotion.hover, value: hovering)
        }
    }
    private struct PresetAction: View {
        let icon: String
        let title: String
        let action: () -> Void
        @State private var hovering = false
        @Environment(\.isEnabled) private var enabled
        @Environment(\.nativeReducedMotion) private var reduceMotion
        var body: some View {
            Button(action: action) {
                NativeIcon(icon, size: 14)
                    .foregroundStyle(hovering && enabled ? (icon == "trash-2" ? Theme.failFg : Theme.ink) : Theme.muted)
                    .frame(width: 28, height: 28)
                    .background(hovering && enabled ? Theme.subtle : .clear, in: RoundedRectangle(cornerRadius: Theme.radiusSm, style: .continuous))
                    .contentShape(Rectangle())
            }.buttonStyle(.plain).opacity(enabled ? 1 : 0.45).pointingHand(enabled)
                .onHover { hovering = $0 && enabled }.animation(reduceMotion ? nil : NativeMotion.hover, value: hovering)
                .help(title).accessibilityLabel(title)
        }
    }
    @ViewBuilder private var rankings: some View {
        let hasContent = model.rankingHasContent(for: rankingMode)
        let phase = model.rankingPhase(for: rankingMode)
        NativeSection("Standings", detail: phase == .loading && hasContent ? "Refreshing" : "", trailing: {
            T3Segmented(options: [("all", "All"), ("random", "Random"), ("chosen", "Chosen")], selection: rankingMode) { rankingMode = $0 }.accessibilityLabel("Ranking scope")
        }) {
            if hasContent {
                if model.standings.isEmpty { EmptyState(icon: "trophy", title: "No verdicts", detail: "Judge a match or sync the shared ledger.") }
                else {
                    NativeStack {
                        ForEach(Array(model.standings.enumerated()), id: \.offset) { i, row in standing(row, index: i) }
                    }
                    Text("Pairwise Elo, K=32 shared across multi-way matches. All-bad is a draw. Failures count against reliability, not rating.")
                        .font(Theme.ui(Theme.textXs)).foregroundStyle(Theme.faint).fixedSize(horizontal: false, vertical: true)
                }
            } else if phase == .failed {
                EmptyState(icon: "trophy", title: "Ranking unavailable", detail: "Reload to try this scope again.")
            } else { ShimmerText(text: "Loading…") }
        }
        if hasContent {
            NativeSection("Shared ledger", trailing: {
                if model.ledger["git"].bool {
                    HStack(spacing: 6) {
                        Button("Sync", nativeIcon: "refresh-cw") { Task { await model.share("ledger.sync", mode: rankingMode) } }
                        Button("Publish", nativeIcon: "upload") { if NativeArenaConfirm("Publish Arena verdict files?", detail: "This pushes new immutable results to the arena-results branch of the configured remote.") { Task { await model.share("ledger.publish", mode: rankingMode) } } }
                    }.disabled(model.busy)
                }
            }) {
                NativeReadoutStrip {
                    NativeReadout(label: "Files", value: "\(model.ledger["files"].int)")
                    NativeReadout(label: "Unpublished", value: "\(model.ledger["unpublished"].int)", tone: model.ledger["unpublished"].int > 0 ? Theme.warnFg : Theme.ink)
                    NativeReadout(label: "New upstream", value: "\(model.ledger["behind"].int)", tone: model.ledger["behind"].int > 0 ? Theme.accent : Theme.ink)
                }
                Text(model.ledger["remote"].string.isEmpty ? "No Git remote. Results stay on this Mac." : model.ledger["remote"].string)
                    .font(model.ledger["remote"].string.isEmpty ? Theme.ui(Theme.textXs) : Theme.mono(Theme.textXs)).foregroundStyle(Theme.muted).textSelection(.enabled)
                if !model.output.isEmpty { Text(model.output).font(Theme.mono(Theme.textXs)).foregroundStyle(Theme.dim).textSelection(.enabled) }
            }
            if !model.recent.isEmpty {
                NativeSection("Recent verdicts", detail: "\(model.recent.count)") {
                    if pageActive { TimelineView(.periodic(from: .now, by: 30)) { clock in recentVerdicts(at: clock.date) } }
                    else { recentVerdicts(at: Date()) }
                }
            }
        }
    }
    private func standing(_ row: JSONValue, index i: Int) -> some View {
        HStack(alignment: .center, spacing: 14) {
            Text("\(i + 1)").font(Theme.num(Theme.textSm, weight: .medium)).foregroundStyle(i == 0 ? Theme.ink : Theme.faint).frame(width: 22, alignment: .leading)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 8) {
                    RoundedRectangle(cornerRadius: 1).fill(Theme.pairColor(row["key"].string)).frame(width: 3, height: 13)
                    Text(row["model"].string).font(Theme.mono(Theme.textSm, weight: .medium)).lineLimit(1)
                    Text(row["route"].string).font(Theme.ui(Theme.textXs)).foregroundStyle(Theme.muted).lineLimit(1)
                }
                Text("\(row["wins"].int)W \(row["losses"].int)L \(row["draws"].int)D · \(row["failures"].int) failed · \(row["matches"].int) matches · \(ArenaStandingDetail(row).firstPlaceLabel) · \(NativeArenaDuration(row["avg_duration_ms"].double)) · \(Int(row["avg_turns"].double.rounded())) steps")
                    .font(Theme.ui(Theme.textXs).monospacedDigit()).foregroundStyle(Theme.muted).lineLimit(1)
            }.frame(maxWidth: .infinity, alignment: .leading)
            NativeTickMeter(fraction: fraction(row), color: Theme.pairColor(row["key"].string), height: 10).frame(width: 150)
            Text("\(row["elo"].int)").font(Theme.num(Theme.textLg)).frame(width: 56, alignment: .trailing)
        }.padding(.vertical, 10).help(ArenaStandingDetail(row).accessibilitySummary)
    }
    private func recentVerdicts(at now: Date) -> some View {
        NativeStack {
            ForEach(Array(model.recent.enumerated()), id: \.offset) { _, record in
                VStack(alignment: .leading, spacing: 4) {
                    Text(record["prompt"].string).lineLimit(2).font(Theme.ui(Theme.textSm))
                    Text(record["contestants"].array.sorted { ($0["rank"].isNull ? 99 : $0["rank"].int) < ($1["rank"].isNull ? 99 : $1["rank"].int) }.map { "\($0["model"].string)\($0["status"].string == "failed" ? " (failed)" : "")" }.joined(separator: "  >  ")).font(Theme.mono(Theme.textXs)).foregroundStyle(Theme.dim).textSelection(.enabled)
                        .help(record["contestants"].array.map { "\($0["route"].string) · \($0["model"].string)" }.joined(separator: "\n"))
                    Text(ArenaPresentationPolicy.recentVerdictMetadata(record, now: now)).font(Theme.ui(Theme.textXs)).foregroundStyle(Theme.faint)
                }.padding(.vertical, 10).frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }
    private func fraction(_ row: JSONValue) -> Double { let floor = min(1000, model.standings.map { $0["elo"].double }.min() ?? 1000), peak = model.standings.map { $0["elo"].double }.max() ?? 1000; return (row["elo"].double - floor + 50) / max(1, peak - floor + 50) }
}

private struct NativeArenaMatchRow: View {
    let match: JSONValue
    let viewed: Bool
    let open: () -> Void
    @State private var hovering = false
    @Environment(\.nativeReducedMotion) private var reduceMotion
    private var status: String { match["verdict"].isNull ? match["status"].string : match["verdict"].string.replacingOccurrences(of: "_", with: " ") }
    var body: some View {
        Button(action: open) {
            VStack(alignment: .leading, spacing: 5) {
                Text(match["prompt"].string).font(Theme.ui(Theme.textSm, weight: viewed ? .medium : .regular)).foregroundStyle(Theme.ink).lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
                HStack(spacing: 6) {
                    StatusDot(color: match["status"].string == "failed" ? Theme.fail : match["status"].string == "done" ? (match["voted_at"].isNull ? Theme.warn : Theme.faint) : Theme.accent, pulse: match["status"].string == "running")
                    Text(match["status"].string == "done" && match["voted_at"].isNull ? "ready to judge" : status).font(Theme.ui(Theme.textXs)).foregroundStyle(Theme.muted)
                    Spacer(minLength: 4)
                    Text("\(match["slots"].array.count) \(match["mode"].string)").font(Theme.ui(Theme.textXs)).foregroundStyle(Theme.faint)
                }.lineLimit(1)
            }.padding(.leading, 16).padding(.trailing, 14).padding(.vertical, 10).contentShape(Rectangle())
                .background(viewed ? Theme.raised : hovering ? Theme.subtle : .clear)
                .overlay(alignment: .leading) { Theme.accent.frame(width: 2).opacity(viewed ? 1 : 0) }
                .overlay(alignment: .bottom) { Theme.rule.frame(height: 1) }
        }.buttonStyle(.plain).pointingHand().onHover { hovering = $0 }.accessibilityAddTraits(viewed ? [.isSelected] : [])
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
        VStack(alignment: .leading, spacing: 20) {
            VStack(alignment: .leading, spacing: 6) {
                Text(value["id"].isNull ? "New preset" : "Edit preset").font(Theme.ui(Theme.textBase, weight: .semibold))
                Text("Contestants get this text verbatim in an empty folder. Say what they should present at the end.")
                    .font(Theme.ui(Theme.textXs)).foregroundStyle(Theme.muted)
            }
            HStack(spacing: 12) {
                T3Field(placeholder: "Title", text: $title).accessibilityLabel("Title")
                T3Field(placeholder: "Category", text: $category, width: 180).accessibilityLabel("Category")
            }
            NativeEditor(text: $prompt, placeholder: "The task").accessibilityLabel("Preset prompt")
            HStack(spacing: 8) {
                Spacer(minLength: 0)
                Button("Cancel") { dismiss() }.buttonStyle(T3Button(.ghost)).keyboardShortcut(.cancelAction)
                Button("Save", action: submit).buttonStyle(T3Button(.primary)).keyboardShortcut(.defaultAction)
                    .disabled(busy || title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }.padding(20).frame(width: 650, height: 520).background(Theme.bg).foregroundStyle(Theme.ink)
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
