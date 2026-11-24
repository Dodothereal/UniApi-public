import SwiftUI
import AppKit
import UniApiCore
import UniApiPresentation

typealias NativeArenaModel = UniApiPresentation.NativeArenaModel

struct NativeArenaPage: View {
    let runtime: NativeRuntime
    let openPrompts: (() -> Void)?
    @StateObject private var model: NativeArenaModel
    @State private var screen: String
    @State private var origin = "Home"
    @State private var selection = ArenaMatchSelection()
    @State private var historySearch = ""
    @State private var preset = ""
    @State private var outcome: JSONValue = .null
    @State private var loadedOutcomeID: String?
    @State private var rankingMode = "all"
    @State private var editing: JSONValue?
    @State private var presetID = ""
    @State private var standingKey = ""
    @State private var rankingSearch = ""
    @Environment(\.nativeInterfaceDensity) private var density
    @Environment(\.nativePageActive) private var pageActive
    @Environment(\.nativeReducedMotion) private var reducedMotion
    @Environment(\.nativeMotionVisible) private var motionVisible
    private var selectionMotion: Animation? { reducedMotion || !motionVisible ? nil : NativeMotion.selection }

    init(runtime: NativeRuntime, opens: String = "Home", matchID: String? = nil, initialPreset: String = "", openPrompts: (() -> Void)? = nil) {
        self.runtime = runtime
        self.openPrompts = openPrompts
        _screen = State(initialValue: opens)
        _preset = State(initialValue: initialPreset)
        var selection = ArenaMatchSelection()
        selection[.judge] = matchID
        _selection = State(initialValue: selection)
        _model = StateObject(wrappedValue: NativeArenaModel(runtime: runtime))
    }

    private var home: Bool { screen == "Home" }
    private var scope: ArenaMatchSelection.Scope { origin == "History" ? .history : .judge }
    private var queue: [JSONValue] { selection.visible(model.matches, in: .judge) }
    private var history: [JSONValue] {
        let term = historySearch.trimmingCharacters(in: .whitespacesAndNewlines)
        return term.isEmpty ? allHistory : allHistory.filter { ArenaPresentationPolicy.matchesHistorySearch($0, term: term) }
    }
    private var allHistory: [JSONValue] { selection.visible(model.matches, in: .history) }
    private var selectedMatch: JSONValue? {
        model.matches.first { $0["id"].string == selection[scope] }
    }
    private var verdictID: String? {
        guard ["Match", "Watch"].contains(screen), let match = selectedMatch, match["revealed"].bool,
              ["ranked", "all_bad"].contains(match["verdict"].string) else { return nil }
        return match["id"].string
    }
    private var readiness: NativePageReadiness {
        if model.failed { return .failed }
        guard model.loaded else { return .pending }
        if let verdictID, loadedOutcomeID != verdictID { return .pending }
        guard screen == "Ranking" || home else { return .ready }
        switch model.rankingPhase(for: home ? "all" : rankingMode) {
        case .ready: return .ready
        case .failed: return .failed
        case .loading, .pending: return .pending
        }
    }

    private func open(_ id: String, from source: String = "Home", watch: Bool = false) {
        origin = source
        selection[source == "History" ? .history : .judge] = id
        let running = model.matches.first { $0["id"].string == id }.map { ArenaMatchSelection.JudgeGroup($0) == .inProgress } ?? false
        screen = watch || running ? "Watch" : "Match"
    }
    private var title: String {
        switch screen {
        case "Ranking": "Standings"
        case "Watch": selectedMatch.map { ArenaMatchSelection.JudgeGroup($0) == .reviewed } == true ? "Match result" : "Live lanes"
        case "Match": selectedMatch.map { ArenaMatchSelection.JudgeGroup($0) == .ready } == true ? "Blind duel" : "Match result"
        case "History", "Presets": screen
        default: "Arena"
        }
    }

