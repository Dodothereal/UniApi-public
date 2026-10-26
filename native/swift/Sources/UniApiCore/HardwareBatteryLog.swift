import Foundation
import Darwin
import CNativeSystem

/// Device diagnostics are local and bounded. All writes and rotations use an
/// opened directory and verified descriptors, never a followed archive link.
public final class NativeBatteryLog: @unchecked Sendable {
    private let directory: URL, maximum: Int, files: Int
    private let lock = NSLock()
    private var sequence = 0, lastFailure: Double = -.infinity
    public init(directory: URL, maximum: Int = 8 * 1024 * 1024, files: Int = 8) {
        self.directory = directory; self.maximum = max(256, maximum); self.files = max(2, min(32, files))
    }
    @discardableResult public func write(_ event: String, data: JSONValue = [:]) -> Bool {
        lock.lock(); defer { lock.unlock() }
        do { try append(event, data); return true }
        catch {
            let now = ProcessInfo.processInfo.systemUptime
            if now - lastFailure >= 60 { lastFailure = now; FileHandle.standardError.write(Data(("Battery diagnostics could not be written: " + String(error.localizedDescription.prefix(500)) + "\n").utf8)) }
            return false
        }
    }
    private func verify(_ fd: Int32, directory: Bool) throws -> stat {
        var info = stat()
        guard fstat(fd, &info) == 0, (info.st_mode & S_IFMT) == (directory ? S_IFDIR : S_IFREG), info.st_uid == geteuid(), directory || info.st_nlink == 1 else { throw NativeFailure("Unsafe battery diagnostic inode") }
        errno = 0; let acl = acl_get_fd_np(fd, ACL_TYPE_EXTENDED), code = errno
        if let acl { acl_free(UnsafeMutableRawPointer(acl)) }
        guard acl == nil && code == ENOENT else { throw NativeFailure("Battery diagnostic inode has extended access controls") }
        guard fchmod(fd, directory ? 0o700 : 0o600) == 0 else { throw NativeFailure("Battery diagnostic permissions could not be secured") }
        return info
    }
    private func append(_ event: String, _ data: JSONValue) throws {
        let folder = try openDirectory(); defer { close(folder) }
        _ = try verify(folder, directory: true)
        sequence += 1
        var record: JSONValue = ["schema": 1, "at": .string(ISO8601DateFormatter().string(from: Date())), "pid": .number(Double(getpid())), "sequence": .number(Double(sequence)), "event": .string(event), "data": data]
        var line = try record.encoded() + Data([10])
        let recordLimit = min(64 * 1024, maximum)
        if line.count > recordLimit { record["data"] = ["truncated": true]; line = try record.encoded() + Data([10]) }
        if line.count > recordLimit { record["event"] = "truncated"; line = try record.encoded() + Data([10]) }
        guard line.count <= recordLimit else { throw NativeFailure("Battery diagnostic record exceeds its limit") }
        func file(_ name: String, create: Bool) throws -> Int32? {
            let fd = openat(folder, name, O_WRONLY | O_APPEND | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC | (create ? O_CREAT : 0), 0o600)
            if fd < 0 { if !create && errno == ENOENT { return nil }; throw NativeFailure("Battery diagnostic file could not be opened") }
            do { _ = try verify(fd, directory: false); return fd } catch { close(fd); throw error }
        }
        let name = "battery.jsonl"
        var descriptor: Int32? = try file(name, create: true)
        defer { if let descriptor { close(descriptor) } }
        var info = stat(); guard let current = descriptor, fstat(current, &info) == 0 else { throw NativeFailure("Battery diagnostic metadata unavailable") }
        if info.st_size > 0 && info.st_size + Int64(line.count) > Int64(maximum) {
            for index in 1..<files { if let fd = try file(name + ".\(index)", create: false) { close(fd) } }
            close(current); descriptor = nil
            for index in stride(from: files - 1, through: 1, by: -1) {
                let source = index == 1 ? name : name + ".\(index - 1)", destination = name + ".\(index)"
                if unlinkat(folder, destination, 0) != 0 && errno != ENOENT { throw NativeFailure("Battery diagnostic archive could not be retired") }
                if renameat(folder, source, folder, destination) != 0 && errno != ENOENT { throw NativeFailure("Battery diagnostic archive could not be rotated") }
            }
            descriptor = try file(name, create: true)
        }
        guard let descriptor else { throw NativeFailure("Battery diagnostic writer unavailable") }
        try line.withUnsafeBytes { buffer in
            var offset = 0
            while offset < buffer.count {
                let count = Darwin.write(descriptor, buffer.baseAddress!.advanced(by: offset), buffer.count - offset)
                if count < 0 && errno == EINTR { continue }
                guard count > 0 else { throw NativeFailure("Battery diagnostic write failed") }; offset += count
            }
        }
    }
    private func openDirectory() throws -> Int32 {
        // Only documented system aliases are normalized. Resolving the caller's
        // whole path would quietly bless an attacker-controlled ancestor link.
        var path = directory.standardizedFileURL.path
        for alias in ["/var", "/tmp", "/etc"] where path == alias || path.hasPrefix(alias + "/") { path = "/private" + path; break }
        var descriptor = open("/", O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else { throw NativeFailure("Battery diagnostic ancestry unavailable") }
        do {
            for component in path.split(separator: "/") {
                let name = String(component)
                var next = openat(descriptor, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                if next < 0 && errno == ENOENT {
                    guard mkdirat(descriptor, name, 0o700) == 0 || errno == EEXIST else { throw NativeFailure("Battery diagnostic directory could not be created") }
                    next = openat(descriptor, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                }
                guard next >= 0 else { throw NativeFailure("Linked or unavailable battery diagnostic ancestry") }
                var info = stat()
                guard fstat(next, &info) == 0, (info.st_mode & S_IFMT) == S_IFDIR, info.st_uid == 0 || info.st_uid == geteuid() else { close(next); throw NativeFailure("Foreign battery diagnostic ancestry") }
                close(descriptor); descriptor = next
            }
            return descriptor
        } catch { close(descriptor); throw error }
    }
}
