import SwiftUI
import UniApiCore

/// Benchmark: start a run, then read it. Running and results are views of one
/// page, so a finished run is one tab away from the models that produced it.
struct NativeBenchmarkPage: View {
    static let viewKey = "uniapi.benchmark.view"
    let runtime: NativeRuntime
    var models: NativePageModels?
    var resultsRun: String?
    var opens: String?
    @AppStorage(NativeBenchmarkPage.viewKey) private var view = "bench"
    private static let run: [(value: String, label: String)] = [("bench", "Run"), ("free", "Free test")]
    private static let results: [(value: String, label: String)] = [("table", "Results"), ("charts", "Charts"), ("runs", "Runs")]
    var body: some View {
        Group {
            if Self.results.contains(where: { $0.value == view }) {
                NativeResultsPage(runtime: runtime, initialRun: resultsRun)
                    .environment(\.nativeHostTabs, NativeHostTabs(title: "Benchmark", view: view, before: Self.run) { view = $0 })
            } else {
                NativeSpeedPage(runtime: runtime, model: models?.speed)
                    .environment(\.nativeHostTabs, NativeHostTabs(title: "Benchmark", view: view, after: Self.results) { view = $0 })
            }
        }
        .onAppear { if let opens { view = opens } }
        .onChange(of: resultsRun) { _, run in if run != nil { view = "table" } }
        // A run opened from Home scopes Results only until the user goes back to Run.
        .onChange(of: view) { _, value in
            if resultsRun != nil, !Self.results.contains(where: { $0.value == value }) { NotificationCenter.default.post(name: .nativeResultsScope, object: nil) }
        }
    }
}

/// Arena: matches, ranking, presets and the prompt library they draw from.
struct NativeArenaHost: View {
    static let viewKey = "uniapi.arena.view"
    let runtime: NativeRuntime
    var opens: String?
    @AppStorage(NativeArenaHost.viewKey) private var view = "Judge"
    private static let arena: [(value: String, label: String)] = ["Judge", "Ranking", "Presets", "History"].map { ($0, $0) }
    var body: some View {
        Group {
            if view == "prompts" {
                NativePromptsPage(runtime: runtime)
                    .environment(\.nativeHostTabs, NativeHostTabs(title: "Arena", view: view, before: Self.arena, current: ("prompts", "Prompts")) { view = $0 })
            } else {
                NativeArenaPage(runtime: runtime)
                    .environment(\.nativeHostTabs, NativeHostTabs(title: "Arena", view: view, after: [("prompts", "Prompts")]) { view = $0 })
            }
        }
        .onAppear { if let opens { view = opens } }
    }
}

/// Energy: power flow, history and sensors, and the charge limit on Macs that
/// support one.
struct NativeEnergyHost: View {
    static let viewKey = "uniapi.energy.view"
    let runtime: NativeRuntime
    var opens: String?
    @AppStorage(NativeEnergyHost.viewKey) private var view = "flow"
    @Environment(\.nativeBatterySupported) private var batterySupported
    private static let energy: [(value: String, label: String)] = [("flow", "Now"), ("history", "History"), ("sensors", "Sensors"), ("settings", "Preferences")]
    var body: some View {
        let charge = batterySupported != false
        Group {
            if view == "battery", charge {
                NativeBatteryPage(runtime: runtime)
                    .environment(\.nativeHostTabs, NativeHostTabs(title: "Energy", view: view, before: Self.energy, current: ("battery", "Charge limit")) { view = $0 })
            } else {
                NativeEnergyPage(runtime: runtime)
                    .environment(\.nativeHostTabs, NativeHostTabs(title: "Energy", view: view, after: charge ? [("battery", "Charge limit")] : []) { view = $0 })
            }
        }
        .onAppear { if let opens { view = opens } }
    }
}
