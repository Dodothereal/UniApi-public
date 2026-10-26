import SwiftUI
import AppKit
import UniApiCore

// Native counterpart of client/src/theme.css. Dynamic NSColors resolve against
// the hosting window's appearance; no global theme mutation is needed. The shell
// can apply .nativeAppearance(.system/.light/.dark) to its root view.
enum NativeAppearance: String, CaseIterable, Identifiable {
    case system, light, dark
    var id: String { rawValue }
    var colorScheme: ColorScheme? {
        switch self { case .system: return nil; case .light: return .light; case .dark: return .dark }
    }
    var appKitAppearance: NSAppearance? {
        switch self {
        case .system: return nil
        case .light: return NSAppearance(named: .aqua)
        case .dark: return NSAppearance(named: .darkAqua)
        }
    }
}

enum NativeInterfaceDensity: String {
    case compact, standard, spacious
    var pageGap: CGFloat { self == .compact ? 20 : self == .spacious ? 28 : 24 }
    var pageMargin: CGFloat { self == .compact ? 22 : self == .spacious ? 30 : 26 }
    var cardScale: CGFloat { self == .compact ? 0.85 : self == .spacious ? 1.15 : 1 }
}

private struct NativeInterfaceDensityKey: EnvironmentKey {
    static let defaultValue = NativeInterfaceDensity.standard
}

extension EnvironmentValues {
    var nativeInterfaceDensity: NativeInterfaceDensity {
        get { self[NativeInterfaceDensityKey.self] }
        set { self[NativeInterfaceDensityKey.self] = newValue }
    }
}

enum Theme {
    static func adaptive(light: UInt32, dark: UInt32,
                         lightAlpha: Double = 1, darkAlpha: Double = 1) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            let hex = isDark ? dark : light
            return NSColor(srgbRed: Double((hex >> 16) & 255) / 255,
                           green: Double((hex >> 8) & 255) / 255,
                           blue: Double(hex & 255) / 255,
                           alpha: isDark ? darkAlpha : lightAlpha)
        })
    }
    static let bg = adaptive(light: 0xfcfcfc, dark: 0x0a0a0a)
    static let surface = adaptive(light: 0xffffff, dark: 0x111111)
    static let popover = adaptive(light: 0xffffff, dark: 0x191919)
    static let ink = adaptive(light: 0x18181b, dark: 0xf5f5f5)
    static let dim = adaptive(light: 0x47464e, dark: 0xa8a8a8)
    static let muted = adaptive(light: 0x71717b, dark: 0x818181)
    static let subtle = adaptive(light: 0x000000, dark: 0xffffff, lightAlpha: 0.04, darkAlpha: 0.04)
    static let subtle2 = adaptive(light: 0x000000, dark: 0xffffff, lightAlpha: 0.07, darkAlpha: 0.07)
    static let border = adaptive(light: 0xe4e4e7, dark: 0xffffff, darkAlpha: 0.06)
    static let input = adaptive(light: 0xd4d4d8, dark: 0xffffff, darkAlpha: 0.08)
    static let field = adaptive(light: 0xffffff, dark: 0xffffff, darkAlpha: 0.035)
    static let well = adaptive(light: 0x000000, dark: 0x000000, lightAlpha: 0.04, darkAlpha: 0.3)
    static let track = adaptive(light: 0x000000, dark: 0xffffff, lightAlpha: 0.07, darkAlpha: 0.05)
    static let segTrack = adaptive(light: 0x000000, dark: 0x000000, lightAlpha: 0.045, darkAlpha: 0.5)
    static let grid = adaptive(light: 0x000000, dark: 0xffffff, lightAlpha: 0.07, darkAlpha: 0.06)
    static let baseline = adaptive(light: 0x000000, dark: 0xffffff, lightAlpha: 0.12, darkAlpha: 0.08)
    static let crosshair = adaptive(light: 0x000000, dark: 0xf5f5f5, lightAlpha: 0.28, darkAlpha: 0.18)
    static let shadow = adaptive(light: 0x000000, dark: 0x000000, lightAlpha: 0.12, darkAlpha: 0.55)
    static let overlay = adaptive(light: 0x000000, dark: 0x000000, lightAlpha: 0.28, darkAlpha: 0.55)
    static let accent = adaptive(light: 0x1447e6, dark: 0x346bf1)
    static let link = adaptive(light: 0x1447e6, dark: 0x8fb2ff)
    static let onAccent = Color.white
    static let controlStroke = Color.white.opacity(0.12)
    static let controlShadow = Color.black.opacity(0.3)
    static let ok = Color(hex: 0x00bc7d)
    static let okFg = adaptive(light: 0x047857, dark: 0x00d492)
    static let warn = Color(hex: 0xfe9a00)
    static let warnFg = adaptive(light: 0xbb4d00, dark: 0xffb900)
    static let fail = Color(hex: 0xfb2c36)
    static let failFg = adaptive(light: 0xc10007, dark: 0xff6467)
    static let sidebarAccent = adaptive(light: 0xf1f1f4, dark: 0x191a1d)
    static let sidebarBG = bg
    static let sidebarInk = adaptive(light: 0x18181b, dark: 0xf1f3f7)
    static let sidebarMuted = adaptive(light: 0x71717b, dark: 0xa3a3a3)
    static let sidebarBorder = adaptive(light: 0xe4e4e7, dark: 0xffffff, darkAlpha: 0.08)
    static func surfaceFor(_ color: Color) -> Color { color.opacity(0.16) }
    static let radiusSm: CGFloat = 6
    static let radiusMd: CGFloat = 8
    static let radius: CGFloat = 10
    static let textXs: CGFloat = 12
    static let textSm: CGFloat = 14
    static let textBase: CGFloat = 16
    static let textLg: CGFloat = 18
    static let text2Xl: CGFloat = 24
    // Same saturated hues and UTF-16 hash as the current web results/stats kit.
    static let pairPalette: [Color] = [
        0x3b82f6, 0xf97316, 0x10b981, 0xa855f7, 0xf59e0b, 0xec4899,
        0x06b6d4, 0x84cc16, 0xef4444, 0x6366f1, 0xd946ef, 0xeab308,
    ].map { Color(hex: UInt32($0)) }
    static func pairColor(_ key: String) -> Color {
        let hash = key.utf16.reduce(UInt32(0)) { ($0 &* 31) &+ UInt32($1) }
        return pairPalette[Int(hash % UInt32(pairPalette.count))]
    }
    static func mono(_ size: CGFloat, weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight, design: .monospaced)
    }
    static func ui(_ size: CGFloat, weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight)
    }
}

