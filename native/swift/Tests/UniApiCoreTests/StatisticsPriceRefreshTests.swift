import XCTest
@testable import UniApiCore

final class StatisticsPriceRefreshTests: XCTestCase {
    func testQualifiedFreeRouteAliasesEstimateAPIValueWithoutInventingAnInvoice() {
        var sante = StatisticsModel(model: "uniapi/command-code/inclusionai%2Fling-3.0-flash-sante%3Afree")
        sante.totals.input = 1_000_000; sante.totals.output = 1_000_000; sante.totals.cacheRead = 1_000_000
        let cost = StatisticsPricing.fold([sante])
        XCTAssertEqual(cost["usd"].double, 0.31, accuracy: 0.000000001)
        XCTAssertEqual(cost["unpricedTokens"].double, 0)
        XCTAssertTrue(cost["billedUsd"].isNull)
        XCTAssertEqual(cost["rows"].array.first?["canonicalModel"], "inclusionai/ling-3.0-flash-sante")
        var free = StatisticsModel(model: "minimax-m3-free"); free.totals.input = 1_000_000
        XCTAssertEqual(StatisticsPricing.fold([free])["usd"].double, 0.3, accuracy: 0.000000001)
    }

    func testQwenFlashCacheCreationRemainsUnpricedInsteadOfGenericMultiplier() {
        var model = StatisticsModel(model: "qwen3.8-flash")
        model.totals.input = 1_000_000; model.totals.output = 1_000_000; model.totals.cacheWrite = 1_000_000
        let cost = StatisticsPricing.fold([model])
        XCTAssertEqual(cost["usd"].double, 0.62, accuracy: 0.000000001)
        XCTAssertEqual(cost["pricedTokens"].int, 2_000_000)
        XCTAssertEqual(cost["unpricedTokens"].int, 1_000_000)
        XCTAssertTrue(cost["rows"].array[0]["components"]["cacheWrite"]["rate"].isNull)
    }

    func testDocumentedAliasesDoNotEnableHeuristicThinkingOrBrowserMappings() {
        let catalog = try! JSONValue.decode(Data(StatisticsPriceCatalog.json.utf8))
        XCTAssertEqual(catalog["checkedAt"], "2026-10-23")
        for id in ["gpt-5.2", "gpt-5.6", "claude-opus-4-5", "gpt-5.4-mini-2026-03-17"] {
            var model = StatisticsModel(model: id); model.totals.input = 1
            XCTAssertEqual(StatisticsPricing.fold([model])["pricedTokens"].int, 1, id)
        }
        for id in ["claude-opus-5-5-high", "chatgpt-web/pro", "gpt-5.6-unpublished"] {
            var model = StatisticsModel(model: id); model.totals.input = 1
            let cost = StatisticsPricing.fold([model])
            XCTAssertEqual(cost["pricedTokens"].int, 0, id)
            XCTAssertEqual(cost["unpricedTokens"].int, 1, id)
        }
    }
}
