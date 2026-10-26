import XCTest
import Darwin
@testable import UniApiCore

final class StatisticsLineReaderTests: XCTestCase {
    private func file(_ data: Data) throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("statistics-lines-" + UUID().uuidString)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("usage.jsonl"); try NativeFile.writeAtomic(data, to: file); return file
    }
    private func read(_ bytes: Data, usageOnly: Bool = false, limit: Int? = nil) throws -> [JSONValue] {
        var rows: [JSONValue] = []
        let url = try file(bytes), fd = open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw NativeFailure("Fixture unavailable") }; defer { close(fd) }
        try StatisticsImporter.lines(descriptor: fd, usageOnly: usageOnly, maximumRowBytes: limit) { rows.append($0) }
        return rows
    }
    func testChunkBoundaryNewlineUnicodeCRLFAndUnterminatedFinalRow() throws {
        let a = "{\"name\":\"" + String(repeating: "x", count: (1 << 20) - 12) + "\"}"
        XCTAssertEqual(a.utf8.count, (1 << 20) - 1)
        let b: JSONValue = ["name": "東京\nescaped", "astral": "\u{1D11E}"]
        let bytes = Data((a + "\n\n" + String(decoding: try b.encoded(), as: UTF8.self) + "\r\n{\"last\":1}").utf8)
        XCTAssertEqual(try read(bytes), [try JSONValue.decode(Data(a.utf8)), b, ["last": 1]])
    }
    func testLargeIgnoredBodyRetainsAllUsageMetadata() throws {
        let row: JSONValue = ["type": "assistant", "timestamp": "2026-10-10T10:00:00Z", "message": ["id": "one", "model": "fixture", "usage": ["input_tokens": 123], "content": .string(String(repeating: "body ", count: 500000))]]
        let data = try row.encoded()
        let expected: JSONValue = ["type": "assistant", "timestamp": "2026-10-10T10:00:00Z", "message": ["id": "one", "model": "fixture", "usage": ["input_tokens": 123]]]
        XCTAssertEqual(try read(data, usageOnly: true), [expected])
        var terminated = data; terminated.append(10)
        XCTAssertEqual(try read(terminated, usageOnly: true), [expected])
    }
    func testMalformedRowsAndInvalidUTF8AreSkippedWithoutLosingLaterRows() throws {
        var data = Data("{\"first\":1}\ninvalid\n".utf8); data.append(contentsOf: [255, 254, 10]); data.append(Data("{\"last\":2}".utf8))
        XCTAssertEqual(try read(data), [["first": 1], ["last": 2]])
    }
    func testInclusiveRowBoundAndOversizeAcrossChunks() throws {
        let data = Data("{\"n\":1}".utf8)
        XCTAssertEqual(try read(data, limit: data.count), [["n": 1]])
        var terminated = data; terminated.append(10)
        XCTAssertEqual(try read(terminated, limit: data.count), [["n": 1]])
        XCTAssertThrowsError(try read(terminated, limit: data.count - 1))
        XCTAssertThrowsError(try read(Data(repeating: 32, count: (1 << 20) + 1), limit: 1 << 20))
    }
    func testCancellationPreventsConsumingAnyRow() async throws {
        let url = try file(Data("{\"n\":1}\n".utf8))
        let task = Task { () -> Bool in
            withUnsafeCurrentTask { $0?.cancel() }
            do { try StatisticsImporter.lines(url) { _ in XCTFail("Cancelled read emitted a row") }; return false }
            catch is CancellationError { return true }
            catch { return false }
        }
        let cancelled = await task.value
        XCTAssertTrue(cancelled)
    }
}