extension View {
    func nativeAppearance(_ appearance: NativeAppearance) -> some View {
        preferredColorScheme(appearance.colorScheme)
    }
}

extension Color {
    init(hex: UInt32) {
        self.init(.sRGB,
                  red: Double((hex >> 16) & 0xFF) / 255.0,
                  green: Double((hex >> 8) & 0xFF) / 255.0,
                  blue: Double(hex & 0xFF) / 255.0,
                  opacity: 1.0)
    }
}

// ======================================================================
// MARK: - Cursor
// ======================================================================

/// Transparent AppKit view that owns a cursor rect. Used on macOS 14, where
/// SwiftUI has no pointer API; clicks pass straight through to the SwiftUI
/// control underneath because hitTest returns nil.
private struct CursorHost: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { HandView() }
    func updateNSView(_ v: NSView, context: Context) {
        v.window?.invalidateCursorRects(for: v)
    }

    final class HandView: NSView {
        override func resetCursorRects() {
            addCursorRect(bounds, cursor: .pointingHand)
        }
        override func updateTrackingAreas() {
            super.updateTrackingAreas()
            trackingAreas.forEach(removeTrackingArea)
            addTrackingArea(NSTrackingArea(
                rect: .zero,
                options: [.activeInActiveApp, .inVisibleRect, .cursorUpdate],
                owner: self))
        }
        override func cursorUpdate(with event: NSEvent) { NSCursor.pointingHand.set() }
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }
}

