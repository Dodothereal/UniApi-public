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
    var body: some View {
        GeometryReader { viewport in
        // Keep room for the rail and two minimum-width contestant cards.
        let showsRail = min(1500, viewport.size.width) - 2 * density.pageMargin >= 848
        let matchLayout = showsRail
            ? AnyLayout(HStackLayout(alignment: .top, spacing: 16))
            : AnyLayout(VStackLayout(alignment: .leading, spacing: 16))
        NativePage(title: "Arena", subtitle: "One task, several models, each in its own sandboxed Claude Code session. Rank what they present; identities reveal after the verdict, and every verdict joins the shared ranking in the repo.", maxWidth: 1500, readiness: pageReadiness, actions: {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 10) { reloadButton; tabs }.fixedSize(horizontal: true, vertical: false)
                VStack(alignment: .trailing, spacing: 8) { reloadButton; tabs }
            }
        }) {
            if !model.pageError(includeRanking: tab == "Ranking").isEmpty { NativeError(message: model.pageError(includeRanking: tab == "Ranking")) }
            if !model.loaded && tab != "Ranking" {
                if !model.failed { ShimmerText(text: "Reading Arena presets and matches…").frame(maxWidth: .infinity).padding(.vertical, 40) }
            } else { switch tab {
            case "New match": NativeArenaNewMatch(model: model, initialPreset: preset) { id in selected = id; tab = "Judge" }
            case "Presets": presets
            case "Ranking": rankings
            default:
                if visible.isEmpty {
                    VStack(spacing: 12) {
                        NativeIcon("swords", size: 24).foregroundStyle(Theme.muted)
                        Text(tab == "Judge" ? "Nothing to judge" : "No matches yet").font(Theme.ui(14, weight: .medium))
                        Text("Start a match. Contestants run in the background and wait here for your verdict.").font(Theme.ui(12.5)).foregroundStyle(Theme.muted)
                        Button("New match", nativeIcon: "plus") { preset = ""; tab = "New match" }.buttonStyle(T3Button(.primary))
                    }.frame(maxWidth: .infinity).padding(.vertical, 48)
                } else {
                    matchLayout {
                        if showsRail { matchRail.frame(width: 260) }
                        else { compactMatchPicker }
                        if let match = model.matches.first(where: { $0["id"].string == selected }) ?? visible.first {
                            // Delete removes the current row before its success callback.
                            let nextID = ArenaPresentationPolicy.nextMatchID(in: visible, after: match["id"].string, history: tab == "History") ?? ""
                            NativeArenaMatch(runtime: runtime, model: model, match: match) { selected = nextID }.id(match["id"].string).frame(minWidth: 0, maxWidth: .infinity)
                        }
                    }
                }
            } }
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
                Text("Match \(index + 1) of \(visible.count)").font(Theme.mono(11)).foregroundStyle(Theme.muted)
                    .fixedSize(horizontal: true, vertical: false)
                Text(current?["prompt"].string ?? "Choose a match").font(Theme.ui(12.5)).lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Text(current.map { "\($0["mode"].string) · \($0["slots"].array.count) · \(matchStatus($0))" } ?? "")
                    .font(Theme.mono(10.5)).foregroundStyle(Theme.muted).fixedSize(horizontal: true, vertical: false)
                NativeIcon("chevron-down", size: 12).foregroundStyle(Theme.muted)
            }.accessibilityElement(children: .ignore)
                .padding(.horizontal, 12).frame(height: 36).foregroundStyle(Theme.ink)
                .background(Theme.field, in: RoundedRectangle(cornerRadius: Theme.radiusMd))
                .overlay(RoundedRectangle(cornerRadius: Theme.radiusMd).strokeBorder(Theme.input, lineWidth: 1))
        }.menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden)
            .accessibilityLabel("Selected match")
            .accessibilityValue("\(index + 1) of \(visible.count). \(current.map { "\($0["mode"].string), \($0["slots"].array.count) contestants, \(matchStatus($0))" } ?? ""). \(current?["prompt"].string ?? "")")
            .help(current?["prompt"].string ?? "Choose a match")
    }
    private func matchStatus(_ match: JSONValue) -> String {
        (match["verdict"].isNull ? match["status"].string : match["verdict"].string).replacingOccurrences(of: "_", with: " ")
    }
    private var matchRail: some View {
        Card(padding: 0) {
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(Array(visible.enumerated()), id: \.offset) { index, match in
                        if index > 0 { Rectangle().fill(Theme.border).frame(height: 1) }
                        NativeArenaMatchRow(match: match, viewed: match["id"].string == (selected.isEmpty ? visible.first?["id"].string : selected)) { selected = match["id"].string }
                    }
                }
            }.frame(height: min(620, CGFloat(visible.count) * 53 - 1))
        }
    }
    private var reloadButton: some View {
        Button("Reload", nativeIcon: "rotate-cw") { Task { await model.reload(ranking: tab == "Ranking" ? rankingMode : nil) } }.buttonStyle(T3Button(.outline))
    }
    private var tabs: some View {
        T3Segmented(options: ["Judge", "New match", "Ranking", "Presets", "History"].map { (value: $0, label: $0) }, selection: tab) { tab = $0 }.accessibilityLabel("Arena view")
    }
    private var presets: some View { VStack(alignment: .leading, spacing: 20) {
        SectionLabel(text: "Presets") {
            Button("New preset", nativeIcon: "plus") { editing = [:] }.buttonStyle(T3Button(.outline))
        }
        if model.state["presets"].array.isEmpty { NativeEmptyState(title: "No presets", detail: "Write one and it is one click away on every new match.") }
        ForEach(ArenaPresentationPolicy.presetGroups(model.state["presets"].array)) { group in
            Card(padding: 0) {
                Text(group.title.uppercased()).font(Theme.ui(11, weight: .medium)).tracking(0.55).foregroundStyle(Theme.muted)
                    .padding(.horizontal, 14).frame(maxWidth: .infinity, minHeight: 36, alignment: .leading)
                    .accessibilityAddTraits(.isHeader)
                Rectangle().fill(Theme.border).frame(height: 1).accessibilityHidden(true)
                ForEach(Array(group.presets.enumerated()), id: \.element["id"]) { index, p in
                    if index > 0 { Rectangle().fill(Theme.border).frame(height: 1).accessibilityHidden(true) }
                    PresetRow(preset: p, use: { preset = p["id"].string; tab = "New match" }, edit: { editing = p }, delete: {
                        if NativeArenaConfirm("Delete preset “\(p["title"].string)”?", detail: "Deleted built-in presets will stay deleted.") { Task { _ = await model.call("preset.delete", ["id": p["id"]]); await model.load() } }
                    })
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
                        Text(preset["title"].string).font(Theme.ui(13, weight: .medium)).foregroundStyle(Theme.ink)
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
                }.fixedSize()
            }.padding(.horizontal, 14).padding(.vertical, 10)
                .background(hovering ? Theme.subtle : .clear)
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
                    .background(hovering && enabled ? Theme.subtle : .clear, in: RoundedRectangle(cornerRadius: Theme.radiusMd))
                    .contentShape(Rectangle())
            }.buttonStyle(.plain).opacity(enabled ? 1 : 0.45).pointingHand(enabled)
                .onHover { hovering = $0 && enabled }.animation(reduceMotion ? nil : NativeMotion.hover, value: hovering)
                .help(title).accessibilityLabel(title)
        }
    }
    private var rankings: some View {
        let hasContent = model.rankingHasContent(for: rankingMode)
        let phase = model.rankingPhase(for: rankingMode)
        return VStack(alignment: .leading, spacing: 16) {
        NativeCard(title: "Standings") {
            Text("Pairwise Elo, K=32 shared across multi-way matches. All-bad is a draw; failures affect reliability, not rating.").font(Theme.ui(12)).foregroundStyle(Theme.muted)
            T3Segmented(options: [("all", "All"), ("random", "Random"), ("chosen", "Chosen")], selection: rankingMode) { rankingMode = $0 }.accessibilityLabel("Ranking scope")
            if phase == .loading && hasContent { ShimmerText(text: "Refreshing ranking…") }
            if hasContent {
                if model.standings.isEmpty { NativeEmptyState(title: "No verdicts yet", detail: "Judge a match or sync the shared ledger.") }
                ForEach(Array(model.standings.enumerated()), id: \.offset) { i, row in VStack(alignment: .leading, spacing: 5) { HStack { Text("\(i + 1). \(row["route"].string) · \(row["model"].string)").font(Theme.mono(12)); Spacer(); Text("\(row["elo"].int)").font(Theme.mono(13, weight: .semibold)) }; Text("\(row["wins"].int)W \(row["losses"].int)L \(row["draws"].int)D · \(row["failures"].int) failed · \(row["matches"].int) matches · \(ArenaStandingDetail(row).firstPlaceLabel) · \(NativeArenaDuration(row["avg_duration_ms"].double)) · \(Int(row["avg_turns"].double.rounded())) steps").font(Theme.ui(11)).foregroundStyle(Theme.muted); NativeGrowBar(fraction: fraction(row), color: Theme.pairColor(row["key"].string), delay: Double(i) * 0.045) }.padding(.vertical, 6).help(ArenaStandingDetail(row).accessibilitySummary) }
            } else if phase == .failed {
                NativeEmptyState(title: "Ranking unavailable", detail: "Use Reload to retry this scope.")
            } else { ShimmerText(text: "Reading ranking and shared ledger…") }
        }
        if hasContent {
        NativeCard(title: "Shared ledger") {
            Text("\(model.recent.count) recent records · \(model.ledger["files"].int) files · \(model.ledger["unpublished"].int) unpublished · \(model.ledger["behind"].int) new upstream").font(Theme.ui(12))
            Text(model.ledger["remote"].string.isEmpty ? "Results stay on this machine without a Git remote." : model.ledger["remote"].string).font(Theme.mono(11)).textSelection(.enabled)
            if model.ledger["git"].bool { HStack { Button("Sync") { Task { await model.share("ledger.sync", mode: rankingMode) } }; Button("Publish") { if NativeArenaConfirm("Publish Arena verdict files?", detail: "This pushes new immutable results to the arena-results branch of the configured remote.") { Task { await model.share("ledger.publish", mode: rankingMode) } } } }.disabled(model.busy) }
            if !model.output.isEmpty { Text(model.output).font(Theme.mono(11)).textSelection(.enabled) }
        }
        NativeCard(title: "Recent verdicts") {
            if pageActive { TimelineView(.periodic(from: .now, by: 30)) { clock in recentVerdicts(at: clock.date) } }
            else { recentVerdicts(at: Date()) }
        }
        }
    } }
    private func recentVerdicts(at now: Date) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(Array(model.recent.enumerated()), id: \.offset) { _, record in
                VStack(alignment: .leading, spacing: 3) {
                    Text(record["prompt"].string).lineLimit(2).font(Theme.ui(12))
                    Text(ArenaPresentationPolicy.recentVerdictMetadata(record, now: now)).font(Theme.mono(10)).foregroundStyle(Theme.muted)
                    Text(record["contestants"].array.sorted { ($0["rank"].isNull ? 99 : $0["rank"].int) < ($1["rank"].isNull ? 99 : $1["rank"].int) }.map { "\($0["route"].string) · \($0["model"].string)\($0["status"].string == "failed" ? " (failed)" : "")" }.joined(separator: " > ")).font(Theme.mono(11)).textSelection(.enabled)
                    Divider()
                }
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
    var body: some View {
        Button(action: open) {
            HStack(spacing: 10) {
                StatusDot(color: match["status"].string == "failed" ? Theme.fail : match["status"].string == "done" ? Theme.ok : Theme.accent, pulse: match["status"].string == "running")
                VStack(alignment: .leading, spacing: 2) {
                    Text(match["prompt"].string).font(Theme.ui(12.5)).foregroundStyle(Theme.ink).lineLimit(1)
                    Text("\(match["mode"].string) · \(match["slots"].array.count) · \(match["verdict"].isNull ? match["status"].string : match["verdict"].string.replacingOccurrences(of: "_", with: " "))")
                        .font(Theme.mono(10.5)).foregroundStyle(Theme.muted).lineLimit(1)
                }.frame(maxWidth: .infinity, alignment: .leading)
                RowActionLabel(title: viewed ? "Viewing" : "View", active: viewed, hovering: hovering, width: 64).accessibilityHidden(true)
            }.padding(.horizontal, 12).frame(height: 52).contentShape(Rectangle())
                .background(viewed || hovering ? Theme.subtle : .clear)
        }.buttonStyle(.plain).pointingHand().onHover { hovering = $0 }.accessibilityAddTraits(viewed ? [.isSelected] : [])
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
                Text(value["id"].isNull ? "New preset" : "Edit preset").font(Theme.ui(18, weight: .semibold))
                Text("Every contestant receives the prompt verbatim in an empty folder. Say what the judge should be shown at the end.")
                    .font(Theme.ui(12)).foregroundStyle(Theme.muted)
            }
            HStack(spacing: 12) {
                T3Field(placeholder: "Title", text: $title).accessibilityLabel("Title")
                T3Field(placeholder: "Category", text: $category, width: 180).accessibilityLabel("Category")
            }
            TextEditor(text: $prompt).font(Theme.ui(13)).scrollContentBackground(.hidden)
                .padding(10).background(Theme.field, in: RoundedRectangle(cornerRadius: Theme.radiusMd))
                .overlay(RoundedRectangle(cornerRadius: Theme.radiusMd).strokeBorder(Theme.input, lineWidth: 1))
                .overlay(alignment: .topLeading) {
                    if prompt.isEmpty {
                        Text("The task").font(Theme.ui(13)).foregroundStyle(Theme.muted).padding(14)
                            .allowsHitTesting(false).accessibilityHidden(true)
                    }
                }.accessibilityLabel("Preset prompt")
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
