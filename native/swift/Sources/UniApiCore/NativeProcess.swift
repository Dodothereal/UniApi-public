import Foundation
import Darwin

private func nativeSpawnAttributes(_ attributes: inout posix_spawnattr_t?) throws {
    var mask = sigset_t(), defaults = sigset_t()
    sigemptyset(&mask); sigemptyset(&defaults)
    for value in [SIGTERM, SIGINT, SIGHUP, SIGQUIT, SIGPIPE] { sigaddset(&defaults, value) }
    guard posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_SETSIGMASK | POSIX_SPAWN_SETSIGDEF)) == 0,
          posix_spawnattr_setpgroup(&attributes, 0) == 0,
          posix_spawnattr_setsigmask(&attributes, &mask) == 0,
          posix_spawnattr_setsigdefault(&attributes, &defaults) == 0 else { throw NativeFailure("Cannot isolate child group and signal handling") }
}

public struct NativeProcessResult: Sendable {
    public var status: Int32
    public var stdout: Data
    public var stderr: Data
    public var output: String { String(decoding: stdout, as: UTF8.self) }
    public var errorOutput: String { String(decoding: stderr, as: UTF8.self) }
}

private final class NativeChildState: @unchecked Sendable {
    let lock = NSLock()
    var pid: pid_t?
    var cancelled = false
    var closed = false
    private var escalation: DispatchWorkItem?
    func cancel() {
        lock.lock(); defer { lock.unlock() }
        cancelled = true
        guard let pid, !closed else { return }
        // The group is created before exec, never inherited from the app.
        _ = kill(-pid, SIGTERM)
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.lock.lock(); defer { self.lock.unlock() }
            guard !self.closed, self.pid == pid else { return }
            _ = kill(-pid, SIGKILL)
        }
        escalation = work
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 2, execute: work)
    }
    func finish() { lock.lock(); defer { lock.unlock() }; closed = true; escalation?.cancel(); escalation = nil; pid = nil }
}

