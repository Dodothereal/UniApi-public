import XCTest
import Darwin
@testable import UniApiCore

final class StatisticsCompressedHistoryTests: XCTestCase {
    // A checksummed, compressed-block Zstandard frame generated from `ledger`
    // with Node's built-in encoder. Tests never require an external command.
    private let encoded = Data(base64Encoded: "KLUv/WRWAB0GAFJMJR5wN9UB6IgRKQkqt1EjRCHUa4DpB+eLsGj5qj5uwQGEGGMCHLWGhNJJFg35JNPo32nY2MmXcVFnH+P21g0UqZmaRiBNSVMCiiyubwfqt8dqx2nd2QJ68LAtYLfK4NKtcL2xio+TK4P7sM04HeZgE2L8OtiHRXCQTl7WYBmSQ9er9YReITYQqJ0c9R6H8Xpv3/XbEP1EEABQyf6GveCb1k1CGxfHGnd0IAA/I49Vdl1C9hQEel4AZHKC+p1Wg8oUFAhuNVg=")!
    private let ledger = "{\"type\":\"session_meta\",\"payload\":{\"id\":\"archive-session\",\"cwd\":\"fixture\"}}\n{\"type\":\"turn_context\",\"payload\":{\"turn_id\":\"old\",\"model\":\"gpt-older\"}}\n{\"type\":\"token_usage_record\",\"timestamp\":\"2026-10-10T10:00:02Z\",\"payload\":{\"turn_id\":\"old\",\"response_id\":\"archived-one\",\"usage\":{\"input_tokens\":100,\"output_tokens\":20,\"cached_input_tokens\":30}}}\n"

