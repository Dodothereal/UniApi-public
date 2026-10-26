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

/// Pointer movement must not invalidate the shell's selected chart hierarchy.
private struct NativeSidebarHover<Content: View>: View {
    let selected: Bool
    let action: () -> Void
    @ViewBuilder var content: () -> Content
    @State private var hovered = false
    @Environment(\.nativeReducedMotion) private var reduceMotion
    var body: some View {
        Button(action: action) {
            content()
                .background(selected ? Theme.sidebarAccent : hovered ? Theme.subtle : .clear)
                .clipShape(RoundedRectangle(cornerRadius: Theme.radiusMd))
                .contentShape(Rectangle())
        }.buttonStyle(.plain).pointingHand()
            .onHover { hovered = $0 }
            .animation(reduceMotion ? nil : NativeMotion.hover, value: hovered)
            .animation(reduceMotion ? nil : NativeMotion.hover, value: selected)
            .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

extension View {
    func nativeSidebarRow(selected: Bool, action: @escaping () -> Void) -> some View {
        NativeSidebarHover(selected: selected, action: action) { self }
    }
}
