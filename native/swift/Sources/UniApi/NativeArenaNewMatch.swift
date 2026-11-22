import SwiftUI
import UniApiCore
import UniApiPresentation

/// The match setup sheet, ordered by what changes most: the task, then who
/// competes, then the limits, which keep their last values behind a disclosure.
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
    @State private var showLimits = false
    @Environment(\.dismiss) private var dismiss
    @Environment(\.nativeReducedMotion) private var reduceMotion
    private var contestants: [JSONValue] { model.state["contestants"].array }
    private var chosen: Set<String> { ArenaContestantPolicy.selection(Set(((try? JSONValue.decode(Data(chosenJSON.utf8))) ?? []).array.map(\.string)), contestants: contestants) }
    private var eligible: Set<String> { Set(contestants.map { $0["key"].string }).subtracting(model.state["excluded"].array.map(\.string)) }
    private var field: Int { mode == "random" ? count : chosen.count }
    private var blocked: Bool {
        busy || (mode == "random" ? eligible.count < count : chosen.count < 2 || chosen.count > 8) || !randomPreset && presetID.isEmpty && prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
    /// Why Start is unavailable, in one line.
    private var blocker: String {
        if !randomPreset && presetID.isEmpty && prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return "Write a task or choose a preset." }
        if mode == "random" { return eligible.count < count ? "The pool holds \(eligible.count) of the \(count) models this draw needs." : "" }
        return chosen.count < 2 ? "Choose at least two contestants." : chosen.count > 8 ? "Choose at most eight contestants." : ""
    }
    var body: some View {
        BenchSheet(title: "New match", detail: mode == "random" ? "blind draw" : "head-to-head", width: 640) {
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 22) {
                        taskBand
                        fieldBand
                        limits.id("limits")
                    }.padding(.trailing, 2)
                }
                .frame(maxHeight: 600)
                // The limits open below the fold on a short window; bring them into view.
                .onChange(of: showLimits) { _, open in
                    guard open else { return }
                    if reduceMotion { proxy.scrollTo("limits", anchor: .bottom) }
                    else { withAnimation(NativeMotion.toggle) { proxy.scrollTo("limits", anchor: .bottom) } }
                }
            }
        } note: {
            Text(blocker)
        } actions: {
            Button("Cancel") { dismiss() }.buttonStyle(Press(.quiet)).keyboardShortcut(.cancelAction)
            Button("Start with \(field) contestants", nativeIcon: "play") { Task { await start() } }
                .buttonStyle(Press(.primary)).disabled(blocked)
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

    // ---- the task ----------------------------------------------------------
    private var taskBand: some View {
        Band(title: "Task", spacing: 12) {
            presetMenu
        } content: {
            if randomPreset {
                Text("A preset is drawn for this match, so no single task decides the ranking.")
                    .font(Theme.ui(12.5)).foregroundStyle(Theme.muted).fixedSize(horizontal: false, vertical: true)
            } else {
                BenchEditor(text: Binding(get: { prompt }, set: { prompt = $0; presetID = "" }),
                            placeholder: "What every contestant is asked to do, in its own empty folder", label: "Match prompt", height: 124)
            }
            HStack(spacing: 10) {
                Flip(isOn: $randomPreset).accessibilityLabel("Draw a random preset")
                Text("Draw a random preset").font(Theme.ui(12.5)).foregroundStyle(Theme.dim)
                Spacer(minLength: 8)
                if !randomPreset {
                    Button("Save as preset", nativeIcon: "plus") { saving = true }.buttonStyle(Press(.quiet))
                        .disabled(prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
    }
    private var presetMenu: some View {
        Menu {
            Button("Custom prompt") { presetID = "" }
            ForEach(ArenaPresentationPolicy.presetGroups(model.state["presets"].array)) { group in
                Section(group.title) { ForEach(group.presets, id: \.self["id"]) { p in Button(p["title"].string) { presetID = p["id"].string } } }
            }
        } label: {
            HStack(spacing: 8) {
                Text(model.state["presets"].array.first(where: { $0["id"].string == presetID })?["title"].string ?? "Custom prompt").lineLimit(1)
                Spacer(minLength: 0)
                NativeIcon("chevrons-up-down", size: 12, strokeWidth: 1.75).foregroundStyle(Theme.muted)
            }
            .font(Theme.ui(12.5)).foregroundStyle(Theme.ink).padding(.horizontal, 10).frame(width: 250, height: 28)
            .overlay(RoundedRectangle(cornerRadius: Theme.radiusControl, style: .continuous).strokeBorder(Theme.ruleStrong, lineWidth: 1))
            .contentShape(Rectangle())
        }.menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize().disabled(randomPreset)
            .opacity(randomPreset ? 0.4 : 1).pointingHand(!randomPreset).accessibilityLabel("Preset")
    }

    // ---- who competes ------------------------------------------------------
    private var fieldBand: some View {
        Band(title: "Contestants", spacing: 0) {
            Stops(options: [("random", "Random"), ("chosen", "Chosen")], selection: mode, icons: ["random": "shuffle", "chosen": "list-checks"]) { mode = $0 }
                .accessibilityLabel("Match mode")
        } content: {
            if mode == "random" {
                OptionRow(title: "Drawn at random", detail: "Each one is its own Claude Code session in its own folder.") {
                    Stops(options: Array(2...8).map { (value: $0, label: String($0)) }, selection: count, spacing: 14) { count = $0 }.accessibilityLabel("Contestant count")
                }
                OptionRow(title: "Pool", detail: "\(eligible.count) of \(contestants.count) models can be drawn.", ruled: false) {
                    Button("Manage pool", nativeIcon: "sliders-horizontal") { picker = "pool" }
                }
            } else {
                ForEach(contestants.filter { chosen.contains($0["key"].string) }, id: \.self) { c in
                    HStack(spacing: 10) {
                        Theme.pairColor(c["key"].string).frame(width: 2, height: 14)
                        Text(c["label"].string).font(Theme.mono(12)).foregroundStyle(Theme.ink).lineLimit(1).truncationMode(.middle)
                        Spacer(minLength: 8)
                        IconPress(icon: "x", help: "Remove contestant", size: 13) { setChosen(chosen.subtracting([c["key"].string])) }
                            .accessibilityLabel("Remove " + c["label"].string)
                    }
                    .frame(minHeight: 34).overlay(alignment: .bottom) { Rule() }
                }
                OptionRow(title: chosen.isEmpty ? "Nobody chosen" : "\(chosen.count) chosen", detail: "Between two and eight. Positions are shuffled and hidden until you vote.", ruled: false) {
                    Button("Pick contestants", nativeIcon: "plus") { picker = "chosen" }
                }
            }
        }
    }

    // ---- limits ------------------------------------------------------------
    private var limits: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                if reduceMotion { showLimits.toggle() } else { withAnimation(NativeMotion.toggle) { showLimits.toggle() } }
            } label: {
                HStack(spacing: 12) {
                    HStack(spacing: 6) {
                        NativeIcon(showLimits ? "chevron-down" : "chevron-right", size: 13, strokeWidth: 1.75).foregroundStyle(Theme.muted)
                        Text("Limits").font(Theme.heading()).foregroundStyle(Theme.ink)
                    }
                    Rule().frame(minWidth: 12, maxWidth: .infinity)
                    Text("\(timeout) min · \(turns) steps · Telegram \(notify ? "on" : "off")").font(Theme.mono(10.5)).foregroundStyle(Theme.muted).fixedSize()
                }.frame(minHeight: 28).contentShape(Rectangle())
            }
            .buttonStyle(.plain).pointingHand()
            .accessibilityLabel("Limits").accessibilityValue(showLimits ? "Expanded" : "Collapsed")
            if showLimits {
                OptionRow(title: "Time limit", detail: "Per contestant. Out of time is judged on what it presented by then.") {
                    NativeArenaBudgetPicker(title: "Time limit", value: $timeout, presets: [10, 20, 40, 60], suffix: " min", bounds: 2...120, step: 2)
                }
                OptionRow(title: "Steps", detail: "The most agent turns a contestant may take.") {
                    NativeArenaBudgetPicker(title: "Steps", value: $turns, presets: [40, 80, 160, 300], suffix: "", bounds: 5...400, step: 5)
                }
                OptionRow(title: "Telegram when done", detail: "One ping when the match is ready to judge.", ruled: false) {
                    Flip(isOn: $notify).accessibilityLabel("Telegram when finished")
                }
            }
        }
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
        Stops(options: presets.map { (value: $0, label: "\($0)\(suffix)") }, selection: value, spacing: 14) {
            value = $0; showsCustom = false
        }.accessibilityLabel(title)
    }
    private var custom: some View {
        Button(presets.contains(value) ? "Custom" : "Custom: \(value)\(suffix)") { showsCustom.toggle() }
            .buttonStyle(Press(presets.contains(value) ? .quiet : .secondary))
            .accessibilityLabel("Custom " + title.lowercased()).accessibilityValue("\(value)\(suffix)")
    }
    var body: some View {
        HStack(spacing: 10) { segments; custom }
        .popover(isPresented: $showsCustom, arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: 12) {
                MicroLabel("Custom " + title.lowercased())
                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    Text("\(value)\(suffix)").font(Theme.readout(24)).foregroundStyle(Theme.ink).frame(minWidth: 84, alignment: .leading)
                    Stepper("\(value)\(suffix)", value: $value, in: bounds, step: step).labelsHidden().accessibilityLabel(title)
                }
            }.padding(16).background(Theme.popover).foregroundStyle(Theme.ink)
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
    private var routes: [(value: String, label: String)] {
        [(value: "", label: "All routes")] + Array(Set(model.state["contestants"].array.map { $0["route"].string })).sorted().map { (value: $0, label: routeName($0)) }
    }
    var body: some View {
        BenchSheet(title: title, detail: maximum.map { "\(picked.count) of \($0) selected" } ?? "\(picked.count) selected", width: 700, height: 560) {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 12) {
                    Pick(title: "Route", selection: $route, options: routes, width: 190)
                    Entry(placeholder: "Search every word", text: $query, icon: "search").accessibilityLabel("Search contestants")
                }
                VStack(spacing: 0) {
                    LedgerHead {
                        MicroLabel("Model").padding(.leading, 26)
                        Spacer(minLength: 0)
                        MicroLabel("Route").frame(width: 190, alignment: .leading)
                    }
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 0) {
                            if rows.isEmpty { Text("No matching contestants").font(Theme.ui(12.5)).foregroundStyle(Theme.muted).padding(.vertical, 20) }
                            ForEach(rows, id: \.self) { c in
                                Toggle(isOn: Binding(get: { picked.contains(c["key"].string) }, set: { on in
                                    if on { if maximum == nil || picked.count < maximum! { picked.insert(c["key"].string) } }
                                    else { picked.remove(c["key"].string) }
                                })) {
                                    HStack(spacing: 12) {
                                        Text(c["model"].string.isEmpty ? c["label"].string : c["model"].string).font(Theme.mono(12)).foregroundStyle(Theme.ink).lineLimit(1).truncationMode(.middle)
                                            .frame(maxWidth: .infinity, alignment: .leading)
                                        if let check = checks[c["key"].string] {
                                            Text(check["message"].string).font(Theme.ui(11.5)).foregroundStyle(check["ok"].bool ? Theme.okFg : Theme.failFg).lineLimit(1)
                                        }
                                        Text(c["routeName"].string.isEmpty ? c["route"].string : c["routeName"].string).font(Theme.ui(11.5)).foregroundStyle(Theme.muted).lineLimit(1)
                                            .frame(width: 190, alignment: .leading)
                                    }
                                }.toggleStyle(ArenaCheckRow())
                                    .accessibilityLabel(c["label"].string).help(c["label"].string)
                            }
                        }.padding(.horizontal, 8)
                    }.padding(.horizontal, -8)
                }
            }
        } note: {
            Text("Check routes sends one eight-token request per selected provider model. Subscription models are not probed.")
        } actions: {
            Button("None shown") { picked.subtract(rows.map { $0["key"].string }) }.buttonStyle(Press(.quiet))
            Button("All shown") { for row in rows where maximum == nil || picked.count < maximum! { picked.insert(row["key"].string) } }.buttonStyle(Press(.quiet))
            Button("Check routes", nativeIcon: "activity") { Task { checking = true; if let value = await model.call("check", ["contestants": .array(model.state["contestants"].array.filter { picked.contains($0["key"].string) && $0["route"].string != "subscription" })]) { for row in value["results"].array { checks[row["key"].string] = row; if !row["ok"].bool { picked.remove(row["key"].string) } } }; checking = false } }
                .disabled(checking || picked.isEmpty)
            Button("Done") { changed(picked); dismiss() }
                .buttonStyle(Press(.primary)).keyboardShortcut(.defaultAction)
        }
        .task { if !initialized { picked = selection; initialized = true } }
    }
}

