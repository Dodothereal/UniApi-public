import SwiftUI
import UniApiCore
import UniApiPresentation

struct NativeArenaRunCard: View {
    @ObservedObject var model: NativeArenaModel
    let match: JSONValue
    let open: () -> Void

    var body: some View {
        let ready = ArenaMatchSelection.JudgeGroup(match) == .ready
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(ready ? ArenaMatchSelection.JudgeGroup.ready.title : ArenaPresentationPolicy.matchStatus(match).capitalized)
                        .font(Theme.ui(Theme.textXs, weight: .medium)).foregroundStyle(ready ? Theme.okFg : Theme.muted)
                    Text(match["prompt"].string).font(Theme.ui(Theme.textSm, weight: .semibold)).lineLimit(2)
                }.frame(maxWidth: .infinity, alignment: .leading)
                Button(ready ? "Judge match" : "Watch run", nativeIcon: "arrow-right", action: open)
                    .buttonStyle(T3Button(ready ? .primary : .outline))
            }
            if ready {
                Text("\(match["slots"].array.filter { $0["status"].string == "done" }.count) answers ready · identities hidden")
                    .font(Theme.ui(Theme.textXs)).foregroundStyle(Theme.muted)
            } else {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 113), spacing: 12)], spacing: 8) {
                    ForEach(match["slots"].array, id: \.self["id"]) { slot in
                        NativeArenaStepBar(slot: slot, live: model.live[slot["id"].string] ?? .null, budget: match["max_turns"].int)
                    }
                }
            }
        }.padding(14).frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.radiusMd))
            .overlay(RoundedRectangle(cornerRadius: Theme.radiusMd).strokeBorder(Theme.border, lineWidth: 1).allowsHitTesting(false))
    }
}

struct NativeArenaLive: View {
    @ObservedObject var model: NativeArenaModel
    let match: JSONValue
    let judge: () -> Void
    @State private var stopping = false
    @Environment(\.nativeInterfaceDensity) private var density

    private var ready: Bool { ArenaMatchSelection.JudgeGroup(match) == .ready }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(match["prompt"].string).font(Theme.ui(18, weight: .semibold)).lineLimit(3).help(match["prompt"].string)
                    Text("Contestant identities stay hidden until judging is complete.")
                        .font(Theme.ui(Theme.textXs)).foregroundStyle(Theme.muted)
                }.frame(maxWidth: .infinity, alignment: .leading)
                if ready {
                    Button("Judge this match", nativeIcon: "arrow-right", action: judge).buttonStyle(T3Button(.primary))
                } else {
                    Button("Stop", nativeIcon: "square") {
                        stopping = true
                        Task { defer { stopping = false }; _ = await model.performMatchAction("cancel", id: match["id"]) }
                    }.buttonStyle(T3Button(.outline)).disabled(stopping)
                }
            }.padding(.horizontal, density.pageMargin)
            GeometryReader { viewport in
                let slots = match["slots"].array
                let available = viewport.size.width - 2 * density.pageMargin
                let width = max(216, (available - 12 * CGFloat(max(0, slots.count - 1))) / CGFloat(max(1, slots.count)))
                ScrollView(.horizontal) {
                    HStack(alignment: .top, spacing: 12) {
                        ForEach(slots, id: \.self["id"]) { slot in
                            NativeArenaLane(model: model, slot: slot, budget: match["max_turns"].int)
                                .frame(width: min(440, width), height: max(0, viewport.size.height - 1), alignment: .top)
                        }
                    }.padding(.horizontal, density.pageMargin)
                }
            }
        }.padding(.vertical, density.pageGap)
    }
}

