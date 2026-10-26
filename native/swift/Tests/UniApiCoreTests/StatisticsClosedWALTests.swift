import XCTest
import CSQLite
import Darwin
import CryptoKit
@testable import UniApiCore

final class StatisticsClosedWALTests: XCTestCase {
    private func store(wal: Bool = true) throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("statistics-closed-wal-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        addTeardownBlock { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: folder.path); try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("store.db")
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(file.path, &db), SQLITE_OK)
        guard let db else { throw NativeFailure("Fixture database unavailable") }
        var closed = false
        defer { if !closed { sqlite3_close(db) } }
        XCTAssertEqual(sqlite3_exec(db, "PRAGMA journal_mode=\(wal ? "WAL" : "DELETE"); CREATE TABLE fixture(value INTEGER); INSERT INTO fixture VALUES(123);", nil, nil, nil), SQLITE_OK)
        XCTAssertEqual(sqlite3_exec(db, "PRAGMA wal_checkpoint(TRUNCATE)", nil, nil, nil), SQLITE_OK)
        XCTAssertEqual(sqlite3_close(db), SQLITE_OK); closed = true
        // Apple's SQLite may retain empty sidecars on close. This fixture owns
        // its now-closed store; normalize exactly the absent-sidecar case.
        for suffix in ["-wal", "-shm"] {
            let sidecar = URL(fileURLWithPath: file.path + suffix)
            if FileManager.default.fileExists(atPath: sidecar.path) {
                if suffix == "-wal" { XCTAssertEqual(try Data(contentsOf: sidecar).count, 0) }
                try FileManager.default.removeItem(at: sidecar)
            }
        }
        return file
    }
    private func signature(_ file: URL) throws -> String {
        var info = stat(); XCTAssertEqual(lstat(file.path, &info), 0)
        let digest = SHA256.hash(data: try Data(contentsOf: file)).map { String(format: "%02x", $0) }.joined()
        return "\(info.st_ino):\(info.st_size):\(info.st_mtimespec):\(info.st_ctimespec):\(digest)"
    }
    func testClosedWALWithoutSidecarsReadsFromPrivateCopyOnly() throws {
        let file = try store()
        let header = try Data(contentsOf: file)
        XCTAssertEqual(Array(header[18...19]), [2, 2])
        for suffix in ["-wal", "-shm"] { XCTAssertFalse(FileManager.default.fileExists(atPath: file.path + suffix)) }
        try FileManager.default.setAttributes([.posixPermissions: 0o400], ofItemAtPath: file.path)
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: file.deletingLastPathComponent().path)
        let before = try signature(file)
        let snapshot = try SQLiteSnapshotCore(file)
        let db = try NativeDatabase(url: snapshot.database, readOnly: true)
        XCTAssertEqual(try db.query("SELECT value FROM fixture").first?["value"], 123)
        XCTAssertEqual(try signature(file), before)
        for suffix in ["-wal", "-shm"] { XCTAssertFalse(FileManager.default.fileExists(atPath: file.path + suffix)) }
        var privateWAL = stat(); XCTAssertEqual(lstat(snapshot.database.path + "-wal", &privateWAL), 0)
        XCTAssertEqual(privateWAL.st_mode & 0o777, 0o600)
        XCTAssertEqual(privateWAL.st_size, 0)
    }
    func testExistingEmptyWALIsPreservedWithoutSourceSHM() throws {
        let file = try store(), wal = URL(fileURLWithPath: file.path + "-wal")
        try NativeFile.writeAtomic(Data(), to: wal)
        let before = try signature(file), sidecar = try signature(wal)
        let snapshot = try SQLiteSnapshotCore(file)
        let db = try NativeDatabase(url: snapshot.database, readOnly: true)
        XCTAssertEqual(try db.query("SELECT value FROM fixture").first?["value"], 123)
        XCTAssertEqual(try signature(file), before); XCTAssertEqual(try signature(wal), sidecar)
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path + "-shm"))
    }
    func testRollbackStoreDoesNotAcquireUnneededWALPlaceholder() throws {
        let file = try store(wal: false), before = try signature(file)
        let snapshot = try SQLiteSnapshotCore(file)
        let db = try NativeDatabase(url: snapshot.database, readOnly: true)
        XCTAssertEqual(try db.query("SELECT value FROM fixture").first?["value"], 123)
        XCTAssertFalse(FileManager.default.fileExists(atPath: snapshot.database.path + "-wal"))
        XCTAssertEqual(try signature(file), before)
    }
    func testNewSourceWALDuringCaptureRetriesInsteadOfIgnoringIt() throws {
        let file = try store(); var attempts: [Int] = []
        let snapshot = try SQLiteSnapshotCore(file, afterCopy: { attempt in
            attempts.append(attempt)
            if attempt == 0 { try NativeFile.writeAtomic(Data(), to: URL(fileURLWithPath: file.path + "-wal")) }
        })
        XCTAssertEqual(attempts, [0, 1])
        let db = try NativeDatabase(url: snapshot.database, readOnly: true)
        XCTAssertEqual(try db.query("SELECT value FROM fixture").first?["value"], 123)
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path + "-shm"))
    }
}
