import Foundation
import CoreFoundation
import Darwin

/// An explicit local recording has its own private file, bounded lifetime and
/// metadata schema. It cannot be redirected to an arbitrary caller-supplied file.
public final class NativeUIProfileFile: @unchecked Sendable {
    public let sessionID: UUID
    public let url: URL
    private let lock = NSLock()
    private var file: Int32 = -1
    private var folder: Int32 = -1
    private var bytes = 0, records = 0
    private var device: dev_t = 0, inode: ino_t = 0
    private let maximumBytes: Int, maximumRecords: Int
    private let maximumDuration: Double
    private let elapsed: () -> Double

    public convenience init(dataRoot: URL) throws {
        let clock = ContinuousClock(), start = clock.now
        try self.init(dataRoot: dataRoot, sessionID: UUID(), maximumBytes: 4 << 20,
                      maximumRecords: 4096, maximumDuration: 300, elapsed: {
            let value = start.duration(to: clock.now).components
            return Double(value.seconds) + Double(value.attoseconds) / 1e18
        })
    }

    init(dataRoot: URL, sessionID: UUID, maximumBytes: Int, maximumRecords: Int,
         maximumDuration: Double, elapsed: @escaping () -> Double) throws {
        guard maximumBytes > 0, maximumBytes <= 4 << 20, maximumRecords > 0, maximumRecords <= 4096,
              maximumDuration.isFinite, maximumDuration > 0, maximumDuration <= 300 else {
            throw NativeFailure("Invalid performance recording limits.")
        }
        self.sessionID = sessionID; self.maximumBytes = maximumBytes
        self.maximumRecords = maximumRecords; self.maximumDuration = maximumDuration; self.elapsed = elapsed
        let root = try Self.openDataRoot(dataRoot)
        defer { Darwin.close(root) }
        let logs = try Self.child(root, name: "logs", privateMode: false)
        defer { Darwin.close(logs) }
        let directory = try Self.child(logs, name: "ui-recordings", privateMode: true)
        let name = "ui-" + sessionID.uuidString.lowercased() + ".jsonl"
        let descriptor = openat(directory, name, O_WRONLY | O_APPEND | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { Darwin.close(directory); throw NativeFailure("Cannot create a fresh performance recording.") }
        do {
            try NativeLegacyProtected.noACL(descriptor)
            var info = stat()
            guard fstat(descriptor, &info) == 0, Self.safeFile(info), info.st_size == 0 else {
                throw NativeFailure("Performance recording file is unsafe.")
            }
            file = descriptor; folder = directory; device = info.st_dev; inode = info.st_ino
        } catch {
            Darwin.close(descriptor); Darwin.close(directory); throw error
        }
        url = dataRoot.standardizedFileURL.appendingPathComponent("logs/ui-recordings/" + name)
    }

    deinit { close() }
    public func close() { lock.withLock { closeLocked() } }
    private func closeLocked() {
        if file >= 0 { Darwin.close(file); file = -1 }
        if folder >= 0 { Darwin.close(folder); folder = -1 }
    }

    public func append(_ data: Data) throws {
        try lock.withLock {
            do {
                guard file >= 0 else { throw NativeFailure("Performance recording is closed.") }
                let age = elapsed()
                guard age.isFinite, age >= 0, age < maximumDuration else {
                    throw NativeFailure("Performance recording reached its five-minute limit.")
                }
                let record = try sanitized(data)
                guard records < maximumRecords, record.count <= maximumBytes - bytes else {
                    throw NativeFailure("Performance recording reached its size limit.")
                }
                var info = stat(), named = stat()
                guard fstat(file, &info) == 0, Self.safeFile(info), info.st_dev == device, info.st_ino == inode,
                      info.st_size == bytes,
                      fstatat(folder, url.lastPathComponent, &named, AT_SYMLINK_NOFOLLOW) == 0,
                      Self.safeFile(named), named.st_dev == device, named.st_ino == inode else {
                    throw NativeFailure("Performance recording file changed independently.")
                }
                try NativeLegacyProtected.noACL(file)
                var offset = 0
                try record.withUnsafeBytes { buffer in
                    while offset < buffer.count {
                        let written = Darwin.write(file, buffer.baseAddress!.advanced(by: offset), buffer.count - offset)
                        if written < 0 && errno == EINTR { continue }
                        guard written > 0 else { throw NativeFailure("Cannot write the performance recording.") }
                        offset += written
                    }
                }
                bytes += record.count; records += 1
            } catch {
                // Never truncate on failure: the file may have been changed
                // independently. A partial append is an incomplete tail that
                // readers must reject; earlier complete records stay intact.
                closeLocked(); throw error
            }
        }
    }

    private func sanitized(_ data: Data) throws -> Data {
        let required: Set<String> = ["schema", "pid", "session", "visit", "page", "initial", "trigger", "phase",
            "elapsedMs", "userCPUMs", "systemCPUMs", "peakResidentBytes", "recordedAt"]
        let optional: Set<String> = ["parentNavigationVisit", "reason", "origin"]
        guard data.count <= 16384, var row = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              required.isSubset(of: Set(row.keys)), Set(row.keys).isSubset(of: required.union(optional)),
              integer(row["schema"], maximum: 1) == 1,
              integer(row["pid"], maximum: Int64(Int32.max)) != nil,
              integer(row["visit"], maximum: Int64.max) != nil,
              (row["session"] as? String).flatMap(UUID.init(uuidString:)) == sessionID,
              let initial = row["initial"] as? NSNumber, CFGetTypeID(initial) == CFBooleanGetTypeID(), !initial.boolValue,
              let page = row["page"] as? String, NativeNavigationPreferences.Page(rawValue: page) != nil,
              let trigger = row["trigger"] as? String, ["navigation", "refresh", "rebuild"].contains(trigger),
              let phase = row["phase"] as? String,
              ["visitStarted", "firstViewCommit", "dataViewCommit", "failureViewCommit", "firstDisplayCallback", "dataDisplayCallback", "failureDisplayCallback", "cancelled", "incomplete"].contains(phase),
              ["elapsedMs", "userCPUMs", "systemCPUMs", "peakResidentBytes"].allSatisfy({ finite(row[$0]) }),
              let date = row["recordedAt"] as? String,
              date.range(of: #"^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d{1,9})?Z$"#, options: .regularExpression) != nil,
              row["origin"] == nil || row["origin"] as? String == "manual",
              row["parentNavigationVisit"] == nil || integer(row["parentNavigationVisit"], maximum: Int64.max) != nil,
              row["reason"] == nil || ["replacedRead", "scopeChanged", "inactive", "disappeared", "taskCancelled", "noAcceptedCommit", "sessionEnded"].contains(row["reason"] as? String ?? "") else {
            throw NativeFailure("Performance recording accepts timing metadata only.")
        }
        row["session"] = sessionID.uuidString; row["origin"] = "manual"
        // Re-encode admitted values rather than retaining unchecked raw JSON,
        // including any shadowed values in duplicate keys.
        var canonical = try JSONSerialization.data(withJSONObject: row, options: [.sortedKeys])
        canonical.append(10)
        guard canonical.count <= 4096 else { throw NativeFailure("Performance recording row is too large.") }
        return canonical
    }
    private func finite(_ value: Any?) -> Bool {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else { return false }
        return number.doubleValue.isFinite && number.doubleValue >= 0 && number.doubleValue <= 1e18
    }
    private func integer(_ value: Any?, maximum: Int64) -> Int64? {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
        let value = number.doubleValue
        guard value.isFinite, value >= 1, value < Double(Int64.max), value <= Double(maximum), value.rounded() == value else { return nil }
        return Int64(value)
    }
    private static func safeFile(_ info: stat) -> Bool {
        info.st_mode & S_IFMT == S_IFREG && info.st_uid == getuid() && info.st_nlink == 1 && info.st_mode & 0o7777 == 0o600
    }
    private static func openDataRoot(_ url: URL) throws -> Int32 {
        guard url.isFileURL, !url.path.contains("\0") else { throw NativeFailure("Invalid performance recording folder.") }
        var path = url.standardizedFileURL.path
        for alias in ["/var", "/tmp", "/etc"] where path == alias || path.hasPrefix(alias + "/") { path = "/private" + path; break }
        var fd = open("/", O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw NativeFailure("Performance recording folder is unavailable.") }
        do {
            for part in path.split(separator: "/") {
                let next = openat(fd, String(part), O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                guard next >= 0 else { throw NativeFailure("Linked or unavailable performance data folder.") }
                Darwin.close(fd); fd = next
                var info = stat()
                guard fstat(fd, &info) == 0, info.st_uid == 0 || info.st_uid == getuid() else { throw NativeFailure("Performance folder owner is invalid.") }
            }
            var info = stat()
            guard fstat(fd, &info) == 0, info.st_uid == getuid(), info.st_mode & 0o022 == 0 else { throw NativeFailure("Performance data folder is unsafe.") }
            try NativeLegacyProtected.directoryACL(fd)
            return fd
        } catch { Darwin.close(fd); throw error }
    }
    private static func child(_ parent: Int32, name: String, privateMode: Bool) throws -> Int32 {
        if mkdirat(parent, name, 0o700) != 0 && errno != EEXIST { throw NativeFailure("Cannot create the performance folder.") }
        let fd = openat(parent, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw NativeFailure("Linked or unavailable performance folder.") }
        do {
            var info = stat()
            guard fstat(fd, &info) == 0, info.st_uid == getuid(), info.st_mode & (privateMode ? 0o7777 : 0o022) == (privateMode ? 0o700 : 0) else { throw NativeFailure("Performance folder permissions are unsafe.") }
            if privateMode { try NativeLegacyProtected.noACL(fd) } else { try NativeLegacyProtected.directoryACL(fd) }
            return fd
        } catch { Darwin.close(fd); throw error }
    }
}
