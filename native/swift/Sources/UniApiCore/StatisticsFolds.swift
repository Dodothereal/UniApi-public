import Foundation

struct StatisticsSummary {
    var totals = StatisticsTotals(), sessions = 0, projects = 0, models = 0, activeDays = 0
    var sidechainMessages = 0, sidechainTokens: Double = 0, proxyMessages = 0
    var effort: [String: Int] = [:], first: Double? = nil, last: Double? = nil
    var json: JSONValue { ["totals": totals.json, "sessions": .number(Double(sessions)), "projects": .number(Double(projects)), "models": .number(Double(models)), "activeDays": .number(Double(activeDays)), "sidechainMessages": .number(Double(sidechainMessages)), "sidechainTokens": .number(sidechainTokens), "proxyMessages": .number(Double(proxyMessages)), "effort": .object(effort.mapValues { .number(Double($0)) }), "first": statisticsOptional(first), "last": statisticsOptional(last)] }
}
struct StatisticsModel {
    var model: String, totals = StatisticsTotals(), days = 0, sessions = 0
    var first: Double? = nil, last: Double? = nil, pruned = false, viaProxy = false
    var json: JSONValue { ["model": .string(model), "totals": totals.json, "days": .number(Double(days)), "sessions": .number(Double(sessions)), "first": statisticsOptional(first), "last": statisticsOptional(last), "pruned": .bool(pruned), "viaProxy": .bool(viaProxy)] }
}
struct StatisticsSpeed {
    var timedResponses = 0, totalResponses = 0, outputTokens: Double = 0, durationMs: Double = 0, estimatedResponses = 0
    var avg: Double? { durationMs > 0 ? outputTokens * 1000 / durationMs : nil }
    mutating func add(_ e: StatisticsUsage, streaming: Bool = false) {
        totalResponses += 1
        let duration: Double?, output: Double
        if streaming {
            // Only source-verified clocks paired with the same generation's full
            // generated output qualify. Tool stdout, cache and untimed history
            // never enter either side of the ratio.
            let verified = e.source == "antigravity" && e.streamTiming == "antigravity-stream-duration"
                || e.source == "dsh" && e.streamTiming == "dsh-host-chunk-clock"
            guard verified, let matched = e.streamOutputTokens, matched == e.output else { return }
            duration = e.streamDurationMs; output = matched
        } else { duration = e.durationMs; output = e.output }
        guard let duration, duration.isFinite, duration > 0, output.isFinite, output > 0 else { return }
        if streaming {
            guard (output * 1000 / duration).isFinite, (outputTokens + output).isFinite, (durationMs + duration).isFinite else { return }
        }
        timedResponses += 1; outputTokens += output; durationMs += duration
        if !streaming && e.timing == "estimated" { estimatedResponses += 1 }
    }
    var json: JSONValue { ["avgTps": statisticsOptional(avg), "timedResponses": .number(Double(timedResponses)), "totalResponses": .number(Double(totalResponses)), "outputTokens": .number(outputTokens), "durationMs": .number(durationMs), "estimatedResponses": .number(Double(estimatedResponses))] }
}
struct StatisticsDerived {
    var summary = StatisticsSummary(), models: [StatisticsModel] = [], days: [JSONValue] = [], projects: [JSONValue] = []
    var heat = Array(repeating: Array(repeating: 0, count: 24), count: 7)
    var throughput: JSONValue = [:], stackModels: [String] = [], stackDropped = 0, onDiskGrand: Double = 0, isLifetime = false, events = 0
    var json: JSONValue { ["summary": summary.json, "models": .array(models.map(\.json)), "days": .array(days), "projects": .array(projects), "heat": .array(heat.map { .array($0.map { .number(Double($0)) }) }), "throughput": throughput, "stackModels": .array(stackModels.map(JSONValue.string)), "stackDropped": .number(Double(stackDropped)), "onDiskGrand": .number(onDiskGrand), "isLifetime": .bool(isLifetime), "events": .number(Double(events)), "cost": StatisticsPricing.fold(models)] }
}

