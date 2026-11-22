import SwiftUI
import AppKit
import UniApiCore

// The Meter kit. Content sits on the canvas on one grid; structure comes from
// alignment, whitespace and hairline rules. A filled `Well` is reserved for
// things you edit or plot. See docs/DESIGN.md.

// ======================================================================
// MARK: - Rules and ticks
// ======================================================================

/// One-point hairline.
struct Rule: View {
    var strong = false
    var vertical = false
    var body: some View {
        (strong ? Theme.ruleStrong : Theme.rule)
            .frame(width: vertical ? 1 : nil, height: vertical ? nil : 1)
            .accessibilityHidden(true)
    }
}

/// Graduated ticks hanging from the top edge, the recurring Meter motif.
/// Either a fixed `step` in points or a number of equal `divisions`.
struct TickScale: Shape {
    var step: CGFloat = 6
    var divisions: Int? = nil
    var major: Int = 5
    var minorHeight: CGFloat = 3
    var majorHeight: CGFloat = 6
    func path(in rect: CGRect) -> Path {
        var path = Path()
        let count: Int
        let gap: CGFloat
        if let divisions, divisions > 0 {
            count = divisions
            gap = (rect.width - 1) / CGFloat(divisions)
        } else {
            gap = max(2, step)
            count = Int((rect.width - 1) / gap)
        }
        guard count >= 0, gap > 0 else { return path }
        for index in 0...count {
            let height = index % max(1, major) == 0 ? majorHeight : minorHeight
            path.addRect(CGRect(x: rect.minX + CGFloat(index) * gap, y: rect.minY, width: 1, height: height))
        }
        return path
    }
}

/// A full-width hairline that starts as a ruler.
struct TickRule: View {
    var span: CGFloat = 120
    var body: some View {
        ZStack(alignment: .topLeading) {
            Rule(strong: true)
            TickScale().fill(Theme.faint).frame(width: span, height: 6)
        }
        .frame(maxWidth: .infinity, alignment: .topLeading).frame(height: 6, alignment: .top)
        .accessibilityHidden(true)
    }
}

/// Engraved caption: column heads, units, eyebrows.
struct MicroLabel: View {
    var text: String
    var color: Color = Theme.muted
    var size: CGFloat = 9.5
    init(_ text: String, color: Color = Theme.muted, size: CGFloat = 9.5) {
        self.text = text; self.color = color; self.size = size
    }
    var body: some View {
        Text(text.uppercased()).font(Theme.label(size)).tracking(size * 0.09)
            .foregroundStyle(color).lineLimit(1)
    }
}

// ======================================================================
// MARK: - Structure
// ======================================================================

/// A named section. The name sits on its own rule: `Name ------- trailing`.
struct Band<Trailing: View, Content: View>: View {
    var title: String
    var hint: String = ""
    var spacing: CGFloat = 14
    @ViewBuilder var trailing: () -> Trailing
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: spacing) {
            HStack(alignment: .center, spacing: 12) {
                Text(title).font(Theme.heading()).foregroundStyle(Theme.ink)
                    .lineLimit(1).fixedSize().accessibilityAddTraits(.isHeader)
                if !hint.isEmpty {
                    Text(hint).font(Theme.ui(11.5)).foregroundStyle(Theme.muted).lineLimit(1)
                }
                Rule().frame(minWidth: 12, maxWidth: .infinity).layoutPriority(-1)
                trailing()
            }
            .frame(minHeight: 28)
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

extension Band where Trailing == EmptyView {
    init(_ title: String, hint: String = "", spacing: CGFloat = 14, @ViewBuilder content: @escaping () -> Content) {
        self.init(title: title, hint: hint, spacing: spacing, trailing: { EmptyView() }, content: content)
    }
}

/// Equal columns that wrap. Every cell in a row gets the row's height.
struct ColumnFlow: Layout {
    var minimum: CGFloat = 150
    var spacing: CGFloat = 24
    var rowSpacing: CGFloat = 24
    var maxColumns: Int = 6

    private func columns(_ width: CGFloat, _ count: Int) -> Int {
        guard count > 0 else { return 1 }
        let fit = Int((width + spacing) / (minimum + spacing))
        return max(1, min(count, min(maxColumns, fit)))
    }
    private func rows(_ width: CGFloat, _ subviews: Subviews) -> (CGFloat, [CGFloat]) {
        let count = columns(width, subviews.count)
        let cell = max(0, (width - spacing * CGFloat(count - 1)) / CGFloat(count))
        var heights: [CGFloat] = []
        var index = 0
        while index < subviews.count {
            let row = subviews[index..<min(subviews.count, index + count)]
            heights.append(row.map { $0.sizeThatFits(ProposedViewSize(width: cell, height: nil)).height }.max() ?? 0)
            index += count
        }
        return (cell, heights)
    }
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width.flatMap { $0.isFinite ? $0 : nil } ?? CGFloat(subviews.count) * (minimum + spacing)
        let (_, heights) = rows(width, subviews)
        return CGSize(width: width, height: heights.reduce(0, +) + rowSpacing * CGFloat(max(0, heights.count - 1)))
    }
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let count = columns(bounds.width, subviews.count)
        let (cell, heights) = rows(bounds.width, subviews)
        var y = bounds.minY
        for (rowIndex, height) in heights.enumerated() {
            for column in 0..<count {
                let index = rowIndex * count + column
                guard index < subviews.count else { break }
                subviews[index].place(at: CGPoint(x: bounds.minX + CGFloat(column) * (cell + spacing), y: y),
                                      anchor: .topLeading, proposal: ProposedViewSize(width: cell, height: height))
            }
            y += height + rowSpacing
        }
    }
}

