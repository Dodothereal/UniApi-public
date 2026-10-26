import SwiftUI
import UniApiCore

struct NativeSwitcherClaudeModelPicker: View {
    let models: [String]
    @Binding var chosen: String
    @State private var open = false
    @State private var query = ""
    var body: some View {
        HStack {
            T3Field(placeholder: "Default or custom model ID", text: $chosen, mono: true)
            Button("Browse models") { query = ""; open = true }.buttonStyle(T3Button())
        }.popover(isPresented: $open) {
            VStack(alignment: .leading, spacing: 12) {
                T3Field(placeholder: "Search models", text: $query).onSubmit {
                    if let model = NativeSwitcherDisplayPolicies.claudeSubmitChoice(models: models, query: query) { choose(model) }
                }
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 6) {
                        let custom = query.trimmingCharacters(in: .whitespacesAndNewlines)
                        if !custom.isEmpty && !models.contains(custom) { Button("Use custom model: " + custom) { choose(custom) }.buttonStyle(T3Button()) }
                        ForEach(NativeSwitcherDisplayPolicies.matchingModels(models, query: query), id: \.self) { model in
                            Button { choose(model) } label: { HStack { Text(model).font(Theme.mono(12)).textSelection(.disabled); Spacer(); if model == chosen { NativeIcon("check", size: 14) } } }.buttonStyle(.plain).padding(.vertical, 5)
                        }
                        if models.isEmpty { Text("No model list yet. Refresh the provider or enter a custom model ID.").font(Theme.ui(12)).foregroundStyle(Theme.muted) }
                    }
                }.frame(maxHeight: 300)
                Text("Save model to apply this choice. Custom IDs are passed through to the provider.").font(Theme.ui(11)).foregroundStyle(Theme.muted)
            }.padding(16).frame(width: 450).background(Theme.bg)
        }
    }
    private func choose(_ model: String) { chosen = model; open = false }
}
