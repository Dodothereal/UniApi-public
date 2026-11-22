import SwiftUI
import AppKit
import UniApiCore

/// Embedded by Settings. Editing one look never changes the other, even
/// when the currently displayed system appearance uses that other look.
struct NativeThemeSettingsView: View {
    @Environment(\.colorScheme) private var colorScheme
    @State private var variant: NativeThemePreferences.Variant = .dark
    @State private var showAdvanced = false
    @State private var showContrast = false
    @State private var paletteUndo: PaletteUndo?
    private var store: NativeThemeStore { .shared }
    private let common: [NativeThemePreferences.Token] = [.accent, .highlight, .background, .surface, .text]
    /// The remaining roles in the order the strip groups them. Anything a
    /// later version adds still appears, after these.
    private var advanced: [NativeThemePreferences.Token] {
        let grouped: [NativeThemePreferences.Token] = [.popover, .field, .sidebar, .sidebarSelection, .secondaryText, .mutedText,
                                                       .onAccent, .border, .input, .success, .warning, .failure]
        return grouped + NativeThemePreferences.Token.allCases.filter { !common.contains($0) && !grouped.contains($0) }
    }

    /// The name people see for a stored variant.
    static func lookName(_ variant: NativeThemePreferences.Variant) -> String { variant == .dark ? "Graphite" : "Paper" }
    /// The name people see for a stored preset; the default palette is Meter.
    static func presetName(_ preset: NativeThemePreferences.Preset) -> String { preset == .original ? "Meter" : preset.title }
    /// The look on screen, said as its palette: a preset name or a count of edits.
    static func summary(for scheme: ColorScheme) -> String {
        let variant: NativeThemePreferences.Variant = scheme == .dark ? .dark : .light
        let preferences = NativeThemeStore.shared.preferences
        if let preset = NativeThemePreferences.Preset.allCases.first(where: { matches($0, preferences, variant) }) {
            return presetName(preset) + " palette on " + lookName(variant)
        }
        let edits = NativeThemePreferences.Token.allCases.filter { preferences.colorOverride($0, variant) != nil }.count
        return "\(edits) custom " + (edits == 1 ? "color" : "colors") + " on " + lookName(variant)
    }
    fileprivate static func matches(_ preset: NativeThemePreferences.Preset, _ preferences: NativeThemePreferences,
                                    _ variant: NativeThemePreferences.Variant) -> Bool {
        var palette = NativeThemePreferences()
        palette.apply(preset, variant: variant)
        return NativeThemePreferences.Token.allCases.allSatisfy {
            preferences.colorOverride($0, variant) == palette.colorOverride($0, variant)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            HStack(alignment: .center, spacing: 12) {
                MicroLabel("Editing")
                Stops(options: [(NativeThemePreferences.Variant.dark, "Graphite"), (.light, "Paper")], selection: variant,
                      icons: [.dark: "moon", .light: "sun"]) { variant = $0 }
                    .accessibilityLabel("Editing variant")
                if (colorScheme == .dark) != (variant == .dark) {
                    Text("The app is showing \(Self.lookName(colorScheme == .dark ? .dark : .light)); these colors appear when the look changes.")
                        .font(Theme.ui(11.5)).foregroundStyle(Theme.muted).lineLimit(2)
                }
                Spacer(minLength: 8)
                if let undo = paletteUndo {
                    Button("Undo \(Self.lookName(undo.variant)) palette", nativeIcon: "undo-2") { undoPalette(undo) }
                        .help("Restore the previous palette, keeping later individual color edits.")
                }
                Button("Reset \(Self.lookName(variant))", nativeIcon: "rotate-ccw") { replacePalette { $0.reset(variant) } }
                    .padding(.trailing, -8)
            }
            .buttonStyle(Press(.quiet))
            NativeThemeStrip(preferences: store.preferences, variant: variant)
            VStack(alignment: .leading, spacing: 10) {
                MicroLabel("Palettes")
                ColumnFlow(minimum: 110, spacing: 24, rowSpacing: 16, maxColumns: 4) {
                    ForEach(NativeThemePreferences.Preset.allCases, id: \.rawValue) { preset in
                        NativeThemePresetChoice(preset: preset, variant: variant, preferences: store.preferences) {
                            replacePalette { $0.apply(preset, variant: variant) }
                        }
                    }
                }
            }
            VStack(alignment: .leading, spacing: 0) {
                LedgerHead {
                    MicroLabel("Color")
                    Spacer(minLength: 8)
                    MicroLabel("Hex, applied on Return")
                }
                colorRows(common)
                SettingsFold(title: "Every color", detail: "Text shades, sidebar, popover, fields, rules and status.", isOpen: $showAdvanced,
                             open: "Show", close: "Hide", label: "Advanced colors", closingRule: false) {
                    colorRows(advanced)
                }
                NativeThemeContrastChecks(preferences: store.preferences, variant: variant, expanded: $showContrast)
            }
        }.onAppear { variant = colorScheme == .dark ? .dark : .light }
    }

