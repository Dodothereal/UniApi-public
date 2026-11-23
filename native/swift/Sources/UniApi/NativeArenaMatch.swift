import AppKit
import SwiftUI
import UniApiCore
import UniApiPresentation

struct NativeArenaMatch: View {
    let runtime: NativeRuntime
    @ObservedObject var model: NativeArenaModel
    let match: JSONValue
    let outcome: JSONValue
    let next: () -> Void
    @State private var draft: ArenaDuel?
    @State private var busy = false
    @State private var tab = "Answers"
    @State private var leftContent = "Result"
    @State private var rightContent = "Result"
    @State private var compared = [0, 1]
    @Environment(\.nativePageActive) private var pageActive
    @Environment(\.nativeInterfaceDensity) private var density
    @Environment(\.nativeReducedMotion) private var reducedMotion
    @Environment(\.nativeMotionVisible) private var visible

    private var slots: [JSONValue] { match["slots"].array }
    private var compactNames: [String: String] {
        ArenaPresentationPolicy.compactModelNames(slots.map { $0["model"].string })
    }
    private var done: [Int] { slots.filter { $0["status"].string == "done" }.map { $0["idx"].int } }
    private var judging: Bool { ArenaMatchSelection.JudgeGroup(match) == .ready }
    private var duel: ArenaDuel { draft ?? ArenaDuel(contestants: done) }
    private var revealed: Bool { match["revealed"].bool }
    private var motion: Animation? { reducedMotion || !visible ? nil : NativeMotion.reveal }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .top, spacing: 8) {
                    Text(judging ? "Which answer does the job better?" : "Match prompt")
                        .font(Theme.ui(18, weight: .semibold)).accessibilityAddTraits(.isHeader)
                    Spacer(minLength: 8)
                    if judging { NativeStatus(text: "Identities hidden", tone: .idle) }
                    NativeIconMenu(help: "Match actions") {
                        Button("Run again") { act("rerun") }
                        Button("Delete match", role: .destructive) {
                            if NativeArenaConfirm("Delete this match and all its workspaces?", detail: "Any immutable verdict already in the results ledger remains there.") {
                                act("delete", then: next)
                            }
                        }
                    }
                }
                NativeDisclosure(String(match["prompt"].string.prefix(80)) + (match["prompt"].string.count > 80 ? "…" : "")) {
                    ScrollView {
                        Text(match["prompt"].string).textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }.frame(maxHeight: 130)
                }.help(match["prompt"].string)
            }.padding(.horizontal, density.pageMargin).padding(.vertical, 10)
            if !match["error"].isNull {
                NativeError(message: match["error"].string).padding(.horizontal, density.pageMargin).padding(.bottom, 8)
            }
            if judging {
                duelBody
            } else {
                resultBody
            }
        }.animation(motion, value: revealed)
    }

    private var duelBody: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                Text(duel.pair == nil ? "Ranking ready" : "Duel \(duel.decisions + 1)")
                    .font(Theme.ui(Theme.textSm, weight: .semibold))
                HStack(spacing: 5) {
                    ForEach(0..<(duel.pair == nil ? duel.decisions : duel.maximumDecisions), id: \.self) { step in
                        Circle().fill(step <= duel.decisions ? Theme.accent : Theme.track)
                            .frame(width: step == duel.decisions ? 8 : 6, height: step == duel.decisions ? 8 : 6)
                    }
                }.accessibilityHidden(true)
                Spacer(minLength: 8)
                Text("\(duel.decisions) complete\(duel.pair == nil ? "" : " · up to \(duel.maximumDecisions)")")
                    .font(Theme.mono(Theme.textXs)).foregroundStyle(Theme.muted)
            }.padding(.horizontal, density.pageMargin).padding(.vertical, 10)
            Theme.rule.frame(height: 1)
            if let pair = duel.pair, let left = slot(pair.left), let right = slot(pair.right) {
                HStack(alignment: .top, spacing: 0) {
                    answer(left, selection: $leftContent)
                    Theme.rule.frame(width: 1)
                    answer(right, selection: $rightContent)
                }.id(duel.decisions).nativeEntrance(.page)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Review the blind ranking").font(Theme.ui(20, weight: .semibold))
                        Text("Submitting reveals the contestants and records the verdict.").foregroundStyle(Theme.muted)
                        ForEach(Array(duel.groups.enumerated()), id: \.offset) { index, group in
                            let rank = 1 + duel.groups.prefix(index).reduce(0) { $0 + $1.count }
                            Text("\(rank) · " + group.compactMap { slot($0)?["label"].string }.joined(separator: " = "))
                                .font(Theme.mono(Theme.textSm))
                        }
                    }.frame(maxWidth: .infinity, alignment: .leading).padding(density.pageMargin)
                }.frame(maxHeight: .infinity)
            }
            Theme.rule.frame(height: 1)
            ViewThatFits(in: .horizontal) {
                HStack { secondaryChoices; Spacer(minLength: 12); duelChoices }
                VStack(alignment: .trailing, spacing: 8) { duelChoices; secondaryChoices }
            }.padding(.horizontal, density.pageMargin).padding(.vertical, 12).disabled(busy)
        }
        .background {
            if pageActive {
                NativeArenaDuelKeys(choose: choose).allowsHitTesting(false).accessibilityHidden(true)
            }
        }
    }

    private var secondaryChoices: some View {
        HStack {
            Button("Skip") { act("skip") }.buttonStyle(T3Button(.ghost))
            Button("All bad") { act("vote", ["allBad": true]) }.buttonStyle(T3Button(.outline))
            if draft != nil { Button("Reset") { draft = nil }.buttonStyle(T3Button(.ghost)) }
        }
    }

    @ViewBuilder private var duelChoices: some View {
        if duel.pair != nil {
            HStack {
                Button("Left better", nativeIcon: "arrow-left") { choose(.left) }.buttonStyle(T3Button(.primary)).help("Left arrow")
                Button("Tie", nativeIcon: "arrow-down") { choose(.tie) }.buttonStyle(T3Button(.outline)).help("Down arrow")
                Button("Right better", nativeIcon: "arrow-right") { choose(.right) }.buttonStyle(T3Button(.primary)).help("Right arrow")
            }
        } else {
            Button("Submit & reveal", nativeIcon: "trophy") {
                let groups = duel.groups.map { JSONValue.array($0.map { .number(Double($0)) }) }
                act("vote", ["rankGroups": .array(groups)])
            }.buttonStyle(T3Button(.primary)).disabled(done.count < 2)
        }
    }

    private var resultBody: some View {
        VStack(alignment: .leading, spacing: 0) {
            if revealed { reveal.nativeEntrance(.page).animation(motion, value: outcome) }
            HStack {
                NativeTabs(options: (revealed ? ["Answers", "Performance"] : ["Answers"]).map { ($0, $0) }, selection: tab, height: 34) { tab = $0 }
                Spacer()
            }.padding(.horizontal, density.pageMargin)
            Theme.rule.frame(height: 1)
            if tab == "Performance" && revealed {
                NativeArenaPerformance(slots: slots, compared: slots)
            } else {
                HStack(alignment: .top, spacing: 0) {
                    resultSide(0, content: $leftContent)
                    if slots.count > 1 {
                        Theme.rule.frame(width: 1)
                        resultSide(1, content: $rightContent)
                    }
                }
            }
            Theme.rule.frame(height: 1)
            HStack {
                Spacer()
                Button("Next match", nativeIcon: "arrow-right", action: next).buttonStyle(T3Button(.primary))
            }.padding(.horizontal, density.pageMargin).padding(.vertical, 12).disabled(busy)
        }
    }

    private var reveal: some View {
        let contestants = outcome["verdict"]["contestants"].array
        let rank = Dictionary(contestants.filter { !$0["rank"].isNull }.map {
            (ArenaContestantPolicy.key($0), $0["rank"].int)
        }, uniquingKeysWith: { a, _ in a })
        let ordered = slots.sorted {
            let a = rank[ArenaContestantPolicy.key($0)] ?? Int.max, b = rank[ArenaContestantPolicy.key($1)] ?? Int.max
            return a == b ? $0["idx"].int < $1["idx"].int : a < b
        }
        let names = ArenaPresentationPolicy.compactModelNames(slots.map { $0["model"].string }, trimSharedSuffix: true)
        return VStack(alignment: .leading, spacing: 8) {
            Text(match["verdict"].isNull ? "Contestants revealed" : match["verdict"].string.replacingOccurrences(of: "_", with: " ").capitalized)
                .font(Theme.ui(18, weight: .semibold)).accessibilityAddTraits(.isHeader)
            ScrollView(.horizontal) {
                HStack(spacing: 8) {
                    ForEach(ordered, id: \.self["id"]) { slot in
                        let key = ArenaContestantPolicy.key(slot), delta = outcome["deltas"][key]
                        let name = slot["model"].string
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Text(rank[key].map { "Rank \($0) · \(slot["label"].string.suffix(1))" } ?? slot["label"].string)
                                    .font(Theme.ui(Theme.textXs, weight: .semibold))
                                Spacer()
                                if !delta.isNull {
                                    NativeNumberText(text: "\(delta.int > 0 ? "+" : "")\(delta.int) Elo", font: Theme.num(Theme.textXs, weight: .medium), color: delta.int >= 0 ? Theme.okFg : Theme.failFg)
                                }
                            }
                            Text(names[name] ?? name).font(Theme.mono(Theme.textSm))
                                .lineLimit(2, reservesSpace: true).truncationMode(names[name] == nil ? .middle : .tail)
                                .accessibilityLabel(name)
                            Text(slot["route"].string).foregroundStyle(Theme.muted).lineLimit(1)
                        }.padding(10).frame(width: 218, alignment: .leading)
                            .background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.radiusMd))
                            .help("\(slot["label"].string) · \(slot["model"].string) · \(slot["route"].string)")
                            .accessibilityElement(children: .combine)
                    }
                }
            }
        }.padding(.horizontal, density.pageMargin).padding(.vertical, 8)
    }

    private func slot(_ index: Int) -> JSONValue? { slots.first { $0["idx"].int == index } }

    private func resultSide(_ side: Int, content: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            if slots.count > 2 {
                Picker(side == 0 ? "Left contestant" : "Right contestant", selection: Binding(get: { compared[side] }, set: { index in
                    if compared[1 - side] == index { compared.swapAt(0, 1) }
                    else { compared[side] = index }
                })) {
                    ForEach(slots.indices, id: \.self) { index in Text(slots[index]["label"].string).tag(index) }
                }.padding(.horizontal, 12).padding(.vertical, 6)
            }
            if slots.indices.contains(compared[side]) {
                answer(slots[compared[side]], selection: content).id(slots[compared[side]]["id"])
            }
        }.frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func answer(_ slot: JSONValue, selection: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            NativeTabs(options: ["Result", "Transcript", "Files"].map { ($0, $0) }, selection: selection.wrappedValue, height: 33) { selection.wrappedValue = $0 }
                .padding(.horizontal, 12).accessibilityLabel("\(slot["label"].string) content")
            Theme.rule.frame(height: 1)
            NativeArenaSlot(runtime: runtime, model: model, slot: slot, tab: selection.wrappedValue,
                            compactName: compactNames[slot["model"].string], judging: judging)
        }.frame(minWidth: 0, maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    @discardableResult private func choose(_ choice: ArenaDuel.Choice) -> Bool {
        guard !busy, duel.pair != nil else { return false }
        var updated = duel
        updated.choose(choice)
        withAnimation(motion) { draft = updated; leftContent = "Result"; rightContent = "Result" }
        return true
    }

    private func act(_ op: String, _ input: JSONObject = [:], then after: (() -> Void)? = nil) {
        guard !busy else { return }
        busy = true
        Task { defer { busy = false }; _ = await model.performMatchAction(op, id: match["id"], input: input, after: after) }
    }
}

