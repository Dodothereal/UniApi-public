import Foundation
import Darwin

enum IPC {
    static func directory(_ uid: uid_t) -> String { "/var/run/app.devved.uniapi.fans-\(uid)" }
    static func path(_ uid: uid_t, _ pid: pid_t) -> String { directory(uid) + "/\(pid).sock" }
    /// The installed daemon's fixed endpoint. A temporary session names itself after the server
    /// process it belongs to; the daemon outlives all of them, so its path cannot.
    static func controlPath(_ uid: uid_t) -> String { directory(uid) + "/control.sock" }
    /// True when something is listening. Used to tell a crashed daemon's leftover socket file
    /// (safe to unlink) from a live one (must never be stolen).
    static func reachable(_ path: String) -> Bool {
        let fd = socket(AF_UNIX,SOCK_STREAM,0)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        var addr = address(path)
        return withUnsafePointer(to:&addr) { $0.withMemoryRebound(to:sockaddr.self,capacity:1) { connect(fd,$0,socklen_t(MemoryLayout<sockaddr_un>.size)) } } == 0
    }
    static func address(_ path: String) -> sockaddr_un {
        var address = sockaddr_un(); address.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8) + [0]
        precondition(bytes.count <= MemoryLayout.size(ofValue:address.sun_path))
        withUnsafeMutableBytes(of:&address.sun_path) { $0.copyBytes(from:bytes) }
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        return address
    }
    static func request(_ request: ControlRequest, uid: uid_t = getuid(), pid: pid_t = getpid()) throws -> ControlReply {
        let fd = socket(AF_UNIX,SOCK_STREAM,0)
        guard fd >= 0 else { throw FanError("Could not open the control connection.") }
        defer { close(fd) }
        var timeout = timeval(tv_sec:15,tv_usec:0)
        setsockopt(fd,SOL_SOCKET,SO_RCVTIMEO,&timeout,socklen_t(MemoryLayout<timeval>.size))
        setsockopt(fd,SOL_SOCKET,SO_SNDTIMEO,&timeout,socklen_t(MemoryLayout<timeval>.size))
        var noSignal: Int32 = 1; setsockopt(fd,SOL_SOCKET,SO_NOSIGPIPE,&noSignal,4)
        var addr = address(path(uid,pid))
        let result = withUnsafePointer(to:&addr) { $0.withMemoryRebound(to:sockaddr.self,capacity:1) { connect(fd,$0,socklen_t(MemoryLayout<sockaddr_un>.size)) } }
        guard result == 0 else { throw FanError("Enable fan controls to start a secure control session.") }
        var data = try JSONEncoder().encode(request); data.append(10)
        try sendData(data,fd:fd)
        let response = try readLine(fd:fd)
        return try JSONDecoder().decode(ControlReply.self,from:response)
    }
    static func sendData(_ data: Data, fd: Int32) throws {
        try data.withUnsafeBytes { bytes in
            var sent = 0
            while sent < bytes.count {
                let n = write(fd,bytes.baseAddress!.advanced(by:sent),bytes.count-sent)
                guard n > 0 else { throw FanError("The control connection closed.") }; sent += n
            }
        }
    }
    static func readLine(fd: Int32) throws -> Data {
        var data = Data(), buffer = [UInt8](repeating:0,count:1024)
        while data.count < 8192 {
            let n = read(fd,&buffer,buffer.count)
            guard n > 0 else { throw FanError("The control session did not respond.") }
            data.append(contentsOf:buffer.prefix(n))
            if let newline = data.firstIndex(of:10) { return data.prefix(upTo:newline) }
        }
        throw FanError("Control request exceeded the size limit.")
    }
}
