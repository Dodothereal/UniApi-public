import SwiftUI
import UniApiCore
import UniApiPresentation

struct NativeArenaNewMatch: View {
    @ObservedObject var model: NativeArenaModel
    let initialPreset: String
    let queued: (String) -> Void
    @AppStorage("uniapi.arena.mode") private var mode = "random"
    @AppStorage("uniapi.arena.prompt") private var prompt = ""
    @AppStorage("uniapi.arena.chosen") private var chosenJSON = "[]"
    @State private var presetID = ""
    @State private var initialized = false
    @State private var randomPreset = false
    @State private var count = 2
    @State private var timeout = 20
    @State private var turns = 80
    @State private var notify = true
    @State private var picker = ""
    @State private var saving = false
    @State private var busy = false
    private var contestants: [JSONValue] { model.state["contestants"].array }
    private var chosen: Set<String> { ArenaContestantPolicy.selection(Set(((try? JSONValue.decode(Data(chosenJSON.utf8))) ?? []).array.map(\.string)), contestants: contestants) }
    private var eligible: Set<String> { Set(contestants.map { $0["key"].string }).subtracting(model.state["excluded"].array.map(\.string)) }
    private var startDisabled: Bool { busy || (mode == "random" ? eligible.count < count : chosen.count < 2 || chosen.count > 8) || !randomPreset && presetID.isEmpty && prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    @Environment(\.nativeInterfaceDensity) private var density
    private func label(_ text: String, detail: String = "") -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(text).font(Theme.ui(11, weight: .medium)).foregroundStyle(Theme.muted)
            if !detail.isEmpty { Text(detail).font(Theme.ui(11)).foregroundStyle(Theme.faint).lineLimit(1) }
        }.accessibilityAddTraits(.isHeader)
    }
    /// The task every contestant gets. It is the page; the right pane only says who runs it and for how long.
    private func task(fills: Bool) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                NativeMenuSelectLabel(title: model.state["presets"].array.first(where: { $0["id"].string == presetID })?["title"].string ?? "Custom prompt", width: 260) {
                    Button("Custom prompt") { presetID = "" }
                    ForEach(ArenaPresentationPolicy.presetGroups(model.state["presets"].array)) { group in
                        Section(group.title) { ForEach(group.presets, id: \.self["id"]) { p in Button(p["title"].string) { presetID = p["id"].string } } }
                    }
                }.disabled(randomPreset).accessibilityLabel("Preset")
                Button("Save as preset", nativeIcon: "save") { saving = true }.buttonStyle(T3Button(.ghost))
                    .disabled(randomPreset || prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                Spacer(minLength: 0)
                Text("Random preset").font(Theme.ui(Theme.textXs)).foregroundStyle(Theme.muted)
                T3Switch(isOn: $randomPreset).accessibilityLabel("Draw a random preset")
                    .help("Draw a different preset for each match, so no single task decides the ranking.")
            }
            if randomPreset {
                Text("Each match draws one of the \(model.state["presets"].array.count) presets.").font(Theme.ui(Theme.textXs)).foregroundStyle(Theme.muted)
                    .frame(maxWidth: .infinity, maxHeight: fills ? .infinity : nil, alignment: .topLeading)
            } else {
                NativeEditor(text: Binding(get: { prompt }, set: { prompt = $0; presetID = "" }), placeholder: "What every contestant is asked to do, in its own empty folder")
                    .frame(minHeight: 200, maxHeight: fills ? .infinity : 260).accessibilityLabel("Match prompt")
            }
        }.padding(.horizontal, density.pageMargin).padding(.vertical, 20)
    }
    private var setup: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 12) {
                label("Contestants", detail: mode == "random" ? "\(eligible.count) of \(contestants.count) in the pool" : "\(chosen.count) picked, 2 to 8")
                T3Segmented(options: [("random", "Random draw"), ("chosen", "Hand-picked")], selection: mode, icons: ["random": "shuffle", "chosen": "list-checks"]) { mode = $0 }.accessibilityLabel("Match mode")
                    .help(mode == "random" ? "Drawn from every model on every route, so the ranking is not shaped by who you pick." : "You pick exactly which models compete.")
                if mode == "random" {
                    T3Segmented(options: Array(2...8).map { (value: $0, label: String($0)) }, selection: count) { count = $0 }.accessibilityLabel("Contestant count")
                    Button("Edit pool", nativeIcon: "list-checks") { picker = "pool" }.buttonStyle(T3Button(.outline))
                } else {
                    let picked = contestants.filter { chosen.contains($0["key"].string) }
                    VStack(spacing: 0) {
                        ForEach(picked, id: \.self) { c in
                            HStack(spacing: 8) {
                                Text(c["label"].string).font(Theme.mono(Theme.textXs)).foregroundStyle(Theme.dim).lineLimit(1).truncationMode(.middle).frame(maxWidth: .infinity, alignment: .leading)
                                T3IconButton(system: "x", help: "Remove " + c["label"].string, size: 12) { setChosen(chosen.subtracting([c["key"].string])) }
                            }.frame(minHeight: 30).overlay(alignment: .bottom) { Theme.rule.frame(height: 1) }
                        }
                    }
                    Button(picked.isEmpty ? "Pick contestants" : "Change", nativeIcon: "plus") { picker = "chosen" }.buttonStyle(T3Button(.outline))
                }
            }.padding(16).frame(maxWidth: .infinity, alignment: .leading)
            VStack(alignment: .leading, spacing: 12) {
                label("Limits", detail: "per contestant")
                VStack(alignment: .leading, spacing: 6) {
                    Text("Time").font(Theme.ui(Theme.textXs)).foregroundStyle(Theme.dim)
                        .help("A session that runs out is judged on what it presented by then.")
                    NativeArenaBudgetPicker(title: "Time limit", value: $timeout, presets: [10, 20, 40, 60], suffix: " min", bounds: 2...120, step: 2)
                }
                VStack(alignment: .leading, spacing: 6) {
                    Text("Steps").font(Theme.ui(Theme.textXs)).foregroundStyle(Theme.dim)
                    NativeArenaBudgetPicker(title: "Steps", value: $turns, presets: [40, 80, 160, 300], suffix: "", bounds: 5...400, step: 5)
                }
                HStack(spacing: 8) {
                    Text("Telegram when ready to judge").font(Theme.ui(Theme.textXs)).foregroundStyle(Theme.dim)
                    Spacer(minLength: 8)
                    T3Switch(isOn: $notify).accessibilityLabel("Telegram when finished")
                }
            }.padding(16).frame(maxWidth: .infinity, alignment: .leading)
                .overlay(alignment: .top) { Theme.rule.frame(height: 1) }
        }
    }
    private var startBar: some View {
        Button("Start \(mode == "random" ? count : chosen.count) contestants", nativeIcon: "play") { Task { await start() } }
            .buttonStyle(T3Button(.primary, size: Theme.textSm)).disabled(startDisabled)
            .keyboardShortcut(.return, modifiers: .command)
            .padding(.horizontal, 16).padding(.vertical, 12).frame(maxWidth: .infinity, alignment: .trailing)
            .overlay(alignment: .top) { Theme.rule.frame(height: 1) }
    }
    var body: some View { GeometryReader { geometry in
        if geometry.size.width >= 860 {
            HStack(alignment: .top, spacing: 0) {
                task(fills: true).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                VStack(spacing: 0) {
                    ScrollView { setup }.scrollContentBackground(.hidden)
                    startBar
                }
                .frame(width: 360).frame(maxHeight: .infinity, alignment: .top)
                .overlay(alignment: .leading) { Theme.rule.frame(width: 1) }
            }
        } else {
            VStack(spacing: 0) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        task(fills: false)
                        Theme.rule.frame(height: 1)
                        setup
                    }
                }.scrollContentBackground(.hidden)
                startBar
            }
        }
    }
    .task { guard !initialized else { return }; initialized = true; let d = model.state["defaults"]; count = d["count"].int; timeout = d["timeoutMin"].int; turns = d["maxTurns"].int; notify = d["notify"].bool; presetID = initialPreset; if let p = model.state["presets"].array.first(where: { $0["id"].string == initialPreset }) { prompt = p["prompt"].string } }
    .onChange(of: presetID) { _, id in if let p = model.state["presets"].array.first(where: { $0["id"].string == id }) { prompt = p["prompt"].string } }
    .sheet(isPresented: Binding(get: { !picker.isEmpty }, set: { if !$0 { picker = "" } })) {
        NativeArenaContestantPicker(model: model, title: picker == "pool" ? "Random pool" : "Choose contestants", selection: picker == "pool" ? eligible : chosen, maximum: picker == "pool" ? nil : 8) { selection in
            if picker == "pool" { Task { _ = await model.call("settings", ["excluded": .array(contestants.filter { !selection.contains($0["key"].string) }.map { $0["key"] })]); await model.load() } } else { setChosen(selection) }
        }
    }
    .sheet(isPresented: $saving) { NativeArenaSavePrompt(prompt: prompt) { input in if let value = await model.call("preset.save", input) { await model.load(); presetID = value["id"].string; saving = false } } }
    }
    private func setChosen(_ selection: Set<String>) { chosenJSON = String(decoding: (try? JSONValue.array(selection.sorted().map(JSONValue.string)).encoded()) ?? Data("[]".utf8), as: UTF8.self) }
    private func start() async {
        busy = true; defer { busy = false }
        _ = await model.call("settings", ["defaults": ["count": .number(Double(count)), "timeoutMin": .number(Double(timeout)), "maxTurns": .number(Double(turns)), "notify": .bool(notify)]])
        var input: JSONObject = ["mode": .string(mode), "prompt": .string(prompt), "randomPreset": .bool(randomPreset), "count": .number(Double(count)), "timeoutMin": .number(Double(timeout)), "maxTurns": .number(Double(turns)), "notify": .bool(notify), "contestants": .array(contestants.filter { chosen.contains($0["key"].string) }.map { ["route": $0["route"], "model": $0["model"]] })]
        if !presetID.isEmpty && !randomPreset { input["presetId"] = .string(presetID) }
        if let match = await model.call("match.create", input) { await model.load(); queued(match["id"].string) }
    }
}

