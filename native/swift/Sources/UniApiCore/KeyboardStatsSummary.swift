import Foundation

/// Turns stored counters into the figures the Keyboard Stats page shows.
public enum NativeKeyboardSummary {
    public static let ranges = ["today", "7d", "30d", "all"]

    public static func day(_ date: Date, calendar: Calendar) -> String {
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }
    static func date(_ day: String, calendar: Calendar) -> Date? {
        let parts = day.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3 else { return nil }
        return calendar.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2], hour: 12))
    }
    /// First day of a range, or nil for all time.
    public static func firstDay(_ range: String, now: Double, calendar: Calendar = .current) -> String? {
        let days: Int
        switch range {
        case "today": days = 0
        case "7d": days = 6
        case "30d": days = 29
        default: return nil
        }
        let today = Date(timeIntervalSince1970: now / 1000)
        return day(calendar.date(byAdding: .day, value: -days, to: today) ?? today, calendar: calendar)
    }
    /// Current and longest runs of consecutive days with typing.
    public static func streaks(_ days: [String], today: String, calendar: Calendar = .current) -> (current: Int, longest: Int) {
        let dates = Set(days).compactMap { date($0, calendar: calendar) }.sorted()
        var longest = 0, run = 0, previous: Date?
        for value in dates {
            if let previous, let next = calendar.date(byAdding: .day, value: 1, to: previous), calendar.isDate(next, inSameDayAs: value) { run += 1 } else { run = 1 }
            longest = max(longest, run); previous = value
        }
        guard let last = dates.last, let now = date(today, calendar: calendar) else { return (0, longest) }
        // A streak survives until a whole day passes without typing.
        let gap = calendar.dateComponents([.day], from: last, to: now).day ?? 99
        return (gap <= 1 ? run : 0, longest)
    }
    private static func totals(_ value: NativeKeyboardTotals) -> JSONObject {
        let minutes = value.activeMs / 60_000
        let net = value.activeMs >= 1000 ? max(0, Double(value.timedCharacters - value.deleted)) / 5 / minutes : 0
        return ["keys": .number(Double(value.keys)), "characters": .number(Double(value.characters)), "words": .number(Double(value.words)),
                "deleted": .number(Double(value.deleted)), "corrections": .number(Double(value.corrections)),
                "shortcuts": .number(Double(value.shortcuts)), "repeats": .number(Double(value.repeats)), "bursts": .number(Double(value.bursts)),
                "activeMs": .number(value.activeMs), "wpm": .number(value.wpm), "netWpm": .number(net), "peakWpm": .number(value.peakWpm),
                "correctionRate": .number(value.correctionRate),
                "accuracy": .number(value.characters > 0 ? max(0, 1 - value.correctionRate) : 0),
                "deletedPerCorrection": .number(value.corrections > 0 ? Double(value.deleted) / Double(value.corrections) : 0),
                "charactersPerCorrection": .number(value.corrections > 0 ? Double(value.characters) / Double(value.corrections) : 0),
                "charactersPerWord": .number(value.words > 0 ? Double(value.characters) / Double(value.words) : 0),
                "keysPerMinute": .number(value.activeMs >= 1000 ? Double(value.characters + value.deleted) / minutes : 0),
                "burstMs": .number(value.bursts > 0 ? value.activeMs / Double(value.bursts) : 0)]
    }

    public static func build(slots: [NativeKeyboardSlot: NativeKeyboardTotals], keys: [Int: Int], shortcuts: [String: Int],
                             allDays: [String], range: String, now: Double, iso: Bool, calendar: Calendar = .current) -> JSONObject {
        var total = NativeKeyboardTotals()
        var byDay: [String: NativeKeyboardTotals] = [:]
        var byHour = Array(repeating: NativeKeyboardTotals(), count: 24)
        var byWeekday = Array(repeating: NativeKeyboardTotals(), count: 7)
        for (slot, value) in slots {
            total.add(value); byDay[slot.day, default: .init()].add(value)
            if (0..<24).contains(slot.hour) { byHour[slot.hour].add(value) }
            if let date = date(slot.day, calendar: calendar) {
                // Monday first.
                byWeekday[(calendar.component(.weekday, from: date) + 5) % 7].add(value)
            }
        }
        let today = day(Date(timeIntervalSince1970: now / 1000), calendar: calendar)
        var dayNames = byDay.keys.sorted()
        if let first = firstDay(range, now: now, calendar: calendar), var cursor = date(first, calendar: calendar), let end = date(today, calendar: calendar) {
            dayNames = []
            while cursor <= end, dayNames.count < 400 {
                dayNames.append(day(cursor, calendar: calendar))
                guard let next = calendar.date(byAdding: .day, value: 1, to: cursor) else { break }
                cursor = next
            }
        }
        let active = byDay.filter { $0.value.keys > 0 }
        let best = active.max { ($0.value.keys, $1.key) < ($1.value.keys, $0.key) }
        let fastest = active.filter { $0.value.timedCharacters >= 200 }.max { $0.value.wpm < $1.value.wpm }
        let streak = streaks(allDays, today: today, calendar: calendar)
        let pressed = keys.values.reduce(0, +)
        var result = totals(total)
        result["days"] = .number(Double(active.count))
        result["keysPerDay"] = .number(active.isEmpty ? 0 : Double(total.keys) / Double(active.count))
        result["bestDay"] = best.map { ["day": .string($0.key), "keys": .number(Double($0.value.keys))] } ?? .null
        result["fastestDay"] = fastest.map { ["day": .string($0.key), "wpm": .number($0.value.wpm)] } ?? .null
        result["streak"] = .number(Double(streak.current)); result["longestStreak"] = .number(Double(streak.longest))
        result["uniqueKeys"] = .number(Double(keys.filter { $0.value > 0 }.count))
        result["travelMeters"] = .number(NativeKeyboardLayout.travelMeters(keys, iso: iso))
        let busiest = byHour.enumerated().max { ($0.element.keys, $1.offset) < ($1.element.keys, $0.offset) }
        result["busiestHour"] = (busiest?.element.keys ?? 0) > 0 ? .number(Double(busiest!.offset)) : .null

        func share(_ count: Int) -> JSONValue { .number(pressed > 0 ? Double(count) / Double(pressed) : 0) }
        let ranked = keys.filter { $0.value > 0 }.sorted { ($0.value, $1.key) > ($1.value, $0.key) }
        var categories: [String: Int] = [:], fingers: [String: Int] = [:], rows = Array(repeating: 0, count: NativeKeyboardLayout.rowTitles.count)
        var left = 0, right = 0
        let positions = NativeKeyboardLayout.positions(iso: iso)
        for (code, count) in keys {
            categories[NativeKeyboardKeys.category(code), default: 0] += count
            if let finger = NativeKeyboardLayout.finger(code) {
                fingers[finger.rawValue, default: 0] += count
                if finger.left == true { left += count } else if finger.left == false { right += count }
            }
            if let row = positions[code]?.row { rows[row] += count }
        }
        func series(_ value: NativeKeyboardTotals) -> JSONObject {
            ["keys": .number(Double(value.keys)), "characters": .number(Double(value.characters)), "deleted": .number(Double(value.deleted)),
             "words": .number(Double(value.words)), "wpm": .number(value.wpm), "activeMs": .number(value.activeMs),
             "correctionRate": .number(value.correctionRate)]
        }
        return [
            "range": .string(ranges.contains(range) ? range : "all"), "today": .string(today), "iso": .bool(iso),
            "totals": .object(result),
            "keys": .array(ranked.map { ["code": .number(Double($0.key)), "count": .number(Double($0.value)), "share": share($0.value),
                                         "category": .string(NativeKeyboardKeys.category($0.key))] }),
            "categories": .array(categories.sorted { ($0.value, $1.key) > ($1.value, $0.key) }.map { ["name": .string($0.key), "count": .number(Double($0.value)), "share": share($0.value)] }),
            "fingers": .array(NativeKeyboardLayout.Finger.allCases.map { ["id": .string($0.rawValue), "name": .string($0.title), "count": .number(Double(fingers[$0.rawValue] ?? 0)), "share": share(fingers[$0.rawValue] ?? 0)] }),
            "hands": ["left": .number(Double(left)), "right": .number(Double(right)),
                      "leftShare": .number(left + right > 0 ? Double(left) / Double(left + right) : 0)],
            "rows": .array(rows.enumerated().map { ["name": .string(NativeKeyboardLayout.rowTitles[$0.offset]), "count": .number(Double($0.element)), "share": share($0.element)] }),
            "hours": .array(byHour.enumerated().map { var item = series($0.element); item["hour"] = .number(Double($0.offset)); return .object(item) }),
            "weekdays": .array(byWeekday.enumerated().map { var item = series($0.element); item["weekday"] = .number(Double($0.offset)); return .object(item) }),
            "daily": .array(dayNames.map { var item = series(byDay[$0] ?? .init()); item["day"] = .string($0); return .object(item) }),
            "shortcuts": .array(shortcuts.filter { $0.value > 0 }.sorted { ($0.value, $1.key) > ($1.value, $0.key) }.prefix(12).map { ["combo": .string($0.key), "count": .number(Double($0.value))] })
        ]
    }
}