public final class NativeProcess: @unchecked Sendable {
    public init() {}
    public func open(_ executable: URL, arguments: [String] = [], environment: [String: String]? = nil, directory: URL? = nil) throws -> NativeProcessSession {
        try NativeProcessSession(executable: executable, arguments: arguments, environment: environment, directory: directory)
    }
    public func which(_ name: String) -> URL? {
        if name.contains("/") {
            let url = URL(fileURLWithPath: NSString(string: name).expandingTildeInPath)
            return FileManager.default.isExecutableFile(atPath: url.path) ? url : nil
        }
        let home = FileManager.default.homeDirectoryForCurrentUser
        var directories = (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":").map(String.init)
        directories += [home.appendingPathComponent(".local/bin").path, "/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin", "/usr/sbin", "/sbin"]
        let nvm = home.appendingPathComponent(".nvm/versions/node")
        if let versions = try? FileManager.default.contentsOfDirectory(at: nvm, includingPropertiesForKeys: nil) {
            directories += versions.sorted { $0.lastPathComponent > $1.lastPathComponent }.map { $0.appendingPathComponent("bin").path }
        }
        for directory in directories {
            let url = URL(fileURLWithPath: directory).appendingPathComponent(name)
            if FileManager.default.isExecutableFile(atPath: url.path) { return url }
        }
        return nil
    }
    public func cleanAgentEnvironment(_ original: [String: String] = ProcessInfo.processInfo.environment) -> [String: String] {
        original.filter { key, _ in
            if key == "CLAUDE_CONFIG_DIR" || key == "CODEX_HOME" { return true }
            return !key.hasPrefix("ANTHROPIC_") && !key.hasPrefix("CLAUDE") && !key.hasPrefix("CODEX_") && !key.hasPrefix("_EXECPATH") && !key.hasPrefix("_MESSAGING_")
        }
    }
    public func run(_ executable: URL, arguments: [String] = [], environment: [String: String]? = nil, input: Data? = nil, directory: URL? = nil) async throws -> NativeProcessResult {
        try await runStreaming(executable, arguments: arguments, environment: environment, input: input, directory: directory, onOutput: { _ in })
    }
    public func run(_ executable: URL, arguments: [String] = [], environment: [String: String]? = nil, input: Data? = nil, directory: URL? = nil, timeout: TimeInterval) async throws -> NativeProcessResult {
        guard timeout > 0, timeout.isFinite else { throw NativeFailure("Process timeout must be positive and finite") }
        return try await withThrowingTaskGroup(of: NativeProcessResult.self) { group in
            group.addTask { try await self.run(executable, arguments: arguments, environment: environment, input: input, directory: directory) }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(min(timeout, 86400 * 365) * 1e9))
                throw NativeFailure("\(executable.lastPathComponent) exceeded its \(Int(timeout)) second deadline")
            }
            defer { group.cancelAll() }
            return try await group.next()!
        }
    }
    public func runStreaming(_ executable: URL, arguments: [String] = [], environment: [String: String]? = nil, input: Data? = nil, directory: URL? = nil, onErrorOutput: @escaping @Sendable (Data) -> Void = { _ in }, onOutput: @escaping @Sendable (Data) -> Void) async throws -> NativeProcessResult {
        let state = NativeChildState()
        return try await withTaskCancellationHandler(operation: {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                DispatchQueue.global(qos: .userInitiated).async {
                    var descriptors: [Int32] = []
                    do {
                        func makePipe() throws -> (Int32, Int32) {
                            var p: [Int32] = [-1, -1]
                            guard pipe(&p) == 0 else { throw NativeFailure("Cannot allocate child pipe") }
                            descriptors += p
                            for fd in p { _ = fcntl(fd, F_SETFD, FD_CLOEXEC) }
                            return (p[0], p[1])
                        }
                        let out = try makePipe(), err = try makePipe(), stdin = try makePipe()
                        var attributes: posix_spawnattr_t?
                        var actions: posix_spawn_file_actions_t?
                        guard posix_spawnattr_init(&attributes) == 0 else { throw NativeFailure("Cannot initialize process attributes") }
                        defer { posix_spawnattr_destroy(&attributes) }
                        guard posix_spawn_file_actions_init(&actions) == 0 else { throw NativeFailure("Cannot initialize process file actions") }
                        defer { posix_spawn_file_actions_destroy(&actions) }
                        try nativeSpawnAttributes(&attributes)
                        for (from, to) in [(stdin.0, STDIN_FILENO), (out.1, STDOUT_FILENO), (err.1, STDERR_FILENO)] {
                            guard posix_spawn_file_actions_adddup2(&actions, from, to) == 0 else { throw NativeFailure("Cannot configure child streams") }
                        }
                        for fd in descriptors { posix_spawn_file_actions_addclose(&actions, fd) }
                        if let directory {
                            guard posix_spawn_file_actions_addchdir_np(&actions, directory.path) == 0 else { throw NativeFailure("Cannot configure child directory") }
                        }
                        let argv = ([executable.path] + arguments).map { strdup($0) } + [nil]
                        let envp = (environment ?? ProcessInfo.processInfo.environment).sorted { $0.key < $1.key }.map { strdup("\($0.key)=\($0.value)") } + [nil]
                        defer { argv.forEach { free($0) }; envp.forEach { free($0) } }
                        var pid: pid_t = 0
                        state.lock.lock()
                        if state.cancelled { state.lock.unlock(); throw CancellationError() }
                        let status = argv.withUnsafeBufferPointer { args in envp.withUnsafeBufferPointer { env in
                            posix_spawn(&pid, executable.path, &actions, &attributes, UnsafeMutablePointer(mutating: args.baseAddress!), UnsafeMutablePointer(mutating: env.baseAddress!))
                        } }
                        if status != 0 { state.lock.unlock(); throw NativeFailure("Cannot launch \(executable.lastPathComponent): \(String(cString: strerror(status)))") }
                        state.pid = pid; state.lock.unlock()
                        for fd in [stdin.0, out.1, err.1] { close(fd); descriptors.removeAll { $0 == fd } }
                        let collected = NativeProcessOutput(), readers = DispatchGroup()
                        for (fd, isError) in [(out.0, false), (err.0, true)] {
                            readers.enter()
                            DispatchQueue.global(qos: .utility).async {
                                defer { close(fd); readers.leave() }
                                var buffer = [UInt8](repeating: 0, count: 65536)
                                while true {
                                    let count = Darwin.read(fd, &buffer, buffer.count)
                                    if count == 0 { break }
                                    if count < 0 { if errno == EINTR { continue }; break }
                                    let bytes = Data(buffer.prefix(count))
                                    collected.append(bytes, error: isError)
                                    if isError { onErrorOutput(bytes) } else { onOutput(bytes) }
                                }
                            }
                        }
                        descriptors.removeAll { $0 == out.0 || $0 == err.0 || $0 == stdin.1 }
                        DispatchQueue.global(qos: .utility).async {
                            defer { close(stdin.1) }
                            _ = fcntl(stdin.1, F_SETNOSIGPIPE, 1)
                            if let input { input.withUnsafeBytes { bytes in
                                var offset = 0
                                while offset < bytes.count {
                                    let count = Darwin.write(stdin.1, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
                                    if count < 0 { if errno == EINTR { continue }; break }
                                    offset += count
                                }
                            } }
                        }
                        // Reap only after stream closure. Escalation cannot race
                        // PID reuse while a descendant still owns a stream.
                        readers.wait()
                        var waitStatus: Int32 = 0
                        while waitpid(pid, &waitStatus, 0) < 0 && errno == EINTR {}
                        state.lock.lock(); let cancelled = state.cancelled; state.lock.unlock()
                        state.finish()
                        let exitCode = (waitStatus & 0x7f) == 0 ? (waitStatus >> 8) & 0xff : 128 + (waitStatus & 0x7f)
                        if cancelled { continuation.resume(throwing: CancellationError()) }
                        else { continuation.resume(returning: NativeProcessResult(status: exitCode, stdout: collected.stdout, stderr: collected.stderr)) }
                    } catch {
                        descriptors.forEach { close($0) }; state.finish()
                        continuation.resume(throwing: error)
                    }
                }
            }
        }, onCancel: { state.cancel() })
    }
}

