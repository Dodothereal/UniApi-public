import SwiftUI
import AppKit
import UniApiCore

// Earlier component names. Each one now draws with the Meter kit so a page
// that has not been rebuilt yet still belongs to the same app. New code uses
// Kit.swift directly; this file shrinks as pages migrate.

struct Card<Content: View>: View {
    @Environment(\.nativeInterfaceDensity) private var density
    var padding: CGFloat = 16
    var radius: CGFloat = Theme.radiusWell
    @ViewBuilder var content: () -> Content
    var body: some View {
        VStack(alignment: .leading, spacing: 0) { content() }
            .padding(padding * density.cardScale)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.well, in: RoundedRectangle(cornerRadius: min(radius, Theme.radiusWell), style: .continuous))
    }
}

struct TopBar<Leading: View, Trailing: View>: View {
    @ViewBuilder var leading: () -> Leading
    @ViewBuilder var trailing: () -> Trailing

    var body: some View {
        HStack(spacing: 8) {
            leading()
            Spacer(minLength: 12)
            trailing()
        }
        .frame(height: 40)
        .padding(.horizontal, 16)
    }
}

/// Page title block: eyebrow, expanded title, actions, then the tick rule.
struct PageHeader<Trailing: View>: View {
    var title: String
    var subtitle: String? = nil
    var eyebrow: String = ""
    var centerTrailing: Bool = false
    @ViewBuilder var trailing: () -> Trailing

    private var heading: some View {
        VStack(alignment: .leading, spacing: 7) {
            if !eyebrow.isEmpty { MicroLabel(eyebrow) }
            Text(title).font(Theme.display()).tracking(-0.4).foregroundStyle(Theme.ink)
                .lineLimit(1).accessibilityAddTraits(.isHeader)
        }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .bottom, spacing: 20) {
                    heading.fixedSize(horizontal: true, vertical: true)
                    Spacer(minLength: 0)
                    HStack(spacing: 8) { trailing() }.fixedSize(horizontal: true, vertical: false)
                }
                VStack(alignment: .leading, spacing: 12) {
                    heading.frame(maxWidth: .infinity, alignment: .leading)
                    HStack(spacing: 8) { trailing() }.frame(maxWidth: .infinity, alignment: .leading)
                }.frame(maxWidth: .infinity, alignment: .leading)
            }
            TickRule().padding(.top, 14)
            if let subtitle {
                Text(subtitle).font(Theme.ui(12.5)).foregroundStyle(Theme.muted)
                    .lineSpacing(2).fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: 620, alignment: .leading).padding(.top, 12)
            }
        }
    }
}

extension PageHeader where Trailing == EmptyView {
    init(title: String, subtitle: String? = nil) {
        self.init(title: title, subtitle: subtitle, centerTrailing: false, trailing: { EmptyView() })
    }
}

struct SectionLabel<Trailing: View>: View {
    var text: String
    @ViewBuilder var trailing: () -> Trailing
    var body: some View {
        HStack(spacing: 12) {
            Text(text).font(Theme.heading()).foregroundStyle(Theme.ink).lineLimit(1).fixedSize()
                .accessibilityAddTraits(.isHeader)
            Rule().frame(minWidth: 12, maxWidth: .infinity)
            trailing()
        }.frame(minHeight: 24)
    }
}

extension SectionLabel where Trailing == EmptyView {
    init(_ text: String) { self.init(text: text, trailing: { EmptyView() }) }
}

/// Title and description on the left, control on the right.
struct SettingRow<Control: View>: View {
    @Environment(\.nativeReducedMotion) private var reduceMotion
    var title: String
    var desc: String? = nil
    /// Every other string this row's description can switch to. They are laid
    /// out invisibly underneath the real one, so the row always occupies the
    /// height of its tallest variant and picking a different option cannot
    /// shove the rest of the page up or down.
    var descVariants: [String] = []
    @ViewBuilder var control: () -> Control