    private func colorRows(_ tokens: [NativeThemePreferences.Token]) -> some View {
        ColumnFlow(minimum: 280, spacing: 32, rowSpacing: 0, maxColumns: 2) {
            ForEach(tokens, id: \.rawValue) { token in
                NativeThemeColorRow(token: token, variant: variant, store: store)
            }
        }
    }

    private struct PaletteUndo {
        let variant: NativeThemePreferences.Variant
        let before: NativeThemePreferences
        let after: NativeThemePreferences
    }
    private func replacePalette(_ change: (inout NativeThemePreferences) -> Void) {
        let before = store.preferences
        var after = before
        change(&after)
        guard after != before else { return }
        paletteUndo = PaletteUndo(variant: variant, before: before, after: after)
        store.update { $0 = after }
    }
    private func undoPalette(_ undo: PaletteUndo) {
        store.update { current in
            current.undoPaletteChange(before: undo.before, after: undo.after, variant: undo.variant)
        }
        paletteUndo = nil
    }
}

/// The live palette as a calibration strip: every token is one swatch under a
/// graduation, grouped by what it colors. It shows the look being edited, also
/// when the app itself is in the other one.
private struct NativeThemeStrip: View {
    let preferences: NativeThemePreferences
    let variant: NativeThemePreferences.Variant

    private static let groups: [(name: String, tokens: [NativeThemePreferences.Token])] = [
        ("Ground", [.background, .surface, .popover, .field, .sidebar, .sidebarSelection]),
        ("Ink", [.text, .secondaryText, .mutedText]),
        ("Signal", [.accent, .onAccent, .highlight]),
        ("Rules", [.border, .input]),
        ("Status", [.success, .warning, .failure]),
    ]
    /// The text a swatch is read against, where the pairing is fixed.
    private static let samples: [NativeThemePreferences.Token: NativeThemePreferences.Token] = [
        .background: .text, .surface: .secondaryText, .sidebar: .mutedText, .accent: .onAccent,
    ]
    private func color(_ token: NativeThemePreferences.Token) -> Color {
        Color(hex: UInt32(preferences.hex(token, variant), radix: 16) ?? 0)
    }

    var body: some View {
        GeometryReader { geometry in
            let gap: CGFloat = 12
            let unit = max(0, (geometry.size.width - gap * CGFloat(Self.groups.count - 1)) / 17)
            HStack(alignment: .top, spacing: gap) {
                ForEach(Self.groups, id: \.name) { group in
                    VStack(alignment: .leading, spacing: 0) {
                        TickScale(divisions: group.tokens.count, major: group.tokens.count, minorHeight: 3, majorHeight: 6)
                            .fill(Theme.faint).frame(height: 6)
                        HStack(spacing: 0) {
                            ForEach(group.tokens, id: \.rawValue) { token in
                                color(token)
                                    .overlay {
                                        if let sample = Self.samples[token] {
                                            Text("Aa").font(Theme.ui(11.5, weight: .medium)).foregroundStyle(color(sample))
                                        }
                                    }
                                    .help(token.title + "  #" + preferences.hex(token, variant))
                            }
                        }
                        .frame(height: 40)
                        .overlay(Rectangle().strokeBorder(Theme.rule, lineWidth: 1))
                        .padding(.top, 2)
                        MicroLabel(group.name).padding(.top, 7)
                    }
                    .frame(width: unit * CGFloat(group.tokens.count), alignment: .leading)
                }
            }
        }
        .frame(height: 68)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(NativeThemeSettingsView.lookName(variant)) palette")
    }
}

