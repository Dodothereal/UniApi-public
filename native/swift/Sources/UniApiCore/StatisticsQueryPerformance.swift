import Foundation

/// The overview's source cards need totals, not five complete chart boards.
/// Preserve the fold's event order and its UTC lifetime-tail reconciliation;
/// adding source totals together would change floating-point accumulation.
enum StatisticsSourceTotals {
    static func fold(_ events: [StatisticsUsage], range: Int, cache: StatisticsCache?, now: Double, calendar: Calendar) -> JSONValue {
        let cutoff = statisticsDay(now, calendar: calendar) - Double(range - 1) * 86_400_000
        let lifetime = range == 0 ? cache : nil
        let watermark = lifetime.flatMap { $0.computedOn.count == 10 && statisticsDate($0.computedOn, utc: true) != nil ? $0.computedOn : nil }
        var totals = Dictionary(uniqueKeysWithValues: StatisticsSource.allCases.map { ($0.rawValue, StatisticsTotals()) })
        var fresh = StatisticsTotals()
        for event in events where range == 0 || event.ts >= cutoff {
            totals[event.source, default: StatisticsTotals()].add(event)
            if event.source == "claude", let watermark, statisticsUTC(event.ts) > watermark { fresh.add(event) }
        }
        if let lifetime {
            let observed = totals["claude"] ?? StatisticsTotals()
            var reported = lifetime.totals
            reported.thinking = observed.thinking; reported.webFetch = observed.webFetch; reported.messages = lifetime.messages
            if watermark != nil { reported.addReported(fresh); reported.messages += fresh.messages }
            totals["claude"] = reported
        }
        return .object(Dictionary(uniqueKeysWithValues: StatisticsSource.allCases.map { ($0.rawValue, totals[$0.rawValue]!.json) }))
    }
}