    private func directory() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("compressed-statistics-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }; return root.resolvingSymlinksInPath()
    }
    private func put(_ data: Data, _ url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url)
    }
    // Raw blocks are also valid Zstandard. This independent frame builder
    // exercises chunk boundaries without bringing a compressor into the app.
    private func frame(_ bytes: Data) -> Data {
        var out = Data([0x28, 0xb5, 0x2f, 0xfd, 0xa0])
        let size = UInt32(bytes.count)
        for shift in [0, 8, 16, 24] { out.append(UInt8(truncatingIfNeeded: size >> shift)) }
        var position = 0
        repeat {
            let count = min(128 << 10, bytes.count - position), last = position + count == bytes.count
            let block = UInt32(count << 3) | (last ? 1 : 0)
            for shift in [0, 8, 16] { out.append(UInt8(truncatingIfNeeded: block >> shift)) }
            out.append(bytes[position..<(position + count)]); position += count
        } while position < bytes.count
        return out
    }
    private func usage(_ root: URL, compressed: Bool = true) -> URL {
        root.appendingPathComponent("home/.codex/sessions/old.jsonl" + (compressed ? ".zst" : ""))
    }
    private func totals(_ service: NativeStatisticsService) async throws -> JSONValue {
        try await service.handle("overview", input: ["source": "codex", "range": 0])
    }

    func testCompressedBlocksMatchExactPlainUsageAndLeaveSourceUnchanged() throws {
        let root = try directory(), compressed = usage(root), plain = usage(root, compressed: false)
        try put(encoded, compressed); try put(Data(ledger.utf8), plain)
        let actual = try StatisticsImporter.read(compressed, source: "codex").records
        let expected = try StatisticsImporter.read(plain, source: "codex").records
        XCTAssertEqual(try JSONValue.decode(JSONEncoder().encode(actual)), try JSONValue.decode(JSONEncoder().encode(expected)))
        XCTAssertEqual(actual.count, 1); XCTAssertEqual(actual[0].input, 70); XCTAssertEqual(actual[0].cacheRead, 30); XCTAssertEqual(actual[0].grand, 120)
        XCTAssertEqual(try Data(contentsOf: compressed), encoded)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: compressed.deletingLastPathComponent().path).sorted(), ["old.jsonl", "old.jsonl.zst"])
    }
    func testConcatenatedFramesSkippableFrameUnicodeAndUnterminatedTail() throws {
        let url = usage(try directory())
        var bytes = frame(Data("{\"n\":1}\r\n".utf8))
        bytes.append(Data([0x50, 0x2a, 0x4d, 0x18, 3, 0, 0, 0, 1, 2, 3]))
        bytes.append(frame(Data("{\"name\":\"東京\"}".utf8)))
        try put(bytes, url)
        var rows: [JSONValue] = []; try StatisticsImporter.lines(url) { rows.append($0) }
        XCTAssertEqual(rows, [["n": 1], ["name": "東京"]])
    }
    func testLargeRowCrossesInputOutputChunksWithoutDroppingMetadata() throws {
        let url = usage(try directory())
        let ignored = "{\"type\":\"response_item\",\"payload\":{\"type\":\"message\",\"content\":\"" + String(repeating: "x", count: (2 << 20) + 7) + "\"}}\n"
        try put(frame(Data((ignored + ledger).utf8)), url)
        let rows = try StatisticsImporter.read(url, source: "codex").records
        XCTAssertEqual(rows.count, 1); XCTAssertEqual(rows[0].grand, 120)
    }
    func testTruncationChecksumFailureGarbageAndEmptyInputAreRejected() throws {
        let url = usage(try directory())
        var badChecksum = encoded; badChecksum[badChecksum.count - 1] ^= 1
        for bytes in [Data(encoded.dropLast()), badChecksum, encoded + Data([1, 2, 3]), Data()] {
            try put(bytes, url); XCTAssertThrowsError(try StatisticsImporter.read(url, source: "codex"))
        }
        try put(frame(Data()), url)
        XCTAssertTrue(try StatisticsImporter.read(url, source: "codex").records.isEmpty)
    }
    func testCompressedSourceSymlinkAndDirectoryAreRefused() throws {
        let root = try directory(), target = root.appendingPathComponent("target"), link = usage(root)
        try put(encoded, target)
        try FileManager.default.createDirectory(at: link.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
        XCTAssertThrowsError(try StatisticsImporter.read(link, source: "codex"))
        try FileManager.default.removeItem(at: link); try FileManager.default.createDirectory(at: link, withIntermediateDirectories: false)
        XCTAssertThrowsError(try StatisticsImporter.read(link, source: "codex"))
    }
    func testServiceCompressionRenameAndMirrorsKeepIDsModelsAndTotals() async throws {
        let root = try directory(), plain = usage(root, compressed: false), compressed = usage(root)
        try put(Data(ledger.utf8), plain)
        let runtime = try NativeRuntime(paths: NativePaths(root: root, home: root.appendingPathComponent("home")))
        let service = NativeStatisticsService(runtime: runtime)
        let before = try await totals(service)
        try put(encoded, compressed); _ = try await service.handle("rescan")
        let mirror = try await totals(service)
        XCTAssertEqual(mirror["derived"], before["derived"])
        try FileManager.default.removeItem(at: plain); _ = try await service.handle("rescan")
        let after = try await totals(service)
        XCTAssertEqual(after["derived"], before["derived"])
        XCTAssertEqual(try runtime.db.query("SELECT path FROM stats_files").count, 1)
        XCTAssertEqual(try runtime.db.query("SELECT model FROM stats_records").first?["model"], "gpt-older")
        XCTAssertEqual(try Data(contentsOf: compressed), encoded)
    }
    func testFailedCompressedReplacementRetainsLastValidPlainCacheThenRecovers() async throws {
        let root = try directory(), plain = usage(root, compressed: false), compressed = usage(root)
        try put(Data(ledger.utf8), plain)
        let runtime = try NativeRuntime(paths: NativePaths(root: root, home: root.appendingPathComponent("home")))
        let service = NativeStatisticsService(runtime: runtime), before = try await totals(service)
        let existing = try runtime.db.query("SELECT * FROM stats_files"), records = try runtime.db.query("SELECT * FROM stats_records")
        let cachePath = try XCTUnwrap(existing.first?["path"]?.string)
        try FileManager.default.removeItem(at: plain); try put(Data(encoded.dropLast()), compressed)
        _ = try await service.handle("rescan"); let held = try await totals(service)
        XCTAssertEqual(held["derived"], before["derived"]); XCTAssertFalse(held["warnings"].array.isEmpty)
        XCTAssertEqual(try runtime.db.query("SELECT * FROM stats_files"), existing)
        XCTAssertEqual(try runtime.db.query("SELECT * FROM stats_records"), records)
        try put(encoded, compressed); _ = try await service.handle("rescan"); let repaired = try await totals(service)
        XCTAssertEqual(repaired["derived"], before["derived"]); XCTAssertTrue(repaired["warnings"].array.isEmpty)
        XCTAssertEqual(try runtime.db.query("SELECT path,source_path FROM stats_files").first?["path"], .string(cachePath))
        XCTAssertEqual(try runtime.db.query("SELECT path,source_path FROM stats_files").first?["source_path"], .string(cachePath + ".zst"))
    }
    func testCancellationStopsCompressedReaderBeforePublishingRows() async throws {
        let url = usage(try directory()); try put(encoded, url)
        let task = Task { () -> Bool in
            withUnsafeCurrentTask { $0?.cancel() }
            do { _ = try StatisticsImporter.read(url, source: "codex"); return false }
            catch is CancellationError { return true }
            catch { return false }
        }
        let cancelled = await task.value; XCTAssertTrue(cancelled)
    }
    func testReadOnlyLegacyCacheWithoutSourcePathReadsArchiveWithoutMigrationOrWrites() async throws {
        let root = try directory(), home = root.appendingPathComponent("home"), plain = usage(root, compressed: false)
        try put(Data(ledger.utf8), plain)
        let writable = try NativeRuntime(paths: NativePaths(root: root, home: home))
        let writer = NativeStatisticsService(runtime: writable); _ = try await totals(writer)
        try writable.db.execute("ALTER TABLE stats_files DROP COLUMN source_path")
        try writable.db.execute("DELETE FROM schema_migrations WHERE name='stats-source-path-1'")
        let before = try writable.db.query("SELECT * FROM stats_files"), rows = try writable.db.query("SELECT * FROM stats_records")
        try FileManager.default.removeItem(at: plain); try put(encoded, usage(root))
        let readonly = try NativeRuntime(paths: NativePaths(root: root, home: home, readOnly: true))
        let reader = NativeStatisticsService(runtime: readonly), value = try await totals(reader)
        XCTAssertEqual(value["derived"]["summary"]["totals"]["input"].double, 70)
        XCTAssertEqual(value["derived"]["summary"]["totals"]["cacheRead"].double, 30)
        XCTAssertEqual(try writable.db.query("SELECT * FROM stats_files"), before)
        XCTAssertEqual(try writable.db.query("SELECT * FROM stats_records"), rows)
        XCTAssertFalse(try writable.db.query("PRAGMA table_info(stats_files)").contains { $0["name"]?.string == "source_path" })
        XCTAssertTrue(try writable.db.query("SELECT name FROM schema_migrations WHERE name='stats-source-path-1'").isEmpty)
    }
}