private struct NativeThemePresetChoice: View {
    let preset: NativeThemePreferences.Preset
    let variant: NativeThemePreferences.Variant
    let preferences: NativeThemePreferences
    let action: () -> Void
    @State private var hovering = false
    @Environment(\.nativeReducedMotion) private var reduceMotion

    private var palette: NativeThemePreferences {
        var result = NativeThemePreferences()
        result.apply(preset, variant: variant)
        return result
    }
    private var selected: Bool { NativeThemeSettingsView.matches(preset, preferences, variant) }
    var body: some View {
        let colors = palette
        let name = NativeThemeSettingsView.presetName(preset)
        Button(action: action) {
            VStack(alignment: .leading, spacing: 0) {
                ZStack(alignment: .topLeading) {
                    (hovering || selected ? Theme.ruleStrong : Theme.rule).frame(height: 1)
                    (selected ? Theme.signal : Theme.faint).frame(width: 2, height: 7)
                }
                .frame(height: 7, alignment: .top)
                HStack(spacing: 0) {
                    ForEach([NativeThemePreferences.Token.background, .surface, .accent, .highlight, .text], id: \.rawValue) { token in
                        Color(hex: UInt32(colors.hex(token, variant), radix: 16) ?? 0)
                    }
                }
                .frame(height: 14)
                .overlay(Rectangle().strokeBorder(Theme.rule, lineWidth: 1))
                .padding(.top, 6)
                ZStack(alignment: .leading) {
                    Text(name).font(Theme.ui(12.5, weight: .semibold)).hidden()
                    Text(name).font(Theme.ui(12.5, weight: selected ? .semibold : .regular))
                        .foregroundStyle(selected || hovering ? Theme.ink : Theme.dim)
                }
                .padding(.top, 8)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain).pointingHand().onHover { hovering = $0 }
        .animation(reduceMotion ? nil : NativeMotion.hover, value: hovering)
        .accessibilityLabel("\(name) palette")
        .accessibilityHint("Applies to the \(variant.rawValue) variant")
        .accessibilityAddTraits(selected ? [.isSelected] : [])
    }
}

/// The sidebar shares the text roles and the status marks share the status
/// roles. Keep the strip and the checks aligned with those fallbacks in Theme,
/// including when only one look is edited.
private struct NativeThemeResolvedColors {
    let preferences: NativeThemePreferences
    let variant: NativeThemePreferences.Variant

    func hex(_ token: NativeThemePreferences.Token) -> String { preferences.hex(token, variant) }
    func sidebarText() -> String { hex(.text) }
    func sidebarMuted() -> String { hex(.mutedText) }
}

private struct NativeThemeContrastChecks: View {
    let preferences: NativeThemePreferences
    let variant: NativeThemePreferences.Variant
    @Binding var expanded: Bool