enum ReadoutSize {
    case hero, large, medium, small
    var points: CGFloat { switch self { case .hero: return 54; case .large: return 34; case .medium: return 24; case .small: return 17 } }
}

/// A reading: engraved label, condensed numerals, unit, one line of detail.
/// It hangs from a rule with a tick; tint the tick to tie it to a series.
struct Readout: View {
    var label: String
    var value: String
    var unit: String = ""
    var detail: String = ""
    var size: ReadoutSize = .large
    var tint: Color? = nil
    var color: Color = Theme.ink
    var ruled: Bool = true
    var delay: Double = 0
    var isolateLayout = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if ruled {
                ZStack(alignment: .topLeading) {
                    Rule()
                    (tint ?? Theme.ink).frame(width: 2, height: 7)
                }
                .frame(height: 7, alignment: .top).padding(.bottom, 9)
            }
            MicroLabel(label)
            HStack(alignment: .firstTextBaseline, spacing: 5) {
                NativeNumberText(text: value, font: Theme.readout(size.points), color: color,
                                 delay: delay, isolateLayout: isolateLayout)
                if !unit.isEmpty { MicroLabel(unit, size: size == .hero ? 11 : 9.5) }
            }
            .padding(.top, size == .hero ? 4 : 5)
            if !detail.isEmpty {
                Text(detail).font(Theme.ui(11.5)).foregroundStyle(Theme.muted)
                    .lineLimit(2).fixedSize(horizontal: false, vertical: true).padding(.top, 4)
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(label)
        .accessibilityValue([value, unit, detail].filter { !$0.isEmpty }.joined(separator: " "))
    }
}

/// A row of readouts on one baseline that wraps on narrow pages.
struct ReadoutStrip<Content: View>: View {
    var minimum: CGFloat = 150
    @ViewBuilder var content: () -> Content
    var body: some View {
        ColumnFlow(minimum: minimum, spacing: 24, rowSpacing: 22) { content() }
    }
}

/// A ledger line. Its text stays on the content edge; the hover and selection
/// fill bleeds eight points into the margins. Selected rows carry the signal tick.
struct LedgerRow<Content: View>: View {
    var selected = false
    var minHeight: CGFloat = 36
    var ruled = true
    var action: (() -> Void)? = nil
    @ViewBuilder var content: () -> Content
    @State private var hovering = false
    @Environment(\.nativeReducedMotion) private var reduceMotion
    @Environment(\.isEnabled) private var enabled

