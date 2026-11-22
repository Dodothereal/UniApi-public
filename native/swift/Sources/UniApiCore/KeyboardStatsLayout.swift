import Foundation

/// A keyboard macOS lists, reduced to what choosing a drawing needs.
public struct NativeKeyboardDevice: Sendable, Equatable {
    public var name: String
    public var builtIn: Bool, apple: Bool
    public init(name: String, builtIn: Bool = false, apple: Bool = false) { self.name = name; self.builtIn = builtIn; self.apple = apple }
}

/// What macOS reports about the keyboards in use.
public struct NativeKeyboardHardware: Sendable, Equatable {
    public var devices: [NativeKeyboardDevice]
    /// Physical standard of the keyboard typed on most recently.
    public var standard: NativeKeyboardLayout.Standard
    /// macOS did not recognise that keyboard as an Apple model.
    public var generic: Bool
    public init(devices: [NativeKeyboardDevice] = [], standard: NativeKeyboardLayout.Standard = .ansi, generic: Bool = false) {
        self.devices = devices; self.standard = standard; self.generic = generic
    }
}

/// Physical arrangement of the keyboard in use and the touch-typing finger
/// for each key. Codes are macOS virtual key codes, which name positions.
public enum NativeKeyboardLayout {
    public enum Standard: String, CaseIterable, Sendable {
        case ansi, iso, jis
        public var title: String { rawValue.uppercased() }
    }
    public enum Form: String, CaseIterable, Sendable {
        case compact, tenkeyless, full
        public var title: String {
            switch self {
            case .compact: return "Compact"
            case .tenkeyless: return "Tenkeyless"
            case .full: return "Full size"
            }
        }
    }
    public enum Section: Sendable { case main, navigation, numpad }
    public struct Model: Sendable, Equatable {
        public var standard: Standard, form: Form
        /// Apple boards have a Fn key and Apple's modifier order.
        public var apple: Bool
        /// Product name macOS reports, or empty when none was found.
        public var name: String
        public init(standard: Standard = .ansi, form: Form = .compact, apple: Bool = true, name: String = "") {
            self.standard = standard; self.form = form; self.apple = apple; self.name = name
        }
    }
    /// One key cap. Positions and sizes are in key units from the top left;
    /// a regular letter key is one unit wide and one unit tall.
    public struct Key: Sendable, Equatable, Identifiable {
        /// Negative for a cap that sends no key code, such as Touch ID.
        public var code: Int
        public var x: Double, y: Double, width: Double, height: Double
        /// Width cut from the lower left of a two-row Return key.
        public var notch: Double
        public var section: Section
        public var id: Int { code }
        public var centre: (x: Double, y: Double) { (x + width / 2, y + height / 2) }
        /// Index into `rowTitles`.
        public var row: Int { Int((y + height - 0.5).rounded(.down)) }
    }
    public static let touchID = -1
    public enum Finger: String, CaseIterable, Sendable {
        case leftPinky, leftRing, leftMiddle, leftIndex, thumbs, rightIndex, rightMiddle, rightRing, rightPinky
        public var title: String {
            switch self {
            case .leftPinky: return "Left pinky"
            case .leftRing: return "Left ring"
            case .leftMiddle: return "Left middle"
            case .leftIndex: return "Left index"
            case .thumbs: return "Thumbs"
            case .rightIndex: return "Right index"
            case .rightMiddle: return "Right middle"
            case .rightRing: return "Right ring"
            case .rightPinky: return "Right pinky"
            }
        }
        public var left: Bool? {
            switch self {
            case .leftPinky, .leftRing, .leftMiddle, .leftIndex: return true
            case .rightIndex, .rightMiddle, .rightRing, .rightPinky: return false
            case .thumbs: return nil
            }
        }
        var home: Int? {
            switch self {
            case .leftPinky: return 0
            case .leftRing: return 1
            case .leftMiddle: return 2
            case .leftIndex: return 3
            case .rightIndex: return 38
            case .rightMiddle: return 40
            case .rightRing: return 37
            case .rightPinky: return 41
            case .thumbs: return nil
            }
        }
    }
    public static let rowTitles = ["Function row", "Number row", "Top row", "Home row", "Bottom row", "Space row"]
    /// Millimetres between the centres of adjacent keys.
    public static let pitch = 19.05
    public static let mainWidth = 14.5

