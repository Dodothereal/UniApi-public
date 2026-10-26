import XCTest
@testable import UniApiCore

final class BenchmarkCSVTests: XCTestCase {
    func testCSVFormulaPrefixesAndNumericNegatives() {
        for value in ["=1+1", "+SUM(A1:A2)", "-SUM(A1:A2)", "@SUM(A1:A2)"] { XCTAssertTrue(BenchmarkCSV.field(value).hasPrefix("'"), value) }
        for value in ["-2.5", "+4", "0", "-1e3"] { XCTAssertEqual(BenchmarkCSV.field(value), value) }
        XCTAssertEqual(BenchmarkCSV.field("a,\"b\"\nline"), "\"a,\"\"b\"\"\nline\"")
    }
    func testRealWebCSVGoldenColumnsUnitsDelimitersAndBrowserUnavailablePolicy() throws {
        let file = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/benchmark-csv-web-golden.json")
        let fixture = try JSONValue.decode(Data(contentsOf: file))
        XCTAssertEqual(fixture["schema"], 1)
        XCTAssertEqual(BenchmarkCSV.summaryColumns.count, 27); XCTAssertEqual(BenchmarkCSV.rawColumns.count, 39)
        for item in fixture["cases"].array {
            XCTAssertEqual(BenchmarkCSV.summary(item["summary"], label: item["label"].string), item["expectedSummary"].string, item["name"].string)
            XCTAssertEqual(BenchmarkCSV.raw(item["rows"].array), item["expectedRaw"].string, item["name"].string)
        }
    }
}