    private var row: some View {
        content()
            .frame(maxWidth: .infinity, minHeight: minHeight, alignment: .leading)
            .background {
                RoundedRectangle(cornerRadius: Theme.radiusControl, style: .continuous)
                    .fill(selected ? Theme.pressed : hovering && action != nil ? Theme.hover : .clear)
                    .padding(.horizontal, -8)
            }
            .overlay(alignment: .leading) {
                if selected { Theme.signal.frame(width: 2, height: 14).offset(x: -8) }
            }
            .overlay(alignment: .bottom) { if ruled { Rule() } }
            .contentShape(Rectangle())
    }
    var body: some View {
        Group {
            if let action {
                Button(action: action) { row }.buttonStyle(.plain).pointingHand(enabled)
                    .accessibilityAddTraits(selected ? .isSelected : [])
            } else { row }
        }
        .onHover { hovering = $0 && enabled }
        .animation(reduceMotion ? nil : NativeMotion.hover, value: hovering)
    }
}

/// Column heads for a ledger: micro labels above a strong rule.
struct LedgerHead<Content: View>: View {
    @ViewBuilder var content: () -> Content
    var body: some View {
        HStack(spacing: 12) { content() }
            .frame(maxWidth: .infinity, minHeight: 24, alignment: .leading)
            .overlay(alignment: .bottom) { Rule(strong: true) }
    }
}

/// Filled ground for an editor, a plot, a transcript or a drop target.
struct Well<Content: View>: View {
    var padding: CGFloat = 16
    var radius: CGFloat = Theme.radiusWell
    @ViewBuilder var content: () -> Content
    var body: some View {
        content()
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.well, in: RoundedRectangle(cornerRadius: radius, style: .continuous))
    }
}

/// A setting: name and one line of consequence on the left, its control on
/// the right, a rule beneath.
struct OptionRow<Control: View>: View {
    var title: String
    var detail: String = ""
    var ruled = true
    @ViewBuilder var control: () -> Control
    var body: some View {
        HStack(alignment: .center, spacing: 20) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(Theme.ui(13, weight: .medium)).foregroundStyle(Theme.ink)
                if !detail.isEmpty {
                    Text(detail).font(Theme.ui(12)).foregroundStyle(Theme.muted)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            control().fixedSize(horizontal: true, vertical: false)
        }
        .padding(.vertical, 11)
        .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
        .overlay(alignment: .bottom) { if ruled { Rule() } }
    }
}

// ======================================================================
// MARK: - Controls
// ======================================================================

enum PressKind { case primary, secondary, quiet, danger }

/// `Button(...).buttonStyle(Press(.primary))`. Primary is solid ink: one per
/// page, for the action the page exists for.
struct Press: ButtonStyle {
    var kind: PressKind = .secondary
    var full = false
    var height: CGFloat = 28
    init(_ kind: PressKind = .secondary, full: Bool = false, height: CGFloat = 28) {
        self.kind = kind; self.full = full; self.height = height
    }
    func makeBody(configuration: Configuration) -> some View {
        PressBody(kind: kind, full: full, height: height, configuration: configuration)
    }
}

private struct PressBody: View {
    var kind: PressKind
    var full: Bool
    var height: CGFloat
    let configuration: ButtonStyleConfiguration
    @State private var hovering = false
    @Environment(\.isEnabled) private var enabled
    @Environment(\.nativeReducedMotion) private var reduceMotion
    @Environment(\.nativeMotionVisible) private var visible
    private var isHovering: Bool { hovering && enabled && visible }

