import Foundation
import Darwin

struct NativeLegacyHTTPExchange: Sendable { let data: Data; let reachedEOF: Bool }

enum NativeLegacyHTTPProbe {
    typealias Exchange = @Sendable (UInt16, Data, Double) async throws -> NativeLegacyHTTPExchange
    static func get(port: UInt16, path: String, timeout: Double, exchange: Exchange = { try await socketExchange(port: $0, request: $1, timeout: $2) }) async throws -> JSONValue {
        guard port > 0, path.hasPrefix("/"), path.utf8.allSatisfy({ (33...126).contains($0) }), !path.contains("#"),
              timeout.isFinite, timeout > 0 else { throw NativeFailure("Invalid bounded legacy health probe") }
        let request = Data("GET \(path) HTTP/1.1\r\nHost: 127.0.0.1:\(port)\r\nConnection: close\r\nAccept: application/json\r\nAccept-Encoding: identity\r\n\r\n".utf8)
        let value = try await exchange(port, request, timeout)
        try Task.checkCancellation()
        guard value.reachedEOF else { throw NativeFailure("Legacy probe transport did not close") }
        return try JSONValue.decode(body(value.data))
    }
    static func body(_ wire: Data) throws -> Data {
        guard wire.count <= 16 * 1024 * 1024, let split = wire.range(of: Data("\r\n\r\n".utf8)), split.lowerBound < 65536,
              let header = String(data: wire[..<split.lowerBound], encoding: .utf8) else { throw NativeFailure("Legacy probe response exceeded its bound or has invalid headers") }
        let lines = header.components(separatedBy: "\r\n")
        guard let first = lines.first, first.hasPrefix("HTTP/1.1 200 ") || first.hasPrefix("HTTP/1.0 200 ") else { throw NativeFailure("Legacy probe was not successful") }
        var fields: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { throw NativeFailure("Invalid legacy probe header") }
            let key = line[..<colon].lowercased(), value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            guard fields[key] == nil else { throw NativeFailure("Ambiguous legacy probe headers") }; fields[key] = value
        }
        guard fields["content-encoding"] == nil || fields["content-encoding"] == "identity" else { throw NativeFailure("Unsupported legacy probe encoding") }
        let body = Data(wire[split.upperBound...])
        if let transfer = fields["transfer-encoding"] {
            guard transfer.lowercased() == "chunked", fields["content-length"] == nil else { throw NativeFailure("Ambiguous legacy probe framing") }
            var cursor = 0, output = Data()
            while cursor < body.count {
                guard let line = body.range(of: Data("\r\n".utf8), in: cursor..<body.count), line.lowerBound - cursor < 128,
                      let text = String(data: body[cursor..<line.lowerBound], encoding: .ascii),
                      let size = Int(text.components(separatedBy: ";")[0], radix: 16), size >= 0, size <= 16 * 1024 * 1024 else { throw NativeFailure("Invalid legacy probe chunk") }
                cursor = line.upperBound
                if size == 0 {
                    guard body[cursor...] == Data("\r\n".utf8) else { throw NativeFailure("Unsupported legacy probe trailers") }; return output
                }
                guard size <= body.count - cursor - 2, body[cursor + size..<cursor + size + 2] == Data("\r\n".utf8) else { throw NativeFailure("Truncated legacy probe chunk") }
                output.append(body[cursor..<cursor + size]); cursor += size + 2
            }
            throw NativeFailure("Legacy probe chunks are incomplete")
        }
        if let length = fields["content-length"] { guard let expected = Int(length), expected == body.count else { throw NativeFailure("Legacy probe body is incomplete") } }
        return body
    }
    private final class Lifetime: @unchecked Sendable {
        let lock = NSLock()
        var fd: Int32 = -1, cancelled = false
        func claim(_ socket: Int32) throws {
            try lock.withLock { guard !cancelled else { throw CancellationError() }; fd = socket }
        }
        func check() throws { try lock.withLock { if cancelled { throw CancellationError() } } }
        func cancel() { lock.withLock { cancelled = true; if fd >= 0 { _ = shutdown(fd, SHUT_RDWR) } } }
        func finish() { lock.withLock { let held = fd; fd = -1; if held >= 0 { close(held) } } }
    }
    static func socketExchange(port: UInt16, request: Data, timeout: Double) async throws -> NativeLegacyHTTPExchange {
        guard timeout.isFinite, timeout > 0, timeout <= 30 else { throw NativeFailure("Invalid legacy probe deadline") }
        let lifetime = Lifetime()
        return try await withTaskCancellationHandler(operation: {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                DispatchQueue.global(qos: .utility).async {
                    do {
                        let result: NativeLegacyHTTPExchange = try {
                            let fd = socket(AF_INET, SOCK_STREAM, 0)
                            guard fd >= 0 else { throw NativeFailure("Cannot allocate legacy probe socket") }
                            do { try lifetime.claim(fd) } catch { close(fd); throw error }
                            defer { lifetime.finish() }
                            guard fcntl(fd, F_SETFL, O_NONBLOCK) == 0 else { throw NativeFailure("Cannot bound legacy probe socket") }
                            var noPipe: Int32 = 1
                            guard setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noPipe, socklen_t(MemoryLayout<Int32>.size)) == 0 else { throw NativeFailure("Cannot isolate legacy probe socket") }
                            let deadline = ProcessInfo.processInfo.systemUptime + timeout
                            func wait(_ events: Int16) throws {
                                while true {
                                    try lifetime.check()
                                    let remaining = deadline - ProcessInfo.processInfo.systemUptime
                                    guard remaining > 0 else { throw NativeFailure("Legacy probe transport deadline expired") }
                                    var descriptor = pollfd(fd: fd, events: events, revents: 0)
                                    let result = poll(&descriptor, 1, Int32(min(50, max(1, remaining * 1000))))
                                    if result < 0 && errno == EINTR { continue }
                                    guard result >= 0 else { throw NativeFailure("Legacy probe socket polling failed") }
                                    if result > 0 { try lifetime.check(); return }
                                }
                            }
                            var address = sockaddr_in(); address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
                            address.sin_family = sa_family_t(AF_INET); address.sin_port = port.bigEndian; address.sin_addr.s_addr = inet_addr("127.0.0.1")
                            let connected = withUnsafePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
                            guard connected == 0 || errno == EINPROGRESS else { throw NativeFailure("Legacy probe connection failed") }
                            if connected != 0 {
                                try wait(Int16(POLLOUT)); var error: Int32 = 0, length = socklen_t(MemoryLayout<Int32>.size)
                                guard getsockopt(fd, SOL_SOCKET, SO_ERROR, &error, &length) == 0, error == 0 else { throw NativeFailure("Legacy probe connection failed") }
                            }
                            try request.withUnsafeBytes { bytes in
                                var offset = 0
                                while offset < bytes.count {
                                    try wait(Int16(POLLOUT))
                                    let count = send(fd, bytes.baseAddress!.advanced(by: offset), bytes.count - offset, 0)
                                    if count < 0 && [EINTR, EAGAIN, EWOULDBLOCK].contains(errno) { continue }
                                    guard count > 0 else { throw NativeFailure("Legacy probe request failed") }; offset += count
                                }
                            }
                            var output = Data(), bytes = [UInt8](repeating: 0, count: 65536)
                            while true {
                                try wait(Int16(POLLIN)); let count = recv(fd, &bytes, bytes.count, 0)
                                if count < 0 && [EINTR, EAGAIN, EWOULDBLOCK].contains(errno) { continue }
                                if count == 0 { try lifetime.check(); return .init(data: output, reachedEOF: true) }
                                guard count > 0, output.count + count <= 16 * 1024 * 1024 else { throw NativeFailure("Legacy probe response failed or exceeded its bound") }
                                output.append(contentsOf: bytes.prefix(count))
                            }
                        }()
                        // Socket finish executes before the continuation resumes.
                        continuation.resume(returning: result)
                    } catch { continuation.resume(throwing: error) }
                }
            }
        }, onCancel: { lifetime.cancel() })
    }
}
