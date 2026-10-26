import XCTest
import Foundation
import Darwin
@testable import UniApiCore

final class StatisticsDiscoveryAcceptanceTests: XCTestCase {
    private struct Fixture {
        let root: URL
        let runtime: NativeRuntime
        let service: NativeStatisticsService
        var home: URL { root.appendingPathComponent("home") }
        var sessions: URL { home.appendingPathComponent(".codex/sessions") }
    }
    private struct Snapshot {
        let files: [JSONObject], rows: [JSONObject]
        let overview: JSONValue, published: JSONValue
    }
    private func fixture() async throws -> Fixture {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("statistics-discovery-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let runtime = try NativeRuntime(paths: NativePaths(root: root.appendingPathComponent("native"), home: root.appendingPathComponent("home")))
        await runtime.jobs.suspendForShutdown()
        return Fixture(root: root, runtime: runtime, service: .shared(runtime: runtime))
    }
    private func put(_ values: [JSONValue], at url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let text = try values.map { String(decoding: try $0.encoded(), as: UTF8.self) }.joined(separator: "\n") + "\n"
        try Data(text.utf8).write(to: url)
    }
    private func codex(_ url: URL, id: String = "one", input: Int = 10) throws {
        try put([
            ["type": "session_meta", "payload": ["id": "private-session", "cwd": "fixture"]],
            ["type": "turn_context", "payload": ["turn_id": .string(id), "model": "fixture-codex"]],
            ["type": "token_usage_record", "timestamp": "2026-10-10T10:00:02Z", "payload": ["turn_id": .string(id), "response_id": .string(id), "usage": ["input_tokens": .number(Double(input)), "output_tokens": 2]]]
        ], at: url)
    }
    private func claude(_ url: URL, id: String, input: Int, output: Int) throws {
        try put([["type": "assistant", "uuid": .string(id), "timestamp": "2026-10-10T10:00:02Z", "sessionId": "private-session", "cwd": "fixture", "message": ["id": .string(id), "model": "fixture-claude", "usage": ["input_tokens": .number(Double(input)), "output_tokens": .number(Double(output))]]]], at: url)
    }
    private func snapshot(_ runtime: NativeRuntime, _ service: NativeStatisticsService) async throws -> Snapshot {
        let overview = try await service.handle("overview")
        return Snapshot(files: try runtime.db.query("SELECT * FROM stats_files ORDER BY path"),
                        rows: try runtime.db.query("SELECT rowid,* FROM stats_records ORDER BY path,rowid"),
                        overview: overview, published: service.cachedSummary())
    }
    private func snapshot(_ f: Fixture) async throws -> Snapshot { try await snapshot(f.runtime, f.service) }
    private func assertPreserved(_ before: Snapshot, _ after: Snapshot, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(after.files, before.files, file: file, line: line)
        XCTAssertEqual(after.rows, before.rows, file: file, line: line)
        for field in ["derived", "sources", "colors", "scan", "warnings"] {
            XCTAssertEqual(after.overview[field], before.overview[field], field, file: file, line: line)
        }
        for field in ["grand", "models", "responses", "loaded", "provenance", "readerGeneration"] {
            XCTAssertEqual(after.published[field], before.published[field], field, file: file, line: line)
        }
        XCTAssertFalse(after.published["scanning"].bool, file: file, line: line)
    }
    private func rejectedRescan(_ service: NativeStatisticsService, file: StaticString = #filePath, line: UInt = #line) async {
        do { _ = try await service.handle("rescan"); XCTFail("Incomplete discovery must throw before import", file: file, line: line) }
        catch { XCTAssertFalse(error is CancellationError, file: file, line: line) }
    }
    private func denied(_ url: URL, mode: mode_t = 0, _ body: () async throws -> Void) async throws {
        var info = stat()
        guard getuid() != 0, lstat(url.path, &info) == 0, info.st_uid == getuid(), info.st_mode & S_IFMT == S_IFDIR,
              chmod(url.path, mode) == 0 else { throw NativeFailure("A real owned-directory permission fault is required") }
        defer { XCTAssertEqual(chmod(url.path, info.st_mode & 0o7777), 0) }
        try await body()
    }
    private func requireEnumerationDenied(_ url: URL) throws {
        var caught: Error?
        do { _ = try FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: nil) }
        catch { caught = error }
        XCTAssertNotNil(caught, "Actual Foundation enumeration must fail")
        errno = 0
        let directory = opendir(url.path), code = errno
        if let directory { closedir(directory) }
        XCTAssertNil(directory); XCTAssertEqual(code, EACCES)
        guard caught != nil && directory == nil && code == EACCES else { throw NativeFailure("Permission fault was not established") }
    }

