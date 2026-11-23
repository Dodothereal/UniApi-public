import SwiftUI
import UniApiCore
import UniApiPresentation

struct NativeArenaMatch: View {
    let runtime: NativeRuntime
    @ObservedObject var model: NativeArenaModel
    let match: JSONValue
    let next: () -> Void
    @State private var picks: [Int] = []
    @State private var busy = false
    @State private var showPrompt = false
    @State private var content = "Result"
    private var done: [JSONValue] { match["slots"].array.filter { $0["status"].string == "done" } }
    private var judging: Bool { match["status"].string == "done" && match["voted_at"].isNull }
    private var running: Bool { ["queued", "running"].contains(match["status"].string) }
    @Environment(\.nativeInterfaceDensity) private var density
    private var order: String { picks.map { String(UnicodeScalar(65 + max(0, min(7, $0)))!) }.joined(separator: " > ") }
    var body: some View { VStack(alignment: .leading, spacing: 0) {
        HStack(alignment: .top, spacing: 8) {
            Button { showPrompt.toggle() } label: {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    NativeIcon("chevron-right", size: 12).foregroundStyle(Theme.faint).rotationEffect(.degrees(showPrompt ? 90 : 0))
                    Text(match["prompt"].string).font(Theme.ui(Theme.textSm)).foregroundStyle(Theme.ink).lineSpacing(3).lineLimit(showPrompt ? 12 : 1)
                        .multilineTextAlignment(.leading).frame(maxWidth: .infinity, alignment: .leading)
                }.contentShape(Rectangle())
            }.buttonStyle(.plain).pointingHand().accessibilityLabel("Match prompt").accessibilityValue(showPrompt ? "Expanded" : "Collapsed")
                .help(showPrompt ? "Collapse the task" : "Show the whole task")
        }.padding(.horizontal, density.pageMargin).padding(.top, 14).padding(.bottom, 6)
        // One switch for every contestant: the same part of each answer, side by side.
        HStack(spacing: 8) {
            NativeTabs(options: [("Result", "Result"), ("Transcript", "Transcript"), ("Files", "Files")], selection: content, height: 34) { content = $0 }
                .accessibilityLabel("Contestant content")
            Spacer(minLength: 8)
            Text("\(done.count)/\(match["slots"].array.count) finished").font(Theme.num(Theme.textXs, weight: .regular)).foregroundStyle(Theme.muted).lineLimit(1)
            if running { Button("Stop", nativeIcon: "square") { act("cancel") }.buttonStyle(T3Button(.outline)) }
            NativeIconMenu(help: "Match actions") {
                if !running { Button("Run again") { act("rerun") } }
                Button("Delete match", role: .destructive) { if NativeArenaConfirm("Delete this match and all its workspaces?", detail: "Any immutable verdict already in the results ledger remains there.") { act("delete", then: next) } }
            }
        }.padding(.horizontal, density.pageMargin).disabled(busy)
            .overlay(alignment: .bottom) { Theme.rule.frame(height: 1) }
        if !match["error"].isNull { NativeError(message: match["error"].string).padding(.horizontal, density.pageMargin).padding(.vertical, 8) }
        GeometryReader { geometry in
            let slots = match["slots"].array
            // Equal columns while each keeps a readable measure; otherwise they scroll sideways
            // with the next contestant showing at the edge.
            if CGFloat(slots.count) * 320 <= geometry.size.width {
                HStack(alignment: .top, spacing: 0) { columns(slots, width: nil) }
            } else {
                ScrollView(.horizontal) { HStack(alignment: .top, spacing: 0) { columns(slots, width: min(420, max(280, geometry.size.width / 2.25))) }.frame(height: geometry.size.height) }
            }
        }
        Theme.border.frame(height: 1)
        // The verdict stays in reach however far the contestants scroll.
        HStack(spacing: 10) {
            if judging {
                Text(picks.isEmpty ? "Pick the best, then rank the rest" : order).font(picks.isEmpty ? Theme.ui(Theme.textXs) : Theme.mono(Theme.textSm, weight: .medium))
                    .foregroundStyle(picks.isEmpty ? Theme.muted : Theme.ink).lineLimit(1)
                if !picks.isEmpty { Button("Reset") { picks = [] }.buttonStyle(T3Button(.ghost)) }
            } else if !match["verdict"].isNull {
                NativeStatus(text: match["verdict"].string.replacingOccurrences(of: "_", with: " "), tone: .ok)
            }
            Spacer(minLength: 8)
            if !running && match["voted_at"].isNull { Button("Skip") { act("skip") }.buttonStyle(T3Button(.ghost)) }
            if judging {
                Button("All bad") { act("vote", ["allBad": true]) }.buttonStyle(T3Button(.outline))
                Button("Submit ranking", nativeIcon: "trophy") { act("vote", ["ranking": .array(picks.map { .number(Double($0)) })]) }
                    .buttonStyle(T3Button(.primary)).disabled(picks.count != done.count || done.count < 2)
            }
            Button("Next", nativeIcon: "arrow-right") { next() }.buttonStyle(T3Button(judging ? .outline : .primary))
        }.padding(.horizontal, density.pageMargin).frame(height: 52).background(Theme.bg).disabled(busy)
    } }
    @ViewBuilder private func columns(_ slots: [JSONValue], width: CGFloat?) -> some View {
        ForEach(Array(slots.enumerated()), id: \.element) { index, slot in
            let idx = slot["idx"].int
            NativeArenaSlot(runtime: runtime, model: model, slot: slot, tab: content, rank: rank(slot), judging: judging,
                            pickable: judging && slot["status"].string == "done" && !picks.contains(idx), nextRank: picks.count + 1,
                            pick: { pick(idx) }, unpick: { if let at = picks.firstIndex(of: idx) { picks = Array(picks.prefix(at)) } })
                .frame(width: width).frame(maxWidth: width == nil ? .infinity : nil, maxHeight: .infinity, alignment: .top)
                .overlay(alignment: .leading) { if index > 0 { Theme.rule.frame(width: 1) } }
        }
    }
    private func rank(_ slot: JSONValue) -> Int? { let order = match["ranking"].isNull ? picks : match["ranking"].array.map(\.int); return order.firstIndex(of: slot["idx"].int).map { $0 + 1 } }
    private func pick(_ index: Int) { picks.append(index); let remaining = done.map { $0["idx"].int }.filter { !picks.contains($0) }; if remaining.count == 1 { picks += remaining } }
    private func act(_ op: String, _ input: JSONObject = [:], then after: (() -> Void)? = nil) { Task { busy = true; defer { busy = false }; _ = await model.performMatchAction(op, id: match["id"], input: input, after: after) } }
}

