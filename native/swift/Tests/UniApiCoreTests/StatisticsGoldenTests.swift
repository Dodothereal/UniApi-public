import XCTest
@testable import UniApiCore

/// Frozen outputs from the web implementation cover complete folds rather than
/// reproducing the Swift algorithm in assertions. The corpus is synthetic.
final class StatisticsGoldenTests: XCTestCase {
    func testWebGoldenAccountingAcrossSourcesRangesWatermarksAndTimeZones() throws {
        let file = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/statistics-web-golden.json")
        let fixture = try JSONValue.decode(Data(contentsOf: file))
        XCTAssertEqual(fixture["schema"], 1)
        let decoder = JSONDecoder()
        let events = try decoder.decode([StatisticsUsage].self, from: fixture["events"].encoded())
        for item in fixture["cases"].array {
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = try XCTUnwrap(TimeZone(identifier: item["zone"].string))
            let input = item["empty"].bool ? [] : events
            let cache = StatisticsCache.parse(fixture["caches"][item["cacheName"].string])
            let range = item["range"].int, source = item["source"].string, now = fixture["now"].double
            let context = item["zone"].string + "/" + source + "/" + item["cacheName"].string + "/\(range)"
            let actual = StatisticsFold.sources(input, range: range, cache: cache, source: source, now: now, calendar: calendar).json
            compare(actual, item["expected"], context)
            for (model, expected) in item["details"].object {
                let detail = StatisticsFold.detail(input, range: range, cache: cache, source: source, model: model, now: now, calendar: calendar) ?? .null
                compare(detail, expected, context + "/detail/" + model)
            }
        }
    }

    func testComparisonNormalizationRejectsUnequalRankReorderingAndAllowsTrueTies() {
        func row(_ name: String, tokens: Int) -> JSONValue { ["model": .string(name), "path": .string(name), "tokens": .number(Double(tokens)), "totals": ["input": .number(Double(tokens))]] }
        let high = row("high", tokens: 200), one = row("a", tokens: 100), two = row("b", tokens: 100), low = row("low", tokens: 90)
        for path in ["overview/models", "overview/projects", "overview/cost/unpriced"] {
            XCTAssertEqual(normalized([high, one, two, low], path: path), normalized([high, two, one, low], path: path), path)
            XCTAssertNotEqual(normalized([high, one, low], path: path), normalized([one, high, low], path: path), path)
        }
        XCTAssertEqual(normalized([high, low], path: "overview/throughput/models"), normalized([low, high], path: "overview/throughput/models"))
    }

    private func normalized(_ rows: [JSONValue], path: String) -> [JSONValue] {
        let identity = rows.first?.object["model"] != nil ? "model" : rows.first?.object["path"] != nil ? "path" : rows.first?.object["source"] != nil ? "source" : nil
        guard let identity else { return rows }
        func key(_ value: JSONValue) -> String { value[identity].string + "\u{0}" + value["source"].string }
        if ["models", "pairs", "harnesses"].contains(where: { path.hasSuffix("/throughput/" + $0) || path.hasSuffix("/throughput/streaming/" + $0) }) { return rows.sorted { key($0) < key($1) } }
        let rank: ((JSONValue) -> Double)?
        if path.hasSuffix("/models") || path.hasSuffix("/projects") {
            rank = { value in ["input", "output", "cacheRead", "cacheWrite"].reduce(0) { $0 + value["totals"][$1].double } }
        } else if path.hasSuffix("/cost/unpriced") { rank = { $0["tokens"].double } }
        else { rank = nil }
        guard let rank else { return rows }
        // Equal-ranked adjacent rows may have different deterministic tie
        // breaks. Never reorder groups: an inverted ranking must fail parity.
        var output: [JSONValue] = [], start = 0
        while start < rows.count {
            var end = start + 1
            while end < rows.count, rank(rows[start]) == rank(rows[end]) { end += 1 }
            output.append(contentsOf: rows[start..<end].sorted { key($0) < key($1) })
            start = end
        }
        return output
    }

    private func compare(_ actual: JSONValue, _ expected: JSONValue, _ path: String) {
        switch (actual, expected) {
        case let (.number(a), .number(b)):
            XCTAssertEqual(a, b, accuracy: max(1e-9, abs(b) * 1e-12), path)
        case let (.object(a), .object(b)):
            if path.hasSuffix("/cost") {
                XCTAssertEqual(a["ratesDate"], "2026-10-23", path + "/ratesDate")
            }
            XCTAssertEqual(Set(a.keys), Set(b.keys), path + "/keys")
            for key in b.keys.sorted() { compare(a[key] ?? .null, b[key]!, path + "/" + key) }
        case let (.array(a), .array(b)):
            XCTAssertEqual(a.count, b.count, path + "/count")
            for (index, pair) in zip(normalized(a, path: path), normalized(b, path: path)).enumerated() { compare(pair.0, pair.1, path + "/\(index)") }
        default: XCTAssertEqual(actual, expected, path)
        }
    }
}
