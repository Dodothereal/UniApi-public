import SwiftUI
import UniApiCore
import UniApiPresentation

struct NativeArenaMatch: View {
    let runtime: NativeRuntime
    @ObservedObject var model: NativeArenaModel
    let match: JSONValue
    var stage: CGFloat = 520
    let next: () -> Void
    @State private var picks: [Int] = []
    @State private var busy = false
    @State private var showPrompt = false
    @State private var tab = "Result"
    @Environment(\.nativeReducedMotion) private var reduceMotion
    private var done: [JSONValue] { match["slots"].array.filter { $0["status"].string == "done" } }
    private var judging: Bool { match["status"].string == "done" && match["voted_at"].isNull }
    private var running: Bool { ["queued", "running"].contains(match["status"].string) }
    var body: some View { VStack(alignment: .leading, spacing: 18) {
        task
        if !match["error"].isNull { BenchFailure(message: match["error"].string) }
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .center, spacing: 16) { verdictState; Spacer(minLength: 12); verdictControls }
            VStack(alignment: .leading, spacing: 12) { verdictState; verdictControls }
        }.frame(minHeight: 36).disabled(busy)
        Band(title: "Contestants", spacing: 14) {
            Text("\(done.count) of \(match["slots"].array.count) finished").font(Theme.mono(10.5)).foregroundStyle(Theme.muted).fixedSize()
            Stops(options: [("Result", "Result"), ("Transcript", "Transcript"), ("Files", "Files")], selection: tab) { tab = $0 }
                .accessibilityLabel("Contestant content")
        } content: {
            ColumnFlow(minimum: 280, spacing: 24, rowSpacing: 28, maxColumns: 4) {
                ForEach(match["slots"].array, id: \.self) { slot in
                    NativeArenaSlot(runtime: runtime, model: model, slot: slot, rank: rank(slot),
                                    pickable: judging && done.count > 1 && slot["status"].string == "done" && !picks.contains(slot["idx"].int),
                                    nextRank: picks.count + 1, tab: tab, stage: stage, timeout: match["timeout_s"].double) { pick(slot["idx"].int) }
                        .disabled(busy)
                }
            }
        }
    } }

    // ---- the task ----------------------------------------------------------
    private var task: some View {
        HStack(alignment: .top, spacing: 12) {
            Button {
                if reduceMotion { showPrompt.toggle() } else { withAnimation(NativeMotion.toggle) { showPrompt.toggle() } }
            } label: {
                HStack(alignment: .top, spacing: 8) {
                    NativeIcon(showPrompt ? "chevron-down" : "chevron-right", size: 13, strokeWidth: 1.75).foregroundStyle(Theme.muted)
                        .frame(height: 18)
                    Text(match["prompt"].string).font(Theme.ui(13)).foregroundStyle(Theme.ink).lineSpacing(4)
                        .lineLimit(showPrompt ? nil : 2).multilineTextAlignment(.leading).textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }.contentShape(Rectangle())
            }.buttonStyle(.plain).pointingHand().accessibilityLabel("Match prompt").accessibilityValue(showPrompt ? "Expanded" : "Collapsed")
            Tag(match["mode"].string).fixedSize(horizontal: true, vertical: false).padding(.top, 5)
            HStack(spacing: 2) {
                if running { Button("Stop", nativeIcon: "square") { act("cancel") } }
                else { IconPress(icon: "rotate-cw", help: "Run again") { act("rerun") } }
                IconPress(icon: "trash-2", help: "Delete match") {
                    if NativeArenaConfirm("Delete this match and all its workspaces?", detail: "Any immutable verdict already in the results ledger remains there.") { act("delete", then: next) }
                }
            }
        }.disabled(busy)
    }

    // ---- the verdict -------------------------------------------------------
    private func letter(_ index: Int) -> String { String(UnicodeScalar(65 + max(0, min(7, index)))!) }
    @ViewBuilder private var verdictState: some View {
        if judging {
            if done.count < 2 {
                ArenaVerdictWord(text: done.isEmpty ? "Nobody finished" : "One finished", detail: "Nothing to rank. Call it all bad, or skip it.")
            } else {
                HStack(alignment: .center, spacing: 14) {
                    ArenaOrder(letters: picks.map(letter), slots: done.count)
                        .accessibilityLabel(picks.isEmpty ? "Pick Best, then rank the rest." : picks.map(letter).joined(separator: " > "))
                    if picks.isEmpty {
                        Text("Pick the best, then rank the rest.").font(Theme.ui(12.5)).foregroundStyle(Theme.muted).lineLimit(1)
                    }
                }
            }
        } else if !match["verdict"].isNull {
            HStack(alignment: .center, spacing: 14) {
                ArenaVerdictWord(text: match["verdict"].string.replacingOccurrences(of: "_", with: " ").capitalizedFirst)
                if !match["ranking"].isNull { ArenaOrder(letters: match["ranking"].array.map { letter($0.int) }, slots: match["ranking"].array.count) }
            }
        } else if running {
            HStack(spacing: 10) {
                NativeStatusDot(color: Theme.signal, size: 7, pulse: match["status"].string == "running")
                ArenaVerdictWord(text: match["status"].string == "running" ? "Running" : "Queued", detail: "The verdict opens when every contestant has stopped.")
            }
        } else {
            ArenaVerdictWord(text: match["status"].string.capitalizedFirst, detail: "No verdict was given.")
        }
    }
    private var verdictControls: some View {
        HStack(spacing: 8) {
            if judging {
                Button("Reset", nativeIcon: "undo-2") { picks = [] }.buttonStyle(Press(.quiet)).disabled(picks.isEmpty)
                Button("Skip") { act("skip") }.buttonStyle(Press(.quiet))
                Button("All bad") { act("vote", ["allBad": true]) }
                Button("Submit ranking", nativeIcon: "trophy") { act("vote", ["ranking": .array(picks.map { .number(Double($0)) })]) }
                    .buttonStyle(ArenaVerdictPress()).disabled(picks.count != done.count || done.count < 2)
            } else {
                if !running && match["voted_at"].isNull { Button("Skip") { act("skip") }.buttonStyle(Press(.quiet)) }
                Button { next() } label: {
                    HStack(spacing: 6) { Text("Next"); NativeIcon("arrow-right", size: 13, strokeWidth: 1.75) }
                }.buttonStyle(ArenaVerdictPress())
            }
        }.fixedSize(horizontal: true, vertical: false)
    }
    private func rank(_ slot: JSONValue) -> Int? { let order = match["ranking"].isNull ? picks : match["ranking"].array.map(\.int); return order.firstIndex(of: slot["idx"].int).map { $0 + 1 } }
    private func pick(_ index: Int) { picks.append(index); let remaining = done.map { $0["idx"].int }.filter { !picks.contains($0) }; if remaining.count == 1 { picks += remaining } }
    private func act(_ op: String, _ input: JSONObject = [:], then after: (() -> Void)? = nil) { Task { busy = true; defer { busy = false }; _ = await model.performMatchAction(op, id: match["id"], input: input, after: after) } }
}

