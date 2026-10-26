import Foundation
import Darwin
import CNativeSystem

public struct NativeTransferIdentity: Sendable, Equatable {
    public let pid: Int32, parent: Int32, uid: UInt32
    public let bornSeconds: UInt64, bornMicroseconds: UInt64
    public let executable: String
    public let arguments: [String]
    public init(pid: Int32, parent: Int32, uid: UInt32, bornSeconds: UInt64, bornMicroseconds: UInt64, executable: String, arguments: [String]) {
        self.pid = pid; self.parent = parent; self.uid = uid; self.bornSeconds = bornSeconds; self.bornMicroseconds = bornMicroseconds
        self.executable = executable; self.arguments = arguments
    }
}

public struct NativeTransferSockets: Sendable, Equatable {
    public var listeningPorts: Set<UInt16> = []
    public var activeTCP = 0, pendingAccepts = 0
    public var isIdle: Bool { activeTCP == 0 && pendingAccepts == 0 }
    public init(listeningPorts: Set<UInt16> = [], activeTCP: Int = 0, pendingAccepts: Int = 0) {
        self.listeningPorts = listeningPorts; self.activeTCP = activeTCP; self.pendingAccepts = pendingAccepts
    }
}

/// Read-only kernel census for a later atomic retirement guard. It never
/// signals a process, contacts a provider or returns environment contents.
public enum NativeTransferProcessSystem {
    private static func information(_ pid: Int32, missing: Bool = false) throws -> proc_bsdinfo? {
        guard pid > 1 else { throw NativeFailure("Invalid service process") }
        var info = proc_bsdinfo(); errno = 0
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        let result = proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size)
        if result == 0 && missing && (errno == ESRCH || errno == ENOENT) { return nil }
        guard result == size, info.pbi_pid == UInt32(pid), info.pbi_uid == getuid(), info.pbi_ruid == getuid(),
              info.pbi_flags & UInt32(PROC_FLAG_SYSTEM) == 0 else { throw NativeFailure("Service process identity could not be established") }
        return info
    }
    public static func identity(_ pid: Int32) throws -> NativeTransferIdentity {
        let info = try information(pid)!
        var path = [UInt8](repeating: 0, count: Int(NativeProcPathBufferSize))
        guard proc_pidpath(pid, &path, UInt32(path.count)) > 0 else { throw NativeFailure("Service executable could not be established") }
        let executable = String(decoding: path.prefix(while: { $0 != 0 }), as: UTF8.self)
        let args = try arguments(pid)
        let after = try information(pid)!
        var finalPath = [UInt8](repeating: 0, count: path.count)
        guard after.pbi_start_tvsec == info.pbi_start_tvsec, after.pbi_start_tvusec == info.pbi_start_tvusec,
              after.pbi_ppid == info.pbi_ppid, proc_pidpath(pid, &finalPath, UInt32(finalPath.count)) > 0,
              finalPath == path else { throw NativeFailure("Service identity changed during its census") }
        return .init(pid: pid, parent: Int32(info.pbi_ppid), uid: info.pbi_uid,
                     bornSeconds: info.pbi_start_tvsec, bornMicroseconds: info.pbi_start_tvusec,
                     executable: executable, arguments: args)
    }
    /// Instance liveness cannot turn inspection failure or exec/reparent into
    /// exit evidence. Only an absent PID or a different birth is disappearance.
    public static func sameInstance(_ value: NativeTransferIdentity) throws -> Bool {
        guard let now = try information(value.pid, missing: true) else { return false }
        return now.pbi_uid == value.uid && now.pbi_start_tvsec == value.bornSeconds && now.pbi_start_tvusec == value.bornMicroseconds
    }
    static func sameProcess(_ value: NativeTransferIdentity) -> Bool {
        guard let now = try? identity(value.pid) else { return false }
        return now.uid == value.uid && now.bornSeconds == value.bornSeconds && now.bornMicroseconds == value.bornMicroseconds && now.executable == value.executable
    }
    static func stopped(_ pid: Int32) -> Bool {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        return proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size && info.pbi_status == 4
    }
    public static func stopped(_ value: NativeTransferIdentity) throws -> Bool {
        guard let now = try information(value.pid, missing: true) else { return false }
        guard now.pbi_uid == value.uid, now.pbi_start_tvsec == value.bornSeconds, now.pbi_start_tvusec == value.bornMicroseconds else { return false }
        return now.pbi_status == 4
    }
    public static func directory(_ value: NativeTransferIdentity) throws -> URL {
        guard try sameInstance(value) else { throw NativeFailure("Service disappeared before directory census") }
        var info = proc_vnodepathinfo()
        let size = Int32(MemoryLayout<proc_vnodepathinfo>.size)
        guard proc_pidinfo(value.pid, PROC_PIDVNODEPATHINFO, 0, &info, size) == size else { throw NativeFailure("Service directory could not be established") }
        let text = withUnsafeBytes(of: info.pvi_cdir.vip_path) { String(bytes: $0.prefix(while: { $0 != 0 }), encoding: .utf8) }
        guard let text, text.hasPrefix("/"), try sameInstance(value) else { throw NativeFailure("Service directory changed during census") }
        return URL(fileURLWithPath: text, isDirectory: true)
    }
    public static func children(_ pid: Int32) throws -> [Int32] {
        // Unlike PROC_PIDLISTFDS, libproc's convenience child API returns a
        // PID count (also for its sizing call), not a byte count.
        let required = proc_listchildpids(pid, nil, 0)
        guard required >= 0, required < 262_144 else { throw NativeFailure("Service children could not be established") }
        var values = [Int32](repeating: 0, count: Int(required) + 64)
        let count = proc_listchildpids(pid, &values, Int32(values.count * MemoryLayout<Int32>.size))
        guard count >= 0, Int(count) < values.count else { throw NativeFailure("Service child inventory changed beyond its bound") }
        return Array(values.prefix(Int(count)).filter { $0 > 1 })
    }
    public static func sockets(_ pid: Int32) throws -> NativeTransferSockets {
        let required = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, nil, 0)
        let stride = MemoryLayout<proc_fdinfo>.stride
        guard required > 0, required < 8 * 1024 * 1024 else { throw NativeFailure("Service sockets could not be inspected") }
        var descriptors = [proc_fdinfo](repeating: proc_fdinfo(), count: Int(required) / stride + 64)
        let copied = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, &descriptors, Int32(descriptors.count * stride))
        guard copied > 0, Int(copied) < descriptors.count * stride, Int(copied) % stride == 0 else { throw NativeFailure("Service socket inventory is incomplete") }
        var census = NativeTransferSockets()
        for descriptor in descriptors.prefix(Int(copied) / stride) where descriptor.proc_fdtype == UInt32(PROX_FDTYPE_SOCKET) {
            var socket = socket_fdinfo()
            let size = Int32(MemoryLayout<socket_fdinfo>.size)
            guard proc_pidfdinfo(pid, descriptor.proc_fd, PROC_PIDFDSOCKETINFO, &socket, size) == size else { throw NativeFailure("An owned service socket could not be inspected") }
            guard socket.psi.soi_kind == SOCKINFO_TCP else { continue }
            let tcp = socket.psi.soi_proto.pri_tcp
            if tcp.tcpsi_state == TSI_S_LISTEN {
                census.listeningPorts.insert(UInt16(bigEndian: UInt16(truncatingIfNeeded: tcp.tcpsi_ini.insi_lport)))
                guard socket.psi.soi_qlen >= 0, socket.psi.soi_incqlen >= 0 else { throw NativeFailure("Service accept inventory is unverified") }
                census.pendingAccepts += Int(socket.psi.soi_qlen) + Int(socket.psi.soi_incqlen)
            } else {
                // Closing/half-closed connections can still have an upstream
                // handler running. An established-only count misses those.
                census.activeTCP += 1
            }
        }
        return census
    }
    private static func arguments(_ pid: Int32) throws -> [String] {
        var query: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var length = 0
        guard sysctl(&query, UInt32(query.count), nil, &length, nil, 0) == 0, length > 4, length <= 2 * 1024 * 1024 else { throw NativeFailure("Service launch arguments could not be inspected") }
        var bytes = [UInt8](repeating: 0, count: length)
        guard sysctl(&query, UInt32(query.count), &bytes, &length, nil, 0) == 0, length <= bytes.count else { throw NativeFailure("Service launch arguments changed during inspection") }
        return try decodeArguments(Data(bytes.prefix(length)))
    }
    /// KERN_PROCARGS2 contains environment bytes after argv. A missing/empty
    /// argv[0] must not shift the argc window into that private tail. Refuse
    /// ambiguous images and environment-shaped entries rather than return them.
    static func decodeArguments(_ data: Data) throws -> [String] {
        let bytes = Array(data)
        guard bytes.count > MemoryLayout<Int32>.size, bytes.count <= 2 * 1024 * 1024 else { throw NativeFailure("Service arguments are truncated") }
        let count = data.withUnsafeBytes { $0.loadUnaligned(as: Int32.self) }
        guard count > 0, count < 4096 else { throw NativeFailure("Service argument count is invalid") }
        var cursor = MemoryLayout<Int32>.size
        let imageStart = cursor
        while cursor < bytes.count, bytes[cursor] != 0 { cursor += 1 }
        guard cursor < bytes.count, let image = String(bytes: bytes[imageStart..<cursor], encoding: .utf8), image.hasPrefix("/") else { throw NativeFailure("Service argument image is invalid") }
        while cursor < bytes.count, bytes[cursor] == 0 { cursor += 1 }
        var values: [String] = []
        for _ in 0..<count {
            let start = cursor
            while cursor < bytes.count, bytes[cursor] != 0 { cursor += 1 }
            guard cursor < bytes.count else { throw NativeFailure("Service arguments are truncated") }
            guard let value = String(bytes: bytes[start..<cursor], encoding: .utf8),
                  !value.contains("=") || value.hasPrefix("-") || value.hasPrefix("/") || value.hasPrefix("file://") else { throw NativeFailure("Service argument boundary is ambiguous") }
            values.append(value); cursor += 1
        }
        guard let first = values.first, !first.isEmpty else { throw NativeFailure("Service argument boundary is ambiguous") }
        let matches = first.hasPrefix("/") ? URL(fileURLWithPath: first).resolvingSymlinksInPath().path == URL(fileURLWithPath: image).resolvingSymlinksInPath().path : !first.contains("/") && first == URL(fileURLWithPath: image).lastPathComponent
        guard matches else { throw NativeFailure("Service argument boundary is ambiguous") }
        return values
    }
}
