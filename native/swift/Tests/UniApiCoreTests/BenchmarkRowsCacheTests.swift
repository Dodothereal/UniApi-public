import XCTest
import Darwin
@testable import UniApiCore

final class BenchmarkRowsCacheTests: XCTestCase {
    private func fixture() throws -> (NativePaths, BenchmarkStore) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("benchmark-rows-" + UUID().uuidString)
        let paths = NativePaths(root: root, home: root); try paths.ensureDirectories()
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return (paths, BenchmarkStore(paths: paths))
    }
    private func row(_ id: String) -> JSONValue {
        ["id": .string(id), "run_id": "fixture", "provider": "p", "model": "model", "test": "throughput", "ts": "2026-10-10T10:00:00Z", "ok": true, "curve": [[0, 2]], "unknown": ["preserved": true]]
    }
    private func put(_ rows: [JSONValue], at file: URL) throws {
        let data = try rows.reduce(into: Data()) { $0.append(try $1.encoded()); $0.append(10) }
        try NativeFile.writeAtomic(data, to: file)
    }
    func testWarmRowsMatchUncachedFoldAndCallerEditsDoNotChangeStoredGeneration() async throws {
        let (paths, store) = try fixture(), legacy = paths.data.appendingPathComponent("results.jsonl")
        var noID = row("one"); noID["id"] = .null
        var different = noID; different["curve"] = [[0, 102]]
        try put([row("explicit"), noID, different], at: legacy)
        try put([row("explicit"), noID], at: paths.bench.appendingPathComponent("results/results.jsonl"))
        let expected = try await BenchmarkStore(paths: paths, cacheByteLimit: 0).rows()
        var first = try await store.rows(); XCTAssertEqual(first, expected)
        first[0]["unknown"] = "caller edit"
        let warm = try await store.rows()
        XCTAssertEqual(warm, expected)
        XCTAssertEqual(BenchmarkFold.summary(warm), BenchmarkFold.summary(expected))
        XCTAssertEqual(warm.count, 3)
    }
    func testAppendDeleteTruncateAndSameDateReplacementRefreshRows() async throws {
        let (paths, store) = try fixture(), legacy = paths.data.appendingPathComponent("results.jsonl")
        let current = paths.bench.appendingPathComponent("results/results.jsonl")
        try put([row("one")], at: legacy); _ = try await store.rows()
        try await store.append(row("two"))
        let appended = try await store.rows(); XCTAssertEqual(Set(appended.map { $0["id"].string }), ["one", "two"])
        try FileManager.default.removeItem(at: legacy)
        let removed = try await store.rows(); XCTAssertEqual(removed.map { $0["id"].string }, ["two"])
        let date = try FileManager.default.attributesOfItem(atPath: current.path)[.modificationDate]!
        try put([row("new")], at: current)
        try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: current.path)
        let replaced = try await store.rows(); XCTAssertEqual(replaced.map { $0["id"].string }, ["new"])
        try put([], at: current)
        let truncated = try await store.rows(); XCTAssertTrue(truncated.isEmpty)
    }
    func testCacheNeverAdmitsLinkedFIFOOrDirectoryReplacement() async throws {
        for kind in ["link", "fifo", "directory"] {
            let (paths, store) = try fixture(), file = paths.data.appendingPathComponent("results.jsonl")
            try put([row("one")], at: file); _ = try await store.rows()
            let outside = paths.root.appendingPathComponent("outside.jsonl")
            try FileManager.default.moveItem(at: file, to: outside)
            if kind == "link" { try FileManager.default.createSymbolicLink(at: file, withDestinationURL: outside) }
            else if kind == "fifo" { XCTAssertEqual(mkfifo(file.path, 0o600), 0) }
            else { try FileManager.default.createDirectory(at: file, withIntermediateDirectories: false) }
            do { _ = try await store.rows(); XCTFail("Invalid replacement admitted: " + kind) } catch {}
            try FileManager.default.removeItem(at: file); try FileManager.default.moveItem(at: outside, to: file)
            let restored = try await store.rows(); XCTAssertEqual(restored.map { $0["id"].string }, ["one"])
        }
    }
    func testSmallCacheBudgetsNeverDropRecordsOrUnknownFields() async throws {
        let (paths, _) = try fixture(), file = paths.data.appendingPathComponent("results.jsonl")
        let expected = [row("one"), row("two"), row("three")]
        try put(expected, at: file)
        for store in [BenchmarkStore(paths: paths, cacheByteLimit: 1), BenchmarkStore(paths: paths, cacheRowLimit: 1)] {
            let first = try await store.rows(), second = try await store.rows()
            XCTAssertEqual(first.count, 3); XCTAssertEqual(second, first)
            XCTAssertTrue(second.allSatisfy { $0["unknown"]["preserved"].bool })
        }
    }
    func testParentDirectoryLinksAreRejectedByColdAndWarmRowsAndHistory() async throws {
        for relative in ["data", "data/bench", "data/bench/results"] {
            let (paths, warm) = try fixture()
            try put([row("one")], at: paths.data.appendingPathComponent("results.jsonl"))
            try put([row("two")], at: paths.bench.appendingPathComponent("results/results.jsonl"))
            _ = try await warm.rows(); _ = try await warm.runHistory()
            let folder = paths.root.appendingPathComponent(relative), outside = paths.root.appendingPathComponent("outside")
            try FileManager.default.moveItem(at: folder, to: outside)
            try FileManager.default.createSymbolicLink(at: folder, withDestinationURL: outside)
            for store in [warm, BenchmarkStore(paths: paths)] {
                do { _ = try await store.rows(); XCTFail("Linked row ancestry admitted: " + relative) } catch {}
                do { _ = try await store.runHistory(); XCTFail("Linked history ancestry admitted: " + relative) } catch {}
            }
        }
    }
    func testAlreadyCancelledColdAndWarmReadsNeverReturnPayloads() async throws {
        let (paths, warm) = try fixture()
        try put([row("one")], at: paths.data.appendingPathComponent("results.jsonl"))
        _ = try await warm.rows(); _ = try await warm.runHistory()
        for store in [warm, BenchmarkStore(paths: paths)] {
            for history in [false, true] {
                let task = Task {
                    withUnsafeCurrentTask { $0?.cancel() }
                    return try await (history ? store.runHistory() : store.rows())
                }
                do { _ = try await task.value; XCTFail("Cancelled read returned data") }
                catch { XCTAssertTrue(error is CancellationError) }
            }
        }
    }
    func testOversizedCompleteLineFailsThenValidReplacementCanLoad() async throws {
        let (paths, store) = try fixture(), file = paths.data.appendingPathComponent("results.jsonl")
        try put([row("one")], at: file); _ = try await store.rows()
        var data = Data("{\"payload\":\"".utf8); data.append(Data(repeating: 120, count: 17 << 20)); data.append(contentsOf: "\"}\n".utf8)
        try NativeFile.writeAtomic(data, to: file)
        do { _ = try await store.rows(); XCTFail("Oversized terminated row admitted") }
        catch { XCTAssertTrue(error.localizedDescription.contains("oversized row")) }
        try put([row("restored")], at: file)
        let restored = try await store.rows(); XCTAssertEqual(restored.map { $0["id"].string }, ["restored"])
    }
}