    func testUnreadableRootRescanPreservesEntireCacheAndPublishedUsageThenRecovers() async throws {
        let f = try await fixture(), path = f.sessions.appendingPathComponent("one.jsonl")
        try codex(path)
        let bytes = try Data(contentsOf: path), before = try await snapshot(f)
        XCTAssertEqual(before.rows.count, 1); XCTAssertEqual(before.published["grand"], 12)
        try await denied(f.sessions) {
            try requireEnumerationDenied(f.sessions)
            await rejectedRescan(f.service)
            let held = try await snapshot(f)
            assertPreserved(before, held)
            XCTAssertFalse(held.published["error"].string.isEmpty)
        }
        _ = try await f.service.handle("rescan")
        let recovered = try await snapshot(f)
        XCTAssertEqual(recovered.rows, before.rows); XCTAssertEqual(recovered.published["grand"], 12)
        XCTAssertTrue(recovered.published["error"].isNull)
        XCTAssertEqual(try Data(contentsOf: path), bytes)
    }

    func testUnreadableNestedSubtreeAbortsBeforeChangedAndDeletedFilesCommit() async throws {
        let f = try await fixture(), nested = f.sessions.appendingPathComponent("nested")
        try codex(nested.appendingPathComponent("one.jsonl"))
        let changed = f.home.appendingPathComponent(".claude/projects/fixture/changed.jsonl")
        let deleted = f.home.appendingPathComponent(".claude/projects/fixture/deleted.jsonl")
        try claude(changed, id: "changed", input: 20, output: 3)
        try claude(deleted, id: "deleted", input: 4, output: 1)
        let before = try await snapshot(f)
        XCTAssertEqual(before.files.count, 3); XCTAssertEqual(before.published["grand"], 40)
        try claude(changed, id: "changed", input: 100, output: 3)
        try FileManager.default.removeItem(at: deleted)
        try await denied(nested) {
            try requireEnumerationDenied(nested)
            await rejectedRescan(f.service)
            let held = try await snapshot(f)
            assertPreserved(before, held)
        }
        _ = try await f.service.handle("rescan")
        let after = try await snapshot(f)
        XCTAssertEqual(after.files.count, 2); XCTAssertEqual(after.rows.count, 2)
        XCTAssertEqual(after.published["grand"], 115)
        XCTAssertFalse(after.rows.contains { $0["msg_id"]?.string == "deleted" })
        XCTAssertEqual(after.rows.first { $0["source"]?.string == "claude" }?["input"], 100)
    }

    func testReadOnlyRescanPreservesPublishedGenerationOnDiscoveryError() async throws {
        let f = try await fixture(), path = f.sessions.appendingPathComponent("one.jsonl")
        try codex(path); _ = try await snapshot(f)
        let readonly = try NativeRuntime(paths: NativePaths(root: f.runtime.paths.root, home: f.home, readOnly: true))
        await readonly.jobs.suspendForShutdown()
        let reader = NativeStatisticsService.shared(runtime: readonly), before = try await snapshot(readonly, reader)
        try codex(path, input: 20)
        try await denied(f.sessions) {
            try requireEnumerationDenied(f.sessions)
            await rejectedRescan(reader)
            let held = try await snapshot(readonly, reader)
            assertPreserved(before, held)
        }
        _ = try await reader.handle("rescan")
        let after = try await snapshot(readonly, reader)
        XCTAssertEqual(after.published["grand"], 22)
        XCTAssertEqual(after.files, before.files); XCTAssertEqual(after.rows, before.rows)
        XCTAssertEqual(try f.runtime.db.query("SELECT rowid,* FROM stats_records ORDER BY path,rowid"), before.rows)
    }