extension View {
    /// The pointing hand every clickable thing on the web gets for free.
    /// Baked into the shared controls below so call sites rarely need it.
    @ViewBuilder
    func pointingHand(_ on: Bool = true) -> some View {
        if #available(macOS 15.0, *) {
            self.pointerStyle(on ? .link : nil)
        } else {
            self.overlay { if on { CursorHost().allowsHitTesting(false) } }
        }
    }
}

// ======================================================================
// MARK: - Containers
// ======================================================================

/// `bg-card border rounded-lg` - T3 only boxes things that are genuinely a
/// unit (a table, a chart, a selectable tile). Settings-style content stays
/// flat on the canvas; use `SettingRow` for that.
struct Card<Content: View>: View {
    @Environment(\.nativeInterfaceDensity) private var density
    var padding: CGFloat = 16
    var radius: CGFloat = Theme.radius
    @ViewBuilder var content: () -> Content
    var body: some View {
        VStack(alignment: .leading, spacing: 0) { content() }
            .padding(padding * density.cardScale)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.surface)
            .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .strokeBorder(Theme.border, lineWidth: 1)
            )
    }
}

// ======================================================================
// MARK: - Page furniture
// ======================================================================

/// Compatibility container for shell chrome. Page actions belong in NativePage
/// content; this must not be installed as a fixed page toolbar.
///
/// This used to carry a `UniApi / <page>` breadcrumb. With four flat
/// destinations there is no hierarchy for crumbs to describe: the first was
/// always "UniApi" and the second always repeated the highlighted sidebar row
/// AND the `PageHeader` title an inch below it. So the bar now carries only
/// things you can act on - the sidebar toggle when the sidebar is shut, and
/// the page's own tools on the right.
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

/// Big page title + optional muted description, T3 settings-page style.
struct PageHeader<Trailing: View>: View {
    var title: String
    var subtitle: String? = nil
    /// Tall trailing content (a badge, not a button) reads better centred on
    /// the whole title block than baselined to the title's first line.
    var centerTrailing: Bool = false
    @ViewBuilder var trailing: () -> Trailing

    private var heading: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(Theme.ui(22, weight: .semibold)).tracking(-0.22).foregroundStyle(Theme.ink)
                .accessibilityAddTraits(.isHeader)
            if let subtitle {
                Text(subtitle).font(Theme.ui(12.5)).foregroundStyle(Theme.muted)
                    .lineSpacing(3).fixedSize(horizontal: false, vertical: true)
            }
        }
    }
    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: centerTrailing ? .center : .firstTextBaseline, spacing: 20) {
                heading.fixedSize(horizontal: true, vertical: true)
                Spacer(minLength: 0)
                HStack(spacing: 10) { trailing() }.fixedSize(horizontal: true, vertical: false)
            }
            VStack(alignment: .leading, spacing: 12) {
                heading.frame(maxWidth: .infinity, alignment: .leading)
                HStack(spacing: 10) { trailing() }.frame(maxWidth: .infinity, alignment: .trailing)
            }.frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

extension PageHeader where Trailing == EmptyView {
    init(title: String, subtitle: String? = nil) {
        self.init(title: title, subtitle: subtitle, centerTrailing: false,
                  trailing: { EmptyView() })
    }
}

/// Small label that introduces a group of rows ("Color scheme", "Themes").
struct SectionLabel<Trailing: View>: View {
    var text: String
    @ViewBuilder var trailing: () -> Trailing
    var body: some View {
        HStack(spacing: 8) {
            Text(text)
                .font(Theme.ui(Theme.textSm, weight: .medium))
                .foregroundStyle(Theme.ink)
            Spacer(minLength: 8)
            trailing()
        }
    }
}

extension SectionLabel where Trailing == EmptyView {
    init(_ text: String) { self.init(text: text, trailing: { EmptyView() }) }
}

/// The core T3 settings primitive: title + description on the left, control on
/// the right, no box and no divider. Vertical rhythm alone separates rows.
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

// ======================================================================
// MARK: - Controls
// ======================================================================

enum T3ButtonKind { case primary, outline, ghost, destructive }

/// `Button(...).buttonStyle(T3Button(.outline))`
struct T3Button: ButtonStyle {
    var kind: T3ButtonKind = .outline
    var size: CGFloat = Theme.textXs
    var full: Bool = false
    init(_ kind: T3ButtonKind = .outline, size: CGFloat = Theme.textXs, full: Bool = false) {
        self.kind = kind; self.size = size; self.full = full
    }

