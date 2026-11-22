import Foundation

/// One key press, identified only by its physical macOS virtual key code.
/// No character, text or ordering is retained beyond the counters below.
public struct NativeKeyboardEvent: Sendable, Equatable {
    public var code: Int
    public var command: Bool, control: Bool, option: Bool, shift: Bool
    public var repeated: Bool
    /// Milliseconds since 1970.
    public var time: Double
    public init(code: Int, command: Bool = false, control: Bool = false, option: Bool = false, shift: Bool = false, repeated: Bool = false, time: Double) {
        self.code = code; self.command = command; self.control = control; self.option = option; self.shift = shift
        self.repeated = repeated; self.time = time
    }
}

public enum NativeKeyboardKeys {
    public static let delete = 51, forwardDelete = 117, space = 49, returnKey = 36, tab = 48, keypadEnter = 76
    public static let modifiers: Set<Int> = [54, 55, 56, 57, 58, 59, 60, 61, 62, 63]
    static let keypad: Set<Int> = [65, 67, 69, 75, 78, 81, 82, 83, 84, 85, 86, 87, 88, 89, 91, 92]
    /// Keys that produce a visible character, excluding separators.
    public static let glyphs: Set<Int> = Set(0...50).subtracting([returnKey, tab, space]).union(keypad)
    public static let separators: Set<Int> = [space, returnKey, keypadEnter]
    public static func isCorrection(_ code: Int) -> Bool { code == delete || code == forwardDelete }
    public static func category(_ code: Int) -> String {
        if modifiers.contains(code) { return "Modifiers" }
        if isCorrection(code) { return "Corrections" }
        if code == space { return "Space" }
        if code == returnKey || code == keypadEnter || code == tab || code == 53 { return "Control keys" }
        if [123, 124, 125, 126, 115, 116, 119, 121].contains(code) { return "Navigation" }
        if [18, 19, 20, 21, 22, 23, 25, 26, 28, 29].contains(code) || (82...92).contains(code) { return "Digits" }
        if [0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 11, 12, 13, 14, 15, 16, 17, 31, 32, 34, 35, 37, 38, 40, 45, 46].contains(code) { return "Letters" }
        if glyphs.contains(code) { return "Punctuation" }
        return "Function keys"
    }
    /// `cmd+shift+8`: modifiers in a fixed order, then the key code.
    public static func combination(_ event: NativeKeyboardEvent) -> String {
        var parts: [String] = []
        if event.control { parts.append("ctrl") }
        if event.option { parts.append("opt") }
        if event.shift { parts.append("shift") }
        if event.command { parts.append("cmd") }
        return (parts + [String(event.code)]).joined(separator: "+")
    }
}

public struct NativeKeyboardSlot: Hashable, Sendable {
    public var day: String, hour: Int
    public init(day: String, hour: Int) { self.day = day; self.hour = hour }
    /// Local calendar day and hour of an event time.
    public static func local(_ milliseconds: Double, calendar: Calendar = .current) -> NativeKeyboardSlot {
        let parts = calendar.dateComponents([.year, .month, .day, .hour], from: Date(timeIntervalSince1970: milliseconds / 1000))
        return .init(day: String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0), hour: parts.hour ?? 0)
    }
}

public struct NativeKeyboardTotals: Sendable, Equatable {
    public var keys = 0, characters = 0, timedCharacters = 0, words = 0, deleted = 0, corrections = 0
    public var shortcuts = 0, repeats = 0, bursts = 0
    public var activeMs = 0.0, peakWpm = 0.0
    public init() {}
    public var isEmpty: Bool { self == .init() }
    public mutating func add(_ other: NativeKeyboardTotals) {
        keys += other.keys; characters += other.characters; timedCharacters += other.timedCharacters; words += other.words
        deleted += other.deleted; corrections += other.corrections; shortcuts += other.shortcuts; repeats += other.repeats
        bursts += other.bursts; activeMs += other.activeMs; peakWpm = max(peakWpm, other.peakWpm)
    }
    /// Five characters per word over the time spent typing.
    public var wpm: Double { activeMs >= 1000 ? Double(timedCharacters) / 5 / (activeMs / 60_000) : 0 }
    public var correctionRate: Double { characters > 0 ? Double(deleted) / Double(characters) : 0 }
}

public struct NativeKeyboardDelta: Sendable, Equatable {
    public var slots: [NativeKeyboardSlot: NativeKeyboardTotals] = [:]
    public var keys: [String: [Int: Int]] = [:]
    public var shortcuts: [String: [String: Int]] = [:]
    public init() {}
    public var isEmpty: Bool { slots.isEmpty && keys.isEmpty && shortcuts.isEmpty }
}