    private struct Line {
        var keys: [Key] = []
        var x: Double
        let y: Double, section: Section
        init(_ y: Double, x: Double = 0, _ section: Section = .main) { self.y = y; self.x = x; self.section = section }
        mutating func add(_ code: Int, _ width: Double = 1, height: Double = 1, down: Double = 0, notch: Double = 0) {
            keys.append(.init(code: code, x: x, y: y + down, width: width, height: height, notch: notch, section: section)); x += width
        }
        mutating func add(_ codes: [Int], _ width: Double = 1) { for code in codes { add(code, width) } }
        mutating func gap(_ width: Double) { x += width }
        /// Left, a stacked Up and Down, and Right in the lower half of the row.
        mutating func arrows() {
            add(123, height: 0.5, down: 0.5); add(126, height: 0.5); x -= 1; add(125, height: 0.5, down: 0.5); add(124, height: 0.5, down: 0.5)
        }
    }

    /// Every key cap of a keyboard model.
    public static func keys(_ model: Model) -> [Key] {
        let standard = model.standard, apple = model.apple, compact = model.form == .compact
        var function = Line(0)
        if apple {
            function.add(53, 1.5)
            if compact { function.add([122, 120, 99, 118, 96, 97, 98, 100, 101, 109, 103, 111]); function.add(touchID) }
            else { function.add([122, 120, 99, 118, 96, 97, 98, 100, 101, 109, 103, 111], 13.0 / 12.0) }
        } else {
            function.add(53)
            for group in [[122, 120, 99, 118], [96, 97, 98, 100], [101, 109, 103, 111]] { function.gap(0.5); function.add(group) }
        }
        var numbers = Line(1)
        let digits = [18, 19, 20, 21, 23, 22, 26, 28, 25, 29, 27, 24]
        switch standard {
        case .ansi: numbers.add(50); numbers.add(digits)
        case .iso: numbers.add(10); numbers.add(digits)
        case .jis: numbers.add(digits); numbers.add(93)
        }
        numbers.add(51, 1.5)
        var top = Line(2)
        top.add(48, 1.5); top.add([12, 13, 14, 15, 17, 16, 32, 34, 31, 35, 33, 30])
        if standard == .ansi { top.add(42) } else { top.add(36, height: 2, notch: 0.25) }
        var home = Line(3)
        home.add(standard == .jis && apple ? 59 : 57, 1.75); home.add([0, 1, 2, 3, 5, 4, 38, 40, 37, 41, 39])
        if standard == .ansi { home.add(36, 1.75) } else { home.add(42) }
        var bottom = Line(4)
        let lower = [6, 7, 8, 9, 11, 45, 46, 43, 47, 44]
        switch standard {
        case .ansi: bottom.add(56, 2.25); bottom.add(lower); bottom.add(60, 2.25)
        case .iso: bottom.add(56, 1.25); bottom.add(50); bottom.add(lower); bottom.add(60, 2.25)
        case .jis: bottom.add(56, 2.25); bottom.add(lower); bottom.add(94); bottom.add(60, 1.25)
        }
        var space = Line(5)
        let jis = standard == .jis
        switch (compact, apple) {
        case (true, true):
            if jis { space.add(57); space.add(58); space.add(55, 1.25); space.add(102, 1.25); space.add(49, 3.5); space.add(104, 1.25); space.add(54, 1.25); space.add(63) }
            else { space.add([63, 59, 58]); space.add(55, 1.25); space.add(49, 5); space.add(54, 1.25); space.add(61) }
            space.arrows()
        case (true, false):
            space.add([59, 58, 55], 1.25)
            if jis { space.add(102); space.add(49, 3.25); space.add(104) } else { space.add(49, 5.25) }
            space.add([54, 61], 1.25); space.arrows()
        case (false, _):
            let left = jis && apple ? 57 : 59
            space.add(left, jis && apple ? 1.25 : 1.5); space.add(58, 1.25); space.add(55, 1.5)
            if jis { space.add(102, 1.25); space.add(49, 3.5); space.add(104, 1.25) } else { space.add(49, 6) }
            space.add(54, 1.5); space.add(61, 1.25); space.add(62, jis && apple ? 1.75 : 1.5)
        }
        var result = [function, numbers, top, home, bottom, space].flatMap(\.keys)
        guard !compact else { return result }

        let navigationX = mainWidth + 0.5
        var navigation: [Line] = []
        var line = Line(0, x: navigationX, .navigation); line.add([105, 107, 113]); navigation.append(line)
        line = Line(1, x: navigationX, .navigation); line.add([apple ? 63 : 114, 115, 116]); navigation.append(line)
        line = Line(2, x: navigationX, .navigation); line.add([117, 119, 121]); navigation.append(line)
        line = Line(4, x: navigationX + 1, .navigation); line.add(126); navigation.append(line)
        line = Line(5, x: navigationX, .navigation); line.add([123, 125, 124]); navigation.append(line)
        result += navigation.flatMap(\.keys)
        guard model.form == .full else { return result }

        let padX = navigationX + 3.5
        var pad: [Line] = []
        func row(_ y: Double, _ build: (inout Line) -> Void) { var line = Line(y, x: padX, .numpad); build(&line); pad.append(line) }
        if apple {
            row(0) { $0.add([106, 64, 79, 80]) }
            row(1) { $0.add([71, 81, 75, 67]) }
            row(2) { $0.add([89, 91, 92, 78]) }
            row(3) { $0.add([86, 87, 88, 69]) }
        } else {
            row(1) { $0.add([71, 75, 67, 78]) }
            row(2) { $0.add([89, 91, 92]); $0.add(69, height: 2) }
            row(3) { $0.add([86, 87, 88]) }
        }
        row(4) { $0.add([83, 84, 85]); $0.add(76, height: 2) }
        row(5) { $0.add(82, 2); $0.add(65) }
        return result + pad.flatMap(\.keys)
    }
    /// Width and height of a model in key units.
    public static func size(_ model: Model) -> (width: Double, height: Double) {
        switch model.form {
        case .compact: return (mainWidth, 6)
        case .tenkeyless: return (mainWidth + 3.5, 6)
        case .full: return (mainWidth + 8, 6)
        }
    }

