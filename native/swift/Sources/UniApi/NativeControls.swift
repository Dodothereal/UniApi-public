import SwiftUI
import AppKit
import UniApiCore

// ======================================================================
// MARK: - Buttons
// ======================================================================

/// Ink carries the one primary action of a view. Outline is the default for
/// everything else, ghost for actions that repeat on every row, destructive
/// for actions that remove something.
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
    private var height: CGFloat { size >= 14 ? Theme.controlLg : size <= 11 ? Theme.controlXs : Theme.control }

    private var fg: Color {
        switch kind {
        case .primary: return Theme.onInk
        case .outline: return Theme.ink
        case .ghost: return isHovering ? Theme.ink : Theme.dim
        case .destructive: return Theme.failFg
        }
    }
    private var fill: Color {
        switch kind {
        case .primary: return Theme.ink.opacity(configuration.isPressed ? 0.78 : isHovering ? 0.88 : 1)
        case .outline: return isHovering ? Theme.raised : Theme.surface
        case .ghost: return configuration.isPressed ? Theme.subtle2 : isHovering ? Theme.subtle : .clear
        case .destructive: return isHovering ? Theme.surfaceFor(Theme.fail) : .clear
        }
    }
    private var stroke: Color {
        switch kind {
        case .primary, .ghost: return .clear
        case .outline: return isHovering ? Theme.input : Theme.border
        case .destructive: return Theme.fail.opacity(isHovering ? 0.55 : 0.32)
        }
    }

    var body: some View {
        configuration.label
            .font(Theme.ui(size, weight: .medium))
            .foregroundStyle(fg)
            .lineLimit(1)
            .padding(.horizontal, size >= 14 ? 14 : 10)
            .frame(maxWidth: full ? .infinity : nil)
            .frame(height: height)
            .background(RoundedRectangle(cornerRadius: Theme.radiusMd, style: .continuous).fill(fill))
            .overlay(RoundedRectangle(cornerRadius: Theme.radiusMd, style: .continuous).strokeBorder(stroke, lineWidth: 1))
            .contentShape(RoundedRectangle(cornerRadius: Theme.radiusMd, style: .continuous))
            // Mixed Text, Label and icon-row labels must expose one control
            // baseline to surrounding header and form stacks.
            .alignmentGuide(.firstTextBaseline) { _ in height * 0.645 }
            .alignmentGuide(.lastTextBaseline) { _ in height * 0.645 }
            .opacity(enabled ? 1 : 0.4)
            .scaleEffect(configuration.isPressed && !reduceMotion && visible ? 0.97 : 1)
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

/// Square icon button. `active` marks a toggle that is currently on.
struct T3IconButton: View {
    @Environment(\.isEnabled) private var enabled
    @Environment(\.nativeReducedMotion) private var reduceMotion
    @Environment(\.nativeMotionVisible) private var visible
    var system: String
    var help: String = ""
    var size: CGFloat = 15
    var active: Bool = false
    var action: () -> Void
    @State private var hovering = false
    private var isHovering: Bool { hovering && enabled && visible }

    var body: some View {
        Button(action: action) {
            NativeIcon(systemName: system, size: size)
                .foregroundStyle(active || isHovering ? Theme.ink : Theme.muted)
                .frame(width: Theme.control, height: Theme.control)
                .background(
                    RoundedRectangle(cornerRadius: Theme.radiusMd, style: .continuous)
                        .fill(active ? Theme.subtle2 : (isHovering ? Theme.subtle : .clear))
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(NativePressStyle())
        .opacity(enabled ? 1 : 0.4)
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

/// Bare label that compresses under the pointer. For rows, tiles and icon
/// buttons that draw their own surface.
struct NativePressStyle: ButtonStyle {
    var scale: CGFloat = 0.97
    func makeBody(configuration: Configuration) -> some View {
        NativePressBody(scale: scale, configuration: configuration)
    }
}

private struct NativePressBody: View {
    let scale: CGFloat
    let configuration: ButtonStyleConfiguration
    @Environment(\.nativeReducedMotion) private var reduceMotion
    @Environment(\.nativeMotionVisible) private var visible
    var body: some View {
        configuration.label
            .scaleEffect(configuration.isPressed && !reduceMotion && visible ? scale : 1)
            .animation(reduceMotion || !visible ? nil : NativeMotion.press, value: configuration.isPressed)
    }
}

// ======================================================================
// MARK: - Switch, field
// ======================================================================

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
                    .frame(width: 32, height: 18)
                Circle()
                    .fill(Theme.switchKnob)
                    .frame(width: 14, height: 14)
                    .padding(.horizontal, 2)
                    .shadow(color: Theme.controlShadow, radius: 1, y: 0.5)
            }
            .frame(width: 32, height: 18)
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .pointingHand(enabled && environmentEnabled)
        .opacity(enabled && environmentEnabled ? 1 : 0.4)
        .accessibilityValue(isOn ? "On" : "Off")
        .animation(reduceMotion ? nil : NativeMotion.toggle, value: isOn)
    }
}

extension Theme {
    static let switchKnob = adaptive(light: 0xffffff, dark: 0xf5f3f0)
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
        HStack(spacing: 7) {
            if let leadingIcon { NativeIcon(leadingIcon, size: 13).foregroundStyle(focused ? Theme.dim : Theme.faint) }
            TextField(placeholder, text: $text)
                .textFieldStyle(.plain)
                .font(mono ? Theme.mono(Theme.textXs) : Theme.ui(Theme.textSm))
                .foregroundStyle(Theme.ink)
                .focused($focused)
                .onAppear { if autoFocus { focused = true } }
        }
            .padding(.horizontal, 10)
            .frame(height: 30)
            .frame(width: width)
            .nativeFieldChrome(focused: focused)
            .animation(reduceMotion ? nil : NativeMotion.hover, value: focused)
    }
}

extension View {
    /// The one input surface: paper fill, input hairline, accent ring on focus.
    func nativeFieldChrome(focused: Bool, radius: CGFloat = Theme.radiusMd) -> some View {
        background(RoundedRectangle(cornerRadius: radius, style: .continuous).fill(Theme.field))
            .overlay(RoundedRectangle(cornerRadius: radius, style: .continuous)
                .strokeBorder(focused ? Theme.accent : Theme.input, lineWidth: 1))
            .background(RoundedRectangle(cornerRadius: radius + 3, style: .continuous)
                .fill(focused ? Theme.accentRing : .clear).padding(-3))
    }
}

private struct NativeFieldModifier: ViewModifier {
    var mono: Bool
    @FocusState private var focused: Bool
    @Environment(\.nativeReducedMotion) private var reduceMotion
    func body(content: Content) -> some View {
        content.textFieldStyle(.plain)
            .font(mono ? Theme.mono(Theme.textXs) : Theme.ui(Theme.textSm)).foregroundStyle(Theme.ink)
            .focused($focused)
            .padding(.horizontal, 10).frame(height: 30)
            .nativeFieldChrome(focused: focused)
            .animation(reduceMotion ? nil : NativeMotion.hover, value: focused)
    }
}

extension View {
    /// Dress a bare TextField or SecureField as the standard field.
    func nativeField(mono: Bool = false) -> some View { modifier(NativeFieldModifier(mono: mono)) }
}

/// Multi-line text in the standard field surface.
struct NativeEditor: View {
    @Binding var text: String
    var placeholder: String = ""
    var mono = false
    @FocusState private var focused: Bool
    @Environment(\.nativeReducedMotion) private var reduceMotion
    var body: some View {
        TextEditor(text: $text)
            .font(mono ? Theme.mono(Theme.textSm) : Theme.ui(Theme.textSm)).lineSpacing(3)
            .scrollContentBackground(.hidden).focused($focused)
            .padding(.horizontal, 7).padding(.vertical, 9)
            .overlay(alignment: .topLeading) {
                if text.isEmpty && !placeholder.isEmpty {
                    Text(placeholder).font(Theme.ui(Theme.textSm)).foregroundStyle(Theme.faint)
                        .padding(.horizontal, 12).padding(.vertical, 9).allowsHitTesting(false).accessibilityHidden(true)
                }
            }
            .nativeFieldChrome(focused: focused)
            .animation(reduceMotion ? nil : NativeMotion.hover, value: focused)
    }
}

// ======================================================================
// MARK: - Segmented, tabs
// ======================================================================

/// A choice between values: recessed track, raised thumb that slides.
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
        HStack(spacing: 1) {
            ForEach(options, id: \.value) { opt in
                let sel = opt.value == selection
                Button { if enabled { onSelect(opt.value) } } label: {
                    Group {
                        if let icon = icons[opt.value] {
                            HStack(spacing: 6) { NativeIcon(icon, size: 13); Text(opt.label) }
                        } else { Text(opt.label) }
                    }
                        .font(Theme.ui(Theme.textXs, weight: .medium))
                        // A segment is a control, not prose: it pushes back on
                        // its neighbours rather than wrapping.
                        .lineLimit(1)
                        .fixedSize(horizontal: true, vertical: false)
                        .padding(.horizontal, 10)
                        .frame(height: Theme.control - 4)
                        .background {
                            if sel {
                                RoundedRectangle(cornerRadius: Theme.radiusMd - 2, style: .continuous)
                                    .fill(Theme.raised)
                                    .overlay(RoundedRectangle(cornerRadius: Theme.radiusMd - 2, style: .continuous)
                                        .strokeBorder(Theme.border, lineWidth: 1))
                                    .shadow(color: Theme.controlShadow.opacity(0.5), radius: 1, y: 0.5)
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
        .padding(2)
        .accessibilityElement(children: .contain)
        .background(RoundedRectangle(cornerRadius: Theme.radiusMd, style: .continuous).fill(Theme.segTrack))
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
            .scaleEffect(configuration.isPressed && !reduceMotion && visible ? 0.97 : 1)
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

/// Views of one page. Lives in the page bar: the label sits on the bar's
/// rule and the accent underline slides along it.
struct NativeTabs<T: Hashable>: View {
    @Environment(\.nativeReducedMotion) private var reduceMotion
    @Environment(\.nativeMotionVisible) private var visible
    var options: [(value: T, label: String)]
    var selection: T
    var counts: [T: Int] = [:]
    var height: CGFloat = Theme.barHeight
    var onSelect: (T) -> Void
    @Namespace private var ns

    var body: some View {
        HStack(spacing: 2) {
            ForEach(options, id: \.value) { option in
                let selected = option.value == selection
                Button { onSelect(option.value) } label: {
                    HStack(spacing: 6) {
                        Text(option.label).font(Theme.ui(Theme.textSm, weight: .medium))
                        if let count = counts[option.value], count > 0 {
                            Text(String(count)).font(Theme.mono(10.5))
                                .foregroundStyle(selected ? Theme.dim : Theme.faint)
                        }
                    }
                    .lineLimit(1).fixedSize()
                    .padding(.horizontal, 10)
                    .frame(height: height)
                    .overlay(alignment: .bottom) {
                        if selected {
                            Rectangle().fill(Theme.accent).frame(height: 2).padding(.horizontal, 10)
                                .matchedGeometryEffect(id: "tab-underline", in: ns)
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(T3SegmentButton(selected: selected))
                .accessibilityLabel(option.label)
                .accessibilityAddTraits(selected ? [.isSelected] : [])
                .pointingHand()
            }
        }
        .accessibilityElement(children: .contain)
        .animation(reduceMotion || !visible ? nil : NativeMotion.segmented, value: selection)
    }
}

// ======================================================================
// MARK: - Inline atoms
// ======================================================================

/// An identifier: mono, quiet, on the faintest tone step.
struct MonoChip: View {
    var text: String
    var color: Color = Theme.muted
    var body: some View {
        Text(text)
            .font(Theme.mono(Theme.textXs - 1))
            .foregroundStyle(color)
            .lineLimit(1)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(RoundedRectangle(cornerRadius: Theme.radiusXs, style: .continuous)
                .fill(color == Theme.muted ? Theme.subtle : color.opacity(0.13)))
    }
}

/// A keyboard shortcut, drawn as the key it names.
struct NativeKbd: View {
    var keys: String
    init(_ keys: String) { self.keys = keys }
    var body: some View {
        Text(keys)
            .font(Theme.ui(10.5, weight: .medium))
            .foregroundStyle(Theme.muted)
            .padding(.horizontal, 5).frame(minWidth: 18, minHeight: 18)
            .background(RoundedRectangle(cornerRadius: Theme.radiusXs, style: .continuous).fill(Theme.surface))
            .overlay(RoundedRectangle(cornerRadius: Theme.radiusXs, style: .continuous).strokeBorder(Theme.border, lineWidth: 1))
            .accessibilityHidden(true)
    }
}

struct StatusDot: View {
    var color: Color
    var size: CGFloat = 6
    var pulse: Bool = false
    var body: some View { NativeStatusDot(color: color, size: size, pulse: pulse) }
}

/// State named in words, with the mark that carries the same meaning. Colour
/// alone never says it.
struct NativeStatus: View {
    enum Tone { case ok, warn, fail, idle }
    var text: String
    var tone: Tone
    var body: some View {
        HStack(spacing: 5) {
            NativeIcon(tone == .ok ? "check" : tone == .warn ? "triangle-alert" : tone == .fail ? "circle-alert" : "circle-minus", size: 12)
            Text(text).font(Theme.ui(Theme.textXs, weight: .medium)).lineLimit(1)
        }
        .foregroundStyle(tone == .ok ? Theme.okFg : tone == .warn ? Theme.warnFg : tone == .fail ? Theme.failFg : Theme.muted)
        .accessibilityElement(children: .combine)
    }
}

// ======================================================================
// MARK: - Right rail
// ======================================================================
//
// Everything a list row puts to the right of its title sits in a column of a
// fixed width, so a row's neighbours never move when its numbers change.

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
            .frame(height: Theme.controlXs)
            .background(RoundedRectangle(cornerRadius: Theme.radiusMd, style: .continuous)
                .fill(active ? Theme.surfaceFor(Theme.ok) : (hovering ? Theme.raised : .clear))
                .overlay(RoundedRectangle(cornerRadius: Theme.radiusMd, style: .continuous)
                    .strokeBorder(active ? .clear : hovering ? Theme.input : Theme.border, lineWidth: 1)))
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

// ======================================================================
// MARK: - Menu select
// ======================================================================

/// A compact menu trigger, with AppKit retaining menu keyboard behavior.
struct NativeMenuSelect<Value: Hashable>: View {
    var title: String
    @Binding var selection: Value
    var options: [(value: Value, label: String)]
    var width: CGFloat? = nil
    @Environment(\.isEnabled) private var enabled
    @Environment(\.nativeReducedMotion) private var reduceMotion
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
                NativeIcon("chevrons-up-down", size: 12).foregroundStyle(Theme.faint)
            }
            .font(Theme.ui(Theme.textXs, weight: .medium)).foregroundStyle(Theme.ink)
            .padding(.leading, 10).padding(.trailing, 8).frame(width: width, height: Theme.control)
            .background(hovering ? Theme.raised : Theme.surface, in: RoundedRectangle(cornerRadius: Theme.radiusMd, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: Theme.radiusMd, style: .continuous).strokeBorder(hovering ? Theme.input : Theme.border, lineWidth: 1))
            .contentShape(Rectangle())
        }
        .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
        .opacity(enabled ? 1 : 0.4).onHover { hovering = $0 && enabled }
        .animation(reduceMotion ? nil : NativeMotion.hover, value: hovering)
        .pointingHand(enabled).accessibilityLabel(title)
    }
}

/// The select surface around arbitrary menu content (sections, actions).
struct NativeMenuSelectLabel<Items: View>: View {
    var title: String
    var width: CGFloat? = nil
    @ViewBuilder var items: () -> Items
    @Environment(\.isEnabled) private var enabled
    @Environment(\.nativeReducedMotion) private var reduceMotion
    @State private var hovering = false
    var body: some View {
        Menu { items() } label: {
            HStack(spacing: 8) {
                Text(title).lineLimit(1)
                if width != nil { Spacer(minLength: 0) }
                NativeIcon("chevrons-up-down", size: 12).foregroundStyle(Theme.faint)
            }
            .font(Theme.ui(Theme.textXs, weight: .medium)).foregroundStyle(Theme.ink)
            .padding(.leading, 10).padding(.trailing, 8).frame(width: width, height: Theme.control)
            .background(hovering ? Theme.raised : Theme.surface, in: RoundedRectangle(cornerRadius: Theme.radiusMd, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: Theme.radiusMd, style: .continuous).strokeBorder(hovering ? Theme.input : Theme.border, lineWidth: 1))
            .contentShape(Rectangle())
        }
        .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
        .opacity(enabled ? 1 : 0.4).onHover { hovering = $0 && enabled }
        .animation(reduceMotion ? nil : NativeMotion.hover, value: hovering)
        .pointingHand(enabled)
    }
}
