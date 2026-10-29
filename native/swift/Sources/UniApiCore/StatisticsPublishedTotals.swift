import Foundation

/// Home and the summary operation need three counters, not a chart board.
/// Keep the full fold's accumulation order: lifetime reconciliation combines
/// Claude first and all other sources together, never per-source subtotals.
struct StatisticsPublishedTotals {
    let totals: StatisticsTotals
    let models: Int

    static func fold(_ events: [StatisticsUsage], cache: StatisticsCache?) -> StatisticsPublishedTotals {
        var models = Set<String>()
        guard let cache else {
            var totals = StatisticsTotals()
            for event in events { totals.add(event); models.insert(event.model) }
            return StatisticsPublishedTotals(totals: totals, models: models.count)
        }

        let watermarkValid = cache.computedOn.count == 10 && statisticsDate(cache.computedOn, utc: true) != nil
        var claude = StatisticsTotals(), others = StatisticsTotals(), fresh = StatisticsTotals()
        for event in events {
            models.insert(event.model)
            if event.source == "claude" {
                claude.add(event)
                if watermarkValid, statisticsUTC(event.ts) > cache.computedOn { fresh.add(event) }
            } else { others.add(event) }
        }
        var totals = cache.totals
        totals.thinking = claude.thinking; totals.webFetch = claude.webFetch
        totals.messages = cache.messages
        if watermarkValid { totals.addReported(fresh); totals.messages += fresh.messages }
        totals.add(others)
        models.formUnion(cache.perModel.keys)
        return StatisticsPublishedTotals(totals: totals, models: models.count)
    }
}