    static let keypadDigits: Set<Int> = [65, 67, 69, 75, 78, 82, 83, 84, 85, 86, 87, 88, 89, 91, 92]
    static let navigationKeys: Set<Int> = [105, 107, 113, 114, 115, 116, 117, 119, 121]
    private static let notKeyboards = ["receiver", "mouse", "yubikey", "virtualhid", "headset", "controller"]

    /// Chooses the drawing closest to the keyboard in use. macOS names the
    /// connected keyboards and the physical standard but not the number of
    /// keys, so the size of an unrecognised board follows the keys that have
    /// been pressed: a number pad that was used is drawn.
    public static func detect(_ hardware: NativeKeyboardHardware, used: Set<Int>) -> Model {
        let devices = hardware.devices.filter { device in
            device.builtIn || !notKeyboards.contains { device.name.lowercased().contains($0) }
        }
        let external = devices.filter { !$0.builtIn }
        let appleExternal = external.filter(\.apple), other = external.filter { !$0.apple }
        let pad = !used.isDisjoint(with: keypadDigits)
        func foreign(_ device: NativeKeyboardDevice?) -> Model {
            let form: Form = pad ? .full : (used.isDisjoint(with: navigationKeys) ? .compact : .tenkeyless)
            return .init(standard: hardware.standard, form: form, apple: false, name: device?.name ?? "")
        }
        if hardware.generic, !other.isEmpty || devices.isEmpty { return foreign(other.first { $0.name.lowercased().contains("keyboard") } ?? other.first) }
        if let device = appleExternal.first(where: { $0.name.lowercased().contains("keypad") }) {
            return .init(standard: hardware.standard, form: .full, apple: true, name: device.name)
        }
        // Fn with an arrow sends Home and End on a compact Apple board, so
        // only number-pad keys show that a larger one is in use.
        if let device = appleExternal.first { return .init(standard: hardware.standard, form: pad ? .full : .compact, apple: true, name: device.name) }
        if let device = devices.first(where: \.builtIn) { return .init(standard: hardware.standard, form: .compact, apple: true, name: device.name) }
        if let device = other.first { return foreign(device) }
        return .init(standard: hardware.standard, form: pad ? .full : .compact, apple: !hardware.generic, name: "")
    }

    private static let fingers: [Int: Finger] = {
        var map: [Int: Finger] = [:]
        func assign(_ finger: Finger, _ codes: [Int]) { for code in codes { map[code] = finger } }
        assign(.leftPinky, [53, 50, 10, 18, 48, 12, 57, 0, 56, 6, 63, 59])
        assign(.leftRing, [19, 13, 1, 7])
        assign(.leftMiddle, [20, 14, 2, 8])
        assign(.leftIndex, [21, 23, 15, 17, 3, 5, 9, 11])
        assign(.rightIndex, [22, 26, 16, 32, 4, 38, 45, 46])
        assign(.rightMiddle, [28, 34, 40, 43])
        assign(.rightRing, [25, 31, 37, 47])
        assign(.rightPinky, [29, 27, 24, 93, 51, 35, 33, 30, 42, 41, 39, 36, 44, 94, 60, 62, 123, 124, 125, 126])
        assign(.thumbs, [49, 55, 54, 58, 61, 102, 104])
        return map
    }()
    public static func finger(_ code: Int) -> Finger? { fingers[code] }

    public static func positions(_ model: Model) -> [Int: Key] {
        Dictionary(keys(model).filter { $0.code >= 0 }.map { ($0.code, $0) }, uniquingKeysWith: { first, _ in first })
    }
    /// Row of a key in the main block; number pad and navigation keys have none.
    public static func row(_ code: Int, _ model: Model) -> Int? {
        positions(model)[code].flatMap { $0.section == .main ? $0.row : nil }
    }