    private var foreground: Color {
        switch kind {
        case .primary: return Theme.onInk
        case .secondary: return Theme.ink
        case .quiet: return isHovering ? Theme.ink : Theme.dim
        case .danger: return isHovering ? Theme.onAccent : Theme.failFg
        }
    }
    private var fill: Color {
        switch kind {
        case .primary: return Theme.ink.opacity(configuration.isPressed ? 0.72 : isHovering ? 0.86 : 1)
        case .secondary: return configuration.isPressed ? Theme.pressed : isHovering ? Theme.hover : .clear
        case .quiet: return configuration.isPressed ? Theme.pressed : isHovering ? Theme.hover : .clear
        case .danger: return isHovering ? Theme.fail : Theme.surfaceFor(Theme.fail)
        }
    }
    var body: some View {
        configuration.label
            .font(Theme.ui(12.5, weight: .medium))
            .foregroundStyle(foreground)
            .lineLimit(1)
            .padding(.horizontal, kind == .quiet ? 8 : 12)
            .frame(height: height)
            .frame(maxWidth: full ? .infinity : nil)
            .background(RoundedRectangle(cornerRadius: Theme.radiusControl, style: .continuous).fill(fill))
            .overlay {
                if kind == .secondary {
                    RoundedRectangle(cornerRadius: Theme.radiusControl, style: .continuous)
                        .strokeBorder(Theme.ruleStrong, lineWidth: 1)
                }
            }
            .alignmentGuide(.firstTextBaseline) { _ in height * 0.64 }
            .alignmentGuide(.lastTextBaseline) { _ in height * 0.64 }
            .contentShape(Rectangle())
            .opacity(enabled ? 1 : 0.4)
            .scaleEffect(configuration.isPressed && !reduceMotion && visible ? 0.98 : 1)
            .animation(reduceMotion || !visible ? nil : NativeMotion.press, value: configuration.isPressed)
            .animation(reduceMotion || !visible ? nil : NativeMotion.hover, value: isHovering)
            .onHover { inside in
                let next = inside && enabled && visible
                if next != hovering { hovering = next }
            }
            .onChange(of: enabled) { _, enabled in if !enabled { hovering = false } }
            .onChange(of: visible) { _, visible in if !visible { hovering = false } }
            .onDisappear { hovering = false }
            .pointingHand(enabled)
    }
}

/// Square quiet button carrying one glyph.
struct IconPress: View {
    var icon: String
    var help: String
    var size: CGFloat = 14
    var active = false
    var action: () -> Void
    @State private var hovering = false
    @Environment(\.isEnabled) private var enabled
    @Environment(\.nativeReducedMotion) private var reduceMotion

    var body: some View {
        Button(action: action) {
            NativeIcon(icon, size: size, strokeWidth: 1.75)
                .foregroundStyle(active || hovering ? Theme.ink : Theme.muted)
                .frame(width: 28, height: 28)
                .background(RoundedRectangle(cornerRadius: Theme.radiusControl, style: .continuous)
                    .fill(active ? Theme.pressed : hovering ? Theme.hover : .clear))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain).opacity(enabled ? 1 : 0.4)
        .onHover { hovering = $0 && enabled }
        .animation(reduceMotion ? nil : NativeMotion.hover, value: hovering)
        .pointingHand(enabled).accessibilityLabel(help).help(help)
    }
}

/// Choose one of a few. Labels stand on a hairline; a signal bar slides to the
/// chosen one.
struct Stops<T: Hashable>: View {
    var options: [(value: T, label: String)]
    var selection: T
    var icons: [T: String] = [:]
    var enabled = true
    var spacing: CGFloat = 18
    var onSelect: (T) -> Void
    @Namespace private var namespace
    @Environment(\.nativeReducedMotion) private var reduceMotion
    @Environment(\.nativeMotionVisible) private var visible
    @Environment(\.isEnabled) private var environmentEnabled

    var body: some View {
        HStack(spacing: spacing) {
            ForEach(options, id: \.value) { option in
                let chosen = option.value == selection
                Button { if enabled { onSelect(option.value) } } label: {
                    StopsLabel(title: option.label, icon: icons[option.value], chosen: chosen)
                        .overlay(alignment: .bottom) {
                            if chosen {
                                Theme.signal.frame(height: 2)
                                    .matchedGeometryEffect(id: "needle", in: namespace)
                            }
                        }
                }
                .buttonStyle(.plain).disabled(!enabled)
                .accessibilityLabel(option.label)
                .accessibilityAddTraits(chosen ? [.isSelected] : [])
                .pointingHand(enabled && environmentEnabled)
            }
        }
        .background(alignment: .bottom) { Rule() }
        .fixedSize(horizontal: true, vertical: false)
        .accessibilityElement(children: .contain)
        .opacity(enabled && environmentEnabled ? 1 : 0.45)
        .animation(reduceMotion || !visible ? nil : NativeMotion.segmented, value: selection)
    }
}