    func makeBody(configuration: Configuration) -> some View {
        T3ButtonBody(kind: kind, size: size, full: full, configuration: configuration)
    }
}

private struct T3ButtonBody: View {
    var kind: T3ButtonKind
    var size: CGFloat
    var full: Bool
    let configuration: ButtonStyleConfiguration
    @State private var hovering = false
    @Environment(\.isEnabled) private var enabled
    @Environment(\.nativeReducedMotion) private var reduceMotion
    @Environment(\.nativeMotionVisible) private var visible
    private var isHovering: Bool { hovering && enabled && visible }

    private var fg: Color {
        switch kind {
        case .primary: return Theme.onAccent
        case .outline: return isHovering ? Theme.ink : Theme.dim
        case .ghost: return isHovering ? Theme.ink : Theme.muted
        case .destructive: return Theme.onAccent
        }
    }
    private var bg: Color {
        switch kind {
        case .primary: return Theme.accent.opacity(configuration.isPressed ? 0.8 : (isHovering ? 1.0 : 0.92))
        case .outline: return isHovering ? Theme.subtle2 : Theme.subtle
        case .ghost: return isHovering ? Theme.subtle : .clear
        case .destructive: return Theme.fail.opacity(configuration.isPressed ? 0.8 : (isHovering ? 1.0 : 0.92))
        }
    }
    private var stroke: Color {
        switch kind {
        case .primary, .destructive: return Theme.controlStroke
        case .outline: return Theme.input
        case .ghost: return .clear
        }
    }

