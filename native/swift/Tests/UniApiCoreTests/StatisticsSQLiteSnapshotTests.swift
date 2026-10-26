import XCTest
import Darwin
import CSQLite
@testable import UniApiCore

final class StatisticsSQLiteSnapshotTests: XCTestCase {
    private func root() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("statistics-sqlite-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }; return url
    }
    private func writer(_ file: URL) throws -> NativeDatabase {
        let db = try NativeDatabase(url: file)
        try db.executeScript("PRAGMA wal_autocheckpoint=0; CREATE TABLE fixture(value INTEGER); INSERT INTO fixture VALUES(100);")
        return db
    }
    private func values(_ file: URL) throws -> [Int] {
        var db: OpaquePointer?
        guard sqlite3_open_v2(file.path, &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK else { throw NativeFailure("Fixture snapshot open failed") }
        defer { sqlite3_close(db) }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT value FROM fixture ORDER BY value", -1, &statement, nil) == SQLITE_OK else { throw NativeFailure("Fixture snapshot query failed") }
        defer { sqlite3_finalize(statement) }
        var result: [Int] = []
        while sqlite3_step(statement) == SQLITE_ROW { result.append(Int(sqlite3_column_int(statement, 0))) }
        return result
    }
    func testReadsCommittedWALWithoutCreatingOrChangingAnyForeignSidecar() throws {
        let root = try root(), original = root.appendingPathComponent("writer/source.db"), source = root.appendingPathComponent("readonly/source.db")
        let writer = try writer(original)
        try FileManager.default.createDirectory(at: source.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: original, to: source)
        try FileManager.default.copyItem(atPath: original.path + "-wal", toPath: source.path + "-wal")
        let main = try Data(contentsOf: source), wal = try Data(contentsOf: URL(fileURLWithPath: source.path + "-wal"))
        // No source SHM exists and the source directory cannot create one.
        XCTAssertEqual(chmod(source.deletingLastPathComponent().path, 0o500), 0)
        defer { _ = chmod(source.deletingLastPathComponent().path, 0o700) }
        let reader = try StatisticsSourceDatabase(source)
        XCTAssertEqual(try reader.rows("SELECT value FROM fixture").first?["value"], 100)
        XCTAssertFalse(FileManager.default.fileExists(atPath: source.path + "-shm"))
        XCTAssertEqual(try Data(contentsOf: source), main)
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: source.path + "-wal")), wal)
        XCTAssertEqual(try writer.query("SELECT value FROM fixture").first?["value"], 100)
    }
    func testSourceSHMIsIgnoredAndPrivateSnapshotIsProtectedAndRemoved() throws {
        let root = try root(), file = root.appendingPathComponent("source.db"), scratch = root.appendingPathComponent("scratch")
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        let writer = try writer(file)
        let shm = URL(fileURLWithPath: file.path + "-shm"), before = try Data(contentsOf: shm)
        var snapshot: SQLiteSnapshotCore? = try SQLiteSnapshotCore(file, temporaryRoot: scratch)
        let privateFile = snapshot!.database
        XCTAssertEqual(try values(privateFile), [100])
        XCTAssertEqual((try FileManager.default.attributesOfItem(atPath: privateFile.path)[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        XCTAssertEqual((try FileManager.default.attributesOfItem(atPath: privateFile.deletingLastPathComponent().path)[.posixPermissions] as? NSNumber)?.intValue, 0o700)
        XCTAssertEqual(try Data(contentsOf: shm), before)
        snapshot = nil; XCTAssertFalse(FileManager.default.fileExists(atPath: privateFile.path))
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: scratch.path).isEmpty)
        XCTAssertEqual(try writer.query("SELECT value FROM fixture").first?["value"], 100)
    }
    func testConcurrentWALChangeRetriesAndReadsTheCompleteNewPair() throws {
        let root = try root(), file = root.appendingPathComponent("source.db"), writer = try writer(file)
        var attempts = 0
        let snapshot = try SQLiteSnapshotCore(file, temporaryRoot: root, afterCopy: { attempt in
            attempts += 1
            if attempt == 0 { try writer.execute("INSERT INTO fixture VALUES(?)", [200]) }
        })
        XCTAssertEqual(attempts, 2); XCTAssertEqual(try values(snapshot.database), [100, 200])
        XCTAssertEqual(try writer.query("SELECT COUNT(*) AS n FROM fixture").first?["n"], 2)
    }
    func testContinuouslyChangingSourceFailsAndCleansEveryPrivateAttempt() throws {
        let root = try root(), file = root.appendingPathComponent("source.db"), scratch = root.appendingPathComponent("scratch")
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        let writer = try writer(file)
        XCTAssertThrowsError(try SQLiteSnapshotCore(file, temporaryRoot: scratch, afterCopy: { attempt in try writer.execute("INSERT INTO fixture VALUES(?)", [.number(Double(attempt + 200))]) }))
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: scratch.path).isEmpty)
    }
    func testLinksFIFOHotJournalAndSizeBoundsAreRejectedWithoutOpeningSQLite() throws {
        let root = try root(), file = root.appendingPathComponent("source.db"), writer = try writer(file)
        let link = root.appendingPathComponent("link.db")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: file)
        XCTAssertThrowsError(try SQLiteSnapshotCore(link, temporaryRoot: root))
        let fifo = root.appendingPathComponent("pipe.db"); XCTAssertEqual(mkfifo(fifo.path, 0o600), 0)
        XCTAssertThrowsError(try SQLiteSnapshotCore(fifo, temporaryRoot: root))
        XCTAssertThrowsError(try SQLiteSnapshotCore(file, temporaryRoot: root, maximumDatabaseBytes: 1))
        XCTAssertThrowsError(try SQLiteSnapshotCore(file, temporaryRoot: root, maximumWALBytes: 1))
        let journal = URL(fileURLWithPath: file.path + "-journal")
        try NativeFile.writeAtomic(Data("unrecovered journal".utf8), to: journal)
        XCTAssertThrowsError(try SQLiteSnapshotCore(file, temporaryRoot: root))
        try FileManager.default.removeItem(at: journal)
        XCTAssertEqual(try writer.query("SELECT value FROM fixture").first?["value"], 100)
    }
    func testNonWALDatabaseWorksAndLinkedWALDoesNotRedirectSnapshot() throws {
        let root = try root(), file = root.appendingPathComponent("source.db")
        do { let db = try writer(file); try db.executeScript("PRAGMA wal_checkpoint(TRUNCATE); PRAGMA journal_mode=DELETE;"); XCTAssertEqual(try db.query("SELECT value FROM fixture").first?["value"], 100) }
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path + "-wal"))
        let snapshot = try SQLiteSnapshotCore(file, temporaryRoot: root)
        XCTAssertEqual(try values(snapshot.database), [100])
        let outside = root.appendingPathComponent("other-wal")
        try NativeFile.writeAtomic(Data("private fixture".utf8), to: outside)
        try FileManager.default.createSymbolicLink(at: URL(fileURLWithPath: file.path + "-wal"), withDestinationURL: outside)
        XCTAssertThrowsError(try SQLiteSnapshotCore(file, temporaryRoot: root))
        XCTAssertEqual(try Data(contentsOf: outside), Data("private fixture".utf8))
    }
    func testCommittedPersistJournalIsColdAndAllForeignFilesStayUnchanged() throws {
        let root = try root(), file = root.appendingPathComponent("source.db")
        let writer = try NativeDatabase(url: file)
        try writer.executeScript("PRAGMA wal_checkpoint(TRUNCATE); PRAGMA journal_mode=PERSIST; CREATE TABLE fixture(value INTEGER); INSERT INTO fixture VALUES(100);")
        let journal = URL(fileURLWithPath: file.path + "-journal")
        let shm = URL(fileURLWithPath: file.path + "-shm")
        let priorSHM = FileManager.default.fileExists(atPath: shm.path) ? try Data(contentsOf: shm) : nil
        let before = try [file, journal].map { try Data(contentsOf: $0) }
        XCTAssertGreaterThan(before[1].count, 512); XCTAssertTrue(before[1].prefix(28).allSatisfy { $0 == 0 })
        var metadata = [stat(), stat()]
        for (index, url) in [file, journal].enumerated() { XCTAssertEqual(lstat(url.path, &metadata[index]), 0) }
        let reader = try StatisticsSourceDatabase(file)
        XCTAssertEqual(try reader.rows("SELECT value FROM fixture").first?["value"], 100)
        XCTAssertEqual(try [file, journal].map { try Data(contentsOf: $0) }, before)
        for (index, url) in [file, journal].enumerated() {
            var after = stat(); XCTAssertEqual(lstat(url.path, &after), 0)
            XCTAssertEqual(after.st_ino, metadata[index].st_ino); XCTAssertEqual(after.st_size, metadata[index].st_size)
            XCTAssertEqual(after.st_mtimespec.tv_sec, metadata[index].st_mtimespec.tv_sec); XCTAssertEqual(after.st_mtimespec.tv_nsec, metadata[index].st_mtimespec.tv_nsec)
            XCTAssertEqual(after.st_ctimespec.tv_sec, metadata[index].st_ctimespec.tv_sec); XCTAssertEqual(after.st_ctimespec.tv_nsec, metadata[index].st_ctimespec.tv_nsec)
        }
        if let priorSHM { XCTAssertEqual(try Data(contentsOf: shm), priorSHM) }
        else { XCTAssertFalse(FileManager.default.fileExists(atPath: shm.path)) }
        XCTAssertEqual(try writer.query("SELECT value FROM fixture").first?["value"], 100)
    }
    func testPersistCommitDuringCopyRetriesBeforeReadingTheNewCompleteDatabase() throws {
        let root = try root(), file = root.appendingPathComponent("source.db")
        let writer = try NativeDatabase(url: file)
        try writer.executeScript("PRAGMA wal_checkpoint(TRUNCATE); PRAGMA journal_mode=PERSIST; CREATE TABLE fixture(value INTEGER); INSERT INTO fixture VALUES(100);")
        var calls = 0
        let snapshot = try SQLiteSnapshotCore(file, temporaryRoot: root, afterCopy: { attempt in
            calls += 1; if attempt == 0 { try writer.execute("INSERT INTO fixture VALUES(?)", [200]) }
        })
        XCTAssertEqual(calls, 2); XCTAssertEqual(try values(snapshot.database), [100, 200])
    }
    func testColdJournalBecomingPossiblyHotDuringCopyIsRejectedAndPrivateFilesCleaned() throws {
        let root = try root(), file = root.appendingPathComponent("source.db"), scratch = root.appendingPathComponent("scratch")
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        let writer = try NativeDatabase(url: file)
        try writer.executeScript("PRAGMA wal_checkpoint(TRUNCATE); PRAGMA journal_mode=PERSIST; CREATE TABLE fixture(value INTEGER); INSERT INTO fixture VALUES(100);")
        let journal = URL(fileURLWithPath: file.path + "-journal")
        XCTAssertThrowsError(try SQLiteSnapshotCore(file, temporaryRoot: scratch, afterCopy: { attempt in
            if attempt == 0 {
                var bytes = try Data(contentsOf: journal); bytes[0] = 1
                try NativeFile.writeAtomic(bytes, to: journal)
            }
        }))
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: scratch.path).isEmpty)
        try FileManager.default.removeItem(at: journal)
        XCTAssertEqual(try writer.query("SELECT value FROM fixture").first?["value"], 100)
    }
}
