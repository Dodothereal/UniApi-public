import Foundation

public enum StatisticsSource: String, CaseIterable, Codable, Sendable {
    case claude, codex, antigravity, zcode, opencode, dsh
}

struct StatisticsUsage: Codable, Sendable {
    var id: String
    var source: String
    var ts: Double
    var model: String
    var project: String = "unknown"
    var session: String = ""
    var sidechain: Bool = false
    var effort: String = ""
    var input: Double = 0
    var output: Double = 0
    var thinking: Double = 0
    var cacheWrite: Double = 0
    var cacheRead: Double = 0
    var webSearch: Double = 0
    var webFetch: Double = 0
    var durationMs: Double? = nil
    var timing: String? = nil
    // A matching generation output/stream-clock pair, never a response-time estimate.
    var streamDurationMs: Double? = nil
    var streamOutputTokens: Double? = nil
    var streamTiming: String? = nil
    var rawDay: String = ""
    var grand: Double { input + output + cacheWrite + cacheRead }
}

struct StatisticsTotals: Sendable {
    var messages: Double = 0, input: Double = 0, output: Double = 0, thinking: Double = 0
    var cacheWrite: Double = 0, cacheRead: Double = 0, webSearch: Double = 0, webFetch: Double = 0
    var grand: Double { input + output + cacheWrite + cacheRead }
    mutating func add(_ e: StatisticsUsage) {
        messages += 1; input += e.input; output += e.output; thinking += e.thinking
        cacheWrite += e.cacheWrite; cacheRead += e.cacheRead; webSearch += e.webSearch; webFetch += e.webFetch
    }
    mutating func add(_ t: StatisticsTotals) {
        messages += t.messages; input += t.input; output += t.output; thinking += t.thinking
        cacheWrite += t.cacheWrite; cacheRead += t.cacheRead; webSearch += t.webSearch; webFetch += t.webFetch
    }
    mutating func addReported(_ t: StatisticsTotals) {
        input += t.input; output += t.output; cacheWrite += t.cacheWrite; cacheRead += t.cacheRead; webSearch += t.webSearch
    }
    var json: JSONValue { ["messages": .number(messages), "input": .number(input), "output": .number(output), "thinking": .number(thinking), "cacheWrite": .number(cacheWrite), "cacheRead": .number(cacheRead), "webSearch": .number(webSearch), "webFetch": .number(webFetch)] }
}

struct StatisticsCache: Sendable {
    var totals = StatisticsTotals()
    var sessions: Double = 0, messages: Double = 0, activeDays: Int = 0, models: Int = 0
    var computedOn = "", firstDay = "", lastDay = ""
    var daily: [String: Double] = [:]
    var perModel: [String: StatisticsTotals] = [:]
    var json: JSONValue { ["totals": totals.json, "sessions": .number(sessions), "messages": .number(messages), "activeDays": .number(Double(activeDays)), "models": .number(Double(models)), "computedOn": .string(computedOn), "firstDay": .string(firstDay), "lastDay": .string(lastDay)] }
    static func parse(_ o: JSONValue) -> StatisticsCache? {
        guard case .object = o["modelUsage"] else { return nil }
        var c = StatisticsCache(); c.sessions = statisticsNumber(o["totalSessions"]); c.messages = statisticsNumber(o["totalMessages"])
        c.computedOn = o["lastComputedDate"].string; c.models = o["modelUsage"].object.count
        for (model, m) in o["modelUsage"].object {
            guard case .object = m else { continue }
            var t = StatisticsTotals()
            t.input = statisticsNumber(m["inputTokens"]); t.output = statisticsNumber(m["outputTokens"])
            t.cacheRead = statisticsNumber(m["cacheReadInputTokens"]); t.cacheWrite = statisticsNumber(m["cacheCreationInputTokens"])
            t.webSearch = statisticsNumber(m["webSearchRequests"]); c.totals.addReported(t)
            if t.grand > 0 && model != "unknown" { c.perModel[model] = t }
        }
        let dates = o["dailyActivity"].array.map { $0["date"].string }.filter { !$0.isEmpty }.sorted()
        c.activeDays = dates.count; c.firstDay = dates.first ?? ""; c.lastDay = dates.last ?? ""
        for row in o["dailyModelTokens"].array where !row["date"].string.isEmpty {
            c.daily[row["date"].string] = row["tokensByModel"].object.values.reduce(0) { $0 + statisticsNumber($1) }
        }
        return c.totals.grand > 0 ? c : nil
    }
}

func statisticsNumber(_ v: JSONValue, coerce: Bool = false) -> Double {
    if case .number(let n) = v, n.isFinite { return n }
    if coerce, let n = Double(v.string), n.isFinite { return n }
    return 0
}
func statisticsTokens(_ v: JSONValue) -> Double { max(0, statisticsNumber(v, coerce: true).rounded(.towardZero)) }
func statisticsTimestamp(_ v: JSONValue) -> Double? {
    StatisticsDateParser.shared.timestamp(v.string)
}
func statisticsDuration(_ start: Double?, _ end: Double?) -> Double? {
    guard let start, let end, start.isFinite, end.isFinite, start > 0, end > start else { return nil }
    return end - start
}
func statisticsUTC(_ ts: Double) -> String {
    var calendar = Calendar(identifier: .gregorian); calendar.timeZone = TimeZone(secondsFromGMT: 0)!
    return statisticsDayKey(ts, calendar: calendar)
}
func statisticsDay(_ ts: Double, calendar: Calendar = .current) -> Double { calendar.startOfDay(for: Date(timeIntervalSince1970: ts / 1000)).timeIntervalSince1970 * 1000 }
func statisticsDayKey(_ ts: Double, calendar: Calendar = .current) -> String {
    let c = calendar.dateComponents([.year, .month, .day], from: Date(timeIntervalSince1970: ts / 1000))
    return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
}
func statisticsValidDate(_ ts: Double) -> Bool { ts.isFinite && ts > 0 && abs(ts) <= 8_640_000_000_000_000 }
func statisticsDate(_ key: String, utc: Bool = false, calendar: Calendar = .current) -> Double? {
    let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.calendar = calendar; f.timeZone = utc ? TimeZone(secondsFromGMT: 0) : calendar.timeZone; f.dateFormat = "yyyy-MM-dd"; f.isLenient = false
    guard let d = f.date(from: String(key.prefix(10))), f.string(from: d) == String(key.prefix(10)) else { return nil }
    return d.timeIntervalSince1970 * 1000
}
func statisticsOptional(_ v: Double?) -> JSONValue { v.map(JSONValue.number) ?? .null }

private final class StatisticsDateParser: @unchecked Sendable {
    static let shared = StatisticsDateParser()
    private let lock = NSLock(), fractional = ISO8601DateFormatter(), plain = ISO8601DateFormatter(), day = DateFormatter()
    init() {
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]; plain.formatOptions = [.withInternetDateTime]
        day.calendar = Calendar(identifier: .gregorian); day.locale = Locale(identifier: "en_US_POSIX"); day.timeZone = TimeZone(secondsFromGMT: 0); day.dateFormat = "yyyy-MM-dd"; day.isLenient = false
    }
    func timestamp(_ value: String) -> Double? {
        if let timestamp = StatisticsTimestampFastPath.timestamp(value) { return timestamp }
        lock.lock(); defer { lock.unlock() }
        if let date = fractional.date(from: value) ?? plain.date(from: value) { return date.timeIntervalSince1970 * 1000 }
        if value.count == 10, let date = day.date(from: value), day.string(from: date) == value { return date.timeIntervalSince1970 * 1000 }
        return nil
    }
}