enum StatisticsFold {
    static func filtered(_ evs: [StatisticsUsage], range: Int, now: Double, calendar: Calendar) -> [StatisticsUsage] {
        // Match the current server's local-midnight cutoff, including its fixed-day window.
        let cutoff = statisticsDay(now, calendar: calendar) - Double(range - 1) * 86_400_000
        return range == 0 ? evs : evs.filter { $0.ts >= cutoff }
    }
    static func summary(_ events: [StatisticsUsage], calendar: Calendar) -> StatisticsSummary {
        var s = StatisticsSummary(), sessions = Set<String>(), projects = Set<String>(), models = Set<String>(), days = Set<Double>()
        var dates = StatisticsCalendarCursor(calendar: calendar)
        for e in events {
            s.totals.add(e); sessions.insert(e.session); projects.insert(e.project); models.insert(e.model); days.insert(dates.day(e.ts))
            if e.sidechain { s.sidechainMessages += 1; s.sidechainTokens += e.grand }
            if e.source == "claude" && !e.model.hasPrefix("claude-") { s.proxyMessages += 1 }
            let effort = e.effort.isEmpty ? e.source == "claude" ? "default" : "not recorded" : e.effort
            s.effort[effort, default: 0] += 1; s.first = min(s.first ?? e.ts, e.ts); s.last = max(s.last ?? e.ts, e.ts)
        }
        s.sessions = sessions.count; s.projects = projects.count; s.models = models.count; s.activeDays = days.count
        return s
    }
    static func models(_ events: [StatisticsUsage], calendar: Calendar) -> [StatisticsModel] {
        var rows: [String: StatisticsModel] = [:], days: [String: Set<Double>] = [:], sessions: [String: Set<String>] = [:]
        var dates = StatisticsCalendarCursor(calendar: calendar)
        for e in events {
            var m = rows[e.model] ?? StatisticsModel(model: e.model); m.totals.add(e)
            m.viaProxy = m.viaProxy || (e.source == "claude" && !e.model.hasPrefix("claude-")); m.first = min(m.first ?? e.ts, e.ts); m.last = max(m.last ?? e.ts, e.ts)
            days[e.model, default: []].insert(dates.day(e.ts)); sessions[e.model, default: []].insert(e.session); rows[e.model] = m
        }
        for name in rows.keys { rows[name]!.days = days[name]!.count; rows[name]!.sessions = sessions[name]!.count }
        return rows.values.sorted { $0.totals.grand == $1.totals.grand ? $0.model < $1.model : $0.totals.grand > $1.totals.grand }
    }
    static func throughput(_ events: [StatisticsUsage], calendar: Calendar) -> JSONValue {
        var response = throughputBoard(events, calendar: calendar, streaming: false)
        response["streaming"] = throughputBoard(events, calendar: calendar, streaming: true)
        return response
    }
    private static func throughputBoard(_ events: [StatisticsUsage], calendar: Calendar, streaming: Bool) -> JSONValue {
        var all = StatisticsSpeed(), models: [String: StatisticsSpeed] = [:], pairs: [String: (String, String, StatisticsSpeed)] = [:]
        var harnesses = Dictionary(uniqueKeysWithValues: StatisticsSource.allCases.map { ($0.rawValue, StatisticsSpeed()) })
        var days: [Double: (models: [String: StatisticsSpeed], harnesses: [String: StatisticsSpeed])] = [:]
        var dates = StatisticsCalendarCursor(calendar: calendar)
        for e in events {
            all.add(e, streaming: streaming); models[e.model, default: StatisticsSpeed()].add(e, streaming: streaming); harnesses[e.source, default: StatisticsSpeed()].add(e, streaming: streaming)
            let key = e.source + "\u{0}" + e.model; var p = pairs[key] ?? (e.source, e.model, StatisticsSpeed()); p.2.add(e, streaming: streaming); pairs[key] = p
            let day = dates.day(e.ts); var d = days[day] ?? ([:], [:]); d.models[e.model, default: StatisticsSpeed()].add(e, streaming: streaming); d.harnesses[e.source, default: StatisticsSpeed()].add(e, streaming: streaming); days[day] = d
        }
        func decorated(_ s: StatisticsSpeed, _ fields: JSONObject) -> JSONValue { .object(s.json.object.merging(fields) { _, new in new }) }
        return ["basis": .string(streaming ? "streaming" : "response"), "summary": all.json, "models": .array(models.keys.sorted().map { decorated(models[$0]!, ["model": .string($0)]) }), "harnesses": .array(StatisticsSource.allCases.map { decorated(harnesses[$0.rawValue]!, ["source": .string($0.rawValue)]) }), "pairs": .array(pairs.keys.sorted().map { let p = pairs[$0]!; return decorated(p.2, ["source": .string(p.0), "model": .string(p.1)]) }), "days": .array(days.keys.sorted().map { ["day": .number($0), "models": .object(days[$0]!.models.mapValues(\.json)), "harnesses": .object(days[$0]!.harnesses.mapValues(\.json))] })]
    }
    static func derive(_ events: [StatisticsUsage], range: Int, cache: StatisticsCache? = nil, now: Double, calendar: Calendar) -> StatisticsDerived {
        let evs = filtered(events, range: range, now: now, calendar: calendar)
        var d = StatisticsDerived(); d.summary = summary(evs, calendar: calendar); d.models = models(evs, calendar: calendar); d.events = evs.count; d.onDiskGrand = d.summary.totals.grand
        d.stackModels = Array(d.models.prefix(8).map(\.model)); d.stackDropped = max(0, d.models.count - 8); d.throughput = throughput(evs, calendar: calendar)
        var daily: [Double: (StatisticsTotals, [String: StatisticsTotals])] = [:]
        var projects: [String: (StatisticsTotals, Set<String>)] = [:]
        var dates = StatisticsCalendarCursor(calendar: calendar)
        for e in evs {
            let day = dates.day(e.ts); var bucket = daily[day] ?? (StatisticsTotals(), [:]); bucket.0.add(e); bucket.1[e.model, default: StatisticsTotals()].add(e); daily[day] = bucket
            var p = projects[e.project] ?? (StatisticsTotals(), []); p.0.add(e); p.1.insert(e.session); projects[e.project] = p
            let c = calendar.dateComponents([.weekday, .hour], from: Date(timeIntervalSince1970: e.ts / 1000)); d.heat[((c.weekday ?? 1) + 5) % 7][min(23, max(0, c.hour ?? 0))] += 1
        }
        d.days = daily.keys.sorted().map { ["day": .number($0), "totals": daily[$0]!.0.json, "perModel": .object(daily[$0]!.1.mapValues(\.json))] }
        d.projects = projects.keys.sorted { projects[$0]!.0.grand == projects[$1]!.0.grand ? $0 < $1 : projects[$0]!.0.grand > projects[$1]!.0.grand }.map { ["path": .string($0), "name": .string($0.split(separator: "/").last.map(String.init) ?? $0), "totals": projects[$0]!.0.json, "sessions": .number(Double(projects[$0]!.1.count))] }
        if range == 0, let cache { lifetime(&d, events: evs, cache: cache, calendar: calendar) }
        return d
    }
    static func lifetime(_ d: inout StatisticsDerived, events: [StatisticsUsage], cache: StatisticsCache, calendar: Calendar) {
        d.isLifetime = true
        let watermarkValid = cache.computedOn.count == 10 && statisticsDate(cache.computedOn, utc: true) != nil
        let fresh = watermarkValid ? events.filter { statisticsUTC($0.ts) > cache.computedOn } : nil
        let observed = d.summary.totals; var t = cache.totals
        t.thinking = observed.thinking; t.webFetch = observed.webFetch; t.messages = cache.messages
        if let fresh { let tail = summary(fresh, calendar: calendar).totals; t.addReported(tail); t.messages += tail.messages }
        d.summary.totals = t; d.summary.sessions = Int(cache.sessions)
        var dates = StatisticsCalendarCursor(calendar: calendar)
        var days = Set(events.map { dates.day($0.ts) }); for key in cache.daily.keys { if let day = statisticsDate(key, calendar: calendar) { days.insert(day) } }
        d.summary.activeDays = max(cache.activeDays, days.count)
        if let first = statisticsDate(cache.firstDay, calendar: calendar) { d.summary.first = min(d.summary.first ?? first, first) }
        if let last = statisticsDate(cache.lastDay, calendar: calendar) { d.summary.last = max(d.summary.last ?? last, last) }
        var rows = Dictionary(uniqueKeysWithValues: d.models.map { ($0.model, $0) })
        let freshModels = fresh.map { Dictionary(uniqueKeysWithValues: models($0, calendar: calendar).map { ($0.model, $0.totals) }) }
        let observedModels = Set(events.map(\.model))
        for (name, cached) in cache.perModel {
            var m = rows[name] ?? StatisticsModel(model: name); m.pruned = !observedModels.contains(name)
            if m.pruned { m.viaProxy = !name.hasPrefix("claude-") }
            if let freshModels {
                let old = m.totals; m.totals = cached; m.totals.thinking = old.thinking; m.totals.messages = old.messages; m.totals.webFetch = old.webFetch
                if let tail = freshModels[name] { m.totals.addReported(tail) }
            } else if m.totals.grand < cached.grand {
                let old = m.totals; m.totals = cached; m.totals.thinking = old.thinking; m.totals.messages = old.messages; m.totals.webFetch = old.webFetch
            }
            rows[name] = m
        }
        d.models = rows.values.sorted { $0.totals.grand == $1.totals.grand ? $0.model < $1.model : $0.totals.grand > $1.totals.grand }; d.summary.models = d.models.count
        addUntimedModels(&d)
    }
    static func addUntimedModels(_ d: inout StatisticsDerived) {
        var rows = d.throughput["models"].array; let present = Set(rows.map { $0["model"].string })
        for m in d.models where !present.contains(m.model) { var value = StatisticsSpeed().json; value["model"] = .string(m.model); rows.append(value) }
        d.throughput["models"] = .array(rows)
        var streams = d.throughput["streaming"]["models"].array
        let presentStreams = Set(streams.map { $0["model"].string })
        for m in d.models where !presentStreams.contains(m.model) { var value = StatisticsSpeed().json; value["model"] = .string(m.model); streams.append(value) }
        d.throughput["streaming"]["models"] = .array(streams)
    }
    private static func summaryAndModels(_ events: [StatisticsUsage], cache: StatisticsCache? = nil, calendar: Calendar) -> (summary: StatisticsSummary, models: [StatisticsModel]) {
        // The combined lifetime board reads only these two projections from
        // its Claude/other partitions. Their charts already belong to the
        // complete raw board; rebuilding them here discards all that work.
        var board = StatisticsDerived()
        board.summary = summary(events, calendar: calendar)
        board.models = models(events, calendar: calendar)
        if let cache { lifetime(&board, events: events, cache: cache, calendar: calendar) }
        return (board.summary, board.models)
    }
    static func sources(_ events: [StatisticsUsage], range: Int, cache: StatisticsCache?, source: String, now: Double, calendar: Calendar) -> StatisticsDerived {
        if source == "claude" { return derive(events.filter { $0.source == "claude" }, range: range, cache: cache, now: now, calendar: calendar) }
        if source != "all" { return derive(events.filter { $0.source == source }, range: range, now: now, calendar: calendar) }
        var d = derive(events, range: range, now: now, calendar: calendar)
        guard range == 0, let cache else { return d }
        let claude = summaryAndModels(events.filter { $0.source == "claude" }, cache: cache, calendar: calendar)
        let others = summaryAndModels(events.filter { $0.source != "claude" }, calendar: calendar)
        d.isLifetime = true; d.summary.totals = claude.summary.totals; d.summary.totals.add(others.summary.totals); d.summary.sessions = claude.summary.sessions + others.summary.sessions
        var days = Set(d.days.map { $0["day"].double }); for key in cache.daily.keys { if let day = statisticsDate(key, calendar: calendar) { days.insert(day) } }; d.summary.activeDays = max(claude.summary.activeDays, days.count)
        d.summary.first = [claude.summary.first, others.summary.first].compactMap { $0 }.min(); d.summary.last = [claude.summary.last, others.summary.last].compactMap { $0 }.max()
        let raw = Dictionary(uniqueKeysWithValues: d.models.map { ($0.model, $0) }); var rows = Dictionary(uniqueKeysWithValues: claude.models.map { ($0.model, $0) })
        for other in others.models {
            if var m = rows[other.model] { m.totals.add(other.totals); m.days = raw[other.model]?.days ?? 0; m.sessions += other.sessions; m.first = raw[other.model]?.first; m.last = raw[other.model]?.last; m.pruned = false; rows[other.model] = m }
            else { rows[other.model] = other }
        }
        d.models = rows.values.sorted { $0.totals.grand == $1.totals.grand ? $0.model < $1.model : $0.totals.grand > $1.totals.grand }; d.summary.models = rows.count; addUntimedModels(&d)
        return d
    }
    static func detail(_ events: [StatisticsUsage], range: Int, cache: StatisticsCache?, source: String, model: String, now: Double, calendar: Calendar, lifetimeModel: StatisticsModel? = nil) -> JSONValue? {
        guard events.contains(where: { $0.model == model }) || cache?.perModel[model] != nil else { return nil }
        let matches = events.filter { $0.model == model && (source == "all" || $0.source == source) }
        var d = sources(matches, range: range, cache: nil, source: source, now: now, calendar: calendar)
        var dated = d.summary; let lifetime = range == 0 && (source == "claude" || source == "all") && cache?.perModel[model] != nil
        let coverage: JSONValue = ["datedTotals": dated.totals.json, "first": statisticsOptional(dated.first), "last": statisticsOptional(dated.last), "lifetime": .bool(lifetime)]
        if lifetime, let row = lifetimeModel ?? sources(events, range: range, cache: cache, source: source, now: now, calendar: calendar).models.first(where: { $0.model == model }) { d.summary.totals = row.totals; d.models = [row]; d.isLifetime = true }
        d.summary.sessions = Set(filtered(matches, range: range, now: now, calendar: calendar).map { $0.source + ":" + $0.session }).count; dated.sessions = d.summary.sessions
        return ["derived": d.json, "coverage": coverage, "datedSummary": dated.json]
    }
}