private struct NativeArenaBudgetPicker: View {
    let title: String
    @Binding var value: Int
    let presets: [Int]
    let suffix: String
    let bounds: ClosedRange<Int>
    let step: Int
    @State private var showsCustom = false
    private var segments: some View {
        T3Segmented(options: presets.map { (value: $0, label: "\($0)\(suffix)") }, selection: value) {
            value = $0; showsCustom = false
        }.accessibilityLabel(title)
    }
    private var custom: some View {
        Button(presets.contains(value) ? "Custom" : "Custom: \(value)\(suffix)") { showsCustom.toggle() }
            .buttonStyle(T3Button(presets.contains(value) ? .ghost : .outline))
            .accessibilityLabel("Custom " + title.lowercased()).accessibilityValue("\(value)\(suffix)")
    }
    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 6) { segments; custom }
            VStack(alignment: .leading, spacing: 6) { segments; custom }
        }
        .popover(isPresented: $showsCustom, arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: 12) {
                Text("Custom " + title.lowercased()).font(Theme.ui(Theme.textXs, weight: .medium))
                Stepper("\(value)\(suffix)", value: $value, in: bounds, step: step)
                    .font(Theme.mono(12)).frame(width: 150).accessibilityLabel(title)
            }.padding(16).background(Theme.bg).foregroundStyle(Theme.ink)
        }
    }
}
private struct NativeArenaContestantPicker: View {
    @ObservedObject var model: NativeArenaModel
    let title: String
    let selection: Set<String>
    let maximum: Int?
    let changed: (Set<String>) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var picked = Set<String>()
    @State private var initialized = false
    @State private var query = ""
    @State private var route = ""
    @State private var checks: [String: JSONValue] = [:]
    @State private var checking = false
    private var rows: [JSONValue] { let terms = query.lowercased().split(separator: " "); return Array(model.state["contestants"].array.filter { c in (route.isEmpty || c["route"].string == route) && terms.allSatisfy { c["label"].string.lowercased().contains($0) } }.prefix(500)) }
    private func routeName(_ id: String) -> String {
        let name = model.state["contestants"].array.first(where: { $0["route"].string == id })?["routeName"].string ?? ""
        return name.isEmpty ? id : name
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text(title).font(Theme.ui(Theme.textBase, weight: .semibold))
                Spacer()
                Button("Done") { changed(picked); dismiss() }
                    .buttonStyle(T3Button(.primary)).keyboardShortcut(.defaultAction)
            }
            HStack(spacing: 12) {
                NativeMenuSelectLabel(title: route.isEmpty ? "All routes" : routeName(route), width: 190) {
                    Button("All routes") { route = "" }
                    ForEach(Array(Set(model.state["contestants"].array.map { $0["route"].string })).sorted(), id: \.self) { id in
                        Button(routeName(id)) { route = id }
                    }
                }.accessibilityLabel("Route")
                T3Field(placeholder: "Search every word", text: $query, leadingIcon: "search").accessibilityLabel("Search contestants")
            }
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    if rows.isEmpty { Text("No matching contestants").font(Theme.ui(12)).foregroundStyle(Theme.muted).padding(.vertical, 24) }
                    ForEach(rows, id: \.self) { c in
                        Toggle(isOn: Binding(get: { picked.contains(c["key"].string) }, set: { on in
                            if on { if maximum == nil || picked.count < maximum! { picked.insert(c["key"].string) } }
                            else { picked.remove(c["key"].string) }
                        })) {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(c["model"].string.isEmpty ? c["label"].string : c["model"].string).font(Theme.mono(12)).lineLimit(2)
                                HStack(spacing: 8) {
                                    Text(c["routeName"].string.isEmpty ? c["route"].string : c["routeName"].string).font(Theme.ui(11)).foregroundStyle(Theme.muted)
                                    if let check = checks[c["key"].string] { Text(check["message"].string).font(Theme.ui(10)).foregroundStyle(check["ok"].bool ? Theme.okFg : Theme.failFg) }
                                }
                            }.frame(maxWidth: .infinity, alignment: .leading)
                        }.toggleStyle(.checkbox).padding(.vertical, 8).padding(.horizontal, 2)
                            .overlay(alignment: .bottom) { Theme.rule.frame(height: 1) }
                            .accessibilityLabel(c["label"].string).help(c["label"].string)
                    }
                }
            }
            HStack(spacing: 8) {
                Text("\(picked.count) selected").font(Theme.num(Theme.textXs, weight: .medium)).foregroundStyle(Theme.muted)
                Spacer()
                Button("None shown") { picked.subtract(rows.map { $0["key"].string }) }.buttonStyle(T3Button(.ghost))
                Button("All shown") { for row in rows where maximum == nil || picked.count < maximum! { picked.insert(row["key"].string) } }.buttonStyle(T3Button(.ghost))
                Button("Check routes", nativeIcon: "activity") { Task { checking = true; if let value = await model.call("check", ["contestants": .array(model.state["contestants"].array.filter { picked.contains($0["key"].string) && $0["route"].string != "subscription" })]) { for row in value["results"].array { checks[row["key"].string] = row; if !row["ok"].bool { picked.remove(row["key"].string) } } }; checking = false } }
                    .buttonStyle(T3Button(.outline)).disabled(checking || picked.isEmpty)
                    .help("Sends one eight-token request per selected provider model and unticks the ones that fail. Subscription models are not probed.")
            }
        }.padding(20).frame(width: 700, height: 520).background(Theme.bg).foregroundStyle(Theme.ink)
            .tint(Theme.accent).task { if !initialized { picked = selection; initialized = true } }
    }
}
private struct NativeArenaSavePrompt: View {
    let prompt: String
    let save: (JSONObject) async -> Void
    @State private var title = ""
    @State private var category = "custom"
    @State private var saving = false
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("Save preset").font(Theme.ui(Theme.textBase, weight: .semibold))
            VStack(spacing: 12) {
                T3Field(placeholder: "Title", text: $title).accessibilityLabel("Title")
                T3Field(placeholder: "Category", text: $category).accessibilityLabel("Category")
            }
            HStack(spacing: 8) {
                Spacer(minLength: 0)
                Button("Cancel") { dismiss() }
                    .buttonStyle(T3Button(.ghost)).keyboardShortcut(.cancelAction)
                Button("Save", action: submit)
                    .buttonStyle(T3Button(.primary)).keyboardShortcut(.defaultAction)
                    .disabled(saving || title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }.padding(20).frame(width: 420).background(Theme.bg).foregroundStyle(Theme.ink)
    }
    private func submit() {
        guard !saving, !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        let input: JSONObject = ["title": .string(title), "category": .string(category), "prompt": .string(prompt)]
        saving = true
        Task { await save(input); saving = false }
    }
}