private struct NativeArenaLane: View {
    @ObservedObject var model: NativeArenaModel
    let slot: JSONValue
    let budget: Int
    @State private var owner: NativeArenaModel.ContentOwner?
    @Environment(\.nativeReducedMotion) private var reducedMotion
    @Environment(\.nativeMotionVisible) private var visible
    private var id: String { slot["id"].string }
    private var live: JSONValue { model.live[id] ?? .null }
    private var motion: Animation? { reducedMotion || !visible ? nil : NativeMotion.reveal }
    private var events: [JSONValue] { model.transcripts[id] ?? [] }
    private var observedSteps: Int? {
        let recorded = live["observedSteps"]
        guard recorded.isNull else { return recorded.int }
        return model.transcripts[id].map(ArenaPresentationPolicy.observedSteps)
    }
    private var steps: [String] {
        let recent = events.suffix(64).flatMap { event -> [String] in
            let payload = event["payload"]
            guard event["type"].string == "assistant", payload["parent_tool_use_id"].isNull else { return [] }
            return payload["content"].array.filter { $0["type"].string == "tool_use" }.map { $0["name"].string }.filter { !$0.isEmpty }
        }
        return Array(recent.suffix(5).reversed())
    }
    private var excerpt: String {
        let active = live["text"].string
        if slot["status"].string == "running", !active.isEmpty { return active }
        let final = slot["final_text"].string
        if !final.isEmpty { return final }
        return events.reversed().first { event in
            event["type"].string == "assistant" && event["payload"]["parent_tool_use_id"].isNull &&
                event["payload"]["content"].array.contains { $0["type"].string == "text" }
        }?["payload"]["content"].array.filter { $0["type"].string == "text" }.map { $0["text"].string }.joined(separator: "\n") ?? ""
    }

    var body: some View {
        let status = slot["status"].string
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                NativeArenaStepBar(slot: slot, live: live, budget: budget, observedSteps: observedSteps)
                Theme.rule.frame(height: 1)
                Text("Recent steps").font(Theme.ui(Theme.textXs, weight: .semibold)).accessibilityAddTraits(.isHeader)
                if !live["tool"].string.isEmpty, status == "running" {
                    Text("Latest tool · \(live["tool"].string)").foregroundStyle(Theme.accent).lineLimit(1)
                }
                if steps.isEmpty { Text("No tool calls recorded yet").foregroundStyle(Theme.muted) }
                ForEach(Array(steps.enumerated()), id: \.offset) { _, step in
                    Label(step, systemImage: "chevron.right").font(Theme.mono(Theme.textXs)).foregroundStyle(Theme.dim)
                }
                if !model.contentError(id, tab: "Transcript").isEmpty { NativeError(message: model.contentError(id, tab: "Transcript")) }
                Theme.rule.frame(height: 1)
                Text("Answer excerpt").font(Theme.ui(Theme.textXs, weight: .semibold)).accessibilityAddTraits(.isHeader)
                Text(excerpt.isEmpty ? "No answer text yet" : String(excerpt.suffix(1000)))
                    .font(Theme.ui(Theme.textSm)).foregroundStyle(excerpt.isEmpty ? Theme.muted : Theme.dim)
                    .textSelection(.enabled)
            }.padding(14).frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.radiusMd))
        .overlay(RoundedRectangle(cornerRadius: Theme.radiusMd).strokeBorder(Theme.border, lineWidth: 1).allowsHitTesting(false))
        .animation(motion, value: status)
        .animation(motion, value: steps)
        .nativePageTask(id: "\(id):\(model.readActive):\(model.readGeneration)") {
            guard model.readActive, let request = model.beginContent(id, tab: "Transcript") else { return }
            owner = request
            await model.transcript(id, content: request)
        }
        .nativePageActivity(suspended: { if let owner { model.endContent(owner) }; owner = nil })
    }
}

private struct NativeArenaStepBar: View {
    let slot: JSONValue
    let live: JSONValue
    let budget: Int
    var observedSteps: Int? = nil

    var body: some View {
        let status = slot["status"].string, running = status == "running", queued = status == "queued"
        let recorded = slot["turns"].int
        let observed = live["observedSteps"]
        let used: Int? = running ? (observedSteps ?? (observed.isNull ? nil : observed.int)) : queued ? 0 : recorded > 0 ? recorded : nil
        let color = status == "done" ? Theme.ok : status == "failed" ? Theme.fail : Theme.accent
        VStack(alignment: .leading, spacing: 6) {
            Text(slot["label"].string).font(Theme.ui(Theme.textXs, weight: .semibold)).lineLimit(1)
            HStack(spacing: 4) {
                StatusDot(color: color, pulse: running)
                Text(status.capitalized).font(Theme.ui(Theme.textXs)).lineLimit(1)
                Spacer(minLength: 0)
            }.foregroundStyle(Theme.muted)
            NativeGrowBar(fraction: used.flatMap { budget > 0 ? Double($0) / Double(budget) : nil } ?? 0, color: color)
                .accessibilityHidden(true)
            NativeNumberText(text: used.map { "\($0)/\(budget) \(running ? "observed steps" : "steps")" } ?? "Steps not reported",
                             font: Theme.num(Theme.textXs, weight: .regular), color: Theme.muted)
                .lineLimit(1)
        }.accessibilityElement(children: .combine)
    }
}
