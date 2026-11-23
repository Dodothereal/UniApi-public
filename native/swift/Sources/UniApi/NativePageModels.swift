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
        await statistics.prefetch(source: source, range: [0, 7, 30, 90, 365].contains(savedRange) ? savedRange : 0)
    }
}

/// Pointer movement must not invalidate the shell's selected chart hierarchy.
/// The selected plate is one view shared by every row of a namespace, so it
/// slides to the next row instead of blinking from one to the other.
private struct NativeSidebarHover<Content: View>: View {
    let selected: Bool
    let namespace: Namespace.ID
    let action: () -> Void
    @ViewBuilder var content: () -> Content
    @State private var hovered = false
    @Environment(\.nativeReducedMotion) private var reduceMotion
    var body: some View {
        Button(action: action) {
            content()
                .background {
                    ZStack(alignment: .leading) {
                        RoundedRectangle(cornerRadius: Theme.radiusMd, style: .continuous)
                            .fill(hovered && !selected ? Theme.subtle : .clear)
                        if selected {
                            RoundedRectangle(cornerRadius: Theme.radiusMd, style: .continuous)
                                .fill(Theme.sidebarAccent)
                                .overlay(RoundedRectangle(cornerRadius: Theme.radiusMd, style: .continuous).strokeBorder(Theme.sidebarBorder, lineWidth: 1))
                                .overlay(alignment: .leading) {
                                    Capsule().fill(Theme.accent).frame(width: 2.5, height: 14).offset(x: -1)
                                }
                                .matchedGeometryEffect(id: "plate", in: namespace)
                        }
                    }
                }
                .contentShape(Rectangle())
        }.buttonStyle(NativePressStyle(scale: 0.985)).pointingHand()
            .onHover { hovered = $0 }
            .animation(reduceMotion ? nil : NativeMotion.hover, value: hovered)
            .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

extension View {
    func nativeSidebarRow(selected: Bool, namespace: Namespace.ID, action: @escaping () -> Void) -> some View {
        NativeSidebarHover(selected: selected, namespace: namespace, action: action) { self }
    }
}
