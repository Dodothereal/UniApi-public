import SwiftUI
import UniApiCore

struct NativeCodeModelPickerItem: Identifiable {
    let threadID: String
    let route: JSONValue, options: JSONValue
    let currentModel: String
    var id: String { threadID + ":" + route["id"].string }
}

struct NativeCodeModelPicker: View {
    private struct Row: Identifiable { let value: JSONValue; var id: Data { Data(value["value"].string.utf8) } }
    let item: NativeCodeModelPickerItem
    let choose: (String) async -> Bool
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var busy = false
    @State private var error = ""
    @FocusState private var focused: Bool
    private var choices: [JSONValue] { CodeSessionChoices.models(route: item.route, options: item.options) }
    private var filtered: [JSONValue] { CodeModelChoices.filter(choices, query: query) }
    private var custom: String? { CodeModelChoices.customModel(query: query, route: item.route, choices: choices) }
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                NativeIcon("search", size: 15).foregroundStyle(Theme.muted)
                TextField(item.route["kind"].string == "agent" ? "Search \(item.route["name"].string) models" : "Search \(item.route["name"].string) models or type a model ID", text: $query)
                    .textFieldStyle(.plain).font(Theme.ui(Theme.textBase)).focused($focused)
                    .onSubmit { if let value = custom ?? filtered.first?["value"].string { pick(value) } }
                Button("Done") { dismiss() }.buttonStyle(T3Button(.ghost)).keyboardShortcut(.cancelAction)
            }.padding(.leading, 18).padding(.trailing, 10).frame(height: Theme.barHeight)
                .overlay(alignment: .bottom) { Theme.rule.frame(height: 1) }
            ScrollView { LazyVStack(alignment: .leading, spacing: 0) {
                if let custom { NativeCodeModelRow(title: custom, detail: "Use this ID as typed", selected: false, icon: "plus") { pick(custom) } }
                ForEach(filtered.map { Row(value: $0) }) { entry in let row = entry.value
                    NativeCodeModelRow(title: row["value"].string.isEmpty ? row["displayName"].string : row["value"].string,
                                       detail: [row["displayName"].string != row["value"].string && !row["value"].string.isEmpty ? row["displayName"].string : "", row["description"].string].filter { !$0.isEmpty }.joined(separator: " · "),
                                       selected: CodeModelChoices.sameID(item.currentModel, row["value"].string), icon: "check") { pick(row["value"].string) }
                }
                if filtered.isEmpty && custom == nil {
                    Text(item.route["kind"].string == "agent" ? "No match. Refresh the agent's models or clear the search." : "No match. Type a model ID to use it.").font(Theme.ui(12)).foregroundStyle(Theme.muted).padding(.horizontal, 18).padding(.vertical, 14)
                }
            } }.frame(maxWidth: .infinity, maxHeight: .infinity)
            if !error.isEmpty { NativeError(message: error).padding(.horizontal, 18).padding(.vertical, 10) }
        }.frame(width: 560, height: 480).background(Theme.bg).disabled(busy).onAppear { focused = true }
    }
    private func pick(_ value: String) {
        guard !busy else { return }; busy = true
        Task { if await choose(value) { dismiss() } else { error = "The model could not be changed; the current selection is preserved." }; busy = false }
    }
}

private struct NativeCodeModelRow: View {
    let title: String, detail: String
    let selected: Bool
    let icon: String
    let action: () -> Void
    @State private var hovering = false
    var body: some View {
        Button(action: action) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(title).font(Theme.mono(12)).foregroundStyle(Theme.ink).lineLimit(1).truncationMode(.middle)
                    if !detail.isEmpty { Text(detail).font(Theme.ui(11)).foregroundStyle(Theme.muted).lineLimit(2) }
                }
                Spacer(minLength: 8)
                if selected || icon != "check" { NativeIcon(icon, size: 13).foregroundStyle(selected ? Theme.accent : Theme.muted) }
            }.padding(.horizontal, 18).padding(.vertical, 9).frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
                .background(hovering ? Theme.subtle : .clear)
                .overlay(alignment: .leading) { Theme.accent.frame(width: 2).opacity(selected ? 1 : 0) }
                .overlay(alignment: .bottom) { Theme.rule.frame(height: 1) }
        }.buttonStyle(.plain).pointingHand().onHover { hovering = $0 }.accessibilityAddTraits(selected ? [.isSelected] : [])
    }
}