private struct NativeArenaDuelKeys: NSViewRepresentable {
    let choose: (ArenaDuel.Choice) -> Bool

    func makeNSView(context: Context) -> MonitorView { MonitorView() }
    func updateNSView(_ view: MonitorView, context: Context) { view.choose = choose }
    static func dismantleNSView(_ view: MonitorView, coordinator: ()) { view.stop() }

    final class MonitorView: NSView {
        var choose: ((ArenaDuel.Choice) -> Bool)?
        private var monitor: Any?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            stop()
            guard window != nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                guard let self, let window = self.window, event.window === window, window.isKeyWindow,
                      window.attachedSheet == nil, !event.isARepeat,
                      event.modifierFlags.intersection([.command, .option, .shift, .control]).isEmpty,
                      (window.firstResponder as? NSTextView)?.isEditable != true else { return event }
                let choice: ArenaDuel.Choice
                switch event.specialKey {
                case .leftArrow: choice = .left
                case .downArrow: choice = .tie
                case .rightArrow: choice = .right
                default: return event
                }
                return self.choose?(choice) == true ? nil : event
            }
        }

        func stop() {
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
        }
    }
}

private struct NativeArenaPerformance: View {
    let slots: [JSONValue], compared: [JSONValue]
    @Environment(\.nativeInterfaceDensity) private var density