    var body: some View {
        NativeSettingRowLayout() {
            labels
            control().fixedSize(horizontal: true, vertical: false)
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
    private var labels: some View {
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(Theme.ui(Theme.textSm, weight: .medium))
                    .foregroundStyle(Theme.ink)
                if let d = desc {
                    ZStack(alignment: .topLeading) {
                        ForEach(descVariants, id: \.self) { v in
                            descText(v).opacity(0).accessibilityHidden(true)
                        }
                        descText(d).id(d).transition(.opacity)
                    }
                    .animation(reduceMotion ? nil : .easeOut(duration: 0.16), value: d)
                }
            }
    }

    private func descText(_ s: String) -> some View {
        Text(s)
            .font(Theme.ui(Theme.textXs + 0.5))
            .foregroundStyle(Theme.muted)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Measure the control rather than the description's unwrapped ideal width.
/// The same child views retain focus when the row changes between two columns
/// and a stack during window resizing.
private struct NativeSettingRowLayout: Layout {
    private func dimensions(_ width: CGFloat?, _ subviews: Subviews) -> (CGFloat, CGSize, CGSize, Bool) {
        let control = subviews[1].sizeThatFits(.unspecified)
        let available = max(0, width.flatMap { $0.isFinite ? $0 : nil } ?? (220 + 20 + control.width))
        let stacked = available < 220 + 20 + control.width
        let labels = subviews[0].sizeThatFits(ProposedViewSize(width: stacked ? available : max(0, available - 20 - control.width), height: nil))
        return (available, labels, control, stacked)
    }
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard subviews.count == 2 else { return .zero }
        let (width, labels, control, stacked) = dimensions(proposal.width, subviews)
        return CGSize(width: width, height: stacked ? labels.height + 10 + control.height : max(labels.height, control.height))
    }
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard subviews.count == 2 else { return }
        let (_, labels, control, stacked) = dimensions(bounds.width, subviews)
        subviews[0].place(at: bounds.origin, anchor: .topLeading,
                          proposal: ProposedViewSize(width: stacked ? bounds.width : max(0, bounds.width - 20 - control.width), height: labels.height))
        subviews[1].place(at: CGPoint(x: bounds.maxX - control.width, y: bounds.minY + (stacked ? labels.height + 10 : 0)),
                          anchor: .topLeading, proposal: ProposedViewSize(control))
    }
}

enum T3ButtonKind { case primary, outline, ghost, destructive }

struct T3Button: ButtonStyle {
    var kind: T3ButtonKind = .outline
    var full: Bool = false
    init(_ kind: T3ButtonKind = .outline, size: CGFloat = Theme.textXs, full: Bool = false) {
        self.kind = kind; self.full = full
    }
    func makeBody(configuration: Configuration) -> some View {
        let mapped: PressKind = kind == .primary ? .primary : kind == .ghost ? .quiet : kind == .destructive ? .danger : .secondary
        return Press(mapped, full: full).makeBody(configuration: configuration)
    }
}

struct T3IconButton: View {
    var system: String
    var help: String = ""
    var size: CGFloat = 13
    var active: Bool = false
    var action: () -> Void
    var body: some View { IconPress(icon: system, help: help.isEmpty ? system : help, size: size, active: active, action: action) }
}

struct T3Switch: View {
    @Binding var isOn: Bool
    var enabled: Bool = true
    var body: some View { Flip(isOn: $isOn, enabled: enabled) }
}

struct T3Field: View {
    var placeholder: String
    @Binding var text: String
    var mono: Bool = false
    var width: CGFloat? = nil
    var leadingIcon: String? = nil
    var autoFocus = false
    var body: some View { Entry(placeholder: placeholder, text: $text, mono: mono, width: width, icon: leadingIcon, autoFocus: autoFocus) }
}

struct T3Segmented<T: Hashable>: View {
    var options: [(value: T, label: String)]
    var selection: T
    var enabled: Bool = true
    var icons: [T: String] = [:]
    var onSelect: (T) -> Void
    var body: some View { Stops(options: options, selection: selection, icons: icons, enabled: enabled, onSelect: onSelect) }
}

struct MonoChip: View {
    var text: String
    var color: Color = Theme.muted
    var body: some View { Tag(text, tone: color == Theme.muted ? nil : color) }
}

struct StatusDot: View {
    var color: Color
    var size: CGFloat = 6
    var pulse: Bool = false
    var body: some View { NativeStatusDot(color: color, size: size, pulse: pulse) }
}

/// A count with its status dot, pinned to a fixed column.
struct StatCount: View {
    var count: Int
    var label: String
    var color: Color
    var width: CGFloat = 68
    /// Draws the slot but leaves it blank, so a row with nothing to report
    /// still reserves the column and everything after it stays put.
    var placeholder: Bool = false

    var body: some View {
        HStack(spacing: 5) {
            StatusDot(color: color, size: 5)
            Text("\(count) \(label)")
                .font(Theme.mono(11))
                .foregroundStyle(Theme.dim)
                .lineLimit(1)
            Spacer(minLength: 0)
        }
        .opacity(placeholder ? 0 : 1)
        .frame(width: width, alignment: .leading)
    }
}

/// Fixed-width trailing slot for a row's action, so two labels of different
/// length still start at the same x.
struct RowActionLabel: View {
    @Environment(\.nativeReducedMotion) private var reduceMotion
    var title: String
    var active: Bool = false
    var hovering: Bool = false
    var width: CGFloat = 72

    var body: some View {
        Text(title)
            .font(Theme.ui(Theme.textXs, weight: .medium))
            .foregroundStyle(active ? Theme.okFg : (hovering ? Theme.ink : Theme.muted))
            .lineLimit(1)
            .frame(width: width)
            .padding(.vertical, 5)
            .background(RoundedRectangle(cornerRadius: Theme.radiusControl, style: .continuous)
                .fill(active ? Theme.surfaceFor(Theme.ok) : (hovering ? Theme.hover : .clear))
                .overlay(RoundedRectangle(cornerRadius: Theme.radiusMd, style: .continuous)
                    .strokeBorder(active ? .clear : Theme.border, lineWidth: 1)))
            .animation(reduceMotion ? nil : NativeMotion.hover, value: hovering)
    }
}

extension View {
    /// Reserve a fixed slot in a row's right rail. Pair with `.hidden()`-style
    /// placeholders rather than `if` so the column survives an empty row.
    func railSlot(_ width: CGFloat) -> some View {
        frame(width: width, alignment: .trailing)
    }
}
