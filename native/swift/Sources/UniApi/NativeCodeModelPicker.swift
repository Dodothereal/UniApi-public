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
        VStack(alignment: .leading, spacing: 14) {
            HStack { Text(item.route["name"].string + " models").font(Theme.ui(18, weight: .semibold)); Spacer(); Button("Done") { dismiss() } }
            TextField(item.route["kind"].string == "agent" ? "Search model names, IDs or descriptions" : "Search models or type a custom ID", text: $query)
                .focused($focused).onSubmit { if let value = custom ?? filtered.first?["value"].string { pick(value) } }
            ScrollView { LazyVStack(alignment: .leading, spacing: 5) {
                if let custom { Button("Use “\(custom)”") { pick(custom) }.buttonStyle(.bordered) }
                ForEach(filtered.map { Row(value: $0) }) { entry in let row = entry.value; Button { pick(row["value"].string) } label: {
                    HStack {
                        let selected = CodeModelChoices.sameID(item.currentModel, row["value"].string)
                        ZStack {
                            Circle().fill(selected ? Theme.okFg : .clear)
                                .overlay(Circle().strokeBorder(selected ? Theme.okFg : Theme.muted.opacity(0.45), lineWidth: 1))
                            if selected { NativeIcon("check", size: 8, strokeWidth: 3).foregroundStyle(Theme.bg) }
                        }.frame(width: 12, height: 12).frame(width: 18, height: 14).accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(row["value"].string.isEmpty ? row["displayName"].string : row["value"].string).font(Theme.mono(12))
                            if row["displayName"].string != row["value"].string && !row["value"].string.isEmpty { Text(row["displayName"].string).font(Theme.ui(11)).foregroundStyle(Theme.muted) }
                            if !row["description"].string.isEmpty { Text(row["description"].string).font(Theme.ui(11)).foregroundStyle(Theme.muted) }
                        }; Spacer()
                    }.padding(8).frame(maxWidth: .infinity, alignment: .leading).background(CodeModelChoices.sameID(item.currentModel, row["value"].string) ? Theme.subtle2 : Theme.subtle, in: RoundedRectangle(cornerRadius: Theme.radiusMd))
                }.buttonStyle(.plain) }
                if filtered.isEmpty && custom == nil { NativeEmptyState(title: "No matching models", detail: item.route["kind"].string == "agent" ? "Refresh the agent's models, or clear the search to use its default." : "Type an API model ID to use a custom model.") }
            } }.frame(maxWidth: .infinity, maxHeight: .infinity)
            if !error.isEmpty { NativeError(message: error) }
            Text("Current: " + (item.currentModel.isEmpty ? "Agent default" : item.currentModel)).font(Theme.mono(11)).foregroundStyle(Theme.muted).textSelection(.enabled)
        }.padding(20).frame(width: 620, height: 520).background(Theme.bg).disabled(busy).onAppear { focused = true }
    }
    private func pick(_ value: String) {
        guard !busy else { return }; busy = true
        Task { if await choose(value) { dismiss() } else { error = "The model could not be changed; the current selection is preserved." }; busy = false }
    }
}
