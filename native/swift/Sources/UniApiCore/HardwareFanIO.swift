import Foundation
import Darwin
import CryptoKit

public enum NativeUnixJSON {
    public static func request(_ body: JSONValue, path: String, timeout: Double = 20) async throws -> JSONValue {
        guard timeout.isFinite, timeout > 0, timeout <= 60 else { throw NativeFailure("Invalid control request deadline") }
        let owner = NativeUnixRequestOwner()
        return try await withTaskCancellationHandler(operation: {
            try Task.checkCancellation()
            let value = try await Task.detached(priority: .utility) { try exchange(body, path: path, timeout: timeout, owner: owner) }.value
            try Task.checkCancellation(); return value
        }, onCancel: { owner.cancel() })
    }
    private static func exchange(_ body: JSONValue, path: String, timeout: Double, owner: NativeUnixRequestOwner) throws -> JSONValue {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw NativeFailure("The control connection could not be opened") }
        guard owner.adopt(fd) else { close(fd); throw CancellationError() }
        defer { owner.release(fd) }
        guard fcntl(fd, F_SETFD, FD_CLOEXEC) == 0, fcntl(fd, F_SETFL, O_NONBLOCK) == 0 else { throw NativeFailure("The control connection could not be isolated") }
        var noSignal: Int32 = 1
        guard setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSignal, socklen_t(MemoryLayout<Int32>.size)) == 0 else { throw NativeFailure("The control socket could not be configured") }
        let deadline = ProcessInfo.processInfo.systemUptime + timeout
        func wait(_ events: Int16) throws {
            while true {
                try owner.check()
                let remaining = deadline - ProcessInfo.processInfo.systemUptime
                guard remaining > 0 else { throw NativeFailure("The fan control request exceeded its deadline; restoration may still be pending") }
                var readiness = pollfd(fd: fd, events: events, revents: 0)
                let result = poll(&readiness, 1, Int32(min(60000, max(1, (remaining * 1000).rounded(.up)))))
                if result < 0 && errno == EINTR { continue }
                try owner.check()
                guard result >= 0 else { throw NativeFailure("The control connection closed") }
                if result == 0 { continue }
                guard readiness.revents & Int16(POLLNVAL) == 0 else { throw NativeFailure("The control descriptor closed") }
                return
            }
        }
        var address = sockaddr_un(); address.sun_family = sa_family_t(AF_UNIX); address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        let name = Array(path.utf8) + [0]
        guard !path.utf8.contains(0), name.count <= MemoryLayout.size(ofValue: address.sun_path) else { throw NativeFailure("The control socket path is invalid or too long") }
        withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: name) }
        let connected = withUnsafePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) } }
        if connected != 0 {
            guard [EINPROGRESS, EAGAIN, EWOULDBLOCK].contains(errno) else { throw NativeFailure("No fan control session is available") }
            try wait(Int16(POLLOUT))
            var error: Int32 = 0, size = socklen_t(MemoryLayout<Int32>.size)
            guard getsockopt(fd, SOL_SOCKET, SO_ERROR, &error, &size) == 0, error == 0 else { throw NativeFailure("No fan control session is available") }
        }
        var data = try body.encoded(); data.append(10)
        try data.withUnsafeBytes { bytes in
            var sent = 0
            while sent < bytes.count {
                try wait(Int16(POLLOUT))
                let count = Darwin.write(fd, bytes.baseAddress!.advanced(by: sent), bytes.count - sent)
                if count < 0 && [EINTR, EAGAIN, EWOULDBLOCK].contains(errno) { continue }
                guard count > 0 else { throw NativeFailure("The control connection closed") }; sent += count
            }
        }
        var response = Data(), buffer = [UInt8](repeating: 0, count: 1024)
        while true {
            try wait(Int16(POLLIN))
            let count = Darwin.read(fd, &buffer, buffer.count)
            if count < 0 && [EINTR, EAGAIN, EWOULDBLOCK].contains(errno) { continue }
            guard count > 0 else { throw NativeFailure("The fan helper did not respond; restoration may still be pending") }
            response.append(contentsOf: buffer.prefix(count))
            guard response.count <= 8193 else { throw NativeFailure("The helper response exceeded its size limit") }
            if let newline = response.firstIndex(of: 10) {
                guard newline <= 8192 else { throw NativeFailure("The helper response exceeded its size limit") }
                let value = try JSONValue.decode(Data(response.prefix(upTo: newline)))
                guard case .bool = value["ok"], case .string = value["mode"], case .string = value["message"] else { throw NativeFailure("Invalid helper response") }
                try owner.check(); return value
            }
        }
    }
}

private final class NativeUnixRequestOwner: @unchecked Sendable {
    private let lock = NSLock()
    private var descriptor: Int32?, cancelled = false
    func adopt(_ descriptor: Int32) -> Bool { lock.lock(); defer { lock.unlock() }; guard !cancelled else { return false }; self.descriptor = descriptor; return true }
    func check() throws { lock.lock(); defer { lock.unlock() }; if cancelled { throw CancellationError() } }
    func cancel() {
        lock.lock(); defer { lock.unlock() }; cancelled = true
        // shutdown wakes poll/read without releasing a descriptor that another
        // thread could reuse before its owner reaches the final close.
        if let descriptor { _ = shutdown(descriptor, SHUT_RDWR) }
    }
    func release(_ descriptor: Int32) { lock.lock(); defer { lock.unlock() }; close(descriptor); self.descriptor = nil }
}

