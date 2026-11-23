import SwiftUI

extension View {
    /// Actual readings stay visible on first paint. Only a subsequent semantic
    /// number change rolls; there is no delayed text state or per-cell AppKit host.
    func nativeStatsNumberTransition(_ value: Double?) -> some View {
        modifier(NativeStatsNumberTransition(value: value.flatMap { $0.isFinite ? $0 : nil }))
    }

    /// The modifier owns pointer state so a row cannot invalidate its board.
    func nativeStatsRowHover(radius: CGFloat = Theme.radiusMd, overlay: Bool = false) -> some View {
        modifier(NativeStatsRowHover(radius: radius, overlay: overlay))
    }
}

private struct NativeStatsNumberTransition: ViewModifier {
    let value: Double?
    @Environment(\.nativeReducedMotion) private var reduceMotion
    @Environment(\.nativeMotionVisible) private var visible

    func body(content: Content) -> some View {
        let allowed = !reduceMotion && visible && value != nil
        content
            .contentTransition(allowed ? .numericText(value: value ?? 0) : .identity)
            .animation(allowed ? NativeMotion.number : nil, value: value)
            .transaction { if reduceMotion || !visible { $0.animation = nil } }
    }
}

private struct NativeStatsRowHover: ViewModifier {
    let radius: CGFloat
    let overlay: Bool
    @State private var hovering = false
    @Environment(\.isEnabled) private var enabled
    @Environment(\.nativeReducedMotion) private var reduceMotion
    @Environment(\.nativeMotionVisible) private var visible

    func body(content: Content) -> some View {
        content
            .background { if !overlay { surface } }
            .overlay { if overlay { surface.allowsHitTesting(false).accessibilityHidden(true) } }
            .onHover { inside in
                let next = inside && enabled && visible
                if next != hovering { hovering = next }
            }
            .onChange(of: enabled) { _, enabled in if !enabled { hovering = false } }
            .onChange(of: visible) { _, visible in if !visible { hovering = false } }
            .onDisappear { hovering = false }
    }
    private var surface: some View {
        RoundedRectangle(cornerRadius: radius)
            .fill(hovering && enabled && visible ? Theme.subtle : .clear)
            .animation(reduceMotion || !visible ? nil : NativeMotion.hover, value: hovering)
    }
}
