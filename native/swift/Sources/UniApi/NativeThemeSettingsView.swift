import SwiftUI
import AppKit
import UniApiCore

/// Embedded by Settings. Editing one variant never changes the other, even
/// when the currently displayed system appearance uses that other variant.
struct NativeThemeSettingsView: View {
    @Environment(\.colorScheme) private var colorScheme
    @State private var variant: NativeThemePreferences.Variant = .dark
    @State private var showAdvanced = false
    @State private var showContrast = false
    @State private var paletteUndo: PaletteUndo?
    private var store: NativeThemeStore { .shared }
    private let common: [NativeThemePreferences.Token] = [.accent, .highlight, .background, .surface, .text]
    private var advanced: [NativeThemePreferences.Token] {
        NativeThemePreferences.Token.allCases.filter { !common.contains($0) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            SectionLabel("Custom colors")
            Text("Changes save immediately on this Mac. Hex values apply when you press Return or leave the field.")
                .font(Theme.ui(12)).foregroundStyle(Theme.muted)
            HStack {
                Text("Editing variant").font(Theme.ui(12))
                Picker("Editing variant", selection: $variant) {
                    Text("Light").tag(NativeThemePreferences.Variant.light)
                    Text("Dark").tag(NativeThemePreferences.Variant.dark)
                }.labelsHidden().pickerStyle(.segmented).frame(width: 150)
                Spacer()
                if let undo = paletteUndo {
                    Button("Undo \(undo.variant.rawValue) palette") { undoPalette(undo) }
                        .help("Restore the previous palette, keeping later individual color edits.")
                }
                Button("Reset \(variant.rawValue)") { replacePalette { $0.reset(variant) } }
            }
            Text("App appearance: \(colorScheme == .dark ? "Dark" : "Light") · Editing: \(variant == .dark ? "Dark" : "Light")" +
                 ((colorScheme == .dark) == (variant == .dark) ? "" : " · This variant appears in the preview until the app switches appearance."))
                .font(Theme.ui(11)).foregroundStyle(Theme.muted).fixedSize(horizontal: false, vertical: true)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 120), spacing: 8)], alignment: .leading, spacing: 8) {
                ForEach(NativeThemePreferences.Preset.allCases, id: \.rawValue) { preset in
                    NativeThemePresetCard(preset: preset, variant: variant, preferences: store.preferences) {
                        replacePalette { $0.apply(preset, variant: variant) }
                    }
                }
            }
            NativeThemePreview(preferences: store.preferences, variant: variant)
            NativeThemeContrastChecks(preferences: store.preferences, variant: variant, expanded: $showContrast)
            colorRows(common)
            DisclosureGroup("Advanced colors", isExpanded: $showAdvanced) {
                colorRows(advanced).padding(.top, 10)
            }
            .font(Theme.ui(12, weight: .medium)).foregroundStyle(Theme.ink)
        }.onAppear { variant = colorScheme == .dark ? .dark : .light }
    }

    private func colorRows(_ tokens: [NativeThemePreferences.Token]) -> some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 250), spacing: 16)], alignment: .leading, spacing: 9) {
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

private struct NativeThemePresetCard: View {
    let preset: NativeThemePreferences.Preset
    let variant: NativeThemePreferences.Variant
    let preferences: NativeThemePreferences
    let action: () -> Void

    private var palette: NativeThemePreferences {
        var result = NativeThemePreferences()
        result.apply(preset, variant: variant)
        return result
    }
    private var selected: Bool {
        NativeThemePreferences.Token.allCases.allSatisfy {
            preferences.colorOverride($0, variant) == palette.colorOverride($0, variant)
        }
    }
    var body: some View {
        let colors = palette
        Button(action: action) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 4) {
                    ForEach([NativeThemePreferences.Token.background, .surface, .accent, .highlight, .text], id: \.rawValue) { token in
                        Circle().fill(Color(hex: UInt32(colors.hex(token, variant), radix: 16) ?? 0))
                            .frame(width: 14, height: 14)
                            .overlay(Circle().strokeBorder(Theme.border, lineWidth: 1))
                    }
                }
                Text(preset.title).font(Theme.ui(12, weight: .medium)).foregroundStyle(Theme.ink)
            }
            .frame(maxWidth: .infinity, alignment: .leading).padding(10)
            .background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.radiusMd))
            .overlay(RoundedRectangle(cornerRadius: Theme.radiusMd)
                .strokeBorder(selected ? Theme.accent : Theme.border, lineWidth: selected ? 2 : 1))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(preset.title) palette")
        .accessibilityHint("Applies to the \(variant.rawValue) variant")
        .accessibilityAddTraits(selected ? [.isSelected] : [])
    }
}

/// The sidebar and status markers use distinct original colors even though
/// they share their customization roles. Keep the preview and checks aligned
/// with those fallbacks in Theme, including when only one variant is edited.
private struct NativeThemeResolvedColors {
    let preferences: NativeThemePreferences
    let variant: NativeThemePreferences.Variant

