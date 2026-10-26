import XCTest
@testable import UniApiCore

final class CodexModelCacheTests: XCTestCase {
    func testLargeCatalogKeepsPickerFieldsWithoutRetainingUnusedMetadata() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("models.json")
        let row: JSONValue = ["slug": "fixture-native", "display_name": "Fixture model", "visibility": "list", "hidden": false, "priority": 3, "supported_in_api": true, "multi_agent_version": "v1", "supported_reasoning_levels": [["effort": "ultra"], ["effort": 5], "malformed"], "experimental_supported_tools": .string(String(repeating: "x", count: 9 * 1024 * 1024))]
        try NativeFile.writeAtomic(try JSONValue.object(["models": .array([row, "malformed"])]).encoded(), to: file)
        XCTAssertThrowsError(try SwitcherDisk.json(file))
        let result = try NativeCodexModelCache.rows(file)
        XCTAssertEqual(result.count, 2)
        XCTAssertEqual(result[0]["slug"], "fixture-native")
        XCTAssertEqual(result[0]["supported_reasoning_levels"].array.count, 3)
        XCTAssertEqual(result[0]["supported_reasoning_levels"].array.first, ["effort": "ultra"])
        XCTAssertTrue(result[0]["supported_reasoning_levels"].array.dropFirst().allSatisfy(\.isNull))
        XCTAssertTrue(result[0]["experimental_supported_tools"].isNull)
        XCTAssertTrue(result[1].isNull)
    }
    func testLinkedCatalogAndOversizedInputStayRejected() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("catalog.json"), link = root.appendingPathComponent("link.json")
        try NativeFile.writeAtomic(Data("{\"models\":[]}".utf8), to: file)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: file)
        XCTAssertThrowsError(try NativeCodexModelCache.rows(link))
        let handle = try FileHandle(forWritingTo: file); try handle.truncate(atOffset: 64 * 1024 * 1024 + 1); try handle.close()
        XCTAssertThrowsError(try NativeCodexModelCache.rows(file))
    }
}
