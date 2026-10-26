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
    var body: some View { VStack(alignment: .leading, spacing: 24) {
        SettingRow(title: "Mode", desc: mode == "random" ? "Contestants are drawn at random from every model on every route, so the ranking is not shaped by who you pick." : "You pick exactly which models compete, for a direct head-to-head.") {
            T3Segmented(options: [("random", "Random"), ("chosen", "Chosen")], selection: mode, icons: ["random": "shuffle", "chosen": "list-checks"]) { mode = $0 }.accessibilityLabel("Match mode")
        }
        Rectangle().fill(Theme.border).frame(height: 1)
        VStack(alignment: .leading, spacing: 20) {
            SettingRow(title: "Prompt", desc: randomPreset ? "A random preset per match, so no single task decides the ranking." : "Every contestant gets exactly this task in its own empty folder. Pick a preset or write your own.") {
                Menu {
                    Button("Custom prompt") { presetID = "" }
                    ForEach(ArenaPresentationPolicy.presetGroups(model.state["presets"].array)) { group in
                        Section(group.title) { ForEach(group.presets, id: \.self["id"]) { p in Button(p["title"].string) { presetID = p["id"].string } } }
                    }
                } label: {
                    HStack(spacing: 8) {
                        Text(model.state["presets"].array.first(where: { $0["id"].string == presetID })?["title"].string ?? "Custom prompt").lineLimit(1)
                        Spacer(minLength: 0); NativeIcon("chevron-down", size: 12)
                    }.font(Theme.ui(12)).foregroundStyle(Theme.dim).padding(.horizontal, 11).frame(width: 260, height: 30)
                        .background(Theme.field, in: RoundedRectangle(cornerRadius: Theme.radiusMd))
                        .overlay(RoundedRectangle(cornerRadius: Theme.radiusMd).strokeBorder(Theme.input, lineWidth: 1))
                }.menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).disabled(randomPreset).accessibilityLabel("Preset")
            }
            if !randomPreset {
                TextEditor(text: Binding(get: { prompt }, set: { prompt = $0; presetID = "" })).font(Theme.ui(13)).scrollContentBackground(.hidden)
                    .padding(10).frame(height: 150).background(Theme.field, in: RoundedRectangle(cornerRadius: Theme.radiusMd))
                    .overlay(RoundedRectangle(cornerRadius: Theme.radiusMd).strokeBorder(Theme.input, lineWidth: 1)).accessibilityLabel("Match prompt")
                Button("Save as preset", nativeIcon: "plus") { saving = true }.buttonStyle(T3Button(.ghost)).disabled(prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            SettingRow(title: "Random preset", desc: "Draw a different preset for this match instead of the prompt above.") {
                T3Switch(isOn: $randomPreset).accessibilityLabel("Draw a random preset")
            }
        }
        Rectangle().fill(Theme.border).frame(height: 1)
        VStack(alignment: .leading, spacing: 20) {
            if mode == "random" {
                SettingRow(title: "Contestants", desc: "How many models are drawn. Each one is its own Claude Code session in its own folder.") {
                    T3Segmented(options: Array(2...8).map { (value: $0, label: String($0)) }, selection: count) { count = $0 }.accessibilityLabel("Contestant count")
                }
                SettingRow(title: "Pool", desc: "\(eligible.count) of \(contestants.count) models are eligible. Untick models you never want drawn.") {
                    Button("Manage pool") { picker = "pool" }.buttonStyle(T3Button(.outline))
                }
            } else {
                SectionLabel(text: "Contestants") { Button("Pick contestants", nativeIcon: "plus") { picker = "chosen" }.buttonStyle(T3Button(.outline)) }
                Text("Between two and eight. Their positions are shuffled and hidden until you vote.").font(Theme.ui(12.5)).foregroundStyle(Theme.muted)
                ForEach(contestants.filter { chosen.contains($0["key"].string) }, id: \.self) { c in
                    HStack {
                        Text(c["label"].string).font(Theme.mono(12)).foregroundStyle(Theme.dim)
                        Button { setChosen(chosen.subtracting([c["key"].string])) } label: { NativeIcon("x", size: 12) }
                            .buttonStyle(T3Button(.ghost)).help("Remove contestant").accessibilityLabel("Remove " + c["label"].string)
                    }
                }
            }
        }
        Rectangle().fill(Theme.border).frame(height: 1)
        VStack(spacing: 20) {
            SettingRow(title: "Time limit", desc: "Per contestant. A session that runs out is stopped and judged on what it presented by then.") {
                NativeArenaBudgetPicker(title: "Time limit", value: $timeout, presets: [10, 20, 40, 60], suffix: " min", bounds: 2...120, step: 2)
            }
            SettingRow(title: "Steps", desc: "The most agent turns a contestant may take.") {
                NativeArenaBudgetPicker(title: "Steps", value: $turns, presets: [40, 80, 160, 300], suffix: "", bounds: 5...400, step: 5)
            }
            SettingRow(title: "Telegram when done", desc: "One ping when the match is ready to judge.") { T3Switch(isOn: $notify).accessibilityLabel("Telegram when finished") }
        }
        Button("Start with \(mode == "random" ? count : chosen.count) contestants", nativeIcon: "play") { Task { await start() } }.buttonStyle(T3Button(.primary)).disabled(busy || (mode == "random" ? eligible.count < count : chosen.count < 2 || chosen.count > 8) || !randomPreset && presetID.isEmpty && prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
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
                Text("Custom " + title.lowercased()).font(Theme.ui(12, weight: .medium))
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
                Text(title).font(Theme.ui(18, weight: .semibold))
                Spacer()
                Button("Done") { changed(picked); dismiss() }
                    .buttonStyle(T3Button(.primary)).keyboardShortcut(.defaultAction)
            }
            HStack(spacing: 12) {
                Menu {
                    Button("All routes") { route = "" }
                    ForEach(Array(Set(model.state["contestants"].array.map { $0["route"].string })).sorted(), id: \.self) { id in
                        Button(routeName(id)) { route = id }
                    }
                } label: {
                    HStack(spacing: 8) {
                        Text(route.isEmpty ? "All routes" : routeName(route)).lineLimit(1)
                        Spacer(minLength: 0)
                        NativeIcon("chevron-down", size: 12)
                    }.font(Theme.ui(12)).foregroundStyle(Theme.dim).padding(.horizontal, 11)
                        .frame(width: 190, height: 32)
                        .background(Theme.field, in: RoundedRectangle(cornerRadius: Theme.radiusMd))
                        .overlay(RoundedRectangle(cornerRadius: Theme.radiusMd).strokeBorder(Theme.input, lineWidth: 1))
                }.menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).accessibilityLabel("Route")
                T3Field(placeholder: "Search every word", text: $query, leadingIcon: "search").accessibilityLabel("Search contestants")
            }
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    if rows.isEmpty { Text("No matching contestants").font(Theme.ui(12)).foregroundStyle(Theme.muted).frame(maxWidth: .infinity).padding(.vertical, 32) }
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
                            .accessibilityLabel(c["label"].string).help(c["label"].string)
                    }
                }
            }
            HStack(spacing: 8) {
                Text("\(picked.count) selected").font(Theme.mono(11)).foregroundStyle(Theme.muted)
                Spacer()
                Button("None shown") { picked.subtract(rows.map { $0["key"].string }) }.buttonStyle(T3Button(.ghost))
                Button("All shown") { for row in rows where maximum == nil || picked.count < maximum! { picked.insert(row["key"].string) } }.buttonStyle(T3Button(.ghost))
                Button("Check routes", nativeIcon: "activity") { Task { checking = true; if let value = await model.call("check", ["contestants": .array(model.state["contestants"].array.filter { picked.contains($0["key"].string) && $0["route"].string != "subscription" })]) { for row in value["results"].array { checks[row["key"].string] = row; if !row["ok"].bool { picked.remove(row["key"].string) } } }; checking = false } }
                    .buttonStyle(T3Button(.outline)).disabled(checking || picked.isEmpty)
            }
            Text("Check routes sends one eight-token request per selected provider model. Subscription models are not probed.").font(Theme.ui(11)).foregroundStyle(Theme.muted)
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
            Text("Save preset").font(Theme.ui(18, weight: .semibold))
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