    func testVerifiedDeletionPrunesAfterCompleteDiscovery() async throws {
        let f = try await fixture(), path = f.sessions.appendingPathComponent("one.jsonl")
        try codex(path)
        let before = try await snapshot(f); XCTAssertEqual(before.published["grand"], 12)
        try FileManager.default.removeItem(at: path)
        _ = try await f.service.handle("rescan")
        let after = try await snapshot(f)
        XCTAssertTrue(after.files.isEmpty); XCTAssertTrue(after.rows.isEmpty)
        XCTAssertEqual(after.published["grand"], 0); XCTAssertTrue(after.published["loaded"].bool)
        try FileManager.default.removeItem(at: f.sessions)
        _ = try await f.service.handle("rescan")
        let absentRoot = try await f.service.metadataDiagnostics()
        XCTAssertEqual(absentRoot["files"], 0)
    }

    func testMissingOptionalRootsRemainNormalAndLinkedRootRefuses() async throws {
        let f = try await fixture()
        let empty = try await snapshot(f)
        XCTAssertEqual(empty.published["grand"], 0); XCTAssertTrue(empty.rows.isEmpty)
        let diagnostic = try await f.service.metadataDiagnostics()
        XCTAssertEqual(diagnostic["files"], 0)
        let source = f.sessions.appendingPathComponent("one.jsonl")
        try codex(source); _ = try await f.service.handle("rescan")
        let before = try await snapshot(f)
        let moved = f.home.appendingPathComponent("saved-sessions")
        try FileManager.default.moveItem(at: f.sessions, to: moved)
        try FileManager.default.createSymbolicLink(at: f.sessions, withDestinationURL: moved)
        await rejectedRescan(f.service)
        let held = try await snapshot(f)
        assertPreserved(before, held)
        try FileManager.default.removeItem(at: f.sessions)
        try FileManager.default.moveItem(at: moved, to: f.sessions)
        _ = try await f.service.handle("rescan")
        let recovered = try await snapshot(f); XCTAssertEqual(recovered.published["grand"], 12)
    }

    func testMetadataDiagnosticsThrowsForUnreadableRootWithoutChangingCache() async throws {
        let f = try await fixture(); try codex(f.sessions.appendingPathComponent("one.jsonl"))
        let before = try await snapshot(f)
        try await denied(f.sessions) {
            try requireEnumerationDenied(f.sessions)
            do { _ = try await f.service.metadataDiagnostics(); XCTFail("Metadata diagnosis must not report a complete empty inventory") }
            catch { XCTAssertFalse(error is CancellationError) }
            let after = try await snapshot(f)
            assertPreserved(before, after)
        }
    }

    func testSearchDeniedDirectoryCannotBeTreatedAsMissingEntries() async throws {
        let f = try await fixture(), path = f.sessions.appendingPathComponent("one.jsonl")
        try codex(path); let before = try await snapshot(f)
        try await denied(f.sessions, mode: 0o400) {
            var info = stat()
            errno = 0; XCTAssertEqual(lstat(path.path, &info), -1); XCTAssertEqual(errno, EACCES)
            await rejectedRescan(f.service)
            let held = try await snapshot(f); assertPreserved(before, held)
        }
        _ = try await f.service.handle("rescan")
        let after = try await snapshot(f); XCTAssertEqual(after.published["grand"], 12)
    }

    func testCheckedWALSignaturePropagatesPermissionErrorAndPreservesRegularSelection() async throws {
        let f = try await fixture(), parent = f.home.appendingPathComponent("wal-control")
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let wal = parent.appendingPathComponent("opencode.db-wal")
        XCTAssertNil(try NativeStatisticsService.checkedDiscoverySignature(wal))
        try Data([1, 2, 3]).write(to: wal)
        let signature = try XCTUnwrap(NativeStatisticsService.checkedDiscoverySignature(wal))
        XCTAssertEqual(signature.size, 3)
        XCTAssertEqual(signature.mtime, try XCTUnwrap(NativeStatisticsService.diskSignature(wal)).mtime)
        try await denied(parent) {
            XCTAssertThrowsError(try NativeStatisticsService.checkedDiscoverySignature(wal)) { error in
                let value = error as NSError
                XCTAssertEqual(value.domain, NSPOSIXErrorDomain); XCTAssertEqual(value.code, Int(EACCES))
            }
        }
        let link = parent.appendingPathComponent("link-wal")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: wal)
        XCTAssertNil(try NativeStatisticsService.checkedDiscoverySignature(link))
        XCTAssertNil(try NativeStatisticsService.checkedDiscoverySignature(parent))
        XCTAssertEqual(try Data(contentsOf: wal), Data([1, 2, 3]))
    }
}
