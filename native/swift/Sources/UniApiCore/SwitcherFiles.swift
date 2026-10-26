import Foundation
import Darwin
import CryptoKit

enum SwitcherDisk {
    static func read(_ file: URL, missing: Bool = true, limit: Int = 8 * 1024 * 1024) throws -> Data {
        let fd = open(file.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        if fd < 0 { if missing && errno == ENOENT { return Data() }; throw NativeFailure("Settings must be a readable regular file without links") }
        defer { close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG, info.st_nlink == 1, info.st_size >= 0, info.st_size <= limit else { throw NativeFailure("Settings must be a bounded regular file without links") }
        var result = Data(), buffer = [UInt8](repeating: 0, count: 65536)
        while true {
            let n = Darwin.read(fd, &buffer, buffer.count)
            if n == 0 { break }; if n < 0 && errno == EINTR { continue }
            guard n > 0, result.count + n <= limit else { throw NativeFailure("Settings read failed") }; result.append(contentsOf: buffer.prefix(n))
        }
        return result
    }
    static func text(_ file: URL, missing: Bool = true) throws -> String {
        guard let text = String(data: try read(file, missing: missing), encoding: .utf8) else { throw NativeFailure("Settings must contain UTF-8 text") }; return text
    }
    static func json(_ file: URL, fallback: JSONValue = [:]) throws -> JSONValue {
        let data = try read(file); return data.isEmpty ? fallback : try JSONValue.decode(data)
    }
    static func hash(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
    static func atomic(_ file: URL, _ data: Data, expected: Data? = nil) throws {
        let before = try read(file)
        if let expected, expected != before { throw NativeFailure("Configuration changed during this operation; the other edit was preserved") }
        try NativeFile.writeAtomic(data, to: file)
    }
    static func locked<T>(_ file: URL, _ body: () throws -> T) throws -> T {
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let path = file.appendingPathExtension("lock")
        let fd = open(path.path, O_RDWR | O_CREAT | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC, mode_t(0o600))
        guard fd >= 0 else { throw NativeFailure("Settings ownership lock is unavailable") }
        defer { close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG, info.st_nlink == 1, info.st_uid == geteuid(), flock(fd, LOCK_EX) == 0 else { throw NativeFailure("Settings ownership lock is invalid") }
        defer { flock(fd, LOCK_UN) }; return try body()
    }
    static func validLabel(_ value: JSONValue, limit: Int = 200) -> Bool {
        guard case .string(let text) = value else { return false }
        return !text.isEmpty && text.count <= limit && !text.unicodeScalars.contains { $0.value < 32 || $0.value == 127 }
    }
    static func env(_ paths: NativePaths) -> [String: String] {
        paths.home.standardizedFileURL == FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL ? ProcessInfo.processInfo.environment : [:]
    }
    static func codexHome(_ paths: NativePaths) -> URL { env(paths)["CODEX_HOME"].map { URL(fileURLWithPath: $0) } ?? paths.home.appendingPathComponent(".codex") }
    static func claudeHome(_ paths: NativePaths) -> URL { env(paths)["CLAUDE_CONFIG_DIR"].map { URL(fileURLWithPath: $0) } ?? paths.home.appendingPathComponent(".claude") }
    static func bridgeHome(_ paths: NativePaths) -> URL { env(paths)["CODEX_CHATGPT_WEB_HOME"].map { URL(fileURLWithPath: $0) } ?? paths.home.appendingPathComponent(".codex-chatgpt-web") }
}
