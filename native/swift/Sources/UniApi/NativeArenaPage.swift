import SwiftUI
import AppKit
import UniApiCore
import UniApiPresentation

typealias NativeArenaModel = UniApiPresentation.NativeArenaModel

struct NativeArenaPage: View {
    let runtime: NativeRuntime
    @StateObject private var model: NativeArenaModel
    @State private var tab: String
    @Environment(\.nativeHostTabs) private var host
    @State private var matchSelection = ArenaMatchSelection()
    @State private var historySearch = ""
    @State private var preset = ""
    @State private var rankingMode = "all"
    @State private var editing: JSONValue?
    @State private var presetID = ""
    @State private var standingKey = ""
    @State private var rankingSearch = ""
    @Environment(\.nativeInterfaceDensity) private var density
    @Environment(\.nativePageActive) private var pageActive
    @Environment(\.nativeReducedMotion) private var reducedMotion
    @Environment(\.nativeMotionVisible) private var motionVisible
    init(runtime: NativeRuntime, opens: String = "Judge") {
        self.runtime = runtime
        _tab = State(initialValue: opens)
        _model = StateObject(wrappedValue: NativeArenaModel(runtime: runtime))
    }
    private var scope: ArenaMatchSelection.Scope { tab == "History" ? .history : .judge }
    private var visible: [JSONValue] {
        let rows = matchSelection.visible(model.matches, in: scope)
        let term = historySearch.trimmingCharacters(in: .whitespacesAndNewlines)
        guard scope == .history, !term.isEmpty else { return rows }
        return rows.filter { ArenaPresentationPolicy.matchesHistorySearch($0, term: term) }
    }
    private var current: JSONValue? { matchSelection.current(visible, in: scope) }
    private var selectionMotion: Animation? { reducedMotion || !motionVisible ? nil : NativeMotion.selection }
    private func select(_ id: String?, in scope: ArenaMatchSelection.Scope) {
        withAnimation(selectionMotion) { matchSelection[scope] = id }
    }
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
            NativeTabs(options: ["Judge", "Ranking", "Presets", "History"].map { (value: $0, label: $0) }, selection: tab, counts: ["Judge": waiting]) { tab = $0; host?.select($0) }
                .nativeHostedView(["Judge", "Ranking", "Presets", "History"]) { tab = $0 }
        }, actions: {
            if tab == "History" {
                TextField("Search matches", text: $historySearch).textFieldStyle(.roundedBorder).frame(maxWidth: 170)
            }
            if tab == "Ranking" {
                T3Segmented(options: [("all", "All"), ("random", "Random"), ("chosen", "Chosen")], selection: rankingMode) { rankingMode = $0 }
                    .accessibilityLabel("Ranking scope").help("Matches with random contestants, ones you chose, or both")
            }
            T3IconButton(system: "refresh-cw", help: "Reload") { Task { await model.reload(ranking: tab == "Ranking" ? rankingMode : nil) } }
            if tab == "Presets" { Button("New preset", nativeIcon: "plus") { editing = [:] }.buttonStyle(T3Button(.outline)) }
            if tab == "New match" { Button("Cancel") { tab = "Judge"; host?.select("Judge") }.buttonStyle(T3Button(.ghost)) }
            else { Button("New match", nativeIcon: "plus") { preset = ""; tab = "New match" }.buttonStyle(T3Button(.primary)) }
        }) {
            VStack(alignment: .leading, spacing: 0) {
            if !model.pageError(includeRanking: tab == "Ranking").isEmpty {
                NativeError(message: model.pageError(includeRanking: tab == "Ranking")).padding(.horizontal, density.pageMargin).padding(.top, 16)
            }
            if !model.loaded && tab != "Ranking" {
                if !model.failed { ShimmerText(text: "Loading…").padding(.horizontal, density.pageMargin).padding(.top, density.pageGap) }
            } else { switch tab {
            case "New match": NativeArenaNewMatch(model: model, initialPreset: preset) { id in select(id, in: .judge); tab = "Judge"; host?.select("Judge") }
            case "Presets": presets
            case "Ranking": rankings(width: viewport.size.width)
            default:
                if visible.isEmpty {
                    EmptyState(icon: "swords", title: tab == "Judge" ? "Nothing to judge" : "No matches",
                               detail: tab == "History" && !historySearch.isEmpty ? "No matches fit this search." : "Run a match to compare how models complete the same task.")
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
                            if let match = current {
                                // Delete removes the current row before its success callback.
                                let activeScope = scope, id = match["id"].string
                                let nextID = ArenaPresentationPolicy.nextMatchID(in: visible, after: id, history: activeScope == .history)
                                NativeArenaMatch(runtime: runtime, model: model, match: match, hold: { select(id, in: activeScope) }) {
                                    select(nextID, in: activeScope)
                                }.id(id).frame(minWidth: 0, maxWidth: .infinity)
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
        let current = self.current
        let index = visible.firstIndex(where: { $0["id"] == current?["id"] }) ?? 0
        return Menu {
            ForEach(Array(visible.enumerated()), id: \.element["id"]) { position, match in
                Button {
                    select(match["id"].string, in: scope)
                } label: {
                    Text("\(position + 1). \(match["mode"].string) · \(ArenaPresentationPolicy.matchStatus(match)) · \(String(match["prompt"].string.prefix(100)))")
                }.help(match["prompt"].string)
                    .accessibilityLabel("Match \(position + 1). \(match["prompt"].string)")
                    .accessibilityValue("\(match["mode"].string). \(ArenaPresentationPolicy.matchStatus(match))")
                    .accessibilityAddTraits(match["id"] == current?["id"] ? [.isSelected] : [])
            }
        } label: {
            HStack(spacing: 10) {
                Text("\(index + 1)/\(visible.count)").font(Theme.num(11, weight: .medium)).foregroundStyle(Theme.muted)
                    .fixedSize(horizontal: true, vertical: false)
                Text(current?["prompt"].string ?? "Choose a match").font(Theme.ui(12.5)).lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Text(current.map { "\($0["mode"].string) · \($0["slots"].array.count) · \(ArenaPresentationPolicy.matchStatus($0))" } ?? "")
                    .font(Theme.mono(10.5)).foregroundStyle(Theme.muted).fixedSize(horizontal: true, vertical: false)
                NativeIcon("chevrons-up-down", size: 12).foregroundStyle(Theme.faint)
            }.accessibilityElement(children: .ignore)
                .padding(.horizontal, 12).frame(height: Theme.controlLg).foregroundStyle(Theme.ink)
                .background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.radiusMd, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: Theme.radiusMd, style: .continuous).strokeBorder(Theme.border, lineWidth: 1))
        }.menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden)
            .accessibilityLabel("Selected match")
            .accessibilityValue("\(index + 1) of \(visible.count). \(current.map { "\($0["mode"].string), \($0["slots"].array.count) contestants, \(ArenaPresentationPolicy.matchStatus($0))" } ?? ""). \(current?["prompt"].string ?? "")")
            .help(current?["prompt"].string ?? "Choose a match")
    }
    private var matchRail: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                if scope == .history { matchRows(visible) }
                else {
                    let groups = Dictionary(grouping: visible, by: ArenaMatchSelection.JudgeGroup.init)
                    ForEach(ArenaMatchSelection.JudgeGroup.allCases, id: \.self) { group in
                        matchGroup(group.title, rows: groups[group] ?? [])
                    }
                }
            }
        }
    }
    @ViewBuilder private func matchGroup(_ title: String, rows: [JSONValue]) -> some View {
        if !rows.isEmpty {
            Text("\(title) · \(rows.count)").font(Theme.ui(11, weight: .medium)).foregroundStyle(Theme.muted)
                .padding(.horizontal, 16).frame(height: 30).frame(maxWidth: .infinity, alignment: .leading).accessibilityAddTraits(.isHeader)
            matchRows(rows)
        }
    }
    private func matchRows(_ rows: [JSONValue]) -> some View {
        let selected = current?["id"], activeScope = scope
        return ForEach(rows, id: \.self["id"]) { match in
            NativeArenaMatchRow(match: match, viewed: match["id"] == selected) { select(match["id"].string, in: activeScope) }
        }
    }
    // MARK: Presets

    private var inspectedPreset: JSONValue? { model.state["presets"].array.first { $0["id"].string == presetID } }
    @ViewBuilder private var presets: some View {
        if model.state["presets"].array.isEmpty {
            EmptyState(icon: "file-text", title: "No presets", detail: "A preset is a saved task you can start a match from.", actionTitle: "New preset") { editing = [:] }
                .padding(.horizontal, density.pageMargin).padding(.top, density.pageGap)
        } else {
            let groups = ArenaPresentationPolicy.presetGroups(model.state["presets"].array)
            let order = groups.flatMap { $0.presets.map { $0["id"].string } }
            NativeInspectorSplit(open: inspectedPreset != nil, width: 400, onClose: { presetID = "" }, main: {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(groups) { group in
                            HStack(spacing: 6) {
                                Text(group.title.prefix(1).uppercased() + group.title.dropFirst()).font(Theme.ui(11, weight: .medium)).foregroundStyle(Theme.muted)
                                Text("\(group.presets.count)").font(Theme.num(11, weight: .regular)).foregroundStyle(Theme.faint)
                            }.padding(.horizontal, density.pageMargin).frame(height: 32, alignment: .bottom).padding(.bottom, 6)
                                .accessibilityAddTraits(.isHeader)
                            ForEach(group.presets, id: \.self["id"]) { item in
                                NativeArenaListRow(selected: presetID == item["id"].string, margin: density.pageMargin) {
                                    presetID = presetID == item["id"].string ? "" : item["id"].string
                                } content: {
                                    Text(item["title"].string).font(Theme.ui(Theme.textSm, weight: .medium)).lineLimit(1).frame(width: 220, alignment: .leading)
                                    Text(item["prompt"].string).font(Theme.ui(Theme.textXs)).foregroundStyle(Theme.muted).lineLimit(1).frame(maxWidth: .infinity, alignment: .leading)
                                    if !item["builtin"].bool { Text("yours").font(Theme.ui(11)).foregroundStyle(Theme.dim).fixedSize().padding(.leading, 8) }
                                    NativeIcon("chevron-right", size: 12).foregroundStyle(presetID == item["id"].string ? Theme.ink : Theme.faint).padding(.leading, 12).accessibilityHidden(true)
                                }
                            }
                        }
                    }.padding(.bottom, 32)
                }
                .scrollContentBackground(.hidden).focusable().focusEffectDisabled()
                .onMoveCommand { direction in
                    guard let index = order.firstIndex(of: presetID) else { return }
                    let next = direction == .down ? index + 1 : direction == .up ? index - 1 : index
                    if order.indices.contains(next) { presetID = order[next] }
                }
            }, inspector: {
                if let item = inspectedPreset {
                    NativeInspector(title: item["title"].string, caption: item["category"].string + (item["builtin"].bool ? " · built-in" : ""), onClose: { presetID = "" }) {
                        Text(item["prompt"].string).font(Theme.ui(Theme.textSm)).lineSpacing(3).foregroundStyle(Theme.ink).textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    } actions: {
                        NativeIconMenu(help: "Preset actions") {
                            Button("Delete preset", role: .destructive) {
                                if NativeArenaConfirm("Delete preset “\(item["title"].string)”?", detail: "Deleted built-in presets will stay deleted.") { Task { _ = await model.call("preset.delete", ["id": item["id"]]); presetID = ""; await model.load() } }
                            }
                        }
                        Spacer(minLength: 0)
                        Button("Edit", nativeIcon: "pencil") { editing = item }.buttonStyle(T3Button(.outline))
                        Button("New match", nativeIcon: "play") { preset = item["id"].string; tab = "New match" }.buttonStyle(T3Button(.primary))
                    }
                }
            })
        }
    }

    // MARK: Ranking

    private var inspectedStanding: JSONValue? { model.standings.first { $0["key"].string == standingKey } }
    private var filteredStandings: [JSONValue] {
        let terms = rankingSearch.split(separator: ",").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        guard !terms.isEmpty else { return model.standings }
        return model.standings.filter { row in terms.contains { (row["model"].string + " " + row["route"].string).localizedCaseInsensitiveContains($0) } }
    }
    private func verdicts(for row: JSONValue?) -> [JSONValue] {
        guard let row else { return model.recent }
        return model.recent.filter { $0["contestants"].array.contains { $0["route"] == row["route"] && $0["model"] == row["model"] } }
    }
    @ViewBuilder private func rankings(width: CGFloat) -> some View {
        let hasContent = model.rankingHasContent(for: rankingMode)
        let phase = model.rankingPhase(for: rankingMode)
        if !hasContent {
            Group {
                if phase == .failed { EmptyState(icon: "trophy", title: "Ranking unavailable", detail: "Reload to try this scope again.") }
                else { ShimmerText(text: "Loading…") }
            }.padding(.horizontal, density.pageMargin).padding(.top, density.pageGap)
        } else {
            let wide = width >= 900
            HStack(alignment: .top, spacing: 0) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        if model.standings.isEmpty {
                            EmptyState(icon: "trophy", title: "No verdicts", detail: "Judge a match or sync the shared ledger.")
                                .padding(.horizontal, density.pageMargin).padding(.top, density.pageGap)
                        } else {
                            rankingHeader
                            if filteredStandings.isEmpty {
                                EmptyState(icon: "search", title: "No models found", detail: "Search by model or route.")
                                    .padding(density.pageMargin)
                            } else {
                                standingsTable(width: wide ? width - 341 : width)
                                NativeArenaHeadToHead(rows: filteredStandings, comparisons: model.comparisons)
                            }
                        }
                        if !wide { rankingPane.padding(.top, 24); ledgerActions }
                    }.padding(.bottom, 32).frame(maxWidth: .infinity, alignment: .topLeading)
                }
                .scrollContentBackground(.hidden).focusable().focusEffectDisabled()
                .onMoveCommand { direction in
                    let keys = filteredStandings.map { $0["key"].string }
                    guard let index = keys.firstIndex(of: standingKey) else { if direction == .down, let first = keys.first { standingKey = first }; return }
                    let next = direction == .down ? index + 1 : direction == .up ? index - 1 : index
                    if keys.indices.contains(next) { standingKey = keys[next] }
                }
                .onExitCommand { standingKey = "" }
                if wide {
                    VStack(spacing: 0) {
                        ScrollView { rankingPane }.scrollContentBackground(.hidden)
                        ledgerActions
                    }
                    .frame(width: 340).frame(maxHeight: .infinity, alignment: .top)
                    .overlay(alignment: .leading) { Theme.rule.frame(width: 1) }
                }
            }
        }
    }
    private var rankingHeader: some View {
        HStack(spacing: 10) {
            Text("Elo leaderboard").font(Theme.ui(18, weight: .semibold)).accessibilityAddTraits(.isHeader)
            Spacer(minLength: 0)
            TextField("Search model or route", text: $rankingSearch).textFieldStyle(.roundedBorder).frame(maxWidth: 200)
                .help("Separate terms with commas to show either model in a head-to-head comparison.")
        }.padding(.horizontal, density.pageMargin).padding(.vertical, 16)
    }
    private func standingsTable(width: CGFloat) -> some View {
        let columns: [(String, CGFloat)] = [("Elo", 54), ("Rated pairs", 72), ("Failed", 50)] + (width >= 570 ? [("Avg time", 72)] : [])
        let meter: CGFloat = width >= 660 ? 120 : width >= 450 ? 80 : 42
        let rows = filteredStandings, ranks = Dictionary(uniqueKeysWithValues: model.standings.enumerated().map { ($0.element["key"].string, $0.offset + 1) })
        let lower = floor(min(model.standings.last?["elo"].double ?? 1000, 1000) / 100) * 100
        let upper = max(lower + 100, ceil(max(model.standings.first?["elo"].double ?? 1000, 1000) / 100) * 100)
        return VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 0) {
                Text("#").frame(width: 28, alignment: .leading)
                Text("Model").frame(maxWidth: .infinity, alignment: .leading)
                Text("\(Int(lower))–\(Int(upper))").font(Theme.num(10, weight: .regular)).lineLimit(1)
                    .frame(width: meter).padding(.trailing, 8).accessibilityLabel("Elo bar scale: \(Int(lower)) through \(Int(upper))")
                ForEach(columns, id: \.0) { column in Text(column.0).frame(width: column.1, alignment: .trailing) }
            }.font(Theme.ui(11, weight: .medium)).foregroundStyle(Theme.muted).frame(height: 32).padding(.horizontal, density.pageMargin)
            LazyVStack(spacing: 0) {
                ForEach(rows, id: \.self["key"]) { row in
                    let key = row["key"].string
                    NativeArenaListRow(selected: standingKey == key, margin: density.pageMargin) {
                        withAnimation(selectionMotion) { standingKey = standingKey == key ? "" : key }
                    } content: {
                        let rank = ranks[key] ?? 0
                        Text("\(rank)").font(Theme.num(Theme.textXs, weight: .medium)).foregroundStyle(rank == 1 ? Theme.ink : Theme.muted).frame(width: 28, alignment: .leading)
                        HStack(spacing: 8) {
                            RoundedRectangle(cornerRadius: 1).fill(Theme.pairColor(key)).frame(width: 3, height: 12).accessibilityHidden(true)
                            Text(row["model"].string).font(Theme.mono(Theme.textXs, weight: .medium)).lineLimit(1).truncationMode(.middle)
                            Text(row["route"].string).font(Theme.ui(Theme.textXs)).foregroundStyle(Theme.muted).lineLimit(1)
                        }.frame(maxWidth: .infinity, alignment: .leading)
                        NativeGrowBar(fraction: (row["elo"].double - lower) / (upper - lower), color: Theme.pairColor(key), height: 7)
                            .frame(width: meter).padding(.trailing, 8).accessibilityHidden(true)
                        ForEach(columns, id: \.0) { column in
                            NativeNumberText(text: standingCell(row, column.0), font: Theme.num(Theme.textXs, weight: column.0 == "Elo" ? .semibold : .regular),
                                             color: column.0 == "Elo" ? Theme.ink : column.0 == "Failed" && row["failures"].int > 0 ? Theme.warnFg : Theme.dim)
                                .frame(width: column.1, alignment: .trailing)
                        }
                    }.help(ArenaStandingDetail(row).accessibilitySummary)
                }
            }
        }
    }
    private func standingCell(_ row: JSONValue, _ column: String) -> String {
        switch column {
        case "Elo": return "\(row["elo"].int)"
        case "Rated pairs": return "\(row["wins"].int + row["losses"].int + row["draws"].int)"
        case "Failed": return "\(row["failures"].int)"
        default: return NativeArenaDuration(row["avg_duration_ms"].double)
        }
    }
    private func paneSection<Content: View>(_ title: String, @ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).font(Theme.ui(11, weight: .medium)).foregroundStyle(Theme.muted).accessibilityAddTraits(.isHeader)
            content()
        }
        .padding(.horizontal, 16).padding(.vertical, 14).frame(maxWidth: .infinity, alignment: .leading)
        .overlay(alignment: .top) { Theme.rule.frame(height: 1) }
    }
    private func paneFact(_ label: String, _ value: String, tone: Color = Theme.ink) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(label).font(Theme.ui(Theme.textXs)).foregroundStyle(Theme.dim).lineLimit(1)
            Spacer(minLength: 8)
            Text(value).font(Theme.num(Theme.textXs, weight: .medium)).foregroundStyle(tone).lineLimit(1)
        }
    }
    /// Describes the selected model; with nothing selected, the ledger the standings are folded from.
    @ViewBuilder private var rankingPane: some View {
        let row = inspectedStanding, records = verdicts(for: row)
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .center, spacing: 8) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(row?["model"].string ?? "Verdict ledger").font(row == nil ? Theme.ui(Theme.textSm, weight: .semibold) : Theme.mono(Theme.textSm, weight: .semibold)).lineLimit(1).truncationMode(.middle)
                        .accessibilityAddTraits(.isHeader)
                    Text(row?["route"].string ?? (model.ledger["remote"].string.isEmpty ? "On this Mac only" : model.ledger["remote"].string))
                        .font(Theme.ui(11)).foregroundStyle(Theme.muted).lineLimit(1).truncationMode(.middle).textSelection(.enabled)
                }
                Spacer(minLength: 8)
                if row != nil { T3IconButton(system: "x", help: "Clear the selection", size: 13) { standingKey = "" } }
            }.padding(.leading, 16).padding(.trailing, 10).padding(.vertical, 14)
            if let row {
                paneSection("Rating") {
                    paneFact("Elo", "\(row["elo"].int)")
                    paneFact("Won, lost, drawn", "\(row["wins"].int) · \(row["losses"].int) · \(row["draws"].int)")
                    paneFact("Matches", "\(row["matches"].int)")
                    paneFact("Rated comparisons", "\(row["wins"].int + row["losses"].int + row["draws"].int)")
                    paneFact("First places", ArenaStandingDetail(row).firstPlaceLabel)
                    paneFact("Failed runs", "\(row["failures"].int)", tone: row["failures"].int > 0 ? Theme.warnFg : Theme.ink)
                }
                paneSection("Effort") {
                    paneFact("Average time", NativeArenaDuration(row["avg_duration_ms"].double))
                    paneFact("Average steps", row["avg_turns"].isNull ? "Not recorded" : "\(Int(row["avg_turns"].double.rounded()))")
                }
            } else {
                paneSection("Files") {
                    paneFact("Verdict files", "\(model.ledger["files"].int)")
                    if model.ledger["git"].bool {
                        paneFact("Not published", "\(model.ledger["unpublished"].int)", tone: model.ledger["unpublished"].int > 0 ? Theme.warnFg : Theme.ink)
                        paneFact("New upstream", "\(model.ledger["behind"].int)", tone: model.ledger["behind"].int > 0 ? Theme.accent : Theme.ink)
                    }
                    if !model.output.isEmpty { Text(model.output).font(Theme.mono(11)).foregroundStyle(Theme.dim).textSelection(.enabled) }
                    Text("Pairwise Elo, K=32 shared across multi-way matches. All-bad is a draw. Failures count against reliability, not rating.")
                        .font(Theme.ui(11)).foregroundStyle(Theme.muted).fixedSize(horizontal: false, vertical: true)
                }
            }
            if !records.isEmpty {
                paneSection(row == nil ? "Recent verdicts" : "Its verdicts") {
                    if pageActive { TimelineView(.periodic(from: .now, by: 30)) { clock in recentVerdicts(records, at: clock.date) } }
                    else { recentVerdicts(records, at: Date()) }
                }
            }
        }.frame(maxWidth: .infinity, alignment: .topLeading)
    }
    @ViewBuilder private var ledgerActions: some View {
        if model.ledger["git"].bool, inspectedStanding == nil {
            HStack(spacing: 8) {
                Button("Sync", nativeIcon: "refresh-cw") { Task { await model.share("ledger.sync", mode: rankingMode) } }.buttonStyle(T3Button(.outline))
                Button("Publish", nativeIcon: "upload") { if NativeArenaConfirm("Publish Arena verdict files?", detail: "This pushes new immutable results to the arena-results branch of the configured remote.") { Task { await model.share("ledger.publish", mode: rankingMode) } } }.buttonStyle(T3Button(.outline))
            }
            .disabled(model.busy).padding(.horizontal, 16).padding(.vertical, 12).frame(maxWidth: .infinity, alignment: .trailing)
            .overlay(alignment: .top) { Theme.rule.frame(height: 1) }
        }
    }
    private func recentVerdicts(_ records: [JSONValue], at now: Date) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(Array(records.prefix(12).enumerated()), id: \.offset) { _, record in
                VStack(alignment: .leading, spacing: 4) {
                    Text(record["prompt"].string).lineLimit(2).font(Theme.ui(Theme.textXs)).foregroundStyle(Theme.ink)
                    Text(record["contestants"].array.sorted { ($0["rank"].isNull ? 99 : $0["rank"].int) < ($1["rank"].isNull ? 99 : $1["rank"].int) }.map { "\($0["model"].string)\($0["status"].string == "failed" ? " (failed)" : "")" }.joined(separator: " > ")).font(Theme.mono(11)).foregroundStyle(Theme.dim).textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                        .help(record["contestants"].array.map { "\($0["route"].string) · \($0["model"].string)" }.joined(separator: "\n"))
                    Text(ArenaPresentationPolicy.recentVerdictMetadata(record, now: now)).font(Theme.ui(11)).foregroundStyle(Theme.faint)
                }.frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }
}

