import SwiftUI
import UniApiCore

struct NativeSwitcherClaudeModelPicker: View {
    let models: [String]
    @Binding var chosen: String
    @State private var open = false
    @State private var query = ""
    var body: some View {
        HStack(spacing: 8) {
            Entry(placeholder: "Default or custom model ID", text: $chosen, mono: true)
            Button("Browse models") { query = ""; open = true }.buttonStyle(Press(.secondary))
        }
        .popover(isPresented: $open) {
            VStack(alignment: .leading, spacing: 12) {
                Text("Browse models").font(Theme.display(17)).foregroundStyle(Theme.ink)
                Entry(placeholder: "Search models", text: $query, icon: "search", autoFocus: true, onSubmit: {
                    if let model = NativeSwitcherDisplayPolicies.claudeSubmitChoice(models: models, query: query) { choose(model) }
                })
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        let custom = query.trimmingCharacters(in: .whitespacesAndNewlines)
                        if !custom.isEmpty && !models.contains(custom) {
                            LedgerRow(minHeight: 34, action: { choose(custom) }) {
                                Text("Use custom model: " + custom).font(Theme.ui(12.5)).lineLimit(1).truncationMode(.middle)
                            }
                        }
                        ForEach(NativeSwitcherDisplayPolicies.matchingModels(models, query: query), id: \.self) { model in
                            LedgerRow(selected: model == chosen, minHeight: 34, action: { choose(model) }) {
                                Text(model).font(Theme.mono(12)).foregroundStyle(Theme.ink).lineLimit(1).truncationMode(.middle)
                            }
                        }
                        if models.isEmpty {
                            Text("No model list yet. Refresh the provider or enter a custom model ID.")
                                .font(Theme.ui(12.5)).foregroundStyle(Theme.muted).padding(.vertical, 14)
                        }
                    }
                    .padding(.horizontal, 8)
                }
                .frame(maxHeight: 300).padding(.horizontal, -8)
                Text("Save model to apply this choice. Custom IDs are passed through to the provider.")
                    .font(Theme.ui(11.5)).foregroundStyle(Theme.muted)
            }
            .padding(20).frame(width: 440).background(Theme.popover).foregroundStyle(Theme.ink)
        }
    }
    private func choose(_ model: String) { chosen = model; open = false }
}