private extension String {
    var capitalizedFirst: String { prefix(1).uppercased() + dropFirst() }
}

/// The verdict named as a state, with at most one line beside it.
private struct ArenaVerdictWord: View {
    var text: String
    var detail = ""
    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 14) {
            Text(text).font(Theme.display(24)).tracking(-0.4).foregroundStyle(Theme.ink).lineLimit(1).fixedSize()
            if !detail.isEmpty { Text(detail).font(Theme.ui(12.5)).foregroundStyle(Theme.muted).lineLimit(1) }
        }
    }
}

/// The ranking as it is being built: one place per finished contestant,
/// filled from the left as each is picked.
private struct ArenaOrder: View {
    var letters: [String]
    var slots: Int
    @Environment(\.nativeReducedMotion) private var reduceMotion
    var body: some View {
        HStack(spacing: 6) {
            ForEach(0..<max(slots, letters.count), id: \.self) { place in
                if place > 0 { NativeIcon("chevron-right", size: 12, strokeWidth: 2).foregroundStyle(Theme.faint) }
                let filled = place < letters.count
                Text(filled ? letters[place] : String(place + 1))
                    .font(filled ? Theme.display(24) : Theme.readout(24)).tracking(filled ? -0.4 : 0)
                    .foregroundStyle(filled ? Theme.ink : Theme.faint)
                    .frame(minWidth: 26, minHeight: 32)
                    .overlay(alignment: .bottom) { (place == letters.count ? Theme.signal : filled ? Theme.ink : Theme.ruleStrong).frame(height: 2) }
            }
        }
        .animation(reduceMotion ? nil : NativeMotion.toggle, value: letters)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(letters.joined(separator: " > "))
    }
}