private struct StopsLabel: View {
    var title: String
    var icon: String?
    var chosen: Bool
    @State private var hovering = false
    @Environment(\.isEnabled) private var enabled
    var body: some View {
        HStack(spacing: 6) {
            if let icon { NativeIcon(icon, size: 13, strokeWidth: 1.75) }
            ZStack {
                // The heavier weight always reserves the width, so choosing
                // an option cannot nudge its neighbours.
                Text(title).font(Theme.ui(12.5, weight: .semibold)).hidden()
                Text(title).font(Theme.ui(12.5, weight: chosen ? .semibold : .regular))
            }
        }
        .lineLimit(1).fixedSize()
        .foregroundStyle(chosen || hovering ? Theme.ink : Theme.muted)
        .frame(height: 28)
        .contentShape(Rectangle())
        .onHover { hovering = $0 && enabled }
    }
}

/// A two-position switch, squared like a panel toggle.
struct Flip: View {
    @Binding var isOn: Bool
    var enabled = true
    @Environment(\.nativeReducedMotion) private var reduceMotion
    @Environment(\.isEnabled) private var environmentEnabled

    var body: some View {
        Button {
            guard enabled && environmentEnabled else { return }
            isOn.toggle()
        } label: {
            ZStack(alignment: isOn ? .trailing : .leading) {
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .fill(isOn ? Theme.ink : Theme.track)
                    .overlay {
                        if !isOn {
                            RoundedRectangle(cornerRadius: 4, style: .continuous).strokeBorder(Theme.ruleStrong, lineWidth: 1)
                        }
                    }
                RoundedRectangle(cornerRadius: 2, style: .continuous)
                    .fill(isOn ? Theme.onInk : Theme.muted)
                    .frame(width: 12, height: 12).padding(3)
            }
            .frame(width: 32, height: 18)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain).disabled(!enabled)
        .pointingHand(enabled && environmentEnabled)
        .opacity(enabled && environmentEnabled ? 1 : 0.4)
        .accessibilityAddTraits(.isToggle)
        .accessibilityValue(isOn ? "On" : "Off")
        .animation(reduceMotion ? nil : NativeMotion.toggle, value: isOn)
    }
}

/// Text entry. Focus is marked by the signal color, nothing else moves.
struct Entry: View {
    var placeholder: String
    @Binding var text: String
    var mono = false
    var width: CGFloat? = nil
    var icon: String? = nil
    var autoFocus = false
    var onSubmit: (() -> Void)? = nil
    @FocusState private var focused: Bool
    @Environment(\.nativeReducedMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: 8) {
            if let icon { NativeIcon(icon, size: 13, strokeWidth: 1.75).foregroundStyle(Theme.muted) }
            TextField(placeholder, text: $text)
                .textFieldStyle(.plain)
                .font(mono ? Theme.mono(12) : Theme.ui(13))
                .foregroundStyle(Theme.ink)
                .focused($focused)
                .onSubmit { onSubmit?() }
                .onAppear { if autoFocus { focused = true } }
        }
        .padding(.horizontal, 10)
        .frame(height: 30)
        .frame(width: width)
        .background(RoundedRectangle(cornerRadius: Theme.radiusControl, style: .continuous).fill(Theme.field))
        .overlay(RoundedRectangle(cornerRadius: Theme.radiusControl, style: .continuous)
            .strokeBorder(focused ? Theme.signal : Theme.ruleStrong, lineWidth: 1))
        .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: focused)
    }
}

/// Menu trigger that reads as a value with a caret; AppKit keeps the menu.
struct Pick<Value: Hashable>: View {
    var title: String
    @Binding var selection: Value
    var options: [(value: Value, label: String)]
    var width: CGFloat? = nil
    @Environment(\.isEnabled) private var enabled
    @State private var hovering = false
    var body: some View {
        Menu {
            ForEach(options, id: \.value) { option in
                Button { selection = option.value } label: {
                    if option.value == selection { Label { Text(option.label) } icon: { NativeIcon("check", size: 14) } }
                    else { Text(option.label) }
                }
            }
        } label: {
            HStack(spacing: 8) {
                Text(options.first(where: { $0.value == selection })?.label ?? title).lineLimit(1)
                if width != nil { Spacer(minLength: 0) }
                NativeIcon("chevrons-up-down", size: 12, strokeWidth: 1.75).foregroundStyle(Theme.muted)
            }
            .font(Theme.ui(12.5)).foregroundStyle(Theme.ink)
            .padding(.horizontal, 10).frame(width: width, height: 28)
            .background(hovering ? Theme.hover : .clear, in: RoundedRectangle(cornerRadius: Theme.radiusControl, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: Theme.radiusControl, style: .continuous).strokeBorder(Theme.ruleStrong, lineWidth: 1))
        }
        .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
        .opacity(enabled ? 1 : 0.4).onHover { hovering = $0 && enabled }
        .pointingHand(enabled).accessibilityLabel(title)
    }
}