private struct NativeArenaSlot: View {
    let runtime: NativeRuntime
    @ObservedObject var model: NativeArenaModel
    let slot: JSONValue
    let tab: String
    let rank: Int?
    let judging: Bool
    let pickable: Bool
    let nextRank: Int
    let pick: () -> Void
    let unpick: () -> Void
    @State private var presentation = 0
    @State private var files: [JSONValue] = []
    @State private var preview: NativeArenaPreviewItem?
    @State private var follows = true
    @State private var jump = 0
    @State private var reads = NativePageReadScope()
    @State private var contentOwner: NativeArenaModel.ContentOwner?
    @Environment(\.nativePageActive) private var pageActive
    private var id: String { slot["id"].string }
    private func ordinal(_ rank: Int) -> String { rank == 1 ? "Best" : rank == 2 ? "2nd" : rank == 3 ? "3rd" : "\(rank)th" }
    var body: some View { VStack(alignment: .leading, spacing: 0) {
        HStack(spacing: 10) {
            if rank == nil {
                StatusDot(color: slot["status"].string == "failed" ? Theme.fail : slot["status"].string == "done" ? Theme.ok : Theme.accent, pulse: slot["status"].string == "running")
            }
            if slot["revealed"].bool {
                Text(slot["model"].string).font(Theme.mono(Theme.textSm, weight: .medium)).lineLimit(1).truncationMode(.middle)
                Text(slot["route"].string).font(Theme.ui(Theme.textXs)).foregroundStyle(Theme.muted).lineLimit(1)
            } else { Text(slot["label"].string).font(Theme.ui(Theme.textSm, weight: .semibold)).lineLimit(1) }
            Spacer(minLength: 4)
            if let rank {
                // A placed rank is a button while judging: it takes this and every later pick back.
                Button(action: unpick) {
                    HStack(spacing: 5) {
                        Text(ordinal(rank)).font(Theme.num(Theme.textXs, weight: .semibold))
                        if judging { NativeIcon("x", size: 10) }
                    }
                    .foregroundStyle(rank == 1 ? Theme.bg : Theme.ink).padding(.horizontal, 8).frame(height: 24)
                    .background(rank == 1 ? Theme.ink : Theme.subtle2, in: RoundedRectangle(cornerRadius: Theme.radiusSm, style: .continuous))
                }.buttonStyle(.plain).disabled(!judging).pointingHand(judging)
                    .help(judging ? "Take this rank back" : "Ranked \(ordinal(rank).lowercased())").accessibilityLabel("Rank \(rank)")
            } else if pickable {
                Button(ordinal(nextRank), action: pick).buttonStyle(T3Button(nextRank == 1 ? .primary : .outline))
                    .help(nextRank == 1 ? "Mark as the best answer" : "Place \(ordinal(nextRank).lowercased())")
            } else if slot["status"].string != "done" {
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
        if tab == "Transcript" { NativeCodeScroll(jump: jump, follows: $follows) { VStack(alignment: .leading, spacing: 10) {
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