/// The forward step of a verdict: ink outline, heavier than a secondary press
/// without spending the page's one filled primary.
struct ArenaVerdictPress: ButtonStyle {
    var height: CGFloat = 32
    func makeBody(configuration: Configuration) -> some View { ArenaVerdictPressBody(height: height, configuration: configuration) }
}
private struct ArenaVerdictPressBody: View {
    var height: CGFloat
    let configuration: ButtonStyleConfiguration
    @State private var hovering = false
    @Environment(\.isEnabled) private var enabled
    @Environment(\.nativeReducedMotion) private var reduceMotion
    var body: some View {
        configuration.label
            .font(Theme.ui(12.5, weight: .semibold)).foregroundStyle(hovering && enabled ? Theme.onInk : Theme.ink).lineLimit(1)
            .padding(.horizontal, 14).frame(height: height)
            .background(RoundedRectangle(cornerRadius: Theme.radiusControl, style: .continuous)
                .fill(hovering && enabled ? Theme.ink.opacity(configuration.isPressed ? 0.8 : 1) : configuration.isPressed ? Theme.pressed : .clear))
            .overlay(RoundedRectangle(cornerRadius: Theme.radiusControl, style: .continuous).strokeBorder(Theme.ink, lineWidth: 1.5))
            .contentShape(Rectangle())
            .opacity(enabled ? 1 : 0.35)
            .animation(reduceMotion ? nil : NativeMotion.hover, value: hovering)
            .onHover { hovering = $0 && enabled }
            .onChange(of: enabled) { _, enabled in if !enabled { hovering = false } }
            .pointingHand(enabled)
    }
}

private struct NativeArenaSlot: View {
    let runtime: NativeRuntime
    @ObservedObject var model: NativeArenaModel
    let slot: JSONValue
    let rank: Int?
    let pickable: Bool
    let nextRank: Int
    let tab: String
    let stage: CGFloat
    let timeout: Double
    let pick: () -> Void
    @State private var presentation = 0
    @State private var files: [JSONValue] = []
    @State private var preview: NativeArenaPreviewItem?
    @State private var follows = true
    @State private var jump = 0
    @State private var showFinal = false
    @State private var reads = NativePageReadScope()
    @State private var contentOwner: NativeArenaModel.ContentOwner?
    @Environment(\.nativePageActive) private var pageActive
    @Environment(\.openURL) private var openURL
    private var id: String { slot["id"].string }
    private var status: String { slot["status"].string }
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ZStack(alignment: .topLeading) {
                Rule()
                (pickable ? Theme.signal : Theme.ink).frame(width: 2, height: 7)
            }.frame(height: 7, alignment: .top).padding(.bottom, 8)
            head
            if status == "running" {
                Group {
                    if pageActive { TimelineView(.periodic(from: .now, by: 1)) { timeline in live(at: timeline.date) } }
                    else { live(at: Date()) }
                }.padding(.top, 8)
            }
            if !model.contentError(id, tab: tab).isEmpty { BenchFailure(message: model.contentError(id, tab: tab)).padding(.top, 10) }
            content
                .frame(maxWidth: .infinity).frame(height: stage)
                .background(Theme.well, in: RoundedRectangle(cornerRadius: Theme.radiusWell, style: .continuous))
                .clipShape(RoundedRectangle(cornerRadius: Theme.radiusWell, style: .continuous))
                .padding(.top, 12)
            foot.padding(.top, 12)
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