// ======================================================================
// MARK: - Atoms
// ======================================================================

/// Identifier or state in monospace on a faint ground. A tone colors both.
struct Tag: View {
    var text: String
    var tone: Color? = nil
    var dot = false
    init(_ text: String, tone: Color? = nil, dot: Bool = false) { self.text = text; self.tone = tone; self.dot = dot }
    var body: some View {
        HStack(spacing: 5) {
            if dot { Circle().fill(tone ?? Theme.muted).frame(width: 5, height: 5) }
            Text(text).font(Theme.mono(10.5)).lineLimit(1)
        }
        .foregroundStyle(tone ?? Theme.dim)
        .padding(.horizontal, 6).frame(height: 18)
        .background(RoundedRectangle(cornerRadius: 3, style: .continuous).fill(tone.map { $0.opacity(0.14) } ?? Theme.hover))
    }
}

/// A keyboard shortcut, drawn as its key.
struct KeyCap: View {
    var text: String
    init(_ text: String) { self.text = text }
    var body: some View {
        Text(text).font(Theme.mono(10, weight: .medium)).foregroundStyle(Theme.muted)
            .padding(.horizontal, 5).frame(minWidth: 18, minHeight: 17)
            .overlay(RoundedRectangle(cornerRadius: 3, style: .continuous).strokeBorder(Theme.ruleStrong, lineWidth: 1))
            .accessibilityHidden(true)
    }
}

/// Linear meter. Square ends, an optional tick scale beneath, and the fill
/// sweeps from its previous value rather than from zero on every update.
struct Scale: View {
    var fraction: Double
    var color: Color = Theme.ink
    var height: CGFloat = 4
    var ticks = false
    var spread: ClosedRange<Double>? = nil
    @Environment(\.nativeReducedMotion) private var reduceMotion
    @Environment(\.nativeMotionVisible) private var visible

    var body: some View {
        VStack(spacing: 3) {
            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    Rectangle().fill(Theme.track)
                    if let spread {
                        let lower = NativeMotion.fraction(spread.lowerBound)
                        let upper = NativeMotion.fraction(spread.upperBound)
                        Rectangle().fill(color.opacity(0.25))
                            .frame(width: geometry.size.width * max(0, upper - lower))
                            .offset(x: geometry.size.width * lower)
                    }
                    Rectangle().fill(color)
                        .frame(width: geometry.size.width * NativeMotion.fraction(fraction))
                }
                .clipShape(RoundedRectangle(cornerRadius: 1))
                .animation(reduceMotion || !visible ? nil : NativeMotion.barUpdate, value: fraction)
            }
            .frame(height: height)
            if ticks { TickScale(divisions: 20, major: 5, minorHeight: 2, majorHeight: 4).fill(Theme.faint).frame(height: 4) }
        }
        .accessibilityHidden(true)
    }
}

/// Radial gauge: a 240 degree graduated arc with a signal needle. The reading
/// itself is supplied by the caller as the center content.
struct Dial<Center: View>: View {
    var fraction: Double
    var color: Color = Theme.ink
    var size: CGFloat = 148
    var needle = true
    @ViewBuilder var center: () -> Center
    @Environment(\.nativeReducedMotion) private var reduceMotion
    @Environment(\.nativeMotionVisible) private var visible