    var body: some View {
        configuration.label
            .font(Theme.ui(size, weight: .medium))
            .foregroundStyle(fg)
            .lineLimit(1)
            .padding(.horizontal, kind == .ghost ? 8 : 11)
            .frame(height: 28)
            .frame(maxWidth: full ? .infinity : nil)
            .background(
                RoundedRectangle(cornerRadius: Theme.radiusMd, style: .circular).fill(bg)
            )
            .overlay(
                RoundedRectangle(cornerRadius: Theme.radiusMd, style: .circular)
                    .strokeBorder(stroke, lineWidth: 1)
            )
            // Mixed Text, Label and icon-row labels must expose one control
            // baseline to surrounding header and form stacks.
            .alignmentGuide(.firstTextBaseline) { _ in 18 }
            .alignmentGuide(.lastTextBaseline) { _ in 18 }
            .opacity(enabled ? 1 : 0.45)
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

/// Square ghost icon button - the panel toggles in T3's toolbar.
struct T3IconButton: View {
    @Environment(\.isEnabled) private var enabled
    @Environment(\.nativeReducedMotion) private var reduceMotion
    @Environment(\.nativeMotionVisible) private var visible
    var system: String
    var help: String = ""
    var size: CGFloat = 13
    var active: Bool = false
    var action: () -> Void
    @State private var hovering = false
    private var isHovering: Bool { hovering && enabled && visible }

    var body: some View {
        Button(action: action) {
            NativeIcon(systemName: system, size: size)
                .foregroundStyle(active || isHovering ? Theme.ink : Theme.muted)
                .frame(width: 28, height: 28)
                .background(
                    RoundedRectangle(cornerRadius: Theme.radiusMd, style: .continuous)
                        .fill(active ? Theme.subtle2 : (isHovering ? Theme.subtle : .clear))
                )
        }
        .buttonStyle(.plain)
        .opacity(enabled ? 1 : 0.45)
        .onHover { inside in
            let next = inside && enabled && visible
            if next != hovering { hovering = next }
        }
        .animation(reduceMotion || !visible ? nil : NativeMotion.hover, value: isHovering)
        .onChange(of: enabled) { _, enabled in if !enabled { hovering = false } }
        .onChange(of: visible) { _, visible in if !visible { hovering = false } }
        .onDisappear { hovering = false }
        .pointingHand(enabled)
        .accessibilityLabel(help.isEmpty ? system : help)
        .help(help)
    }
}

/// T3's pill switch: primary when on, `--input` track when off.
struct T3Switch: View {
    @Environment(\.nativeReducedMotion) private var reduceMotion
    @Environment(\.isEnabled) private var environmentEnabled
    @Binding var isOn: Bool
    var enabled: Bool = true

    var body: some View {
        Button {
            guard enabled && environmentEnabled else { return }
            isOn.toggle()
        } label: {
            ZStack(alignment: isOn ? .trailing : .leading) {
                Capsule()
                    .fill(isOn ? Theme.accent : Theme.input)
                    .frame(width: 34, height: 19)
                Circle()
                    .fill(Theme.onAccent)
                    .frame(width: 15, height: 15)
                    .padding(.horizontal, 2)
                    .shadow(color: Theme.controlShadow, radius: 1, y: 0.5)
            }
            .frame(width: 34, height: 19)
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .pointingHand(enabled && environmentEnabled)
        .opacity(enabled && environmentEnabled ? 1 : 0.45)
        .accessibilityValue(isOn ? "On" : "Off")
        .animation(reduceMotion ? nil : NativeMotion.toggle, value: isOn)
    }
}

/// Appearance-aware field; AppKit retains the standard keyboard focus behavior.
struct T3Field: View {
    @Environment(\.nativeReducedMotion) private var reduceMotion
    var placeholder: String
    @Binding var text: String
    var mono: Bool = false
    var width: CGFloat? = nil
    var leadingIcon: String? = nil
    var autoFocus = false
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 8) {
            if let leadingIcon { NativeIcon(leadingIcon, size: 11).foregroundStyle(Theme.muted) }
            TextField(placeholder, text: $text)
                .textFieldStyle(.plain)
                .font(mono ? Theme.mono(Theme.textXs) : Theme.ui(Theme.textSm - 1))
                .foregroundStyle(Theme.ink)
                .focused($focused)
                .onAppear { if autoFocus { focused = true } }
        }
            .padding(.horizontal, 11)
            .frame(height: leadingIcon == nil ? 30 : 32)
            .frame(width: width)
            .background(
                RoundedRectangle(cornerRadius: Theme.radiusMd, style: .continuous)
                    .fill(Theme.field)
            )
            .overlay(
                RoundedRectangle(cornerRadius: Theme.radiusMd, style: .continuous)
                    .strokeBorder(focused ? Theme.accent.opacity(0.7) : Theme.input, lineWidth: 1)
            )
            .animation(reduceMotion ? nil : .easeOut(duration: 0.15), value: focused)
    }
}

/// Segmented control. T3 uses this shape for the color-scheme row; the thumb is
/// a `--muted` surface with an `--input` hairline.
struct T3Segmented<T: Hashable>: View {
    @Environment(\.nativeReducedMotion) private var reduceMotion
    @Environment(\.nativeMotionVisible) private var visible
    @Environment(\.isEnabled) private var environmentEnabled
    var options: [(value: T, label: String)]
    var selection: T
    var enabled: Bool = true
    var icons: [T: String] = [:]
    var onSelect: (T) -> Void
    @Namespace private var ns

