import Foundation
import Darwin

/// EADDRINUSE also describes a closed connection's retained TCP state. Keep
/// the failed port/code so only the final retirement phase may retry it;
/// startup still requires the same successful exclusive, non-reuse bind.
struct NativeOwnershipBindFailure: Error, LocalizedError, Sendable {
    let port: UInt16, code: Int32
    var errorDescription: String? {
        if code == EADDRINUSE {
            return "Local data ownership port \(port) is unavailable (bind errno \(code)). This build will not stop another owner."
        }
        return "Local data ownership port \(port) could not be established (bind errno \(code))."
    }
}

public enum NativeOwnership {
    /// Admission only: never contact, stop or restart the legacy service. A
    /// successful bind proves its listening socket is absent before writable
    /// native services can take ownership of the same persistent job database.
    public static func assertLegacyServerAbsent(port: UInt16 = 8780) throws {
        _ = try claim(port: port)
    }
    public static func claim(port: UInt16 = 8780) throws -> NativeOwnershipLease {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw NativeFailure("Cannot check local data ownership") }
        guard fcntl(fd, F_SETFD, FD_CLOEXEC) == 0 else { close(fd); throw NativeFailure("Cannot isolate the ownership socket") }
        var admitted = false
        defer { if !admitted { close(fd) } }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = port.bigEndian
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        let result = withUnsafePointer(to: &address) { pointer in pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
        guard result == 0 else {
            throw NativeOwnershipBindFailure(port: port, code: errno)
        }
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let named = withUnsafeMutablePointer(to: &address) { pointer in pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &length) } }
        guard named == 0 else { throw NativeFailure("Cannot identify the ownership socket") }
        admitted = true
        return NativeOwnershipLease(fd: fd, port: UInt16(bigEndian: address.sin_port))
    }
}

/// Retain the admission socket for the writable runtime's whole lifetime.
/// A transient probe leaves a race in which launchd can relaunch the old hub.
public final class NativeOwnershipLease: @unchecked Sendable {
    private let fd: Int32
    public let port: UInt16
    fileprivate init(fd: Int32, port: UInt16) { self.fd = fd; self.port = port }
    deinit { Darwin.close(fd) }
}
