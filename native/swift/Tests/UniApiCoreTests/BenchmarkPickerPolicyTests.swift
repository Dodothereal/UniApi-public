import XCTest
@testable import UniApiCore

final class BenchmarkPickerPolicyTests: XCTestCase {
    func testCustomIDsTrimMatchTheCatalogAndHonorTransportCapabilities() {
        let api: JSONValue = ["transport": "api", "catalog": [["id": "known"], ["id": "blocked", "available": false]]]
        XCTAssertEqual(BenchmarkPickerPolicy.customModel(provider: api, query: "  new/model\n"), "new/model")
        XCTAssertNil(BenchmarkPickerPolicy.customModel(provider: .null, query: "new/model"))
        XCTAssertNil(BenchmarkPickerPolicy.customModel(provider: [], query: "new/model"))
        for query in ["", " \n", "known", " known\n", "blocked", " blocked "] {
            XCTAssertNil(BenchmarkPickerPolicy.customModel(provider: api, query: query), query)
        }
        var noCustom = api; noCustom["capabilities"] = ["arbitraryModels": false]
        XCTAssertNil(BenchmarkPickerPolicy.customModel(provider: noCustom, query: "new/model"))
        var browser = api; browser["transport"] = "chatgpt-web"
        XCTAssertNil(BenchmarkPickerPolicy.customModel(provider: browser, query: "new/model"))
        XCTAssertNil(BenchmarkPickerPolicy.customModel(provider: ["transport": "chatgpt-web", "catalog": []], query: "new/model"))
    }
    func testCustomAndCatalogActionsShareReversibleSortedMembership() {
        let original = ["z", "a"]
        let selected = BenchmarkPickerPolicy.toggling("custom", in: original)
        XCTAssertEqual(selected, ["a", "custom", "z"])
        XCTAssertEqual(BenchmarkPickerPolicy.toggling("custom", in: selected), original.sorted())
        XCTAssertEqual(BenchmarkPickerPolicy.toggling("a", in: ["z", "a", "a", "z"]), ["z"])
    }
    func testSelectMatchingKeepsExistingChoicesAndRejectsUnavailableEntries() {
        let rows: [JSONValue] = [["id": "blocked", "available": false], ["id": "b"], ["id": "a", "available": true], ["id": "b"]]
        XCTAssertEqual(BenchmarkPickerPolicy.selectingMatches(rows, in: ["retained", "retained"]), ["a", "b", "retained"])
        XCTAssertEqual(BenchmarkPickerPolicy.selectingMatches([], in: ["retained"]), ["retained"])
        XCTAssertEqual(BenchmarkPickerPolicy.selectingMatches([["id": "blocked", "available": false]], in: []), [])
    }
}
