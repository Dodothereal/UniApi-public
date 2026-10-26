import Foundation

enum ArenaRanking {
    static func valid(_ r: JSONValue) -> Bool {
        guard case .object = r, case .number(let version) = r["v"], version == 1, case .string(let id) = r["id"], !id.isEmpty, case .number(let ts) = r["ts"], ts.isFinite else { return false }
        let contestants = r["contestants"].array
        return ["random", "chosen"].contains(r["mode"].string) && ["ranked", "all_bad"].contains(r["verdict"].string) && contestants.count >= 2 && Set(contestants.map(key)).count == contestants.count && contestants.allSatisfy { if case .string = $0["route"], case .string = $0["model"] { return true }; return false }
    }
    static func key(_ c: JSONValue) -> String { ArenaContestantPolicy.key(c) }
    static func standings(_ records: [JSONValue], mode: String = "all") -> [JSONValue] {
        struct Standing { var route: JSONValue, model: JSONValue, elo: Double = 1000, matches = 0, wins = 0, losses = 0, draws = 0, failures = 0, firsts = 0, durations: [Double] = [], turns: [Double] = [], last: Double = 0 }
        var out: [String: Standing] = [:]
        let records = records.filter { valid($0) && (mode == "all" || $0["mode"].string == mode) }.sorted { $0["ts"].double == $1["ts"].double ? $0["id"].string < $1["id"].string : $0["ts"].double < $1["ts"].double }
        for r in records {
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
                delta[ak, default: 0] += k * (score - expected); delta[bk, default: 0] += k * ((1 - score) - (1 - expected))
            } }
            for (key, value) in delta { out[key]!.elo += value }
        }
        func average(_ values: [Double]) -> JSONValue { values.isEmpty ? .null : .number(values.reduce(0, +) / Double(values.count)) }
        return out.map { key, s -> JSONValue in ["key": .string(key), "route": s.route, "model": s.model, "elo": .number(floor(s.elo + 0.5)), "matches": .number(Double(s.matches)), "wins": .number(Double(s.wins)), "losses": .number(Double(s.losses)), "draws": .number(Double(s.draws)), "failures": .number(Double(s.failures)), "firsts": .number(Double(s.firsts)), "avg_duration_ms": average(s.durations), "avg_turns": average(s.turns), "last_ts": .number(s.last)] }.sorted { a, b in a["elo"] == b["elo"] ? a["wins"] == b["wins"] ? a["key"].string < b["key"].string : a["wins"].int > b["wins"].int : a["elo"].double > b["elo"].double }
    }
}
