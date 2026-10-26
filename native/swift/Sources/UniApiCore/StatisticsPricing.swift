import Foundation

/// Current, sourced API-equivalent value. Usage tokens do not prove an invoice,
/// subscription charge, historical tier, cache TTL or marketplace discount.
enum StatisticsPricing {
    struct Rate {
        let input: Double?, output: Double?, write: Double?, read: Double?
        init(_ value: JSONValue) {
            func amount(_ field: String) -> Double? { value[field].isNull ? nil : value[field].double }
            input = amount("input"); output = amount("output")
            write = amount("cacheWrite"); read = amount("cacheRead")
        }
    }
    private static let catalog = (try? JSONValue.decode(Data(StatisticsPriceCatalog.json.utf8))) ?? [:]
    private static let lookup: [String: JSONValue] = {
        var result: [String: JSONValue] = [:]
        for price in catalog["models"].array {
            for id in [price["id"].string] + price["aliases"].array.map(\.string) { result[id] = price }
        }
        return result
    }()
    private static let unknown: [String: String] = Dictionary(
        catalog["unpriced"].array.map { ($0["id"].string, $0["reason"].string) },
        uniquingKeysWith: { first, _ in first })

    private static func requestedModel(_ model: String) -> String {
        let id = model.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard id.hasPrefix("uniapi/") else { return id }
        let parts = id.split(separator: "/", maxSplits: 2, omittingEmptySubsequences: false)
        guard parts.count == 3, !parts[1].isEmpty, !parts[2].isEmpty,
              let decoded = String(parts[2]).removingPercentEncoding else { return id }
        return decoded.lowercased()
    }
    static func normalize(_ model: String) -> String {
        let id = requestedModel(model)
        return lookup[id]?["id"].string ?? id
    }
    static func rate(_ model: String) -> (Rate, Bool)? {
        guard let price = lookup[requestedModel(model)] else { return nil }
        // Retained compatibility flag means exact registered model identity.
        return (Rate(price["rates"]), true)
    }
    static func fold(_ models: [StatisticsModel]) -> JSONValue {
        var usd = 0.0, priced = 0.0, unpriced = 0.0
        var missing: [JSONValue] = [], rows: [JSONValue] = []
        for model in models {
            let id = requestedModel(model.model), price = lookup[id], t = model.totals
            let counts = [("input", t.input), ("output", t.output), ("cacheWrite", t.cacheWrite), ("cacheRead", t.cacheRead)]
            let valid = counts.allSatisfy { $0.1.isFinite && $0.1 >= 0 }
            var tokens = 0.0, covered = 0.0, uncovered = 0.0, value = 0.0
            var components: JSONObject = [:]
            for (field, count) in counts {
                let count = count.isFinite && count >= 0 ? count : 0
                let r = valid ? price?["rates"][field] ?? .null : .null
                let part: JSONValue = r.isNull ? .null : .number(count * r.double / 1_000_000)
                components[field] = ["tokens": .number(count), "rate": r, "usd": part]
                tokens += count
                if part.isNull { uncovered += count }
                else { covered += count; value += part.double }
            }
            let reason: String
            if !valid { reason = "Invalid token counts; no estimate was produced." }
            else if price == nil { reason = unknown[id] ?? "No verified public API price is registered for this model." }
            else if uncovered > 0 { reason = "Some recorded token types have no verified rate; the displayed value is partial." }
            else { reason = "" }
            let row: JSONValue = [
                "model": .string(model.model), "canonicalModel": price?["id"] ?? .null,
                "tokens": .number(tokens), "usd": covered > 0 ? .number(value) : .null,
                "pricedTokens": .number(covered), "unpricedTokens": .number(uncovered),
                "rates": price?["rates"] ?? .null, "components": .object(components),
                "sourceURL": price?["sourceURL"] ?? .null, "checkedAt": price?["checkedAt"] ?? .null,
                "assumption": price?["assumption"] ?? "", "reason": .string(reason)
            ]
            usd += value; priced += covered; unpriced += uncovered
            if uncovered > 0 { missing.append(["model": .string(model.model), "tokens": .number(uncovered)]) }
            if tokens > 0 || !valid { rows.append(row) }
        }
        func ordered(_ a: JSONValue, _ b: JSONValue) -> Bool {
            a["tokens"].double == b["tokens"].double ? a["model"].string < b["model"].string : a["tokens"].double > b["tokens"].double
        }
        missing.sort(by: ordered); rows.sort(by: ordered)
        return ["usd": .number(usd), "exactUsd": .number(usd), "pricedTokens": .number(priced),
                "unpricedTokens": .number(unpriced), "unpriced": .array(missing),
                "ratesDate": catalog["checkedAt"], "currency": catalog["currency"],
                "basis": catalog["basis"], "billedUsd": .null, "rows": .array(rows)]
    }
}
