import SwiftUI
import UniApiCore
import UniApiPresentation

/// Keep data models, not fourteen hidden view trees or their polling tasks.
/// Closing retains drafts; normal Quit discards them with the presentation.
@MainActor final class NativePageModels: ObservableObject {
    private let runtime: NativeRuntime
    @Published private(set) var statistics: NativeStatsModel
    @Published private(set) var speed: NativeSpeedModel
    init(runtime: NativeRuntime) {
        self.runtime = runtime
        statistics = NativeStatsModel(runtime: runtime)
        speed = NativeSpeedModel(runtime: runtime)
    }
    func discard() {
        statistics.stop(discard: true); speed.stopListening()
        statistics = NativeStatsModel(runtime: runtime)
        speed = NativeSpeedModel(runtime: runtime)
    }
    func prefetchStatistics() async {
        let saved = UserDefaults.standard.string(forKey: "uniapi.stats.source") ?? "all"
        let source = (["all"] + StatisticsSource.allCases.map(\.rawValue)).contains(saved) ? saved : "all"
        let savedRange = UserDefaults.standard.integer(forKey: "uniapi.stats.range")
        await statistics.prefetch(source: source, range: [0, 7, 30].contains(savedRange) ? savedRange : 0)
    }
}

/// One index row. Pointer movement stays inside the row so it cannot
/// invalidate the shell's selected chart hierarchy.
/// The travelling marker is supplied by the shell so a single
/// shape can move between rows; hover stays local to the row.
struct NativeShellRow<Label: View, Marker: View>: View {
    let selected: Bool
    let rail: Bool
    let help: String
    let action: () -> Void
    @ViewBuilder var label: () -> Label
    @ViewBuilder var marker: () -> Marker
    @State private var hovered = false
    @Environment(\.nativeReducedMotion) private var reduceMotion
    var body: some View {
        Button(action: action) {
            label()
                .background {
                    ZStack {
                        if hovered && !selected {
                            RoundedRectangle(cornerRadius: Theme.radiusControl, style: .continuous).fill(Theme.hover)
                        }
                        marker()
                    }
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain).pointingHand()
        .onHover { hovered = $0 }
        .animation(reduceMotion ? nil : NativeMotion.hover, value: hovered)
        .accessibilityLabel(help)
        .accessibilityAddTraits(selected ? .isSelected : [])
        .help(rail ? help : "")
    }
}