/// Folds key presses into counters. A pause longer than `pause` ends a typing
/// burst, so thinking time never lowers the reported speed.
public struct NativeKeyboardFold: Sendable {
    public static let pause = 2_000.0, liveWindow = 10_000.0
    private let slot: @Sendable (Double) -> NativeKeyboardSlot
    private var pending = NativeKeyboardDelta()
    private var lastTypedAt: Double?, burstStartedAt: Double?
    private var burstCharacters = 0, burstSlot: NativeKeyboardSlot?
    private var wordOpen = false, deleting = false
    private var recent: [Double] = []
    public private(set) var sessionKeys = 0
    public private(set) var lastKeyAt: Double?

    public init(slot: @escaping @Sendable (Double) -> NativeKeyboardSlot = { NativeKeyboardSlot.local($0) }) { self.slot = slot }

    public mutating func record(_ event: NativeKeyboardEvent) {
        guard event.time.isFinite, event.code >= 0, event.code < 512 else { return }
        let slot = slot(event.time)
        var totals = pending.slots[slot] ?? .init()
        defer { pending.slots[slot] = totals }
        lastKeyAt = event.time
        let chord = event.command || event.control
        if event.repeated {
            totals.repeats += 1
            if NativeKeyboardKeys.isCorrection(event.code), !chord { totals.deleted += 1; touch(event.time, &totals) }
            return
        }
        totals.keys += 1; sessionKeys += 1
        pending.keys[slot.day, default: [:]][event.code, default: 0] += 1
        if NativeKeyboardKeys.modifiers.contains(event.code) { return }
        if chord {
            totals.shortcuts += 1
            pending.shortcuts[slot.day, default: [:]][NativeKeyboardKeys.combination(event), default: 0] += 1
            return
        }
        if NativeKeyboardKeys.isCorrection(event.code) {
            totals.deleted += 1
            if !deleting { totals.corrections += 1; deleting = true }
            touch(event.time, &totals)
            return
        }
        let glyph = NativeKeyboardKeys.glyphs.contains(event.code), separator = NativeKeyboardKeys.separators.contains(event.code)
        guard glyph || separator else { return }
        deleting = false
        totals.characters += 1
        if let last = lastTypedAt, event.time >= last, event.time - last <= Self.pause {
            totals.activeMs += event.time - last; totals.timedCharacters += 1; burstCharacters += 1
        } else {
            if let peak = finishBurst() {
                if peak.slot == slot { totals.peakWpm = max(totals.peakWpm, peak.wpm) }
                else { pending.slots[peak.slot, default: .init()].peakWpm = max(pending.slots[peak.slot]?.peakWpm ?? 0, peak.wpm) }
            }
            burstStartedAt = event.time; burstCharacters = 1; totals.bursts += 1
        }
        lastTypedAt = event.time; burstSlot = slot
        if glyph { wordOpen = true } else if wordOpen { totals.words += 1; wordOpen = false }
        recent.append(event.time)
        if recent.count > 512 { recent.removeFirst(recent.count - 256) }
    }
    /// Correcting is part of typing time but adds no characters.
    private mutating func touch(_ time: Double, _ totals: inout NativeKeyboardTotals) {
        guard let last = lastTypedAt, time >= last, time - last <= Self.pause else { return }
        totals.activeMs += time - last; lastTypedAt = time
    }
    /// Ends the current burst and returns its speed when it was long enough to rank.
    private mutating func finishBurst() -> (slot: NativeKeyboardSlot, wpm: Double)? {
        defer { burstStartedAt = nil; burstCharacters = 0; burstSlot = nil; wordOpen = false; deleting = false }
        guard let start = burstStartedAt, let end = lastTypedAt, let slot = burstSlot, burstCharacters >= 25, end - start >= 4_000 else { return nil }
        return (slot, Double(burstCharacters - 1) / 5 / ((end - start) / 60_000))
    }
    /// Speed over the trailing window, or zero once typing has paused.
    public func liveWpm(now: Double) -> Double {
        guard let last = lastTypedAt, now - last <= Self.pause else { return 0 }
        let window = recent.filter { now - $0 <= Self.liveWindow }
        guard window.count >= 5, let first = window.first, last - first >= 1_500 else { return 0 }
        return Double(window.count - 1) / 5 / ((last - first) / 60_000)
    }
    /// Removes and returns everything counted since the previous drain.
    public mutating func drain(now: Double) -> NativeKeyboardDelta {
        if let last = lastTypedAt, now - last > Self.pause {
            if let peak = finishBurst() { pending.slots[peak.slot, default: .init()].peakWpm = max(pending.slots[peak.slot]?.peakWpm ?? 0, peak.wpm) }
            lastTypedAt = nil
        }
        recent.removeAll { now - $0 > Self.liveWindow }
        defer { pending = .init() }
        pending.slots = pending.slots.filter { !$0.value.isEmpty }
        return pending
    }
}