    private func metric(_ slot: JSONValue, key: String) -> Double? {
        let value = slot[key].double
        return value > 0 && value.isFinite ? value : nil
    }

    var body: some View {
        ScrollView {
            Text("Match performance").font(Theme.ui(18, weight: .semibold)).accessibilityAddTraits(.isHeader)
                .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, density.pageMargin).padding(.vertical, 16)
            measure("Elapsed time", key: "duration_ms", format: NativeArenaDuration)
            measure("Output tokens", key: "output_tokens", format: NativeNumberFormat.compact)
            measure("Reported cost", key: "cost_usd") { "$" + String(format: $0 < 0.01 ? "%.4f" : "%.2f", $0) }
        }.frame(maxHeight: .infinity)
    }

    private func measure(_ title: String, key: String, format: @escaping (Double) -> String) -> some View {
        let maximum = slots.compactMap { metric($0, key: key) }.max() ?? 1
        return VStack(alignment: .leading, spacing: 8) {
            Text(title).font(Theme.ui(Theme.textSm, weight: .semibold)).accessibilityAddTraits(.isHeader)
            ForEach(compared, id: \.self["id"]) { slot in
                let value = metric(slot, key: key)
                HStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(slot["label"].string).font(Theme.ui(Theme.textXs, weight: .semibold))
                        Text(slot["model"].string).font(Theme.mono(Theme.textXs))
                        Text(slot["route"].string).font(Theme.ui(Theme.textXs)).foregroundStyle(Theme.muted)
                    }.lineLimit(1).truncationMode(.middle).frame(width: 135, alignment: .leading)
                        .help("\(slot["label"].string) · \(slot["model"].string) · \(slot["route"].string)")
                    if let value { NativeGrowBar(fraction: value / maximum, color: Theme.pairColor(ArenaContestantPolicy.key(slot))) }
                    else { Theme.rule.frame(height: 1).frame(maxWidth: .infinity).accessibilityHidden(true) }
                    NativeNumberText(text: value.map(format) ?? "Not recorded", font: Theme.num(Theme.textXs, weight: .medium))
                        .frame(width: 88, alignment: .trailing)
                }.accessibilityElement(children: .combine)
            }
        }.padding(.horizontal, density.pageMargin).padding(.vertical, 12)
            .overlay(alignment: .top) { Theme.rule.frame(height: 1) }
    }
}

