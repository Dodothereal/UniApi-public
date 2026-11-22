import Foundation

/// Physical arrangement of a Mac laptop keyboard and the touch-typing finger
/// for each key. Codes are macOS virtual key codes, which name positions.
public enum NativeKeyboardLayout {
    public struct Key: Sendable, Equatable, Identifiable {
        public var code: Int
        /// Width in key units; a regular letter key is one unit.
        public var width: Double
        /// A second key in the lower half of the same cell.
        public var lower: Int?
        /// Second cell of a key that spans two rows.
        public var continuation: Bool
        public var id: String { "\(code)-\(continuation)" }
        public init(_ code: Int, _ width: Double = 1, lower: Int? = nil, continuation: Bool = false) {
            self.code = code; self.width = width; self.lower = lower; self.continuation = continuation
        }
    }
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

    /// ISO boards add a key beside the left shift and move two others.
    public static func rows(iso: Bool) -> [[Key]] {
        let function = [Key(53, 1.5)] + [122, 120, 99, 118, 96, 97, 98, 100, 101, 109, 103, 111].map { Key($0, 13.0 / 12.0) }
        let numbers = [Key(iso ? 10 : 50)] + [18, 19, 20, 21, 23, 22, 26, 28, 25, 29, 27, 24].map { Key($0) } + [Key(51, 1.5)]
        let letters = [12, 13, 14, 15, 17, 16, 32, 34, 31, 35, 33, 30].map { Key($0) }
        let top = [Key(48, 1.5)] + letters + [iso ? Key(36, 1) : Key(42, 1)]
        let middle = [0, 1, 2, 3, 5, 4, 38, 40, 37, 41, 39].map { Key($0) }
        let home = [Key(57, 1.75)] + middle + (iso ? [Key(42), Key(36, 0.75, continuation: true)] : [Key(36, 1.75)])
        let lower = [6, 7, 8, 9, 11, 45, 46, 43, 47, 44].map { Key($0) }
        let bottom = (iso ? [Key(56, 1.25), Key(50)] : [Key(56, 2.25)]) + lower + [Key(60, 2.25)]
        let base = [Key(63), Key(59), Key(58), Key(55, 1.25), Key(49, 5), Key(54, 1.25), Key(61), Key(123), Key(126, lower: 125), Key(124)]
        return [function, numbers, top, home, bottom, base]
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
        assign(.rightPinky, [29, 27, 24, 51, 35, 33, 30, 42, 41, 39, 36, 44, 60, 123, 124, 125, 126])
        assign(.thumbs, [49, 55, 54, 58, 61])
        return map
    }()
    public static func finger(_ code: Int) -> Finger? { fingers[code] }

    /// Row index and horizontal centre in key units.
    public static func positions(iso: Bool) -> [Int: (row: Int, x: Double)] {
        var result: [Int: (row: Int, x: Double)] = [:]
        for (row, keys) in rows(iso: iso).enumerated() {
            var x = 0.0
            for key in keys {
                if !key.continuation {
                    result[key.code] = (row, x + key.width / 2)
                    if let lower = key.lower { result[lower] = (row, x + key.width / 2) }
                }
                x += key.width
            }
        }
        return result
    }
    public static func row(_ code: Int, iso: Bool) -> Int? { positions(iso: iso)[code]?.row }

    /// Distance from the finger's home key to each key and back, assuming
    /// touch typing. An estimate of reach, not a measurement.
    public static func travelMeters(_ counts: [Int: Int], iso: Bool) -> Double {
        let positions = positions(iso: iso)
        var millimetres = 0.0
        for (code, count) in counts {
            guard let finger = fingers[code], let home = finger.home, let from = positions[home], let to = positions[code] else { continue }
            let dx = to.x - from.x, dy = Double(to.row - from.row)
            millimetres += 2 * (dx * dx + dy * dy).squareRoot() * pitch * Double(count)
        }
        return millimetres / 1000
    }

    /// US labels, used when the active input source cannot be read.
    public static let labels: [Int: String] = [
        0: "A", 1: "S", 2: "D", 3: "F", 4: "H", 5: "G", 6: "Z", 7: "X", 8: "C", 9: "V", 10: "\u{00A7}", 11: "B", 12: "Q", 13: "W", 14: "E", 15: "R",
        16: "Y", 17: "T", 18: "1", 19: "2", 20: "3", 21: "4", 22: "6", 23: "5", 24: "=", 25: "9", 26: "7", 27: "-", 28: "8", 29: "0", 30: "]",
        31: "O", 32: "U", 33: "[", 34: "I", 35: "P", 37: "L", 38: "J", 39: "'", 40: "K", 41: ";", 42: "\\", 43: ",", 44: "/", 45: "N", 46: "M",
        47: ".", 50: "`", 65: "Num .", 67: "Num *", 69: "Num +", 75: "Num /", 76: "Enter", 78: "Num -", 81: "Num =",
        82: "Num 0", 83: "Num 1", 84: "Num 2", 85: "Num 3", 86: "Num 4", 87: "Num 5", 88: "Num 6", 89: "Num 7", 91: "Num 8", 92: "Num 9"
    ]
    /// Names of keys that do not print a character on any layout.
    public static let named: [Int: String] = [
        36: "Return", 48: "Tab", 49: "Space", 51: "Delete", 53: "Esc", 54: "Cmd", 55: "Cmd", 56: "Shift", 57: "Caps", 58: "Opt", 59: "Ctrl",
        60: "Shift", 61: "Opt", 62: "Ctrl", 63: "Fn", 71: "Clear", 76: "Enter", 114: "Help", 115: "Home", 116: "Page Up", 117: "Fwd Del", 119: "End",
        121: "Page Down", 123: "Left", 124: "Right", 125: "Down", 126: "Up", 122: "F1", 120: "F2", 99: "F3", 118: "F4", 96: "F5", 97: "F6",
        98: "F7", 100: "F8", 101: "F9", 109: "F10", 103: "F11", 111: "F12", 105: "F13", 107: "F14", 113: "F15", 106: "F16", 64: "F17", 79: "F18", 80: "F19"
    ]
    public static func label(_ code: Int) -> String { named[code] ?? labels[code] ?? "Key \(code)" }
}