/// A ledger line that is also a checkbox: the whole line toggles.
private struct ArenaCheckRow: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View { ArenaCheckRowBody(configuration: configuration) }
}
private struct ArenaCheckRowBody: View {
    let configuration: ToggleStyleConfiguration
    @State private var hovering = false
    @Environment(\.nativeReducedMotion) private var reduceMotion
    var body: some View {
        Button { configuration.isOn.toggle() } label: {
            HStack(spacing: 12) {
                ZStack {
                    RoundedRectangle(cornerRadius: 3, style: .continuous).fill(configuration.isOn ? Theme.ink : .clear)
                    RoundedRectangle(cornerRadius: 3, style: .continuous).strokeBorder(configuration.isOn ? Theme.ink : Theme.ruleStrong, lineWidth: 1)
                    if configuration.isOn { NativeIcon("check", size: 10, strokeWidth: 2.6).foregroundStyle(Theme.onInk) }
                }.frame(width: 14, height: 14)
                configuration.label
            }
            .frame(maxWidth: .infinity, minHeight: 34, alignment: .leading)
            .background {
                RoundedRectangle(cornerRadius: Theme.radiusControl, style: .continuous).fill(hovering ? Theme.hover : .clear).padding(.horizontal, -8)
            }
            .overlay(alignment: .bottom) { Rule() }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain).pointingHand()
        .onHover { hovering = $0 }
        .animation(reduceMotion ? nil : NativeMotion.hover, value: hovering)
        .accessibilityAddTraits(.isToggle).accessibilityValue(configuration.isOn ? "On" : "Off")
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
        BenchSheet(eyebrow: "Save preset", title: title, editing: $title, placeholder: "Name this task", titleLabel: "Title", focusTitle: true, width: 440) {
            HStack(spacing: 12) {
                MicroLabel("Category")
                Entry(placeholder: "Category", text: $category).accessibilityLabel("Category")
            }
        } note: {
            EmptyView()
        } actions: {
            Button("Cancel") { dismiss() }
                .buttonStyle(Press(.quiet)).keyboardShortcut(.cancelAction)
            Button("Save", action: submit)
                .buttonStyle(Press(.primary)).keyboardShortcut(.defaultAction)
                .disabled(saving || title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
    }
    private func submit() {
        guard !saving, !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        let input: JSONObject = ["title": .string(title), "category": .string(category), "prompt": .string(prompt)]
        saving = true
        Task { await save(input); saving = false }
    }
}
