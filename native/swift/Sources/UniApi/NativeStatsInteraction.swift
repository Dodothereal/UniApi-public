import SwiftUI

/// A `Readout` whose numerals are on screen in the first frame. Statistics
/// snapshots arrive complete, so a reading only rolls when its value changes.
struct NativeStatsReadout: View {
    let label: String
    let value: Double?
    var unit = ""
    var detail = ""
    var size: ReadoutSize = .large
    var tint: Color? = nil
    var format: (Double) -> String = NativeNumberFormat.decimal
    private var reading: String { value.flatMap { $0.isFinite ? format($0) : nil } ?? "--" }
    private var measured: Bool { value.map(\.isFinite) ?? false }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ZStack(alignment: .topLeading) {
                Rule()
                (tint ?? Theme.ink).frame(width: 2, height: 7)
            }
            .frame(height: 7, alignment: .top).padding(.bottom, 9)
            MicroLabel(label)
            HStack(alignment: .firstTextBaseline, spacing: 5) {
                Text(reading).font(Theme.readout(size.points)).monospacedDigit().lineLimit(1)
                    .foregroundStyle(measured ? Theme.ink : Theme.faint)
                    .nativeStatsNumberTransition(value)
                if !unit.isEmpty && measured { MicroLabel(unit) }
            }
            .padding(.top, 5)
            if !detail.isEmpty {
                Text(detail).font(Theme.ui(11.5)).foregroundStyle(Theme.muted)
                    .lineLimit(2).fixedSize(horizontal: false, vertical: true).padding(.top, 4)
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .accessibilityElement(children: .ignore).accessibilityLabel(label)
        .accessibilityValue([measured ? reading : "Unavailable", measured ? unit : "", detail].filter { !$0.isEmpty }.joined(separator: " "))
    }
}

/// One measured whole, cut into its parts on a graduated tape. Parts keep
/// their order, so a refreshed reading slides its boundaries instead of
/// reshuffling them.
struct NativeStatsTape: View {
    struct Part: Identifiable, Equatable {
        var id: String
        var value: Double
        var color: Color
    }
    var parts: [Part]
    var height: CGFloat = 10
    @Environment(\.nativeReducedMotion) private var reduceMotion
    @Environment(\.nativeMotionVisible) private var visible

    var body: some View {
        let total = parts.reduce(0) { $0 + max(0, $1.value) }
        VStack(alignment: .leading, spacing: 4) {
            GeometryReader { geometry in
                HStack(spacing: 0) {
                    ForEach(parts) { part in
                        Rectangle().fill(part.color)
                            .frame(width: total > 0 ? geometry.size.width * CGFloat(max(0, part.value) / total) : 0)
                    }
                }
                .frame(width: geometry.size.width, height: height, alignment: .leading)
                .background(Theme.track)
                .animation(reduceMotion || !visible ? nil : NativeMotion.barUpdate, value: parts)
            }
            .frame(height: height)
            TickScale(divisions: 100, major: 10, minorHeight: 3, majorHeight: 6).fill(Theme.faint).frame(height: 6)
            HStack(spacing: 0) {
                Text("0").frame(maxWidth: .infinity, alignment: .leading)
                Text("50").frame(maxWidth: .infinity, alignment: .center)
                Text("100 %").frame(maxWidth: .infinity, alignment: .trailing)
            }
            .font(Theme.mono(10.5)).foregroundStyle(Theme.faint)
        }
        .accessibilityHidden(true)
    }
}

/// A `Band` whose hint is drawn: the name, one line on how to read the
/// section, the rule, then the section's own control. The hint is the first
/// thing to go when the width runs out.
struct NativeStatsBand<Trailing: View, Content: View>: View {
    var title: String
    var hint: String = ""
    var spacing: CGFloat = 14
    @ViewBuilder var trailing: () -> Trailing
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: spacing) {
            ViewThatFits(in: .horizontal) {
                if !hint.isEmpty { header(hinted: true) }
                header(hinted: false)
            }
            .frame(minHeight: 28)
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
    private func header(hinted: Bool) -> some View {
        HStack(alignment: .center, spacing: 12) {
            Text(title).font(Theme.heading()).foregroundStyle(Theme.ink)
                .lineLimit(1).fixedSize().accessibilityAddTraits(.isHeader)
            if hinted {
                Text(hint).font(Theme.ui(11.5)).foregroundStyle(Theme.muted).lineLimit(1).fixedSize()
            }
            Rule().frame(minWidth: 12, maxWidth: .infinity)
            trailing()
        }
    }
}

extension NativeStatsBand where Trailing == EmptyView {
    init(_ title: String, hint: String = "", spacing: CGFloat = 14, @ViewBuilder content: @escaping () -> Content) {
        self.init(title: title, hint: hint, spacing: spacing, trailing: { EmptyView() }, content: content)
    }
}

/// A quiet control that a panel grows from.
struct NativeStatsDisclosure<Content: View>: View {
    let title: String
    var summary: String = ""
    var openLabel: String = ""
    var closeLabel: String = ""
    @ViewBuilder var content: () -> Content
    @State private var expanded = false
    @State private var hovering = false
    @Environment(\.nativeReducedMotion) private var reduceMotion

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(reduceMotion ? nil : .easeOut(duration: 0.16)) { expanded.toggle() }
            } label: {
                HStack(spacing: 8) {
                    NativeIcon("chevron-right", size: 12, strokeWidth: 1.75)
                        .foregroundStyle(hovering || expanded ? Theme.ink : Theme.muted)
                        .rotationEffect(.degrees(expanded ? 90 : 0))
                    Text(title).font(Theme.ui(12.5, weight: .medium)).foregroundStyle(hovering || expanded ? Theme.ink : Theme.dim)
                        .lineLimit(1).fixedSize()
                    if !summary.isEmpty {
                        Text(summary).font(Theme.ui(11.5)).foregroundStyle(Theme.muted).lineLimit(1)
                    }
                    Spacer(minLength: 0)
                }
                .frame(minHeight: 28).contentShape(Rectangle())
            }
            .buttonStyle(.plain).pointingHand()
            .onHover { hovering = $0 }
            .accessibilityLabel(expanded ? (closeLabel.isEmpty ? title : closeLabel) : (openLabel.isEmpty ? title : openLabel))
            .accessibilityValue(expanded ? "Expanded" : "Collapsed")
            if expanded {
                content().padding(.top, 10).padding(.leading, 20)
                    .transition(.opacity)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

extension View {
    /// Actual readings stay visible on first paint. Only a subsequent semantic
    /// number change rolls; there is no delayed text state or per-cell AppKit host.
    func nativeStatsNumberTransition(_ value: Double?) -> some View {
        modifier(NativeStatsNumberTransition(value: value.flatMap { $0.isFinite ? $0 : nil }))
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
