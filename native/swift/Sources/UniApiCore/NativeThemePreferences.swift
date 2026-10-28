import Foundation
import CoreFoundation

/// Small, private preference document. An absent override retains the original
/// adaptive token, including any transparency, rather than approximating it.
public struct NativeThemePreferences: Equatable, Sendable {
    public static let storageKey = "uniapi-custom-theme-v1"
    public static let maximumBytes = 8192

    public enum Variant: String, CaseIterable, Sendable { case light, dark }
    public enum Token: String, CaseIterable, Sendable {
        case background, surface, popover, sidebar, text, secondaryText, mutedText
        case accent, highlight, onAccent, border, input, field, sidebarSelection
        case success, warning, failure

        public var title: String {
            switch self {
            case .background: return "Background"
            case .surface: return "Surface"
            case .popover: return "Popover"
            case .sidebar: return "Sidebar"
            case .text: return "Main text"
            case .secondaryText: return "Secondary text"
            case .mutedText: return "Muted text"
            case .accent: return "Accent"
            case .highlight: return "Link / highlight"
            case .onAccent: return "Text on accent"
            case .border: return "Borders"
            case .input: return "Input borders"
            case .field: return "Input background"
            case .sidebarSelection: return "Sidebar selection"
            case .success: return "Success"
            case .warning: return "Warning"
            case .failure: return "Error"
            }
        }
        public func defaultHex(_ variant: Variant) -> String {
            let light = ["FCFCFC", "FFFFFF", "FFFFFF", "FCFCFC", "18181B", "47464E", "71717B", "1447E6", "1447E6", "FFFFFF", "E4E4E7", "D4D4D8", "FFFFFF", "F1F1F4", "047857", "BB4D00", "C10007"]
            let dark = ["0A0A0A", "111111", "191919", "0A0A0A", "F5F5F5", "A8A8A8", "818181", "346BF1", "8FB2FF", "FFFFFF", "FFFFFF", "FFFFFF", "FFFFFF", "191A1D", "00D492", "FFB900", "FF6467"]
            let index = Self.allCases.firstIndex(of: self)!
            return (variant == .light ? light : dark)[index]
        }
    }
    public enum Preset: String, CaseIterable, Sendable {
        case original, ocean, forest, plum
        public var title: String { rawValue.capitalized }
    }

    private var light: [String: String] = [:]
    private var dark: [String: String] = [:]
    public init() {}

    /// Accept only opaque, six-digit sRGB values. Whitespace and # are
    /// convenient input syntax; serialized values are always canonical.
    public static func normalizeHex(_ input: String) -> String? {
        var value = input.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.hasPrefix("#") { value.removeFirst() }
        guard value.utf8.count == 6, value.utf8.allSatisfy({ (48...57).contains($0) || (65...70).contains($0) || (97...102).contains($0) }) else { return nil }
        return value.uppercased()
    }

    /// WCAG relative luminance for opaque sRGB colors; callers must not use
    /// this to claim a contrast ratio for translucent composited tokens.
    public static func contrast(_ foreground: String, _ background: String) -> Double? {
        func luminance(_ input: String) -> Double? {
            guard let hex = normalizeHex(input), let value = UInt32(hex, radix: 16) else { return nil }
            let components = [Double((value >> 16) & 255), Double((value >> 8) & 255), Double(value & 255)].map { component in
                let s = component / 255
                return s <= 0.04045 ? s / 12.92 : pow((s + 0.055) / 1.055, 2.4)
            }
            return components[0] * 0.2126 + components[1] * 0.7152 + components[2] * 0.0722
        }
        guard let a = luminance(foreground), let b = luminance(background) else { return nil }
        return (max(a, b) + 0.05) / (min(a, b) + 0.05)
    }