    var body: some View {
        GeometryReader { viewport in
            let back: (() -> Void)? = home ? nil : { screen = ["Watch", "Match"].contains(screen) ? origin : "Home" }
            NativePage(title: title, readiness: readiness, scrolls: home, back: back, actions: {
                if home {
                    NativeIconMenu(help: "Arena pages") {
                        Button("History") { screen = "History" }
                        Button("Presets") { screen = "Presets" }
                        if let openPrompts { Button("Prompts", action: openPrompts) }
                    }
                }
                if screen == "History" {
                    TextField("Search matches", text: $historySearch).textFieldStyle(.roundedBorder).frame(maxWidth: 170)
                }
                if screen == "Ranking" {
                    T3Segmented(options: [("all", "All"), ("random", "Random"), ("chosen", "Chosen")], selection: rankingMode) { rankingMode = $0 }
                        .accessibilityLabel("Ranking scope").help("Matches with random contestants, ones you chose, or both")
                }
                T3IconButton(system: "refresh-cw", help: "Reload") {
                    Task { await model.reload(ranking: home ? "all" : screen == "Ranking" ? rankingMode : nil) }
                }
                if screen == "Presets" { Button("New preset", nativeIcon: "plus") { editing = [:] }.buttonStyle(T3Button(.outline)) }
            }) {
                VStack(alignment: .leading, spacing: 0) {
                    let error = model.pageError(includeRanking: screen == "Ranking" || home)
                    if !error.isEmpty {
                        NativeError(message: error).padding(.horizontal, home ? 0 : density.pageMargin).padding(.bottom, 10)
                    }
                    if !model.loaded && screen != "Ranking" {
                        if !model.failed { ShimmerText(text: "Loading…").padding(density.pageMargin) }
                    } else {
                        content(width: viewport.size.width)
                    }
                }
            }
        }
        .nativePageTask { await model.begin(runtime: runtime) }
        .nativePageTask(id: "\(screen):\(rankingMode):\(model.readActive):\(model.readGeneration)") {
            if model.readActive && (home || screen == "Ranking") { await model.ranking(home ? "all" : rankingMode) }
        }
        .nativePageTask(id: "\(verdictID ?? ""):\(model.readActive):\(model.readGeneration)") {
            guard let id = verdictID, model.readActive else { return }
            let value = await model.call("ranking", ["matchId": .string(id)])
            guard !Task.isCancelled, verdictID == id else { return }
            outcome = value ?? .null
            loadedOutcomeID = id
        }
        .nativePageActivity(suspended: { model.stop() })
        .onChange(of: screen) { previous, current in
            if previous == "Home", current != "Home" { preset = "" }
        }
        .sheet(item: Binding(get: { editing.map { NativeArenaPresetItem(value: $0) } }, set: { editing = $0?.value })) { item in
            NativeArenaPresetEditor(value: item.value) { input in
                if let saved = await model.call("preset.save", input) { editing = nil; await model.load(); return saved }
                return nil
            }
        }
    }

    @ViewBuilder private func content(width: CGFloat) -> some View {
        switch screen {
        case "Home": homeContent(width: width)
        case "Presets": presets
        case "Ranking": rankings(width: width)
        case "History": historyPage
        case "Watch", "Match":
            if let match = selectedMatch {
                let id = match["id"].string, group = ArenaMatchSelection.JudgeGroup(match)
                let next = ArenaPresentationPolicy.nextMatchID(in: scope == .history ? history : queue, after: id, history: scope == .history)
                if group == .inProgress || screen == "Watch" && group == .ready {
                    NativeArenaLive(model: model, match: match) { screen = "Match" }.id(id)
                } else {
                    NativeArenaMatch(runtime: runtime, model: model, match: match, outcome: loadedOutcomeID == id ? outcome : .null) {
                        if let next, next != id { open(next, from: origin) }
                        else { screen = origin }
                    }.id(id)
                }
            } else {
                EmptyState(icon: "swords", title: "Match unavailable", detail: "This match is no longer in the current match list.")
                    .padding(density.pageMargin)
            }
        default: homeContent(width: width)
        }
    }

    private func homeContent(width: CGFloat) -> some View {
        let layout = width >= 920 ? AnyLayout(HStackLayout(alignment: .top, spacing: 24)) : AnyLayout(VStackLayout(alignment: .leading, spacing: 24))
        return layout {
            VStack(alignment: .leading, spacing: 22) {
                NativeArenaNewMatch(model: model, initialPreset: preset) { open($0, watch: true) }.id(preset)
                cards("Ready to judge", rows: queue.filter { ArenaMatchSelection.JudgeGroup($0) == .ready })
                cards("In progress", rows: queue.filter { ArenaMatchSelection.JudgeGroup($0) == .inProgress })
                let recent = allHistory.filter { ArenaMatchSelection.JudgeGroup($0) == .reviewed }
                if !recent.isEmpty {
                    HStack {
                        Text("Recent results").font(Theme.ui(18, weight: .semibold)).accessibilityAddTraits(.isHeader)
                        Spacer()
                        Button("History", nativeIcon: "arrow-right") { screen = "History" }.buttonStyle(T3Button(.ghost))
                    }
                    ForEach(recent.prefix(3), id: \.self["id"]) { match in
                        NativeArenaMatchRow(match: match) { open(match["id"].string, from: "History") }
                    }
                }
                if queue.allSatisfy({ ArenaMatchSelection.JudgeGroup($0) == .reviewed }) && recent.isEmpty {
                    EmptyState(icon: "swords", title: "No matches yet", detail: "Start a match to watch contestants work and judge their answers blind.")
                }
            }.frame(maxWidth: .infinity, alignment: .leading)
            NativeArenaStandingsPreview(rows: model.rankingHasContent(for: "all") ? model.standings : [], trend: model.rankingHasContent(for: "all") ? model.trend : []) { screen = "Ranking" }
                .frame(maxWidth: width >= 920 ? 310 : .infinity, alignment: .leading)
        }
    }

