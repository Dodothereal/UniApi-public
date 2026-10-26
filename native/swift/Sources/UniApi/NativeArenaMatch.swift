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
    private var done: [JSONValue] { match["slots"].array.filter { $0["status"].string == "done" } }
    private var judging: Bool { match["status"].string == "done" && match["voted_at"].isNull }
    private var running: Bool { ["queued", "running"].contains(match["status"].string) }
    var body: some View { VStack(alignment: .leading, spacing: 12) {
        HStack(alignment: .top, spacing: 8) {
            Button { showPrompt.toggle() } label: {
                HStack(alignment: .top, spacing: 8) {
                    NativeIcon(showPrompt ? "chevron-down" : "chevron-right", size: 14).foregroundStyle(Theme.muted)
                    Text(match["prompt"].string).font(Theme.ui(12.5)).foregroundStyle(Theme.dim).lineLimit(showPrompt ? nil : 1).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                    MonoChip(text: match["mode"].string).fixedSize(horizontal: true, vertical: false)
                }.padding(.horizontal, 14).padding(.vertical, 10).background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.radiusMd))
                    .overlay(RoundedRectangle(cornerRadius: Theme.radiusMd).strokeBorder(Theme.border, lineWidth: 1))
            }.buttonStyle(.plain).pointingHand().accessibilityLabel("Match prompt").accessibilityValue(showPrompt ? "Expanded" : "Collapsed")
            if running { Button("Stop", nativeIcon: "square") { act("cancel") }.buttonStyle(T3Button(.outline)) }
            else { Button { act("rerun") } label: { NativeIcon("rotate-cw", size: 13) }.buttonStyle(T3Button(.ghost)).help("Run again").accessibilityLabel("Run again") }
            Button { if NativeArenaConfirm("Delete this match and all its workspaces?", detail: "Any immutable verdict already in the results ledger remains there.") { act("delete", then: next) } } label: { NativeIcon("trash-2", size: 13) }
                .buttonStyle(T3Button(.ghost)).help("Delete match").accessibilityLabel("Delete match")
        }.disabled(busy)
        if !match["error"].isNull { NativeError(message: match["error"].string) }
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 280), spacing: 12, alignment: .top)], alignment: .leading, spacing: 12) {
            ForEach(match["slots"].array, id: \.self) { slot in NativeArenaSlot(runtime: runtime, model: model, slot: slot, rank: rank(slot), pickable: judging && slot["status"].string == "done" && !picks.contains(slot["idx"].int), nextRank: picks.count + 1) { pick(slot["idx"].int) } }
        }
        VStack(alignment: .leading, spacing: 10) {
            if judging {
                Text(picks.isEmpty ? "Pick Best, then rank the rest." : picks.map { String(UnicodeScalar(65 + max(0, min(7, $0)))!) }.joined(separator: " > ")).font(Theme.ui(12))
                HStack(spacing: 8) {
                    Button("Reset") { picks = [] }.buttonStyle(T3Button(.ghost)).disabled(picks.isEmpty)
                    Button("All bad") { act("vote", ["allBad": true]) }.buttonStyle(T3Button(.outline))
                    Button("Submit ranking", nativeIcon: "trophy") { act("vote", ["ranking": .array(picks.map { .number(Double($0)) })]) }
                        .buttonStyle(T3Button(.primary)).disabled(picks.count != done.count || done.count < 2)
                }.fixedSize(horizontal: true, vertical: false)
            }
            HStack {
                if !judging, !match["verdict"].isNull { Text(match["verdict"].string.replacingOccurrences(of: "_", with: " ")).font(Theme.ui(12)).foregroundStyle(Theme.okFg) }
                Text("\(done.count) of \(match["slots"].array.count) finished").font(Theme.mono(10.5)).foregroundStyle(Theme.muted)
                Spacer(minLength: 8)
                if !running && match["voted_at"].isNull { Button("Skip") { act("skip") }.buttonStyle(T3Button(.ghost)) }
                Button("Next") { next() }.buttonStyle(T3Button(.primary))
            }
        }.disabled(busy)
    } }
    private func rank(_ slot: JSONValue) -> Int? { let order = match["ranking"].isNull ? picks : match["ranking"].array.map(\.int); return order.firstIndex(of: slot["idx"].int).map { $0 + 1 } }
    private func pick(_ index: Int) { picks.append(index); let remaining = done.map { $0["idx"].int }.filter { !picks.contains($0) }; if remaining.count == 1 { picks += remaining } }
    private func act(_ op: String, _ input: JSONObject = [:], then after: (() -> Void)? = nil) { Task { busy = true; defer { busy = false }; _ = await model.performMatchAction(op, id: match["id"], input: input, after: after) } }
}