    var body: some View {
        let value = NativeMotion.fraction(fraction)
        ZStack {
            DialTicks(count: 40, major: 5).fill(Theme.faint)
            DialArc(to: 1).stroke(Theme.track, style: StrokeStyle(lineWidth: 3, lineCap: .butt)).padding(11)
            DialArc(to: value).stroke(color, style: StrokeStyle(lineWidth: 3, lineCap: .butt)).padding(11)
            if needle {
                Theme.signal.frame(width: 2, height: 15).offset(y: -size / 2 + 9.5)
                    .rotationEffect(.degrees(-120 + 240 * value))
            }
            center()
        }
        .frame(width: size, height: size)
        .animation(reduceMotion || !visible ? nil : NativeMotion.barUpdate, value: value)
    }
}

private struct DialArc: Shape {
    var to: Double
    var animatableData: Double { get { to } set { to = newValue } }
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.addArc(center: CGPoint(x: rect.midX, y: rect.midY), radius: min(rect.width, rect.height) / 2,
                    startAngle: .degrees(150), endAngle: .degrees(150 + 240 * max(0, min(1, to))), clockwise: false)
        return path
    }
}

private struct DialTicks: Shape {
    var count: Int
    var major: Int
    func path(in rect: CGRect) -> Path {
        var path = Path()
        let radius = min(rect.width, rect.height) / 2
        let center = CGPoint(x: rect.midX, y: rect.midY)
        for index in 0...count {
            let angle = (150 + 240 * Double(index) / Double(count)) * .pi / 180
            let length: CGFloat = index % major == 0 ? 6 : 3
            let outer = CGPoint(x: center.x + CGFloat(cos(angle)) * radius, y: center.y + CGFloat(sin(angle)) * radius)
            let inner = CGPoint(x: center.x + CGFloat(cos(angle)) * (radius - length), y: center.y + CGFloat(sin(angle)) * (radius - length))
            path.move(to: outer); path.addLine(to: inner)
        }
        return path.strokedPath(StrokeStyle(lineWidth: 1))
    }
}

/// Where content will be, said plainly: what is missing and the one way to
/// get it. Left-aligned on the content edge, never a centered void.
struct Blank: View {
    var icon: String = "archive"
    var title: String
    var detail: String = ""
    var actionTitle: String? = nil
    var actionIcon: String = "plus"
    var primary = true
    var action: (() -> Void)? = nil

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            NativeIcon(icon, size: 16, strokeWidth: 1.6).foregroundStyle(Theme.muted)
                .frame(width: 32, height: 32)
                .overlay(RoundedRectangle(cornerRadius: Theme.radiusControl, style: .continuous)
                    .strokeBorder(Theme.ruleStrong, style: StrokeStyle(lineWidth: 1, dash: [3, 3])))
            VStack(alignment: .leading, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(title).font(Theme.ui(13, weight: .medium)).foregroundStyle(Theme.ink)
                    if !detail.isEmpty {
                        Text(detail).font(Theme.ui(12.5)).foregroundStyle(Theme.muted).lineSpacing(2)
                            .fixedSize(horizontal: false, vertical: true).frame(maxWidth: 440, alignment: .leading)
                    }
                }.accessibilityElement(children: .combine)
                if let actionTitle, let action {
                    Button(actionTitle, nativeIcon: actionIcon, action: action)
                        .buttonStyle(Press(primary ? .primary : .secondary))
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 20)
    }
}

enum NoticeTone { case info, warn, fail, ok }

/// An inline message that belongs to the content above or below it.
struct Notice: View {
    var text: String
    var tone: NoticeTone = .info
    private var color: Color {
        switch tone { case .info: return Theme.dim; case .warn: return Theme.warnFg; case .fail: return Theme.failFg; case .ok: return Theme.okFg }
    }
    private var icon: String {
        switch tone { case .info: return "info"; case .warn: return "triangle-alert"; case .fail: return "circle-alert"; case .ok: return "circle-check" }
    }
    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 9) {
            NativeIcon(icon, size: 13, strokeWidth: 1.75).foregroundStyle(color).offset(y: 2)
            Text(text).font(Theme.ui(12.5)).foregroundStyle(tone == .info ? Theme.dim : color)
                .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12).padding(.vertical, 9)
        .background(alignment: .leading) { color.frame(width: 2) }
        .background(tone == .info ? Theme.hover : color.opacity(0.10))
        .clipShape(RoundedRectangle(cornerRadius: 3, style: .continuous))
        .accessibilityElement(children: .combine)
    }
}
