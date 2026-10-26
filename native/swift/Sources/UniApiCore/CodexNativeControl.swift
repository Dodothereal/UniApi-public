import Foundation
import Darwin

/// A private capability authorizes admission changes, never model inference.
/// Reads do not create files. Only explicit shim startup creates the capability.
enum NativeCodexControlSecret {
    enum Purpose: String { case control = "shim-control-token", routing = "routing-token" }
    static func file(_ paths: NativePaths, purpose: Purpose = .control) -> URL { paths.data.appendingPathComponent("codex/native-route/" + purpose.rawValue) }
    static func load(_ paths: NativePaths, create: Bool = false, purpose: Purpose = .control) throws -> String {
        if create { try paths.assertWritable() }
        let file = file(paths, purpose: purpose)
        for directory in [paths.data, paths.data.appendingPathComponent("codex"), file.deletingLastPathComponent()] {
            var info = stat()
            if lstat(directory.path, &info) != 0 {
                guard errno == ENOENT, create else { throw NativeFailure("Native Codex control is not available") }
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
                guard lstat(directory.path, &info) == 0 else { throw NativeFailure("Cannot inspect native Codex control directory") }
            }
            guard info.st_mode & S_IFMT == S_IFDIR, info.st_uid == geteuid(), info.st_mode & 0o022 == 0 else { throw NativeFailure("Native Codex control directories must be owned and protected") }
            try noACL(directory)
        }
        func read() throws -> String {
            let fd = open(file.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
            guard fd >= 0 else { throw NativeFailure("Native Codex control capability is unavailable") }
            defer { close(fd) }
            var info = stat()
            guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_nlink == 1,
                  info.st_uid == geteuid(), info.st_mode & 0o777 == 0o600, info.st_size == 64 else { throw NativeFailure("Invalid native Codex control capability") }
            try noACL(file)
            var bytes = [UInt8](repeating: 0, count: 65), count = 0
            while count < bytes.count {
                let remaining = bytes.count - count
                let n = bytes.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress!.advanced(by: count), remaining) }
                if n < 0 && errno == EINTR { continue }
                guard n >= 0 else { throw NativeFailure("Cannot read native Codex control capability") }
                if n == 0 { break }; count += n
            }
            guard count == 64, bytes.prefix(64).allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else { throw NativeFailure("Invalid native Codex control capability") }
            return String(decoding: bytes.prefix(64), as: UTF8.self)
        }
        if !create { return try read() }
        return try SwitcherDisk.locked(file) {
            var info = stat()
            if lstat(file.path, &info) == 0 { return try read() }
            guard errno == ENOENT else { throw NativeFailure("Cannot inspect native Codex control capability") }
            let token = (UUID().uuidString + UUID().uuidString).replacingOccurrences(of: "-", with: "").lowercased()
            try NativeFile.writeAtomic(Data(token.utf8), to: file)
            return try read()
        }
    }
    private static func noACL(_ path: URL) throws {
        let fd = open(path.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else { throw NativeFailure("Cannot inspect native Codex control permissions") }
        defer { close(fd) }
        errno = 0
        let acl = acl_get_fd_np(fd, ACL_TYPE_EXTENDED), code = errno
        if let acl { _ = acl_free(UnsafeMutableRawPointer(acl)) }
        // Darwin reports no extended ACL as nil/ENOENT, not an empty ACL object.
        guard acl == nil, code == ENOENT else { throw NativeFailure("Native Codex control must not have extended ACLs") }
    }
}

/// A separate capability in the private configured path authorizes inference.
/// It never replaces Codex's native Authorization header or the admin token.
enum NativeCodexRoutingSecret {
    static func load(_ paths: NativePaths, create: Bool = false) throws -> String { try NativeCodexControlSecret.load(paths, create: create, purpose: .routing) }
    static func valid(_ token: String) -> Bool { token.utf8.count == 64 && token.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) } }
}

struct NativeCodexControlClient: Sendable {
    let paths: NativePaths, dependencies: ShimDependencies, port: Int
    init(paths: NativePaths, dependencies: ShimDependencies, port: Int = 8823) { self.paths = paths; self.dependencies = dependencies; self.port = port }
    private func request(_ operation: String, lease: String? = nil, deadline: Double? = nil) async throws -> JSONValue {
        guard (1...65535).contains(port) else { throw NativeFailure("Invalid native Codex control port") }
        let token = try NativeCodexControlSecret.load(paths)
        let body: JSONValue = lease.map { ["lease": .string($0), "deadline": .number(deadline ?? 0)] } ?? [:]
        let request = ShimHTTPRequest(url: URL(string: "http://127.0.0.1:\(port)/_uniapi/codex/control/\(operation)")!, method: operation == "status" ? "GET" : "POST",
                                      headers: ["authorization": "Bearer " + token, "content-type": "application/json"], body: operation == "status" ? nil : try body.encoded(), timeout: 2)
        let upstream = try await dependencies.transport.open(request), value = try JSONValue.decode(await upstream.body(limit: 65536))
        guard upstream.status == 200, value["service"] == "uniapi-shim", value["runtime"] == "swift", value["nativeVersion"] == 1,
              case .bool = value["accepting"], case .number(let count) = value["activeRequests"], count >= 0, count.rounded() == count,
              case .number(let pid) = value["pid"], pid > 0, pid.rounded() == pid, UUID(uuidString: value["instance"].string) != nil else { throw NativeFailure("Native Codex admission could not be verified") }
        return value
    }
    func status() async throws -> JSONValue { try await request("status") }
    func drained<T: Sendable>(_ action: @Sendable () async throws -> T) async throws -> T {
        let lease = UUID().uuidString
        let deadline = ProcessInfo.processInfo.systemUptime + 5
        func resume(_ before: JSONValue?) async throws {
            let after = try await request("resume", lease: lease, deadline: deadline)
            guard after["accepting"] == true, before == nil || (after["instance"] == before!["instance"] && after["pid"] == before!["pid"]) else { throw NativeFailure("The native Codex admission owner changed; inspect routing before continuing") }
        }
        var acquired: JSONValue?
        do {
            // The lease is known BEFORE submission. If a response is lost after
            // admission closes, detached cleanup can still release only ours.
            let before = try await request("drain", lease: lease, deadline: deadline)
            acquired = before
            guard before["accepting"] == false, before["lease"] == .string(lease) else { throw NativeFailure("Native Codex drain ownership is uncertain; no configuration was changed") }
            guard before["activeRequests"] == 0 else { throw NativeFailure("The Swift shim is busy; finish active requests before changing Codex routing") }
            try Task.checkCancellation()
            let value = try await action()
            try await Task.detached { try await resume(before) }.value
            return value
        } catch {
            let original = error
            let observed = acquired
            do { try await Task.detached { try await resume(observed) }.value }
            catch { throw NativeFailure("Codex routing stopped with uncertain admission; inspect native connection status before retrying") }
            throw original
        }
    }
}
