import SwiftUI
import AppKit
import UniApiCore

struct NativeCodeTranscript: View {
    let events: [JSONValue]
    var running = false
    private var results: [String: JSONValue] {
        var result: [String: JSONValue] = [:]
        for event in events where event["type"].string == "tool_result" { for block in event["payload"]["content"].array where block["type"].string == "tool_result" { var value = block; value["structured"] = event["payload"]["tool_use_result"]; result[block["tool_use_id"].string] = value } }; return result
    }
    private var nested: [String: Int] { var counts: [String: Int] = [:]; for event in events where event["type"].string == "assistant" && !event["payload"]["parent_tool_use_id"].isNull { counts[event["payload"]["parent_tool_use_id"].string, default: 0] += event["payload"]["content"].array.filter { $0["type"].string == "tool_use" }.count }; return counts }
    /// The events that are drawn, each with whether it opens a new speaker's
    /// turn. A run of agent events shares one heading.
    private var lines: [(offset: Int, event: JSONValue, leads: Bool)] {
        var speaker = "", output: [(offset: Int, event: JSONValue, leads: Bool)] = []
        for (offset, event) in events.enumerated() {
            let type = event["type"].string
            guard type != "tool_result", !(type == "assistant" && !event["payload"]["parent_tool_use_id"].isNull) else { continue }
            let speaks = type == "user" || type == "assistant"
            output.append((offset, event, speaks && type != speaker))
            if speaks { speaker = type }
        }
        return output
    }
    var body: some View {
        let results = results, nested = nested
        ForEach(lines, id: \.offset) { line in
            NativeCodeEvent(event: line.event, results: results, nested: nested, running: running, leads: line.leads)
        }
    }
}

/// Where one speaker's turn begins: a rule with a tick and an engraved name.
/// The person's own turns are drawn stronger so prompts are easy to find.
struct NativeCodeTurnHead: View {
    let speaker: String
    var own = false
    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            ZStack(alignment: .topLeading) {
                Rule(strong: own)
                (own ? Theme.ink : Theme.faint).frame(width: 2, height: 7)
            }
            .frame(height: 7, alignment: .top)
            MicroLabel(speaker, color: own ? Theme.ink : Theme.muted)
        }
        .padding(.top, 12)
        .accessibilityElement(children: .ignore).accessibilityLabel(speaker).accessibilityAddTraits(.isHeader)
    }
}

/// A quiet fact about the session: started, stopped, done, refused.
struct NativeCodeLine: View {
    var icon: String? = nil
    let text: String
    var tone: Color = Theme.muted
    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            if let icon { NativeIcon(icon, size: 11, strokeWidth: 1.75).offset(y: 1.5) }
            Text(text).font(Theme.mono(10.5)).fixedSize(horizontal: false, vertical: true)
        }
        .foregroundStyle(tone)
    }
}