/// A selectable row of an Arena list: hairline above, raised when selected.
private struct NativeArenaListRow<Content: View>: View {
    let selected: Bool
    let margin: CGFloat
    let action: () -> Void
    @ViewBuilder var content: () -> Content
    @State private var hovering = false
    var body: some View {
        Button(action: action) {
            HStack(spacing: 0) { content() }.frame(minHeight: 38).padding(.horizontal, margin).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(selected ? Theme.raised : hovering ? Theme.subtle : .clear)
        .overlay(alignment: .top) { Theme.rule.frame(height: 1).padding(.horizontal, margin) }
        .overlay(alignment: .leading) { Theme.accent.frame(width: 2).opacity(selected ? 1 : 0) }
        .onHover { hovering = $0 }
        .accessibilityAddTraits(selected ? [.isSelected] : [])
    }
}

private struct NativeArenaMatchRow: View {
    let match: JSONValue
    let viewed: Bool
    let open: () -> Void
    @State private var hovering = false
    @Environment(\.nativeReducedMotion) private var reduceMotion
    /// The model ranked best, once the match is judged and the names are revealed.
    private var winner: String? {
        guard !match["voted_at"].isNull, let first = match["ranking"].array.first?.int,
              let slot = match["slots"].array.first(where: { $0["idx"].int == first }), slot["revealed"].bool, !slot["model"].string.isEmpty else { return nil }
        return slot["model"].string
    }
    var body: some View {
        Button(action: open) {
            VStack(alignment: .leading, spacing: 5) {
                Text(match["prompt"].string).font(Theme.ui(Theme.textSm, weight: viewed ? .medium : .regular)).foregroundStyle(Theme.ink).lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
                HStack(spacing: 6) {
                    StatusDot(color: match["status"].string == "failed" ? Theme.fail : match["status"].string == "done" ? (match["voted_at"].isNull ? Theme.warn : Theme.faint) : Theme.accent, pulse: match["status"].string == "running")
                    if let winner {
                        Text(winner).font(Theme.mono(11)).foregroundStyle(Theme.dim).truncationMode(.middle).help("Ranked best")
                    } else {
                        Text(ArenaPresentationPolicy.matchStatus(match)).font(Theme.ui(Theme.textXs)).foregroundStyle(Theme.muted)
                    }
                    Spacer(minLength: 4)
                    Text(match["voted_at"].isNull ? "\(match["slots"].array.count) \(match["mode"].string)" : NativeListTimeFormat.ago(match["voted_at"].double))
                        .font(Theme.ui(Theme.textXs)).foregroundStyle(Theme.faint).fixedSize()
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
