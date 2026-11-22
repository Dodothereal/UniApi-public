import SwiftUI
import AppKit
import UniApiCore
import Observation

// Paper and graphite. Dynamic NSColors resolve against the hosting window's
// appearance; no global theme mutation is needed. The shell can apply
// .nativeAppearance(.system/.light/.dark) to its root view.
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
    /// Vertical distance between the blocks of a page.
    var pageGap: CGFloat { self == .compact ? 20 : self == .spacious ? 32 : 26 }
    /// The one left and right edge every page shares.
    var pageMargin: CGFloat { self == .compact ? 24 : self == .spacious ? 40 : 32 }
    var cardScale: CGFloat { self == .compact ? 0.85 : self == .spacious ? 1.15 : 1 }
    /// Vertical padding of one margin-labelled section.
    var sectionGap: CGFloat { self == .compact ? 20 : self == .spacious ? 34 : 28 }
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

    // Surfaces, lightest paper to deepest well. `bg` is the page, `surface` a
    // sheet lying on it, `sunken` anything recessed below the page.
    static var bg: Color { token(.background, light: 0xfcf9f3, dark: 0x110f0c) }
    static var surface: Color { token(.surface, light: 0xfefdfb, dark: 0x191713) }
    static var popover: Color { token(.popover, light: 0xfefdfb, dark: 0x211f1b) }
    static let sunken = adaptive(light: 0xf4f1eb, dark: 0x0d0b08)
    static let raised = adaptive(light: 0xffffff, dark: 0x25221f)

    // Ink. Four steps; `faint` is for rulers, placeholders and disabled marks.
    static var ink: Color { token(.text, light: 0x1f1d19, dark: 0xf5f3f0) }
    static var dim: Color { token(.secondaryText, light: 0x4d4a46, dark: 0xb7b4af) }
    static var muted: Color { token(.mutedText, light: 0x63605b, dark: 0x9b9893) }
    static let faint = adaptive(light: 0x989590, dark: 0x5d5a56)

    // Tone steps drawn in ink so they sit on any surface.
    static let subtle = adaptive(light: 0x1f1d19, dark: 0xf5f3f0, lightAlpha: 0.045, darkAlpha: 0.05)
    static let subtle2 = adaptive(light: 0x1f1d19, dark: 0xf5f3f0, lightAlpha: 0.08, darkAlpha: 0.085)
    static let well = adaptive(light: 0x1f1d19, dark: 0x000000, lightAlpha: 0.04, darkAlpha: 0.32)
    static let track = adaptive(light: 0x1f1d19, dark: 0xf5f3f0, lightAlpha: 0.09, darkAlpha: 0.09)
    static let segTrack = adaptive(light: 0x1f1d19, dark: 0x000000, lightAlpha: 0.055, darkAlpha: 0.42)

    // Lines. `rule` separates rows, `border` outlines a sheet, `input`
    // outlines something that takes input.
    static let rule = adaptive(light: 0xebe7e2, dark: 0x25221f)
    static var border: Color { token(.border, light: 0xe0dcd5, dark: 0x302d29) }
    static var input: Color { token(.input, light: 0xc8c3bc, dark: 0x45423e) }
    static var field: Color { token(.field, light: 0xfefdfb, dark: 0x191713) }
    static let grid = adaptive(light: 0x1f1d19, dark: 0xf5f3f0, lightAlpha: 0.07, darkAlpha: 0.065)
    static let baseline = adaptive(light: 0x1f1d19, dark: 0xf5f3f0, lightAlpha: 0.16, darkAlpha: 0.13)
    static let crosshair = adaptive(light: 0x1f1d19, dark: 0xf5f3f0, lightAlpha: 0.32, darkAlpha: 0.24)
    static let shadow = adaptive(light: 0x1f1d19, dark: 0x000000, lightAlpha: 0.14, darkAlpha: 0.6)
    static let overlay = adaptive(light: 0x1f1d19, dark: 0x000000, lightAlpha: 0.26, darkAlpha: 0.58)

    // Signal. Ink carries the primary action; the accent marks selection,
    // focus and values that are changing right now.
    static var accent: Color { token(.accent, light: 0x006849, dark: 0x51bf9a) }
    static var link: Color { token(.highlight, light: 0x005d3e, dark: 0x80d1b2) }
    static var onAccent: Color { token(.onAccent, light: 0xfefdfb, dark: 0x090909) }
    static var accentSoft: Color { accent.opacity(0.12) }
    static var accentRing: Color { accent.opacity(0.28) }
    /// Text on a filled ink surface (the primary button).
    static var onInk: Color { token(.background, light: 0xfcf9f3, dark: 0x110f0c) }
    static let controlStroke = adaptive(light: 0xffffff, dark: 0xffffff, lightAlpha: 0.0, darkAlpha: 0.06)
    static let controlShadow = adaptive(light: 0x1f1d19, dark: 0x000000, lightAlpha: 0.16, darkAlpha: 0.5)

    static var ok: Color { token(.success, light: 0x009956, dark: 0x3bb974) }
    static var okFg: Color { token(.success, light: 0x006436, dark: 0x63d18f) }
    static var warn: Color { token(.warning, light: 0xed990e, dark: 0xf5ae39) }
    static var warnFg: Color { token(.warning, light: 0x864900, dark: 0xf7c15f) }
    static var fail: Color { token(.failure, light: 0xba1d27, dark: 0xf76560) }
    static var failFg: Color { token(.failure, light: 0xa9131f, dark: 0xff847c) }

    static var sidebarAccent: Color { token(.sidebarSelection, light: 0xfefdfb, dark: 0x1f1d19) }
    static var sidebarBG: Color { token(.sidebar, light: 0xf4f1eb, dark: 0x0d0b08) }
    static var sidebarInk: Color { token(.text, light: 0x1f1d19, dark: 0xf5f3f0) }
    static var sidebarMuted: Color { token(.mutedText, light: 0x63605b, dark: 0x9b9893) }
    static var sidebarBorder: Color { token(.border, light: 0xe0dcd5, dark: 0x25221f) }
    static func surfaceFor(_ color: Color) -> Color { color.opacity(0.13) }

    // Geometry. Everything sits on a four point grid.
    static let radiusXs: CGFloat = 4
    static let radiusSm: CGFloat = 6
    static let radiusMd: CGFloat = 7
    static let radius: CGFloat = 12
    static let radiusLg: CGFloat = 16
    static let controlXs: CGFloat = 24
    static let control: CGFloat = 28
    static let controlLg: CGFloat = 34
    static let barHeight: CGFloat = 52
    static let contentWidth: CGFloat = 1080
    static let sheetWidth: CGFloat = 920
    static let marginLabelWidth: CGFloat = 188

    // Type. One family, sizes on a short scale; numerals are tabular.
    static let textXs: CGFloat = 12
    static let textSm: CGFloat = 13
    static let textBase: CGFloat = 15
    static let textLg: CGFloat = 18
    static let text2Xl: CGFloat = 22
    static let textDisplay: CGFloat = 28

    /// Series colours for provider/model pairs. Same hue order in both
    /// appearances, lightness tuned per surface so a pair keeps its identity.
    static let pairPalette: [Color] = zip(
        [0x3075c7, 0xb55508, 0x008d56, 0x825dbc, 0x9b6b00, 0xb04b80,
         0x008a9c, 0x57840f, 0xba4b47, 0x5d6ac8, 0x9e52a3, 0x827700] as [UInt32],
        [0x79b4ff, 0xf09866, 0x5fc995, 0xbd9ef5, 0xd5aa48, 0xec8fbc,
         0x21c7d7, 0x97c169, 0xf69088, 0x9aaaff, 0xd995dd, 0xbdb54e] as [UInt32]
    ).map { adaptive(light: $0, dark: $1) }
    static func pairColor(_ key: String) -> Color {
        let hash = key.utf16.reduce(UInt32(0)) { ($0 &* 31) &+ UInt32($1) }
        return pairPalette[Int(hash % UInt32(pairPalette.count))]
    }
    /// Five chart series that never borrow the accent or a status colour.
    static let series: [Color] = zip(
        [0x226bc0, 0x0d8d82, 0xc08000, 0xb84999, 0x7e63c0] as [UInt32],
        [0x6daaf8, 0x4dc8ba, 0xe9b452, 0xe882c8, 0xb49cf7] as [UInt32]
    ).map { adaptive(light: $0, dark: $1) }

    static func mono(_ size: CGFloat, weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight, design: .monospaced)
    }
    static func ui(_ size: CGFloat, weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight)
    }
    /// Proportional face with tabular figures: readouts that change in place.
    static func num(_ size: CGFloat, weight: Font.Weight = .semibold) -> Font {
        .system(size: size, weight: weight).monospacedDigit()
    }
    /// Optical tracking for large type; body sizes stay untouched.
    static func tracking(_ size: CGFloat) -> CGFloat {
        size >= 28 ? -size * 0.028 : size >= 18 ? -size * 0.02 : size >= 15 ? -size * 0.012 : 0
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