/// A disclosure whose label is the control; its content grows from it.
struct NativeCodeFold<Content: View>: View {
    let title: String
    var live = false
    @ViewBuilder var content: () -> Content
    @State private var open: Bool
    @State private var hovering = false
    @Environment(\.nativeReducedMotion) private var reduceMotion
    init(_ title: String, live: Bool = false, open: Bool = false, @ViewBuilder content: @escaping () -> Content) {
        self.title = title; self.live = live; self.content = content; _open = State(initialValue: open)
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button { withAnimation(reduceMotion ? nil : NativeMotion.toggle) { open.toggle() } } label: {
                HStack(spacing: 6) {
                    NativeIcon("chevron-right", size: 11, strokeWidth: 1.75).rotationEffect(.degrees(open ? 90 : 0))
                    Text(title).font(Theme.ui(11.5, weight: .medium)).lineLimit(1)
                    if live { NativeStatusDot(color: Theme.signal, size: 5, pulse: true) }
                }
                .foregroundStyle(hovering || open ? Theme.ink : Theme.muted)
                .frame(height: 22).contentShape(Rectangle())
            }
            .buttonStyle(.plain).pointingHand().onHover { hovering = $0 }
            .accessibilityLabel(title).accessibilityValue(open ? "Expanded" : "Collapsed")
            if open { content().padding(.leading, 17) }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct NativeCodeToolView: View {
    let block: JSONValue
    let result: JSONValue?
    let pending: Bool
    let nested: Int
    let permissionSummary: Bool
    @State private var open: Bool
    @State private var hovering = false
    @State private var diffWidth: CGFloat = 0
    @Environment(\.nativeReducedMotion) private var reduceMotion
    init(block: JSONValue, result: JSONValue?, pending: Bool, nested: Int, permissionSummary: Bool = false) {
        self.block = block; self.result = result; self.pending = pending; self.nested = nested
        self.permissionSummary = permissionSummary; _open = State(initialValue: permissionSummary)
    }
    private var name: String { block["name"].string }
    private var input: JSONValue { block["input"] }
    private var text: String { guard let content = result?["content"] else { return "" }; if case .string(let text) = content { return text }; if case .array(let blocks) = content { return blocks.map { $0["text"].isNull ? "[image or structured content]" : $0["text"].string }.joined(separator: "\n") }; return json(content) }
    private var failed: Bool { result?["is_error"].bool == true }
    private var indent: CGFloat { permissionSummary ? 0 : 17 }
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if permissionSummary {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(name).font(Theme.ui(12.5, weight: .medium)).foregroundStyle(Theme.ink)
                    Text(summary).font(Theme.mono(11)).foregroundStyle(Theme.muted).textSelection(.enabled)
                }
            } else { head }
            if !open && !text.isEmpty && (failed || ["Bash", "Glob", "Grep"].contains(name)) {
                Text(String(text.components(separatedBy: "\n").prefix(3).joined(separator: "\n").prefix(400)))
                    .font(Theme.mono(10.5)).lineSpacing(2).foregroundStyle(failed ? Theme.failFg : Theme.muted).textSelection(.enabled)
                    .padding(.leading, indent)
            }
            if open {
                VStack(alignment: .leading, spacing: 8) {
                    details
                    if result != nil {
                        MicroLabel("Result")
                        codeWell(maxHeight: 350) {
                            Text(String(text.prefix(20000)) + (text.count > 20000 ? "\n… (truncated)" : "")).font(Theme.mono(11)).lineSpacing(2)
                                .foregroundStyle(failed ? Theme.failFg : Theme.ink).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                    if !permissionSummary {
                        NativeCodeFold("Raw input and result") {
                            codeWell(maxHeight: 280) {
                                Text(json(input) + "\n" + json(result ?? .null)).font(Theme.mono(10.5)).foregroundStyle(Theme.dim)
                                    .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }
                    }
                }
                .padding(.leading, indent)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
    private var head: some View {
        Button { withAnimation(reduceMotion ? nil : NativeMotion.toggle) { open.toggle() } } label: {
            HStack(spacing: 6) {
                NativeIcon("chevron-right", size: 11, strokeWidth: 1.75).foregroundStyle(Theme.muted).rotationEffect(.degrees(open ? 90 : 0))
                Text(name).font(Theme.ui(12.5, weight: .medium)).foregroundStyle(Theme.ink).lineLimit(1).fixedSize()
                Text(summary).font(Theme.mono(11)).foregroundStyle(Theme.muted).lineLimit(1).truncationMode(.middle).padding(.leading, 2)
                Spacer(minLength: 8)
                if nested > 0 { Text("\(nested) nested calls").font(Theme.mono(10.5)).foregroundStyle(Theme.muted).fixedSize() }
                if failed { Tag("error", tone: Theme.failFg) }
                if pending && result == nil {
                    HStack(spacing: 5) {
                        NativeStatusDot(color: Theme.signal, size: 5, pulse: true)
                        Text("running").font(Theme.mono(10.5)).foregroundStyle(Theme.muted)
                    }
                    .fixedSize().accessibilityElement(children: .ignore).accessibilityLabel("running")
                }
            }
            .frame(minHeight: 26)
            .background {
                RoundedRectangle(cornerRadius: Theme.radiusControl, style: .continuous)
                    .fill(hovering ? Theme.hover : .clear).padding(.horizontal, -8)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain).pointingHand().onHover { hovering = $0 }
        .accessibilityValue(open ? "Expanded" : "Collapsed")
    }
    private func codeWell<Body: View>(maxHeight: CGFloat, @ViewBuilder _ body: () -> Body) -> some View {
        ScrollView { body() }.frame(maxHeight: maxHeight)
            .padding(10).background(Theme.well, in: RoundedRectangle(cornerRadius: Theme.radiusWell, style: .continuous))
    }
    private var summary: String { switch name {
        case "Bash": return input["command"].string.components(separatedBy: "\n").first ?? ""
        case "Read", "Write", "Edit", "MultiEdit", "NotebookEdit": return input["file_path"].string
        case "Glob", "Grep": return input["pattern"].string + (input["path"].string.isEmpty ? "" : " in " + input["path"].string)
        case "WebFetch": return input["url"].string
        case "WebSearch": return input["query"].string
        case "Agent", "Task": return input["description"].string
        case "TodoWrite": return "\(input["todos"].array.count) todos"
        case "ExitPlanMode": return "Plan for review"
        case "AskUserQuestion": return input["questions"].array.first?["question"].string ?? ""
        default: return block["title"].string.isEmpty ? String(json(input).prefix(160)) : block["title"].string
    } }
    @ViewBuilder private var details: some View {
        switch name {
        case "Edit": diff(input["old_string"].string, input["new_string"].string)
        case "MultiEdit": ForEach(Array(input["edits"].array.prefix(50).enumerated()), id: \.offset) { _, edit in diff(edit["old_string"].string, edit["new_string"].string) }
        case "Bash", "Write":
            codeWell(maxHeight: 350) {
                Text(name == "Bash" ? input["command"].string : input["content"].string).font(Theme.mono(11)).lineSpacing(2)
                    .foregroundStyle(Theme.ink).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
            }
        case "TodoWrite":
            VStack(alignment: .leading, spacing: 6) {
                ForEach(Array(input["todos"].array.enumerated()), id: \.offset) { _, todo in
                    let status = todo["status"].string
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        NativeIcon(status == "completed" ? "check" : status == "in_progress" ? "circle-dot" : "circle", size: 12, strokeWidth: 1.75)
                            .foregroundStyle(status == "completed" ? Theme.okFg : status == "in_progress" ? Theme.ink : Theme.faint).offset(y: 2)
                        Text(todo["content"].string).font(Theme.ui(12.5)).foregroundStyle(status == "completed" ? Theme.muted : Theme.ink)
                            .strikethrough(status == "completed")
                    }
                    .accessibilityElement(children: .ignore).accessibilityLabel(status + ": " + todo["content"].string)
                }
            }
        case "ExitPlanMode": NativeCodeMarkdown(text: input["plan"].string)
        default:
            codeWell(maxHeight: 350) {
                Text(json(input)).font(Theme.mono(11)).foregroundStyle(Theme.ink).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }
    private func diff(_ old: String, _ new: String) -> some View { ScrollView([.horizontal, .vertical]) { VStack(alignment: .leading, spacing: 0) { ForEach(Array(old.components(separatedBy: "\n").enumerated()), id: \.offset) { _, line in Text("- " + line).foregroundStyle(Theme.failFg).frame(maxWidth: .infinity, alignment: .leading).background(Theme.surfaceFor(Theme.fail)) }; ForEach(Array(new.components(separatedBy: "\n").enumerated()), id: \.offset) { _, line in Text("+ " + line).foregroundStyle(Theme.okFg).frame(maxWidth: .infinity, alignment: .leading).background(Theme.surfaceFor(Theme.ok)) } }.font(Theme.mono(11)).textSelection(.enabled).frame(minWidth: diffWidth, alignment: .topLeading) }.frame(maxHeight: 280)
        .background { GeometryReader { geometry in Color.clear
            .onAppear { diffWidth = geometry.size.width }
            .onChange(of: geometry.size.width) { _, width in diffWidth = width }
        } }
        .padding(10).background(Theme.well, in: RoundedRectangle(cornerRadius: Theme.radiusWell, style: .continuous))
    }
    private func json(_ value: JSONValue) -> String { String(decoding: (try? value.encoded(pretty: true)) ?? Data(), as: UTF8.self) }
}

/// Native block layout around Foundation's inline Markdown parser. Code stays
/// selectable and copyable; no HTML renderer or app web surface is involved.
struct NativeCodeMarkdown: View { let text: String; var body: some View { NativeMarkdown(text: text) } }

struct NativeCodeLiveView: View {
    let live: CodeLiveState
    let events: [JSONValue]
    private var results: [String: JSONValue] { var output: [String: JSONValue] = [:]; for event in events where event["type"].string == "tool_result" { for block in event["payload"]["content"].array { output[block["tool_use_id"].string] = block } }; return output }
    /// The stream opens the agent's turn when nothing saved has spoken since
    /// the person's last message.
    private var leads: Bool {
        events.last { ["user", "assistant"].contains($0["type"].string) && $0["payload"]["parent_tool_use_id"].isNull }?["type"].string != "assistant"
    }
    var body: some View {
        let blocks = live.remaining(events: events)
        VStack(alignment: .leading, spacing: 10) {
            if !blocks.isEmpty && leads { NativeCodeTurnHead(speaker: "Agent") }
            ForEach(blocks) { block in
                if block.type == "text" { NativeMarkdown(text: block.text) }
                else if block.type == "thinking" {
                    NativeCodeFold("Thinking", live: !block.done) { NativeMarkdown(text: block.text).foregroundStyle(Theme.muted) }
                }
                else if block.type == "tool_use" { NativeCodeToolView(block: block.tool, result: results[block.toolID], pending: !block.done, nested: 0) }
            }
        }
    }
}
