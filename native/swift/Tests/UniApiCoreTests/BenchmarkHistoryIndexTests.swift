import XCTest
import Darwin
import CryptoKit
@testable import UniApiCore

final class BenchmarkHistoryIndexTests: XCTestCase {
    private func fixture() throws -> (NativePaths, BenchmarkStore) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("benchmark-index-" + UUID().uuidString)
        let paths = NativePaths(root: root, home: root); try paths.ensureDirectories()
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return (paths, BenchmarkStore(paths: paths))
    }
    private func put(_ rows: [JSONValue], _ file: URL) throws {
        try NativeFile.writeAtomic(Data(try rows.map { String(decoding: try $0.encoded(), as: UTF8.self) }.joined(separator: "\n").utf8), to: file)
    }
    private var first: JSONValue { ["provider": "p", "model": "model", "tier": "quick", "ts": "2026-10-10T10:00:00Z", "ok": true, "curve": [[0, 2]]] }
    func testIndexExactlyMatchesFullHistoryForIDlessTiesAcrossBothLedgers() async throws {
        let (paths, store) = try fixture(), file = paths.data.appendingPathComponent("results.jsonl")
        var second = first; second["tier"] = "deep"; second["curve"] = [[0, 102]]
        var later = first; later["run_id"] = "later"; later["ts"] = "2026-10-11T10:00:00Z"; later["id"] = "explicit"
        try put([first, second, later], file)
        try put([first, second, later], paths.bench.appendingPathComponent("results/results.jsonl"))
        let full = BenchmarkFold.summary(try await store.rows())["runs"].array, index = try await store.runHistory()
        XCTAssertEqual(index, full); XCTAssertEqual(index.first?["id"], "later")
        XCTAssertEqual(index.first { $0["id"] == "unknown" }?["tier"], "quick")
        XCTAssertEqual(index.first { $0["id"] == "unknown" }?["ok"], 2)
        let cached = try await store.runHistory(); XCTAssertEqual(cached, index)
    }
    func testCompleteHashDedupUsesTheSameIdentityContractAsFullRows() async throws {
        let (paths, store) = try fixture()
        let hash = SHA256.hash(data: try first.encoded()).map { String(format: "%02x", $0) }.joined()
        var explicit = first; explicit["id"] = .string(hash); explicit["tier"] = "deep"
        try put([explicit, first], paths.data.appendingPathComponent("results.jsonl"))
        let full = BenchmarkFold.summary(try await store.rows())["runs"].array, index = try await store.runHistory()
        XCTAssertEqual(index, full); XCTAssertEqual(index.first?["ok"], 1)
    }
    func testLinkedHistoryIsRejectedEvenAfterTheSameMetadataWasCached() async throws {
        let (paths, store) = try fixture(), file = paths.data.appendingPathComponent("results.jsonl")
        try put([first], file); _ = try await store.runHistory()
        let outside = paths.root.appendingPathComponent("outside.jsonl")
        try FileManager.default.moveItem(at: file, to: outside)
        try FileManager.default.createSymbolicLink(at: file, withDestinationURL: outside)
        do { _ = try await store.runHistory(); XCTFail("Linked ledger accepted") } catch {}
        try FileManager.default.removeItem(at: file); try FileManager.default.moveItem(at: outside, to: file)
        let restored = try await store.runHistory(); XCTAssertEqual(restored.first?["ok"], 1)
    }
    func testFIFOAndDirectoryAreRejectedAndMissingLedgersAreEmpty() async throws {
        let (paths, store) = try fixture(), file = paths.data.appendingPathComponent("results.jsonl")
        let absent = try await store.runHistory(); XCTAssertTrue(absent.isEmpty)
        XCTAssertEqual(mkfifo(file.path, 0o600), 0)
        do { _ = try await store.runHistory(); XCTFail("FIFO accepted") } catch {}
        try FileManager.default.removeItem(at: file); try FileManager.default.createDirectory(at: file, withIntermediateDirectories: true)
        do { _ = try await store.runHistory(); XCTFail("Directory accepted") } catch {}
    }
    func testOversizedRowsFailWithAndWithoutNewlineAndFailureDoesNotPoisonCache() async throws {
        let (paths, store) = try fixture(), file = paths.data.appendingPathComponent("results.jsonl")
        var bytes = Data("{\"ignored\":\"".utf8)
        let chunk = Data(repeating: 120, count: 1 << 20)
        for _ in 0..<17 { bytes.append(chunk) }
        bytes.append(contentsOf: "\"}".utf8)
        for newline in [false, true] {
            var row = bytes; if newline { row.append(10) }
            try NativeFile.writeAtomic(row, to: file)
            do { _ = try await store.runHistory(); XCTFail("Oversized row accepted") } catch { XCTAssertTrue(error.localizedDescription.contains("oversized row")) }
        }
        try put([first], file); let restored = try await store.runHistory(); XCTAssertEqual(restored.first?["ok"], 1)
    }
}
