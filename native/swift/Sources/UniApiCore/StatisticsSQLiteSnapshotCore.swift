import Foundation
import Darwin

/// Capture foreign SQLite files without opening SQLite against their paths.
/// Only the private copy may create/rebuild a SHM index. No source SHM is read.
final class SQLiteSnapshotCore {
    let database: URL
    private let workspace: URL
    init(_ source: URL, temporaryRoot: URL = FileManager.default.temporaryDirectory,
         maximumDatabaseBytes: Int64 = 16 * 1024 * 1024 * 1024,
         maximumWALBytes: Int64 = 8 * 1024 * 1024 * 1024,
         attempts: Int = 3, afterCopy: ((Int) throws -> Void)? = nil) throws {
        guard maximumDatabaseBytes >= 0, maximumWALBytes >= 0, attempts > 0 else { throw NativeFailure("Invalid SQLite snapshot limits") }
        let parent = open(source.deletingLastPathComponent().path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard parent >= 0 else { throw NativeFailure("Source database directory must be readable and unlinked") }
        defer { close(parent) }
        let name = source.lastPathComponent
        var template = Array(temporaryRoot.appendingPathComponent("uniapi-sqlite-snapshot-XXXXXX").path.utf8CString)
        let created = template.withUnsafeMutableBufferPointer { pointer -> String? in
            guard let path = mkdtemp(pointer.baseAddress!) else { return nil }; return String(cString: path)
        }
        guard let created else { throw NativeFailure("Cannot create private SQLite snapshot") }
        let folder = URL(fileURLWithPath: created, isDirectory: true)
        var retained = false
        defer { if !retained { try? FileManager.default.removeItem(at: folder) } }
        var captured: URL?
        for attempt in 0..<attempts {
            try Task.checkCancellation()
            let destinationDirectory = folder.appendingPathComponent(String(attempt), isDirectory: true)
            guard mkdir(destinationDirectory.path, 0o700) == 0 else { throw NativeFailure("Cannot prepare SQLite snapshot directory") }
            let target = destinationDirectory.appendingPathComponent("store.sqlite3")
            do {
                // PERSIST commits leave a nonempty journal with a zeroed header.
                // Observe that cold header through its protected descriptor;
                // never ask SQLite to recover or alter the foreign journal.
                let journal = try Self.openSource(parent: parent, name: name + "-journal", limit: maximumDatabaseBytes, optional: true)
                defer { if let journal { close(journal.fd) } }
                guard try Self.coldJournal(journal) else { throw NativeFailure("Source database has a pending rollback journal") }
                let main = try Self.openSource(parent: parent, name: name, limit: maximumDatabaseBytes, optional: false)!
                defer { close(main.fd) }
                let wal = try Self.openSource(parent: parent, name: name + "-wal", limit: maximumWALBytes, optional: true)
                defer { if let wal { close(wal.fd) } }
                try Self.copy(main, to: target)
                if let wal { try Self.copy(wal, to: URL(fileURLWithPath: target.path + "-wal")) }
                else { try Self.prepareClosedWAL(main, target: target) }
                try afterCopy?(attempt)
                guard try Self.coldJournal(journal), Self.unchanged(main, parent: parent, name: name),
                      Self.unchanged(wal, parent: parent, name: name + "-wal"),
                      Self.unchanged(journal, parent: parent, name: name + "-journal") else {
                    throw NativeFailure("Source database changed during snapshot")
                }
                captured = target; break
            } catch let error as NativeFailure where error.message == "Source database changed during snapshot" {
                try? FileManager.default.removeItem(at: destinationDirectory)
            }
        }
        guard let captured else { throw NativeFailure("Source database is changing; retry the usage scan") }
        database = captured; workspace = folder; retained = true
    }
    deinit { try? FileManager.default.removeItem(at: workspace) }

    private struct Source { let fd: Int32; let info: stat }
    private static func openSource(parent: Int32, name: String, limit: Int64, optional: Bool) throws -> Source? {
        let fd = openat(parent, name, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        if fd < 0 { if optional && errno == ENOENT { return nil }; throw NativeFailure("Source database must be readable and unlinked") }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_nlink == 1,
              info.st_uid == geteuid(), info.st_size >= 0, info.st_size <= limit else {
            close(fd); throw NativeFailure("Source database must be a bounded owned regular file")
        }
        return Source(fd: fd, info: info)
    }
    private static func prepareClosedWAL(_ source: Source, target: URL) throws {
        // A cleanly checkpointed WAL store can retain header mode 2 without a
        // sidecar. Apple's read-only SQLite cannot initialize its WAL index in
        // that shape. Only the private copy receives an empty WAL; source-side
        // absence is still rechecked below, so a newly arriving WAL retries.
        guard source.info.st_size >= 20 else { return }
        var modes = [UInt8](repeating: 0, count: 2), offset = 0
        while offset < modes.count {
            let count = modes.withUnsafeMutableBytes { bytes in
                pread(source.fd, bytes.baseAddress!.advanced(by: offset), bytes.count - offset, off_t(18 + offset))
            }
            if count < 0 && errno == EINTR { continue }
            guard count > 0 else { throw NativeFailure("Source database changed during snapshot") }
            offset += count
        }
        guard modes == [2, 2] else { return }
        let fd = open(target.path + "-wal", O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw NativeFailure("Cannot prepare private closed-WAL snapshot") }
        defer { close(fd) }
        guard fchmod(fd, 0o600) == 0 else { throw NativeFailure("Cannot protect private closed-WAL snapshot") }
    }
    private static func stable(_ a: stat, _ b: stat) -> Bool {
        a.st_dev == b.st_dev && a.st_ino == b.st_ino && a.st_size == b.st_size &&
        a.st_mtimespec.tv_sec == b.st_mtimespec.tv_sec && a.st_mtimespec.tv_nsec == b.st_mtimespec.tv_nsec &&
        a.st_ctimespec.tv_sec == b.st_ctimespec.tv_sec && a.st_ctimespec.tv_nsec == b.st_ctimespec.tv_nsec
    }
    private static func coldJournal(_ source: Source?) throws -> Bool {
        guard let source, source.info.st_size > 0 else { return true }
        // SQLite invalidates the complete 28-byte rollback header on a PERSIST
        // commit. Anything shorter or nonzero remains conservatively unsafe.
        guard source.info.st_size >= 28 else { return false }
        var header = [UInt8](repeating: 0, count: 28), position = 0
        while position < header.count {
            let count = header.withUnsafeMutableBytes { bytes in
                pread(source.fd, bytes.baseAddress!.advanced(by: position), bytes.count - position, off_t(position))
            }
            if count < 0 && errno == EINTR { continue }
            guard count > 0 else { throw NativeFailure("Source database changed during snapshot") }
            position += count
        }
        return header.allSatisfy { $0 == 0 }
    }
    private static func unchanged(_ source: Source?, parent: Int32, name: String) -> Bool {
        var path = stat()
        let exists = fstatat(parent, name, &path, AT_SYMLINK_NOFOLLOW) == 0
        guard let source else { return !exists && errno == ENOENT }
        var descriptor = stat()
        return exists && fstat(source.fd, &descriptor) == 0 && stable(source.info, descriptor) && stable(source.info, path)
    }
    private static func copy(_ source: Source, to target: URL) throws {
        let output = open(target.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard output >= 0 else { throw NativeFailure("Cannot prepare private SQLite copy") }
        defer { close(output) }
        guard fchmod(output, 0o600) == 0 else { throw NativeFailure("Cannot protect private SQLite copy") }
        var remaining = source.info.st_size, bytes = [UInt8](repeating: 0, count: 1 << 20)
        while remaining > 0 {
            try Task.checkCancellation()
            let count = Darwin.read(source.fd, &bytes, min(bytes.count, Int(remaining)))
            if count < 0 && errno == EINTR { continue }
            guard count > 0 else { throw NativeFailure("Source database changed during snapshot") }
            try bytes.withUnsafeBytes { buffer in
                var position = 0
                while position < count {
                    let written = Darwin.write(output, buffer.baseAddress!.advanced(by: position), count - position)
                    if written < 0 && errno == EINTR { continue }
                    guard written > 0 else { throw NativeFailure("Cannot write private SQLite copy") }
                    position += written
                }
            }
            remaining -= Int64(count)
        }
    }
}