    @ViewBuilder private func cards(_ title: String, rows: [JSONValue]) -> some View {
        if !rows.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                Text(title).font(Theme.ui(18, weight: .semibold)).accessibilityAddTraits(.isHeader)
                ForEach(rows, id: \.self["id"]) { match in
                    NativeArenaRunCard(model: model, match: match) {
                        open(match["id"].string, watch: ArenaMatchSelection.JudgeGroup(match) == .inProgress)
                    }
                }
            }
        }
    }

    private var historyPage: some View {
        ScrollView {
            if history.isEmpty {
                EmptyState(icon: "swords", title: "No matches", detail: historySearch.isEmpty ? "Matches will appear here." : "No matches fit this search.")
                    .padding(density.pageMargin)
            } else {
                LazyVStack(spacing: 0) {
                    ForEach(history, id: \.self["id"]) { match in
                        NativeArenaMatchRow(match: match) {
                            open(match["id"].string, from: "History")
                        }
                    }
                }.padding(.horizontal, density.pageMargin)
            }
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
                        Button("Use preset", nativeIcon: "play") { preset = item["id"].string; screen = "Home" }.buttonStyle(T3Button(.primary))
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
        let compactNames = ArenaPresentationPolicy.compactModelNames(rows.map { $0["model"].string })
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
                    let name = row["model"].string, route = row["route"].string
                    NativeArenaListRow(selected: standingKey == key, margin: density.pageMargin) {
                        withAnimation(selectionMotion) { standingKey = standingKey == key ? "" : key }
                    } content: {
                        let rank = ranks[key] ?? 0
                        Text("\(rank)").font(Theme.num(Theme.textXs, weight: .medium)).foregroundStyle(rank == 1 ? Theme.ink : Theme.muted).frame(width: 28, alignment: .leading)
                        HStack(spacing: 8) {
                            RoundedRectangle(cornerRadius: 1).fill(Theme.pairColor(key)).frame(width: 3, height: 12).accessibilityHidden(true)
                            if let compactName = compactNames[name] {
                                ViewThatFits(in: .horizontal) {
                                    Text(name)
                                    Text(compactName).truncationMode(.tail)
                                }.font(Theme.mono(Theme.textXs, weight: .medium)).lineLimit(1).accessibilityLabel(name)
                            } else {
                                Text(name).font(Theme.mono(Theme.textXs, weight: .medium)).lineLimit(1).truncationMode(.middle)
                            }
                            Text(route).font(Theme.ui(Theme.textXs)).foregroundStyle(Theme.muted).lineLimit(1)
                        }.frame(maxWidth: .infinity, alignment: .leading)
                        NativeGrowBar(fraction: (row["elo"].double - lower) / (upper - lower), color: Theme.pairColor(key), height: 7)
                            .frame(width: meter).padding(.trailing, 8).accessibilityHidden(true)
                        ForEach(columns, id: \.0) { column in
                            NativeNumberText(text: standingCell(row, column.0), font: Theme.num(Theme.textXs, weight: column.0 == "Elo" ? .semibold : .regular),
                                             color: column.0 == "Elo" ? Theme.ink : column.0 == "Failed" && row["failures"].int > 0 ? Theme.warnFg : Theme.dim)
                                .frame(width: column.1, alignment: .trailing)
                        }
                    }.help("\(name) · \(route)\n\(ArenaStandingDetail(row).accessibilitySummary)")
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
                    Text(ArenaPresentationPolicy.verdictOrder(record)).font(Theme.mono(11)).foregroundStyle(Theme.dim).textSelection(.enabled)
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
    let open: () -> Void
    @State private var hovering = false
    @Environment(\.nativeReducedMotion) private var reduceMotion
    var body: some View {
        Button(action: open) {
            VStack(alignment: .leading, spacing: 5) {
                Text(match["prompt"].string).font(Theme.ui(Theme.textSm)).foregroundStyle(Theme.ink).lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
                HStack(spacing: 6) {
                    StatusDot(color: match["status"].string == "failed" ? Theme.fail : match["status"].string == "done" ? (match["voted_at"].isNull ? Theme.warn : Theme.faint) : Theme.accent, pulse: match["status"].string == "running")
                    Text(ArenaPresentationPolicy.matchStatus(match)).font(Theme.ui(Theme.textXs)).foregroundStyle(Theme.muted)
                    Spacer(minLength: 4)
                    Text(match["voted_at"].isNull ? "\(match["slots"].array.count) \(match["mode"].string)" : NativeListTimeFormat.ago(match["voted_at"].double))
                        .font(Theme.ui(Theme.textXs)).foregroundStyle(Theme.faint).fixedSize()
                }.lineLimit(1)
            }.padding(.leading, 16).padding(.trailing, 14).padding(.vertical, 10).contentShape(Rectangle())
                .background(hovering ? Theme.subtle : .clear)
                .overlay(alignment: .bottom) { Theme.rule.frame(height: 1) }
        }.buttonStyle(.plain).pointingHand().onHover { hovering = $0 }
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