    private struct Check: Identifiable {
        let label: String
        let ratio: Double
        var id: String { label }
    }
    private var checks: [Check] {
        let colors = NativeThemeResolvedColors(preferences: preferences, variant: variant)
        var result: [Check] = []
        func add(_ label: String, _ foreground: String, _ background: String) {
            if let ratio = NativeThemePreferences.contrast(foreground, background) {
                result.append(Check(label: label, ratio: ratio))
            }
        }
        for (label, token) in [("Main", NativeThemePreferences.Token.text), ("Secondary", .secondaryText),
                               ("Muted", .mutedText), ("Link", .highlight),
                               ("Success", .success), ("Warning", .warning), ("Error", .failure)] {
            add("\(label) / background", colors.hex(token), colors.hex(.background))
            add("\(label) / surface", colors.hex(token), colors.hex(.surface))
        }
        add("Sidebar text / sidebar", colors.sidebarText(), colors.hex(.sidebar))
        add("Sidebar muted / sidebar", colors.sidebarMuted(), colors.hex(.sidebar))
        add("Sidebar text / selection", colors.sidebarText(), colors.hex(.sidebarSelection))
        add("Action text / accent", colors.hex(.onAccent), colors.hex(.accent))
        return result
    }
    var body: some View {
        let results = checks
        let low = results.filter { $0.ratio < 4.5 }.count
        SettingsFold(title: low == 0 ? "Contrast checks" : "Contrast checks · \(low) low",
                     detail: low == 0 ? "All \(results.count) text pairs reach 4.5:1." : "\(low) of \(results.count) text pairs fall below 4.5:1, the mark for small text.",
                     isOpen: $expanded, open: "Show", close: "Hide", label: "Contrast checks", closingRule: false) {
            VStack(alignment: .leading, spacing: 10) {
                ColumnFlow(minimum: 280, spacing: 32, rowSpacing: 0, maxColumns: 2) {
                    ForEach(results) { check in NativeThemeContrastRow(label: check.label, ratio: check.ratio) }
                }
                Text("The centre mark is 4.5:1. Only opaque surfaces are measured; translucent overlays and other combinations can differ.")
                    .font(Theme.ui(11.5)).foregroundStyle(Theme.muted).fixedSize(horizontal: false, vertical: true)
                    .padding(.bottom, 12)
            }
        }
    }
}

/// One measured pair: its ratio on a scale whose centre mark is the 4.5:1 target.
private struct NativeThemeContrastRow: View {
    let label: String
    let ratio: Double
    var body: some View {
        let low = ratio < 4.5
        HStack(spacing: 12) {
            Text(label).font(Theme.ui(12.5)).foregroundStyle(Theme.ink).lineLimit(1)
            Spacer(minLength: 4)
            Scale(fraction: min(1, ratio / 9), color: low ? Theme.warn : Theme.ink, height: 3, ticks: true)
                .frame(width: 80)
            Text(String(format: "%.1f:1", ratio)).font(Theme.mono(11)).monospacedDigit()
                .foregroundStyle(low ? Theme.warnFg : Theme.dim).frame(width: 50, alignment: .trailing)
        }
        .frame(minHeight: 32)
        .overlay(alignment: .bottom) { Rule() }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(label)
        .accessibilityValue(String(format: "%.1f to 1%@", ratio, low ? ", low" : ""))
    }
}

private struct NativeThemeColorRow: View {
    let token: NativeThemePreferences.Token
    let variant: NativeThemePreferences.Variant
    let store: NativeThemeStore
    @State private var draft = ""
    @State private var invalid = false
    @State private var editVariant: NativeThemePreferences.Variant?
    @State private var editStartingValue: String?
    @FocusState private var editing: Bool
    @Environment(\.nativeReducedMotion) private var reduceMotion
    private var value: String { store.preferences.hex(token, variant) }
    private var custom: Bool { store.preferences.colorOverride(token, variant) != nil }
    private var picker: Binding<Color> {
        Binding(get: { Color(hex: UInt32(value, radix: 16) ?? 0) }, set: { color in
            guard let rgb = NSColor(color).usingColorSpace(.sRGB) else { return }
            let r = Int((max(0, min(1, rgb.redComponent)) * 255).rounded())
            let g = Int((max(0, min(1, rgb.greenComponent)) * 255).rounded())
            let b = Int((max(0, min(1, rgb.blueComponent)) * 255).rounded())
            let hex = String(format: "%02X%02X%02X", r, g, b)
            guard hex != value else { return }
            store.update { _ = $0.set(hex, token: token, variant: variant) }
        })
    }
    var body: some View {
        HStack(spacing: 10) {
            Button { NativeThemeColorPanel.shared.open(NSColor(picker.wrappedValue)) { picker.wrappedValue = Color(nsColor: $0) } } label: {
                RoundedRectangle(cornerRadius: 3, style: .continuous).fill(picker.wrappedValue)
                    .frame(width: 30, height: 20)
                    .overlay(RoundedRectangle(cornerRadius: 3, style: .continuous).strokeBorder(Theme.ruleStrong, lineWidth: 1))
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain).pointingHand()
            .help("Choose \(token.title.lowercased()) in the color panel")
            .accessibilityLabel("\(token.title) color")
            Text(token.title).font(Theme.ui(13)).foregroundStyle(Theme.ink).lineLimit(1)
            if invalid { Tag("Invalid", tone: Theme.failFg) }
            Spacer(minLength: 4)
            TextField("Hex", text: $draft).textFieldStyle(.plain)
                .font(Theme.mono(11.5)).foregroundStyle(custom || editing ? Theme.ink : Theme.muted)
                .multilineTextAlignment(.trailing)
                .padding(.horizontal, 8).frame(width: 84, height: 26)
                .background(RoundedRectangle(cornerRadius: Theme.radiusControl, style: .continuous).fill(editing ? Theme.field : .clear))
                .overlay(RoundedRectangle(cornerRadius: Theme.radiusControl, style: .continuous)
                    .strokeBorder(invalid ? Theme.fail : editing ? Theme.signal : Theme.rule, lineWidth: 1))
                .focused($editing).accessibilityLabel("\(token.title) hex color")
                .onSubmit(commit)
                .onChange(of: editing) { _, focused in
                    if focused {
                        editVariant = variant
                        editStartingValue = value
                    } else {
                        commit()
                        editVariant = nil
                        editStartingValue = nil
                    }
                }
                .help(invalid ? "Use six hexadecimal digits, for example #346BF1." : "Six-digit RGB hex color")
        }
        .frame(minHeight: 40)
        .overlay(alignment: .bottom) { Rule() }
        .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: editing)
        .onAppear { draft = "#" + value }
        .onChange(of: value) { _, newValue in if !editing { draft = "#" + newValue; invalid = false } }
        .onChange(of: variant) { _, _ in
            NativeThemeColorPanel.shared.detach()
            if editing { commit() }
            editVariant = variant
            editStartingValue = value
            draft = "#" + value
            invalid = false
        }
    }
    private func commit() {
        guard let normalized = NativeThemePreferences.normalizeHex(draft) else { invalid = true; return }
        let target = editVariant ?? variant
        let current = store.preferences.hex(token, target)
        // A preset or reset may have changed the color while this field was
        // focused. Do not let an old draft silently overwrite that palette.
        if let start = editStartingValue, current != start {
            draft = "#" + value
            invalid = false
            editStartingValue = value
            return
        }
        invalid = false
        draft = "#" + normalized
        if normalized != current {
            store.update { _ = $0.set(normalized, token: token, variant: target) }
        }
        editStartingValue = normalized
    }
}

/// The system color panel, aimed at one swatch at a time. Picking another
/// swatch or changing the edited look re-aims or releases it, so a panel left
/// open can never write to a color the person is no longer looking at.
@MainActor final class NativeThemeColorPanel: NSObject {
    static let shared = NativeThemeColorPanel()
    private var apply: ((NSColor) -> Void)?

    func open(_ color: NSColor, apply: @escaping (NSColor) -> Void) {
        let panel = NSColorPanel.shared
        self.apply = nil
        panel.showsAlpha = false
        panel.isContinuous = true
        panel.color = color
        panel.setTarget(self)
        panel.setAction(#selector(changed(_:)))
        self.apply = apply
        panel.orderFront(nil)
    }
    func detach() { apply = nil }
    @objc private func changed(_ sender: NSColorPanel) { apply?(sender.color) }
}
