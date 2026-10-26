import Foundation
import Darwin
import CNativeSystem

/// Read-only admission for replacing the root executable while retaining its
/// launchd job, fixed target inode and original preference transaction.
public enum NativeBatteryUpgrade {
    public static func target(_ data: Data) throws -> Int {
        guard !data.isEmpty, data.count <= 16, !data.contains(0) else { throw NativeFailure("Invalid charging handoff target file") }
        var bytes = Array(data)
        while let last = bytes.last, last == 10 || last == 13 { bytes.removeLast() }
        if bytes == Array("off".utf8) { return 0 }
        let target = NativeBatteryDaemonPolicy.target(Data(bytes))
        guard target > 0 else { throw NativeFailure("Invalid charging handoff target file") }
        return target
    }
    public static func inspect(directory: URL, owner: uid_t) throws -> JSONValue {
        guard geteuid() == 0, owner >= 500 else { throw NativeFailure("Charging handoff admission requires administrator ownership and a local user") }
        try NativeBatteryDaemon.validateRootDirectory(directory)
        let fd = open(directory.appendingPathComponent("target").path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else { throw NativeFailure("Charging target is unavailable; controller preserved") }
        defer { close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_nlink == 1,
              info.st_uid == owner, info.st_mode & 0o077 == 0, info.st_size > 0, info.st_size <= 16 else { throw NativeFailure("Charging target ownership or shape is unsafe; controller preserved") }
        errno = 0
        let acl = acl_get_fd_np(fd, ACL_TYPE_EXTENDED), code = errno
        if let acl { acl_free(UnsafeMutableRawPointer(acl)) }
        guard acl == nil, code == ENOENT else { throw NativeFailure("Charging target has an extended ACL; controller preserved") }
        var buffer = [UInt8](repeating: 0, count: 17)
        let count = read(fd, &buffer, buffer.count)
        guard count == info.st_size else { throw NativeFailure("Charging target changed during handoff admission") }
        let target = try target(Data(buffer.prefix(count)))
        let preferences = NativeBatteryPreferences(directory: directory, io: .production())
        var report = try preferences.validateHandoff(target: target)
        report["owner"] = .number(Double(owner)); report["protocol"] = 1
        return report
    }
}
