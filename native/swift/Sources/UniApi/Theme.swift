import SwiftUI
import AppKit
import UniApiCore
import Observation

// Dynamic NSColors resolve against
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
    var pageGap: CGFloat { self == .compact ? 22 : self == .spacious ? 36 : 28 }
    var pageMargin: CGFloat { self == .compact ? 24 : self == .spacious ? 40 : 32 }
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

/// Token reads participate in SwiftUI Observation in the view that reads them.
/// Each adaptive NSColor captures that read's values, rather than reaching back
/// into mutable state later when AppKit resolves its appearance.
@Observable final class NativeThemeStore {
    static let shared = NativeThemeStore()
    private(set) var preferences = NativeThemePreferences(serialized: UserDefaults.standard.string(forKey: NativeThemePreferences.storageKey))

    func update(_ change: (inout NativeThemePreferences) -> Void) {
        var next = preferences
        change(&next)
        guard next != preferences else { return }
        preferences = next
        UserDefaults.standard.set(next.serialized(), forKey: NativeThemePreferences.storageKey)
    }
}

/// The Meter palette. Chrome is monochrome ink on graphite or paper; hue is
/// reserved for data, status and the single signal color that marks what is
/// live, selected or focused. Tokens a person can override resolve through
/// `NativeThemePreferences`.
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
    private static func token(_ token: NativeThemePreferences.Token, light: UInt32, dark: UInt32,
                              lightAlpha: Double = 1, darkAlpha: Double = 1) -> Color {
        let preferences = NativeThemeStore.shared.preferences
        let lightOverride = preferences.colorOverride(token, .light).flatMap { UInt32($0, radix: 16) }
        let darkOverride = preferences.colorOverride(token, .dark).flatMap { UInt32($0, radix: 16) }
        return adaptive(light: lightOverride ?? light, dark: darkOverride ?? dark,
                        lightAlpha: lightOverride == nil ? lightAlpha : 1,
                        darkAlpha: darkOverride == nil ? darkAlpha : 1)
    }

    // ---- ground ----------------------------------------------------------
    /// The bench everything sits on.
    static var canvas: Color { token(.background, light: 0xF4F3EF, dark: 0x0F1012) }
    /// A filled area for something you edit, plot or pick up. Never a frame.
    static var well: Color { token(.surface, light: 0xFFFFFF, dark: 0x181A1D) }
    static var popover: Color { token(.popover, light: 0xFFFFFF, dark: 0x1D2024) }
    static var sidebarBG: Color { token(.sidebar, light: 0xEBEAE5, dark: 0x0A0B0C) }
    static var sidebarAccent: Color { token(.sidebarSelection, light: 0xDDDCD6, dark: 0x1A1C20) }
    static var field: Color { token(.field, light: 0xFFFFFF, dark: 0x16181B) }
    static let hover = adaptive(light: 0x000000, dark: 0xffffff, lightAlpha: 0.045, darkAlpha: 0.05)
    static let pressed = adaptive(light: 0x000000, dark: 0xffffff, lightAlpha: 0.08, darkAlpha: 0.09)

    // ---- ink -------------------------------------------------------------
    static var ink: Color { token(.text, light: 0x131416, dark: 0xF0F1F2) }
    static var dim: Color { token(.secondaryText, light: 0x44474C, dark: 0xB0B4BA) }
    static var muted: Color { token(.mutedText, light: 0x676A70, dark: 0x7F848C) }
    static let faint = adaptive(light: 0xA9ABAF, dark: 0x53585F)
    /// Text and glyphs on an ink-filled control.
    static var onInk: Color { canvas }

    // ---- rules -----------------------------------------------------------
    static var rule: Color { token(.border, light: 0x000000, dark: 0xffffff, lightAlpha: 0.10, darkAlpha: 0.09) }
    static var ruleStrong: Color { token(.input, light: 0x000000, dark: 0xffffff, lightAlpha: 0.20, darkAlpha: 0.17) }

    // ---- signal and status -----------------------------------------------
    /// The needle: live, now, selected, focused. Never a data series.
    static var signal: Color { token(.accent, light: 0xD4420B, dark: 0xFF5A1F) }
    static var link: Color { token(.highlight, light: 0xB93A06, dark: 0xFF9466) }
    static var onAccent: Color { token(.onAccent, light: 0xFFFFFF, dark: 0x160B05) }
    static var ok: Color { token(.success, light: 0x1F9D57, dark: 0x35C77A) }
    static var okFg: Color { token(.success, light: 0x14703C, dark: 0x4ADE8F) }
    static var warn: Color { token(.warning, light: 0xB88500, dark: 0xF2B600) }
    static var warnFg: Color { token(.warning, light: 0x8A6100, dark: 0xFFCB2E) }
    static var fail: Color { token(.failure, light: 0xD11A43, dark: 0xF2365B) }
    static var failFg: Color { token(.failure, light: 0xB01235, dark: 0xFF6482) }
    static func surfaceFor(_ color: Color) -> Color { color.opacity(0.14) }

    // ---- plots -----------------------------------------------------------
    static let track = adaptive(light: 0x000000, dark: 0xffffff, lightAlpha: 0.08, darkAlpha: 0.08)
    static let grid = adaptive(light: 0x000000, dark: 0xffffff, lightAlpha: 0.07, darkAlpha: 0.06)
    static let baseline = adaptive(light: 0x000000, dark: 0xffffff, lightAlpha: 0.16, darkAlpha: 0.14)
    static let crosshair = adaptive(light: 0x000000, dark: 0xf0f1f2, lightAlpha: 0.30, darkAlpha: 0.22)
    static let shadow = adaptive(light: 0x000000, dark: 0x000000, lightAlpha: 0.14, darkAlpha: 0.6)
    static let overlay = adaptive(light: 0x131416, dark: 0x000000, lightAlpha: 0.22, darkAlpha: 0.5)
    /// Twelve series hues ordered so neighbours differ; none of them is the signal.
    static let pairPalette: [Color] = [
        0x5B8DEF, 0xF2994A, 0x35C77A, 0xB07CF7, 0xF2C744, 0xEF6FA8,
        0x3CC8D8, 0x9BCB3C, 0xF2645A, 0x7D7FF5, 0xD873E8, 0xC9A227,
    ].map { Color(hex: UInt32($0)) }
    static func pairColor(_ key: String) -> Color {
        let hash = key.utf16.reduce(UInt32(0)) { ($0 &* 31) &+ UInt32($1) }
        return pairPalette[Int(hash % UInt32(pairPalette.count))]
    }

    // ---- shape -----------------------------------------------------------
    static let radiusControl: CGFloat = 5
    static let radiusWell: CGFloat = 7
    static let radiusSheet: CGFloat = 12

    // ---- type ------------------------------------------------------------
    // Three voices: expanded for names, condensed numerals for readings,
    // monospace for identifiers. Body copy is the plain system face.
    static func ui(_ size: CGFloat, weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight)
    }
    static func mono(_ size: CGFloat, weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight, design: .monospaced)
    }
    /// Page titles.
    static func display(_ size: CGFloat = 24, weight: Font.Weight = .semibold) -> Font {
        .system(size: size, weight: weight).width(.expanded)
    }
    /// Section names that sit on a rule.
    static func heading(_ size: CGFloat = 12, weight: Font.Weight = .semibold) -> Font {
        .system(size: size, weight: weight).width(.expanded)
    }
    /// Engraved micro labels: always uppercased and tracked by `MicroLabel`.
    static func label(_ size: CGFloat = 9.5, weight: Font.Weight = .medium) -> Font {
        .system(size: size, weight: weight).width(.expanded)
    }
    /// Readings. Use the four sizes in `ReadoutSize`, not ad-hoc values.
    static func readout(_ size: CGFloat, weight: Font.Weight = .medium) -> Font {
        .system(size: size, weight: weight).width(.condensed).monospacedDigit()
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

