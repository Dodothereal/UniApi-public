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
    private var choices: [JSONValue] { CodeSessionChoices.models(route: item.route, options: item.options) }
    private var filtered: [JSONValue] { CodeModelChoices.filter(choices, query: query) }
    private var custom: String? { CodeModelChoices.customModel(query: query, route: item.route, choices: choices) }
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(item.route["name"].string + " models").font(Theme.display(17)).foregroundStyle(Theme.ink).lineLimit(1)
                .accessibilityAddTraits(.isHeader)
            Text("Current: " + (item.currentModel.isEmpty ? "Agent default" : item.currentModel)).font(Theme.mono(11)).foregroundStyle(Theme.muted)
                .lineLimit(1).truncationMode(.middle).textSelection(.enabled).padding(.top, 6)
            Entry(placeholder: item.route["kind"].string == "agent" ? "Search model names, IDs or descriptions" : "Search models or type a custom ID",
                  text: $query, icon: "search", autoFocus: true, onSubmit: { if let value = custom ?? filtered.first?["value"].string { pick(value) } })
                .padding(.top, 16)
            Rule(strong: true).padding(.top, 14)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    if let custom {
                        LedgerRow(minHeight: 38, action: { pick(custom) }) {
                            HStack(spacing: 8) {
                                NativeIcon("plus", size: 13, strokeWidth: 1.75).foregroundStyle(Theme.muted)
                                Text("Use “\(custom)”").font(Theme.ui(12.5)).foregroundStyle(Theme.ink).lineLimit(1).truncationMode(.middle)
                            }
                        }
                    }
                    ForEach(filtered.map { Row(value: $0) }) { entry in
                        let row = entry.value
                        LedgerRow(selected: CodeModelChoices.sameID(item.currentModel, row["value"].string), minHeight: 38, action: { pick(row["value"].string) }) {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(row["value"].string.isEmpty ? row["displayName"].string : row["value"].string).font(Theme.mono(12)).foregroundStyle(Theme.ink)
                                if row["displayName"].string != row["value"].string && !row["value"].string.isEmpty {
                                    Text(row["displayName"].string).font(Theme.ui(11.5)).foregroundStyle(Theme.muted)
                                }
                                if !row["description"].string.isEmpty {
                                    Text(row["description"].string).font(Theme.ui(11.5)).foregroundStyle(Theme.muted).fixedSize(horizontal: false, vertical: true)
                                }
                            }
                            .padding(.vertical, 8)
                        }
                    }
                    if filtered.isEmpty && custom == nil {
                        Blank(icon: "search", title: "No matching models",
                              detail: item.route["kind"].string == "agent" ? "Refresh the agent's models, or clear the search to use its default." : "Type an API model ID to use a custom model.")
                    }
                }
                .padding(.horizontal, 8)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity).padding(.horizontal, -8)
            if !error.isEmpty { Notice(text: error, tone: .fail).accessibilityLabel("Error: " + error).padding(.top, 12) }
            HStack {
                Spacer(minLength: 0)
                Button("Done") { dismiss() }.buttonStyle(Press(.secondary)).keyboardShortcut(.cancelAction)
            }
            .padding(.top, 16)
        }
        .padding(24).frame(width: 620, height: 520).background(Theme.canvas).foregroundStyle(Theme.ink).disabled(busy)
    }
    private func pick(_ value: String) {
        guard !busy else { return }; busy = true
        Task { if await choose(value) { dismiss() } else { error = "The model could not be changed; the current selection is preserved." }; busy = false }
    }
}