public struct NativeFanIO: Sendable {
    public var metadata: @Sendable () -> JSONValue
    public var monitor: @Sendable () throws -> AsyncThrowingStream<JSONValue, Error>
    public var request: @Sendable (JSONValue, Bool) async throws -> JSONValue
    public var authorize: @Sendable (String) async throws -> Void
    public var now: @Sendable () -> Double
    public var sleep: @Sendable (Double) async throws -> Void
    public var stopMonitor: @Sendable () async -> Void
    public init(metadata: @escaping @Sendable () -> JSONValue, monitor: @escaping @Sendable () throws -> AsyncThrowingStream<JSONValue, Error>, request: @escaping @Sendable (JSONValue, Bool) async throws -> JSONValue, authorize: @escaping @Sendable (String) async throws -> Void, now: @escaping @Sendable () -> Double = { Date().timeIntervalSince1970 * 1000 }, sleep: @escaping @Sendable (Double) async throws -> Void = { try await Task.sleep(nanoseconds: UInt64($0 * 1e9)) }, stopMonitor: @escaping @Sendable () async -> Void = {}) {
        self.metadata = metadata; self.monitor = monitor; self.request = request; self.authorize = authorize; self.now = now; self.sleep = sleep; self.stopMonitor = stopMonitor
    }
    public static func production(runtime: NativeRuntime) -> NativeFanIO {
        let paths = NativeHardwareLocations(paths: runtime.paths)
        let digests = NativeFanDigestCache()
        let readers = NativeFanMonitorOwner()
        return .init(metadata: {
            let fm = FileManager.default
            let built = digests.digest(paths.fanBinary), installed = digests.digest(paths.fanInstalled)
            let current = built != nil && built == installed
            return ["supported": true, "installed": .bool(fm.isExecutableFile(atPath: paths.fanBinary.path)), "daemonInstalled": .bool(fm.fileExists(atPath: paths.fanInstalled.path) && fm.fileExists(atPath: paths.fanPlist.path)), "daemonAvailable": .bool(fm.fileExists(atPath: paths.fanDaemonSocket)), "current": .bool(current)]
        }, monitor: {
            let process = try runtime.process.open(paths.fanBinary, arguments: ["--monitor"])
            readers.adopt(process)
            return AsyncThrowingStream(bufferingPolicy: .bufferingNewest(4)) { continuation in
                let task = Task {
                    var pending = Data()
                    do {
                        for try await data in process.output {
                            pending.append(data)
                            guard pending.count < 200000 else { throw NativeFailure("Fan telemetry frame exceeded its size limit") }
                            while let end = pending.firstIndex(of: 10) { let line = Data(pending.prefix(upTo: end)); pending.removeSubrange(...end); if line.count <= 100000, let sample = try? JSONValue.decode(line), NativeHardwarePolicies.fanSnapshot(sample) { continuation.yield(sample) } }
                        }
                        let result = try await process.wait()
                        if result.status != 0 { throw NativeFailure(String(result.errorOutput.suffix(1000))) }
                        readers.finished(process)
                        continuation.finish()
                    } catch {
                        process.cancel(); _ = try? await process.wait()
                        readers.finished(process)
                        continuation.finish(throwing: error)
                    }
                }
                continuation.onTermination = { _ in task.cancel(); process.cancel() }
            }
        }, request: { body, daemon in try await NativeUnixJSON.request(body, path: daemon ? paths.fanDaemonSocket : paths.fanSessionSocket) }, authorize: { action in
            guard let osascript = runtime.process.which("osascript"), let bash = runtime.process.which("bash") else { throw NativeFailure("Administrator authorization is unavailable") }
            let script: String
            if action == "enable" { script = NativeHardwareAuthorization.quote(paths.fanBinary.path) + " --serve \(getuid()) \(getpid()) >/dev/null 2>&1 &" }
            else if action == "install" { script = NativeHardwareAuthorization.quote(bash.path) + " " + NativeHardwareAuthorization.quote(paths.fanInstaller.path) + " install " + NativeHardwareAuthorization.quote(paths.fanBinary.path) + " \(getuid())" }
            else if action == "uninstall" { script = NativeHardwareAuthorization.quote(bash.path) + " " + NativeHardwareAuthorization.quote(paths.fanInstaller.path) + " uninstall" }
            else { throw NativeFailure("Unknown fan authorization operation") }
            try await NativeHardwareAuthorization.run(script: script, prompt: "UniApi needs permission for the requested fan helper operation.", process: runtime.process, osascript: osascript)
        }, stopMonitor: { await readers.stop() })
    }
}

/// Owns only processes opened by this IO instance. Stream cancellation signals
/// them immediately; explicit shutdown waits for their existing owned-tree drain.
private final class NativeFanMonitorOwner: @unchecked Sendable {
    private let lock = NSLock()
    private var sessions: [NativeProcessSession] = []
    func adopt(_ session: NativeProcessSession) { lock.lock(); defer { lock.unlock() }; sessions.append(session) }
    func finished(_ session: NativeProcessSession) { lock.lock(); defer { lock.unlock() }; sessions.removeAll { $0 === session } }
    private func owned() -> [NativeProcessSession] { lock.lock(); defer { lock.unlock() }; return sessions }
    func stop() async {
        let pending = owned()
        pending.forEach { $0.cancel() }
        for session in pending { _ = try? await session.wait(); finished(session) }
    }
}

private final class NativeFanDigestCache: @unchecked Sendable {
    private let lock = NSLock()
    private var entries: [URL: (signature: String, digest: String)] = [:]
    func digest(_ url: URL) -> String? {
        lock.lock(); defer { lock.unlock() }
        guard let info = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey]), let size = info.fileSize, let date = info.contentModificationDate else { return nil }
        let signature = "\(size):\(date.timeIntervalSince1970)"
        if let entry = entries[url], entry.signature == signature { return entry.digest }
        guard let bytes = try? Data(contentsOf: url) else { return nil }
        let digest = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
        entries[url] = (signature, digest); return digest
    }
}