    func hex(_ token: NativeThemePreferences.Token) -> String { preferences.hex(token, variant) }
    func sidebarText() -> String {
        preferences.colorOverride(.text, variant) ?? (variant == .dark ? "F1F3F7" : "18181B")
    }
    func sidebarMuted() -> String {
        preferences.colorOverride(.mutedText, variant) ?? (variant == .dark ? "A3A3A3" : "71717B")
    }
    func statusDot(_ token: NativeThemePreferences.Token) -> String {
        if let value = preferences.colorOverride(token, variant) { return value }
        switch token {
        case .success: return "00BC7D"
        case .warning: return "FE9A00"
        case .failure: return "FB2C36"
        default: return hex(token)
        }
    }
    func color(_ hex: String) -> Color { Color(hex: UInt32(hex, radix: 16) ?? 0) }
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
        DisclosureGroup(isExpanded: $expanded) {
            VStack(alignment: .leading, spacing: 5) {
                Text("Aim for 4.5:1 for small text. These checks cover common opaque surfaces; translucent overlays and other combinations can differ.")
                    .font(Theme.ui(11)).foregroundStyle(Theme.muted).fixedSize(horizontal: false, vertical: true)
                ForEach(results) { check in
                    HStack {
                        Text(check.label)
                        Spacer()
                        Text(String(format: "%.1f:1%@", check.ratio, check.ratio < 4.5 ? "  Low" : ""))
                            .foregroundStyle(check.ratio < 4.5 ? Theme.warnFg : Theme.dim)
                    }.font(Theme.ui(11))
                }
            }.padding(.top, 8)
        } label: {
            Text(low == 0 ? "Contrast checks" : "Contrast checks · \(low) low")
                .font(Theme.ui(12, weight: .medium)).foregroundStyle(low == 0 ? Theme.ink : Theme.warnFg)
        }
    }
}

private struct NativeThemePreview: View {
    let preferences: NativeThemePreferences
    let variant: NativeThemePreferences.Variant
    private func color(_ token: NativeThemePreferences.Token) -> Color {
        let color = Color(hex: UInt32(preferences.hex(token, variant), radix: 16) ?? 0)
        if variant == .dark && preferences.colorOverride(token, variant) == nil {
            if token == .border { return color.opacity(0.06) }
            if token == .field { return color.opacity(0.035) }
            if token == .input { return color.opacity(0.08) }
        }
        return color
    }
    var body: some View {
        let resolved = NativeThemeResolvedColors(preferences: preferences, variant: variant)
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 9) {
                Text("UNIAPI").font(.system(size: 10, weight: .bold)).tracking(1)
                Text("Overview").font(.system(size: 11, weight: .medium))
                    .foregroundStyle(resolved.color(resolved.sidebarText()))
                    .padding(7).frame(maxWidth: .infinity, alignment: .leading)
                    .background(color(.sidebarSelection), in: RoundedRectangle(cornerRadius: 5))
                Text("Settings").font(.system(size: 11)).foregroundStyle(resolved.color(resolved.sidebarMuted()))
                Spacer(minLength: 0)
            }.padding(12).frame(width: 120, alignment: .leading)
                .foregroundStyle(resolved.color(resolved.sidebarText())).background(color(.sidebar))
            VStack(alignment: .leading, spacing: 7) {
                Text("Your workspace").font(.system(size: 14, weight: .semibold)).foregroundStyle(color(.text))
                Text("A small preview of your palette").font(.system(size: 11)).foregroundStyle(color(.secondaryText))
                    .padding(5).background(color(.surface), in: RoundedRectangle(cornerRadius: 4))
                HStack(spacing: 7) {
                    Text("Primary action").font(.system(size: 11, weight: .medium)).foregroundStyle(color(.onAccent))
                        .padding(.horizontal, 9).padding(.vertical, 5).background(color(.accent), in: RoundedRectangle(cornerRadius: 5))
                    Text("Link").font(.system(size: 11)).foregroundStyle(color(.highlight))
                    Circle().fill(resolved.color(resolved.statusDot(.success))).frame(width: 7, height: 7)
                    Circle().fill(resolved.color(resolved.statusDot(.warning))).frame(width: 7, height: 7)
                    Circle().fill(resolved.color(resolved.statusDot(.failure))).frame(width: 7, height: 7)
                }
                Text("Palette preview").font(.system(size: 10)).foregroundStyle(color(.mutedText))
            }.padding(14).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
                .background(color(.background))
        }
        .frame(height: 126).clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(color(.border), lineWidth: 1))
        .accessibilityElement(children: .combine)
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
    private var value: String { store.preferences.hex(token, variant) }
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
        HStack(spacing: 8) {
            Text(token.title).font(Theme.ui(12)).foregroundStyle(Theme.ink)
            Spacer(minLength: 4)
            ColorPicker(token.title, selection: picker, supportsOpacity: false).labelsHidden()
                .accessibilityLabel("\(token.title) color")
            TextField("Hex", text: $draft).font(Theme.mono(11)).frame(width: 75)
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
            if invalid { Text("Invalid").font(Theme.ui(10)).foregroundStyle(Theme.failFg) }
        }
        .onAppear { draft = "#" + value }
        .onChange(of: value) { _, newValue in if !editing { draft = "#" + newValue; invalid = false } }
        .onChange(of: variant) { _, _ in
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