    /// Distance from the finger's home key to each key and back, assuming
    /// touch typing. An estimate of reach, not a measurement.
    public static func travelMeters(_ counts: [Int: Int], _ model: Model) -> Double {
        let positions = positions(model)
        var millimetres = 0.0
        for (code, count) in counts {
            guard let finger = fingers[code], let home = finger.home, let from = positions[home]?.centre, let to = positions[code]?.centre else { continue }
            let dx = to.x - from.x, dy = to.y - from.y
            millimetres += 2 * (dx * dx + dy * dy).squareRoot() * pitch * Double(count)
        }
        return millimetres / 1000
    }

    /// US labels, used when the active input source cannot be read.
    public static let labels: [Int: String] = [
        0: "A", 1: "S", 2: "D", 3: "F", 4: "H", 5: "G", 6: "Z", 7: "X", 8: "C", 9: "V", 10: "\u{00A7}", 11: "B", 12: "Q", 13: "W", 14: "E", 15: "R",
        16: "Y", 17: "T", 18: "1", 19: "2", 20: "3", 21: "4", 22: "6", 23: "5", 24: "=", 25: "9", 26: "7", 27: "-", 28: "8", 29: "0", 30: "]",
        31: "O", 32: "U", 33: "[", 34: "I", 35: "P", 37: "L", 38: "J", 39: "'", 40: "K", 41: ";", 42: "\\", 43: ",", 44: "/", 45: "N", 46: "M",
        47: ".", 50: "`", 93: "\u{00A5}", 94: "_", 65: "Num .", 67: "Num *", 69: "Num +", 75: "Num /", 76: "Enter", 78: "Num -", 81: "Num =",
        82: "Num 0", 83: "Num 1", 84: "Num 2", 85: "Num 3", 86: "Num 4", 87: "Num 5", 88: "Num 6", 89: "Num 7", 91: "Num 8", 92: "Num 9"
    ]
    /// Names of keys that do not print a character on any layout.
    public static let named: [Int: String] = [
        36: "Return", 48: "Tab", 49: "Space", 51: "Delete", 53: "Esc", 54: "Cmd", 55: "Cmd", 56: "Shift", 57: "Caps", 58: "Opt", 59: "Ctrl",
        60: "Shift", 61: "Opt", 62: "Ctrl", 63: "Fn", 71: "Clear", 102: "Eisu", 104: "Kana", 76: "Enter", 114: "Help", 115: "Home", 116: "Page Up", 117: "Fwd Del", 119: "End",
        121: "Page Down", 123: "Left", 124: "Right", 125: "Down", 126: "Up", 122: "F1", 120: "F2", 99: "F3", 118: "F4", 96: "F5", 97: "F6",
        98: "F7", 100: "F8", 101: "F9", 109: "F10", 103: "F11", 111: "F12", 105: "F13", 107: "F14", 113: "F15", 106: "F16", 64: "F17", 79: "F18", 80: "F19"
    ]
    public static func label(_ code: Int) -> String { named[code] ?? labels[code] ?? "Key \(code)" }

    /// Legends printed on keys that carry a word or a symbol rather than a
    /// character: the word used on US boards and the international symbol.
    public static let caps: [Int: (word: String, symbol: String)] = [
        36: ("return", "\u{21A9}"), 48: ("tab", "\u{21E5}"), 49: ("", ""), 51: ("delete", "\u{232B}"), 53: ("esc", "esc"),
        54: ("\u{2318}", "\u{2318}"), 55: ("\u{2318}", "\u{2318}"), 56: ("shift", "\u{21E7}"), 60: ("shift", "\u{21E7}"),
        57: ("caps lock", "\u{21EA}"), 58: ("\u{2325}", "\u{2325}"), 61: ("\u{2325}", "\u{2325}"), 59: ("\u{2303}", "\u{2303}"),
        62: ("\u{2303}", "\u{2303}"), 63: ("fn", "fn"), 71: ("clear", "\u{2327}"), 76: ("enter", "\u{2324}"), 102: ("\u{82F1}\u{6570}", "\u{82F1}\u{6570}"),
        104: ("\u{304B}\u{306A}", "\u{304B}\u{306A}"), 114: ("help", "help"), 115: ("home", "\u{2196}"), 116: ("pg up", "\u{21DE}"),
        117: ("del", "\u{2326}"), 119: ("end", "\u{2198}"), 121: ("pg dn", "\u{21DF}"), 123: ("\u{2190}", "\u{2190}"),
        124: ("\u{2192}", "\u{2192}"), 125: ("\u{2193}", "\u{2193}"), 126: ("\u{2191}", "\u{2191}")
    ]
}
