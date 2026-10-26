import SwiftUI

/// The shared tile's exact typography, spacing and accessibility, with a real
/// reading on first paint. Statistics snapshots need no blank stagger interval.
struct NativeStatsValueTile: View {
    let label: String
    let value: Double?
    var unit = ""
    var detail = ""
    var accent: Color = Theme.accent
    var format: (Double) -> String = NativeNumberFormat.decimal
    private var reading: String { value.flatMap { $0.isFinite ? format($0) : nil } ?? "-" }

    var body: some View {
        Card(padding: 14) {
            VStack(alignment: .leading, spacing: 7) {
                HStack(spacing: 6) {
                    StatusDot(color: accent, size: 5)
                    Text(label).font(Theme.ui(12)).foregroundStyle(Theme.muted).lineLimit(1)
                }
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    Text(reading).font(Theme.mono(22, weight: .semibold)).monospacedDigit().lineLimit(1)
                        .nativeStatsNumberTransition(value)
                    if !unit.isEmpty {
                        Text(unit).font(Theme.mono(12)).foregroundStyle(Theme.muted).lineLimit(1)
                    }
                }
                if !detail.isEmpty {
                    Text(detail).font(Theme.ui(11.5)).foregroundStyle(Theme.muted)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .accessibilityElement(children: .ignore).accessibilityLabel(label)
        .accessibilityValue([reading, unit, detail].filter { !$0.isEmpty }.joined(separator: " "))
    }
}

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
