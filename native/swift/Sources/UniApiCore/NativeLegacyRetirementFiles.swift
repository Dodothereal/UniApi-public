import Foundation
import Darwin
import CNativeSystem

/// Selected canonical anchors may contain OS/home aliases. Every relative
/// descendant is opened through the admitted descriptor without following links.
enum NativeLegacyProtected {
    static func directory(anchor: URL, relative: String, owner: UInt32, create: Bool = false, privateLast: Bool = false) throws -> Int32 {
        let root = anchor.standardizedFileURL.resolvingSymlinksInPath()
        var fd = open(root.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw NativeFailure("Transfer directory anchor is unavailable") }
        var retained = false
        defer { if !retained { close(fd) } }
        let parts = relative.split(separator: "/").map(String.init)
        guard !relative.hasPrefix("/"), parts.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." && !$0.contains("\0") }) else { throw NativeFailure("Invalid protected relative directory") }
        for (index, part) in parts.enumerated() {
            if create && mkdirat(fd, part, 0o700) != 0 && errno != EEXIST { throw NativeFailure("Cannot prepare protected transfer directory") }
            let next = openat(fd, part, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard next >= 0 else { throw NativeFailure("Transfer directory is linked or unavailable") }
            close(fd); fd = next
            var info = stat()
            guard fstat(fd, &info) == 0, info.st_uid == owner, info.st_mode & S_IFMT == S_IFDIR,
                  info.st_mode & (privateLast && index == parts.count - 1 ? 0o077 : 0o022) == 0 else { throw NativeFailure("Transfer directory ownership or permissions are unsafe") }
            try directoryACL(fd)
            var after = stat()
            guard fstat(fd, &after) == 0, stable(info, after) else { throw NativeFailure("Transfer directory changed during ACL inspection") }
        }
        retained = true; return fd
    }
    static func noACL(_ fd: Int32) throws {
        errno = 0; let acl = acl_get_fd_np(fd, ACL_TYPE_EXTENDED), code = errno
        if let acl { acl_free(UnsafeMutableRawPointer(acl)) }
        guard acl == nil, code == ENOENT else { throw NativeFailure("Transfer metadata has an extended ACL") }
    }
    /// macOS home descendants such as Library normally deny everyone delete.
    /// Denies cannot widen mode-bit access; files and recovery artifacts retain
    /// the stricter noACL policy. Inspect the opened directory, never its path.
    static func directoryACL(_ fd: Int32) throws {
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFDIR else { throw NativeFailure("Transfer directory ACL requires an open directory") }
        errno = 0; let value = acl_get_fd_np(fd, ACL_TYPE_EXTENDED), code = errno
        guard let value else {
            guard code == ENOENT else { throw NativeFailure("Transfer directory ACL is unavailable") }
            return
        }
        defer { acl_free(UnsafeMutableRawPointer(value)) }
        try denyOnlyACL(value)
    }
    static func denyOnlyACL(_ value: acl_t) throws {
        guard acl_valid(value) == 0 else { throw NativeFailure("Transfer directory ACL is invalid") }
        // Darwin returns EINVAL both at iterator exhaustion and for bad input.
        // Locate a verified tail first, so an inspection failure cannot masquerade
        // as a successful early end. Empty extended ACL objects also fail closed.
        var tail: acl_entry_t?
        guard acl_get_entry(value, Int32(ACL_LAST_ENTRY.rawValue), &tail) == 0, let tail else { throw NativeFailure("Transfer directory ACL entries are unavailable") }
        var cursor = Int32(ACL_FIRST_ENTRY.rawValue)
        for _ in 0..<Int(ACL_MAX_ENTRIES) {
            var entry: acl_entry_t?, tag = ACL_UNDEFINED_TAG
            guard acl_get_entry(value, cursor, &entry) == 0, let entry,
                  acl_get_tag_type(entry, &tag) == 0, tag == ACL_EXTENDED_DENY else { throw NativeFailure("Transfer directory ACL grants access or has unknown entries") }
            if entry == tail { return }
            cursor = Int32(ACL_NEXT_ENTRY.rawValue)
        }
        throw NativeFailure("Transfer directory ACL exceeds the inspection bound")
    }
    static func validateFile(_ fd: Int32, owner: UInt32, maximum: Int64, privateFile: Bool = false, empty: Bool = false) throws {
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_nlink == 1, info.st_uid == owner,
              info.st_mode & (privateFile ? 0o077 : 0o022) == 0, info.st_size >= (empty ? 0 : 1), info.st_size <= maximum else { throw NativeFailure("Transfer metadata must be protected bounded regular files") }
        try noACL(fd)
    }
    static func stable(_ a: stat, _ b: stat) -> Bool {
        a.st_dev == b.st_dev && a.st_ino == b.st_ino && a.st_uid == b.st_uid && a.st_mode == b.st_mode && a.st_nlink == b.st_nlink && a.st_size == b.st_size &&
            a.st_mtimespec.tv_sec == b.st_mtimespec.tv_sec && a.st_mtimespec.tv_nsec == b.st_mtimespec.tv_nsec && a.st_ctimespec.tv_sec == b.st_ctimespec.tv_sec && a.st_ctimespec.tv_nsec == b.st_ctimespec.tv_nsec
    }
    static func read(anchor: URL, relative: String, owner: UInt32, maximum: Int64, privateFile: Bool = false) throws -> Data {
        let parts = relative.split(separator: "/").map(String.init)
        guard let name = parts.last, name != ".", name != "..", !relative.hasPrefix("/"), !name.contains("\0") else { throw NativeFailure("Invalid transfer metadata path") }
        let parent = try directory(anchor: anchor, relative: parts.dropLast().joined(separator: "/"), owner: owner)
        defer { close(parent) }
        let fd = openat(parent, name, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else { throw NativeFailure("Transfer metadata file is unavailable") }; defer { close(fd) }
        try validateFile(fd, owner: owner, maximum: maximum, privateFile: privateFile)
        var before = stat(); guard fstat(fd, &before) == 0 else { throw NativeFailure("Cannot inspect transfer metadata") }
        var value = Data(), bytes = [UInt8](repeating: 0, count: 65536)
        while true {
            let count = Darwin.read(fd, &bytes, bytes.count)
            if count < 0 && errno == EINTR { continue }; if count == 0 { break }
            guard count > 0, value.count + count <= before.st_size else { throw NativeFailure("Transfer metadata changed while reading") }
            value.append(contentsOf: bytes.prefix(count))
        }
        var after = stat(), path = stat()
        guard value.count == before.st_size, fstat(fd, &after) == 0, fstatat(parent, name, &path, AT_SYMLINK_NOFOLLOW) == 0,
              stable(before, after), stable(before, path) else { throw NativeFailure("Transfer metadata changed while reading") }
        return value
    }
    static func publish(_ data: Data, parent: Int32, name: String, owner: UInt32) throws {
        guard !data.isEmpty, data.count <= 1 << 20, !name.contains("/"), !name.contains("\0") else { throw NativeFailure("Invalid recovery snapshot") }
        let fd = openat(parent, name, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw NativeFailure("Cannot publish private recovery definition") }; defer { close(fd) }
        try validateFile(fd, owner: owner, maximum: 1 << 20, privateFile: true, empty: true)
        try data.withUnsafeBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                let count = Darwin.write(fd, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
                if count < 0 && errno == EINTR { continue }
                guard count > 0 else { throw NativeFailure("Cannot write private recovery definition") }; offset += count
            }
        }
        guard fsync(fd) == 0, fsync(parent) == 0 else { throw NativeFailure("Cannot commit private recovery definition") }
    }
}

struct NativeLegacyLoadedJob {
    let path: URL, program: URL, arguments: [String], environment: [String: String], pid: Int32
    static func isAbsent(_ result: NativeProcessResult, label: String, owner: UInt32) -> Bool {
        guard [3, 113].contains(result.status), result.output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
        let lines = result.errorOutput.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        // launchctl prints a space after gui: on the observed system; retain
        // the older compact spelling without accepting UID or label prefixes.
        for domain in ["gui: " + String(owner), "gui:" + String(owner)] {
            let target = "Could not find service \"" + label + "\" in domain for user " + domain
            if lines == [target] || lines == ["Bad request.", target] { return true }
        }
        return false
    }
    static func parse(_ text: String, target: String) throws -> Self {
        guard text.utf8.count <= 1 << 20, !text.contains("\0") else { throw NativeFailure("Loaded legacy metadata is invalid") }
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        guard lines.first(where: { !$0.isEmpty }) == target + " = {" else { throw NativeFailure("Loaded legacy domain or label differs") }
        var depth = 0, fields: [String: String] = [:], argv: [String] = [], blocks: [String: [String: String]] = [:], block = ""
        for line in lines {
            if depth == 1 {
                if line == "arguments = {" { guard !fields.keys.contains("arguments") else { throw NativeFailure("Duplicate loaded argv") }; fields["arguments"] = "present"; block = "arguments" }
                else if ["environment = {", "inherited environment = {", "default environment = {"].contains(line) {
                    block = String(line.dropLast(4)); guard blocks[block] == nil else { throw NativeFailure("Duplicate loaded environment") }; blocks[block] = [:]
                } else if let split = line.range(of: " = "), !line.hasSuffix("{") {
                    let key = String(line[..<split.lowerBound]), value = String(line[split.upperBound...])
                    if ["path", "program", "pid"].contains(key) { guard fields[key] == nil else { throw NativeFailure("Ambiguous loaded metadata") }; fields[key] = value }
                }
            } else if depth == 2 && line != "}" {
                if block == "arguments" { argv.append(line) }
                else if blocks[block] != nil {
                    guard let split = line.range(of: " => ") ?? line.range(of: " = ") else { throw NativeFailure("Unsupported loaded environment") }
                    let key = String(line[..<split.lowerBound]), value = String(line[split.upperBound...])
                    guard blocks[block]?[key] == nil else { throw NativeFailure("Ambiguous loaded environment") }; blocks[block]?[key] = value
                }
            }
            if depth == 2 && line == "}" { block = "" }
            depth += line.filter { $0 == "{" }.count - line.filter { $0 == "}" }.count
            guard depth >= 0 else { throw NativeFailure("Unsupported loaded definition format") }
        }
        guard depth == 0, let path = fields["path"], path.hasPrefix("/"), let program = fields["program"], program.hasPrefix("/"),
              let pidText = fields["pid"], let pid = Int32(pidText), pid > 1, !argv.isEmpty else { throw NativeFailure("Loaded legacy job has no verified running instance") }
        var environment: [String: String] = [:]
        for key in ["default environment", "inherited environment", "environment"] { environment.merge(blocks[key] ?? [:]) { _, newer in newer } }
        return .init(path: URL(fileURLWithPath: path), program: URL(fileURLWithPath: program), arguments: argv, environment: environment, pid: pid)
    }
    static func disabled(_ text: String, label: String) throws -> Bool {
        guard text.utf8.count <= 1 << 20, text.contains("disabled services = {") else { throw NativeFailure("Unsupported legacy disabled-state output") }
        var result: Bool?
        for line in text.split(separator: "\n") {
            let value = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if value.hasPrefix("\"" + label + "\" => ") || value.hasPrefix(label + " => ") {
                guard result == nil, let suffix = value.components(separatedBy: " => ").last, ["true", "false"].contains(suffix) else { throw NativeFailure("Ambiguous legacy disabled state") }
                result = suffix == "true"
            }
        }
        return result ?? false
    }
}

final class NativeLegacyWorkReader: @unchecked Sendable {
    let paths: NativePaths
    let lock = NSLock()
    var generation: [String] = [], cached: NativeTransferWork?
    init(paths: NativePaths) { self.paths = paths }
    private func stamp() throws -> [String] {
        let parent = try NativeLegacyProtected.directory(anchor: paths.data, relative: "", owner: getuid())
        defer { close(parent) }
        return try ["uniapi.sqlite", "uniapi.sqlite-wal", "uniapi.sqlite-journal"].map { name in
            let fd = openat(parent, name, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
            if fd < 0 && errno == ENOENT && name != "uniapi.sqlite" { return "absent" }
            guard fd >= 0 else { throw NativeFailure("Legacy work census is unavailable") }; defer { close(fd) }
            try NativeLegacyProtected.validateFile(fd, owner: getuid(), maximum: 16 * 1024 * 1024 * 1024, empty: true)
            var value = stat(); guard fstat(fd, &value) == 0 else { throw NativeFailure("Legacy work census is unavailable") }
            return "\(value.st_dev):\(value.st_ino):\(value.st_size):\(value.st_mtimespec.tv_sec):\(value.st_mtimespec.tv_nsec):\(value.st_ctimespec.tv_sec):\(value.st_ctimespec.tv_nsec)"
        }
    }
    func read() throws -> NativeTransferWork {
        try lock.withLock {
            let before = try stamp()
            if before == generation, let cached { return cached }
            let snapshot = try SQLiteSnapshotCore(paths.database)
            let db = try NativeDatabase(url: snapshot.database, readOnly: true)
            func count(_ sql: String) throws -> Int {
                let rows = try db.query(sql)
                guard rows.count == 1, case .number(let n) = rows[0]["n"], n.isFinite, n >= 0, n.rounded() == n, n < Double(Int.max) else { throw NativeFailure("Legacy work census has an invalid count") }; return Int(n)
            }
            let value = NativeTransferWork(jobs: try count("SELECT COUNT(*) AS n FROM jobs WHERE status IN ('running','queued')"),
                                           code: try count("SELECT COUNT(*) AS n FROM code_threads WHERE status IN ('starting','running','waiting')"))
            guard try count("SELECT COUNT(*) AS n FROM jobs WHERE status IS NULL OR status NOT IN ('queued','running','done','failed','cancelled')") == 0,
                  try count("SELECT COUNT(*) AS n FROM code_threads WHERE status IS NULL OR status NOT IN ('idle','starting','running','waiting','error')") == 0 else { throw NativeFailure("Legacy work census contains unknown state") }
            guard try stamp() == before else { throw NativeFailure("Legacy work changed during its private census") }
            generation = before; cached = value; return value
        }
    }
}