    public func colorOverride(_ token: Token, _ variant: Variant) -> String? {
        (variant == .light ? light : dark)[token.rawValue]
    }
    public func hex(_ token: Token, _ variant: Variant) -> String {
        colorOverride(token, variant) ?? token.defaultHex(variant)
    }
    public mutating func set(_ input: String, token: Token, variant: Variant) -> Bool {
        guard let value = Self.normalizeHex(input) else { return false }
        if variant == .light { light[token.rawValue] = value } else { dark[token.rawValue] = value }
        return true
    }
    public mutating func reset(_ variant: Variant) {
        if variant == .light { light.removeAll() } else { dark.removeAll() }
    }
    /// Revert the last palette replacement without discarding later individual
    /// edits or any changes made to the other variant.
    public mutating func undoPaletteChange(before: Self, after: Self, variant: Variant) {
        let restored = Token.allCases.map { token -> (Token, String?) in
            let current = colorOverride(token, variant)
            return (token, current == after.colorOverride(token, variant) ? before.colorOverride(token, variant) : current)
        }
        reset(variant)
        for (token, value) in restored {
            if let value { _ = set(value, token: token, variant: variant) }
        }
    }
    public mutating func apply(_ preset: Preset, variant: Variant) {
        reset(variant)
        guard preset != .original else { return }
        // Every preset is a complete variant, so changing a preset never leaves
        // behind an unrelated individual edit from the previous palette.
        let values: [String]
        switch (preset, variant) {
        case (.ocean, .light): values = ["F3F8FC","FFFFFF","FFFFFF","E7F1F7","102C3C","365768","607B89","006A91","006A91","FFFFFF","C5DAE4","ABC7D4","F8FCFE","D3E8F2","08775C","9B5900","B52B3A"]
        case (.ocean, .dark): values = ["09161F","102631","173541","0C202B","E2F3F7","ABC6D0","7899A8","39A9D4","80D2ED","08212C","294955","39606C","142E39","1C3B49","4BD6A7","FFC268","FF858D"]
        case (.forest, .light): values = ["F6F9F3","FFFFFF","FFFFFF","EAF1E6","1B2D22","496252","718879","27754D","27754D","FFFFFF","D0DED0","B7CCB8","FBFDF9","DBEADB","167449","985600","BA3035"]
        case (.forest, .dark): values = ["101A14","18271D","203329","142219","E8F2E8","B1C8B6","819D88","63BC88","8DDBA9","10271A","35503D","45644C","1D3023","284332","62DBA0","FFC368","FF8986"]
        case (.plum, .light): values = ["FBF7FA","FFFFFF","FFFFFF","F3EAF1","342339","68516B","8A758C","934F89","934F89","FFFFFF","E5D5E2","D5BED1","FFFBFE","EFDFEA","08795D","9C5800","B62F48"]
        case (.plum, .dark): values = ["1B111C","2B1D2B","372538","241725","F6EAF4","D3BBD0","A68BA5","D68AC9","ECB0E1","301528","5A4058","70536D","312131","493047","65DBAE","FFC275","FF8DA0"]
        case (.original, _): return
        }
        for (token, value) in zip(Token.allCases, values) { _ = set(value, token: token, variant: variant) }
    }

    public init(serialized: String?) {
        self.init()
        guard let serialized, serialized.utf8.count <= Self.maximumBytes,
              let data = serialized.data(using: .utf8),
              let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let versionValue = root["version"] as? NSNumber,
              CFGetTypeID(versionValue) != CFBooleanGetTypeID(),
              versionValue.doubleValue == 1 else { return }
        for variant in Variant.allCases {
            guard let values = root[variant.rawValue] as? [String: Any] else { continue }
            for token in Token.allCases {
                if let raw = values[token.rawValue] as? String { _ = set(raw, token: token, variant: variant) }
            }
        }
    }
    public func serialized() -> String {
        let root: [String: Any] = ["version": 1, "light": light, "dark": dark]
        guard let data = try? JSONSerialization.data(withJSONObject: root, options: [.sortedKeys]), data.count <= Self.maximumBytes else { return "" }
        return String(decoding: data, as: UTF8.self)
    }
}