/// Persistent duplex stdio for Claude's control protocol and ACP JSON-RPC.
/// Its process group has the same ownership guarantee as one-shot commands.
public final class NativeProcessSession: @unchecked Sendable {
    public let output: AsyncThrowingStream<Data, Error>
    private let state = NativeChildState()
    private let inputLock = NSLock()
    private let writeLock = NSLock()
    private var inputFD: Int32 = -1
    private let completion: Task<NativeProcessResult, Error>
    public var pid: Int32 { state.lock.lock(); defer { state.lock.unlock() }; return state.pid ?? 0 }
    fileprivate init(executable: URL, arguments: [String], environment: [String: String]?, directory: URL?) throws {
        var continuation: AsyncThrowingStream<Data, Error>.Continuation!
        output = AsyncThrowingStream(bufferingPolicy: .bufferingOldest(512)) { continuation = $0 }
        var descriptors: [Int32] = []
        func pipePair() throws -> (Int32, Int32) {
            var pair: [Int32] = [-1, -1]
            guard pipe(&pair) == 0 else { throw NativeFailure("Cannot allocate agent pipes") }
            for fd in pair { _ = fcntl(fd, F_SETFD, FD_CLOEXEC) }
            descriptors += pair; return (pair[0], pair[1])
        }
        let out: (Int32, Int32), err: (Int32, Int32), input: (Int32, Int32)
        do { out = try pipePair(); err = try pipePair(); input = try pipePair() }
        catch { descriptors.forEach { close($0) }; throw error }
        var attributes: posix_spawnattr_t?, actions: posix_spawn_file_actions_t?
        guard posix_spawnattr_init(&attributes) == 0 else { descriptors.forEach { close($0) }; throw NativeFailure("Cannot initialize agent process") }
        defer { posix_spawnattr_destroy(&attributes) }
        guard posix_spawn_file_actions_init(&actions) == 0 else { descriptors.forEach { close($0) }; throw NativeFailure("Cannot initialize agent streams") }
        defer { posix_spawn_file_actions_destroy(&actions) }
        do {
            try nativeSpawnAttributes(&attributes)
            for (from, to) in [(input.0, STDIN_FILENO), (out.1, STDOUT_FILENO), (err.1, STDERR_FILENO)] {
                guard posix_spawn_file_actions_adddup2(&actions, from, to) == 0 else { throw NativeFailure("Cannot configure agent streams") }
            }
            for fd in descriptors { posix_spawn_file_actions_addclose(&actions, fd) }
            if let directory { guard posix_spawn_file_actions_addchdir_np(&actions, directory.path) == 0 else { throw NativeFailure("Cannot configure agent project directory") } }
            let argv = ([executable.path] + arguments).map { strdup($0) } + [nil]
            let envp = (environment ?? ProcessInfo.processInfo.environment).sorted { $0.key < $1.key }.map { strdup("\($0.key)=\($0.value)") } + [nil]
            defer { argv.forEach { free($0) }; envp.forEach { free($0) } }
            var pid: pid_t = 0
            let status = argv.withUnsafeBufferPointer { a in envp.withUnsafeBufferPointer { e in posix_spawn(&pid, executable.path, &actions, &attributes, UnsafeMutablePointer(mutating: a.baseAddress!), UnsafeMutablePointer(mutating: e.baseAddress!)) } }
            guard status == 0 else { throw NativeFailure("Cannot launch agent: \(String(cString: strerror(status)))") }
            state.pid = pid
        } catch { descriptors.forEach { close($0) }; throw error }
        for fd in [input.0, out.1, err.1] { close(fd) }
        inputFD = input.1; _ = fcntl(inputFD, F_SETNOSIGPIPE, 1)
        _ = fcntl(inputFD, F_SETFL, fcntl(inputFD, F_GETFL) | O_NONBLOCK)
        let state = self.state, stream = continuation!, collected = NativeProcessOutput(stderrLimit: 1_048_576)
        let readers = DispatchGroup()
        for (fd, isError) in [(out.0, false), (err.0, true)] {
            readers.enter()
            DispatchQueue.global(qos: .utility).async {
                defer { close(fd); readers.leave() }
                var buffer = [UInt8](repeating: 0, count: 65536)
                while true {
                    let count = Darwin.read(fd, &buffer, buffer.count)
                    if count == 0 { break }
                    if count < 0 { if errno == EINTR { continue }; break }
                    let bytes = Data(buffer.prefix(count))
                    // Stdout belongs in the persisted transcript, not a second
                    // full copy retained for the lifetime of an agent process.
                    if isError { collected.append(bytes, error: true) }
                    else if case .dropped = stream.yield(bytes) {
                        stream.finish(throwing: NativeFailure("Agent output exceeded the bounded buffer; the process was stopped to prevent transcript loss")); state.cancel(); break
                    }
                }
            }
        }
        completion = Task.detached {
            // Pipe closure and waitpid can block indefinitely during an agent
            // turn. Keep those waits off Swift's cooperative executor.
            try await withCheckedThrowingContinuation { continuation in
                DispatchQueue.global(qos: .utility).async {
                    readers.wait()
                    var waitStatus: Int32 = 0
                    state.lock.lock(); let pid = state.pid!; state.lock.unlock()
                    while waitpid(pid, &waitStatus, 0) < 0 && errno == EINTR {}
                    state.lock.lock(); let cancelled = state.cancelled; state.lock.unlock()
                    state.finish(); stream.finish()
                    if cancelled { continuation.resume(throwing: CancellationError()) }
                    else {
                        let status = (waitStatus & 0x7f) == 0 ? (waitStatus >> 8) & 0xff : 128 + (waitStatus & 0x7f)
                        continuation.resume(returning: NativeProcessResult(status: status, stdout: Data(), stderr: collected.stderr))
                    }
                }
            }
        }
        continuation.onTermination = { termination in if case .cancelled = termination { state.cancel() } }
    }
    deinit { closeInput(); state.cancel() }
    public func send(_ data: Data) throws {
        writeLock.lock(); defer { writeLock.unlock() }
        inputLock.lock()
        let fd = inputFD >= 0 ? fcntl(inputFD, F_DUPFD_CLOEXEC, 0) : -1
        inputLock.unlock()
        guard fd >= 0 else { throw NativeFailure("Agent input is closed") }
        defer { close(fd) }
        _ = fcntl(fd, F_SETNOSIGPIPE, 1)
        try data.withUnsafeBytes { buffer in
            var offset = 0
            while offset < buffer.count {
                state.lock.lock(); let cancelled = state.cancelled; state.lock.unlock()
                if cancelled { throw CancellationError() }
                let n = Darwin.write(fd, buffer.baseAddress!.advanced(by: offset), buffer.count - offset)
                if n < 0 {
                    if errno == EINTR { continue }
                    if errno == EAGAIN || errno == EWOULDBLOCK { var ready = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0); _ = poll(&ready, 1, 50); continue }
                    throw NativeFailure("Agent input could not be sent")
                }
                offset += n
            }
        }
    }
    public func send(_ value: JSONValue) throws { var bytes = try value.encoded(); bytes.append(10); try send(bytes) }
    public func closeInput() { inputLock.lock(); defer { inputLock.unlock() }; if inputFD >= 0 { close(inputFD); inputFD = -1 } }
    public func write(_ data: Data) async throws {
        try await withTaskCancellationHandler(operation: {
            try Task.checkCancellation()
            try await withCheckedThrowingContinuation { continuation in
                DispatchQueue.global(qos: .userInitiated).async {
                    do { try self.send(data); continuation.resume() }
                    catch { continuation.resume(throwing: error) }
                }
            }
        }, onCancel: { self.cancel() })
    }
    public func write(_ value: JSONValue) async throws { var bytes = try value.encoded(); bytes.append(10); try await write(bytes) }
    public func cancel() { state.cancel(); closeInput() }
    public func wait() async throws -> NativeProcessResult { try await withTaskCancellationHandler(operation: { try await completion.value }, onCancel: { self.cancel() }) }
}

private final class NativeProcessOutput: @unchecked Sendable {
    private let lock = NSLock()
    private var out = Data(), err = Data()
    private let stderrLimit: Int?
    private var stderrTruncated = false
    init(stderrLimit: Int? = nil) { self.stderrLimit = stderrLimit }
    var stdout: Data { lock.lock(); defer { lock.unlock() }; return out }
    var stderr: Data { lock.lock(); defer { lock.unlock() }; return stderrTruncated ? Data("[Earlier stderr omitted; retained diagnostic tail follows]\n".utf8) + err : err }
    func append(_ bytes: Data, error: Bool) {
        lock.lock(); defer { lock.unlock() }
        if error {
            err.append(bytes)
            if let limit = stderrLimit, err.count > limit { err = Data(err.suffix(limit)); stderrTruncated = true }
        } else { out.append(bytes) }
    }
}