    var body: some View {
        HStack(spacing: 2) {
            ForEach(options, id: \.value) { opt in
                let sel = opt.value == selection
                Button { if enabled { onSelect(opt.value) } } label: {
                    Group {
                        if let icon = icons[opt.value] {
                            HStack(spacing: 6) { NativeIcon(icon, size: 12); Text(opt.label) }
                        } else { Text(opt.label) }
                    }
                        .font(Theme.ui(Theme.textXs, weight: sel ? .medium : .regular))
                        // A segment is a control, not prose: in a tight card
                        // header it must push back on its neighbours rather
                        // than wrap "Responses" into two lines.
                        .lineLimit(1)
                        .fixedSize(horizontal: true, vertical: false)
                        .padding(.horizontal, 11)
                        .padding(.vertical, 5)
                        .background {
                            if sel {
                                RoundedRectangle(cornerRadius: Theme.radiusSm, style: .continuous)
                                    .fill(Theme.subtle2)
                                    .overlay(RoundedRectangle(cornerRadius: Theme.radiusSm,
                                                              style: .continuous)
                                        .strokeBorder(Theme.input, lineWidth: 1))
                                    .matchedGeometryEffect(id: "seg-thumb", in: ns)
                            }
                        }
                        .contentShape(Rectangle())
                }
                .buttonStyle(T3SegmentButton(selected: sel))
                .disabled(!enabled)
                .accessibilityLabel(opt.label)
                .accessibilityAddTraits(sel ? [.isSelected] : [])
                .pointingHand(enabled && environmentEnabled)
            }
        }
        .padding(3)
        .accessibilityElement(children: .contain)
        .background(RoundedRectangle(cornerRadius: Theme.radiusMd, style: .continuous)
            .fill(Theme.segTrack))
        .overlay(RoundedRectangle(cornerRadius: Theme.radiusMd, style: .continuous)
            .strokeBorder(Theme.border, lineWidth: 1))
        .opacity(enabled && environmentEnabled ? 1 : 0.5)
        .animation(reduceMotion || !visible ? nil : NativeMotion.segmented, value: selection)
    }
}

/// A segment owns its hover/press surface. Hovering one option must not publish
/// state on the segmented group or a page that embeds it in a chart heading.
private struct T3SegmentButton: ButtonStyle {
    let selected: Bool
    func makeBody(configuration: Configuration) -> some View {
        T3SegmentButtonBody(selected: selected, configuration: configuration)
    }
}

private struct T3SegmentButtonBody: View {
    let selected: Bool
    let configuration: ButtonStyleConfiguration
    @State private var hovering = false
    @Environment(\.isEnabled) private var enabled
    @Environment(\.nativeReducedMotion) private var reduceMotion
    @Environment(\.nativeMotionVisible) private var visible
    private var isHovering: Bool { hovering && enabled && visible }

    var body: some View {
        configuration.label
            .foregroundStyle(selected || isHovering ? Theme.ink : Theme.muted)
            .background {
                RoundedRectangle(cornerRadius: Theme.radiusSm, style: .continuous)
                    .fill(isHovering && !selected ? Theme.subtle : .clear)
            }
            .scaleEffect(configuration.isPressed && !reduceMotion && visible ? 0.98 : 1)
            .animation(reduceMotion || !visible ? nil : NativeMotion.hover, value: isHovering)
            .animation(reduceMotion || !visible ? nil : NativeMotion.press, value: configuration.isPressed)
            .onHover { inside in
                let next = inside && enabled && visible
                if next != hovering { hovering = next }
            }
            .onChange(of: enabled) { _, enabled in if !enabled { hovering = false } }
            .onChange(of: visible) { _, visible in if !visible { hovering = false } }
            .onDisappear { hovering = false }
    }
}

// ======================================================================
// MARK: - Inline atoms
// ======================================================================

/// The `claude-bai` style id chip: mono, muted, faint surface.
struct MonoChip: View {
    var text: String
    var color: Color = Theme.muted
    var body: some View {
        Text(text)
            .font(Theme.mono(Theme.textXs - 1))
            .foregroundStyle(color)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(RoundedRectangle(cornerRadius: 5, style: .continuous)
                .fill(color == Theme.muted ? Theme.subtle : color.opacity(0.14)))
    }
}

/// The little colored dot T3 overlays on provider icons.
struct StatusDot: View {
    var color: Color
    var size: CGFloat = 6
    var pulse: Bool = false
    var body: some View { NativeStatusDot(color: color, size: size, pulse: pulse) }
}

// ======================================================================
// MARK: - Right rail
// ======================================================================
//
// Everything a list row puts to the right of its title has to sit in a column
// of a fixed width. Intrinsically-sized content packed against a trailing edge
// looks aligned only while every row happens to be the same length: "15 ok"
// pushes its dot further left than "8 ok", a missing failure count deletes a
// whole slot, and "Viewing" shifts the button that "View" left behind. The
// atoms below pin the width so a row's neighbours never move.

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
            .background(RoundedRectangle(cornerRadius: Theme.radiusMd, style: .continuous)
                .fill(active ? Theme.surfaceFor(Theme.ok) : (hovering ? Theme.subtle2 : .clear))
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