    // ---- who ---------------------------------------------------------------
    private var head: some View {
        HStack(alignment: .center, spacing: 12) {
            Text(String(slot["label"].string.suffix(1))).font(Theme.display(24)).tracking(-0.4).foregroundStyle(Theme.ink)
                .frame(minWidth: 20, alignment: .leading).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                if slot["revealed"].bool {
                    Text(slot["model"].string).font(Theme.mono(12, weight: .medium)).foregroundStyle(Theme.ink).lineLimit(1).truncationMode(.middle)
                    Text(slot["route"].string).font(Theme.ui(11.5)).foregroundStyle(Theme.muted).lineLimit(1)
                } else {
                    MicroLabel("Contestant")
                    Text("Identity hidden until the verdict").font(Theme.ui(11.5)).foregroundStyle(Theme.muted).lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(slot["revealed"].bool ? "\(slot["model"].string) · \(slot["route"].string)" : slot["label"].string)
            .accessibilityAddTraits(.isHeader)
            switch status {
            case "failed": Tag("failed", tone: Theme.failFg, dot: true)
            case "done", "running": EmptyView()
            default: Tag(status)
            }
            if let rank {
                HStack(alignment: .firstTextBaseline, spacing: 5) {
                    if rank == 1 { NativeIcon("trophy", size: 14, strokeWidth: 1.75).foregroundStyle(Theme.ink).alignmentGuide(.firstTextBaseline) { $0[.bottom] - 2 } }
                    MicroLabel("Rank")
                    Text(String(rank)).font(Theme.readout(24)).foregroundStyle(rank == 1 ? Theme.ink : Theme.muted)
                }
                .accessibilityElement(children: .ignore).accessibilityLabel("#\(rank)")
            }
            if pickable {
                Button(nextRank == 1 ? "Best" : "#\(nextRank)", action: pick).buttonStyle(ArenaVerdictPress())
                    .help(nextRank == 1 ? "Rank this contestant first" : "Rank this contestant number \(nextRank)")
            }
        }.frame(minHeight: 36)
    }
    private func live(at now: Date) -> some View {
        let elapsed = now.timeIntervalSince1970 * 1000 - slot["started_at"].double
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                NativeStatusDot(color: Theme.signal, size: 6, pulse: true)
                Text(model.live[id]?["tool"].string ?? "working").font(Theme.mono(11)).foregroundStyle(Theme.ink).lineLimit(1)
                Text(model.live[id]?["text"].string ?? "").lineLimit(1).font(Theme.ui(11.5)).foregroundStyle(Theme.muted).frame(maxWidth: .infinity, alignment: .leading)
                Text(NativeArenaDuration(elapsed)).font(Theme.mono(10.5)).foregroundStyle(Theme.dim)
            }
            if timeout > 0 { Scale(fraction: elapsed / (timeout * 1000), color: Theme.ink, height: 3, ticks: true) }
        }
    }

    // ---- what it made ------------------------------------------------------
    @ViewBuilder private var content: some View {
        if tab == "Transcript" {
            NativeCodeScroll(jump: jump, follows: $follows) { VStack(alignment: .leading, spacing: 10) {
                NativeCodeTranscript(events: model.transcripts[id] ?? [], running: slot["status"].string == "running")
                NativeCodeLiveView(live: CodeLiveState(json: model.live[id] ?? .null), events: model.transcripts[id] ?? [])
            } }
            .overlay(alignment: .bottomTrailing) {
                if !follows { Button("Jump to latest", nativeIcon: "arrow-down") { jump += 1 }.background(Theme.well, in: RoundedRectangle(cornerRadius: Theme.radiusControl, style: .continuous)).padding(10) }
            }
        } else {
            ScrollView { VStack(alignment: .leading, spacing: 12) {
                switch tab {
                case "Files": fileList
                default: result
                }
            }.padding(16).frame(maxWidth: .infinity, alignment: .leading) }
        }
    }
    @ViewBuilder private var fileList: some View {
        if files.isEmpty && model.contentError(id, tab: tab).isEmpty {
            Text("No public workspace files").font(Theme.ui(12.5)).foregroundStyle(Theme.muted)
        }
        VStack(spacing: 0) {
            ForEach(files, id: \.self) { file in
                LedgerRow(minHeight: 30, action: { open(file["path"].string) }) {
                    HStack(spacing: 8) {
                        NativeIcon("file", size: 12, strokeWidth: 1.75).foregroundStyle(Theme.muted)
                        Text(file["path"].string).font(Theme.mono(11.5)).foregroundStyle(Theme.ink).lineLimit(1).truncationMode(.middle)
                        Spacer(minLength: 8)
                        Text(ByteCountFormatter.string(fromByteCount: Int64(file["size"].double), countStyle: .file)).font(Theme.mono(10.5)).foregroundStyle(Theme.muted)
                    }
                }
            }
        }
    }
    @ViewBuilder private var result: some View {
        let presents = slot["presents"].array
        // A preview fills the stage beneath its caption instead of scrolling inside a scroller.
        let viewport = max(190, stage - (presents.count > 1 ? 162 : 124))
        if !presents.isEmpty {
            if presents.count > 1 {
                ScrollView(.horizontal) { Stops(options: Array(presents.enumerated()).map { (value: $0.offset, label: $0.element["title"].string) }, selection: presentation) { presentation = $0 } }
                    .scrollIndicators(.hidden).accessibilityLabel("Presentation")
            }
            let p = presents[min(presentation, presents.count - 1)]
            let link = p["kind"].string == "url" ? URL(string: p["url"].string).flatMap { ["http", "https"].contains($0.scheme ?? "") ? $0 : nil } : nil
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(p["title"].string).font(Theme.ui(13, weight: .medium)).foregroundStyle(Theme.ink)
                    if !p["note"].isNull { Text(p["note"].string).font(Theme.ui(12.5)).foregroundStyle(Theme.muted).lineLimit(1).help(p["note"].string) }
                }
                Spacer(minLength: 0)
                if let link { IconPress(icon: "external-link", help: "Open in browser") { openURL(link) } }
                else if p["kind"].string != "text" { IconPress(icon: "maximize", help: "Expand preview") { open(p["path"].string) } }
            }
            if p["kind"].string == "text" { NativeCodeMarkdown(text: p["text"].string) }
            else if link != nil {
                NativeArenaURLPreview(url: p["url"].string).id(p["url"].string).frame(height: viewport)
                    .clipShape(RoundedRectangle(cornerRadius: Theme.radiusControl, style: .continuous))
            } else {
                NativeArenaFileView(runtime: runtime, slotID: id, path: p["path"].string).frame(height: viewport)
                    .clipShape(RoundedRectangle(cornerRadius: Theme.radiusControl, style: .continuous))
            }
            if !slot["final_text"].string.isEmpty {
                Button { showFinal.toggle() } label: {
                    HStack(spacing: 6) {
                        NativeIcon(showFinal ? "chevron-down" : "chevron-right", size: 13, strokeWidth: 1.75)
                        Text("Final message")
                    }
                }.buttonStyle(Press(.quiet)).padding(.leading, -8).accessibilityValue(showFinal ? "Expanded" : "Collapsed")
                if showFinal { NativeCodeMarkdown(text: slot["final_text"].string) }
            }
        } else { NativeCodeMarkdown(text: slot["final_text"].string.isEmpty ? ["queued", "running"].contains(slot["status"].string) ? "Nothing presented yet" : "Nothing was presented" : slot["final_text"].string) }
    }

    // ---- what it cost ------------------------------------------------------
    private func measure(_ value: String, _ unit: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 4) {
            Text(value).font(Theme.readout(17)).foregroundStyle(Theme.ink)
            MicroLabel(unit)
        }.fixedSize()
    }
    private func measures(spacing: CGFloat) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: spacing) {
            measure(NativeArenaDuration(slot["duration_ms"].double), "time")
            measure(String(slot["turns"].int), "steps")
            measure(String(slot["tool_calls"].int), "tools")
            measure(NativeNumberFormat.compact(slot["output_tokens"].double), "out")
        }
    }
    private var foot: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                ViewThatFits(in: .horizontal) {
                    measures(spacing: 16)
                    measures(spacing: 9)
                    Text("\(NativeArenaDuration(slot["duration_ms"].double)) · \(slot["turns"].int) steps · \(slot["tool_calls"].int) tools · \(NativeNumberFormat.compact(slot["output_tokens"].double)) out")
                        .font(Theme.mono(11)).foregroundStyle(Theme.muted).lineLimit(1)
                }
                Spacer(minLength: 0)
                if slot["blocked"].int > 0 { Tag("\(slot["blocked"].int) refused", tone: Theme.warnFg) }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("\(slot["status"].string) · \(NativeArenaDuration(slot["duration_ms"].double)) · \(slot["turns"].int) steps · \(slot["tool_calls"].int) tools · \(slot["output_tokens"].int) out" + (slot["blocked"].int > 0 ? " · \(slot["blocked"].int) refused" : ""))
            if !slot["error"].isNull {
                Text(slot["error"].string).font(Theme.ui(11.5)).foregroundStyle(slot["status"].string == "done" ? Theme.warnFg : Theme.failFg)
                    .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
            }
        }
    }
    private func open(_ path: String) { preview = NativeArenaPreviewItem(path: path) }
}
private struct NativeArenaPreviewItem: Identifiable { let path: String; var id: String { path } }
