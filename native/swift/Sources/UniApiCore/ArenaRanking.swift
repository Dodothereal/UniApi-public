import Foundation

enum ArenaRanking {
    static func valid(_ r: JSONValue) -> Bool {
        guard case .object = r, case .number(let version) = r["v"], version == 1, case .string(let id) = r["id"], !id.isEmpty, case .number(let ts) = r["ts"], ts.isFinite else { return false }
        let contestants = r["contestants"].array
        return ["random", "chosen"].contains(r["mode"].string) && ["ranked", "all_bad"].contains(r["verdict"].string) && contestants.count >= 2 && Set(contestants.map(key)).count == contestants.count && contestants.allSatisfy { if case .string = $0["route"], case .string = $0["model"] { return true }; return false }
    }
    static func key(_ c: JSONValue) -> String { ArenaContestantPolicy.key(c) }
    static func standings(_ records: [JSONValue], mode: String = "all") -> [JSONValue] {
        fold(records, mode: mode).standings
    }
    static func fold(_ records: [JSONValue], mode: String, trend: Bool = false, matchID: String = "") ->
        (standings: [JSONValue], comparisons: [JSONValue], trend: [JSONValue], verdict: JSONValue, deltas: JSONValue) {
        struct Standing { var route: JSONValue, model: JSONValue, elo: Double = 1000, matches = 0, wins = 0, losses = 0, draws = 0, failures = 0, firsts = 0, durations: [Double] = [], turns: [Double] = [], last: Double = 0 }
        struct Pair: Hashable { let first: String, second: String }
        struct Results { var wins = 0, losses = 0, draws = 0 }
        var out: [String: Standing] = [:]
        var comparisons: [Pair: Results] = [:]
        let records = records.filter { valid($0) && (mode == "all" || $0["mode"].string == mode) }.sorted { $0["ts"].double == $1["ts"].double ? $0["id"].string < $1["id"].string : $0["ts"].double < $1["ts"].double }
        let trendStart = trend ? max(0, records.count - 24) : records.count
        var history: [String: [JSONValue]] = [:]
        var verdict: JSONValue = .null, matchDeltas: JSONObject = [:]
        for (index, r) in records.enumerated() {
            let selected = r["id"].string == matchID
            if selected { verdict = r }
            for c in r["contestants"].array {
                let key = key(c); var s = out[key] ?? Standing(route: c["route"], model: c["model"]); s.matches += 1; s.last = max(s.last, r["ts"].double)
                if c["status"].string != "done" { s.failures += 1 } else { if !c["duration_ms"].isNull { s.durations.append(c["duration_ms"].double) }; if !c["turns"].isNull { s.turns.append(c["turns"].double) }; if r["verdict"].string == "ranked" && c["rank"].int == 1 { s.firsts += 1 } }; out[key] = s
            }
            let played = r["contestants"].array.filter { $0["status"].string == "done" && (r["verdict"].string == "all_bad" || !$0["rank"].isNull) }
            guard played.count >= 2 else { continue }
            let before = Dictionary(uniqueKeysWithValues: played.map { (key($0), out[key($0)]!.elo) }), k = 32 / Double(played.count - 1); var delta: [String: Double] = [:]
            for i in 0..<(played.count - 1) { for j in (i + 1)..<played.count {
                let a = played[i], b = played[j], ak = key(a), bk = key(b), expected = 1 / (1 + pow(10, (before[bk]! - before[ak]!) / 400)), score: Double
                if r["verdict"].string == "all_bad" || a["rank"] == b["rank"] { score = 0.5; out[ak]!.draws += 1; out[bk]!.draws += 1 }
                else if a["rank"].double < b["rank"].double { score = 1; out[ak]!.wins += 1; out[bk]!.losses += 1 }
                else { score = 0; out[bk]!.wins += 1; out[ak]!.losses += 1 }
                let forward = ak < bk, pair = Pair(first: forward ? ak : bk, second: forward ? bk : ak)
                if score == 0.5 { comparisons[pair, default: Results()].draws += 1 }
                else if (score == 1) == forward { comparisons[pair, default: Results()].wins += 1 }
                else { comparisons[pair, default: Results()].losses += 1 }
                delta[ak, default: 0] += k * (score - expected); delta[bk, default: 0] += k * ((1 - score) - (1 - expected))
            } }
            for (key, value) in delta {
                out[key]!.elo += value
                if selected { matchDeltas[key] = .number(floor(out[key]!.elo + 0.5) - floor(before[key]! + 0.5)) }
                if index >= trendStart {
                    history[key, default: []].append(["ts": r["ts"], "elo": .number(floor(out[key]!.elo + 0.5))])
                }
            }
        }
        func average(_ values: [Double]) -> JSONValue { values.isEmpty ? .null : .number(values.reduce(0, +) / Double(values.count)) }
        let rows: [JSONValue] = out.map { key, s in
            ["key": .string(key), "route": s.route, "model": s.model, "elo": .number(floor(s.elo + 0.5)),
             "matches": .number(Double(s.matches)), "wins": .number(Double(s.wins)), "losses": .number(Double(s.losses)),
             "draws": .number(Double(s.draws)), "failures": .number(Double(s.failures)), "firsts": .number(Double(s.firsts)),
             "avg_duration_ms": average(s.durations), "avg_turns": average(s.turns), "last_ts": .number(s.last)]
        }
        let standings = rows.sorted { a, b in
            if a["elo"] != b["elo"] { return a["elo"].double > b["elo"].double }
            if a["wins"] != b["wins"] { return a["wins"].int > b["wins"].int }
            return a["key"].string < b["key"].string
        }
        let pairs = comparisons.keys.sorted { ($0.first, $0.second) < ($1.first, $1.second) }.map { key -> JSONValue in
            let results = comparisons[key]!
            return ["first": .string(key.first), "second": .string(key.second), "wins": .number(Double(results.wins)), "losses": .number(Double(results.losses)), "draws": .number(Double(results.draws))]
        }
        let series: [JSONValue] = standings.prefix(3).compactMap { row in
            let key = row["key"].string
            guard let points = history[key] else { return nil }
            return ["key": row["key"], "model": row["model"], "route": row["route"], "points": .array(points)]
        }
        return (standings, pairs, series, verdict, .object(matchDeltas))
    }
}