private struct NativeArenaSlot: View {
    let runtime: NativeRuntime
    @ObservedObject var model: NativeArenaModel
    let slot: JSONValue
    let tab: String
    let compactName: String?
    let judging: Bool
    @State private var presentation = 0
    @State private var files: [JSONValue] = []
    @State private var preview: NativeArenaPreviewItem?
    @State private var follows = true
    @State private var jump = 0
    @State private var reads = NativePageReadScope()
    @State private var contentOwner: NativeArenaModel.ContentOwner?
    @Environment(\.nativePageActive) private var pageActive
    private var id: String { slot["id"].string }
    var body: some View { VStack(alignment: .leading, spacing: 0) {
        HStack(spacing: 10) {
            StatusDot(color: slot["status"].string == "failed" ? Theme.fail : slot["status"].string == "done" ? Theme.ok : Theme.accent, pulse: slot["status"].string == "running")
            if slot["revealed"].bool {
                Text(slot["label"].string.suffix(1)).font(Theme.mono(Theme.textXs, weight: .medium)).foregroundStyle(Theme.muted)
                Text(compactName ?? slot["model"].string).font(Theme.mono(Theme.textSm, weight: .medium)).lineLimit(1)
                    .truncationMode(compactName == nil ? .middle : .tail).accessibilityLabel(slot["model"].string)
                    .help("\(slot["label"].string) · \(slot["model"].string) · \(slot["route"].string)")
                Text(slot["route"].string).font(Theme.ui(Theme.textXs)).foregroundStyle(Theme.muted).lineLimit(1)
            } else { Text(slot["label"].string).font(Theme.ui(Theme.textSm, weight: .semibold)).lineLimit(1) }
            Spacer(minLength: 4)
            if slot["status"].string != "done" {
                Text(slot["status"].string).font(Theme.ui(Theme.textXs)).foregroundStyle(slot["status"].string == "failed" ? Theme.failFg : Theme.muted)
            }
        }.padding(.horizontal, 16).frame(height: 44)
            .overlay(alignment: .bottom) { Theme.rule.frame(height: 1) }
        if !model.contentError(id, tab: tab).isEmpty { NativeError(message: model.contentError(id, tab: tab)).padding(12) }
        if slot["status"].string == "running" {
            HStack(spacing: 8) {
                ShimmerText(text: model.live[id]?["tool"].string ?? "working")
                Text(model.live[id]?["text"].string ?? "").lineLimit(1).font(Theme.ui(11)).foregroundStyle(Theme.muted).frame(maxWidth: .infinity, alignment: .leading)
                if pageActive { TimelineView(.periodic(from: .now, by: 1)) { timeline in duration(at: timeline.date) } }
                else { duration(at: Date()) }
            }.padding(.horizontal, 16).frame(height: 32).background(Theme.sunken)
        }
        if tab == "Transcript" { NativeCodeScroll(jump: jump, follows: $follows, scrollsWithDownArrow: !judging) { VStack(alignment: .leading, spacing: 10) {
            if model.transcripts[id]?.isEmpty == true, slot["status"].string != "running", model.contentError(id, tab: tab).isEmpty {
                Text("No transcript was recorded").font(Theme.ui(12)).foregroundStyle(Theme.muted)
            }
            NativeCodeTranscript(events: model.transcripts[id] ?? [], running: slot["status"].string == "running")
            NativeCodeLiveView(live: CodeLiveState(json: model.live[id] ?? .null), events: model.transcripts[id] ?? [])
        } }.frame(maxHeight: .infinity).overlay(alignment: .bottomTrailing) { if !follows { Button("Jump to latest", nativeIcon: "arrow-down") { jump += 1 }.buttonStyle(T3Button(.outline)).padding(8) } } }
        else { ScrollView { VStack(alignment: .leading, spacing: 10) {
            switch tab {
            case "Files":
                if files.isEmpty && model.contentError(id, tab: tab).isEmpty { Text("No public workspace files").font(Theme.ui(12)).foregroundStyle(Theme.muted) }
                ForEach(files, id: \.self) { file in Button { open(file["path"].string) } label: { HStack { Text(file["path"].string).font(Theme.mono(Theme.textXs)).lineLimit(1).truncationMode(.middle); Spacer(); Text(ByteCountFormatter.string(fromByteCount: Int64(file["size"].double), countStyle: .file)).font(Theme.num(11, weight: .regular)).foregroundStyle(Theme.muted) }.contentShape(Rectangle()) }.buttonStyle(.plain).pointingHand() }
            default: result
            }
        }.padding(.horizontal, 16).padding(.vertical, 14).frame(maxWidth: .infinity, alignment: .leading) }.frame(maxHeight: .infinity) }
        Theme.rule.frame(height: 1)
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 14) {
                Text(NativeArenaDuration(slot["duration_ms"].double))
                Text("\(slot["turns"].int) steps")
                Text("\(slot["tool_calls"].int) tools")
                Text("\(NativeNumberFormat.compact(Double(slot["output_tokens"].int))) out")
                if slot["blocked"].int > 0 { Text("\(slot["blocked"].int) refused").foregroundStyle(Theme.warnFg) }
            }.font(Theme.num(11, weight: .regular)).foregroundStyle(Theme.muted).lineLimit(1)
            if !slot["error"].isNull { Text(slot["error"].string).font(Theme.ui(11)).foregroundStyle(slot["status"].string == "done" ? Theme.warnFg : Theme.failFg).textSelection(.enabled) }
        }.padding(.horizontal, 16).padding(.vertical, 8)
    }
    .nativePageTask(id: "\(id):\(tab):\(slot["status"].string):\(model.readActive):\(model.readGeneration)") {
        guard model.readActive, let ticket = reads.begin("content") else { return }
        let owner = model.beginContent(id, tab: tab); contentOwner = owner
        guard let owner else { return }
        if tab == "Transcript" { await model.transcript(id, content: owner) }
        if tab == "Files", reads.accepts(ticket), let value = await model.call("files", ["id": slot["id"]], content: owner) {
            guard reads.accepts(ticket) else { return }
            files = value["files"].array
        }
    }
    .nativePageActivity(reads: reads, suspended: { if let contentOwner { model.endContent(contentOwner) }; contentOwner = nil })
    .sheet(item: $preview) { item in NativeArenaArtifactPreview(runtime: runtime, slotID: id, path: item.path) }
    }
    private func duration(at now: Date) -> some View { Text(NativeArenaDuration(now.timeIntervalSince1970 * 1000 - slot["started_at"].double)).font(Theme.mono(10.5)) }
    @ViewBuilder private var result: some View {
        let presents = slot["presents"].array
        if !presents.isEmpty {
            if presents.count > 1 {
                ScrollView(.horizontal) { T3Segmented(options: Array(presents.enumerated()).map { (value: $0.offset, label: $0.element["title"].string) }, selection: presentation) { presentation = $0 } }.accessibilityLabel("Presentation")
            }
            let p = presents[min(presentation, presents.count - 1)]
            Text(p["title"].string).font(Theme.ui(13, weight: .semibold)); if !p["note"].isNull { Text(p["note"].string).font(Theme.ui(12)).foregroundStyle(Theme.muted) }
            if p["kind"].string == "text" { NativeCodeMarkdown(text: p["text"].string) }
            else if p["kind"].string == "url", let url = URL(string: p["url"].string), ["http", "https"].contains(url.scheme ?? "") { NativeArenaURLPreview(url: p["url"].string).id(p["url"].string).frame(height: 420); Link(destination: url) { Label { Text("Open in browser") } icon: { NativeIcon("external-link", size: 13) } }.font(Theme.ui(12)) }
            else { NativeArenaFileView(runtime: runtime, slotID: id, path: p["path"].string).frame(minHeight: 280); Button("Expand preview", nativeIcon: "external-link") { open(p["path"].string) }.buttonStyle(T3Button(.outline)) }
            if !slot["final_text"].string.isEmpty { NativeDisclosure("Final message") { NativeCodeMarkdown(text: slot["final_text"].string) } }
        } else { NativeCodeMarkdown(text: slot["final_text"].string.isEmpty ? ["queued", "running"].contains(slot["status"].string) ? "Nothing presented yet" : "Nothing was presented" : slot["final_text"].string) }
    }
    private func open(_ path: String) { preview = NativeArenaPreviewItem(path: path) }
}
private struct NativeArenaPreviewItem: Identifiable { let path: String; var id: String { path } }
