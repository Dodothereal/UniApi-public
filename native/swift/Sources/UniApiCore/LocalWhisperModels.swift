import Foundation
import CryptoKit
import Darwin

/// Explicit, optional assets only. This store never loads a model or starts inference.
public struct LocalWhisperAssets: Sendable {
    public let url: URL
    public let bytes: Int64
    public let sha256: String
    public init(url: URL, bytes: Int64, sha256: String) {
        self.url = url; self.bytes = bytes; self.sha256 = sha256.lowercased()
    }
    public static let production = LocalWhisperAssets(
        url: URL(string: "https://huggingface.co/ggerganov/whisper.cpp/resolve/87cd18b47b941d2f65d09981dad23bb7d0481c77/ggml-large-v3-turbo-q5_0.bin")!,
        bytes: 574041195,
        sha256: "394221709cd5ad1f40c46e6031ca61bce88931e6e088c188294c6d5a55ffa7e2")
}

public actor NativeLocalWhisperModels {
    public typealias Progress = @Sendable (Double, String) async throws -> Void
    /// The handle is an exclusively created private partial file. Do not close it or retain it
    /// after returning. Throwing (including cancellation) prevents publication.
    public typealias Downloader = @Sendable (URL, FileHandle, Int64, @escaping Progress) async throws -> Void
    private let paths: NativePaths
    private let assets: LocalWhisperAssets
    private let downloader: Downloader
    private var installing = false
    private var leases = 0
    private var verifiedFingerprint: WhisperModelFingerprint?
    // Internal diagnostic for offline cache regression tests; never persisted or trusted.
    private(set) var verificationHashCount = 0
    private let name = "ggml-large-v3-turbo-q5_0.bin"
    private var directory: URL { paths.data.appendingPathComponent("local-models/whisper", isDirectory: true) }

    public init(paths: NativePaths, assets: LocalWhisperAssets = .production,
                downloader: @escaping Downloader = { url, destination, maximumBytes, progress in
                    try await NativeLocalWhisperModels.download(url, destination, maximumBytes, progress)
                }) {
        self.paths = paths; self.assets = assets; self.downloader = downloader
    }

    /// `available` always means the installed file passed size, ownership and checksum checks.
    /// Missing or unsafe storage is reported without creating directories.
    public func status() -> JSONValue {
        var result: JSONObject = ["available": false, "installing": .bool(installing),
            "inUse": .bool(leases > 0), "bytes": .number(Double(assets.bytes)),
            "model": .string(name)]
        do {
            let dir = try openDirectory(create: false); defer { close(dir) }
            let lock = try acquireModelLock(dir, exclusive: false, create: false)
            defer { if let lock { close(lock) } }
            let fd = try verifiedModel(dir); defer { close(fd) }
            result["available"] = true
            result["state"] = "installed"
        } catch {
            verifiedFingerprint = nil
            result["state"] = installing ? "installing" : "unavailable"
            result["message"] = .string(error.localizedDescription)
        }
        return .object(result)
    }

    public func install(progress: @escaping Progress) async throws {
        try paths.assertWritable()
        guard !installing else { throw NativeFailure("A local Whisper model install is already running") }
        guard leases == 0 else { throw NativeFailure("The local Whisper model is in use") }
        guard assets.bytes > 0, assets.sha256.count == 64,
              assets.sha256.allSatisfy({ $0.isHexDigit && $0.isASCII }) else {
            throw NativeFailure("Invalid local Whisper model descriptor")
        }
        try Task.checkCancellation()
        let dir = try openDirectory(create: true); defer { close(dir) }
        guard let lock = try acquireModelLock(dir, exclusive: true, create: true) else {
            throw NativeFailure("Local Whisper model coordination is unavailable")
        }
        defer { close(lock) }
        var existing = stat()
        if fstatat(dir, name, &existing, AT_SYMLINK_NOFOLLOW) == 0 {
            let fd = try verifiedModel(dir); close(fd)
            return
        }
        guard errno == ENOENT else { throw NativeFailure("Cannot inspect local Whisper model") }
        verifiedFingerprint = nil
        installing = true; defer { installing = false; verifiedFingerprint = nil }
        let part = ".\(UUID().uuidString).part"
        let fd = openat(dir, part, O_RDWR | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw NativeFailure("Cannot create private model download") }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: false)
        var identity = stat(); _ = fstat(fd, &identity)
        defer {
            // Never unlink a replacement planted at our random partial name.
            var current = stat()
            if fstatat(dir, part, &current, AT_SYMLINK_NOFOLLOW) == 0,
               current.st_dev == identity.st_dev, current.st_ino == identity.st_ino {
                _ = unlinkat(dir, part, 0)
            }
            try? handle.close()
        }
        try await progress(0, "Downloading local Whisper model")
        try await downloader(assets.url, handle, assets.bytes, progress)
        try Task.checkCancellation()
        try await progress(0.99, "Verifying local Whisper model")
        try verify(fd)
        guard fsync(fd) == 0 else { throw NativeFailure("Cannot sync model download") }
        try Task.checkCancellation()
        // The final callback can throw or cancel too; run it before the commit point.
        try await progress(1, "Local Whisper model verified")
        try Task.checkCancellation()
        var current = stat()
        guard fstatat(dir, part, &current, AT_SYMLINK_NOFOLLOW) == 0,
              current.st_dev == identity.st_dev, current.st_ino == identity.st_ino else {
            throw NativeFailure("Model partial was replaced")
        }
        // Exclusive promotion cannot overwrite an installed model from another store/process.
        guard renameatx_np(dir, part, dir, name, UInt32(RENAME_EXCL)) == 0 else {
            throw NativeFailure("Cannot atomically publish local Whisper model")
        }
        // Rename can change ctime. The next lookup verifies the published identity once.
        verifiedFingerprint = nil
        _ = fsync(dir)
    }

    public func remove() throws {
        try paths.assertWritable()
        guard !installing, leases == 0 else { throw NativeFailure("The local Whisper model is busy") }
        verifiedFingerprint = nil
        let dir = try openDirectory(create: false); defer { close(dir) }
        guard let lock = try acquireModelLock(dir, exclusive: true, create: true) else {
            throw NativeFailure("Local Whisper model coordination is unavailable")
        }
        defer { close(lock) }
        // Allow removal of corrupt bytes, but never links, foreign files or special files.
        let fd = openat(dir, name, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        if fd < 0, errno == ENOENT { return }
        guard fd >= 0 else { throw NativeFailure("Cannot open local Whisper model for removal") }
        defer { close(fd) }
        try ownedFile(fd)
        var opened = stat(), current = stat(); _ = fstat(fd, &opened)
        guard fstatat(dir, name, &current, AT_SYMLINK_NOFOLLOW) == 0,
              current.st_dev == opened.st_dev, current.st_ino == opened.st_ino,
              unlinkat(dir, name, 0) == 0 else { throw NativeFailure("Cannot safely remove local Whisper model") }
        _ = fsync(dir)
    }

    /// Parent ASR must keep the entire inference operation inside this lease.
    public func withModel<T: Sendable>(_ use: @Sendable (URL) async throws -> T) async throws -> T {
        guard !installing else { throw NativeFailure("The local Whisper model is being installed") }
        try Task.checkCancellation()
        let dir = try openDirectory(create: false); defer { close(dir) }
        guard let lock = try acquireModelLock(dir, exclusive: false, create: !paths.readOnly) else {
            throw NativeFailure("Local Whisper model coordination is unavailable")
        }
        defer { close(lock) }
        let fd = try verifiedModel(dir); defer { close(fd) }
        leases += 1; defer { leases -= 1 }
        return try await use(directory.appendingPathComponent(name))
    }

    /// Never delete this inode: replacing a lock file splits coordination between owners.
    /// Every acquisition is nonblocking, including calls made while an actor is suspended.
    /// Closing the private descriptor releases its flock after the entire operation finishes.
    private func acquireModelLock(_ dir: Int32, exclusive: Bool, create: Bool) throws -> Int32? {
        let flags = O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC
        var fd = openat(dir, ".model.lock", flags)
        if fd < 0, errno == ENOENT, create {
            fd = openat(dir, ".model.lock", O_RDWR | O_CREAT | O_EXCL | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC, 0o600)
            if fd < 0, errno == EEXIST { fd = openat(dir, ".model.lock", flags) }
        }
        if fd < 0, errno == ENOENT, !create { return nil }
        guard fd >= 0 else { throw NativeFailure("Cannot safely open local Whisper model lock") }
        do {
            let opened = try ownedFile(fd)
            guard opened.st_mode & 0o7777 == 0o600 else {
                throw NativeFailure("Local Whisper model lock requires mode 0600")
            }
            guard flock(fd, (exclusive ? LOCK_EX : LOCK_SH) | LOCK_NB) == 0 else {
                if errno == EWOULDBLOCK || errno == EAGAIN {
                    throw NativeFailure("Local Whisper model is busy in another operation or process")
                }
                throw NativeFailure("Cannot acquire local Whisper model lock")
            }
            var current = stat()
            guard fstatat(dir, ".model.lock", &current, AT_SYMLINK_NOFOLLOW) == 0,
                  current.st_dev == opened.st_dev, current.st_ino == opened.st_ino else {
                throw NativeFailure("Local Whisper model lock was replaced")
            }
            try ownedFile(fd)
            return fd
        } catch { close(fd); throw error }
    }

    private func openDirectory(create: Bool) throws -> Int32 {
        // Walk from / using no-follow directory descriptors, including configured ancestors.
        // Foundation can standardize an existing /private/var back to /var. Admit
        // only that root-owned macOS alias, before computing either component count.
        let components = try Self.modelStoragePath(directory.standardizedFileURL.path)
            .split(separator: "/").map(String.init)
        let dataComponents = try Self.modelStoragePath(paths.data.standardizedFileURL.path)
            .split(separator: "/").count
        var fd = open("/", O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard fd >= 0 else { throw NativeFailure("Model storage is unavailable") }
        do {
            for (index, component) in components.enumerated() {
                var next = openat(fd, component, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                if next < 0, errno == ENOENT, create, index >= dataComponents - 1 {
                    guard mkdirat(fd, component, 0o700) == 0 || errno == EEXIST else { throw NativeFailure("Cannot create model storage") }
                    next = openat(fd, component, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                }
                guard next >= 0 else { throw NativeFailure("Model storage is unavailable or linked") }
                close(fd); fd = next
                var info = stat()
                guard fstat(fd, &info) == 0 else { throw NativeFailure("Cannot inspect model storage") }
                if index >= dataComponents - 1 {
                    guard info.st_uid == geteuid(), info.st_mode & 0o022 == 0 else { throw NativeFailure("Model storage must be owned and private") }
                    if index >= dataComponents {
                        guard info.st_mode & 0o777 == 0o700 else { throw NativeFailure("Model directories require mode 0700") }
                    }
                }
            }
            return fd
        } catch { verifiedFingerprint = nil; close(fd); throw error }
    }

    static func modelStoragePath(_ path: String) throws -> String {
        guard path == "/var" || path.hasPrefix("/var/") else { return path }
        var info = stat()
        guard lstat("/var", &info) == 0, info.st_mode & S_IFMT == S_IFLNK,
              info.st_uid == 0 else { throw NativeFailure("The macOS /var storage alias is unavailable") }
        var buffer = [CChar](repeating: 0, count: Int(PATH_MAX) + 1)
        let count = readlink("/var", &buffer, buffer.count)
        guard count > 0, count < buffer.count else { throw NativeFailure("Cannot inspect the macOS /var storage alias") }
        let target = String(decoding: buffer.prefix(Int(count)).map { UInt8(bitPattern: $0) }, as: UTF8.self)
        guard target == "private/var" || target == "/private/var" else {
            throw NativeFailure("The macOS /var storage alias has an unexpected target")
        }
        // This is a literal, boundary-checked substitution, not general symlink resolution.
        return "/private" + path
    }
    @discardableResult
    private func ownedFile(_ fd: Int32) throws -> stat {
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
              info.st_uid == geteuid(), info.st_nlink == 1, info.st_mode & 0o777 == 0o600 else {
            throw NativeFailure("Model must be an owned, unlinked regular file with mode 0600")
        }
        return info
    }
    private func verifiedModel(_ dir: Int32) throws -> Int32 {
        let fd = openat(dir, name, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else {
            verifiedFingerprint = nil
            throw NativeFailure("Local Whisper model is unavailable; install it explicitly")
        }
        do { try verify(fd); return fd } catch { close(fd); throw error }
    }
    private func verify(_ fd: Int32) throws {
        do { try verifyFingerprint(fd) }
        catch { verifiedFingerprint = nil; throw error }
    }
    private func fingerprint(_ fd: Int32) throws -> WhisperModelFingerprint {
        let info = try ownedFile(fd)
        guard info.st_size == assets.bytes else { throw NativeFailure("Local Whisper model size mismatch") }
        return WhisperModelFingerprint(info)
    }
    private func verifyFingerprint(_ fd: Int32) throws {
        try Task.checkCancellation()
        let before = try fingerprint(fd)
        if verifiedFingerprint == before { return }
        verifiedFingerprint = nil
        verificationHashCount += 1
        guard lseek(fd, 0, SEEK_SET) == 0 else { throw NativeFailure("Cannot read model") }
        var hash = SHA256(), buffer = [UInt8](repeating: 0, count: 1 << 20)
        var total: Int64 = 0
        while true {
            try Task.checkCancellation()
            let count = Darwin.read(fd, &buffer, buffer.count)
            if count < 0, errno == EINTR { continue }
            guard count >= 0 else { throw NativeFailure("Cannot hash model") }
            if count == 0 { break }
            total += Int64(count)
            guard total <= assets.bytes else { throw NativeFailure("Local Whisper model size mismatch") }
            hash.update(data: Data(buffer.prefix(count)))
        }
        guard total == assets.bytes else { throw NativeFailure("Local Whisper model size mismatch") }
        let digest = hash.finalize().map { String(format: "%02x", $0) }.joined()
        guard digest == assets.sha256 else { throw NativeFailure("Local Whisper model checksum mismatch") }
        // Do not certify bytes changed during hashing. Both timestamps include nanoseconds;
        // restoring mtime after an in-place edit still changes ctime and invalidates the cache.
        let after = try fingerprint(fd)
        guard before == after else { throw NativeFailure("Local Whisper model changed during verification") }
        verifiedFingerprint = after
    }

    public static func download(_ url: URL, _ destination: FileHandle, _ maximumBytes: Int64,
                                _ progress: @escaping Progress) async throws {
        let delegate = WhisperDownloadDelegate(destination: destination, maximumBytes: maximumBytes)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil; configuration.urlCredentialStorage = nil
        configuration.urlCache = nil; configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        let session = URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
        let task = session.downloadTask(with: url)
        let lifecycle = WhisperDownloadLifecycle()
        defer { task.cancel(); session.invalidateAndCancel() }
        do {
            try await withTaskCancellationHandler(operation: {
                // Serialize startup with cancellation. If already cancelled, never resume
                // and never wait for a delegate completion for a task that did not start.
                guard lifecycle.start({ task.resume() }) else { throw CancellationError() }
                try Task.checkCancellation()
                for try await fraction in delegate.events {
                    try Task.checkCancellation()
                    try await progress(min(0.98, fraction * 0.98), "Downloading local Whisper model")
                }
                try Task.checkCancellation()
            }, onCancel: { lifecycle.cancel { task.cancel() } })
        } catch {
            lifecycle.cancel { task.cancel() }
            // Do not close/unlink the destination while the delegate could still be copying.
            if lifecycle.hasStarted { await delegate.waitForCompletion() }
            throw error
        }
    }
}

/// Process-local evidence of a full hash, tied to metadata from the opened descriptor.
/// Never serialize this value: each new store/process must establish its own hash evidence.
struct WhisperModelFingerprint: Equatable {
    let device: dev_t
    let inode: ino_t
    let size: off_t
    let mode: mode_t
    let owner: uid_t
    let group: gid_t
    let links: nlink_t
    let modifiedSeconds: Int
    let modifiedNanoseconds: Int
    let changedSeconds: Int
    let changedNanoseconds: Int
    let flags: UInt32
    let generation: UInt32
    init(_ info: stat) {
        device = info.st_dev; inode = info.st_ino; size = info.st_size
        mode = info.st_mode; owner = info.st_uid; group = info.st_gid; links = info.st_nlink
        modifiedSeconds = Int(info.st_mtimespec.tv_sec)
        modifiedNanoseconds = Int(info.st_mtimespec.tv_nsec)
        changedSeconds = Int(info.st_ctimespec.tv_sec)
        changedNanoseconds = Int(info.st_ctimespec.tv_nsec)
        flags = info.st_flags; generation = info.st_gen
    }
}

/// Resume and cancel are ordered under one lock so a cancellation cannot strand a
/// suspended URLSession task whose delegate completion the caller is awaiting.
final class WhisperDownloadLifecycle: @unchecked Sendable {
    private let lock = NSLock()
    private var started = false
    private var cancelled = false
    var hasStarted: Bool {
        lock.lock(); defer { lock.unlock() }; return started
    }
    func start(_ resume: @Sendable () -> Void) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard !cancelled, !started else { return false }
        started = true
        resume()
        return true
    }
    func cancel(_ cancel: @Sendable () -> Void) {
        lock.lock(); defer { lock.unlock() }
        guard !cancelled else { return }
        cancelled = true
        if started { cancel() }
    }
}

/// URLSession owns its disk-backed download. Its temporary URL is valid only inside
/// didFinishDownloadingTo, so copy it there with a bounded buffer into our private partial.
private final class WhisperDownloadDelegate: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    let events: AsyncThrowingStream<Double, Error>
    private let continuation: AsyncThrowingStream<Double, Error>.Continuation
    private let destination: FileHandle
    private let maximumBytes: Int64
    private var copyError: Error?
    private var copied = false
    private let completionLock = NSLock()
    private var completed = false
    private var completionWaiters: [CheckedContinuation<Void, Never>] = []
    func waitForCompletion() async {
        await withCheckedContinuation { waiter in
            completionLock.lock()
            if completed { completionLock.unlock(); waiter.resume() }
            else { completionWaiters.append(waiter); completionLock.unlock() }
        }
    }
    init(destination: FileHandle, maximumBytes: Int64) {
        var captured: AsyncThrowingStream<Double, Error>.Continuation!
        events = AsyncThrowingStream(bufferingPolicy: .bufferingNewest(1)) { captured = $0 }
        continuation = captured; self.destination = destination; self.maximumBytes = maximumBytes
    }
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        if totalBytesWritten > maximumBytes { copyError = NativeFailure("Model download exceeds pinned size"); downloadTask.cancel() }
        continuation.yield(min(1, Double(totalBytesWritten) / Double(maximumBytes)))
    }
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        do {
            guard let response = downloadTask.response as? HTTPURLResponse, response.statusCode == 200 else { throw NativeFailure("Model download requires HTTP 200") }
            let source = try FileHandle(forReadingFrom: location); defer { try? source.close() }
            var total: Int64 = 0
            while let bytes = try source.read(upToCount: 1 << 20), !bytes.isEmpty {
                guard downloadTask.state != .canceling else { throw CancellationError() }
                total += Int64(bytes.count)
                guard total <= maximumBytes else { throw NativeFailure("Model download exceeds pinned size") }
                try destination.write(contentsOf: bytes)
            }
            copied = true
        } catch { copyError = error }
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        completionLock.lock()
        completed = true
        let waiters = completionWaiters; completionWaiters.removeAll()
        completionLock.unlock()
        for waiter in waiters { waiter.resume() }
        if let failure = copyError ?? error { continuation.finish(throwing: failure) }
        else if !copied { continuation.finish(throwing: NativeFailure("Model download did not produce a file")) }
        else { continuation.finish() }
    }
}
