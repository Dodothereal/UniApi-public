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
    var body: some View { let results = results, nested = nested; ForEach(Array(events.enumerated()), id: \.offset) { _, event in
        if event["type"].string != "tool_result" && !(event["type"].string == "assistant" && !event["payload"]["parent_tool_use_id"].isNull) { NativeCodeEvent(event: event, results: results, nested: nested, running: running) }
    } }
}

struct NativeCodeToolView: View {
    let block: JSONValue
    let result: JSONValue?
    let pending: Bool
    let nested: Int
    let permissionSummary: Bool
    @State private var open: Bool
    @State private var raw = false
    @State private var diffWidth: CGFloat = 0
    init(block: JSONValue, result: JSONValue?, pending: Bool, nested: Int, permissionSummary: Bool = false) {
        self.block = block; self.result = result; self.pending = pending; self.nested = nested
        self.permissionSummary = permissionSummary; _open = State(initialValue: permissionSummary)
    }
    private var name: String { block["name"].string }
    private var input: JSONValue { block["input"] }
    private var text: String { guard let content = result?["content"] else { return "" }; if case .string(let text) = content { return text }; if case .array(let blocks) = content { return blocks.map { $0["text"].isNull ? "[image or structured content]" : $0["text"].string }.joined(separator: "\n") }; return json(content) }
    private var failed: Bool { result?["is_error"].bool == true }
    var body: some View { VStack(alignment: .leading, spacing: 7) {
        if permissionSummary { HStack(spacing: 6) { Text(name).font(Theme.ui(12, weight: .medium)); Text(summary).font(Theme.mono(11)).foregroundStyle(Theme.muted).textSelection(.enabled) } }
        else { Button { withAnimation(NativeMotion.toggle) { open.toggle() } } label: { HStack { NativeIcon(systemName: open ? "chevron.down" : "chevron.right", size: 10); Text(name).font(Theme.ui(12, weight: .medium)); Text(summary).font(Theme.mono(11)).foregroundStyle(Theme.muted).lineLimit(1); Spacer(); if pending && result == nil { ShimmerText(text: "running", font: Theme.ui(10)) }; if failed { Text("error").font(Theme.ui(11)).foregroundStyle(Theme.failFg) }; if nested > 0 { Text("\(nested) nested calls").font(Theme.ui(10)).foregroundStyle(Theme.muted) } } }.buttonStyle(.plain) }
        if !open && !text.isEmpty && (failed || ["Bash", "Glob", "Grep"].contains(name)) { Text(String(text.components(separatedBy: "\n").prefix(3).joined(separator: "\n").prefix(400))).font(Theme.mono(11)).foregroundStyle(failed ? Theme.failFg : Theme.muted).textSelection(.enabled) }
        if open {
            if !permissionSummary { Divider() }
            details
            if result != nil { Text("Result").font(Theme.ui(10)).foregroundStyle(Theme.muted); ScrollView { Text(String(text.prefix(20000)) + (text.count > 20000 ? "\n… (truncated)" : "")).font(Theme.mono(11)).foregroundStyle(failed ? Theme.failFg : Theme.ink).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }.frame(maxHeight: 350) }
            if !permissionSummary { Toggle("Raw input and result", isOn: $raw).font(Theme.ui(10)) }; if raw { ScrollView { Text(json(input) + "\n" + json(result ?? .null)).font(Theme.mono(10)).textSelection(.enabled) }.frame(maxHeight: 280) }
        }
    }.padding(9).background(open ? Theme.surface : Theme.subtle, in: RoundedRectangle(cornerRadius: Theme.radiusMd)) }
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
        case "Bash", "Write": ScrollView { Text(name == "Bash" ? input["command"].string : input["content"].string).font(Theme.mono(11)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }.frame(maxHeight: 350)
        case "TodoWrite": ForEach(Array(input["todos"].array.enumerated()), id: \.offset) { _, todo in HStack { Text(todo["status"].string).font(Theme.mono(10)).foregroundStyle(Theme.muted); Text(todo["content"].string).font(Theme.ui(12)).strikethrough(todo["status"].string == "completed") } }
        case "ExitPlanMode": NativeCodeMarkdown(text: input["plan"].string)
        default: Text(json(input)).font(Theme.mono(11)).textSelection(.enabled)
        }
    }
    private func diff(_ old: String, _ new: String) -> some View { ScrollView([.horizontal, .vertical]) { VStack(alignment: .leading, spacing: 0) { ForEach(Array(old.components(separatedBy: "\n").enumerated()), id: \.offset) { _, line in Text("- " + line).foregroundStyle(Theme.failFg).frame(maxWidth: .infinity, alignment: .leading).background(Theme.fail.opacity(0.07)) }; ForEach(Array(new.components(separatedBy: "\n").enumerated()), id: \.offset) { _, line in Text("+ " + line).foregroundStyle(Theme.okFg).frame(maxWidth: .infinity, alignment: .leading).background(Theme.ok.opacity(0.07)) } }.font(Theme.mono(11)).textSelection(.enabled).frame(minWidth: diffWidth, alignment: .topLeading) }.frame(maxHeight: 280)
        .background { GeometryReader { geometry in Color.clear
            .onAppear { diffWidth = geometry.size.width }
            .onChange(of: geometry.size.width) { _, width in diffWidth = width }
        } }
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
    var body: some View { VStack(alignment: .leading, spacing: 8) { ForEach(live.remaining(events: events)) { block in
        if block.type == "text" { NativeMarkdown(text: block.text) }
        else if block.type == "thinking" { DisclosureGroup(block.done ? "Thinking" : "Thinking…") { NativeMarkdown(text: block.text).foregroundStyle(Theme.muted) }.font(Theme.ui(12)); if !block.done { ShimmerText(text: "Thinking") } }
        else if block.type == "tool_use" { NativeCodeToolView(block: block.tool, result: results[block.toolID], pending: !block.done, nested: 0) }
    } } }
}