private struct NativeArenaSlot: View {
    let runtime: NativeRuntime
    @ObservedObject var model: NativeArenaModel
    let slot: JSONValue
    let rank: Int?
    let pickable: Bool
    let nextRank: Int
    let pick: () -> Void
    @State private var tab = "Result"
    @State private var presentation = 0
    @State private var files: [JSONValue] = []
    @State private var preview: NativeArenaPreviewItem?
    @State private var follows = true
    @State private var jump = 0
    @State private var reads = NativePageReadScope()
    @State private var contentOwner: NativeArenaModel.ContentOwner?
    @Environment(\.nativePageActive) private var pageActive
    private var id: String { slot["id"].string }
    var body: some View { Card(padding: 0) { VStack(alignment: .leading, spacing: 0) {
        HStack(spacing: 8) {
            StatusDot(color: slot["status"].string == "failed" ? Theme.fail : slot["status"].string == "done" ? Theme.ok : Theme.accent, pulse: slot["status"].string == "running")
            Text(slot["revealed"].bool ? "\(slot["model"].string) · \(slot["route"].string)" : slot["label"].string).font(Theme.ui(13, weight: .medium)).lineLimit(1).frame(maxWidth: .infinity, alignment: .leading)
            if let rank { MonoChip(text: "#\(rank)", color: rank == 1 ? Theme.okFg : Theme.muted) }
            if pickable { Button(nextRank == 1 ? "Best" : "#\(nextRank)", action: pick).buttonStyle(T3Button(.primary)) }
        }.padding(.horizontal, 14).frame(height: 44)
        HStack {
            T3Segmented(options: [("Result", "Result"), ("Transcript", "Transcript"), ("Files", "Files")], selection: tab) { tab = $0 }.accessibilityLabel("Contestant content")
            Spacer(minLength: 0)
        }.padding(.horizontal, 14).padding(.bottom, 10)
        Rectangle().fill(Theme.border).frame(height: 1)
        if !model.contentError(id, tab: tab).isEmpty { NativeError(message: model.contentError(id, tab: tab)).padding(12) }
        if slot["status"].string == "running" {
            HStack(spacing: 8) {
                ShimmerText(text: model.live[id]?["tool"].string ?? "working")
                Text(model.live[id]?["text"].string ?? "").lineLimit(1).font(Theme.ui(11)).foregroundStyle(Theme.muted).frame(maxWidth: .infinity, alignment: .leading)
                if pageActive { TimelineView(.periodic(from: .now, by: 1)) { timeline in duration(at: timeline.date) } }
                else { duration(at: Date()) }
            }.padding(.horizontal, 14).frame(height: 32).background(Theme.subtle)
        }
        if tab == "Transcript" { NativeCodeScroll(jump: jump, follows: $follows) { VStack(alignment: .leading, spacing: 10) {
            NativeCodeTranscript(events: model.transcripts[id] ?? [], running: slot["status"].string == "running")
            NativeCodeLiveView(live: CodeLiveState(json: model.live[id] ?? .null), events: model.transcripts[id] ?? [])
        } }.frame(height: 560).overlay(alignment: .bottomTrailing) { if !follows { Button("Jump to latest", nativeIcon: "arrow-down") { jump += 1 }.buttonStyle(T3Button(.outline)).padding(8) } } }
        else { ScrollView { VStack(alignment: .leading, spacing: 10) {
            switch tab {
            case "Files":
                if files.isEmpty && model.contentError(id, tab: tab).isEmpty { Text("No public workspace files").font(Theme.ui(12)).foregroundStyle(Theme.muted) }
                ForEach(files, id: \.self) { file in Button { open(file["path"].string) } label: { HStack { Text(file["path"].string).font(Theme.mono(11)); Spacer(); Text(ByteCountFormatter.string(fromByteCount: Int64(file["size"].double), countStyle: .file)).font(Theme.mono(10)).foregroundStyle(Theme.muted) } }.buttonStyle(.plain) }
            default: result
            }
        }.padding(.horizontal, 14).padding(.vertical, 12).frame(maxWidth: .infinity, alignment: .leading) }.frame(height: 560) }
        Rectangle().fill(Theme.border).frame(height: 1)
        VStack(alignment: .leading, spacing: 4) {
            Text("\(slot["status"].string) · \(NativeArenaDuration(slot["duration_ms"].double)) · \(slot["turns"].int) steps · \(slot["tool_calls"].int) tools · \(slot["output_tokens"].int) out").font(Theme.mono(10.5)).foregroundStyle(Theme.muted)
            if slot["blocked"].int > 0 { Text("\(slot["blocked"].int) refused").font(Theme.mono(10.5)).foregroundStyle(Theme.warnFg) }
            if !slot["error"].isNull { Text(slot["error"].string).font(Theme.ui(11)).foregroundStyle(slot["status"].string == "done" ? Theme.warnFg : Theme.failFg).textSelection(.enabled) }
        }.padding(.horizontal, 14).padding(.vertical, 8)
    } }
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
            if !slot["final_text"].string.isEmpty { DisclosureGroup("Final message") { NativeCodeMarkdown(text: slot["final_text"].string) } }
        } else { NativeCodeMarkdown(text: slot["final_text"].string.isEmpty ? ["queued", "running"].contains(slot["status"].string) ? "Nothing presented yet" : "Nothing was presented" : slot["final_text"].string) }
    }
    private func open(_ path: String) { preview = NativeArenaPreviewItem(path: path) }
}
private struct NativeArenaPreviewItem: Identifiable { let path: String; var id: String { path } }
